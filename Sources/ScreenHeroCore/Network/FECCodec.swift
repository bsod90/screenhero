import Foundation

/// Forward Error Correction (FEC) codec using XOR-based parity
/// Groups data fragments into blocks and generates parity fragments for recovery
///
/// With k data fragments per block and 1 parity fragment:
/// - Can recover ANY 1 lost fragment per block
/// - Overhead: 1/k (e.g., 10% for k=10)
///
/// Example: k=10, frame has 100 fragments
/// - 10 FEC blocks, each with 10 data + 1 parity = 11 fragments
/// - Total: 110 fragments sent (10% overhead)
/// - Can recover 1 lost fragment per block (up to 10 total)

public struct FECConfig: Sendable {
    /// Number of data fragments per FEC block
    public let blockSize: Int

    /// Number of parity fragments per block (currently only 1 supported)
    public let parityCount: Int

    /// Whether FEC is enabled
    public let enabled: Bool

    public init(blockSize: Int = 10, parityCount: Int = 1, enabled: Bool = true) {
        self.blockSize = max(2, blockSize)
        self.parityCount = max(1, min(parityCount, 2))  // 1-2 parity supported
        self.enabled = enabled
    }

    /// Default config: 3 data fragments + 1 parity = ~33% overhead
    /// Very small blocks handle bursty WiFi packet loss better.
    /// At 200 fragments/frame: ~67 blocks, can recover up to 67 lost fragments
    /// if distributed across different blocks.
    public static let `default` = FECConfig(blockSize: 3, parityCount: 1, enabled: true)

    /// Disabled FEC
    public static let disabled = FECConfig(enabled: false)

    /// Calculate overhead percentage
    public var overheadPercent: Double {
        guard enabled else { return 0 }
        return Double(parityCount) / Double(blockSize) * 100
    }
}

/// FEC block identifier
public struct FECBlockID: Hashable, Sendable {
    public let frameId: UInt64
    public let blockIndex: UInt16

    public init(frameId: UInt64, blockIndex: UInt16) {
        self.frameId = frameId
        self.blockIndex = blockIndex
    }
}

/// Fragment with FEC metadata
public struct FECFragment: Sendable {
    /// Original fragment data (payload only, no header)
    public let data: Data

    /// Frame this fragment belongs to
    public let frameId: UInt64

    /// Original fragment index within frame (before FEC)
    public let originalIndex: UInt16

    /// FEC block index within frame
    public let blockIndex: UInt16

    /// Index within FEC block (0..<blockSize for data, blockSize+ for parity)
    public let indexInBlock: UInt8

    /// Total data fragments in this block (may be < blockSize for last block)
    public let blockDataCount: UInt8

    /// Whether this is a parity fragment
    public let isParity: Bool

    public init(data: Data, frameId: UInt64, originalIndex: UInt16,
                blockIndex: UInt16, indexInBlock: UInt8, blockDataCount: UInt8, isParity: Bool) {
        self.data = data
        self.frameId = frameId
        self.originalIndex = originalIndex
        self.blockIndex = blockIndex
        self.indexInBlock = indexInBlock
        self.blockDataCount = blockDataCount
        self.isParity = isParity
    }
}

/// FEC Encoder - adds parity fragments to data
public final class FECEncoder: @unchecked Sendable {
    private let config: FECConfig

    public init(config: FECConfig = .default) {
        self.config = config
    }

