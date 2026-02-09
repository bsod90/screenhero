import CoreGraphics
import Foundation

/// Analyzes images for testing purposes
public struct ImageAnalyzer {

    /// Result of analyzing an image
    public struct AnalysisResult: Sendable {
        public let width: Int
        public let height: Int
        public let isBlack: Bool
        public let isSolidColor: Bool
        public let averageColor: (r: UInt8, g: UInt8, b: UInt8)
        public let colorVariance: Double
        public let hasContent: Bool
    }

    /// Analyze a CGImage to determine if it contains content
    public static func analyze(_ image: CGImage) -> AnalysisResult {
        let width = image.width
        let height = image.height

        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return AnalysisResult(
                width: width,
                height: height,
                isBlack: true,
                isSolidColor: true,
                averageColor: (0, 0, 0),
                colorVariance: 0,
                hasContent: false
            )
        }

        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow

        var totalR: UInt64 = 0
        var totalG: UInt64 = 0
        var totalB: UInt64 = 0
        var pixelCount: UInt64 = 0

        // Sample pixels (not every pixel for performance)
        let sampleStep = max(1, min(width, height) / 100)

        var firstR: UInt8?
        var firstG: UInt8?
        var firstB: UInt8?
        var allSame = true

        for y in stride(from: 0, to: height, by: sampleStep) {
            for x in stride(from: 0, to: width, by: sampleStep) {
                let offset = y * bytesPerRow + x * bytesPerPixel

                // Handle different pixel formats (BGRA vs RGBA)
                let r: UInt8
                let g: UInt8
                let b: UInt8

                if image.bitmapInfo.contains(.byteOrder32Little) {
                    // BGRA format
                    b = ptr[offset]
                    g = ptr[offset + 1]
                    r = ptr[offset + 2]
                } else {
                    // RGBA format
                    r = ptr[offset]
                    g = ptr[offset + 1]
                    b = ptr[offset + 2]
                }

                totalR += UInt64(r)
                totalG += UInt64(g)
                totalB += UInt64(b)
                pixelCount += 1

                if let fr = firstR, let fg = firstG, let fb = firstB {
                    if r != fr || g != fg || b != fb {
                        allSame = false
                    }
                } else {
                    firstR = r
                    firstG = g
                    firstB = b
                }
            }
        }

        let avgR = UInt8(totalR / max(1, pixelCount))
        let avgG = UInt8(totalG / max(1, pixelCount))
        let avgB = UInt8(totalB / max(1, pixelCount))

        // Calculate variance
        var varianceSum: Double = 0
        pixelCount = 0

        for y in stride(from: 0, to: height, by: sampleStep) {
            for x in stride(from: 0, to: width, by: sampleStep) {
                let offset = y * bytesPerRow + x * bytesPerPixel

                let r: UInt8
                let g: UInt8
                let b: UInt8

                if image.bitmapInfo.contains(.byteOrder32Little) {
                    b = ptr[offset]
                    g = ptr[offset + 1]
                    r = ptr[offset + 2]
                } else {
                    r = ptr[offset]
                    g = ptr[offset + 1]
                    b = ptr[offset + 2]
                }

                let diffR = Double(r) - Double(avgR)
                let diffG = Double(g) - Double(avgG)
                let diffB = Double(b) - Double(avgB)

                varianceSum += diffR * diffR + diffG * diffG + diffB * diffB
                pixelCount += 1
            }
        }

        let variance = varianceSum / Double(max(1, pixelCount))

        let isBlack = avgR < 10 && avgG < 10 && avgB < 10 && variance < 100
        let isSolidColor = allSame || variance < 10
        let hasContent = !isBlack && variance > 100

        return AnalysisResult(
            width: width,
            height: height,
            isBlack: isBlack,
            isSolidColor: isSolidColor,
            averageColor: (avgR, avgG, avgB),
            colorVariance: variance,
            hasContent: hasContent
        )
    }

    /// Quick check if an image is all black
    public static func isBlackScreen(_ image: CGImage) -> Bool {
        analyze(image).isBlack
    }

    /// Quick check if an image has visual content
    public static func hasVisualContent(_ image: CGImage) -> Bool {
        analyze(image).hasContent
    }
}
