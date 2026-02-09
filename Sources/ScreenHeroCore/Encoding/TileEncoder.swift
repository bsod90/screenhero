import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Encodes dirty regions of a frame as JPEG tiles for bandwidth optimization
/// Used when only a small portion of the screen has changed
public class TileEncoder {
    /// Threshold for using tile encoding (percentage of frame that changed)
    /// Below this threshold, we use JPEG tiles instead of full H.264 frame
    public var tileThreshold: CGFloat = 0.15  // 15% of screen

    /// Minimum tile size (too small tiles have overhead issues)
    public let minTileSize: Int = 64

    /// JPEG compression quality (0.0 - 1.0)
    public var jpegQuality: CGFloat = 0.85

    /// Frame counter for tile updates
    private var frameCount: UInt64 = 0

    /// Stats
    private var tilesEncoded: UInt64 = 0
    private var bytesEncoded: UInt64 = 0
    private var lastStatsTime: UInt64 = 0

    public init() {}

    /// Analyze dirty rects to determine encoding strategy
    public func analyzeDirtyRects(
        _ rects: [CGRect],
        frameWidth: Int,
        frameHeight: Int
    ) -> DirtyRectAnalysis {
        let frameArea = CGFloat(frameWidth * frameHeight)

        guard !rects.isEmpty else {
            return DirtyRectAnalysis(
                boundingBox: .zero,
                dirtyArea: 0,
                dirtyPercentage: 0,
                useTileEncoding: false,
                regions: []
            )
        }

        // Calculate bounding box and total dirty area
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = CGFloat.leastNormalMagnitude
        var maxY = CGFloat.leastNormalMagnitude
        var totalArea: CGFloat = 0

        for rect in rects {
            minX = min(minX, rect.minX)
            minY = min(minY, rect.minY)
            maxX = max(maxX, rect.maxX)
            maxY = max(maxY, rect.maxY)
            totalArea += rect.width * rect.height
        }

        let boundingBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let dirtyPercentage = totalArea / frameArea

        // Merge overlapping/adjacent rects and expand to multiples of 16 (macroblock size)
        let mergedRegions = mergeAndExpandRects(rects, frameWidth: frameWidth, frameHeight: frameHeight)

        // Use tile encoding if dirty area is below threshold and regions are reasonable
        let useTileEncoding = dirtyPercentage < tileThreshold &&
                             mergedRegions.count <= 8 &&  // Don't use tiles if too many regions
                             boundingBox.width >= CGFloat(minTileSize) &&
                             boundingBox.height >= CGFloat(minTileSize)

        return DirtyRectAnalysis(
            boundingBox: boundingBox,
            dirtyArea: totalArea,
            dirtyPercentage: dirtyPercentage,
            useTileEncoding: useTileEncoding,
            regions: mergedRegions
        )
    }

    /// Merge overlapping rects and expand to 16-pixel boundaries
    private func mergeAndExpandRects(
        _ rects: [CGRect],
        frameWidth: Int,
        frameHeight: Int
    ) -> [CGRect] {
        guard !rects.isEmpty else { return [] }

        // Expand each rect to 16-pixel boundaries
        var expanded = rects.map { rect -> CGRect in
            let x = max(0, Int(rect.minX) / 16 * 16)
            let y = max(0, Int(rect.minY) / 16 * 16)
            let maxX = min(frameWidth, (Int(rect.maxX) + 15) / 16 * 16)
            let maxY = min(frameHeight, (Int(rect.maxY) + 15) / 16 * 16)
            return CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
        }

        // Simple merge: combine overlapping rects
        var merged: [CGRect] = []
        for rect in expanded {
            var didMerge = false
            for i in 0..<merged.count {
                if merged[i].intersects(rect) || merged[i].insetBy(dx: -16, dy: -16).intersects(rect) {
                    merged[i] = merged[i].union(rect)
                    didMerge = true
                    break
                }
            }
            if !didMerge {
                merged.append(rect)
            }
        }

        return merged
    }

    /// Encode dirty regions as JPEG tiles
    /// Returns nil if tile encoding is not beneficial
    public func encodeTiles(
        from sampleBuffer: CMSampleBuffer,
        analysis: DirtyRectAnalysis
    ) -> [TileUpdate]? {
        guard analysis.useTileEncoding,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let captureTimestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let currentFrameId = frameCount
        frameCount += 1

        var tiles: [TileUpdate] = []

        for region in analysis.regions {
            // Ensure region is within bounds
            let x = max(0, min(width - 1, Int(region.minX)))
            let y = max(0, min(height - 1, Int(region.minY)))
            let w = min(width - x, Int(region.width))
            let h = min(height - y, Int(region.height))

            guard w >= minTileSize && h >= minTileSize else { continue }

            // Extract region and encode as JPEG
            if let jpegData = encodeRegionAsJPEG(
                baseAddress: baseAddress,
                bytesPerRow: bytesPerRow,
                x: x,
                y: y,
                width: w,
                height: h
            ) {
                let tile = TileUpdate(
                    frameId: currentFrameId,
                    x: x,
                    y: y,
                    width: w,
                    height: h,
                    jpegData: jpegData,
                    captureTimestamp: captureTimestamp,
                    fullWidth: width,
                    fullHeight: height
                )
                tiles.append(tile)

                tilesEncoded += 1
                bytesEncoded += UInt64(jpegData.count)
            }
        }

        // Log stats periodically
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastStatsTime > 5_000_000_000 && tilesEncoded > 0 {
            lastStatsTime = now
            let avgSize = bytesEncoded / tilesEncoded
            print("[TileEncoder] Encoded \(tilesEncoded) tiles, avg size: \(avgSize) bytes")
        }

        return tiles.isEmpty ? nil : tiles
    }

    /// Extract a region from the pixel buffer and encode as JPEG
    private func encodeRegionAsJPEG(
        baseAddress: UnsafeMutableRawPointer,
        bytesPerRow: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> Data? {
        // Create a CGImage from the region
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitsPerComponent = 8
        let bitsPerPixel = 32

        // Calculate offset to the region start
        let regionBytesPerRow = width * 4
        var regionData = Data(capacity: regionBytesPerRow * height)

        // Copy rows from the source
        let srcPtr = baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let srcOffset = (y + row) * bytesPerRow + x * 4
            let srcRow = srcPtr.advanced(by: srcOffset)
            regionData.append(srcRow, count: regionBytesPerRow)
        }

        // Create CGImage from region data
        guard let provider = CGDataProvider(data: regionData as CFData) else {
            return nil
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: regionBytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }

        // Encode as JPEG
        let jpegData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            jpegData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ]

        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return jpegData as Data
    }
}
