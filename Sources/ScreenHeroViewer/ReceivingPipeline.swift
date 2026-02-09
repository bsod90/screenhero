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

        netLog("[Pipeline] Starting packet processing loop")

        for await packet in packetsStream {
            guard isRunning else { break }

            // Decode immediately - no jitter buffer for lowest latency
            do {
                let pixelBuffer = try await decoder.decode(packet)

                // Update statistics
                framesReceived += 1
                bytesReceived += UInt64(packet.data.count)

                // Log first frame and periodically
                if framesReceived == 1 {
                    netLog("[Pipeline] First frame decoded!")
                } else if framesReceived % 60 == 0 {
                    netLog("[Pipeline] Frames: \(framesReceived), Data: \(String(format: "%.1f", Double(bytesReceived) / 1_000_000))MB")
                }

                // Call frame handlers
                await frameHandler?(pixelBuffer)
                await frameWithTimestampHandler?(pixelBuffer, packet.captureTimestamp)

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

        netLog("[Pipeline] Packet loop ended")
    }


    public func stop() async {
        isRunning = false
        receiveTask?.cancel()
        receiveTask = nil

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
