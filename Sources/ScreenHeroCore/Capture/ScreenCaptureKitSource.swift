import CoreMedia
import Foundation
import ScreenCaptureKit

/// Screen capture source using ScreenCaptureKit
/// Requires screen recording permission on macOS
@available(macOS 13.0, *)
public actor ScreenCaptureKitSource: FrameSource {
    public let config: StreamConfig
    private let displayID: CGDirectDisplayID?

    private var stream: SCStream?
    private var continuation: AsyncStream<CMSampleBuffer>.Continuation?
    // Thread-safe reference for nonisolated callback access
    private nonisolated(unsafe) var continuationRef: AsyncStream<CMSampleBuffer>.Continuation?
    private var isRunning = false
    private var streamOutput: StreamOutput?
    private var _frames: AsyncStream<CMSampleBuffer>?
    // Thread-safe reference for nonisolated callback access
    private nonisolated(unsafe) var hasEmittedFirstFrame = false
    // Stats for dirty rect optimization (using lock for thread safety)
    private nonisolated(unsafe) var statsLock = NSLock()
    private nonisolated(unsafe) var _framesEmitted: UInt64 = 0
    private nonisolated(unsafe) var _framesSkipped: UInt64 = 0
    private nonisolated(unsafe) var _lastStatsTime: UInt64 = 0

    public var frames: AsyncStream<CMSampleBuffer> {
        if let existing = _frames {
            return existing
        }
        let stream = AsyncStream<CMSampleBuffer> { continuation in
            self.continuation = continuation
            self.continuationRef = continuation
        }
        _frames = stream
        return stream
    }

    /// Initialize with a specific display or the main display
    public init(config: StreamConfig, displayID: CGDirectDisplayID? = nil) {
        self.config = config
        self.displayID = displayID
    }

    /// Get the frames stream - call this before start()
    public func getFrames() -> AsyncStream<CMSampleBuffer> {
        frames
    }

    public func start() async throws {
        guard !isRunning else { return }

        // Get available content
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Find the display
        let display: SCDisplay
        if let displayID = displayID {
            guard let found = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenCaptureError.displayNotFound
            }
            display = found
        } else {
            guard let mainDisplay = content.displays.first else {
                throw ScreenCaptureError.noDisplaysAvailable
            }
            display = mainDisplay
        }

        // Create content filter
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Configure stream
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = config.width
        streamConfig.height = config.height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        // Hide cursor from capture - it will be rendered locally on the viewer
        // for smoother cursor movement even with packet loss
        streamConfig.showsCursor = false
        // Increased queue depth for 4K to prevent frame drops
        streamConfig.queueDepth = 6

        if #available(macOS 14.0, *) {
            streamConfig.captureResolution = .best
        }

        // Create stream
        stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)

        // Initialize frames stream
        _ = frames

        // Create output handler
        let output = StreamOutput { [weak self] sampleBuffer in
            self?.handleSampleBuffer(sampleBuffer)
        }
        streamOutput = output

        // Add stream output
        try stream?.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

        // Start capture
        try await stream?.startCapture()
        isRunning = true
    }

    private nonisolated func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Skip idle/blank frames to reduce unnecessary encoding.
        // Allow the first frame even if dirtyRects is empty (some displays report empty on first frame).
        let allowEmptyDirtyRects = !hasEmittedFirstFrame
        if !Self.shouldEmitFrame(sampleBuffer: sampleBuffer, allowEmptyDirtyRects: allowEmptyDirtyRects) {
            incrementSkipped()
            return
        }

        // Direct yield without Task hop - continuation.yield is thread-safe
        if !hasEmittedFirstFrame {
            hasEmittedFirstFrame = true
        }
        incrementEmitted()
        continuationRef?.yield(sampleBuffer)
    }

    private nonisolated func incrementEmitted() {
        statsLock.lock()
        _framesEmitted += 1
        logDirtyRectStatsLocked()
        statsLock.unlock()
    }

    private nonisolated func incrementSkipped() {
        statsLock.lock()
        _framesSkipped += 1
        logDirtyRectStatsLocked()
        statsLock.unlock()
    }

    private nonisolated func logDirtyRectStatsLocked() {
        let now = DispatchTime.now().uptimeNanoseconds
        // Log every 5 seconds
        if now - _lastStatsTime > 5_000_000_000 {
            _lastStatsTime = now
            let total = _framesEmitted + _framesSkipped
            if total > 0 {
                let skipRate = Double(_framesSkipped) / Double(total) * 100
                print("[DirtyRect] Emitted: \(_framesEmitted), Skipped: \(_framesSkipped) (\(String(format: "%.1f", skipRate))% saved)")
            }
        }
    }

    /// Determine whether a frame should be emitted based on ScreenCaptureKit metadata.
    /// Exposed for tests.
    static func shouldEmitFrame(sampleBuffer: CMSampleBuffer, allowEmptyDirtyRects: Bool = false) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first else {
            return true
        }
        return shouldEmitFrame(frameInfo: info, allowEmptyDirtyRects: allowEmptyDirtyRects)
    }

    static func shouldEmitFrame(frameInfo: [SCStreamFrameInfo: Any], allowEmptyDirtyRects: Bool = false) -> Bool {
        if let status = frameInfo[SCStreamFrameInfo.status] as? SCFrameStatus {
            switch status {
            case .idle, .blank, .suspended, .stopped:
                return false
            case .complete, .started:
                break
            @unknown default:
                break
            }
        }

        if let dirtyRects = frameInfo[SCStreamFrameInfo.dirtyRects] as? [NSValue] {
            if dirtyRects.isEmpty {
                return allowEmptyDirtyRects
            }
            return true
        }

        return true
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false

        try? await stream?.stopCapture()
        stream = nil
        streamOutput = nil
        continuation?.finish()
        continuation = nil
        continuationRef = nil
        hasEmittedFirstFrame = false

        // Reset stats
        statsLock.lock()
        _framesEmitted = 0
        _framesSkipped = 0
        _lastStatsTime = 0
        statsLock.unlock()
    }

    /// Get available displays
    public static func availableDisplays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)

        return content.displays.map { display in
            // Get native pixel dimensions from CoreGraphics
            let nativeWidth: Int
            let nativeHeight: Int
            if let mode = CGDisplayCopyDisplayMode(display.displayID) {
                nativeWidth = mode.pixelWidth
                nativeHeight = mode.pixelHeight
            } else {
                // Fallback: assume 2x scaling for Retina
                nativeWidth = display.width * 2
                nativeHeight = display.height * 2
            }

            return DisplayInfo(
                displayID: display.displayID,
                width: display.width,
                height: display.height,
                nativeWidth: nativeWidth,
                nativeHeight: nativeHeight
            )
        }
    }
}

/// Errors that can occur during screen capture
public enum ScreenCaptureError: Error, Sendable {
    case displayNotFound
    case noDisplaysAvailable
    case permissionDenied
    case captureStartFailed(String)
}

/// Information about an available display
public struct DisplayInfo: Sendable {
    public let displayID: CGDirectDisplayID
    /// Logical width in points (for window sizing)
    public let width: Int
    /// Logical height in points (for window sizing)
    public let height: Int
    /// Native pixel width (for streaming)
    public let nativeWidth: Int
    /// Native pixel height (for streaming)
    public let nativeHeight: Int
}

/// Stream output handler for ScreenCaptureKit
@available(macOS 13.0, *)
private class StreamOutput: NSObject, SCStreamOutput {
    private let handler: @Sendable (CMSampleBuffer) -> Void

    init(handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.handler = handler
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        handler(sampleBuffer)
    }
}
