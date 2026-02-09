import Foundation
import ScreenHeroCore
import CoreMedia
import ScreenCaptureKit

/// Connects frame source → encoder → network sender
@available(macOS 13.0, *)
public actor StreamingPipeline {
    private let source: any FrameSource
    private let encoder: any VideoEncoder
    private let sender: any NetworkSender
    private let config: StreamConfig
    private let manageSenderLifecycle: Bool

    private var isRunning = false
    private var streamTask: Task<Void, Never>?

    // Tile encoder for partial screen updates
    private let tileEncoder = TileEncoder()

    // Track frames since last keyframe (need periodic full frames for reference)
    private var framesSinceKeyframe: UInt64 = 0
    private let maxFramesBetweenFullEncode: UInt64 = 30  // Force full encode every 30 frames

    // Statistics
    private var framesSent: UInt64 = 0
    private var bytesSent: UInt64 = 0
    private var lastFrameTime: UInt64 = 0
    private var tileUpdatesSent: UInt64 = 0
    private var fullFramesSent: UInt64 = 0

    public init(
        source: any FrameSource,
        encoder: any VideoEncoder,
        sender: any NetworkSender,
        config: StreamConfig,
        manageSenderLifecycle: Bool = true
    ) {
        self.source = source
        self.encoder = encoder
        self.sender = sender
        self.config = config
        self.manageSenderLifecycle = manageSenderLifecycle
    }

    public func start() async throws {
        guard !isRunning else { return }

        // Configure encoder
        netLog("[Pipeline] Configuring encoder...")
        try await encoder.configure(config)
        netLog("[Pipeline] Encoder configured")

        // Start sender (only if we manage its lifecycle)
        if manageSenderLifecycle {
            netLog("[Pipeline] Starting sender...")
            try await sender.start()
            netLog("[Pipeline] Sender started")
        }

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
        netLog("[Pipeline] Starting frame processing loop (tile encoding enabled)")

        for await sampleBuffer in framesStream {
            guard isRunning else { break }

            do {
                // Analyze dirty rects to decide encoding strategy
                let dirtyRects = extractDirtyRects(from: sampleBuffer)
                let frameWidth = config.width
                let frameHeight = config.height
                let analysis = tileEncoder.analyzeDirtyRects(dirtyRects, frameWidth: frameWidth, frameHeight: frameHeight)

                // Decide: tile encoding or full frame?
                // Use tile encoding only if:
                // 1. Analysis says it's beneficial
                // 2. We haven't gone too long without a full frame (need reference frames)
                let useTiles = analysis.useTileEncoding &&
                              framesSinceKeyframe < maxFramesBetweenFullEncode &&
                              framesSinceKeyframe > 0  // First frame must be full

                if useTiles {
                    // Try tile encoding
                    if let tiles = tileEncoder.encodeTiles(from: sampleBuffer, analysis: analysis) {
                        try await sender.sendTiles(tiles)

                        // Update statistics
                        let tileBytes = tiles.reduce(0) { $0 + $1.jpegData.count }
                        framesSent += 1
                        bytesSent += UInt64(tileBytes)
                        tileUpdatesSent += 1
                        framesSinceKeyframe += 1
                        lastFrameTime = DispatchTime.now().uptimeNanoseconds

                        // Log tile usage periodically
                        if tileUpdatesSent % 60 == 0 {
                            let tilePercent = Double(tileUpdatesSent) / Double(max(1, tileUpdatesSent + fullFramesSent)) * 100
                            netLog("[Pipeline] Tile updates: \(tileUpdatesSent) (\(String(format: "%.1f", tilePercent))%), dirty: \(String(format: "%.1f", analysis.dirtyPercentage * 100))%")
                        }
                        continue
                    }
                    // Fall through to full frame if tile encoding failed
                }

                // Full frame encoding
                let packet = try await encoder.encode(sampleBuffer)

                // Track keyframes for tile encoding decisions
                if packet.isKeyframe {
                    framesSinceKeyframe = 0
                    netLog("[Pipeline] KEYFRAME frame \(packet.frameId): \(packet.data.count) bytes")
                } else {
                    framesSinceKeyframe += 1
                }

                // Send packet
                try await sender.send(packet)

                // Update statistics
                framesSent += 1
                fullFramesSent += 1
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

    /// Extract dirty rects from sample buffer attachments
    private func extractDirtyRects(from sampleBuffer: CMSampleBuffer) -> [CGRect] {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let dirtyRects = info[SCStreamFrameInfo.dirtyRects] as? [NSValue] else {
            return []
        }

        return dirtyRects.map { $0.rectValue }
    }

    public func stop() async {
        isRunning = false
        streamTask?.cancel()
        streamTask = nil

        await source.stop()
        try? await encoder.flush()

        // Only stop sender if we manage its lifecycle
        if manageSenderLifecycle {
            await sender.stop()
        }
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
