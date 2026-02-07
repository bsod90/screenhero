import CoreVideo
import Foundation

/// A passthrough decoder for testing that doesn't actually decode
/// Just unwraps raw pixel data from EncodedPacket format
public actor PassthroughDecoder: VideoDecoder {
    private var config: StreamConfig?

    public init() {}

    public func configure(_ config: StreamConfig) async throws {
        self.config = config
    }

    public func decode(_ packet: EncodedPacket) async throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            packet.width,
            packet.height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw VideoDecoderError.decodingFailed("Failed to create pixel buffer")
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw VideoDecoderError.decodingFailed("No base address")
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let expectedSize = bytesPerRow * packet.height

        if packet.data.count >= expectedSize {
            packet.data.copyBytes(to: baseAddress.assumingMemoryBound(to: UInt8.self), count: expectedSize)
        }

        return buffer
    }

    public func flush() async throws {
        // Nothing to flush for passthrough
    }
}
