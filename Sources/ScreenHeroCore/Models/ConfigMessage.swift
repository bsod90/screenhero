import Foundation

/// Configuration message for client-server config exchange
/// Magic: "SHCF" (ScreenHero ConFig)
public struct ConfigMessage: Sendable, Codable {
    public static let magic: UInt32 = 0x53484346  // "SHCF"

    /// Message types
    public enum MessageType: UInt8, Sendable, Codable {
        case request = 1      // Client requests current config
        case response = 2     // Server sends current config
        case update = 3       // Client wants to change config
        case ack = 4          // Server acknowledges config change
    }

    public let type: MessageType
    public let config: StreamConfigData

    public init(type: MessageType, config: StreamConfigData) {
        self.type = type
        self.config = config
    }

    /// Serialize to network data
    public func serialize() -> Data {
        var data = Data()

        // Magic (4 bytes)
        var magic = Self.magic.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &magic) { Array($0) })

        // Type (1 byte)
        data.append(type.rawValue)

        // Config as JSON
        if let jsonData = try? JSONEncoder().encode(config) {
            // Length (4 bytes)
            var length = UInt32(jsonData.count).bigEndian
            data.append(contentsOf: withUnsafeBytes(of: &length) { Array($0) })

            // JSON data
            data.append(jsonData)
        }

        return data
    }

    /// Deserialize from network data
    public static func deserialize(from data: Data) -> ConfigMessage? {
        guard data.count >= 9 else { return nil }  // magic(4) + type(1) + length(4)

        // Check magic
        let magic = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(as: UInt32.self).bigEndian
        }
        guard magic == Self.magic else { return nil }

        // Read type
        guard let type = MessageType(rawValue: data[4]) else { return nil }

        // Read length
        let length = data.subdata(in: 5..<9).withUnsafeBytes { ptr -> UInt32 in
            ptr.load(as: UInt32.self).bigEndian
        }

        guard data.count >= 9 + Int(length) else { return nil }

        // Parse JSON
        let jsonData = data.subdata(in: 9..<(9 + Int(length)))
        guard let config = try? JSONDecoder().decode(StreamConfigData.self, from: jsonData) else {
            return nil
        }

        return ConfigMessage(type: type, config: config)
    }

    /// Check if data starts with config message magic
    public static func isConfigMessage(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let magic = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(as: UInt32.self).bigEndian
        }
        return magic == Self.magic
    }
}

/// Serializable stream configuration data
public struct StreamConfigData: Sendable, Codable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var codec: String  // "h264" or "hevc"
    public var bitrate: Int   // bits per second
    public var keyframeInterval: Int
    public var fullColorMode: Bool
    public var useNativeResolution: Bool

    // Display info from server
    public var serverDisplayWidth: Int?
    public var serverDisplayHeight: Int?
    public var serverNativeWidth: Int?
    public var serverNativeHeight: Int?

    public init(
        width: Int = 1920,
        height: Int = 1080,
        fps: Int = 60,
        codec: String = "h264",
        bitrate: Int = 20_000_000,
        keyframeInterval: Int = 30,
        fullColorMode: Bool = false,
        useNativeResolution: Bool = false,
        serverDisplayWidth: Int? = nil,
        serverDisplayHeight: Int? = nil,
        serverNativeWidth: Int? = nil,
        serverNativeHeight: Int? = nil
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
        self.bitrate = bitrate
        self.keyframeInterval = keyframeInterval
        self.fullColorMode = fullColorMode
        self.useNativeResolution = useNativeResolution
        self.serverDisplayWidth = serverDisplayWidth
        self.serverDisplayHeight = serverDisplayHeight
        self.serverNativeWidth = serverNativeWidth
        self.serverNativeHeight = serverNativeHeight
    }

    /// Convert to StreamConfig
    public func toStreamConfig() -> StreamConfig {
        StreamConfig(
            width: width,
            height: height,
            fps: fps,
            codec: codec == "hevc" ? .hevc : .h264,
            bitrate: bitrate,
            keyframeInterval: keyframeInterval,
            lowLatencyMode: true,
            fullColorMode: fullColorMode
        )
    }

    /// Create from StreamConfig
    public static func from(_ config: StreamConfig) -> StreamConfigData {
        StreamConfigData(
            width: config.width,
            height: config.height,
            fps: config.fps,
            codec: config.codec == .hevc ? "hevc" : "h264",
            bitrate: config.bitrate,
            keyframeInterval: config.keyframeInterval,
            fullColorMode: config.fullColorMode
        )
    }
}
