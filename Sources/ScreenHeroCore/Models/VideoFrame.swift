import CoreMedia
import Foundation

/// Metadata for a video frame
public struct VideoFrame: Sendable {
    /// Unique identifier for this frame
    public let id: UInt64

    /// Presentation timestamp
    public let presentationTime: CMTime

    /// Frame duration
    public let duration: CMTime

    /// Frame dimensions
    public let width: Int
    public let height: Int

    /// Whether this is a keyframe
    public let isKeyframe: Bool

    /// Capture timestamp (for latency measurement)
    public let captureTimestamp: UInt64

    public init(
        id: UInt64,
        presentationTime: CMTime,
        duration: CMTime,
        width: Int,
        height: Int,
        isKeyframe: Bool,
        captureTimestamp: UInt64
    ) {
        self.id = id
        self.presentationTime = presentationTime
        self.duration = duration
        self.width = width
        self.height = height
        self.isKeyframe = isKeyframe
        self.captureTimestamp = captureTimestamp
    }
}
