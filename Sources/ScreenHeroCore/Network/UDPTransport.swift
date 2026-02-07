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

        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            Task {
                switch state {
                case .ready:
                    await self.setActive(true)
                case .failed, .cancelled:
                    await self.setActive(false)
                default:
                    break
                }
            }
        }

        connection?.start(queue: queue)

        // UDP is connectionless - we don't need to wait for "ready" state
        // Just mark as active and let sends happen (they'll fail individually if there's an issue)
        isActive = true
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

/// UDP-based network receiver using Network.framework (multicast or unicast)
public actor UDPReceiver: NetworkReceiver {
    private let port: UInt16
    private let multicastGroup: String?
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

    /// Initialize for multicast reception
    public init(port: UInt16 = MulticastConfig.defaultPort, multicastGroup: String = MulticastConfig.groupAddress, maxPacketSize: Int = 1400) {
        self.port = port
        self.multicastGroup = multicastGroup
        self.packetProtocol = PacketProtocol(maxPacketSize: maxPacketSize)
    }

    /// Initialize for unicast reception (listen on port, receive from any sender)
    public init(port: UInt16, maxPacketSize: Int = 1400) {
        self.port = port
        self.multicastGroup = nil
        self.packetProtocol = PacketProtocol(maxPacketSize: maxPacketSize)
    }

    public func start() async throws {
        // Initialize packets stream
        _ = _packets

        if let multicastGroup = multicastGroup {
            try await startMulticast(group: multicastGroup)
        } else {
            try await startUnicast()
        }
    }

    private func startMulticast(group: String) async throws {
        print("[UDPReceiver] Starting multicast receiver on \(group):\(port)")

        let multicastGroupEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(group),
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
                        print("[UDPReceiver] Multicast receiver ready")
                        await self.setActive(true)
                        cont.resume()
                    case .failed(let error):
                        print("[UDPReceiver] Multicast receiver failed: \(error)")
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

    private func startUnicast() async throws {
        print("[UDPReceiver] Starting unicast receiver on port \(port)")

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NetworkTransportError.invalidAddress
        }

        listener = try NWListener(using: params, on: nwPort)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }

                Task {
                    switch state {
                    case .ready:
                        print("[UDPReceiver] Unicast listener ready on port \(self.port)")
                        await self.setActive(true)
                        cont.resume()
                    case .failed(let error):
                        print("[UDPReceiver] Unicast listener failed: \(error)")
                        await self.setActive(false)
                        cont.resume(throwing: NetworkTransportError.connectionFailed(error.localizedDescription))
                    case .cancelled:
                        await self.setActive(false)
                    default:
                        break
                    }
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                connection.stateUpdateHandler = { state in
                    if case .ready = state {
                        self.receiveOnConnection(connection)
                    }
                }
                connection.start(queue: self.queue)
            }

            listener?.start(queue: queue)
        }
    }

    private nonisolated func receiveOnConnection(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content {
                Task {
                    await self.processReceivedData(data)
                }
            }

            if error == nil {
                self.receiveOnConnection(connection)
            }
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

// MARK: - Server-style UDP Sender (learns client IPs dynamically)

/// Subscriber info with outgoing connection
private struct Subscriber {
    let ip: String
    let port: UInt16
    let connection: NWConnection
    var lastSeen: Date
}

/// UDP Server that listens for subscribers and streams to them
public actor UDPStreamServer: NetworkSender {
    private let port: UInt16
    private var listener: NWListener?
    private var subscribers: [String: Subscriber] = [:]  // "IP:port" -> Subscriber
    private let queue = DispatchQueue(label: "com.screenhero.udpserver")
    private let packetProtocol: PacketProtocol

    public private(set) var isActive = false

    public init(port: UInt16, maxPacketSize: Int = 1400) {
        self.port = port
        self.packetProtocol = PacketProtocol(maxPacketSize: maxPacketSize)
    }

    public func start() async throws {
        print("[UDPServer] Starting on port \(port)...")

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NetworkTransportError.invalidAddress
        }

        listener = try NWListener(using: params, on: nwPort)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                Task {
                    switch state {
                    case .ready:
                        print("[UDPServer] Listening on port \(self.port)")
                        await self.setActive(true)
                        cont.resume()
                    case .failed(let error):
                        print("[UDPServer] Failed: \(error)")
                        await self.setActive(false)
                        cont.resume(throwing: NetworkTransportError.connectionFailed(error.localizedDescription))
                    case .cancelled:
                        await self.setActive(false)
                    default:
                        break
                    }
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener?.start(queue: queue)
        }
    }

    private nonisolated func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                // Listen for messages
                self.receiveOnConnection(connection)
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private nonisolated func receiveOnConnection(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self = self else { return }

            if let data = content, let message = String(data: data, encoding: .utf8) {
                if message.hasPrefix("SUBSCRIBE") {
                    // Extract client's listening port from message: "SUBSCRIBE:port"
                    var clientPort: UInt16 = 5001  // default
                    if message.contains(":"), let portStr = message.split(separator: ":").last,
                       let port = UInt16(portStr) {
                        clientPort = port
                    }

                    if let endpoint = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let host, _) = endpoint {
                        let ip = host.debugDescription
                        print("[UDPServer] Subscribe from \(ip), will send to port \(clientPort)")
                        Task {
                            await self.addSubscriber(ip: ip, sendPort: clientPort)
                        }
                    }
                }
            }

            if error == nil {
                self.receiveOnConnection(connection)
            }
        }
    }

    private func addSubscriber(ip: String, sendPort: UInt16) {
        let key = "\(ip):\(sendPort)"

        if subscribers[key] == nil {
            print("[UDPServer] Creating outgoing connection to \(ip):\(sendPort)")

            // Create dedicated outgoing connection to client
            let host = NWEndpoint.Host(ip)
            guard let port = NWEndpoint.Port(rawValue: sendPort) else { return }

            let params = NWParameters.udp
            let conn = NWConnection(host: host, port: port, using: params)

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[UDPServer] Outgoing connection to \(ip):\(sendPort) ready")
                case .failed(let error):
                    print("[UDPServer] Outgoing connection to \(ip):\(sendPort) failed: \(error)")
                default:
                    break
                }
            }
            conn.start(queue: queue)

            subscribers[key] = Subscriber(ip: ip, port: sendPort, connection: conn, lastSeen: Date())
            print("[UDPServer] New subscriber: \(key) (total: \(subscribers.count))")
        } else {
            // Update last seen
            subscribers[key]?.lastSeen = Date()
        }
    }

    private func setActive(_ active: Bool) {
        isActive = active
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
        for (_, sub) in subscribers {
            sub.connection.cancel()
        }
        subscribers.removeAll()
        isActive = false
    }

    public func send(_ packet: EncodedPacket) async throws {
        guard isActive else {
            throw NetworkTransportError.notConnected
        }

        // Remove stale subscribers (not seen in 10 seconds)
        let cutoff = Date().addingTimeInterval(-10)
        let stale = subscribers.filter { $0.value.lastSeen < cutoff }
        for (key, sub) in stale {
            print("[UDPServer] Removing stale subscriber: \(key)")
            sub.connection.cancel()
            subscribers.removeValue(forKey: key)
        }

        guard !subscribers.isEmpty else {
            // No subscribers yet, just skip
            return
        }

        let fragments = packetProtocol.fragment(packet: packet)

        for (_, subscriber) in subscribers {
            for fragment in fragments {
                let data = fragment.serialize()
                subscriber.connection.send(content: data, completion: .contentProcessed { error in
                    if let error = error {
                        print("[UDPServer] Send error to \(subscriber.ip): \(error)")
                    }
                })
            }
        }
    }

    public var subscriberCount: Int {
        subscribers.count
    }
}

