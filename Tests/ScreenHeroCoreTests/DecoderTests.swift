import XCTest
import CoreVideo
@testable import ScreenHeroCore

final class DecoderTests: XCTestCase {

    // MARK: - PassthroughDecoder Tests

    func testPassthroughDecoderDecodesPacket() async throws {
        let decoder = PassthroughDecoder()
        let config = StreamConfig(
            width: 640,
            height: 480,
            fps: 30,
            codec: .passthrough
        )

        try await decoder.configure(config)

        // Create a test packet with raw pixel data
        let width = 640
        let height = 480
        let bytesPerRow = width * 4
        var pixelData = Data(count: bytesPerRow * height)

        // Fill with test pattern
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                pixelData[offset] = UInt8(x % 256)     // B
                pixelData[offset + 1] = UInt8(y % 256) // G
                pixelData[offset + 2] = 128            // R
                pixelData[offset + 3] = 255            // A
            }
        }

        let packet = EncodedPacket(
            frameId: 0,
            data: pixelData,
            presentationTimeNs: 0,
            isKeyframe: true,
            codec: .passthrough,
            width: width,
            height: height,
            captureTimestamp: 0,
            encodeTimestamp: 0
        )

        let pixelBuffer = try await decoder.decode(packet)

        XCTAssertEqual(CVPixelBufferGetWidth(pixelBuffer), width)
        XCTAssertEqual(CVPixelBufferGetHeight(pixelBuffer), height)
    }

    func testPassthroughDecoderPreservesPixelData() async throws {
        let decoder = PassthroughDecoder()
        let config = StreamConfig(
            width: 64,
            height: 64,
            fps: 30,
            codec: .passthrough
        )

        try await decoder.configure(config)

        let width = 64
        let height = 64
        let bytesPerRow = width * 4
        var pixelData = Data(count: bytesPerRow * height)

        // Fill with known pattern
        for i in 0..<(bytesPerRow * height) {
            pixelData[i] = UInt8(i % 256)
        }

        let packet = EncodedPacket(
            frameId: 0,
            data: pixelData,
            presentationTimeNs: 0,
            isKeyframe: true,
            codec: .passthrough,
            width: width,
            height: height,
            captureTimestamp: 0,
            encodeTimestamp: 0
        )

        let pixelBuffer = try await decoder.decode(packet)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            XCTFail("No base address")
            return
        }

        let decodedBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

        // Verify a sample of pixels
        for y in stride(from: 0, to: height, by: 16) {
            for x in stride(from: 0, to: width, by: 16) {
                let srcOffset = y * bytesPerRow + x * 4
                let dstOffset = y * decodedBytesPerRow + x * 4

                XCTAssertEqual(ptr[dstOffset], pixelData[srcOffset], "Mismatch at (\(x), \(y)) blue")
                XCTAssertEqual(ptr[dstOffset + 1], pixelData[srcOffset + 1], "Mismatch at (\(x), \(y)) green")
                XCTAssertEqual(ptr[dstOffset + 2], pixelData[srcOffset + 2], "Mismatch at (\(x), \(y)) red")
            }
        }
    }

    // MARK: - VideoToolboxDecoder Tests

    func testVideoToolboxDecoderConfiguration() async throws {
        let decoder = VideoToolboxDecoder()
        let config = StreamConfig(
            width: 1920,
            height: 1080,
            fps: 30,
            codec: .h264
        )

        // Should not throw
        try await decoder.configure(config)
    }

    func testVideoToolboxDecoderRequiresFormatDescription() async throws {
        let decoder = VideoToolboxDecoder()
        let config = StreamConfig(
            width: 640,
            height: 480,
            fps: 30,
            codec: .h264
        )

        try await decoder.configure(config)

        // Create a packet without parameter sets
        let packet = EncodedPacket(
            frameId: 0,
            data: Data([0x00, 0x00, 0x00, 0x01, 0x65]), // Fake NAL
            presentationTimeNs: 0,
            isKeyframe: true,
            codec: .h264,
            width: 640,
            height: 480,
            captureTimestamp: 0,
            encodeTimestamp: 0,
            parameterSets: nil
        )

        // Should throw because no format description
        do {
            _ = try await decoder.decode(packet)
            XCTFail("Should have thrown")
        } catch VideoDecoderError.formatDescriptionMissing {
            // Expected
        }
    }

    // MARK: - Passthrough Roundtrip Test

    func testPassthroughEncoderDecoderRoundtrip() async throws {
        let encoder = PassthroughEncoder()
        let decoder = PassthroughDecoder()
        let config = StreamConfig(
            width: 128,
            height: 128,
            fps: 30,
            codec: .passthrough
        )

        try await encoder.configure(config)
        try await decoder.configure(config)

        // Create source pixel buffer with test pattern
        let sourceBuffer = try createTestPixelBuffer(width: 128, height: 128)

        // Create sample buffer from pixel buffer
        let sampleBuffer = try createSampleBuffer(from: sourceBuffer)

        // Encode
        let packet = try await encoder.encode(sampleBuffer)

        // Decode
        let decodedBuffer = try await decoder.decode(packet)

        // Compare
        XCTAssertEqual(CVPixelBufferGetWidth(decodedBuffer), 128)
        XCTAssertEqual(CVPixelBufferGetHeight(decodedBuffer), 128)

        // Compare pixel data
        CVPixelBufferLockBaseAddress(sourceBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(decodedBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(sourceBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(decodedBuffer, .readOnly)
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(sourceBuffer),
              let dstBase = CVPixelBufferGetBaseAddress(decodedBuffer) else {
            XCTFail("No base addresses")
            return
        }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(sourceBuffer)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(decodedBuffer)
        let srcPtr = srcBase.assumingMemoryBound(to: UInt8.self)
        let dstPtr = dstBase.assumingMemoryBound(to: UInt8.self)

        // Compare sample pixels
        for y in stride(from: 0, to: 128, by: 32) {
            for x in stride(from: 0, to: 128, by: 32) {
                let srcOffset = y * srcBytesPerRow + x * 4
                let dstOffset = y * dstBytesPerRow + x * 4

                XCTAssertEqual(srcPtr[srcOffset], dstPtr[dstOffset], "Blue mismatch at (\(x), \(y))")
                XCTAssertEqual(srcPtr[srcOffset + 1], dstPtr[dstOffset + 1], "Green mismatch at (\(x), \(y))")
                XCTAssertEqual(srcPtr[srcOffset + 2], dstPtr[dstOffset + 2], "Red mismatch at (\(x), \(y))")
            }
        }
    }

    // MARK: - Helper Methods

    private func createTestPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw TestError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    ptr[offset] = UInt8((x * 255) / width)     // B
                    ptr[offset + 1] = UInt8((y * 255) / height) // G
                    ptr[offset + 2] = 128                       // R
                    ptr[offset + 3] = 255                       // A
                }
            }
        }

        return buffer
    }

    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer) throws -> CMSampleBuffer {
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )

        guard let formatDesc = formatDescription else {
            throw TestError.formatDescriptionCreationFailed
        }

        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: 0, timescale: 30),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        guard let sample = sampleBuffer else {
            throw TestError.sampleBufferCreationFailed
        }

        return sample
    }

    enum TestError: Error {
        case pixelBufferCreationFailed
        case formatDescriptionCreationFailed
        case sampleBufferCreationFailed
    }
}
