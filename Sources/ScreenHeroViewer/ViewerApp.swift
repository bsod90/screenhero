import Foundation
import ScreenHeroCore
import AppKit
import CoreVideo
import Metal
import MetalKit

/// Flush stdout to ensure output appears immediately
func log(_ message: String) {
    print(message)
    fflush(stdout)
}

/// Detects latency marker in received frames and calculates end-to-end latency
class LatencyDetector {
    /// Colors for each 100ms time slot (must match LatencyMarkerWindow)
    private static let markerColors: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (255, 0, 0),     // Red
        (0, 255, 0),     // Green
        (0, 0, 255),     // Blue
        (255, 255, 0),   // Yellow
        (0, 255, 255),   // Cyan
        (255, 0, 255),   // Magenta
    ]

    // Statistics
    private var latencySamples: [UInt64] = []
    private var lastLogTime: UInt64 = 0
    private let logIntervalMs: UInt64 = 2000

    /// Detect marker in pixel buffer and calculate latency
    func detectLatency(in pixelBuffer: CVPixelBuffer) -> UInt64? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Sample center of marker region (top-left 100x100, sample at 50,50)
        // Marker is positioned at top-left with 10px padding, so sample around (60, 60)
        let sampleX = 60
        let sampleY = 60

        guard sampleX < width && sampleY < height else { return nil }

        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

        // BGRA format - each pixel is 4 bytes
        let pixelOffset = sampleY * bytesPerRow + sampleX * 4
        let b = ptr[pixelOffset]
        let g = ptr[pixelOffset + 1]
        let r = ptr[pixelOffset + 2]

        // Match to closest color
        guard let slot = matchColorToSlot(r: r, g: g, b: b) else { return nil }

        // Calculate latency using wall-clock time for cross-machine compatibility (NTP-synchronized)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let currentSlot = Int((nowMs / 100) % 6)
        let offsetInSlot = nowMs % 100

        var slotDiff = currentSlot - slot
        if slotDiff < 0 { slotDiff += 6 }

        let latencyMs = UInt64(slotDiff) * 100 + offsetInSlot
        return latencyMs
    }

    /// Record latency sample and log statistics periodically
    func recordLatency(_ latencyMs: UInt64) {
        latencySamples.append(latencyMs)

        // Keep only last 100 samples
        if latencySamples.count > 100 {
            latencySamples.removeFirst()
        }

        // Log statistics every 2 seconds
        let nowMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
        if nowMs - lastLogTime >= logIntervalMs {
            logStatistics()
            lastLogTime = nowMs
        }
    }

    private func logStatistics() {
        guard !latencySamples.isEmpty else { return }

        let sorted = latencySamples.sorted()
        let count = sorted.count
        let min = sorted.first!
        let max = sorted.last!
        let avg = sorted.reduce(0, +) / UInt64(count)
        let p99Index = Int(Double(count) * 0.99)
        let p99 = sorted[Swift.min(p99Index, count - 1)]

        log("[Latency] min=\(min)ms avg=\(avg)ms p99=\(p99)ms max=\(max)ms (n=\(count))")
    }

    private func matchColorToSlot(r: UInt8, g: UInt8, b: UInt8) -> Int? {
        // Simple threshold-based matching
        let threshold: UInt8 = 128

        let isRed = r > threshold
        let isGreen = g > threshold
        let isBlue = b > threshold

        switch (isRed, isGreen, isBlue) {
        case (true, false, false): return 0  // Red
        case (false, true, false): return 1  // Green
        case (false, false, true): return 2  // Blue
        case (true, true, false): return 3   // Yellow
        case (false, true, true): return 4   // Cyan
        case (true, false, true): return 5   // Magenta
        default: return nil
        }
    }
}

/// Logs network-based latency from capture timestamps
class NetworkLatencyLogger {
    private var latencySamples: [UInt64] = []
    private var lastLogTime: UInt64 = 0
    private let logIntervalMs: UInt64 = 2000

    func recordLatency(captureTimestamp: UInt64) {
        guard captureTimestamp > 0 else { return }

        // Use wall-clock time for cross-machine compatibility (NTP-synchronized)
        let nowNs = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let latencyMs = (nowNs - captureTimestamp) / 1_000_000

        latencySamples.append(latencyMs)

        if latencySamples.count > 100 {
            latencySamples.removeFirst()
        }

        let nowMs = nowNs / 1_000_000
        if nowMs - lastLogTime >= logIntervalMs {
            logStatistics()
            lastLogTime = nowMs
        }
    }

    private func logStatistics() {
        guard !latencySamples.isEmpty else { return }

        let sorted = latencySamples.sorted()
        let count = sorted.count
        let min = sorted.first!
        let max = sorted.last!
        let avg = sorted.reduce(0, +) / UInt64(count)
        let p99Index = Int(Double(count) * 0.99)
        let p99 = sorted[Swift.min(p99Index, count - 1)]

        log("[Network Latency] min=\(min)ms avg=\(avg)ms p99=\(p99)ms max=\(max)ms (n=\(count))")
    }
}

