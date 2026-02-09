import Foundation

/// A jitter buffer that reorders and smooths packet delivery
/// Handles out-of-order packet arrival common in UDP streaming
public actor JitterBuffer {
    /// Buffer configuration
    public struct Configuration: Sendable {
        /// Target buffer depth in milliseconds
        public let targetDepthMs: Int

        /// Maximum buffer depth in milliseconds
        public let maxDepthMs: Int

        /// Minimum buffer depth in milliseconds
        public let minDepthMs: Int

        public init(
            targetDepthMs: Int = 50,
            maxDepthMs: Int = 200,
            minDepthMs: Int = 20
        ) {
            self.targetDepthMs = targetDepthMs
            self.maxDepthMs = maxDepthMs
            self.minDepthMs = minDepthMs
        }
    }

    private let config: Configuration
    private var buffer: [UInt64: EncodedPacket] = [:]
    private var nextExpectedFrameId: UInt64 = 0
    private var lastOutputTime: UInt64 = 0
    private var isInitialized = false

    // Statistics
    private var packetsReceived: UInt64 = 0
    private var packetsDropped: UInt64 = 0
    private var packetsReordered: UInt64 = 0
    private var packetsLate: UInt64 = 0

    // Adaptive depth
    private var currentDepthMs: Int
    private var recentDelays: [Int] = []
    private let maxRecentDelays = 100

    public init(config: Configuration = Configuration()) {
        self.config = config
        self.currentDepthMs = config.targetDepthMs
    }

    /// Insert a packet into the buffer
    public func insert(_ packet: EncodedPacket) async {
        packetsReceived += 1

        // Initialize on first packet
        if !isInitialized {
            nextExpectedFrameId = packet.frameId
            isInitialized = true
        }

        // Calculate delay for adaptive buffering
        let nowNs = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let delay = Int((nowNs - packet.captureTimestamp) / 1_000_000)
        updateAdaptiveDepth(delay: delay)

        // Check if packet is too old (already output)
        if packet.frameId < nextExpectedFrameId {
            // If we haven't output anything yet, we might be receiving out of order
            // at stream start - adjust the expected ID down
            if lastOutputTime == 0 {
                nextExpectedFrameId = packet.frameId
                packetsReordered += 1
            } else {
                // Truly late packet - drop it
                packetsLate += 1
                return
            }
        }

        // Check if packet is a duplicate
        if buffer[packet.frameId] != nil {
            return
        }

        // Track reordering (packet arrived after a later packet)
        if !buffer.isEmpty {
            if let maxInBuffer = buffer.keys.max(), packet.frameId < maxInBuffer {
                packetsReordered += 1
            }
        }

        // Add to buffer
        buffer[packet.frameId] = packet

        // Limit buffer size
        pruneBuffer()
    }

    /// Get the next packet ready for display
    /// Returns nil if no packet is ready
    public func pop() async -> EncodedPacket? {
        guard isInitialized else { return nil }

        // Check if we have the next expected frame
        if let packet = buffer[nextExpectedFrameId] {
            buffer.removeValue(forKey: nextExpectedFrameId)
            nextExpectedFrameId += 1
            lastOutputTime = DispatchTime.now().uptimeNanoseconds
            return packet
        }

        // Check if we should skip ahead (too many missing frames)
        let minFrameId = buffer.keys.min()
        if let minId = minFrameId {
            let gapSize = Int(minId - nextExpectedFrameId)

            // If gap is too large or we've waited too long, skip ahead
            if gapSize > 5 || shouldSkipAhead() {
                packetsDropped += UInt64(gapSize)
                nextExpectedFrameId = minId

                if let packet = buffer[nextExpectedFrameId] {
                    buffer.removeValue(forKey: nextExpectedFrameId)
                    nextExpectedFrameId += 1
                    lastOutputTime = DispatchTime.now().uptimeNanoseconds
                    return packet
                }
            }
        }

        return nil
    }

    private func shouldSkipAhead() -> Bool {
        guard lastOutputTime > 0 else { return false }

        let timeSinceLastOutput = (DispatchTime.now().uptimeNanoseconds - lastOutputTime) / 1_000_000
        return timeSinceLastOutput > UInt64(config.maxDepthMs)
    }

    private func pruneBuffer() {
        // Remove very old packets
        let oldestAllowed = nextExpectedFrameId > 100 ? nextExpectedFrameId - 100 : 0
        buffer = buffer.filter { $0.key >= oldestAllowed }

        // If buffer is too large, drop oldest frames
        while buffer.count > 60 {
            if let minKey = buffer.keys.min() {
                buffer.removeValue(forKey: minKey)
                packetsDropped += 1
            } else {
                break
            }
        }
    }

    private func updateAdaptiveDepth(delay: Int) {
        recentDelays.append(delay)
        if recentDelays.count > maxRecentDelays {
            recentDelays.removeFirst()
        }

        // Calculate jitter (variance in delays)
        if recentDelays.count >= 10 {
            let avg = recentDelays.reduce(0, +) / recentDelays.count
            let variance = recentDelays.map { abs($0 - avg) }.reduce(0, +) / recentDelays.count

            // Adjust buffer depth based on jitter
            if variance > currentDepthMs / 2 {
                currentDepthMs = min(currentDepthMs + 5, config.maxDepthMs)
            } else if variance < currentDepthMs / 4 {
                currentDepthMs = max(currentDepthMs - 5, config.minDepthMs)
            }
        }
    }

    /// Current buffer depth in frames
    public var depth: Int {
        buffer.count
    }

    /// Current adaptive buffer depth in milliseconds
    public var currentBufferDepthMs: Int {
        currentDepthMs
    }

    /// Get statistics
    public var statistics: Statistics {
        Statistics(
            packetsReceived: packetsReceived,
            packetsDropped: packetsDropped,
            packetsReordered: packetsReordered,
            packetsLate: packetsLate,
            currentDepth: buffer.count,
            currentBufferDepthMs: currentDepthMs
        )
    }

    public struct Statistics: Sendable {
        public let packetsReceived: UInt64
        public let packetsDropped: UInt64
        public let packetsReordered: UInt64
        public let packetsLate: UInt64
        public let currentDepth: Int
        public let currentBufferDepthMs: Int

        public var dropRate: Double {
            guard packetsReceived > 0 else { return 0 }
            return Double(packetsDropped) / Double(packetsReceived)
        }
    }

    /// Reset the buffer
    public func reset() async {
        buffer.removeAll()
        nextExpectedFrameId = 0
        lastOutputTime = 0
        isInitialized = false
        packetsReceived = 0
        packetsDropped = 0
        packetsReordered = 0
        packetsLate = 0
        recentDelays.removeAll()
        currentDepthMs = config.targetDepthMs
    }
}
