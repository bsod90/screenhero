import Foundation

/// Protocol for sending encoded packets over the network
public protocol NetworkSender: Actor {
    /// Send an encoded packet
    func send(_ packet: EncodedPacket) async throws

    /// Send tile updates (for partial screen updates)
    /// Default implementation does nothing - override in senders that support tiles
    func sendTiles(_ tiles: [TileUpdate]) async throws

    /// Start the sender
    func start() async throws

    /// Stop the sender
    func stop() async

    /// Whether the sender is currently active
    var isActive: Bool { get }
}

/// Default implementation for sendTiles (no-op for senders that don't support tiles)
public extension NetworkSender {
    func sendTiles(_ tiles: [TileUpdate]) async throws {
        // Default: do nothing
        // Senders that support tile updates should override this
    }
}

/// Protocol for receiving encoded packets from the network
public protocol NetworkReceiver: Actor {
    /// Async stream of received packets
    var packets: AsyncStream<EncodedPacket> { get }

    /// Start receiving packets
    func start() async throws

    /// Stop receiving packets
    func stop() async

    /// Whether the receiver is currently active
    var isActive: Bool { get }
}

/// Errors that can occur during network operations
public enum NetworkTransportError: Error, Sendable {
    case connectionFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
    case notConnected
    case invalidAddress
    case authenticationFailed
    case timeout
}
