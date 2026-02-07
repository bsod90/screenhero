import Foundation

/// In-process loopback transport for testing
/// Connects a sender and receiver without actual network I/O
public final class LoopbackTransport: Sendable {
    private let channel = LoopbackChannel()

    public init() {}

    /// The sender side of the loopback
    public var senderSide: LoopbackSender {
        LoopbackSender(channel: channel)
    }

    /// The receiver side of the loopback
    public var receiverSide: LoopbackReceiver {
        LoopbackReceiver(channel: channel)
    }
}

/// Thread-safe channel for passing packets between sender and receiver
public actor LoopbackChannel {
    private var continuation: AsyncStream<EncodedPacket>.Continuation?
    private var isActive = false
    private var packetStream: AsyncStream<EncodedPacket>?

    /// Simulated network latency in nanoseconds
    public var simulatedLatencyNs: UInt64 = 0

    /// Simulated packet loss rate (0.0 - 1.0)
    public var packetLossRate: Double = 0.0

    func getPackets() -> AsyncStream<EncodedPacket> {
        if let existing = packetStream {
            return existing
        }
        let stream = AsyncStream<EncodedPacket> { continuation in
            self.continuation = continuation
        }
        packetStream = stream
        return stream
    }

    func send(_ packet: EncodedPacket) async throws {
        guard isActive else {
            throw NetworkTransportError.notConnected
        }

        // Simulate packet loss
        if packetLossRate > 0 && Double.random(in: 0..<1) < packetLossRate {
            return
        }

        // Simulate latency
        if simulatedLatencyNs > 0 {
            try? await Task.sleep(nanoseconds: simulatedLatencyNs)
        }

        continuation?.yield(packet)
    }

    func start() {
        isActive = true
        // Trigger stream creation if needed
        _ = getPackets()
    }

    func stop() {
        isActive = false
        continuation?.finish()
        continuation = nil
        packetStream = nil
    }
}

/// Sender side of the loopback transport
public actor LoopbackSender: NetworkSender {
    private let channel: LoopbackChannel
    public private(set) var isActive = false

    init(channel: LoopbackChannel) {
        self.channel = channel
    }

    public func send(_ packet: EncodedPacket) async throws {
        try await channel.send(packet)
    }

    public func start() async throws {
        await channel.start()
        isActive = true
    }

    public func stop() async {
        await channel.stop()
        isActive = false
    }
}

/// Receiver side of the loopback transport
public actor LoopbackReceiver: NetworkReceiver {
    private let channel: LoopbackChannel
    public private(set) var isActive = false
    private var cachedStream: AsyncStream<EncodedPacket>?

    init(channel: LoopbackChannel) {
        self.channel = channel
    }

    public nonisolated var packets: AsyncStream<EncodedPacket> {
        // Return an empty stream - callers should use getPackets() after start()
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    public func start() async throws {
        cachedStream = await channel.getPackets()
        isActive = true
    }

    public func stop() async {
        isActive = false
        cachedStream = nil
    }

    /// Get packets stream (must call start first)
    public func getPackets() async -> AsyncStream<EncodedPacket> {
        if let cached = cachedStream {
            return cached
        }
        return await channel.getPackets()
    }
}
