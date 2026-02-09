import Foundation
import Network

/// Flush stdout to ensure output appears immediately
public func netLog(_ message: String) {
    print(message)
    fflush(stdout)
}

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
    private let queue = DispatchQueue(label: "com.screenhero.udpsender", qos: .userInteractive)
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
    private let queue = DispatchQueue(label: "com.screenhero.udpreceiver", qos: .userInteractive)
    private let packetProtocol: PacketProtocol
    private var continuation: AsyncStream<EncodedPacket>.Continuation?
    private struct PendingFrame {
        var fragments: [NetworkPacket]
        var firstSeenNs: UInt64
        var lastUpdatedNs: UInt64
    }
    private var pendingFragments: [UInt64: PendingFrame] = [:]
    private let fragmentTimeout: TimeInterval = 0.05

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
        netLog("[UDPReceiver] Starting multicast receiver on \(group):\(port)")

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
                        netLog("[UDPReceiver] Multicast receiver ready")
                        await self.setActive(true)
                        cont.resume()
                    case .failed(let error):
                        netLog("[UDPReceiver] Multicast receiver failed: \(error)")
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
        netLog("[UDPReceiver] Starting unicast receiver on port \(port)")

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
                        netLog("[UDPReceiver] Unicast listener ready on port \(self.port)")
                        await self.setActive(true)
                        cont.resume()
                    case .failed(let error):
                        netLog("[UDPReceiver] Unicast listener failed: \(error)")
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
        let nowNs = DispatchTime.now().uptimeNanoseconds

        // Add to pending fragments
        if pendingFragments[frameId] == nil {
            pendingFragments[frameId] = PendingFrame(
                fragments: [],
                firstSeenNs: nowNs,
                lastUpdatedNs: nowNs
            )
        }
        pendingFragments[frameId]?.fragments.append(fragment)
        pendingFragments[frameId]?.lastUpdatedNs = nowNs

        if let entry = pendingFragments[frameId] {
            let fragments = entry.fragments
            let totalNeeded = Int(fragment.totalFragments)
            let dataNeeded = Int(fragment.dataFragmentCount)
            let dataCount = fragments.filter { !$0.isParity }.count

            let shouldAttempt = dataCount == dataNeeded || fragments.count >= dataNeeded

            if shouldAttempt, let packet = packetProtocol.reassemble(fragments: fragments) {
                continuation?.yield(packet)
                pendingFragments.removeValue(forKey: frameId)
            } else if fragments.count == totalNeeded {
                // All fragments arrived but still couldn't reassemble
                pendingFragments.removeValue(forKey: frameId)
            }
        }

        // Clean up old fragments
        cleanupOldFragments(nowNs: nowNs)
    }

    private func cleanupOldFragments(nowNs: UInt64) {
        let timeoutNs = UInt64(fragmentTimeout * 1_000_000_000)
        let expired = pendingFragments.filter { nowNs - $0.value.firstSeenNs > timeoutNs }
        for key in expired.keys {
            pendingFragments.removeValue(forKey: key)
        }

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

// MARK: - Server-style UDP Sender (uses incoming connections for replies)

/// Subscriber info - uses the same connection that sent SUBSCRIBE
private struct Subscriber {
    let id: String
    let connection: NWConnection
    var lastSeen: Date
}

/// UDP Server that listens for subscribers and streams to them
/// Uses the same connection for bidirectional communication (more firewall-friendly)
public actor UDPStreamServer: NetworkSender {
    private let port: UInt16
    private var listener: NWListener?
    private var subscribers: [String: Subscriber] = [:]
    private let queue = DispatchQueue(label: "com.screenhero.udpserver", qos: .userInteractive)
    private let packetProtocol: PacketProtocol

    public private(set) var isActive = false

    /// Callback for handling received input events
    private var inputEventHandler: ((InputEvent) -> InputEvent?)?

    /// Current stream configuration (can be changed by client)
    private var currentConfig: StreamConfigData?

    /// Callback for when client requests config change
    private var configChangeHandler: ((StreamConfigData) async -> Bool)?

    /// Enable packet pacing to reduce burst loss on LAN
    /// WARNING: Task.sleep() has ~500μs minimum overhead on macOS, so with 200+ fragments
    /// per frame, pacing can cause 100ms+ delays. Disabled by default.
    private let pacingEnabled: Bool = false

    public init(port: UInt16, maxPacketSize: Int = 1400) {
        self.port = port
        self.packetProtocol = PacketProtocol(maxPacketSize: maxPacketSize)
    }

    /// Set the handler for input events. The handler may return an InputEvent to send back (e.g., releaseCapture)
    public func setInputEventHandler(_ handler: @escaping (InputEvent) -> InputEvent?) {
        inputEventHandler = handler
        netLog("[UDPServer] Input event handler SET")
    }

    /// Set the current configuration (server reports this to clients)
    public func setCurrentConfig(_ config: StreamConfigData) {
        currentConfig = config
        netLog("[UDPServer] Config updated: \(config.width)x\(config.height) \(config.codec) \(config.bitrate/1_000_000)Mbps k=\(config.keyframeInterval)")
    }

    /// Set the handler for config change requests from clients
    /// Handler returns true if config was accepted and applied
    public func setConfigChangeHandler(_ handler: @escaping (StreamConfigData) async -> Bool) {
        configChangeHandler = handler
    }

    public func start() async throws {
        netLog("[UDPServer] Starting on port \(port)...")

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
                        netLog("[UDPServer] Listening on port \(self.port)")
                        await self.setActive(true)
                        cont.resume()
                    case .failed(let error):
                        netLog("[UDPServer] Failed: \(error)")
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
                Task { await self?.handleNewConnection(connection) }
            }

            listener?.start(queue: queue)
        }
    }

    private nonisolated func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                // Extract subscriber ID from endpoint
                if let endpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = endpoint {
                    let id = "\(host):\(port)"
                    netLog("[UDPServer] Connection ready from \(id)")
                    Task {
                        await self.addSubscriber(id: id, connection: connection)
                    }
                }
                // Start listening for messages on this connection
                self.receiveOnConnection(connection)
            case .failed(let error):
                netLog("[UDPServer] Connection failed: \(error)")
            case .cancelled:
                if let endpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = endpoint {
                    let id = "\(host):\(port)"
                    Task {
                        await self.removeSubscriber(id: id)
                    }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Track if we've logged connection info
    private static var hasLoggedConnectionReceive = false

    private nonisolated func receiveOnConnection(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self = self else { return }

            if let data = content {
                // Log first few packets to confirm data is arriving
                if !Self.hasLoggedConnectionReceive {
                    netLog("[UDPServer] Receiving data from connection, size=\(data.count)")
                    Self.hasLoggedConnectionReceive = true
                }

                // Log all received data for debugging (first time only per connection type)
                let dataPreview = data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")

                // Try to parse as text message first
                if let message = String(data: data, encoding: .utf8), message.hasPrefix("SUBSCRIBE") {
                    if let endpoint = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let host, let port) = endpoint {
                        let id = "\(host):\(port)"
                        netLog("[UDPServer] SUBSCRIBE from \(id)")
                        Task {
                            await self.updateSubscriberLastSeen(id: id)
                            // Send current config to new subscriber
                            await self.sendCurrentConfig(to: connection)
                        }
                    }
                }
                // Check for config message (magic 0x53484346 = "SHCF")
                else if ConfigMessage.isConfigMessage(data) {
                    if let configMsg = ConfigMessage.deserialize(from: data) {
                        Task {
                            await self.handleConfigMessage(configMsg, from: connection)
                        }
                    }
                }
                // Try to parse as input event (magic 0x53484950 = "SHIP")
                else if data.count >= 4 {
                    let magic = UInt32(data[data.startIndex]) << 24 |
                                UInt32(data[data.startIndex + 1]) << 16 |
                                UInt32(data[data.startIndex + 2]) << 8 |
                                UInt32(data[data.startIndex + 3])

                    // Debug: log non-video packets
                    if data.count < 100 {  // Input events are 28 bytes, video fragments are larger
                        netLog("[UDPServer] Small packet (\(data.count) bytes): magic=\(String(format: "0x%08X", magic)) expected=\(String(format: "0x%08X", InputEvent.magic))")
                    }

                    if magic == InputEvent.magic {
                        if let inputEvent = InputEvent.deserialize(from: data) {
                            netLog("[UDPServer] INPUT RECEIVED: \(inputEvent.type)")
                            Task {
                                await self.handleInputEvent(inputEvent, from: connection)
                            }
                        } else {
                            netLog("[UDPServer] Failed to deserialize input (data: \(dataPreview))")
                        }
                    } else {
                        // Unknown packet type - only log if small (to avoid video fragment spam)
                        if data.count < 100 {
                            netLog("[UDPServer] Unknown packet: \(dataPreview) (magic: \(String(format: "0x%08X", magic)))")
                        }
                    }
                }
            }

            if error == nil {
                self.receiveOnConnection(connection)
            }
        }
    }

    private func sendCurrentConfig(to connection: NWConnection) {
        guard let config = currentConfig else { return }
        let msg = ConfigMessage(type: .response, config: config)
        let data = msg.serialize()
        connection.send(content: data, completion: .idempotent)
        netLog("[UDPServer] Sent config to client: \(config.width)x\(config.height)")
    }

    private func handleConfigMessage(_ msg: ConfigMessage, from connection: NWConnection) async {
        switch msg.type {
        case .request:
            // Client wants current config
            sendCurrentConfig(to: connection)

        case .update:
            // Client wants to change config
            netLog("[UDPServer] Config change request: \(msg.config.width)x\(msg.config.height) \(msg.config.codec) \(msg.config.bitrate/1_000_000)Mbps k=\(msg.config.keyframeInterval)")

            if let handler = configChangeHandler {
                let accepted = await handler(msg.config)
                if accepted {
                    currentConfig = msg.config
                    // Send ack with updated config
                    let ack = ConfigMessage(type: .ack, config: msg.config)
                    connection.send(content: ack.serialize(), completion: .idempotent)
                    netLog("[UDPServer] Config change accepted")
                } else {
                    // Send current config (unchanged)
                    if let config = currentConfig {
                        let response = ConfigMessage(type: .response, config: config)
                        connection.send(content: response.serialize(), completion: .idempotent)
                    }
                    netLog("[UDPServer] Config change rejected")
                }
            }

        default:
            break
        }
    }

    private func handleInputEvent(_ event: InputEvent, from connection: NWConnection) {
        guard let handler = inputEventHandler else {
            netLog("[UDPServer] ERROR: inputEventHandler is nil! Cannot process input event: \(event.type)")
            return
        }

        netLog("[UDPServer] Calling input handler for event: \(event.type)")

        // Handle the event and get optional response
        if let response = handler(event) {
            // Send response back to the client
            let data = response.serialize()
            connection.send(content: data, completion: .idempotent)
            netLog("[UDPServer] Sent response: \(response.type)")
        }
    }

    private func addSubscriber(id: String, connection: NWConnection) {
        if subscribers[id] == nil {
            subscribers[id] = Subscriber(id: id, connection: connection, lastSeen: Date())
            netLog("[UDPServer] New subscriber: \(id) (total: \(subscribers.count))")
        }
    }

    private func updateSubscriberLastSeen(id: String) {
        subscribers[id]?.lastSeen = Date()
    }

    private func removeSubscriber(id: String) {
        if subscribers.removeValue(forKey: id) != nil {
            netLog("[UDPServer] Subscriber disconnected: \(id)")
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
            netLog("[UDPServer] Removing stale subscriber: \(key)")
            sub.connection.cancel()
            subscribers.removeValue(forKey: key)
        }

        guard !subscribers.isEmpty else {
            return
        }

        let fragments = packetProtocol.fragment(packet: packet)

        if packet.frameId == 0 {
            netLog("[UDPServer] Sending first frame to \(subscribers.count) subscriber(s), \(fragments.count) fragments")
        }

        let fragmentCount = fragments.count
        let pacingDelayNs = pacingEnabled ? pacingDelayNs(fragmentCount: fragmentCount) : 0

        for fragment in fragments {
            let data = fragment.serialize()
            for (_, subscriber) in subscribers {
                // Fire-and-forget for low latency - don't wait for completion
                subscriber.connection.send(content: data, completion: .idempotent)
            }

            if pacingDelayNs > 0 {
                try? await Task.sleep(nanoseconds: pacingDelayNs)
            }
        }
    }

    private func pacingDelayNs(fragmentCount: Int) -> UInt64 {
        guard fragmentCount > 1 else { return 0 }
        let fps = max(1, currentConfig?.fps ?? 60)
        let frameIntervalNs = UInt64(1_000_000_000 / fps)
        let spacing = frameIntervalNs / UInt64(fragmentCount)
        return spacing
    }

    public var subscriberCount: Int {
        subscribers.count
    }

    /// Broadcast an input event to all subscribers (e.g., cursor position updates)
    public func broadcastInputEvent(_ event: InputEvent) {
        guard !subscribers.isEmpty else { return }
        let data = event.serialize()
        for (_, subscriber) in subscribers {
            subscriber.connection.send(content: data, completion: .idempotent)
        }
    }
}

