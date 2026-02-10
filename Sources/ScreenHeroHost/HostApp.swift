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

/// Manages the streaming session with dynamic reconfiguration support
@available(macOS 14.0, *)
actor StreamingSession {
    private let port: UInt16
    private let inputPort: UInt16
    private let displayIndex: Int
    private var currentConfig: StreamConfigData
    private var pipeline: StreamingPipeline?
    private var server: UDPStreamServer?
    private var inputServer: UDPInputServer?
    private var inputHandler: InputEventHandler?
    private var cursorTracker: CursorTracker?
    private var display: DisplayInfo?

    init(port: UInt16, inputPort: UInt16, displayIndex: Int, initialConfig: StreamConfigData) {
        self.port = port
        self.inputPort = inputPort
        self.displayIndex = displayIndex
        self.currentConfig = initialConfig
    }

    func start() async throws {
        // Get display info
        let displays = try await ScreenCaptureKitSource.availableDisplays()
        guard !displays.isEmpty else {
            throw NSError(domain: "ScreenHero", code: 1, userInfo: [NSLocalizedDescriptionKey: "No displays found"])
        }

        display = displays[min(displayIndex, displays.count - 1)]
        guard let display = display else { return }

        log("[Session] Display: \(display.width)x\(display.height) (native: \(display.nativeWidth)x\(display.nativeHeight))")

        // Update config with display info
        currentConfig.serverDisplayWidth = display.width
        currentConfig.serverDisplayHeight = display.height
        currentConfig.serverNativeWidth = display.nativeWidth
        currentConfig.serverNativeHeight = display.nativeHeight

        // Resolve native resolution if requested
        if currentConfig.useNativeResolution {
            currentConfig.width = display.nativeWidth
            currentConfig.height = display.nativeHeight
            log("[Session] Using native resolution: \(currentConfig.width)x\(currentConfig.height)")
        }

        // Create server (keeps running across config changes)
        server = UDPStreamServer(port: port, maxPacketSize: currentConfig.maxPacketSize)
        inputHandler = InputEventHandler(displayID: display.displayID)

        await server?.setInputEventHandler { [inputHandler] inputEvent in
            return inputHandler?.handleEvent(inputEvent)
        }

        // Separate input server to reduce input loss under heavy video load
        inputServer = UDPInputServer(port: inputPort)
        await inputServer?.setInputEventHandler { [inputHandler] inputEvent in
            return inputHandler?.handleEvent(inputEvent)
        }

        // Set up config change handler
        await server?.setConfigChangeHandler { [weak self] newConfig in
            guard let self = self else { return false }
            return await self.handleConfigChange(newConfig)
        }

        // Set current config on server
        await server?.setCurrentConfig(currentConfig)

        // Start server
        try await server?.start()
        try await inputServer?.start()
        log("[Session] Server started on port \(port)")
        log("[Session] Input server started on port \(inputPort)")

        // Start cursor tracking for local cursor rendering
        // Use NSScreen to get display bounds in AppKit coordinates (same as NSEvent.mouseLocation)
        // This is essential for multi-monitor setups where displays have non-zero origins
        cursorTracker = CursorTracker()
        await cursorTracker?.setUpdateHandler { [weak self] cursorEvent in
            Task {
                await self?.server?.broadcastInputEvent(cursorEvent)
            }
        }
        // Find the NSScreen matching our display ID
        let screenBounds: CGRect
        if let screen = NSScreen.screens.first(where: {
            let screenNumber = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return screenNumber == display.displayID
        }) {
            screenBounds = screen.frame
            log("[Session] Found matching NSScreen: \(screenBounds)")
        } else {
            // Fallback: use primary screen or create bounds from display dimensions
            screenBounds = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: display.width, height: display.height)
            log("[Session] WARNING: Could not find matching NSScreen, using fallback: \(screenBounds)")
        }
        await cursorTracker?.start(screenBounds: screenBounds)
        log("[Session] Cursor tracking started (display bounds: \(screenBounds))")

        // Start streaming with current config
        try await startPipeline()
    }

    private func startPipeline() async throws {
        guard let display = display, let server = server else { return }

        let streamConfig = currentConfig.toStreamConfig()

        log("[Session] Starting pipeline: \(streamConfig.width)x\(streamConfig.height) \(currentConfig.codec) \(streamConfig.bitrate/1_000_000)Mbps k=\(streamConfig.keyframeInterval)")

        let source = ScreenCaptureKitSource(config: streamConfig, displayID: display.displayID)
        let encoder = VideoToolboxEncoder()

        pipeline = StreamingPipeline(
            source: source,
            encoder: encoder,
            sender: server,
            config: streamConfig,
            manageSenderLifecycle: false  // Server is managed by session, not pipeline
        )

        try await pipeline?.start()
        log("[Session] Pipeline started")
    }

    private func stopPipeline() async {
        await pipeline?.stop()
        pipeline = nil
        log("[Session] Pipeline stopped")
    }

    func handleConfigChange(_ newConfig: StreamConfigData) async -> Bool {
        log("[Session] Config change requested:")
        log("[Session]   Resolution: \(newConfig.width)x\(newConfig.height)")
        log("[Session]   Codec: \(newConfig.codec)")
        log("[Session]   Bitrate: \(newConfig.bitrate/1_000_000) Mbps")
        log("[Session]   Keyframe: \(newConfig.keyframeInterval)")
        log("[Session]   FullColor: \(newConfig.fullColorMode)")
        log("[Session]   Native: \(newConfig.useNativeResolution)")

        // Stop current pipeline
        await stopPipeline()

        // Update config
        var updatedConfig = newConfig

        // Preserve display info
        updatedConfig.serverDisplayWidth = display?.width
        updatedConfig.serverDisplayHeight = display?.height
        updatedConfig.serverNativeWidth = display?.nativeWidth
        updatedConfig.serverNativeHeight = display?.nativeHeight

        // Handle native resolution
        if updatedConfig.useNativeResolution, let display = display {
            updatedConfig.width = display.nativeWidth
            updatedConfig.height = display.nativeHeight
            log("[Session] Resolved native resolution: \(updatedConfig.width)x\(updatedConfig.height)")
        }

        currentConfig = updatedConfig

        // Update server config
        await server?.setCurrentConfig(currentConfig)

        // Restart pipeline with new config
        do {
            try await startPipeline()
            log("[Session] Config change applied successfully")
            return true
        } catch {
            log("[Session] ERROR: Failed to apply config: \(error)")
            return false
        }
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

        log("ScreenHero Host (CLI) - Dynamic Config Enabled")
        log("=============================================")
        log("Port: \(args.port)")
        log("Initial Resolution: \(args.width)x\(args.height)")
        log("FPS: \(args.fps)")
        log("Bitrate: \(args.bitrate / 1_000_000) Mbps")
        log("Codec: \(args.codec)")
        log("Keyframe Interval: \(args.keyframeInterval)")
        if args.fullColor {
            log("Full color mode: ENABLED (4:4:4 chroma)")
        }
        if args.native {
            log("Native resolution: ENABLED")
        }
        if args.latencyMarker {
            log("Latency marker: ENABLED")
        }
        log("")
        log("Clients can change all settings dynamically!")
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
            let initialConfig = StreamConfigData(
                width: args.width,
                height: args.height,
                fps: args.fps,
                codec: args.codec,
                bitrate: args.bitrate,
                keyframeInterval: args.keyframeInterval,
                fullColorMode: args.fullColor,
                useNativeResolution: args.native,
                maxPacketSize: args.maxPacketSize
            )

            let session = StreamingSession(
                port: args.port,
                inputPort: args.inputPort ?? args.port + 1,
                displayIndex: args.display,
                initialConfig: initialConfig
            )

            try await session.start()
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
        var inputPort: UInt16? = nil
        var width: Int = 1920
        var height: Int = 1080
        var fps: Int = 60
        var bitrate: Int = 20_000_000
        var codec: String = "h264"
        var keyframeInterval: Int = 30  // 0.5s GOP at 60fps - lower burst loss on LAN
        var maxPacketSize: Int = 1400
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
            case "--input-port":
                if i + 1 < arguments.count, let v = UInt16(arguments[i + 1]) { args.inputPort = v; i += 1 }
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
            case "--packet-size", "--mtu":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { args.maxPacketSize = v; i += 1 }
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
        ScreenHero Host - CLI Screen Streaming Server (Dynamic Config)

        Usage: ScreenHeroHost [options]

        Options:
          -p, --port <port>       Port to listen on (default: 5000)
          --input-port <port>     Port for input events (default: port+1)
          -w, --width <pixels>    Initial stream width (default: 1920)
          -h, --height <pixels>   Initial stream height (default: 1080)
          -f, --fps <fps>         Frames per second (default: 60)
          -b, --bitrate <mbps>    Bitrate in Mbps (default: 20)
          -c, --codec <codec>     h264 or hevc (default: h264)
          -k, --keyframe <frames> Keyframe interval (default: 30)
          --packet-size <bytes>   Max UDP packet size (default: 1400)
          -d, --display <index>   Display index (default: 0)
          --native                Stream at display's native resolution
          --full-color            Enable 4:4:4 chroma for sharper text (needs ~2x bitrate)
          --latency-marker        Show latency measurement marker overlay
          --help                  Show this help

        Dynamic Config:
          All settings can be changed by the viewer client without restarting.
          The viewer sends its desired config on connect and can change it anytime.

        Examples:
          ScreenHeroHost -p 5000                      # Start with defaults, client controls config
          ScreenHeroHost -p 5000 -w 1920 -h 1080 -b 20
          ScreenHeroHost --native -b 50 -c hevc
          ScreenHeroHost --full-color -b 40           # Full color mode with higher bitrate
        """)
    }
}
