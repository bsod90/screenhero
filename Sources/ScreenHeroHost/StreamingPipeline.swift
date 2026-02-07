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
        try await encoder.configure(config)

        // Start sender
        try await sender.start()

        // Start source
        try await source.start()

        isRunning = true

        // Start streaming task
        streamTask = Task { [weak self] in
            await self?.runPipeline()
        }
    }

    private func runPipeline() async {
        let framesStream = await source.frames

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
            } catch {
                print("Pipeline error: \(error)")
            }
        }
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