// MARK: - Client-style UDP Receiver (connects to server)

/// UDP Client that subscribes to a server and receives stream
/// Uses same connection for subscribe and receive (bidirectional)
public actor UDPStreamClient: NetworkReceiver {
    private let serverHost: String
    private let serverPort: UInt16
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.screenhero.udpclient", qos: .userInteractive)
    private let packetProtocol: PacketProtocol
    private var continuation: AsyncStream<EncodedPacket>.Continuation?
    private struct PendingFrame {
        var fragments: [NetworkPacket]
        var firstSeenNs: UInt64
        var lastUpdatedNs: UInt64
    }
    private var pendingFragments: [UInt64: PendingFrame] = [:]
    private let fragmentTimeout: TimeInterval = 0.05
    private var subscribeTimer: DispatchSourceTimer?

    /// Callback for handling received input events (e.g., releaseCapture from host)
    private var inputEventHandler: ((InputEvent) -> Void)?

    /// Callback for when server sends config
    private var configHandler: ((StreamConfigData) -> Void)?

    /// Requested config to send on connect
    private var requestedConfig: StreamConfigData?

    public private(set) var isActive = false

    /// Server's current config (received from server)
    public private(set) var serverConfig: StreamConfigData?

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
        // listenPort is now ignored - we receive on the same connection
        self.packetProtocol = PacketProtocol(maxPacketSize: maxPacketSize)
    }

    /// Set the handler for input events received from the server (e.g., releaseCapture)
    public func setInputEventHandler(_ handler: @escaping (InputEvent) -> Void) {
        inputEventHandler = handler
    }

    /// Set the handler for config updates from server
    public func setConfigHandler(_ handler: @escaping (StreamConfigData) -> Void) {
        configHandler = handler
    }

    /// Set the config to request from server on connect
    public func setRequestedConfig(_ config: StreamConfigData) {
        requestedConfig = config
    }

    public func start() async throws {
        netLog("[UDPClient] Connecting to \(serverHost):\(serverPort)...")

        _ = _packets

        let host = NWEndpoint.Host(serverHost)
        guard let port = NWEndpoint.Port(rawValue: serverPort) else {
            throw NetworkTransportError.invalidAddress
        }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        connection = NWConnection(host: host, port: port, using: params)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                Task {
                    switch state {
                    case .ready:
                        netLog("[UDPClient] Connected to \(self.serverHost):\(self.serverPort)")
                        await self.setActive(true)
                        await self.startSubscribing()
                        await self.startReceiving()
                        cont.resume()
                    case .failed(let error):
                        netLog("[UDPClient] Connection failed: \(error)")
                        await self.setActive(false)
                        cont.resume(throwing: NetworkTransportError.connectionFailed(error.localizedDescription))
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

    private func startSubscribing() {
        // Send SUBSCRIBE multiple times quickly at startup for reliability
        sendSubscribeMessage()

        // Send config request after first subscribe
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            Task { await self?.sendSubscribeMessage() }
        }
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            Task {
                await self?.sendSubscribeMessage()
                // Send config update request if we have one
                await self?.sendConfigRequest()
            }
        }
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            Task { await self?.sendSubscribeMessage() }
        }

        // Then keep sending periodically to maintain subscription
        subscribeTimer = DispatchSource.makeTimerSource(queue: queue)
        subscribeTimer?.schedule(deadline: .now() + 0.5, repeating: 2.0)
        subscribeTimer?.setEventHandler { [weak self] in
            Task { await self?.sendSubscribeMessage() }
        }
        subscribeTimer?.resume()
    }

    private func sendSubscribeMessage() {
        guard let data = "SUBSCRIBE".data(using: .utf8) else { return }
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func sendConfigRequest() {
        guard let config = requestedConfig, let conn = connection else { return }
        let msg = ConfigMessage(type: .update, config: config)
        conn.send(content: msg.serialize(), completion: .idempotent)
        netLog("[UDPClient] Sent config request: \(config.width)x\(config.height) \(config.codec) \(config.bitrate/1_000_000)Mbps k=\(config.keyframeInterval)")
    }

    /// Request a config change from server
    public func requestConfigChange(_ config: StreamConfigData) {
        guard let conn = connection else { return }
        requestedConfig = config
        let msg = ConfigMessage(type: .update, config: config)
        conn.send(content: msg.serialize(), completion: .idempotent)
        netLog("[UDPClient] Requested config change: \(config.width)x\(config.height) \(config.codec)")
    }

    private func startReceiving() {
        guard let conn = connection else { return }
        receiveLoop(on: conn)
    }

    private nonisolated func receiveLoop(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self = self else { return }

            if let error = error {
                netLog("[UDPClient] Receive error: \(error)")
                return
            }

            if let data = content {
                Task {
                    await self.processReceivedData(data)
                }
            }

            // Continue receiving
            self.receiveLoop(on: connection)
        }
    }

    // FEC recovery statistics
    private var fecRecoveredFrames: UInt64 = 0
    private var fecUnrecoverableFrames: UInt64 = 0
    private var lastFecLogTime: UInt64 = 0

    // Adaptive bitrate state
    private var adaptiveBitrateEnabled = true
    private var lastBitrateAdjustTime: UInt64 = 0
    private var lastLossRateForAdjust: Double = 0
    private var originalBitrate: Int = 0
    private var currentBitrate: Int = 0
    private var originalKeyframeInterval: Int = 0
    private var currentKeyframeInterval: Int = 0
    private let bitrateAdjustIntervalNs: UInt64 = 3_000_000_000  // 3 seconds
    private let lossThresholdHigh: Double = 0.10  // 10% loss = reduce bitrate
    private let lossThresholdLow: Double = 0.02   // 2% loss = increase bitrate

    private func processReceivedData(_ data: Data) async {
        // First, check if this is a config message
        if ConfigMessage.isConfigMessage(data) {
            if let configMsg = ConfigMessage.deserialize(from: data) {
                handleConfigMessage(configMsg)
            }
            return
        }

        // Check if this is an input event (e.g., releaseCapture from host)
        // InputEvent magic is 0x53484950 ("SHIP") at the start
        if data.count >= 4 {
            let magic = data.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(as: UInt32.self).bigEndian
            }
            if magic == InputEvent.magic {
                if let inputEvent = InputEvent.deserialize(from: data) {
                    inputEventHandler?(inputEvent)
                }
                return
            }
        }

        guard let fragment = NetworkPacket.deserialize(from: data) else {
            return
        }

        let frameId = fragment.frameId
        let nowNs = DispatchTime.now().uptimeNanoseconds

        if pendingFragments[frameId] == nil {
            pendingFragments[frameId] = PendingFrame(
                fragments: [],
                firstSeenNs: nowNs,
                lastUpdatedNs: nowNs
            )
        }
        pendingFragments[frameId]?.fragments.append(fragment)
        pendingFragments[frameId]?.lastUpdatedNs = nowNs

        if let entry = pendingFragments[frameId] {
            let fragments = entry.fragments
            let currentCount = fragments.count
            let totalNeeded = Int(fragment.totalFragments)
            let dataNeeded = Int(fragment.dataFragmentCount)
            let dataCount = fragments.filter { !$0.isParity }.count

            // Try to reassemble when we have all data OR enough fragments for FEC recovery
            let shouldAttempt = dataCount == dataNeeded || currentCount >= dataNeeded
            let hadAllData = dataCount == dataNeeded

            if shouldAttempt, let packet = packetProtocol.reassemble(fragments: fragments) {
                // Track FEC recovery: if we didn't have all data but still got a packet, FEC helped
                if !hadAllData {
                    fecRecoveredFrames += 1
                    if fecRecoveredFrames <= 3 {
                        netLog("[FEC] Recovered frame \(frameId) using parity (total recovered: \(fecRecoveredFrames))")
                    }
                }

                // Log keyframes
                if packet.isKeyframe {
                    netLog("[UDPClient] KEYFRAME received: frame \(frameId), \(packet.data.count) bytes")
                }
                continuation?.yield(packet)
                pendingFragments.removeValue(forKey: frameId)
            } else if currentCount == totalNeeded {
                // Reassembly failed even with all fragments
                fecUnrecoverableFrames += 1
                pendingFragments.removeValue(forKey: frameId)
            }
        }

        // Cleanup old fragments (frames where we never got enough fragments)
        let timeoutNs = UInt64(fragmentTimeout * 1_000_000_000)
        let expired = pendingFragments.filter { nowNs - $0.value.firstSeenNs > timeoutNs }
        for key in expired.keys {
            pendingFragments.removeValue(forKey: key)
            fecUnrecoverableFrames += 1
        }

        // Keep only the last 50 frame IDs to prevent memory growth
        if pendingFragments.count > 50 {
            let sortedKeys = pendingFragments.keys.sorted()
            let keysToRemove = sortedKeys.prefix(pendingFragments.count - 50)
            for key in keysToRemove {
                pendingFragments.removeValue(forKey: key)
                fecUnrecoverableFrames += 1
            }
        }

        // Periodic FEC stats (every 5 seconds)
        if nowNs - lastFecLogTime > 5_000_000_000 {
            lastFecLogTime = nowNs
            if fecRecoveredFrames > 0 || fecUnrecoverableFrames > 0 {
                netLog("[FEC Stats] Recovered: \(fecRecoveredFrames) frames, Lost: \(fecUnrecoverableFrames) frames")
            }
        }

        // Adaptive bitrate check (every 3 seconds)
        await checkAdaptiveBitrate(nowNs: nowNs)
    }

    private func checkAdaptiveBitrate(nowNs: UInt64) async {
        guard adaptiveBitrateEnabled,
              nowNs - lastBitrateAdjustTime > bitrateAdjustIntervalNs,
              let config = requestedConfig else {
            return
        }

        // Initialize tracking on first run
        if originalBitrate == 0 {
            originalBitrate = config.bitrate
            currentBitrate = config.bitrate
            originalKeyframeInterval = config.keyframeInterval
            currentKeyframeInterval = config.keyframeInterval
        }

        lastBitrateAdjustTime = nowNs

        // Calculate loss rate
        let totalFrames = fecRecoveredFrames + fecUnrecoverableFrames
        guard totalFrames > 30 else { return }  // Need enough samples

        let lossRate = Double(fecUnrecoverableFrames) / Double(totalFrames)

        // Reset stats for next interval
        fecRecoveredFrames = 0
        fecUnrecoverableFrames = 0

        // Adjust bitrate and keyframe interval based on loss
        var newBitrate = currentBitrate
        var newKeyframeInterval = currentKeyframeInterval
        var configChanged = false

        if lossRate > lossThresholdHigh {
            // High loss - reduce bitrate by 25%
            newBitrate = max(5_000_000, Int(Double(currentBitrate) * 0.75))
            // Also reduce keyframe interval to repair artifacts faster (minimum 10 frames = ~0.16s at 60fps)
            newKeyframeInterval = max(10, currentKeyframeInterval / 2)

            if newBitrate != currentBitrate || newKeyframeInterval != currentKeyframeInterval {
                netLog("[AdaptiveBitrate] Loss \(String(format: "%.1f", lossRate * 100))%% - bitrate: \(currentBitrate/1_000_000)->\(newBitrate/1_000_000)Mbps, keyframe: \(currentKeyframeInterval)->\(newKeyframeInterval)")
                configChanged = true
            }
        } else if lossRate < lossThresholdLow {
            // Low loss - try to increase back towards original
            if currentBitrate < originalBitrate {
                newBitrate = min(originalBitrate, Int(Double(currentBitrate) * 1.10))
            }
            if currentKeyframeInterval < originalKeyframeInterval {
                newKeyframeInterval = min(originalKeyframeInterval, currentKeyframeInterval + 5)
            }

            if newBitrate != currentBitrate || newKeyframeInterval != currentKeyframeInterval {
                netLog("[AdaptiveBitrate] Loss \(String(format: "%.1f", lossRate * 100))%% - bitrate: \(currentBitrate/1_000_000)->\(newBitrate/1_000_000)Mbps, keyframe: \(currentKeyframeInterval)->\(newKeyframeInterval)")
                configChanged = true
            }
        }

        if configChanged {
            currentBitrate = newBitrate
            currentKeyframeInterval = newKeyframeInterval

            // Request new config from server
            let newConfig = StreamConfigData(
                width: config.width,
                height: config.height,
                fps: config.fps,
                codec: config.codec,
                bitrate: newBitrate,
                keyframeInterval: newKeyframeInterval,
                fullColorMode: config.fullColorMode,
                useNativeResolution: config.useNativeResolution,
                maxPacketSize: config.maxPacketSize
            )
            requestedConfig = newConfig
            sendConfigRequest()
        }
    }

    public func stop() async {
        subscribeTimer?.cancel()
        subscribeTimer = nil
        connection?.cancel()
        connection = nil
        isActive = false
        continuation?.finish()
    }

    public func getPackets() -> AsyncStream<EncodedPacket> {
        _packets
    }

    /// Track first input send for logging
    private static var hasLoggedFirstInput = false

    /// Send an input event to the server
    public func sendInputEvent(_ event: InputEvent) {
        guard isActive, let connection = connection else {
            netLog("[UDPClient] Cannot send input: isActive=\(isActive), connection=\(connection != nil)")
            return
        }
        let data = event.serialize()

        // Log first input event and all non-move events
        if !Self.hasLoggedFirstInput {
            netLog("[UDPClient] First input event: \(event.type), data size=\(data.count), magic=\(String(format: "0x%08X", InputEvent.magic))")
            let preview = data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            netLog("[UDPClient] Data preview: \(preview)")
            Self.hasLoggedFirstInput = true
        } else if event.type != .mouseMove {
            netLog("[UDPClient] Sending input: \(event.type)")
        }

        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                netLog("[UDPClient] Input send error: \(error)")
            }
        })
    }

    private func handleConfigMessage(_ msg: ConfigMessage) {
        switch msg.type {
        case .response, .ack:
            serverConfig = msg.config
            netLog("[UDPClient] Server config: \(msg.config.width)x\(msg.config.height) \(msg.config.codec) \(msg.config.bitrate/1_000_000)Mbps k=\(msg.config.keyframeInterval)")
            if let nativeW = msg.config.serverNativeWidth, let nativeH = msg.config.serverNativeHeight {
                netLog("[UDPClient] Server display: native \(nativeW)x\(nativeH)")
            }
            configHandler?(msg.config)

        default:
            break
        }
    }
}

