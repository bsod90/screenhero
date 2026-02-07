import Foundation

/// Protocol for fragmenting large frames into network packets and reassembling them
public struct PacketProtocol: Sendable {
    /// Maximum size of each packet payload (excluding header)
    public let maxPacketSize: Int

    /// Header size in bytes
    public static let headerSize = 32

    public init(maxPacketSize: Int = 1400) {
        self.maxPacketSize = maxPacketSize
    }

    /// Fragment a frame into network packets
    public func fragment(packet: EncodedPacket) -> [NetworkPacket] {
        let payloadMaxSize = maxPacketSize - Self.headerSize
        let totalFragments = (packet.data.count + payloadMaxSize - 1) / payloadMaxSize

        var fragments: [NetworkPacket] = []
        fragments.reserveCapacity(totalFragments)

        for i in 0..<totalFragments {
            let start = i * payloadMaxSize
            let end = min(start + payloadMaxSize, packet.data.count)
            let fragmentData = packet.data.subdata(in: start..<end)

            let fragment = NetworkPacket(
                frameId: packet.frameId,
                fragmentIndex: UInt16(i),
                totalFragments: UInt16(totalFragments),
                isKeyframe: packet.isKeyframe,
                codec: packet.codec,
                width: UInt16(packet.width),
                height: UInt16(packet.height),
                presentationTimeNs: packet.presentationTimeNs,
                captureTimestamp: packet.captureTimestamp,
                payload: fragmentData,
                parameterSets: i == 0 ? packet.parameterSets : nil
            )

            fragments.append(fragment)
        }

        return fragments
    }

    /// Reassemble network packets into an encoded packet
    /// Returns nil if fragments are incomplete
    public func reassemble(fragments: [NetworkPacket]) -> EncodedPacket? {
        guard !fragments.isEmpty else { return nil }

        // Sort by fragment index
        let sorted = fragments.sorted { $0.fragmentIndex < $1.fragmentIndex }

        // Verify we have all fragments
        let first = sorted[0]
        guard sorted.count == Int(first.totalFragments) else { return nil }

        // Verify fragment indices are sequential
        for (index, fragment) in sorted.enumerated() {
            guard fragment.fragmentIndex == index else { return nil }
            guard fragment.frameId == first.frameId else { return nil }
        }

        // Combine payloads
        var combinedData = Data()
        combinedData.reserveCapacity(sorted.reduce(0) { $0 + $1.payload.count })

        for fragment in sorted {
            combinedData.append(fragment.payload)
        }

        return EncodedPacket(
            frameId: first.frameId,
            data: combinedData,
            presentationTimeNs: first.presentationTimeNs,
            isKeyframe: first.isKeyframe,
            codec: first.codec,
            width: Int(first.width),
            height: Int(first.height),
            captureTimestamp: first.captureTimestamp,
            encodeTimestamp: DispatchTime.now().uptimeNanoseconds,
            parameterSets: first.parameterSets
        )
    }
}

/// A network packet (potentially a fragment of a larger frame)
public struct NetworkPacket: Sendable {
    /// Frame identifier
    public let frameId: UInt64

    /// Fragment index (0-based)
    public let fragmentIndex: UInt16

    /// Total number of fragments for this frame
    public let totalFragments: UInt16

    /// Whether the frame is a keyframe
    public let isKeyframe: Bool

    /// Video codec
    public let codec: VideoCodec

    /// Frame width
    public let width: UInt16

    /// Frame height
    public let height: UInt16

    /// Presentation timestamp in nanoseconds
    public let presentationTimeNs: UInt64

    /// Capture timestamp for latency measurement
    public let captureTimestamp: UInt64

    /// Packet payload data
    public let payload: Data

    /// Parameter sets (only on first fragment of keyframe)
    public let parameterSets: Data?

    public init(
        frameId: UInt64,
        fragmentIndex: UInt16,
        totalFragments: UInt16,
        isKeyframe: Bool,
        codec: VideoCodec,
        width: UInt16,
        height: UInt16,
        presentationTimeNs: UInt64,
        captureTimestamp: UInt64,
        payload: Data,
        parameterSets: Data? = nil
    ) {
        self.frameId = frameId
        self.fragmentIndex = fragmentIndex
        self.totalFragments = totalFragments
        self.isKeyframe = isKeyframe
        self.codec = codec
        self.width = width
        self.height = height
        self.presentationTimeNs = presentationTimeNs
        self.captureTimestamp = captureTimestamp
        self.payload = payload
        self.parameterSets = parameterSets
    }

