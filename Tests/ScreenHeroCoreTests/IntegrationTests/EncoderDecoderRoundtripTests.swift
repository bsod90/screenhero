import XCTest
import CoreMedia
import CoreVideo
@testable import ScreenHeroCore

final class EncoderDecoderRoundtripTests: XCTestCase {

    // MARK: - H.264 Roundtrip Tests

    func testH264EncoderDecoderRoundtrip() async throws {
        let encoder = VideoToolboxEncoder()
        let decoder = VideoToolboxDecoder()

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
        try await decoder.configure(config)

        // Encode multiple frames
        var packets: [EncodedPacket] = []
        for i in 0..<5 {
            let sampleBuffer = try createTestSampleBuffer(
                width: 320,
                height: 240,
                frameIndex: i
            )
            let packet = try await encoder.encode(sampleBuffer)
            packets.append(packet)
        }

        // Decode all frames
        var decodedBuffers: [CVPixelBuffer] = []
        for packet in packets {
            let pixelBuffer = try await decoder.decode(packet)
            decodedBuffers.append(pixelBuffer)
        }

        XCTAssertEqual(decodedBuffers.count, 5)

        // Verify dimensions
        for buffer in decodedBuffers {
            XCTAssertEqual(CVPixelBufferGetWidth(buffer), 320)
            XCTAssertEqual(CVPixelBufferGetHeight(buffer), 240)
        }
    }

    func testHEVCEncoderDecoderRoundtrip() async throws {
        let encoder = VideoToolboxEncoder()
        let decoder = VideoToolboxDecoder()

        let config = StreamConfig(
            width: 320,
            height: 240,
            fps: 30,
            codec: .hevc,
            bitrate: 1_000_000,
            keyframeInterval: 30,
            lowLatencyMode: true
        )

        try await encoder.configure(config)
        try await decoder.configure(config)

        // Encode and decode a single frame
        let sampleBuffer = try createTestSampleBuffer(width: 320, height: 240, frameIndex: 0)
        let packet = try await encoder.encode(sampleBuffer)
        let decodedBuffer = try await decoder.decode(packet)

        XCTAssertEqual(CVPixelBufferGetWidth(decodedBuffer), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(decodedBuffer), 240)
    }

    // MARK: - Full Pipeline Test

    func testFullPipelineWithPacketProtocol() async throws {
        let encoder = VideoToolboxEncoder()
        let decoder = VideoToolboxDecoder()
        let packetProtocol = PacketProtocol(maxPacketSize: 1400)

        let config = StreamConfig(
            width: 640,
            height: 480,
            fps: 30,
            codec: .h264,
            bitrate: 2_000_000,
            keyframeInterval: 30,
            lowLatencyMode: true
        )

        try await encoder.configure(config)
        try await decoder.configure(config)

        // Create and encode a frame
        let sampleBuffer = try createTestSampleBuffer(width: 640, height: 480, frameIndex: 0)
        let encodedPacket = try await encoder.encode(sampleBuffer)

        // Fragment for network transmission
        let fragments = packetProtocol.fragment(packet: encodedPacket)
        XCTAssertGreaterThan(fragments.count, 0)

        // Simulate network transmission (serialize and deserialize)
        let serializedFragments = fragments.map { $0.serialize() }
        let deserializedFragments = serializedFragments.compactMap { NetworkPacket.deserialize(from: $0) }
        XCTAssertEqual(deserializedFragments.count, fragments.count)

        // Reassemble
        guard let reassembledPacket = packetProtocol.reassemble(fragments: deserializedFragments) else {
            XCTFail("Failed to reassemble")
            return
        }

        // Verify reassembled packet matches original
        XCTAssertEqual(reassembledPacket.data, encodedPacket.data)
        XCTAssertEqual(reassembledPacket.isKeyframe, encodedPacket.isKeyframe)
        XCTAssertEqual(reassembledPacket.codec, encodedPacket.codec)

        // Decode
        let decodedBuffer = try await decoder.decode(reassembledPacket)
        XCTAssertEqual(CVPixelBufferGetWidth(decodedBuffer), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(decodedBuffer), 480)
    }

    // MARK: - Latency Measurement

    func testEncodingLatency() async throws {
        let encoder = VideoToolboxEncoder()

        let config = StreamConfig(
            width: 1920,
            height: 1080,
            fps: 60,
            codec: .h264,
            bitrate: 10_000_000,
            lowLatencyMode: true
        )

        try await encoder.configure(config)

        var encodeTimes: [Double] = []

        for i in 0..<30 {
            let sampleBuffer = try createTestSampleBuffer(width: 1920, height: 1080, frameIndex: i)

            let startTime = DispatchTime.now()
            _ = try await encoder.encode(sampleBuffer)
            let endTime = DispatchTime.now()

            let elapsedNs = Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds)
            let elapsedMs = elapsedNs / 1_000_000
            encodeTimes.append(elapsedMs)
        }

        let averageEncodeTime = encodeTimes.reduce(0, +) / Double(encodeTimes.count)
        let maxEncodeTime = encodeTimes.max() ?? 0

        print("Encode times (ms): avg=\(averageEncodeTime), max=\(maxEncodeTime)")

        // Encoding should generally be fast with hardware acceleration
        // This is informational - not a strict test
        XCTAssertLessThan(averageEncodeTime, 50, "Average encode time should be under 50ms")
    }

    // MARK: - Helper Methods

    private func createTestSampleBuffer(width: Int, height: Int, frameIndex: Int) throws -> CMSampleBuffer {
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

        // Fill with animated test pattern
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
            let phase = frameIndex * 10

            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    ptr[offset] = UInt8((x + phase) % 256)     // B
                    ptr[offset + 1] = UInt8((y + phase) % 256) // G
                    ptr[offset + 2] = UInt8(128)               // R
                    ptr[offset + 3] = 255                      // A
                }
            }
        }

        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &formatDescription
        )

        guard let formatDesc = formatDescription else {
            throw TestError.formatDescriptionCreationFailed
        }

        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: CMTimeValue(frameIndex), timescale: 30),
            decodeTimeStamp: .invalid
        )

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
