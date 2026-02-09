import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import ScreenHeroCore

/// Composites JPEG tile updates onto pixel buffers
/// Used to apply partial screen updates to the last decoded full frame
public class TileCompositor {
    /// Pixel buffer pool for efficient buffer allocation
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0

    /// Stats
    private var tilesComposited: UInt64 = 0
    private var lastLogTime: UInt64 = 0

    public init() {}

    /// Composite a tile onto a base pixel buffer
    /// Returns a new pixel buffer with the tile drawn on top
    public func compositeTile(_ tile: TileUpdate, onto baseBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(baseBuffer)
        let height = CVPixelBufferGetHeight(baseBuffer)

        // Get or create output buffer
        guard let outputBuffer = getOutputBuffer(width: width, height: height) else {
            return nil
        }

        // Lock both buffers
        CVPixelBufferLockBaseAddress(baseBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outputBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(baseBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(outputBuffer, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(baseBuffer),
              let dstBase = CVPixelBufferGetBaseAddress(outputBuffer) else {
            return nil
        }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(baseBuffer)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)

        // Copy base frame to output
        if srcBytesPerRow == dstBytesPerRow {
            memcpy(dstBase, srcBase, srcBytesPerRow * height)
        } else {
            // Row-by-row copy if bytes per row differs
            for y in 0..<height {
                let srcRow = srcBase.advanced(by: y * srcBytesPerRow)
                let dstRow = dstBase.advanced(by: y * dstBytesPerRow)
                memcpy(dstRow, srcRow, min(srcBytesPerRow, dstBytesPerRow))
            }
        }

        // Decode JPEG tile
        guard let tileImage = decodeJPEG(tile.jpegData) else {
            return outputBuffer  // Return base frame copy if tile decode fails
        }

        // Draw tile onto output buffer
        drawTile(tileImage, at: (tile.x, tile.y), onto: dstBase, bytesPerRow: dstBytesPerRow, bufferHeight: height)

        tilesComposited += 1

        // Log periodically
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastLogTime > 5_000_000_000 && tilesComposited > 0 {
            lastLogTime = now
            print("[TileCompositor] Composited \(tilesComposited) tiles")
        }

        return outputBuffer
    }

    /// Get or create an output buffer from the pool
    private func getOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        // Create pool if needed or if dimensions changed
        if pixelBufferPool == nil || poolWidth != width || poolHeight != height {
            createPool(width: width, height: height)
        }

        guard let pool = pixelBufferPool else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)

        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    /// Create pixel buffer pool
    private func createPool(width: Int, height: Int) {
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]

        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            nil,
            poolAttributes as CFDictionary,
            bufferAttributes as CFDictionary,
            &pool
        )

        if status == kCVReturnSuccess {
            pixelBufferPool = pool
            poolWidth = width
            poolHeight = height
        }
    }

    /// Decode JPEG data to CGImage
    private func decodeJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Draw a CGImage tile onto a pixel buffer at the specified position
    private func drawTile(_ image: CGImage, at position: (x: Int, y: Int), onto buffer: UnsafeMutableRawPointer, bytesPerRow: Int, bufferHeight: Int) {
        let tileWidth = image.width
        let tileHeight = image.height

        // Create a bitmap context for the tile image
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        // Render tile to temporary buffer
        let tileRowBytes = tileWidth * 4
        var tileData = [UInt8](repeating: 0, count: tileRowBytes * tileHeight)

        guard let context = CGContext(
            data: &tileData,
            width: tileWidth,
            height: tileHeight,
            bitsPerComponent: 8,
            bytesPerRow: tileRowBytes,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return
        }

        // Draw image (flipped because CGContext origin is bottom-left)
        context.draw(image, in: CGRect(x: 0, y: 0, width: tileWidth, height: tileHeight))

        // Copy tile data to output buffer at the correct position
        // Note: Pixel buffer origin is top-left, CGContext drew with origin at bottom-left
        let dstPtr = buffer.assumingMemoryBound(to: UInt8.self)

        for row in 0..<tileHeight {
            let dstY = position.y + row
            guard dstY >= 0 && dstY < bufferHeight else { continue }

            let srcOffset = (tileHeight - 1 - row) * tileRowBytes  // Flip vertically
            let dstOffset = dstY * bytesPerRow + position.x * 4

            let copyWidth = min(tileWidth * 4, bytesPerRow - position.x * 4)
            guard copyWidth > 0 else { continue }

            memcpy(dstPtr.advanced(by: dstOffset), &tileData[srcOffset], copyWidth)
        }
    }
}