@available(macOS 14.0, *)
@main
struct ViewerCLI {
    static func main() async {
        let args = parseArgs()

        if args.help {
            printHelp()
            return
        }

        guard let host = args.host else {
            log("ERROR: Host IP is required. Use -h <ip> to specify the host.")
            log("Run with --help for usage information.")
            return
        }

        log("ScreenHero Viewer (CLI)")
        log("=======================")
        log("Host: \(host):\(args.port)")
        log("")
        log("Requested Stream Config:")
        log("  Resolution: \(args.streamWidth)x\(args.streamHeight)\(args.native ? " (native)" : "")")
        log("  FPS: \(args.fps)")
        log("  Bitrate: \(args.bitrate / 1_000_000) Mbps")
        log("  Codec: \(args.codec)")
        log("  Keyframe: \(args.keyframeInterval)")
        if args.fullColor {
            log("  Full color: ENABLED (4:4:4 chroma)")
        }
        if args.measureLatency {
            log("Latency measurement: ENABLED")
        }
        if args.enableInput {
            log("Input capture: ENABLED (click to capture, Escape to release)")
        }
        log("")

        // Initialize NSApplication for window
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        // Create window for display
        let window = createWindow(width: args.width, height: args.height, fullscreen: args.fullscreen)

        // Use Metal-based zero-copy rendering for lower latency
        let metalView = MetalVideoDisplayView(frame: window.contentView!.bounds)

        // Create input capture view (wraps the metal view)
        let inputCaptureView = InputCaptureView(frame: window.contentView!.bounds, videoView: metalView)
        inputCaptureView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(inputCaptureView)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(inputCaptureView)
        app.activate(ignoringOtherApps: true)

        do {
            // Decoder config (uses stream params from server)
            let config = StreamConfig(
                width: args.streamWidth,
                height: args.streamHeight,
                fps: args.fps,
                codec: args.codec == "hevc" ? .hevc : .h264,
                bitrate: args.bitrate,
                keyframeInterval: args.keyframeInterval,
                lowLatencyMode: true,
                maxPacketSize: args.maxPacketSize
            )

            // Create UDP client that connects to the host server
            let client = UDPStreamClient(
                serverHost: host,
                serverPort: args.port,
                maxPacketSize: args.maxPacketSize
            )

            // Set the config we want from the server
            let requestedConfig = StreamConfigData(
                width: args.streamWidth,
                height: args.streamHeight,
                fps: args.fps,
                codec: args.codec,
                bitrate: args.bitrate,
                keyframeInterval: args.keyframeInterval,
                fullColorMode: args.fullColor,
                useNativeResolution: args.native,
                maxPacketSize: args.maxPacketSize
            )
            await client.setRequestedConfig(requestedConfig)

            // Log when server confirms config and set remote screen dimensions
            await client.setConfigHandler { serverConfig in
                log("[Config] Server confirmed: \(serverConfig.width)x\(serverConfig.height) \(serverConfig.codec) \(serverConfig.bitrate/1_000_000)Mbps k=\(serverConfig.keyframeInterval)")

                // Set remote screen dimensions for cursor coordinate mapping
                // Use logical display dimensions (points), not native pixels, because
                // cursor positions are sent in logical coordinates
                if let displayWidth = serverConfig.serverDisplayWidth,
                   let displayHeight = serverConfig.serverDisplayHeight {
                    log("[Config] Remote display: \(displayWidth)x\(displayHeight) (logical)")
                    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                        inputCaptureView.setRemoteScreenSize(width: displayWidth, height: displayHeight)
                    }
                    CFRunLoopWakeUp(CFRunLoopGetMain())
                }
            }

            // Handle cursor position events from host (sent via main video connection)
            await client.setInputEventHandler { inputEvent in
                if inputEvent.type == .cursorPosition {
                    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                        inputCaptureView.updateCursorPosition(inputEvent)
                    }
                    CFRunLoopWakeUp(CFRunLoopGetMain())
                }
            }

            let decoder = VideoToolboxDecoder()

            let pipeline = ReceivingPipeline(
                receiver: client,
                decoder: decoder,
                config: config
            )

            // Set up frame handler using CFRunLoopPerformBlock for guaranteed execution with app.run()
            await pipeline.setFrameHandler { pixelBuffer in
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                    inputCaptureView.displayPixelBuffer(pixelBuffer)
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }

