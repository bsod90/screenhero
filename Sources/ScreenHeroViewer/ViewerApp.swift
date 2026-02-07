import Foundation
import ScreenHeroCore
import AppKit
import CoreVideo

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
            print("ERROR: Host IP is required. Use -h <ip> to specify the host.")
            print("Run with --help for usage information.")
            return
        }

        print("ScreenHero Viewer (CLI)")
        print("=======================")
        print("Host: \(host):\(args.port)")
        print("")

        // Initialize NSApplication for window
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        // Create window for display
        let window = createWindow(width: args.width, height: args.height, fullscreen: args.fullscreen)
        let displayView = VideoDisplayView(frame: window.contentView!.bounds)
        displayView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(displayView)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        do {
            let config = StreamConfig(
                width: args.width,
                height: args.height,
                fps: 60,
                codec: .hevc,
                bitrate: 30_000_000,
                keyframeInterval: 30,
                lowLatencyMode: true
            )

            // Create UDP client that connects to the host server
            let client = UDPStreamClient(serverHost: host, serverPort: args.port)
            let decoder = VideoToolboxDecoder()

            let pipeline = ReceivingPipeline(
                receiver: client,
                decoder: decoder,
                config: config
            )

            // Set up frame handler
            await pipeline.setFrameHandler { pixelBuffer in
                await MainActor.run {
                    displayView.displayPixelBuffer(pixelBuffer)
                }
            }

            print("Connecting to \(host):\(args.port)...")
            try await pipeline.start()
            print("Connected! Press Ctrl+C to stop.")
            print("")

            // Stats printing task
            let statsTask = Task {
                var lastFrames: UInt64 = 0
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let stats = await pipeline.statistics
                    let fps = Double(stats.framesReceived - lastFrames) / 2.0
                    lastFrames = stats.framesReceived
                    print("[Stats] Frames: \(stats.framesReceived), FPS: \(String(format: "%.1f", fps)), Latency: \(String(format: "%.1f", stats.averageLatencyMs))ms, Data: \(String(format: "%.1f", stats.megabytesReceived))MB")
                }
            }

            // Run app event loop
            app.run()

            statsTask.cancel()

        } catch {
            print("ERROR: \(error)")
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
        var help: Bool = false
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
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { args.width = v; i += 1 }
            case "-H", "--height":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]) { args.height = v; i += 1 }
            case "-f", "--fullscreen":
                args.fullscreen = true
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

        Options:
          -p, --port <port>       Port number (default: 5000)
          -w, --width <pixels>    Window width (default: 1920)
          -H, --height <pixels>   Window height (default: 1080)
          -f, --fullscreen        Run in fullscreen mode
          --help                  Show this help

        Examples:
          ScreenHeroViewer -h 192.168.1.100
          ScreenHeroViewer -h 192.168.1.100 -p 5000
          ScreenHeroViewer -h 192.168.1.100 -f
        """)
    }
}

/// Simple NSView that displays CVPixelBuffer
class VideoDisplayView: NSView {
    private var currentImage: CGImage?
    private let ciContext = CIContext()

    override var isFlipped: Bool { true }

    func displayPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
            currentImage = cgImage
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
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

        context.draw(image, in: drawRect)
    }
}
