import XCTest
@testable import ScreenHeroCore

final class FECCodecTests: XCTestCase {

    // MARK: - FECConfig Tests

    func testDefaultConfig() {
        let config = FECConfig.default
        XCTAssertEqual(config.blockSize, 5)
        XCTAssertEqual(config.parityCount, 1)
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.overheadPercent, 20.0) // 1/5 = 20%
    }

    func testDisabledConfig() {
        let config = FECConfig.disabled
        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.overheadPercent, 0)
    }

    func testCustomConfig() {
        let config = FECConfig(blockSize: 10, parityCount: 2, enabled: true)
        XCTAssertEqual(config.blockSize, 10)
        XCTAssertEqual(config.parityCount, 2)
        XCTAssertEqual(config.overheadPercent, 20.0) // 2/10 = 20%
    }

    func testConfigMinimumBlockSize() {
        let config = FECConfig(blockSize: 1, parityCount: 1, enabled: true)
        XCTAssertEqual(config.blockSize, 2) // Minimum is 2
    }

    func testConfigParityCountClamped() {
        let config = FECConfig(blockSize: 5, parityCount: 5, enabled: true)
        XCTAssertEqual(config.parityCount, 2) // Maximum is 2
    }

    // MARK: - FECEncoder Tests

    func testEncoderWithDisabledFEC() {
        let encoder = FECEncoder(config: .disabled)
        let fragments = [
            Data([1, 2, 3]),
            Data([4, 5, 6]),
            Data([7, 8, 9])
        ]

        let encoded = encoder.encode(fragments: fragments, frameId: 1)

        // No parity fragments should be added
        XCTAssertEqual(encoded.count, 3)
        XCTAssertTrue(encoded.allSatisfy { !$0.isParity })
    }

    func testEncoderAddsParity() {
        let config = FECConfig(blockSize: 3, parityCount: 1, enabled: true)
        let encoder = FECEncoder(config: config)
        let fragments = [
            Data([1, 2, 3]),
            Data([4, 5, 6]),
            Data([7, 8, 9])
        ]

        let encoded = encoder.encode(fragments: fragments, frameId: 1)

        // 3 data + 1 parity = 4 total
        XCTAssertEqual(encoded.count, 4)

        let dataFragments = encoded.filter { !$0.isParity }
        let parityFragments = encoded.filter { $0.isParity }

        XCTAssertEqual(dataFragments.count, 3)
        XCTAssertEqual(parityFragments.count, 1)
    }

    func testEncoderMultipleBlocks() {
        let config = FECConfig(blockSize: 3, parityCount: 1, enabled: true)
        let encoder = FECEncoder(config: config)
        let fragments = (0..<7).map { Data(repeating: UInt8($0), count: 10) }

        let encoded = encoder.encode(fragments: fragments, frameId: 1)

        // 7 data fragments = 3 blocks (3 + 3 + 1)
        // Block 0: 3 data + 1 parity = 4
        // Block 1: 3 data + 1 parity = 4
        // Block 2: 1 data + 1 parity = 2
        // Total: 10 fragments
        XCTAssertEqual(encoded.count, 10)

        let parityCount = encoded.filter { $0.isParity }.count
        XCTAssertEqual(parityCount, 3) // One parity per block
    }

    func testEncoderXORParity() {
        let config = FECConfig(blockSize: 3, parityCount: 1, enabled: true)
        let encoder = FECEncoder(config: config)

        // Use simple data where XOR result is predictable
        let fragments = [
            Data([0b00001111, 0b00001111]),
            Data([0b11110000, 0b00001111]),
            Data([0b11111111, 0b00000000])
        ]

        let encoded = encoder.encode(fragments: fragments, frameId: 1)
        let parity = encoded.first { $0.isParity }

        XCTAssertNotNil(parity)
        // XOR: 0b00001111 ^ 0b11110000 ^ 0b11111111 = 0b00000000
        // XOR: 0b00001111 ^ 0b00001111 ^ 0b00000000 = 0b00000000
        XCTAssertEqual(parity?.data, Data([0b00000000, 0b00000000]))
    }

    func testEncoderEmptyFragments() {
        let encoder = FECEncoder(config: .default)
        let encoded = encoder.encode(fragments: [], frameId: 1)
        XCTAssertTrue(encoded.isEmpty)
    }

    func testEncoderFragmentMetadata() {
        let config = FECConfig(blockSize: 3, parityCount: 1, enabled: true)
        let encoder = FECEncoder(config: config)
        let fragments = [
            Data([1]),
            Data([2]),
            Data([3]),
            Data([4])
        ]

        let encoded = encoder.encode(fragments: fragments, frameId: 42)

        // Verify all fragments have correct frame ID
        XCTAssertTrue(encoded.allSatisfy { $0.frameId == 42 })

        // Verify block indices
        let block0 = encoded.filter { $0.blockIndex == 0 }
        let block1 = encoded.filter { $0.blockIndex == 1 }

        XCTAssertEqual(block0.count, 4) // 3 data + 1 parity
        XCTAssertEqual(block1.count, 2) // 1 data + 1 parity
    }

    // MARK: - FECDecoder Tests

    func testDecoderRecoversSingleMissingFragment() {
        let config = FECConfig(blockSize: 3, parityCount: 1, enabled: true)
        let encoder = FECEncoder(config: config)
        let decoder = FECDecoder(config: config)

        let originalFragments = [
            Data([10, 20, 30]),
            Data([40, 50, 60]),
            Data([70, 80, 90])
        ]

        let encoded = encoder.encode(fragments: originalFragments, frameId: 1)

        // Simulate losing the second data fragment
        let received = encoded.filter { !(!$0.isParity && $0.indexInBlock == 1) }

        // Process all received fragments
        var recovered: [RecoveredFragment]? = nil
        for fragment in received {
            if let result = decoder.processFragment(fragment) {
                recovered = result
            }
        }

        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.count, 1)

        // The recovered fragment should match original
        if let recov = recovered?.first {
            XCTAssertEqual(recov.indexInBlock, 1)
            // Note: XOR recovery might have trailing zeros trimmed
            XCTAssertTrue(recov.data.starts(with: originalFragments[1]))
        }
    }

    func testDecoderCannotRecoverTwoMissingFragments() {
        let config = FECConfig(blockSize: 3, parityCount: 1, enabled: true)
        let encoder = FECEncoder(config: config)
        let decoder = FECDecoder(config: config)

        let originalFragments = [
            Data([10, 20, 30]),
            Data([40, 50, 60]),
            Data([70, 80, 90])
        ]

        let encoded = encoder.encode(fragments: originalFragments, frameId: 1)

        // Simulate losing TWO data fragments (only keep index 0 and parity)
        let received = encoded.filter { $0.isParity || $0.indexInBlock == 0 }

        // Process all received fragments
        var recovered: [RecoveredFragment]? = nil
        for fragment in received {
            if let result = decoder.processFragment(fragment) {
                recovered = result
            }
        }

        // Should NOT recover - XOR FEC can only recover 1 missing per block
        XCTAssertNil(recovered)
    }

    func testDecoderNoRecoveryNeededWhenComplete() {
        let config = FECConfig(blockSize: 3, parityCount: 1, enabled: true)
        let encoder = FECEncoder(config: config)
        let decoder = FECDecoder(config: config)

        let originalFragments = [
            Data([10, 20, 30]),
            Data([40, 50, 60]),
            Data([70, 80, 90])
        ]

        let encoded = encoder.encode(fragments: originalFragments, frameId: 1)

        // All fragments received - no recovery needed
        var recovered: [RecoveredFragment]? = nil
        for fragment in encoded {
            if let result = decoder.processFragment(fragment) {
                recovered = result
            }
        }

        // Recovery should not be triggered
        XCTAssertNil(recovered)
    }

    func testDecoderDisabledReturnsNil() {
        let decoder = FECDecoder(config: .disabled)
        let fragment = FECFragment(
            data: Data([1, 2, 3]),
            frameId: 1,
            originalIndex: 0,
            blockIndex: 0,
            indexInBlock: 0,
            blockDataCount: 3,
            isParity: false
        )

        let result = decoder.processFragment(fragment)
        XCTAssertNil(result)
    }

    func testDecoderStatistics() {
        let config = FECConfig(blockSize: 3, parityCount: 1, enabled: true)
        let encoder = FECEncoder(config: config)
        let decoder = FECDecoder(config: config)

        // Encode and lose one fragment
        let encoded = encoder.encode(fragments: [Data([1]), Data([2]), Data([3])], frameId: 1)
        let received = encoded.filter { !(!$0.isParity && $0.indexInBlock == 1) }

        for fragment in received {
            _ = decoder.processFragment(fragment)
        }

        XCTAssertEqual(decoder.recoveredFragments, 1)
    }

    func testDecoderReset() {
        let config = FECConfig(blockSize: 3, parityCount: 1, enabled: true)
        let decoder = FECDecoder(config: config)

        // Add a partial block
        let fragment = FECFragment(
            data: Data([1, 2, 3]),
            frameId: 1,
            originalIndex: 0,
            blockIndex: 0,
            indexInBlock: 0,
            blockDataCount: 3,
            isParity: false
        )
        _ = decoder.processFragment(fragment)

        decoder.reset()

        // After reset, block should no longer be tracked
        XCTAssertTrue(decoder.isBlockComplete(frameId: 1, blockIndex: 0))
    }

    // MARK: - Integration Tests

    func testFECRoundTripWithPacketLoss() {
        let config = FECConfig(blockSize: 5, parityCount: 1, enabled: true)
        let encoder = FECEncoder(config: config)
        let decoder = FECDecoder(config: config)

        // Create 15 fragments (3 full blocks)
        let originalFragments = (0..<15).map { i in
            Data(repeating: UInt8(i), count: 100)
        }

        let encoded = encoder.encode(fragments: originalFragments, frameId: 1)

        // Verify block structure
        let dataFragments = encoded.filter { !$0.isParity }
        let parityFragments = encoded.filter { $0.isParity }
        XCTAssertEqual(dataFragments.count, 15)
        XCTAssertEqual(parityFragments.count, 3) // One per block

        // Simulate losing one fragment from each block (positions 0, 5, 10)
        let lostIndices: Set<Int> = [0, 6, 12] // First data fragment in each block
        var received: [FECFragment] = []
        for (i, fragment) in encoded.enumerated() {
            if !lostIndices.contains(i) {
                received.append(fragment)
            }
        }

        // Process and expect 3 recoveries
        var recoveredCount = 0
        for fragment in received {
            if decoder.processFragment(fragment) != nil {
                recoveredCount += 1
            }
        }

        XCTAssertEqual(recoveredCount, 3) // One recovery per block
        XCTAssertEqual(decoder.recoveredFragments, 3)
    }

    func testFECBlockIDEquality() {
        let id1 = FECBlockID(frameId: 1, blockIndex: 0)
        let id2 = FECBlockID(frameId: 1, blockIndex: 0)
        let id3 = FECBlockID(frameId: 1, blockIndex: 1)
        let id4 = FECBlockID(frameId: 2, blockIndex: 0)

        XCTAssertEqual(id1, id2)
        XCTAssertNotEqual(id1, id3)
        XCTAssertNotEqual(id1, id4)
    }

    func testRecoveredFragmentOriginalIndex() {
        let recovered = RecoveredFragment(
            frameId: 1,
            blockIndex: 2,
            indexInBlock: 3,
            data: Data()
        )

        // Block 2, index 3, blockSize 5: 2*5 + 3 = 13
        XCTAssertEqual(recovered.originalIndex(blockSize: 5), 13)

        // Block 2, index 3, blockSize 10: 2*10 + 3 = 23
        XCTAssertEqual(recovered.originalIndex(blockSize: 10), 23)
    }
}
