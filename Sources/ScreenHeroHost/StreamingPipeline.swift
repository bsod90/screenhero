import Foundation
import ScreenHeroCore
import CoreMedia

/// Connects frame source → encoder → network sender
@available(macOS 13.0, *)
public actor StreamingPipeline {
    private let source: any FrameSource
    private let encoder: any VideoEncoder
    private let sender: any NetworkSender
    private let config: StreamConfig

    private var isRunning = false
    private var streamTask: Task<Void, Never>?

    // Statistics
    private var framesSent: UInt64 = 0
    private var bytesSent: UInt64 = 0
    private var lastFrameTime: UInt64 = 0

    public init(
        source: any FrameSource,
        encoder: any VideoEncoder,
        sender: any NetworkSender,
        config: StreamConfig
    ) {
        self.source = source
        self.encoder = encoder
        self.sender = sender
        self.config = config
    }

    public func start() async throws {
        guard !isRunning else { return }

        // Configure encoder
        netLog("[Pipeline] Configuring encoder...")
        try await encoder.configure(config)
        netLog("[Pipeline] Encoder configured")

        // Start sender
        netLog("[Pipeline] Starting sender...")
        try await sender.start()
        netLog("[Pipeline] Sender started")

        // Start source
        netLog("[Pipeline] Starting capture source...")
        try await source.start()
        netLog("[Pipeline] Capture source started")

        isRunning = true

        // Start streaming task
        netLog("[Pipeline] Starting streaming loop...")
        streamTask = Task { [weak self] in
            await self?.runPipeline()
        }
    }

    private func runPipeline() async {
        let framesStream = await source.frames
        netLog("[Pipeline] Starting frame processing loop")

        for await sampleBuffer in framesStream {
            guard isRunning else { break }

            do {
                // Encode frame
                let packet = try await encoder.encode(sampleBuffer)

                // Send packet
                try await sender.send(packet)

                // Update statistics
                framesSent += 1
                bytesSent += UInt64(packet.data.count)
                lastFrameTime = DispatchTime.now().uptimeNanoseconds

                // Log every 60 frames (once per second at 60fps)
                if framesSent % 60 == 0 {
                    netLog("[Pipeline] Sent \(framesSent) frames, \(String(format: "%.2f", Double(bytesSent) / 1_000_000)) MB")
                }
            } catch VideoEncoderError.noImageBuffer {
                // Skip sample buffers without image data (status frames from ScreenCaptureKit)
                continue
            } catch {
                // Only log other errors occasionally to avoid spam
                if framesSent % 30 == 0 {
                    netLog("[Pipeline] Error: \(error)")
                }
            }
        }
        netLog("[Pipeline] Frame loop ended")
    }

    public func stop() async {
        isRunning = false
        streamTask?.cancel()
        streamTask = nil

        await source.stop()
        try? await encoder.flush()
        await sender.stop()
    }

    public var statistics: PipelineStatistics {
        PipelineStatistics(
            framesSent: framesSent,
            bytesSent: bytesSent,
            lastFrameTime: lastFrameTime
        )
    }
}

public struct PipelineStatistics: Sendable {
    public let framesSent: UInt64
    public let bytesSent: UInt64
    public let lastFrameTime: UInt64

    public var megabytesSent: Double {
        Double(bytesSent) / (1024 * 1024)
    }
}