    /// Encode fragments with FEC parity
    /// Input: array of data fragments for a single frame
    /// Output: array of FECFragments (data + parity)
    public func encode(fragments: [Data], frameId: UInt64) -> [FECFragment] {
        guard config.enabled, !fragments.isEmpty else {
            // FEC disabled - wrap fragments without parity
            return fragments.enumerated().map { index, data in
                FECFragment(
                    data: data,
                    frameId: frameId,
                    originalIndex: UInt16(index),
                    blockIndex: 0,
                    indexInBlock: UInt8(index),
                    blockDataCount: UInt8(fragments.count),
                    isParity: false
                )
            }
        }

        var result: [FECFragment] = []
        let blockSize = config.blockSize
        let numBlocks = (fragments.count + blockSize - 1) / blockSize

        for blockIdx in 0..<numBlocks {
            let startIdx = blockIdx * blockSize
            let endIdx = min(startIdx + blockSize, fragments.count)
            let blockFragments = Array(fragments[startIdx..<endIdx])
            let blockDataCount = UInt8(blockFragments.count)

            // Add data fragments with FEC metadata
            for (i, data) in blockFragments.enumerated() {
                result.append(FECFragment(
                    data: data,
                    frameId: frameId,
                    originalIndex: UInt16(startIdx + i),
                    blockIndex: UInt16(blockIdx),
                    indexInBlock: UInt8(i),
                    blockDataCount: blockDataCount,
                    isParity: false
                ))
            }

            // Generate and add parity fragment(s)
            for parityIdx in 0..<config.parityCount {
                let parityData = generateParity(fragments: blockFragments, parityIndex: parityIdx)
                result.append(FECFragment(
                    data: parityData,
                    frameId: frameId,
                    originalIndex: UInt16(startIdx),  // Reference first fragment in block
                    blockIndex: UInt16(blockIdx),
                    indexInBlock: UInt8(blockSize + parityIdx),  // Parity comes after data
                    blockDataCount: blockDataCount,
                    isParity: true
                ))
            }
        }

        return result
    }

    /// Generate XOR parity for a block of fragments
    private func generateParity(fragments: [Data], parityIndex: Int) -> Data {
        guard !fragments.isEmpty else { return Data() }

        // Find max length (all fragments should be padded to same size for XOR)
        let maxLen = fragments.map { $0.count }.max() ?? 0

        // XOR all fragments together
        var parity = Data(repeating: 0, count: maxLen)

        for fragment in fragments {
            for i in 0..<fragment.count {
                parity[i] ^= fragment[i]
            }
        }

        // For second parity (if parityCount > 1), use different combination
        // This is a simplified approach - true Reed-Solomon would be better
        if parityIndex == 1 {
            // Rotate and XOR again for diversity
            var parity2 = Data(repeating: 0, count: maxLen)
            for (idx, fragment) in fragments.enumerated() {
                let shift = (idx + 1) % 8
                for i in 0..<fragment.count {
                    let rotated = (fragment[i] << shift) | (fragment[i] >> (8 - shift))
                    parity2[i] ^= rotated
                }
            }
            return parity2
        }

        return parity
    }
}

/// FEC Decoder - recovers lost fragments using parity
public class FECDecoder {
    private let config: FECConfig

    /// Pending blocks waiting for recovery
    /// Key: FECBlockID, Value: received fragments for that block
    private var pendingBlocks: [FECBlockID: PendingBlock] = [:]

    /// Timeout for pending blocks (seconds)
    private let blockTimeout: TimeInterval = 0.5

    /// Statistics
    public private(set) var recoveredFragments: UInt64 = 0
    public private(set) var unrecoverableBlocks: UInt64 = 0

    private struct PendingBlock {
        var dataFragments: [UInt8: Data]  // indexInBlock -> data
        var parityFragments: [UInt8: Data]  // parityIndex -> data
        var blockDataCount: UInt8
        var timestamp: Date

        var receivedDataCount: Int { dataFragments.count }
        var receivedParityCount: Int { parityFragments.count }
        var missingDataCount: Int { Int(blockDataCount) - receivedDataCount }
    }

    public init(config: FECConfig = .default) {
        self.config = config
    }