// MARK: - Separate UDP input channel (recommended)

/// UDP server that receives only input events and sends optional responses
public actor UDPInputServer {
    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.screenhero.udpinputserver", qos: .userInteractive)
    private var connections: [String: NWConnection] = [:]
    private var inputEventHandler: ((InputEvent) -> InputEvent?)?

    public private(set) var isActive = false

    public init(port: UInt16) {
        self.port = port
    }

    public func setInputEventHandler(_ handler: @escaping (InputEvent) -> InputEvent?) {
        inputEventHandler = handler
        netLog("[UDPInputServer] Input event handler SET")
    }

    public func start() async throws {
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
                    await self.handleListenerState(state, continuation: cont)
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                Task {
                    await self.handleNewConnection(connection)
                }
            }

            listener?.start(queue: queue)
        }
    }

    private func handleNewConnection(_ connection: NWConnection) async {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            Task {
                await self.handleConnectionState(state, connection: connection)
            }
        }
        connection.start(queue: queue)
    }

    private nonisolated func receiveOnConnection(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self = self else { return }

            if let data = content, data.count >= 4 {
                let magic = UInt32(data[data.startIndex]) << 24 |
                            UInt32(data[data.startIndex + 1]) << 16 |
                            UInt32(data[data.startIndex + 2]) << 8 |
                            UInt32(data[data.startIndex + 3])
                if magic == InputEvent.magic, let inputEvent = InputEvent.deserialize(from: data) {
                    Task {
                        await self.handleInputEvent(inputEvent, from: connection)
                    }
                }
            }

            if error == nil {
                self.receiveOnConnection(connection)
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State, continuation: CheckedContinuation<Void, Error>) async {
        switch state {
        case .ready:
            netLog("[UDPInputServer] Listening on port \(port)")
            isActive = true
            continuation.resume()
        case .failed(let error):
            netLog("[UDPInputServer] Failed: \(error)")
            isActive = false
            continuation.resume(throwing: NetworkTransportError.connectionFailed(error.localizedDescription))
        case .cancelled:
            isActive = false
        default:
            break
        }
    }

    private func handleConnectionState(_ state: NWConnection.State, connection: NWConnection) async {
        switch state {
        case .ready:
            if let endpoint = connection.currentPath?.remoteEndpoint,
               case .hostPort(let host, let port) = endpoint {
                let id = "\(host):\(port)"
                connections[id] = connection
                netLog("[UDPInputServer] Connection ready from \(id)")
            }
            receiveOnConnection(connection)
        case .failed(let error):
            netLog("[UDPInputServer] Connection failed: \(error)")
        case .cancelled:
            if let endpoint = connection.currentPath?.remoteEndpoint,
               case .hostPort(let host, let port) = endpoint {
                let id = "\(host):\(port)"
                connections.removeValue(forKey: id)
            }
        default:
            break
        }
    }

    private func handleInputEvent(_ event: InputEvent, from connection: NWConnection) async {
        netLog("[UDPInputServer] INPUT RECEIVED: \(event.type)")
        if let response = inputEventHandler?(event) {
            let responseData = response.serialize()
            connection.send(content: responseData, completion: .idempotent)
        }
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
        for (_, conn) in connections {
            conn.cancel()
        }
        connections.removeAll()
        isActive = false
    }
}

