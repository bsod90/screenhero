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

    /// Use 4:4:4 chroma subsampling for full color accuracy
    /// When enabled, uses H.264 High 4:4:4 or HEVC RExt profile
    /// This provides sharper text and UI elements but requires more bandwidth
    public let fullColorMode: Bool

    public init(
        width: Int = 1920,
        height: Int = 1080,
        fps: Int = 60,
        codec: VideoCodec = .h264,
        bitrate: Int = 20_000_000,
        keyframeInterval: Int = 60,
        lowLatencyMode: Bool = true,
        maxPacketSize: Int = 1400,
        fullColorMode: Bool = false
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
        self.bitrate = bitrate
        self.keyframeInterval = keyframeInterval
        self.lowLatencyMode = lowLatencyMode
        self.maxPacketSize = maxPacketSize
        self.fullColorMode = fullColorMode
    }

    /// Preset for 1080p60
    public static let hd1080p60 = StreamConfig(
        width: 1920,
        height: 1080,
        fps: 60,
        codec: .h264,
        bitrate: 20_000_000,
        keyframeInterval: 30,  // Keyframe every 0.5 seconds
        lowLatencyMode: true,
        fullColorMode: false
    )

    /// Preset for 4K60 (default for high quality)
    public static let uhd4k60 = StreamConfig(
        width: 3840,
        height: 2160,
        fps: 60,
        codec: .hevc,
        bitrate: 50_000_000,   // 50 Mbps - Apple recommends 75 for 4K
        keyframeInterval: 60,  // Keyframe every second
        lowLatencyMode: true,
        fullColorMode: false
    )

    /// Default preset - matches screen resolution
    public static var `default`: StreamConfig {
        screenShare
    }

    /// Preset for screen sharing (optimized for low latency)
    public static let screenShare = StreamConfig(
        width: 2560,           // 1440p is a good balance
        height: 1440,
        fps: 60,
        codec: .hevc,
        bitrate: 30_000_000,   // 30 Mbps - plenty for 1440p
        keyframeInterval: 30,  // Keyframe every 0.5 seconds
        lowLatencyMode: true,
        fullColorMode: false
    )

    /// Preset for high quality 4K (use on fast networks)
    public static let highQuality4K = StreamConfig(
        width: 3840,
        height: 2160,
        fps: 60,
        codec: .hevc,
        bitrate: 50_000_000,   // 50 Mbps
        keyframeInterval: 30,
        lowLatencyMode: true,
        fullColorMode: false
    )

    /// Preset for full color mode (4:4:4 chroma) - sharper text, higher bandwidth
    public static let fullColor1080p = StreamConfig(
        width: 1920,
        height: 1080,
        fps: 60,
        codec: .h264,
        bitrate: 40_000_000,   // 40 Mbps - 4:4:4 needs ~2x bandwidth
        keyframeInterval: 30,
        lowLatencyMode: true,
        fullColorMode: true
    )

    /// Preset for testing (low bandwidth)
    public static let testing = StreamConfig(
        width: 640,
        height: 480,
        fps: 30,
        codec: .h264,
        bitrate: 2_000_000,
        keyframeInterval: 15,
        lowLatencyMode: true,
        fullColorMode: false
    )
}
