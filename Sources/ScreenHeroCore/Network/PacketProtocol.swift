import Foundation

/// Protocol for fragmenting large frames into network packets and reassembling them
/// Supports Forward Error Correction (FEC) for packet loss recovery
public struct PacketProtocol: Sendable {
    /// Maximum size of each packet payload (excluding header)
    public let maxPacketSize: Int

    /// FEC configuration
    public let fecConfig: FECConfig

    /// FEC encoder (only used on sender side)
    private let fecEncoder: FECEncoder

    /// Header size in bytes
    /// Magic(4) + FrameId(8) + FragmentInfo(4) + DataFragCount(2) + Flags(1) + Dimensions(4) + PTS(8) + CaptureTS(8) + ParamSetsLen(2) + PayloadLen(2) + FEC(4) = 47
    public static let headerSize = 47

    public init(maxPacketSize: Int = 1400, fecConfig: FECConfig = .default) {
        self.maxPacketSize = maxPacketSize
        self.fecConfig = fecConfig
        self.fecEncoder = FECEncoder(config: fecConfig)
    }

    /// Fragment a frame into network packets with FEC parity
    public func fragment(packet: EncodedPacket) -> [NetworkPacket] {
        let payloadMaxSize = maxPacketSize - Self.headerSize
        let dataFragmentCount = (packet.data.count + payloadMaxSize - 1) / payloadMaxSize

        // First, create the raw data fragments
        var rawFragments: [Data] = []
        rawFragments.reserveCapacity(dataFragmentCount)

        for i in 0..<dataFragmentCount {
            let start = i * payloadMaxSize
            let end = min(start + payloadMaxSize, packet.data.count)
            rawFragments.append(Data(packet.data[start..<end]))
        }

        // Apply FEC encoding (adds parity fragments)
        let fecFragments = fecEncoder.encode(fragments: rawFragments, frameId: packet.frameId)

        // Calculate total fragments including parity
        let totalFragments = fecFragments.count

        // Convert FEC fragments to NetworkPackets
        var networkPackets: [NetworkPacket] = []
        networkPackets.reserveCapacity(totalFragments)

        for (i, fecFrag) in fecFragments.enumerated() {
            let netPacket = NetworkPacket(
                frameId: packet.frameId,
                fragmentIndex: UInt16(i),
                totalFragments: UInt16(totalFragments),
                dataFragmentCount: UInt16(dataFragmentCount),
                isKeyframe: packet.isKeyframe,
                codec: packet.codec,
                width: UInt16(packet.width),
                height: UInt16(packet.height),
                presentationTimeNs: packet.presentationTimeNs,
                captureTimestamp: packet.captureTimestamp,
                payload: fecFrag.data,
                parameterSets: fecFrag.originalIndex == 0 && !fecFrag.isParity ? packet.parameterSets : nil,
                fecBlockIndex: fecFrag.blockIndex,
                fecIndexInBlock: fecFrag.indexInBlock,
                fecBlockDataCount: fecFrag.blockDataCount,
                isParity: fecFrag.isParity
            )
            networkPackets.append(netPacket)
        }

        return networkPackets
    }

