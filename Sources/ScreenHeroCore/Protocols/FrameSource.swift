import CoreMedia
import Foundation

/// Protocol for frame sources (screen capture, synthetic patterns, etc.)
public protocol FrameSource: Actor {
    /// Async stream of captured frames
    var frames: AsyncStream<CMSampleBuffer> { get }

    /// Start capturing frames
    func start() async throws

    /// Stop capturing frames
    func stop() async

    /// Current configuration
    var config: StreamConfig { get }
}