            // Set up input capture if enabled
            if args.enableInput {
                // Separate UDP input channel to avoid video congestion
                let inputPort = args.inputPort ?? args.port + 1
                log("[Input] Connecting to input server at \(host):\(inputPort)...")
                let inputClient = UDPInputClient(serverHost: host, serverPort: inputPort)
                try await inputClient.start()
                log("[Input] Connected to input server!")

                // Enable input capture with sender callback
                log("[Input] Setting up input sender callback")
                inputCaptureView.enableInput { inputEvent in
                    // Log all events for debugging
                    if inputEvent.type == .mouseMove {
                        // Only log first few mouse moves to avoid spam
                        struct MoveCounter { static var count = 0 }
                        MoveCounter.count += 1
                        if MoveCounter.count <= 3 {
                            log("[Input] Callback: mouseMove dx=\(inputEvent.x) dy=\(inputEvent.y)")
                        }
                    } else {
                        log("[Input] Callback: \(inputEvent.type)")
                    }
                    Task {
                        await inputClient.sendInputEvent(inputEvent)
                    }
                }

                // Handle releaseCapture events from host
                await inputClient.setInputEventHandler { inputEvent in
                    if inputEvent.type == .releaseCapture {
                        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                            inputCaptureView.handleReleaseCaptureFromHost()
                        }
                        CFRunLoopWakeUp(CFRunLoopGetMain())
                    }
                }
            }

            // Set up latency measurement if enabled
            let visualLatencyDetector = args.measureLatency ? LatencyDetector() : nil
            let networkLatencyLogger = args.measureLatency ? NetworkLatencyLogger() : nil

            if args.measureLatency {
                await pipeline.setFrameHandlerWithTimestamp { pixelBuffer, captureTimestamp in
                    // Log network-based latency
                    networkLatencyLogger?.recordLatency(captureTimestamp: captureTimestamp)

                    // Detect visual marker latency
                    if let latencyMs = visualLatencyDetector?.detectLatency(in: pixelBuffer) {
                        visualLatencyDetector?.recordLatency(latencyMs)
                    }
                }
            }

            log("Connecting to \(host):\(args.port)...")
            try await pipeline.start()
            log("Connected! Press Ctrl+C to stop.")
            log("")

            // Stats printing task
            let statsTask = Task {
                var lastFrames: UInt64 = 0
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let stats = await pipeline.statistics
                    let fps = Double(stats.framesReceived - lastFrames) / 2.0
                    lastFrames = stats.framesReceived
                    log("[Stats] Frames: \(stats.framesReceived), FPS: \(String(format: "%.1f", fps)), Data: \(String(format: "%.1f", stats.megabytesReceived))MB")
                }
            }

            // Run app event loop
            app.run()

            statsTask.cancel()

        } catch {
            log("ERROR: \(error)")
        }
    }

    static func createWindow(width: Int, height: Int, fullscreen: Bool) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: fullscreen ? [.borderless] : [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScreenHero Viewer"
        window.center()
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.acceptsMouseMovedEvents = true  // Required for mouse capture

        if fullscreen {
            window.level = .mainMenu + 1
            window.setFrame(NSScreen.main!.frame, display: true)
        }

        return window
    }

    struct Args {
        var host: String?
        var port: UInt16 = 5000
        var width: Int = 1920
        var height: Int = 1080
        var fullscreen: Bool = false
        var measureLatency: Bool = false
        var enableInput: Bool = false
        var help: Bool = false
        // Stream config options (sent to server)
        // Defaults optimized for reliable streaming over lossy networks:
        // - 1080p is a good balance of quality and keyframe size
        // - 8Mbps keeps keyframes at ~35-50KB (25-36 fragments)
        // - k=1 (every frame is keyframe) means any lost frame is recoverable
        var streamWidth: Int = 1920
        var streamHeight: Int = 1080
        var fps: Int = 60
        var bitrate: Int = 8_000_000  // 8Mbps - good quality, small keyframes
        var codec: String = "h264"
        var keyframeInterval: Int = 30  // 0.5s GOP at 60fps - lower burst loss on LAN
        var fullColor: Bool = false
        var native: Bool = false
        var maxPacketSize: Int = 1400
        var inputPort: UInt16? = nil
    }

    static func parseArgs() -> Args {
        var args = Args()
        let arguments = CommandLine.arguments
        var i = 1

        while i < arguments.count {
            switch arguments[i] {
            case "-h", "--host":
                if i + 1 < arguments.count { args.host = arguments[i + 1]; i += 1 }
            case "-p", "--port":
                if i + 1 < arguments.count, let v = UInt16(arguments[i + 1]) { args.port = v; i += 1 }
            case "-w", "--width":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { args.width = v; args.streamWidth = v; i += 1 }
            case "-H", "--height":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { args.height = v; args.streamHeight = v; i += 1 }
            case "-f", "--fullscreen":
                args.fullscreen = true
            case "--measure-latency":
                args.measureLatency = true
            case "--enable-input":
                args.enableInput = true
            // Stream config options
            case "-sw", "--stream-width":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { args.streamWidth = v; i += 1 }
            case "-sh", "--stream-height":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { args.streamHeight = v; i += 1 }
            case "--fps":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { args.fps = v; i += 1 }
            case "-b", "--bitrate":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { args.bitrate = v * 1_000_000; i += 1 }
            case "-c", "--codec":
                if i + 1 < arguments.count { args.codec = arguments[i + 1]; i += 1 }
            case "-k", "--keyframe":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { args.keyframeInterval = v; i += 1 }
            case "--full-color":
                args.fullColor = true
            case "--native":
                args.native = true
            case "--packet-size", "--mtu":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { args.maxPacketSize = v; i += 1 }
            case "--input-port":
                if i + 1 < arguments.count, let v = UInt16(arguments[i + 1]) { args.inputPort = v; i += 1 }
            case "--help":
                args.help = true
            default:
                break
            }
            i += 1
        }
        return args
    }

    static func printHelp() {
        print("""
        ScreenHero Viewer - CLI Screen Streaming Client

        Usage: ScreenHeroViewer -h <host> [options]

        Required:
          -h, --host <ip>         Host IP address to connect to

        Window Options:
          -p, --port <port>       Port number (default: 5000)
          -w, --width <pixels>    Window width (default: 1920)
          -H, --height <pixels>   Window height (default: 1080)
          -f, --fullscreen        Run in fullscreen mode

        Stream Config (sent to server - controls remote streaming):
          -sw, --stream-width <px>  Stream width (default: 1920)
          -sh, --stream-height <px> Stream height (default: 1080)
          --fps <fps>              Frames per second (default: 60)
          -b, --bitrate <mbps>     Bitrate in Mbps (default: 8)
          -c, --codec <codec>      h264 or hevc (default: h264)
          -k, --keyframe <frames>  Keyframe interval (default: 30)
          --full-color             Enable 4:4:4 chroma for sharper text
          --native                 Use server's native display resolution
          --packet-size <bytes>    Max UDP packet size (default: 1400)
          --input-port <port>      UDP port for input events (default: port+1 when input enabled)

        Other Options:
          --enable-input          Enable mouse/keyboard capture and streaming
          --measure-latency       Enable latency measurement (use with host --latency-marker)
          --help                  Show this help

        Input Capture (when --enable-input is used):
          - Click inside window to capture mouse
          - Press Escape to release mouse (always works)
          - Moving mouse to screen edge on host releases capture

        Examples:
          ScreenHeroViewer -h 192.168.1.100                     # 1080p@8Mbps (reliable)
          ScreenHeroViewer -h 192.168.1.100 -b 15 -k 3          # Higher quality
          ScreenHeroViewer -h 192.168.1.100 --native -b 20      # Native resolution
          ScreenHeroViewer -h 192.168.1.100 --enable-input      # With input capture
          ScreenHeroViewer -h 192.168.1.100 -f                  # Fullscreen
        """)
    }
}

