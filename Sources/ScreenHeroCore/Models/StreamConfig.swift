import Foundation

/// Configuration for a video stream
public struct StreamConfig: Sendable, Codable, Equatable {
    /// Video width in pixels
    public let width: Int

    /// Video height in pixels
    public let height: Int

    /// Target frames per second
    public let fps: Int

    /// Video codec to use
    public let codec: VideoCodec

    /// Target bitrate in bits per second
    public let bitrate: Int

    /// Keyframe interval in frames
    public let keyframeInterval: Int

    /// Whether to use low-latency encoding mode
    public let lowLatencyMode: Bool

    /// Maximum packet size for network transmission (MTU consideration)
    public let maxPacketSize: Int

    public init(
        width: Int = 1920,
        height: Int = 1080,
        fps: Int = 60,
        codec: VideoCodec = .h264,
        bitrate: Int = 20_000_000,
        keyframeInterval: Int = 60,
        lowLatencyMode: Bool = true,
        maxPacketSize: Int = 1400
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
        self.bitrate = bitrate
        self.keyframeInterval = keyframeInterval
        self.lowLatencyMode = lowLatencyMode
        self.maxPacketSize = maxPacketSize
    }

    /// Preset for 1080p60
    public static let hd1080p60 = StreamConfig(
        width: 1920,
        height: 1080,
        fps: 60,
        codec: .h264,
        bitrate: 20_000_000,
        keyframeInterval: 30,  // Keyframe every 0.5 seconds
        lowLatencyMode: true
    )

    /// Preset for 4K60 (default for high quality)
    public static let uhd4k60 = StreamConfig(
        width: 3840,
        height: 2160,
        fps: 60,
        codec: .hevc,
        bitrate: 80_000_000,   // 80 Mbps for high quality 4K
        keyframeInterval: 30,  // Keyframe every 0.5 seconds
        lowLatencyMode: true
    )

    /// Default preset - matches screen resolution
    public static var `default`: StreamConfig {
        uhd4k60
    }

    /// Preset for screen sharing (optimized for text clarity)
    public static let screenShare = StreamConfig(
        width: 3840,
        height: 2160,
        fps: 60,
        codec: .hevc,
        bitrate: 100_000_000,  // 100 Mbps for sharp text
        keyframeInterval: 15,  // Keyframe every 0.25 seconds for quick sync
        lowLatencyMode: true
    )

    /// Preset for testing (low bandwidth)
    public static let testing = StreamConfig(
        width: 640,
        height: 480,
        fps: 30,
        codec: .h264,
        bitrate: 2_000_000,
        keyframeInterval: 15,
        lowLatencyMode: true
    )
}
