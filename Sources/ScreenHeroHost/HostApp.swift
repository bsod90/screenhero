import SwiftUI
import ScreenHeroCore
import AppKit

/// Parsed command line arguments for Host
@available(macOS 13.0, *)
struct HostCLIArgs {
    var port: UInt16 = 5000
    var autoStart: Bool = false

    static func parse() -> HostCLIArgs {
        var args = HostCLIArgs()
        let arguments = CommandLine.arguments

        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "-p", "--port":
                if i + 1 < arguments.count, let port = UInt16(arguments[i + 1]) {
                    args.port = port
                    i += 1
                }
            case "-s", "--start":
                args.autoStart = true
            case "--help":
                print("""
                ScreenHero Host

                Usage: ScreenHeroHost [options]

                Options:
                  -p, --port <port>   Port to listen on (default: 5000)
                  -s, --start         Auto-start streaming
                  --help              Show this help

                Examples:
                  ScreenHeroHost -p 5000 -s
                  ScreenHeroHost --start
                """)
                exit(0)
            default:
                break
            }
            i += 1
        }

        print("[Host] Listening on port \(args.port)")
        return args
    }
}

@available(macOS 13.0, *)
class HostAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
@available(macOS 13.0, *)
struct HostApp: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) var appDelegate
    static let cliArgs = HostCLIArgs.parse()

    var body: some Scene {
        WindowGroup {
            HostMainView(port: Self.cliArgs.port,
                        autoStart: Self.cliArgs.autoStart)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 500, height: 600)
    }
}
