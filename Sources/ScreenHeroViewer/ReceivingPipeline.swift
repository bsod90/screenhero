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

    // Statistics
    public private(set) var framesReceived: UInt64 = 0
    public private(set) var bytesReceived: UInt64 = 0
    public private(set) var averageLatencyMs: Double = 0
    private var latencySum: Double = 0

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
        } else {
            print("Unknown receiver type")
            return
        }

        for await packet in packetsStream {
            guard isRunning else { break }

            // Insert into jitter buffer
            await jitterBuffer.insert(packet)

            // Process available frames
            await processBufferedFrames()
        }
    }

    private func processBufferedFrames() async {
        while let packet = await jitterBuffer.pop() {
            do {
                // Decode frame
                let pixelBuffer = try await decoder.decode(packet)

                // Calculate latency
                let now = DispatchTime.now().uptimeNanoseconds
                let latencyNs = now - packet.captureTimestamp
                let latencyMs = Double(latencyNs) / 1_000_000

                // Update statistics
                framesReceived += 1
                bytesReceived += UInt64(packet.data.count)
                latencySum += latencyMs
                averageLatencyMs = latencySum / Double(framesReceived)

                // Call frame handler
                await frameHandler?(pixelBuffer)

            } catch {
                print("Decode error: \(error)")
            }
        }
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
            bytesReceived: bytesReceived,
            averageLatencyMs: averageLatencyMs
        )
    }
}

public struct ReceiveStatistics: Sendable {
    public let framesReceived: UInt64
    public let bytesReceived: UInt64
    public let averageLatencyMs: Double

    public var megabytesReceived: Double {
        Double(bytesReceived) / (1024 * 1024)
    }
}
