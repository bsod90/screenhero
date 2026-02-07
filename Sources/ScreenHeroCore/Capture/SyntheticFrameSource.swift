import CoreMedia
import CoreVideo
import Foundation

/// Test pattern types for synthetic frame generation
public enum TestPattern: Sendable {
    case colorBars
    case gradient
    case checkerboard
    case solidColor(red: UInt8, green: UInt8, blue: UInt8)
    case animatedGradient
}

/// A frame source that generates synthetic test patterns
/// Useful for testing the pipeline without screen capture permissions
public actor SyntheticFrameSource: FrameSource {
    public let config: StreamConfig
    private let pattern: TestPattern

    private var isRunning = false
    private var frameCount: UInt64 = 0
    private var continuation: AsyncStream<CMSampleBuffer>.Continuation?

    private var _frames: AsyncStream<CMSampleBuffer>?

    public var frames: AsyncStream<CMSampleBuffer> {
        if let existing = _frames {
            return existing
        }
        let stream = AsyncStream<CMSampleBuffer> { continuation in
            self.continuation = continuation
        }
        _frames = stream
        return stream
    }

    public init(config: StreamConfig, pattern: TestPattern = .colorBars) {
        self.config = config
        self.pattern = pattern
    }

    /// Get the frames stream - call this before start()
    public func getFrames() -> AsyncStream<CMSampleBuffer> {
        frames
    }

    public func start() async throws {
        guard !isRunning else { return }
        isRunning = true
        frameCount = 0

        // Trigger initialization of frames stream
        _ = frames

        // Start frame generation loop
        Task { [weak self] in
            await self?.generateFrames()
        }
    }

    public func stop() async {
        isRunning = false
        continuation?.finish()
        continuation = nil
    }

    private func generateFrames() async {
        let frameDuration = 1.0 / Double(config.fps)
        let startTime = ContinuousClock.now

        while isRunning {
            let captureTimestamp = DispatchTime.now().uptimeNanoseconds

            // Create pixel buffer with test pattern
            guard let pixelBuffer = createPixelBuffer() else {
                continue
            }

            // Fill with pattern
            fillPixelBuffer(pixelBuffer, frameIndex: frameCount)

            // Create timing info
            let pts = CMTime(
                value: CMTimeValue(frameCount),
                timescale: CMTimeScale(config.fps)
            )
            let duration = CMTime(value: 1, timescale: CMTimeScale(config.fps))

            // Create sample buffer
            if let sampleBuffer = createSampleBuffer(
                from: pixelBuffer,
                pts: pts,
                duration: duration
            ) {
                continuation?.yield(sampleBuffer)
            }

            frameCount += 1

            // Calculate next frame time
            let elapsedNs = (ContinuousClock.now - startTime).components.attoseconds / 1_000_000_000
            let expectedNs = Int64(Double(frameCount) * frameDuration * 1_000_000_000)
            let sleepNs = expectedNs - Int64(elapsedNs)

            if sleepNs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sleepNs))
            }
        }
    }

    private func createPixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            config.width,
            config.height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess else {
            return nil
        }

        return pixelBuffer
    }

    private func fillPixelBuffer(_ pixelBuffer: CVPixelBuffer, frameIndex: UInt64) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = config.width
        let height = config.height

        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        switch pattern {
        case .colorBars:
            fillColorBars(buffer: buffer, width: width, height: height, bytesPerRow: bytesPerRow)

        case .gradient:
            fillGradient(buffer: buffer, width: width, height: height, bytesPerRow: bytesPerRow)

        case .checkerboard:
            fillCheckerboard(buffer: buffer, width: width, height: height, bytesPerRow: bytesPerRow, frameIndex: frameIndex)

        case .solidColor(let red, let green, let blue):
            fillSolidColor(buffer: buffer, width: width, height: height, bytesPerRow: bytesPerRow, r: red, g: green, b: blue)

        case .animatedGradient:
            fillAnimatedGradient(buffer: buffer, width: width, height: height, bytesPerRow: bytesPerRow, frameIndex: frameIndex)
        }
    }

    private func fillColorBars(buffer: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) {
        // SMPTE color bars: white, yellow, cyan, green, magenta, red, blue, black
        let colors: [(UInt8, UInt8, UInt8)] = [
            (255, 255, 255), // White
            (255, 255, 0),   // Yellow
            (0, 255, 255),   // Cyan
            (0, 255, 0),     // Green
            (255, 0, 255),   // Magenta
            (255, 0, 0),     // Red
            (0, 0, 255),     // Blue
            (0, 0, 0),       // Black
        ]

        let barWidth = width / colors.count

        for y in 0..<height {
            for x in 0..<width {
                let colorIndex = min(x / barWidth, colors.count - 1)
                let (r, g, b) = colors[colorIndex]
                let offset = y * bytesPerRow + x * 4
                buffer[offset] = b     // B
                buffer[offset + 1] = g // G
                buffer[offset + 2] = r // R
                buffer[offset + 3] = 255 // A
            }
        }
    }

    private func fillGradient(buffer: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) {
        for y in 0..<height {
            for x in 0..<width {
                let r = UInt8((x * 255) / width)
                let g = UInt8((y * 255) / height)
                let b = UInt8(128)
                let offset = y * bytesPerRow + x * 4
                buffer[offset] = b
                buffer[offset + 1] = g
                buffer[offset + 2] = r
                buffer[offset + 3] = 255
            }
        }
    }

    private func fillCheckerboard(buffer: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, frameIndex: UInt64) {
        let squareSize = 64
        let phase = Int(frameIndex / 30) % 2

        for y in 0..<height {
            for x in 0..<width {
                let isWhite = ((x / squareSize) + (y / squareSize) + phase) % 2 == 0
                let color: UInt8 = isWhite ? 255 : 0
                let offset = y * bytesPerRow + x * 4
                buffer[offset] = color
                buffer[offset + 1] = color
                buffer[offset + 2] = color
                buffer[offset + 3] = 255
            }
        }
    }

    private func fillSolidColor(buffer: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, r: UInt8, g: UInt8, b: UInt8) {
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                buffer[offset] = b
                buffer[offset + 1] = g
                buffer[offset + 2] = r
                buffer[offset + 3] = 255
            }
        }
    }

    private func fillAnimatedGradient(buffer: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, frameIndex: UInt64) {
        let phase = Double(frameIndex % 360) * .pi / 180.0

        for y in 0..<height {
            for x in 0..<width {
                let r = UInt8(127.5 + 127.5 * sin(phase + Double(x) / 100.0))
                let g = UInt8(127.5 + 127.5 * sin(phase + Double(y) / 100.0 + 2.0))
                let b = UInt8(127.5 + 127.5 * sin(phase + Double(x + y) / 200.0 + 4.0))
                let offset = y * bytesPerRow + x * 4
                buffer[offset] = b
                buffer[offset + 1] = g
                buffer[offset + 2] = r
                buffer[offset + 3] = 255
            }
        }
    }

    private func createSampleBuffer(
        from pixelBuffer: CVPixelBuffer,
        pts: CMTime,
        duration: CMTime
    ) -> CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )

        guard let formatDesc = formatDescription else {
            return nil
        }

        var timingInfo = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }
}