    /// Process a received FEC fragment
    /// Returns recovered data fragments if any were recovered, nil otherwise
    public func processFragment(_ fragment: FECFragment) -> [RecoveredFragment]? {
        guard config.enabled else { return nil }

        let blockId = FECBlockID(frameId: fragment.frameId, blockIndex: fragment.blockIndex)

        // Initialize block if needed
        if pendingBlocks[blockId] == nil {
            pendingBlocks[blockId] = PendingBlock(
                dataFragments: [:],
                parityFragments: [:],
                blockDataCount: fragment.blockDataCount,
                timestamp: Date()
            )
        }

        // Add fragment to block
        if fragment.isParity {
            let parityIndex = fragment.indexInBlock - UInt8(config.blockSize)
            pendingBlocks[blockId]?.parityFragments[parityIndex] = fragment.data
        } else {
            pendingBlocks[blockId]?.dataFragments[fragment.indexInBlock] = fragment.data
        }

        // Check if we can recover missing fragments
        guard var block = pendingBlocks[blockId] else { return nil }

        // If we have all data fragments, no recovery needed
        if block.receivedDataCount == Int(block.blockDataCount) {
            pendingBlocks.removeValue(forKey: blockId)
            return nil
        }

        // Try to recover with XOR parity (can recover 1 missing fragment)
        if block.missingDataCount == 1 && block.receivedParityCount >= 1 {
            if let recovered = recoverFragment(block: &block, blockId: blockId) {
                pendingBlocks.removeValue(forKey: blockId)
                recoveredFragments += 1
                return [recovered]
            }
        }

        // Clean up old blocks periodically
        cleanupOldBlocks()

        return nil
    }

    /// Recover a single missing fragment using XOR parity
    private func recoverFragment(block: inout PendingBlock, blockId: FECBlockID) -> RecoveredFragment? {
        // Find the missing index
        var missingIndex: UInt8?
        for i in 0..<block.blockDataCount {
            if block.dataFragments[i] == nil {
                missingIndex = i
                break
            }
        }

        guard let missing = missingIndex,
              let parity = block.parityFragments[0] else {
            return nil
        }

        // XOR all received data fragments with parity to recover missing
        var recovered = parity

        for (idx, data) in block.dataFragments {
            if idx != missing {
                for i in 0..<min(data.count, recovered.count) {
                    recovered[i] ^= data[i]
                }
            }
        }

        // Trim trailing zeros (fragments may have been padded)
        // Note: This is a simplification - real implementation should track original sizes
        while recovered.count > 0 && recovered.last == 0 {
            recovered.removeLast()
        }

        return RecoveredFragment(
            frameId: blockId.frameId,
            blockIndex: blockId.blockIndex,
            indexInBlock: missing,
            data: recovered
        )
    }

    /// Check if a block is complete (all data received or recovered)
    public func isBlockComplete(frameId: UInt64, blockIndex: UInt16) -> Bool {
        let blockId = FECBlockID(frameId: frameId, blockIndex: blockIndex)
        guard let block = pendingBlocks[blockId] else { return true }  // Not tracked = assumed complete
        return block.receivedDataCount == Int(block.blockDataCount)
    }

    /// Get all pending fragments for a frame (for timeout handling)
    public func getPendingBlocks(forFrame frameId: UInt64) -> [UInt16] {
        pendingBlocks.keys
            .filter { $0.frameId == frameId }
            .map { $0.blockIndex }
    }

    /// Mark a block as unrecoverable and remove it
    public func markUnrecoverable(frameId: UInt64, blockIndex: UInt16) {
        let blockId = FECBlockID(frameId: frameId, blockIndex: blockIndex)
        if pendingBlocks.removeValue(forKey: blockId) != nil {
            unrecoverableBlocks += 1
        }
    }

    /// Clean up old pending blocks
    private func cleanupOldBlocks() {
        let cutoff = Date().addingTimeInterval(-blockTimeout)
        let old = pendingBlocks.filter { $0.value.timestamp < cutoff }
        for (blockId, _) in old {
            pendingBlocks.removeValue(forKey: blockId)
            unrecoverableBlocks += 1
        }
    }

    /// Reset decoder state
    public func reset() {
        pendingBlocks.removeAll()
    }
}

/// A fragment that was recovered via FEC
public struct RecoveredFragment: Sendable {
    public let frameId: UInt64
    public let blockIndex: UInt16
    public let indexInBlock: UInt8
    public let data: Data

    /// Calculate the original fragment index within the frame
    public func originalIndex(blockSize: Int) -> UInt16 {
        return UInt16(Int(blockIndex) * blockSize + Int(indexInBlock))
    }
}
