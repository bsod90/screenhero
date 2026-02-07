import Foundation
import ScreenHeroCore
import AppKit

@available(macOS 14.0, *)
@main
struct HostCLI {
    static func main() async {
        let args = parseArgs()

        if args.help {
            printHelp()
            return
        }

        print("ScreenHero Host (CLI)")
        print("=====================")
        print("Port: \(args.port)")
        print("Resolution: \(args.width)x\(args.height)")
        print("FPS: \(args.fps)")
        print("Bitrate: \(args.bitrate / 1_000_000) Mbps")
        print("Codec: \(args.codec)")
        print("")

        // Need to initialize NSApplication for screen capture permissions
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        do {
            let config = StreamConfig(
                width: args.width,
                height: args.height,
                fps: args.fps,
                codec: args.codec == "hevc" ? .hevc : .h264,
                bitrate: args.bitrate,
                keyframeInterval: args.keyframeInterval,
                lowLatencyMode: true
            )

            // Get display
            let displays = try await ScreenCaptureKitSource.availableDisplays()
            guard !displays.isEmpty else {
                print("ERROR: No displays found")
                return
            }

            let display = displays[min(args.display, displays.count - 1)]
            print("Display: \(display.width)x\(display.height)")

            // Create components
            let source = ScreenCaptureKitSource(config: config, displayID: display.displayID)
            let encoder = VideoToolboxEncoder()
            let server = UDPStreamServer(port: args.port)

            let pipeline = StreamingPipeline(
                source: source,
                encoder: encoder,
                sender: server,
                config: config
            )

            print("")
            print("Starting server on port \(args.port)...")
            try await pipeline.start()
            print("Streaming! Press Ctrl+C to stop.")
            print("")

            // Keep running
            while true {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            print("ERROR: \(error)")
        }
    }

    struct Args {
        var port: UInt16 = 5000
        var width: Int = 1920
        var height: Int = 1080
        var fps: Int = 60
        var bitrate: Int = 20_000_000
        var codec: String = "h264"
        var keyframeInterval: Int = 30
        var display: Int = 0
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
          -k, --keyframe <frames> Keyframe interval (default: 30)
          -d, --display <index>   Display index (default: 0)
          --help                  Show this help

        Examples:
          ScreenHeroHost -p 5000 -w 1920 -h 1080 -b 20
          ScreenHeroHost -w 2560 -h 1440 -b 30 -c hevc
          ScreenHeroHost -w 3840 -h 2160 -b 50 -c hevc
        """)
    }
}
