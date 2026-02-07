import Foundation
import Network

/// Multicast address for LAN streaming
public enum MulticastConfig {
    /// Multicast group address for ScreenHero streams
    public static let groupAddress = "239.255.42.99"
    /// Default streaming port
    public static let defaultPort: UInt16 = 5000
}

/// UDP-based network sender using Network.framework (multicast)
public actor UDPSender: NetworkSender {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.screenhero.udpsender")
    private let packetProtocol: PacketProtocol

    public private(set) var isActive = false

    public init(host: String = MulticastConfig.groupAddress, port: UInt16 = MulticastConfig.defaultPort, maxPacketSize: Int = 1400) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.packetProtocol = PacketProtocol(maxPacketSize: maxPacketSize)
    }

    public func start() async throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        connection = NWConnection(host: host, port: port, using: params)

        return try await withCheckedThrowingContinuation { continuation in
            connection?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }

                Task {
                    switch state {
                    case .ready:
                        await self.setActive(true)
                        continuation.resume()
                    case .failed(let error):
                        await self.setActive(false)
                        continuation.resume(throwing: NetworkTransportError.connectionFailed(error.localizedDescription))
                    case .cancelled:
                        await self.setActive(false)
                    default:
                        break
                    }
                }
            }

            connection?.start(queue: queue)
        }
    }

    private func setActive(_ active: Bool) {
        isActive = active
    }

    public func stop() async {
        connection?.cancel()
        connection = nil
        isActive = false
    }

    public func send(_ packet: EncodedPacket) async throws {
        guard isActive, let connection = connection else {
            throw NetworkTransportError.notConnected
        }

        // Fragment the packet
        let fragments = packetProtocol.fragment(packet: packet)

        // Send each fragment
        for fragment in fragments {
            let data = fragment.serialize()
            try await sendData(data, connection: connection)
        }
    }

    private func sendData(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: NetworkTransportError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

/// UDP-based network receiver using Network.framework (multicast)
public actor UDPReceiver: NetworkReceiver {
    private let port: UInt16
    private let multicastGroup: String
    private var connectionGroup: NWConnectionGroup?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.screenhero.udpreceiver")
    private let packetProtocol: PacketProtocol
    private var continuation: AsyncStream<EncodedPacket>.Continuation?
    private var pendingFragments: [UInt64: [NetworkPacket]] = [:]
    private let fragmentTimeout: TimeInterval = 0.5

    public private(set) var isActive = false

    private lazy var _packets: AsyncStream<EncodedPacket> = {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }()

    public nonisolated var packets: AsyncStream<EncodedPacket> {
        AsyncStream { _ in }
    }

    public init(port: UInt16 = MulticastConfig.defaultPort, multicastGroup: String = MulticastConfig.groupAddress, maxPacketSize: Int = 1400) {
        self.port = port
        self.multicastGroup = multicastGroup
        self.packetProtocol = PacketProtocol(maxPacketSize: maxPacketSize)
    }

    public func start() async throws {
        // Initialize packets stream
        _ = _packets

        // Create multicast group descriptor
        let multicastGroupEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(multicastGroup),
            port: NWEndpoint.Port(rawValue: port)!
        )

        let groupDescriptor = try NWMulticastGroup(for: [multicastGroupEndpoint])
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        connectionGroup = NWConnectionGroup(with: groupDescriptor, using: params)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connectionGroup?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }

                Task {
                    switch state {
                    case .ready:
                        await self.setActive(true)
                        cont.resume()
                    case .failed(let error):
                        await self.setActive(false)
                        cont.resume(throwing: NetworkTransportError.connectionFailed(error.localizedDescription))
                    case .cancelled:
                        await self.setActive(false)
                    default:
                        break
                    }
                }
            }

            connectionGroup?.setReceiveHandler(maximumMessageSize: 65536, rejectOversizedMessages: false) { [weak self] message, content, isComplete in
                guard let self = self, let data = content else { return }
                Task {
                    await self.processReceivedData(data)
                }
            }

            connectionGroup?.start(queue: queue)
        }
    }

    private func setActive(_ active: Bool) {
        isActive = active
    }

    private func processReceivedData(_ data: Data) async {
        guard let fragment = NetworkPacket.deserialize(from: data) else {
            return
        }

        let frameId = fragment.frameId

        // Add to pending fragments
        if pendingFragments[frameId] == nil {
            pendingFragments[frameId] = []
        }
        pendingFragments[frameId]?.append(fragment)

        // Check if we have all fragments
        if let fragments = pendingFragments[frameId],
           fragments.count == Int(fragment.totalFragments) {
            if let packet = packetProtocol.reassemble(fragments: fragments) {
                continuation?.yield(packet)
            }
            pendingFragments.removeValue(forKey: frameId)
        }

        // Clean up old fragments
        cleanupOldFragments()
    }

    private func cleanupOldFragments() {
        // Keep only the last 100 frame IDs to prevent memory growth
        if pendingFragments.count > 100 {
            let sortedKeys = pendingFragments.keys.sorted()
            let keysToRemove = sortedKeys.prefix(pendingFragments.count - 100)
            for key in keysToRemove {
                pendingFragments.removeValue(forKey: key)
            }
        }
    }

    public func stop() async {
        connectionGroup?.cancel()
        connectionGroup = nil
        listener?.cancel()
        listener = nil
        isActive = false
        continuation?.finish()
        continuation = nil
    }

    /// Get packets stream (must call start first)
    public func getPackets() -> AsyncStream<EncodedPacket> {
        _packets
    }
}

/// Bidirectional UDP transport (combines sender and receiver)
public actor UDPTransport {
    private let sender: UDPSender
    private let receiver: UDPReceiver

    public init(
        remoteHost: String,
        remotePort: UInt16,
        localPort: UInt16,
        maxPacketSize: Int = 1400
    ) {
        self.sender = UDPSender(host: remoteHost, port: remotePort, maxPacketSize: maxPacketSize)
        self.receiver = UDPReceiver(port: localPort, maxPacketSize: maxPacketSize)
    }

    public func start() async throws {
        try await sender.start()
        try await receiver.start()
    }

    public func stop() async {
        await sender.stop()
        await receiver.stop()
    }

    public func send(_ packet: EncodedPacket) async throws {
        try await sender.send(packet)
    }

    public func getPackets() async -> AsyncStream<EncodedPacket> {
        await receiver.getPackets()
    }
}
