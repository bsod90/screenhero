import XCTest
import CoreMedia
import CoreVideo
@testable import ScreenHeroCore

final class EncoderTests: XCTestCase {

    // MARK: - PassthroughEncoder Tests

    func testPassthroughEncoderRequiresConfiguration() async throws {
        let encoder = PassthroughEncoder()

        // Create a test sample buffer
        let sampleBuffer = try createTestSampleBuffer(width: 640, height: 480)

        // Should throw because not configured
        do {
            _ = try await encoder.encode(sampleBuffer)
            XCTFail("Should have thrown")
        } catch VideoEncoderError.notConfigured {
            // Expected
        }
    }

    func testPassthroughEncoderEncodesFrame() async throws {
        let encoder = PassthroughEncoder()
        let config = StreamConfig(
            width: 640,
            height: 480,
            fps: 30,
            codec: .passthrough
        )

        try await encoder.configure(config)

        let sampleBuffer = try createTestSampleBuffer(width: 640, height: 480)
        let packet = try await encoder.encode(sampleBuffer)

        XCTAssertEqual(packet.frameId, 0)
        XCTAssertEqual(packet.codec, .passthrough)
        XCTAssertEqual(packet.width, 640)
        XCTAssertEqual(packet.height, 480)
        XCTAssertTrue(packet.isKeyframe)
        XCTAssertGreaterThan(packet.data.count, 0)
    }

    func testPassthroughEncoderFrameIdIncreases() async throws {
        let encoder = PassthroughEncoder()
        let config = StreamConfig(
            width: 320,
            height: 240,
            fps: 30,
            codec: .passthrough
        )

        try await encoder.configure(config)

        for i in 0..<5 {
            let sampleBuffer = try createTestSampleBuffer(width: 320, height: 240)
            let packet = try await encoder.encode(sampleBuffer)
            XCTAssertEqual(packet.frameId, UInt64(i))
        }
    }

    // MARK: - VideoToolboxEncoder Tests

    func testVideoToolboxEncoderConfiguration() async throws {
        let encoder = VideoToolboxEncoder()
        let config = StreamConfig(
            width: 1920,
            height: 1080,
            fps: 30,
            codec: .h264,
            bitrate: 5_000_000
        )

        // Should not throw
        try await encoder.configure(config)

        let storedConfig = await encoder.config
        XCTAssertEqual(storedConfig?.width, 1920)
        XCTAssertEqual(storedConfig?.height, 1080)
        XCTAssertEqual(storedConfig?.codec, .h264)
    }

    func testVideoToolboxEncoderEncodesH264() async throws {
        let encoder = VideoToolboxEncoder()
        let config = StreamConfig(
            width: 640,
            height: 480,
            fps: 30,
            codec: .h264,
            bitrate: 2_000_000,
            lowLatencyMode: true
        )

        try await encoder.configure(config)

        let sampleBuffer = try createTestSampleBuffer(width: 640, height: 480)
        let packet = try await encoder.encode(sampleBuffer)

        XCTAssertEqual(packet.frameId, 0)
        XCTAssertEqual(packet.codec, .h264)
        XCTAssertEqual(packet.width, 640)
        XCTAssertEqual(packet.height, 480)
        XCTAssertTrue(packet.isKeyframe) // First frame should be keyframe
        XCTAssertGreaterThan(packet.data.count, 0)
        XCTAssertNotNil(packet.parameterSets) // Keyframe should have SPS/PPS
    }

    func testVideoToolboxEncoderEncodesHEVC() async throws {
        let encoder = VideoToolboxEncoder()
        let config = StreamConfig(
            width: 640,
            height: 480,
            fps: 30,
            codec: .hevc,
            bitrate: 2_000_000,
            lowLatencyMode: true
        )

        try await encoder.configure(config)

        let sampleBuffer = try createTestSampleBuffer(width: 640, height: 480)
        let packet = try await encoder.encode(sampleBuffer)

        XCTAssertEqual(packet.codec, .hevc)
        XCTAssertTrue(packet.isKeyframe)
        XCTAssertGreaterThan(packet.data.count, 0)
    }

    func testVideoToolboxEncoderMultipleFrames() async throws {
        let encoder = VideoToolboxEncoder()
        let config = StreamConfig(
            width: 320,
            height: 240,
            fps: 30,
            codec: .h264,
            bitrate: 1_000_000,
            keyframeInterval: 30,
            lowLatencyMode: true
        )

        try await encoder.configure(config)

        var packets: [EncodedPacket] = []
        for _ in 0..<10 {
            let sampleBuffer = try createTestSampleBuffer(width: 320, height: 240)
            let packet = try await encoder.encode(sampleBuffer)
            packets.append(packet)
        }

        XCTAssertEqual(packets.count, 10)

        // First frame should be keyframe
        XCTAssertTrue(packets[0].isKeyframe)

        // Frame IDs should be sequential
        for (index, packet) in packets.enumerated() {
            XCTAssertEqual(packet.frameId, UInt64(index))
        }
    }

    // MARK: - Helper Methods

    private func createTestSampleBuffer(width: Int, height: Int) throws -> CMSampleBuffer {
        // Create pixel buffer
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
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

        // Fill with test pattern
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

        // Create format description
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &formatDescription
        )

        guard let formatDesc = formatDescription else {
            throw TestError.formatDescriptionCreationFailed
        }

        // Create timing info
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: 0, timescale: 30),
            decodeTimeStamp: .invalid
        )

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
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
