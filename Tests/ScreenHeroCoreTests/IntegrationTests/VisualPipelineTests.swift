import XCTest
import AppKit
import CoreMedia
import CoreVideo
@testable import ScreenHeroCore

final class VisualPipelineTests: XCTestCase {

    // MARK: - Basic Display Tests

    func testSyntheticFrameDisplaysInView() async throws {
        // Create a synthetic frame source
        let config = StreamConfig(
            width: 320,
            height: 240,
            fps: 30,
            codec: .h264,
            bitrate: 1_000_000,
            keyframeInterval: 30,
            lowLatencyMode: true
        )

        let source = SyntheticFrameSource(config: config, pattern: .colorBars)

        // Create testable view
        let view = TestableVideoDisplayView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))

        // Get frames and start source
        let framesStream = await source.getFrames()
        try await source.start()

        // Process a few frames
        var frameCount = 0
        for await sampleBuffer in framesStream {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            // Run on main thread as required by AppKit
            await MainActor.run {
                view.displayPixelBuffer(pixelBuffer)
            }

            frameCount += 1
            if frameCount >= 5 {
                break
            }
        }

        await source.stop()

        // Verify the view received frames
        XCTAssertGreaterThan(view.displayCallCount, 0, "View should have received frames")
        XCTAssertGreaterThan(view.cgImageSuccessCount, 0, "CGImage creation should have succeeded")
        XCTAssertGreaterThan(view.drawCallCount, 0, "draw() should have been called")
        XCTAssertEqual(view.cgImageFailCount, 0, "CGImage creation should not have failed")
    }

    func testCapturedScreenshotIsNotBlack() async throws {
        // Create synthetic frame with colorful content
        let config = StreamConfig(
            width: 320,
            height: 240,
            fps: 30,
            codec: .h264,
            bitrate: 1_000_000,
            keyframeInterval: 30,
            lowLatencyMode: true
        )

        let source = SyntheticFrameSource(config: config, pattern: .colorBars)
        let view = TestableVideoDisplayView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))

        let framesStream = await source.getFrames()
        try await source.start()

        // Get one frame
        for await sampleBuffer in framesStream {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            await MainActor.run {
                view.displayPixelBuffer(pixelBuffer)
            }
            break
        }

        await source.stop()

        // Capture screenshot
        let screenshot = await MainActor.run {
            ScreenshotCapture.captureViewAfterRedraw(view)
        }

        XCTAssertNotNil(screenshot, "Screenshot should be captured")

        if let screenshot = screenshot {
            let analysis = ImageAnalyzer.analyze(screenshot)

            XCTAssertFalse(analysis.isBlack, "Screenshot should not be black")
            XCTAssertTrue(analysis.hasContent, "Screenshot should have visual content")
            // Width/height may be scaled on Retina displays, just check proportions
            XCTAssertGreaterThan(analysis.width, 0, "Width should be positive")
            XCTAssertGreaterThan(analysis.height, 0, "Height should be positive")
            XCTAssertGreaterThan(analysis.colorVariance, 100, "Color bars should have high variance")

            print("Screenshot analysis: avgColor=(\(analysis.averageColor)), variance=\(analysis.colorVariance)")
        }
    }

    func testDifferentPatternsProduceDifferentScreenshots() async throws {
        let config = StreamConfig(
            width: 320,
            height: 240,
            fps: 30,
            codec: .h264,
            bitrate: 1_000_000,
            keyframeInterval: 30,
            lowLatencyMode: true
        )

        var analyses: [TestPattern: ImageAnalyzer.AnalysisResult] = [:]

        for pattern in [TestPattern.colorBars, .gradient, .solidColor(red: 255, green: 0, blue: 0)] {
            let source = SyntheticFrameSource(config: config, pattern: pattern)
            let view = TestableVideoDisplayView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))

            let framesStream = await source.getFrames()
            try await source.start()

            for await sampleBuffer in framesStream {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    continue
                }

                await MainActor.run {
                    view.displayPixelBuffer(pixelBuffer)
                }
                break
            }

            await source.stop()

            if let screenshot = await MainActor.run(body: { ScreenshotCapture.captureViewAfterRedraw(view) }) {
                analyses[pattern] = ImageAnalyzer.analyze(screenshot)
            }
        }

        // Color bars and gradient should have high variance
        if let colorBars = analyses[.colorBars] {
            XCTAssertGreaterThan(colorBars.colorVariance, 100, "Color bars should have high variance")
        }

        if let gradient = analyses[.gradient] {
            XCTAssertGreaterThan(gradient.colorVariance, 100, "Gradient should have high variance")
        }

        // Solid red should have low variance but specific color
        if let solidRed = analyses[.solidColor(red: 255, green: 0, blue: 0)] {
            XCTAssertLessThan(solidRed.colorVariance, 50, "Solid color should have low variance")
            XCTAssertGreaterThan(solidRed.averageColor.r, 200, "Red channel should be high")
        }
    }

    // MARK: - Full Pipeline Tests

    func testLoopbackPipelineWithVisualVerification() async throws {
        let config = StreamConfig(
            width: 320,
            height: 240,
            fps: 30,
            codec: .h264,
            bitrate: 1_000_000,
            keyframeInterval: 30,
            lowLatencyMode: true
        )

        let source = SyntheticFrameSource(config: config, pattern: .colorBars)
        let encoder = VideoToolboxEncoder()
        let decoder = VideoToolboxDecoder()
        let transport = LoopbackTransport()
        let sender = transport.senderSide
        let receiver = transport.receiverSide

        let view = TestableVideoDisplayView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))

        try await encoder.configure(config)
        try await decoder.configure(config)
        try await sender.start()
        try await receiver.start()

        let framesStream = await source.getFrames()
        try await source.start()
        let packets = await receiver.getPackets()

        var framesEncoded = 0
        var framesDecoded = 0

        // Encoding task
        let encodeTask = Task {
            for await sampleBuffer in framesStream {
                do {
                    let encoded = try await encoder.encode(sampleBuffer)
                    try await sender.send(encoded)
                    framesEncoded += 1
                } catch {
                    print("Encode error: \(error)")
                }

                if framesEncoded >= 10 {
                    break
                }
            }
        }

        // Decoding and display
        for await packet in packets {
            do {
                let pixelBuffer = try await decoder.decode(packet)

                await MainActor.run {
                    view.displayPixelBuffer(pixelBuffer)
                }

                framesDecoded += 1
            } catch {
                print("Decode error: \(error)")
            }

            if framesDecoded >= 10 {
                break
            }
        }

        encodeTask.cancel()
        await source.stop()
        await sender.stop()
        await receiver.stop()

        // Verify frames were processed
        XCTAssertGreaterThanOrEqual(framesDecoded, 5, "Should decode at least 5 frames")

        // Verify view state
        XCTAssertGreaterThan(view.displayCallCount, 0, "View should have received frames")
        XCTAssertGreaterThan(view.cgImageSuccessCount, 0, "CGImage creation should succeed")
        XCTAssertGreaterThan(view.drawCallCount, 0, "draw() should be called")

        // Verify screenshot is not black
        if let screenshot = await MainActor.run(body: { ScreenshotCapture.captureViewAfterRedraw(view) }) {
            let analysis = ImageAnalyzer.analyze(screenshot)
            XCTAssertFalse(analysis.isBlack, "After full pipeline, screenshot should not be black")
            XCTAssertTrue(analysis.hasContent, "After full pipeline, screenshot should have content")

            print("Full pipeline screenshot: variance=\(analysis.colorVariance), avgColor=\(analysis.averageColor)")
        }
    }

    // MARK: - Edge Cases

    func testDisplayViewHandlesMultipleRapidFrames() async throws {
        let config = StreamConfig(
            width: 320,
            height: 240,
            fps: 60,
            codec: .h264,
            bitrate: 1_000_000,
            keyframeInterval: 30,
            lowLatencyMode: true
        )

        let source = SyntheticFrameSource(config: config, pattern: .animatedGradient)
        let view = TestableVideoDisplayView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))

        let framesStream = await source.getFrames()
        try await source.start()

        var frameCount = 0
        for await sampleBuffer in framesStream {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            await MainActor.run {
                view.displayPixelBuffer(pixelBuffer)
            }

            frameCount += 1
            if frameCount >= 60 {
                break
            }
        }

        await source.stop()

        // All frames should be processed without failures
        XCTAssertEqual(view.displayCallCount, 60, "All 60 frames should be processed")
        XCTAssertEqual(view.cgImageFailCount, 0, "No CGImage creation failures")
        XCTAssertGreaterThan(view.drawCallCount, 0, "draw() should be called")

        // Verify final frame is visible
        if let screenshot = await MainActor.run(body: { ScreenshotCapture.captureViewAfterRedraw(view) }) {
            XCTAssertFalse(ImageAnalyzer.isBlackScreen(screenshot), "Final frame should be visible")
        }
    }

    func testImageAnalyzerDetectsBlackScreen() {
        // Create a black image
        let width = 100
        let height = 100
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            XCTFail("Failed to create CGContext")
            return
        }

        // Fill with black
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let blackImage = context.makeImage() else {
            XCTFail("Failed to create image")
            return
        }

        XCTAssertTrue(ImageAnalyzer.isBlackScreen(blackImage), "Should detect black screen")
        XCTAssertFalse(ImageAnalyzer.hasVisualContent(blackImage), "Black screen should not have visual content")
    }

    func testImageAnalyzerDetectsColorContent() {
        let width = 100
        let height = 100
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            XCTFail("Failed to create CGContext")
            return
        }

        // Draw a gradient
        for y in 0..<height {
            for x in 0..<width {
                let r = CGFloat(x) / CGFloat(width)
                let g = CGFloat(y) / CGFloat(height)
                context.setFillColor(CGColor(red: r, green: g, blue: 0.5, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }

        guard let colorImage = context.makeImage() else {
            XCTFail("Failed to create image")
            return
        }

        XCTAssertFalse(ImageAnalyzer.isBlackScreen(colorImage), "Should not detect as black screen")
        XCTAssertTrue(ImageAnalyzer.hasVisualContent(colorImage), "Should detect visual content")
    }
}

// Extension to make TestPattern hashable for testing
extension TestPattern: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .colorBars:
            hasher.combine(0)
        case .gradient:
            hasher.combine(1)
        case .checkerboard:
            hasher.combine(2)
        case .solidColor(let r, let g, let b):
            hasher.combine(3)
            hasher.combine(r)
            hasher.combine(g)
            hasher.combine(b)
        case .animatedGradient:
            hasher.combine(4)
        }
    }

    public static func == (lhs: TestPattern, rhs: TestPattern) -> Bool {
        switch (lhs, rhs) {
        case (.colorBars, .colorBars): return true
        case (.gradient, .gradient): return true
        case (.checkerboard, .checkerboard): return true
        case (.animatedGradient, .animatedGradient): return true
        case (.solidColor(let r1, let g1, let b1), .solidColor(let r2, let g2, let b2)):
            return r1 == r2 && g1 == g2 && b1 == b2
        default: return false
        }
    }
}
