import Foundation
import ScreenHeroCore
import AppKit

/// Flush stdout to ensure output appears immediately
func log(_ message: String) {
    print(message)
    fflush(stdout)
}

/// Overlay window that displays a colored marker for latency measurement
/// The marker cycles through 6 colors every 100ms (600ms total cycle)
class LatencyMarkerWindow {
    private let window: NSWindow
    private let markerView: LatencyMarkerView
    private var timer: Timer?

    /// Colors for each 100ms time slot (6 colors = 600ms cycle)
    static let colors: [NSColor] = [
        NSColor(red: 1, green: 0, blue: 0, alpha: 1),     // 0-99ms: Red
        NSColor(red: 0, green: 1, blue: 0, alpha: 1),     // 100-199ms: Green
        NSColor(red: 0, green: 0, blue: 1, alpha: 1),     // 200-299ms: Blue
        NSColor(red: 1, green: 1, blue: 0, alpha: 1),     // 300-399ms: Yellow
        NSColor(red: 0, green: 1, blue: 1, alpha: 1),     // 400-499ms: Cyan
        NSColor(red: 1, green: 0, blue: 1, alpha: 1),     // 500-599ms: Magenta
    ]

    init() {
        // Create transparent overlay window at top-left corner
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        markerView = LatencyMarkerView(frame: NSRect(x: 10, y: 10, width: 100, height: 100))
        window.contentView?.addSubview(markerView)

        // Position at top-left of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            window.setFrameOrigin(NSPoint(x: screenFrame.minX, y: screenFrame.maxY - 120))
        }
    }

    func start() {
        window.orderFront(nil)
        updateMarker()

        // Update marker every 16ms (~60fps) for smooth transitions
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.updateMarker()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        window.orderOut(nil)
    }

    private func updateMarker() {
        // Use wall-clock time for cross-machine compatibility (NTP-synchronized)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let slotIndex = Int((nowMs / 100) % 6)
        markerView.currentColor = Self.colors[slotIndex]
        markerView.timestampMs = nowMs
        markerView.needsDisplay = true
    }

    /// Get the current time slot (0-5) based on current time
    static func currentSlot() -> Int {
        // Use wall-clock time for cross-machine compatibility (NTP-synchronized)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        return Int((nowMs / 100) % 6)
    }

    /// Decode latency from detected slot and current time
    static func calculateLatency(detectedSlot: Int) -> UInt64 {
        // Use wall-clock time for cross-machine compatibility (NTP-synchronized)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let currentSlot = Int((nowMs / 100) % 6)
        let offsetInSlot = nowMs % 100

        var slotDiff = currentSlot - detectedSlot
        if slotDiff < 0 { slotDiff += 6 }

        return UInt64(slotDiff) * 100 + offsetInSlot
    }
}

/// View that displays the latency marker (colored square with timestamp)
class LatencyMarkerView: NSView {
    var currentColor: NSColor = .red
    var timestampMs: UInt64 = 0

    // Pre-cached text attributes (created once, not per-frame)
    // Using monospacedDigitSystemFont for reliability and appropriate number display
    private let textAttributes: [NSAttributedString.Key: Any] = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold)
        return [
            .font: font,
            .foregroundColor: NSColor.black
        ]
    }()

    override func draw(_ dirtyRect: NSRect) {
        // Draw colored square
        currentColor.setFill()
        NSBezierPath(rect: bounds).fill()

        // Draw timestamp text for debugging
        let text = String(format: "%llu", timestampMs % 1000)
        let textSize = text.size(withAttributes: textAttributes)
        let textRect = NSRect(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: textAttributes)
    }
}

