import Foundation

/// Protocol for fragmenting large frames into network packets and reassembling them
public struct PacketProtocol: Sendable {
    /// Maximum size of each packet payload (excluding header)
    public let maxPacketSize: Int

    /// Header size in bytes
    /// Magic(4) + FrameId(8) + FragmentInfo(4) + Flags(1) + Dimensions(4) + PTS(8) + CaptureTS(8) + ParamSetsLen(2) + PayloadLen(2) = 41
    public static let headerSize = 41

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
            // Use Data slice (shares backing storage) instead of subdata (copies)
            let fragmentData = Data(packet.data[start..<end])

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
    /// Optimized: pre-allocate array and insert at index instead of sorting
    public func reassemble(fragments: [NetworkPacket]) -> EncodedPacket? {
        guard !fragments.isEmpty else { return nil }

        let first = fragments[0]
        let totalCount = Int(first.totalFragments)

        // Pre-allocate ordered array with nil placeholders
        var ordered = [NetworkPacket?](repeating: nil, count: totalCount)

        // Insert each fragment at its index position (O(n) instead of O(n log n) sort)
        for fragment in fragments {
            let idx = Int(fragment.fragmentIndex)
            guard idx < totalCount else { return nil }
            guard fragment.frameId == first.frameId else { return nil }
            ordered[idx] = fragment
        }

        // Verify completeness - all slots must be filled
        guard ordered.allSatisfy({ $0 != nil }) else { return nil }

        // Combine payloads
        var combinedData = Data()
        combinedData.reserveCapacity(ordered.reduce(0) { $0 + ($1?.payload.count ?? 0) })

        for fragment in ordered {
            combinedData.append(fragment!.payload)
        }

        // Get the first fragment (index 0) for metadata
        let firstFragment = ordered[0]!

        return EncodedPacket(
            frameId: firstFragment.frameId,
            data: combinedData,
            presentationTimeNs: firstFragment.presentationTimeNs,
            isKeyframe: firstFragment.isKeyframe,
            codec: firstFragment.codec,
            width: Int(firstFragment.width),
            height: Int(firstFragment.height),
            captureTimestamp: firstFragment.captureTimestamp,
            encodeTimestamp: DispatchTime.now().uptimeNanoseconds,
            parameterSets: firstFragment.parameterSets
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
        var data = Data(capacity: PacketProtocol.headerSize + payload.count + (parameterSets?.count ?? 0))

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

        // PTS (8 bytes)
        withUnsafeBytes(of: presentationTimeNs.bigEndian) { data.append(contentsOf: $0) }

        // Capture timestamp (8 bytes)
        withUnsafeBytes(of: captureTimestamp.bigEndian) { data.append(contentsOf: $0) }

        // Parameter sets length (2 bytes)
        let paramSetsLength = UInt16(parameterSets?.count ?? 0)
        withUnsafeBytes(of: paramSetsLength.bigEndian) { data.append(contentsOf: $0) }

        // Payload length (2 bytes)
        withUnsafeBytes(of: UInt16(payload.count).bigEndian) { data.append(contentsOf: $0) }

        // Append parameter sets and payload
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

        // Capture timestamp
        let captureTimestamp = readUInt64()

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
            captureTimestamp: captureTimestamp,
            payload: payload,
            parameterSets: parameterSets
        )
    }
}