    /// Reassemble network packets into an encoded packet with FEC recovery
    /// Returns nil if fragments are incomplete and unrecoverable
    public func reassemble(fragments: [NetworkPacket]) -> EncodedPacket? {
        guard !fragments.isEmpty else { return nil }

        let first = fragments[0]
        let dataFragmentCount = Int(first.dataFragmentCount)

        // Separate data fragments and parity fragments
        var dataFragments = [Int: NetworkPacket]()  // originalIndex -> packet
        var parityFragments = [NetworkPacket]()

        for fragment in fragments {
            guard fragment.frameId == first.frameId else { continue }

            if fragment.isParity {
                parityFragments.append(fragment)
            } else {
                // Calculate original data index from FEC info
                let originalIdx = Int(fragment.fecBlockIndex) * fecConfig.blockSize + Int(fragment.fecIndexInBlock)
                if originalIdx < dataFragmentCount {
                    dataFragments[originalIdx] = fragment
                }
            }
        }

        // Check if we have all data fragments
        if dataFragments.count == dataFragmentCount {
            // All data received, no recovery needed
            return assembleFromData(dataFragments: dataFragments, dataFragmentCount: dataFragmentCount, first: first)
        }

        // Try FEC recovery if we have parity fragments
        if fecConfig.enabled && !parityFragments.isEmpty {
            // Group fragments by FEC block
            var blocks = [UInt16: (data: [UInt8: Data], parity: [UInt8: Data], blockDataCount: UInt8)]()

            for fragment in fragments {
                let blockIdx = fragment.fecBlockIndex
                if blocks[blockIdx] == nil {
                    blocks[blockIdx] = ([:], [:], fragment.fecBlockDataCount)
                }

                if fragment.isParity {
                    let parityIdx = fragment.fecIndexInBlock - UInt8(fecConfig.blockSize)
                    blocks[blockIdx]?.parity[parityIdx] = fragment.payload
                } else {
                    blocks[blockIdx]?.data[fragment.fecIndexInBlock] = fragment.payload
                }
            }

            // Try to recover missing fragments in each block
            for (blockIdx, block) in blocks {
                let blockDataCount = Int(block.blockDataCount)
                let missingCount = blockDataCount - block.data.count

                // XOR FEC can recover 1 missing fragment per block
                if missingCount == 1 && !block.parity.isEmpty {
                    // Find missing index
                    var missingIdx: UInt8?
                    for i in 0..<blockDataCount {
                        if block.data[UInt8(i)] == nil {
                            missingIdx = UInt8(i)
                            break
                        }
                    }

                    if let missing = missingIdx, let parity = block.parity[0] {
                        // Recover: XOR parity with all received fragments
                        var recovered = parity
                        for (idx, data) in block.data {
                            if idx != missing {
                                for i in 0..<min(data.count, recovered.count) {
                                    recovered[i] ^= data[i]
                                }
                            }
                        }

                        // Trim trailing zeros
                        while recovered.count > 1 && recovered.last == 0 {
                            recovered.removeLast()
                        }

                        // Add recovered fragment to data
                        let originalIdx = Int(blockIdx) * fecConfig.blockSize + Int(missing)
                        if originalIdx < dataFragmentCount && dataFragments[originalIdx] == nil {
                            // Create a synthetic fragment for the recovered data
                            let recoveredPacket = NetworkPacket(
                                frameId: first.frameId,
                                fragmentIndex: UInt16(originalIdx),
                                totalFragments: first.totalFragments,
                                dataFragmentCount: first.dataFragmentCount,
                                isKeyframe: first.isKeyframe,
                                codec: first.codec,
                                width: first.width,
                                height: first.height,
                                presentationTimeNs: first.presentationTimeNs,
                                captureTimestamp: first.captureTimestamp,
                                payload: recovered,
                                parameterSets: originalIdx == 0 ? first.parameterSets : nil,
                                fecBlockIndex: blockIdx,
                                fecIndexInBlock: missing,
                                fecBlockDataCount: UInt8(blockDataCount),
                                isParity: false
                            )
                            dataFragments[originalIdx] = recoveredPacket
                        }
                    }
                }
            }
        }

        // Final check - do we have all data fragments now?
        if dataFragments.count == dataFragmentCount {
            return assembleFromData(dataFragments: dataFragments, dataFragmentCount: dataFragmentCount, first: first)
        }

        // Still incomplete
        return nil
    }

    /// Assemble the final packet from ordered data fragments
    private func assembleFromData(dataFragments: [Int: NetworkPacket], dataFragmentCount: Int, first: NetworkPacket) -> EncodedPacket? {
        // Combine payloads in order
        var combinedData = Data()
        combinedData.reserveCapacity(dataFragments.values.reduce(0) { $0 + $1.payload.count })

        for i in 0..<dataFragmentCount {
            guard let fragment = dataFragments[i] else { return nil }
            combinedData.append(fragment.payload)
        }

        // Get parameter sets from first data fragment
        let paramSets = dataFragments[0]?.parameterSets

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
            parameterSets: paramSets
        )
    }
}