@available(macOS 14.0, *)
@main
struct HostCLI {
    static func main() async {
        let args = parseArgs()

        if args.help {
            printHelp()
            return
        }

        log("ScreenHero Host (CLI)")
        log("=====================")
        log("Port: \(args.port)")
        log("Resolution: \(args.width)x\(args.height)")
        log("FPS: \(args.fps)")
        log("Bitrate: \(args.bitrate / 1_000_000) Mbps")
        log("Codec: \(args.codec)")
        if args.fullColor {
            log("Full color mode: ENABLED (4:4:4 chroma)")
        }
        if args.latencyMarker {
            log("Latency marker: ENABLED")
        }
        log("")

        // Need to initialize NSApplication for screen capture permissions
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Start latency marker if requested
        var latencyMarker: LatencyMarkerWindow?
        if args.latencyMarker {
            latencyMarker = LatencyMarkerWindow()
            latencyMarker?.start()
            log("Latency marker overlay started")
        }

        do {
            let config = StreamConfig(
                width: args.width,
                height: args.height,
                fps: args.fps,
                codec: args.codec == "hevc" ? .hevc : .h264,
                bitrate: args.bitrate,
                keyframeInterval: args.keyframeInterval,
                lowLatencyMode: true,
                fullColorMode: args.fullColor
            )

            // Get display
            let displays = try await ScreenCaptureKitSource.availableDisplays()
            guard !displays.isEmpty else {
                log("ERROR: No displays found")
                return
            }

            let display = displays[min(args.display, displays.count - 1)]
            log("Display: \(display.width)x\(display.height) (native: \(display.nativeWidth)x\(display.nativeHeight))")

            // Use native resolution if requested
            let streamWidth = args.native ? display.nativeWidth : args.width
            let streamHeight = args.native ? display.nativeHeight : args.height
            if args.native {
                log("Using native resolution: \(streamWidth)x\(streamHeight)")
            }

            // Update config with actual resolution
            let actualConfig = StreamConfig(
                width: streamWidth,
                height: streamHeight,
                fps: config.fps,
                codec: config.codec,
                bitrate: config.bitrate,
                keyframeInterval: config.keyframeInterval,
                lowLatencyMode: config.lowLatencyMode,
                fullColorMode: config.fullColorMode
            )

            // Create components
            let source = ScreenCaptureKitSource(config: actualConfig, displayID: display.displayID)
            let encoder = VideoToolboxEncoder()
            let server = UDPStreamServer(port: args.port)

            // Create input event handler
            let inputHandler = InputEventHandler()

            // Set up input event handling on the server
            await server.setInputEventHandler { inputEvent in
                return inputHandler.handleEvent(inputEvent)
            }

            let pipeline = StreamingPipeline(
                source: source,
                encoder: encoder,
                sender: server,
                config: actualConfig
            )

            log("")
            log("Starting server on port \(args.port)...")
            try await pipeline.start()
            log("Streaming! Press Ctrl+C to stop.")
            log("")

            // Keep running
            while true {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            log("ERROR: \(error)")
        }
    }

    struct Args {
        var port: UInt16 = 5000
        var width: Int = 1920
        var height: Int = 1080
        var fps: Int = 60
        var bitrate: Int = 20_000_000
        var codec: String = "h264"
        var keyframeInterval: Int = 3  // Very frequent keyframes to survive packet loss
        var display: Int = 0
        var latencyMarker: Bool = false
        var native: Bool = false
        var fullColor: Bool = false
        var help: Bool = false
    }

    static func parseArgs() -> Args {
        var args = Args()
        let arguments = CommandLine.arguments
        var i = 1

        while i < arguments.count {
            switch arguments[i] {
            case "-p", "--port":
                if i + 1 < arguments.count, let v = UInt16(arguments[i + 1]) { args.port = v; i += 1 }
            case "-w", "--width":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { args.width = v; i += 1 }
            case "-h", "--height":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { args.height = v; i += 1 }
            case "-f", "--fps":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { args.fps = v; i += 1 }
            case "-b", "--bitrate":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { args.bitrate = v * 1_000_000; i += 1 }
            case "-c", "--codec":
                if i + 1 < arguments.count { args.codec = arguments[i + 1]; i += 1 }
            case "-k", "--keyframe":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { args.keyframeInterval = v; i += 1 }
            case "-d", "--display":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { args.display = v; i += 1 }
            case "--latency-marker":
                args.latencyMarker = true
            case "--native":
                args.native = true
            case "--full-color":
                args.fullColor = true
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
        ScreenHero Host - CLI Screen Streaming Server

        Usage: ScreenHeroHost [options]

        Options:
          -p, --port <port>       Port to listen on (default: 5000)
          -w, --width <pixels>    Stream width (default: 1920)
          -h, --height <pixels>   Stream height (default: 1080)
          -f, --fps <fps>         Frames per second (default: 60)
          -b, --bitrate <mbps>    Bitrate in Mbps (default: 20)
          -c, --codec <codec>     h264 or hevc (default: h264)
          -k, --keyframe <frames> Keyframe interval (default: 3)
          -d, --display <index>   Display index (default: 0)
          --native                Stream at display's native resolution
          --full-color            Enable 4:4:4 chroma for sharper text (needs ~2x bitrate)
          --latency-marker        Show latency measurement marker overlay
          --help                  Show this help

        Examples:
          ScreenHeroHost -p 5000 -w 1920 -h 1080 -b 20
          ScreenHeroHost --native -b 50 -c hevc
          ScreenHeroHost --full-color -b 40           # Full color mode with higher bitrate
          ScreenHeroHost -w 2560 -h 1440 -b 30 -c hevc
          ScreenHeroHost -w 3840 -h 2160 -b 50 -c hevc
        """)
    }
}
