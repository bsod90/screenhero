import Foundation
import CoreGraphics

/// Represents a JPEG-compressed region update (tile) for bandwidth optimization
/// Used when only a small portion of the screen has changed
public struct TileUpdate: Sendable {
    /// Magic bytes for tile update packets: "SHTL" (ScreenHero TiLe)
    public static let magic: UInt32 = 0x5348544C

    /// Frame ID this tile belongs to
    public let frameId: UInt64

    /// Position of the tile in the full frame (top-left corner)
    public let x: Int
    public let y: Int

    /// Size of the tile
    public let width: Int
    public let height: Int

    /// JPEG-compressed tile data
    public let jpegData: Data

    /// Capture timestamp for latency tracking
    public let captureTimestamp: UInt64

    /// Full frame dimensions (for viewer to know the coordinate space)
    public let fullWidth: Int
    public let fullHeight: Int

    public init(
        frameId: UInt64,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        jpegData: Data,
        captureTimestamp: UInt64,
        fullWidth: Int,
        fullHeight: Int
    ) {
        self.frameId = frameId
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.jpegData = jpegData
        self.captureTimestamp = captureTimestamp
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
    }

    /// Serialize to network data
    /// Format:
    /// - Magic (4 bytes): 0x5348544C
    /// - Frame ID (8 bytes)
    /// - X position (4 bytes)
    /// - Y position (4 bytes)
    /// - Width (4 bytes)
    /// - Height (4 bytes)
    /// - Full width (4 bytes)
    /// - Full height (4 bytes)
    /// - Capture timestamp (8 bytes)
    /// - JPEG data length (4 bytes)
    /// - JPEG data (variable)
    public func serialize() -> Data {
        var data = Data()
        data.reserveCapacity(48 + jpegData.count)

        // Magic
        var magic = Self.magic.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &magic) { Array($0) })

        // Frame ID
        var fid = frameId.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &fid) { Array($0) })

        // Position and size
        var xBE = UInt32(x).bigEndian
        var yBE = UInt32(y).bigEndian
        var wBE = UInt32(width).bigEndian
        var hBE = UInt32(height).bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &xBE) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: &yBE) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: &wBE) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: &hBE) { Array($0) })

        // Full frame dimensions
        var fwBE = UInt32(fullWidth).bigEndian
        var fhBE = UInt32(fullHeight).bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &fwBE) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: &fhBE) { Array($0) })

        // Capture timestamp
        var ts = captureTimestamp.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &ts) { Array($0) })

        // JPEG data length and data
        var jpegLen = UInt32(jpegData.count).bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &jpegLen) { Array($0) })
        data.append(jpegData)

        return data
    }

    /// Deserialize from network data
    public static func deserialize(from data: Data) -> TileUpdate? {
        guard data.count >= 48 else { return nil }

        return data.withUnsafeBytes { ptr -> TileUpdate? in
            // Check magic
            let magic = ptr.load(fromByteOffset: 0, as: UInt32.self).bigEndian
            guard magic == Self.magic else { return nil }

            let frameId = ptr.load(fromByteOffset: 4, as: UInt64.self).bigEndian
            let x = Int(ptr.load(fromByteOffset: 12, as: UInt32.self).bigEndian)
            let y = Int(ptr.load(fromByteOffset: 16, as: UInt32.self).bigEndian)
            let width = Int(ptr.load(fromByteOffset: 20, as: UInt32.self).bigEndian)
            let height = Int(ptr.load(fromByteOffset: 24, as: UInt32.self).bigEndian)
            let fullWidth = Int(ptr.load(fromByteOffset: 28, as: UInt32.self).bigEndian)
            let fullHeight = Int(ptr.load(fromByteOffset: 32, as: UInt32.self).bigEndian)
            let captureTimestamp = ptr.load(fromByteOffset: 36, as: UInt64.self).bigEndian
            let jpegLen = Int(ptr.load(fromByteOffset: 44, as: UInt32.self).bigEndian)

            guard data.count >= 48 + jpegLen else { return nil }

            let jpegData = data.subdata(in: 48..<(48 + jpegLen))

            return TileUpdate(
                frameId: frameId,
                x: x,
                y: y,
                width: width,
                height: height,
                jpegData: jpegData,
                captureTimestamp: captureTimestamp,
                fullWidth: fullWidth,
                fullHeight: fullHeight
            )
        }
    }

    /// Check if data starts with tile update magic
    public static func isTileUpdate(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let magic = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(as: UInt32.self).bigEndian
        }
        return magic == Self.magic
    }
}

/// Result of analyzing dirty rects to determine encoding strategy
public struct DirtyRectAnalysis: Sendable {
    /// Bounding box of all dirty rects
    public let boundingBox: CGRect

    /// Total area covered by dirty rects
    public let dirtyArea: CGFloat

    /// Percentage of frame that is dirty (0.0 - 1.0)
    public let dirtyPercentage: CGFloat

    /// Whether to use tile updates vs full frame encoding
    public let useTileEncoding: Bool

    /// Individual dirty regions (merged and expanded for encoding efficiency)
    public let regions: [CGRect]

    public init(
        boundingBox: CGRect,
        dirtyArea: CGFloat,
        dirtyPercentage: CGFloat,
        useTileEncoding: Bool,
        regions: [CGRect]
    ) {
        self.boundingBox = boundingBox
        self.dirtyArea = dirtyArea
        self.dirtyPercentage = dirtyPercentage
        self.useTileEncoding = useTileEncoding
        self.regions = regions
    }
}
