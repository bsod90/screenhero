import Foundation

/// An encoded video packet ready for transmission
public struct EncodedPacket: Sendable {
    /// Unique frame identifier
    public let frameId: UInt64

    /// Encoded data
    public let data: Data

    /// Presentation timestamp in nanoseconds
    public let presentationTimeNs: UInt64

    /// Whether this is a keyframe (I-frame)
    public let isKeyframe: Bool

    /// Codec used for encoding
    public let codec: VideoCodec

    /// Frame dimensions
    public let width: Int
    public let height: Int

    /// Capture timestamp for latency measurement (nanoseconds since boot)
    public let captureTimestamp: UInt64

    /// Encode timestamp for latency measurement
    public let encodeTimestamp: UInt64

    /// Codec-specific data (SPS/PPS for H.264, VPS/SPS/PPS for HEVC)
    public let parameterSets: Data?

    public init(
        frameId: UInt64,
        data: Data,
        presentationTimeNs: UInt64,
        isKeyframe: Bool,
        codec: VideoCodec,
        width: Int,
        height: Int,
        captureTimestamp: UInt64,
        encodeTimestamp: UInt64,
        parameterSets: Data? = nil
    ) {
        self.frameId = frameId
        self.data = data
        self.presentationTimeNs = presentationTimeNs
        self.isKeyframe = isKeyframe
        self.codec = codec
        self.width = width
        self.height = height
        self.captureTimestamp = captureTimestamp
        self.encodeTimestamp = encodeTimestamp
        self.parameterSets = parameterSets
    }
}

/// Supported video codecs
public enum VideoCodec: String, Sendable, Codable {
    case h264 = "h264"
    case hevc = "hevc"
    case passthrough = "passthrough"
}