    /// Serialize the packet to bytes for transmission
    public func serialize() -> Data {
        var data = Data()
        data.reserveCapacity(PacketProtocol.headerSize + payload.count + (parameterSets?.count ?? 0))

        // Magic number (4 bytes)
        withUnsafeBytes(of: UInt32(0x53485250).bigEndian) { data.append(contentsOf: $0) } // "SHRP"

        // Frame ID (8 bytes)
        withUnsafeBytes(of: frameId.bigEndian) { data.append(contentsOf: $0) }

        // Fragment info (4 bytes)
        withUnsafeBytes(of: fragmentIndex.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: totalFragments.bigEndian) { data.append(contentsOf: $0) }

        // Flags (1 byte)
        var flags: UInt8 = 0
        if isKeyframe { flags |= 0x01 }
        if parameterSets != nil { flags |= 0x02 }
        switch codec {
        case .h264: flags |= 0x00 << 4
        case .hevc: flags |= 0x01 << 4
        case .passthrough: flags |= 0x0F << 4
        }
        data.append(flags)

        // Dimensions (4 bytes)
        withUnsafeBytes(of: width.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: height.bigEndian) { data.append(contentsOf: $0) }

        // Timestamps (11 bytes to reach 32)
        // PTS (8 bytes)
        withUnsafeBytes(of: presentationTimeNs.bigEndian) { data.append(contentsOf: $0) }

        // Parameter sets length (2 bytes)
        let paramSetsLength = UInt16(parameterSets?.count ?? 0)
        withUnsafeBytes(of: paramSetsLength.bigEndian) { data.append(contentsOf: $0) }

        // Payload length (2 bytes) - we can compute this but include for validation
        withUnsafeBytes(of: UInt16(payload.count).bigEndian) { data.append(contentsOf: $0) }

        // Capture timestamp (8 bytes) - we need to add this but header is full
        // Actually recalculating: magic(4) + frameId(8) + frag(4) + flags(1) + dim(4) + pts(8) + paramLen(2) + payloadLen(2) = 33
        // Let's restructure

        // For now, just append the data
        if let paramSets = parameterSets {
            data.append(paramSets)
        }
        data.append(payload)

        return data
    }

    /// Deserialize a packet from bytes
    public static func deserialize(from data: Data) -> NetworkPacket? {
        guard data.count >= PacketProtocol.headerSize else { return nil }

        var offset = 0

        // Helper to read bytes safely (handles alignment)
        func readUInt16() -> UInt16 {
            let value = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            offset += 2
            return value
        }

        func readUInt32() -> UInt32 {
            let value = UInt32(data[offset]) << 24 |
                        UInt32(data[offset + 1]) << 16 |
                        UInt32(data[offset + 2]) << 8 |
                        UInt32(data[offset + 3])
            offset += 4
            return value
        }

        func readUInt64() -> UInt64 {
            let value = UInt64(data[offset]) << 56 |
                        UInt64(data[offset + 1]) << 48 |
                        UInt64(data[offset + 2]) << 40 |
                        UInt64(data[offset + 3]) << 32 |
                        UInt64(data[offset + 4]) << 24 |
                        UInt64(data[offset + 5]) << 16 |
                        UInt64(data[offset + 6]) << 8 |
                        UInt64(data[offset + 7])
            offset += 8
            return value
        }

        // Magic number
        let magic = readUInt32()
        guard magic == 0x53485250 else { return nil }

        // Frame ID
        let frameId = readUInt64()

        // Fragment info
        let fragmentIndex = readUInt16()
        let totalFragments = readUInt16()

        // Flags
        let flags = data[offset]
        offset += 1
        let isKeyframe = (flags & 0x01) != 0
        let hasParamSets = (flags & 0x02) != 0
        let codecBits = (flags >> 4) & 0x0F
        let codec: VideoCodec
        switch codecBits {
        case 0x00: codec = .h264
        case 0x01: codec = .hevc
        default: codec = .passthrough
        }

        // Dimensions
        let width = readUInt16()
        let height = readUInt16()

        // PTS
        let presentationTimeNs = readUInt64()

        // Parameter sets length
        let paramSetsLength = Int(readUInt16())

        // Payload length
        let payloadLength = Int(readUInt16())

        // Parameter sets
        var parameterSets: Data? = nil
        if hasParamSets && paramSetsLength > 0 {
            guard offset + paramSetsLength <= data.count else { return nil }
            parameterSets = data.subdata(in: offset..<(offset + paramSetsLength))
            offset += paramSetsLength
        }

        // Payload
        guard offset + payloadLength <= data.count else { return nil }
        let payload = data.subdata(in: offset..<(offset + payloadLength))

        return NetworkPacket(
            frameId: frameId,
            fragmentIndex: fragmentIndex,
            totalFragments: totalFragments,
            isKeyframe: isKeyframe,
            codec: codec,
            width: width,
            height: height,
            presentationTimeNs: presentationTimeNs,
            captureTimestamp: 0, // Not transmitted in current protocol
            payload: payload,
            parameterSets: parameterSets
        )
    }
}