/// A network packet (potentially a fragment of a larger frame)
/// Supports FEC (Forward Error Correction) for packet loss recovery
public struct NetworkPacket: Sendable {
    /// Frame identifier
    public let frameId: UInt64

    /// Fragment index (0-based, includes parity fragments)
    public let fragmentIndex: UInt16

    /// Total number of fragments for this frame (data + parity)
    public let totalFragments: UInt16

    /// Number of data fragments (excluding parity)
    public let dataFragmentCount: UInt16

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

    // FEC fields
    /// FEC block index within frame
    public let fecBlockIndex: UInt16

    /// Index within FEC block (0..<blockSize for data, blockSize+ for parity)
    public let fecIndexInBlock: UInt8

    /// Number of data fragments in this FEC block
    public let fecBlockDataCount: UInt8

    /// Whether this is a parity (FEC) fragment
    public let isParity: Bool

    public init(
        frameId: UInt64,
        fragmentIndex: UInt16,
        totalFragments: UInt16,
        dataFragmentCount: UInt16 = 0,
        isKeyframe: Bool,
        codec: VideoCodec,
        width: UInt16,
        height: UInt16,
        presentationTimeNs: UInt64,
        captureTimestamp: UInt64,
        payload: Data,
        parameterSets: Data? = nil,
        fecBlockIndex: UInt16 = 0,
        fecIndexInBlock: UInt8 = 0,
        fecBlockDataCount: UInt8 = 0,
        isParity: Bool = false
    ) {
        self.frameId = frameId
        self.fragmentIndex = fragmentIndex
        self.totalFragments = totalFragments
        self.dataFragmentCount = dataFragmentCount > 0 ? dataFragmentCount : totalFragments
        self.isKeyframe = isKeyframe
        self.codec = codec
        self.width = width
        self.height = height
        self.presentationTimeNs = presentationTimeNs
        self.captureTimestamp = captureTimestamp
        self.payload = payload
        self.parameterSets = parameterSets
        self.fecBlockIndex = fecBlockIndex
        self.fecIndexInBlock = fecIndexInBlock
        self.fecBlockDataCount = fecBlockDataCount
        self.isParity = isParity
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

        // Data fragment count (2 bytes) - excludes parity fragments
        withUnsafeBytes(of: dataFragmentCount.bigEndian) { data.append(contentsOf: $0) }

        // Flags (1 byte)
        var flags: UInt8 = 0
        if isKeyframe { flags |= 0x01 }
        if parameterSets != nil { flags |= 0x02 }
        if isParity { flags |= 0x04 }  // FEC parity flag
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

        // FEC info (4 bytes): blockIndex(2) + indexInBlock(1) + blockDataCount(1)
        withUnsafeBytes(of: fecBlockIndex.bigEndian) { data.append(contentsOf: $0) }
        data.append(fecIndexInBlock)
        data.append(fecBlockDataCount)

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

        // Data fragment count
        let dataFragmentCount = readUInt16()

        // Flags
        let flags = data[offset]
        offset += 1
        let isKeyframe = (flags & 0x01) != 0
        let hasParamSets = (flags & 0x02) != 0
        let isParity = (flags & 0x04) != 0  // FEC parity flag
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

        // FEC info (4 bytes)
        let fecBlockIndex = readUInt16()
        let fecIndexInBlock = data[offset]
        offset += 1
        let fecBlockDataCount = data[offset]
        offset += 1

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
            dataFragmentCount: dataFragmentCount,
            isKeyframe: isKeyframe,
            codec: codec,
            width: width,
            height: height,
            presentationTimeNs: presentationTimeNs,
            captureTimestamp: captureTimestamp,
            payload: payload,
            parameterSets: parameterSets,
            fecBlockIndex: fecBlockIndex,
            fecIndexInBlock: fecIndexInBlock,
            fecBlockDataCount: fecBlockDataCount,
            isParity: isParity
        )
    }
}