// MARK: - Client-style UDP Receiver (connects to server)

/// UDP Client that subscribes to a server and receives stream
public actor UDPStreamClient: NetworkReceiver {
    private let serverHost: String
    private let serverPort: UInt16
    private let listenPort: UInt16
    private var subscribeConnection: NWConnection?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.screenhero.udpclient")
    private let packetProtocol: PacketProtocol
    private var continuation: AsyncStream<EncodedPacket>.Continuation?
    private var pendingFragments: [UInt64: [NetworkPacket]] = [:]
    private var subscribeTimer: DispatchSourceTimer?

    public private(set) var isActive = false

    private lazy var _packets: AsyncStream<EncodedPacket> = {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }()

    public nonisolated var packets: AsyncStream<EncodedPacket> {
        AsyncStream { _ in }
    }

    public init(serverHost: String, serverPort: UInt16, listenPort: UInt16 = 5001, maxPacketSize: Int = 1400) {
        self.serverHost = serverHost
        self.serverPort = serverPort
        self.listenPort = listenPort
        self.packetProtocol = PacketProtocol(maxPacketSize: maxPacketSize)
    }

    public func start() async throws {
        print("[UDPClient] Connecting to \(serverHost):\(serverPort), listening on \(listenPort)...")

        _ = _packets

        // Start listener first to receive data from server
        try await startListener()

        // Create connection to send SUBSCRIBE to server
        let host = NWEndpoint.Host(serverHost)
        guard let port = NWEndpoint.Port(rawValue: serverPort) else {
            throw NetworkTransportError.invalidAddress
        }

        let params = NWParameters.udp
        subscribeConnection = NWConnection(host: host, port: port, using: params)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            subscribeConnection?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                Task {
                    switch state {
                    case .ready:
                        print("[UDPClient] Connected to \(self.serverHost):\(self.serverPort)")
                        await self.setActive(true)
                        await self.startSubscribing()
                        cont.resume()
                    case .failed(let error):
                        print("[UDPClient] Connection failed: \(error)")
                        await self.setActive(false)
                        cont.resume(throwing: NetworkTransportError.connectionFailed(error.localizedDescription))
                    case .cancelled:
                        await self.setActive(false)
                    default:
                        break
                    }
                }
            }

            subscribeConnection?.start(queue: queue)
        }
    }

    private func startListener() async throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: listenPort) else {
            throw NetworkTransportError.invalidAddress
        }

        listener = try NWListener(using: params, on: nwPort)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                Task {
                    switch state {
                    case .ready:
                        print("[UDPClient] Listener ready on port \(self.listenPort)")
                        cont.resume()
                    case .failed(let error):
                        print("[UDPClient] Listener failed: \(error)")
                        cont.resume(throwing: NetworkTransportError.connectionFailed(error.localizedDescription))
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection)
            }

            listener?.start(queue: queue)
        }
    }

    private nonisolated func handleIncomingConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.receiveOnConnection(connection)
            }
        }
        connection.start(queue: queue)
    }

    private func setActive(_ active: Bool) {
        isActive = active
    }

    private func startSubscribing() {
        // Send SUBSCRIBE message with our listen port
        sendSubscribeMessage()

        subscribeTimer = DispatchSource.makeTimerSource(queue: queue)
        subscribeTimer?.schedule(deadline: .now() + 1, repeating: 2.0)
        subscribeTimer?.setEventHandler { [weak self] in
            Task { await self?.sendSubscribeMessage() }
        }
        subscribeTimer?.resume()
    }

    private func sendSubscribeMessage() {
        // Include our listening port in the subscribe message
        guard let data = "SUBSCRIBE:\(listenPort)".data(using: .utf8) else { return }
        subscribeConnection?.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[UDPClient] Subscribe send error: \(error)")
            }
        })
    }

    private nonisolated func receiveOnConnection(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self = self else { return }

            if let data = content {
                Task {
                    await self.processReceivedData(data)
                }
            }

            if error == nil {
                self.receiveOnConnection(connection)
            }
        }
    }

    private func processReceivedData(_ data: Data) async {
        guard let fragment = NetworkPacket.deserialize(from: data) else {
            return
        }

        let frameId = fragment.frameId

        if pendingFragments[frameId] == nil {
            pendingFragments[frameId] = []
        }
        pendingFragments[frameId]?.append(fragment)

        if let fragments = pendingFragments[frameId],
           fragments.count == Int(fragment.totalFragments) {
            if let packet = packetProtocol.reassemble(fragments: fragments) {
                continuation?.yield(packet)
            }
            pendingFragments.removeValue(forKey: frameId)
        }

        // Cleanup old fragments
        if pendingFragments.count > 100 {
            let sortedKeys = pendingFragments.keys.sorted()
            for key in sortedKeys.prefix(pendingFragments.count - 100) {
                pendingFragments.removeValue(forKey: key)
            }
        }
    }

    public func stop() async {
        subscribeTimer?.cancel()
        subscribeTimer = nil
        subscribeConnection?.cancel()
        subscribeConnection = nil
        listener?.cancel()
        listener = nil
        isActive = false
        continuation?.finish()
    }

    public func getPackets() -> AsyncStream<EncodedPacket> {
        _packets
    }
}
