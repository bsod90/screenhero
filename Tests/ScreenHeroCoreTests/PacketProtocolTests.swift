import XCTest
@testable import ScreenHeroCore

final class PacketProtocolTests: XCTestCase {
    var packetProtocol: PacketProtocol!

    override func setUp() {
        super.setUp()
        packetProtocol = PacketProtocol(maxPacketSize: 1400)
    }

    // MARK: - Fragmentation Tests

    func testSmallPacketNotFragmented() {
        let smallData = Data(repeating: 0xAB, count: 500)
        let packet = EncodedPacket(
            frameId: 1,
            data: smallData,
            presentationTimeNs: 1000,
            isKeyframe: true,
            codec: .h264,
            width: 1920,
            height: 1080,
            captureTimestamp: 500,
            encodeTimestamp: 600
        )

        let fragments = packetProtocol.fragment(packet: packet)

        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragments[0].fragmentIndex, 0)
        XCTAssertEqual(fragments[0].totalFragments, 1)
        XCTAssertEqual(fragments[0].payload, smallData)
    }

    func testLargePacketFragmented() {
        let largeData = Data(repeating: 0xCD, count: 50_000)
        let packet = EncodedPacket(
            frameId: 42,
            data: largeData,
            presentationTimeNs: 2000,
            isKeyframe: false,
            codec: .hevc,
            width: 3840,
            height: 2160,
            captureTimestamp: 1000,
            encodeTimestamp: 1100
        )

        let fragments = packetProtocol.fragment(packet: packet)

        XCTAssertGreaterThan(fragments.count, 1)

        // Verify fragment indices are sequential
        for (index, fragment) in fragments.enumerated() {
            XCTAssertEqual(fragment.fragmentIndex, UInt16(index))
            XCTAssertEqual(fragment.totalFragments, UInt16(fragments.count))
            XCTAssertEqual(fragment.frameId, 42)
        }

        // Verify total payload size matches
        let totalPayloadSize = fragments.reduce(0) { $0 + $1.payload.count }
        XCTAssertEqual(totalPayloadSize, largeData.count)
    }

    func testFragmentMetadataPreserved() {
        let data = Data(repeating: 0xEF, count: 5000)
        let packet = EncodedPacket(
            frameId: 100,
            data: data,
            presentationTimeNs: 123456789,
            isKeyframe: true,
            codec: .h264,
            width: 1280,
            height: 720,
            captureTimestamp: 100000,
            encodeTimestamp: 100500
        )

        let fragments = packetProtocol.fragment(packet: packet)

        for fragment in fragments {
            XCTAssertEqual(fragment.frameId, 100)
            XCTAssertEqual(fragment.isKeyframe, true)
            XCTAssertEqual(fragment.codec, .h264)
            XCTAssertEqual(fragment.width, 1280)
            XCTAssertEqual(fragment.height, 720)
            XCTAssertEqual(fragment.presentationTimeNs, 123456789)
        }
    }

    // MARK: - Reassembly Tests

    func testReassembleSingleFragment() {
        let originalData = Data(repeating: 0x12, count: 500)
        let packet = EncodedPacket(
            frameId: 1,
            data: originalData,
            presentationTimeNs: 1000,
            isKeyframe: true,
            codec: .h264,
            width: 1920,
            height: 1080,
            captureTimestamp: 500,
            encodeTimestamp: 600
        )

        let fragments = packetProtocol.fragment(packet: packet)
        let reassembled = packetProtocol.reassemble(fragments: fragments)

        XCTAssertNotNil(reassembled)
        XCTAssertEqual(reassembled?.data, originalData)
        XCTAssertEqual(reassembled?.frameId, 1)
        XCTAssertEqual(reassembled?.isKeyframe, true)
    }

    func testReassembleMultipleFragments() {
        let originalData = Data(repeating: 0x34, count: 50_000)
        let packet = EncodedPacket(
            frameId: 42,
            data: originalData,
            presentationTimeNs: 2000,
            isKeyframe: false,
            codec: .hevc,
            width: 3840,
            height: 2160,
            captureTimestamp: 1000,
            encodeTimestamp: 1100
        )

        let fragments = packetProtocol.fragment(packet: packet)
        let reassembled = packetProtocol.reassemble(fragments: fragments)

        XCTAssertNotNil(reassembled)
        XCTAssertEqual(reassembled?.data, originalData)
        XCTAssertEqual(reassembled?.frameId, 42)
        XCTAssertEqual(reassembled?.codec, .hevc)
        XCTAssertEqual(reassembled?.width, 3840)
        XCTAssertEqual(reassembled?.height, 2160)
    }

    func testReassembleOutOfOrderFragments() {
        let originalData = Data(repeating: 0x56, count: 10_000)
        let packet = EncodedPacket(
            frameId: 5,
            data: originalData,
            presentationTimeNs: 3000,
            isKeyframe: true,
            codec: .h264,
            width: 1920,
            height: 1080,
            captureTimestamp: 2000,
            encodeTimestamp: 2100
        )

        var fragments = packetProtocol.fragment(packet: packet)
        fragments.shuffle() // Randomize order

        let reassembled = packetProtocol.reassemble(fragments: fragments)

        XCTAssertNotNil(reassembled)
        XCTAssertEqual(reassembled?.data, originalData)
    }

    func testReassembleIncompleteFragments() {
        let originalData = Data(repeating: 0x78, count: 10_000)
        let packet = EncodedPacket(
            frameId: 7,
            data: originalData,
            presentationTimeNs: 4000,
            isKeyframe: false,
            codec: .h264,
            width: 1920,
            height: 1080,
            captureTimestamp: 3000,
            encodeTimestamp: 3100
        )

        var fragments = packetProtocol.fragment(packet: packet)
        fragments.removeLast() // Remove one fragment

        let reassembled = packetProtocol.reassemble(fragments: fragments)

        XCTAssertNil(reassembled)
    }

    func testFECRecoversSingleMissingFragmentInBlock() {
        let payloadSize = 1400 - PacketProtocol.headerSize
        let originalData = Data(repeating: 0x5A, count: payloadSize * 25) // Ensure multiple FEC blocks
        let packet = EncodedPacket(
            frameId: 9,
            data: originalData,
            presentationTimeNs: 5000,
            isKeyframe: true,
            codec: .h264,
            width: 1920,
            height: 1080,
            captureTimestamp: 4000,
            encodeTimestamp: 4100
        )

        let protocolWithFEC = PacketProtocol(maxPacketSize: 1400)
        var fragments = protocolWithFEC.fragment(packet: packet)

        // Remove one data fragment from the first FEC block (keep parity)
        if let idx = fragments.firstIndex(where: { !$0.isParity && $0.fecBlockIndex == 0 }) {
            fragments.remove(at: idx)
        } else {
            XCTFail("Expected at least one data fragment in block 0")
            return
        }

        let reassembled = protocolWithFEC.reassemble(fragments: fragments)
        XCTAssertNotNil(reassembled)
        XCTAssertEqual(reassembled?.data, originalData)
    }

    func testReassembleEmptyFragments() {
        let reassembled = packetProtocol.reassemble(fragments: [])
        XCTAssertNil(reassembled)
    }

    func testReassembleMixedFrameIds() {
        let data1 = Data(repeating: 0x11, count: 5000)
        let data2 = Data(repeating: 0x22, count: 5000)

        let packet1 = EncodedPacket(
            frameId: 1,
            data: data1,
            presentationTimeNs: 1000,
            isKeyframe: true,
            codec: .h264,
            width: 1920,
            height: 1080,
            captureTimestamp: 500,
            encodeTimestamp: 600
        )

        let packet2 = EncodedPacket(
            frameId: 2,
            data: data2,
            presentationTimeNs: 2000,
            isKeyframe: false,
            codec: .h264,
            width: 1920,
            height: 1080,
            captureTimestamp: 1500,
            encodeTimestamp: 1600
        )

        let fragments1 = packetProtocol.fragment(packet: packet1)
        let fragments2 = packetProtocol.fragment(packet: packet2)

        // Mix fragments from different frames
        var mixed = fragments1
        mixed.append(contentsOf: fragments2)
        mixed.shuffle()

        // Should fail because frame IDs don't match
        let reassembled = packetProtocol.reassemble(fragments: mixed)
        XCTAssertNil(reassembled)
    }

    // MARK: - Serialization Tests

    func testSerializeAndDeserialize() {
        let payload = Data(repeating: 0xAA, count: 1000)
        let packet = NetworkPacket(
            frameId: 123,
            fragmentIndex: 0,
            totalFragments: 3,
            isKeyframe: true,
            codec: .h264,
            width: 1920,
            height: 1080,
            presentationTimeNs: 999999,
            captureTimestamp: 888888,
            payload: payload,
            parameterSets: nil
        )

        let serialized = packet.serialize()
        let deserialized = NetworkPacket.deserialize(from: serialized)

        XCTAssertNotNil(deserialized)
        XCTAssertEqual(deserialized?.frameId, 123)
        XCTAssertEqual(deserialized?.fragmentIndex, 0)
        XCTAssertEqual(deserialized?.totalFragments, 3)
        XCTAssertEqual(deserialized?.isKeyframe, true)
        XCTAssertEqual(deserialized?.codec, .h264)
        XCTAssertEqual(deserialized?.width, 1920)
        XCTAssertEqual(deserialized?.height, 1080)
        XCTAssertEqual(deserialized?.presentationTimeNs, 999999)
        XCTAssertEqual(deserialized?.payload, payload)
    }

    func testSerializeWithParameterSets() {
        let payload = Data(repeating: 0xBB, count: 500)
        let paramSets = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1E])
        let packet = NetworkPacket(
            frameId: 456,
            fragmentIndex: 0,
            totalFragments: 1,
            isKeyframe: true,
            codec: .h264,
            width: 1280,
            height: 720,
            presentationTimeNs: 123456,
            captureTimestamp: 111111,
            payload: payload,
            parameterSets: paramSets
        )

        let serialized = packet.serialize()
        let deserialized = NetworkPacket.deserialize(from: serialized)

        XCTAssertNotNil(deserialized)
        XCTAssertEqual(deserialized?.parameterSets, paramSets)
        XCTAssertEqual(deserialized?.payload, payload)
    }

    func testDeserializeInvalidMagic() {
        var data = Data(repeating: 0x00, count: 100)
        // Set wrong magic number
        data[0] = 0xFF
        data[1] = 0xFF
        data[2] = 0xFF
        data[3] = 0xFF

        let deserialized = NetworkPacket.deserialize(from: data)
        XCTAssertNil(deserialized)
    }

    func testDeserializeTooShort() {
        let data = Data(repeating: 0x00, count: 10)
        let deserialized = NetworkPacket.deserialize(from: data)
        XCTAssertNil(deserialized)
    }

    // MARK: - Round Trip Tests

    func testFullRoundTrip() {
        let originalData = Data((0..<10_000).map { UInt8($0 % 256) })
        let packet = EncodedPacket(
            frameId: 999,
            data: originalData,
            presentationTimeNs: 123456789,
            isKeyframe: true,
            codec: .hevc,
            width: 3840,
            height: 2160,
            captureTimestamp: 100000000,
            encodeTimestamp: 100000500
        )

        // Fragment
        let fragments = packetProtocol.fragment(packet: packet)
        XCTAssertGreaterThan(fragments.count, 1)

        // Serialize each fragment
        let serializedFragments = fragments.map { $0.serialize() }

        // Deserialize each fragment
        let deserializedFragments = serializedFragments.compactMap { NetworkPacket.deserialize(from: $0) }
        XCTAssertEqual(deserializedFragments.count, fragments.count)

        // Reassemble
        let reassembled = packetProtocol.reassemble(fragments: deserializedFragments)

        XCTAssertNotNil(reassembled)
        XCTAssertEqual(reassembled?.data, originalData)
        XCTAssertEqual(reassembled?.frameId, 999)
        XCTAssertEqual(reassembled?.codec, .hevc)
    }

    // MARK: - Performance Tests

    func testFragmentationPerformance() {
        let largeData = Data(repeating: 0xCC, count: 1_000_000) // 1MB
        let packet = EncodedPacket(
            frameId: 1,
            data: largeData,
            presentationTimeNs: 1000,
            isKeyframe: true,
            codec: .h264,
            width: 3840,
            height: 2160,
            captureTimestamp: 500,
            encodeTimestamp: 600
        )

        measure {
            for _ in 0..<100 {
                _ = packetProtocol.fragment(packet: packet)
            }
        }
    }

    func testReassemblyPerformance() {
        let largeData = Data(repeating: 0xDD, count: 1_000_000) // 1MB
        let packet = EncodedPacket(
            frameId: 1,
            data: largeData,
            presentationTimeNs: 1000,
            isKeyframe: true,
            codec: .h264,
            width: 3840,
            height: 2160,
            captureTimestamp: 500,
            encodeTimestamp: 600
        )

        let fragments = packetProtocol.fragment(packet: packet)

        measure {
            for _ in 0..<100 {
                _ = packetProtocol.reassemble(fragments: fragments)
            }
        }
    }
}
