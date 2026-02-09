import Foundation
import ScreenHeroCore
import CoreVideo

/// Connects network receiver → decoder → renderer
public actor ReceivingPipeline {
    private let receiver: any NetworkReceiver
    private let decoder: any VideoDecoder
    private let config: StreamConfig

    private var isRunning = false
    private var receiveTask: Task<Void, Never>?
    private var jitterBuffer: JitterBuffer
    private var frameHandler: (@Sendable (CVPixelBuffer) async -> Void)?
    private var frameWithTimestampHandler: (@Sendable (CVPixelBuffer, UInt64) async -> Void)?

    // Statistics
    public private(set) var framesReceived: UInt64 = 0
    public private(set) var bytesReceived: UInt64 = 0

    public init(
        receiver: any NetworkReceiver,
        decoder: any VideoDecoder,
        config: StreamConfig
    ) {
        self.receiver = receiver
        self.decoder = decoder
        self.config = config
        self.jitterBuffer = JitterBuffer()
    }

    /// Set frame handler callback
    public func setFrameHandler(_ handler: @escaping @Sendable (CVPixelBuffer) async -> Void) {
        self.frameHandler = handler
    }

    /// Set frame handler callback with capture timestamp for latency measurement
    public func setFrameHandlerWithTimestamp(_ handler: @escaping @Sendable (CVPixelBuffer, UInt64) async -> Void) {
        self.frameWithTimestampHandler = handler
    }

    public func start() async throws {
        guard !isRunning else { return }

        // Configure decoder
        try await decoder.configure(config)

        // Start receiver
        try await receiver.start()

        isRunning = true

        // Start receive task
        receiveTask = Task { [weak self] in
            await self?.runPipeline()
        }
    }

    // Track the latest decoded frame for display (newer frames replace older ones)
    private var latestFrame: CVPixelBuffer?
    private var latestFrameTimestamp: UInt64 = 0
    private var displayTask: Task<Void, Never>?
    private var framesDropped: UInt64 = 0
    private let maxDecodeAgeMs: UInt64 = 120

    private func runPipeline() async {
        // Get packets stream based on receiver type
        let packetsStream: AsyncStream<EncodedPacket>

        if let loopbackReceiver = receiver as? LoopbackReceiver {
            packetsStream = await loopbackReceiver.getPackets()
        } else if let udpReceiver = receiver as? UDPReceiver {
            packetsStream = await udpReceiver.getPackets()
        } else if let udpClient = receiver as? UDPStreamClient {
            packetsStream = await udpClient.getPackets()
        } else {
            print("Unknown receiver type: \(type(of: receiver))")
            return
        }

        netLog("[Pipeline] Starting packet processing loop (non-blocking display)")

        // Start display task that consumes latest frame
        displayTask = Task { [weak self] in
            await self?.runDisplayLoop()
        }

        for await packet in packetsStream {
            guard isRunning else { break }

            // Drop non-keyframes if we're already too far behind
            let nowNs = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
            if packet.captureTimestamp > 0, nowNs > packet.captureTimestamp {
                let ageMs = (nowNs - packet.captureTimestamp) / 1_000_000
                if ageMs > maxDecodeAgeMs && !packet.isKeyframe {
                    framesDropped += 1
                    continue
                }
            }

            // Decode immediately - no jitter buffer for lowest latency
            do {
                let pixelBuffer = try await decoder.decode(packet)

                // Update statistics
                framesReceived += 1
                bytesReceived += UInt64(packet.data.count)

                // Replace latest frame (non-blocking) - older frames are dropped
                if latestFrame != nil {
                    framesDropped += 1
                }
                latestFrame = pixelBuffer
                latestFrameTimestamp = packet.captureTimestamp

                // Log first frame and periodically
                if framesReceived == 1 {
                    netLog("[Pipeline] First frame decoded!")
                } else if framesReceived % 60 == 0 {
                    let dropRate = framesDropped > 0 ? Double(framesDropped) / Double(framesReceived) * 100 : 0
                    netLog("[Pipeline] Frames: \(framesReceived), Dropped: \(framesDropped) (\(String(format: "%.1f", dropRate))%), Data: \(String(format: "%.1f", Double(bytesReceived) / 1_000_000))MB")
                }

            } catch VideoDecoderError.waitingForKeyframe {
                // Silently wait for keyframe
                continue
            } catch {
                // Only log errors occasionally
                if framesReceived % 60 == 0 {
                    netLog("[Pipeline] Decode error: \(error)")
                }
            }
        }

        displayTask?.cancel()
        netLog("[Pipeline] Packet loop ended")
    }

    /// Separate display loop that runs independently of decode
    /// Takes the latest frame and displays it, dropping any that arrived while displaying
    private func runDisplayLoop() async {
        while isRunning {
            // Take the latest frame if available
            guard let frame = latestFrame else {
                // No frame yet, wait a bit
                try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
                continue
            }
            let timestamp = latestFrameTimestamp

            // Clear so we don't redisplay the same frame
            latestFrame = nil

            // Call frame handlers (this may block on main thread)
            await frameHandler?(frame)
            await frameWithTimestampHandler?(frame, timestamp)
        }
    }


    public func stop() async {
        isRunning = false
        receiveTask?.cancel()
        receiveTask = nil
        displayTask?.cancel()
        displayTask = nil

        await receiver.stop()
        try? await decoder.flush()
        await jitterBuffer.reset()
    }

    public var statistics: ReceiveStatistics {
        ReceiveStatistics(
            framesReceived: framesReceived,
            bytesReceived: bytesReceived
        )
    }
}

public struct ReceiveStatistics: Sendable {
    public let framesReceived: UInt64
    public let bytesReceived: UInt64

    public var megabytesReceived: Double {
        Double(bytesReceived) / (1024 * 1024)
    }
}