/// UDP client that sends input events and receives optional responses
public actor UDPInputClient {
    private let serverHost: String
    private let serverPort: UInt16
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.screenhero.udpinputclient", qos: .userInteractive)
    private var inputEventHandler: ((InputEvent) -> Void)?

    public private(set) var isActive = false

    public init(serverHost: String, serverPort: UInt16) {
        self.serverHost = serverHost
        self.serverPort = serverPort
    }

    public func setInputEventHandler(_ handler: @escaping (InputEvent) -> Void) {
        inputEventHandler = handler
    }

    public func start() async throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        connection = NWConnection(
            host: NWEndpoint.Host(serverHost),
            port: NWEndpoint.Port(rawValue: serverPort)!,
            using: params
        )

        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            Task {
                await self.handleState(state)
            }
        }

        connection?.start(queue: queue)
    }

    private func startReceiving() {
        guard let conn = connection else { return }
        receiveLoop(on: conn)
    }

    private nonisolated func receiveLoop(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self = self else { return }

            if let data = content, data.count >= 4 {
                let magic = UInt32(data[data.startIndex]) << 24 |
                            UInt32(data[data.startIndex + 1]) << 16 |
                            UInt32(data[data.startIndex + 2]) << 8 |
                            UInt32(data[data.startIndex + 3])
                if magic == InputEvent.magic, let inputEvent = InputEvent.deserialize(from: data) {
                    Task { await self.handleIncomingEvent(inputEvent) }
                }
            }

            if error == nil {
                self.receiveLoop(on: connection)
            }
        }
    }

    public func sendInputEvent(_ event: InputEvent) {
        guard isActive, let connection = connection else {
            netLog("[UDPInputClient] Cannot send input: isActive=\(isActive), connection=\(connection != nil)")
            return
        }
        connection.send(content: event.serialize(), completion: .idempotent)
    }

    private func handleState(_ state: NWConnection.State) async {
        switch state {
        case .ready:
            isActive = true
            startReceiving()
            netLog("[UDPInputClient] Connected to \(serverHost):\(serverPort)")
        case .failed, .cancelled:
            isActive = false
        default:
            break
        }
    }

    private func handleIncomingEvent(_ event: InputEvent) async {
        inputEventHandler?(event)
    }

    public func stop() async {
        connection?.cancel()
        connection = nil
        isActive = false
    }
}