/// Simple NSView that displays CVPixelBuffer
class VideoDisplayView: NSView {
    private var currentImage: CGImage?
    private let ciContext = CIContext()

    // Debug counters
    private var displayCallCount: UInt64 = 0
    private var cgImageSuccessCount: UInt64 = 0
    private var cgImageFailCount: UInt64 = 0
    private var drawCallCount: UInt64 = 0

    override var isFlipped: Bool { true }

    func displayPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        displayCallCount += 1

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
            cgImageSuccessCount += 1
            currentImage = cgImage

            if cgImageSuccessCount == 1 {
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                log("[Display] First frame displayed: \(width)x\(height)")
            }

            // Force immediate redraw
            display()
        } else {
            cgImageFailCount += 1
            if cgImageFailCount == 1 {
                log("[Display] CGImage creation FAILED")
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCallCount += 1

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Fill with black
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)

        // Draw image
        guard let image = currentImage else { return }

        let imageSize = CGSize(width: image.width, height: image.height)
        let viewSize = bounds.size

        // Calculate aspect-fit rect
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height

        var drawRect: CGRect
        if imageAspect > viewAspect {
            // Image is wider - fit to width
            let height = viewSize.width / imageAspect
            drawRect = CGRect(x: 0, y: (viewSize.height - height) / 2, width: viewSize.width, height: height)
        } else {
            // Image is taller - fit to height
            let width = viewSize.height * imageAspect
            drawRect = CGRect(x: (viewSize.width - width) / 2, y: 0, width: width, height: viewSize.height)
        }

        // Fix vertical flip: isFlipped=true puts origin at top-left, but CGContext.draw()
        // expects origin at bottom-left. Apply vertical flip transform.
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: drawRect)
        context.restoreGState()
    }
}
