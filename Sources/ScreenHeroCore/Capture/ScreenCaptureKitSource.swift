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
        streamConfig.showsCursor = true
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
        // Direct yield without Task hop - continuation.yield is thread-safe
        continuationRef?.yield(sampleBuffer)
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
    }

    /// Get available displays
    public static func availableDisplays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)

        return content.displays.map { display in
            DisplayInfo(
                displayID: display.displayID,
                width: display.width,
                height: display.height
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
    public let width: Int
    public let height: Int
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
