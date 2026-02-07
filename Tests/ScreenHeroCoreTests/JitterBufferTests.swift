import XCTest
@testable import ScreenHeroCore

final class JitterBufferTests: XCTestCase {

    // MARK: - Basic Tests

    func testEmptyBufferReturnsNil() async {
        let buffer = JitterBuffer()
        let packet = await buffer.pop()
        XCTAssertNil(packet)
    }

    func testSinglePacketInOut() async {
        let buffer = JitterBuffer()
        let packet = createPacket(frameId: 0)

        await buffer.insert(packet)
        let result = await buffer.pop()

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.frameId, 0)
    }

    func testPacketsInOrderDelivery() async {
        let buffer = JitterBuffer()

        // Insert packets in order
        for i in 0..<5 {
            let packet = createPacket(frameId: UInt64(i))
            await buffer.insert(packet)
        }

        // Pop them out - should come out in order
        for i in 0..<5 {
            let result = await buffer.pop()
            XCTAssertNotNil(result)
            XCTAssertEqual(result?.frameId, UInt64(i))
        }

        // Buffer should be empty
        let result = await buffer.pop()
        XCTAssertNil(result)
    }

    // MARK: - Reordering Tests

    func testOutOfOrderPackets() async {
        let buffer = JitterBuffer()

        // Insert packets out of order
        await buffer.insert(createPacket(frameId: 2))
        await buffer.insert(createPacket(frameId: 0))
        await buffer.insert(createPacket(frameId: 1))

        // Should come out in order
        let p0 = await buffer.pop()
        XCTAssertEqual(p0?.frameId, 0)

        let p1 = await buffer.pop()
        XCTAssertEqual(p1?.frameId, 1)

        let p2 = await buffer.pop()
        XCTAssertEqual(p2?.frameId, 2)
    }

    func testGappedPackets() async {
        let buffer = JitterBuffer()

        // Insert with gaps
        await buffer.insert(createPacket(frameId: 0))
        await buffer.insert(createPacket(frameId: 2)) // Skip 1
        await buffer.insert(createPacket(frameId: 3))

        // First packet should come out
        let p0 = await buffer.pop()
        XCTAssertEqual(p0?.frameId, 0)

        // Next should be nil (waiting for frame 1)
        let p1 = await buffer.pop()
        XCTAssertNil(p1)
    }

    func testLargeGapSkipsAhead() async {
        let buffer = JitterBuffer()

        // Insert packet 0
        await buffer.insert(createPacket(frameId: 0))
        _ = await buffer.pop() // Get frame 0

        // Insert with large gap (skip frames 1-9)
        await buffer.insert(createPacket(frameId: 10))

        // Should skip to frame 10 after enough attempts
        var result: EncodedPacket?
        for _ in 0..<10 {
            result = await buffer.pop()
            if result != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        XCTAssertEqual(result?.frameId, 10)
    }

    // MARK: - Late Packets

    func testLatePacketsDropped() async {
        let buffer = JitterBuffer()

        // Insert and pop frame 0
        await buffer.insert(createPacket(frameId: 0))
        _ = await buffer.pop()

        // Insert and pop frame 1
        await buffer.insert(createPacket(frameId: 1))
        _ = await buffer.pop()

        // Now insert "late" frame 0 again (should be dropped)
        await buffer.insert(createPacket(frameId: 0))

        // Buffer depth should be 0
        let depth = await buffer.depth
        XCTAssertEqual(depth, 0)

        // Stats should show late packet
        let stats = await buffer.statistics
        XCTAssertEqual(stats.packetsLate, 1)
    }

    // MARK: - Duplicate Handling

    func testDuplicatePacketsIgnored() async {
        let buffer = JitterBuffer()

        await buffer.insert(createPacket(frameId: 0))
        await buffer.insert(createPacket(frameId: 0)) // Duplicate
        await buffer.insert(createPacket(frameId: 0)) // Duplicate

        let depth = await buffer.depth
        XCTAssertEqual(depth, 1)
    }

    // MARK: - Statistics

    func testStatisticsTracking() async {
        let buffer = JitterBuffer()

        for i in 0..<10 {
            await buffer.insert(createPacket(frameId: UInt64(i)))
        }

        let stats = await buffer.statistics
        XCTAssertEqual(stats.packetsReceived, 10)
        XCTAssertEqual(stats.packetsDropped, 0)
    }

    // MARK: - Reset

    func testBufferReset() async {
        let buffer = JitterBuffer()

        // Add some packets
        for i in 0..<5 {
            await buffer.insert(createPacket(frameId: UInt64(i)))
        }

        // Reset
        await buffer.reset()

        // Buffer should be empty
        let depth = await buffer.depth
        XCTAssertEqual(depth, 0)

        // Stats should be reset
        let stats = await buffer.statistics
        XCTAssertEqual(stats.packetsReceived, 0)
    }

    // MARK: - Adaptive Depth

    func testAdaptiveDepthStable() async {
        let config = JitterBuffer.Configuration(
            targetDepthMs: 50,
            maxDepthMs: 200,
            minDepthMs: 20
        )
        let buffer = JitterBuffer(config: config)

        // Insert packets with consistent timing (low jitter)
        for i in 0..<100 {
            var packet = createPacket(frameId: UInt64(i))
            await buffer.insert(packet)
        }

        // Adaptive depth should stay near target
        let currentDepth = await buffer.currentBufferDepthMs
        XCTAssertLessThanOrEqual(currentDepth, config.maxDepthMs)
        XCTAssertGreaterThanOrEqual(currentDepth, config.minDepthMs)
    }

    // MARK: - Buffer Pruning

    func testBufferPruning() async {
        let buffer = JitterBuffer()

        // Insert many packets without popping
        for i in 0..<200 {
            await buffer.insert(createPacket(frameId: UInt64(i)))
        }

        // Buffer should be pruned to reasonable size
        let depth = await buffer.depth
        XCTAssertLessThanOrEqual(depth, 100)
    }

    // MARK: - Helper Methods

    private func createPacket(frameId: UInt64) -> EncodedPacket {
        EncodedPacket(
            frameId: frameId,
            data: Data([0x00, 0x01, 0x02]),
            presentationTimeNs: frameId * 16_666_666, // ~60fps
            isKeyframe: frameId == 0,
            codec: .h264,
            width: 1920,
            height: 1080,
            captureTimestamp: DispatchTime.now().uptimeNanoseconds,
            encodeTimestamp: DispatchTime.now().uptimeNanoseconds
        )
    }
}
