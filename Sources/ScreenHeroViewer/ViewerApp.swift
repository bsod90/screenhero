import SwiftUI
import ScreenHeroCore
import AppKit

/// Parsed command line arguments
struct CLIArgs {
    var host: String?
    var port: UInt16 = 5000
    var multicast: Bool = false

    static func parse() -> CLIArgs {
        var args = CLIArgs()
        let arguments = CommandLine.arguments

        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "-h", "--host":
                if i + 1 < arguments.count {
                    args.host = arguments[i + 1]
                    i += 1
                }
            case "-p", "--port":
                if i + 1 < arguments.count, let port = UInt16(arguments[i + 1]) {
                    args.port = port
                    i += 1
                }
            case "-m", "--multicast":
                args.multicast = true
            case "--help":
                print("""
                ScreenHero Viewer

                Usage: ScreenHeroViewer [options]

                Options:
                  -h, --host <ip>     Connect directly to host IP
                  -p, --port <port>   Port number (default: 5000)
                  -m, --multicast     Connect to multicast group
                  --help              Show this help

                Examples:
                  ScreenHeroViewer -h 192.168.1.100 -p 5000
                  ScreenHeroViewer --multicast
                """)
                exit(0)
            default:
                break
            }
            i += 1
        }
        return args
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activate the app and bring to front
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        NSApp.windows.first?.becomeKey()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    static let cliArgs = CLIArgs.parse()

    var body: some Scene {
        WindowGroup {
            ViewerMainView(autoConnectHost: Self.cliArgs.host,
                          autoConnectPort: Self.cliArgs.port,
                          autoConnectMulticast: Self.cliArgs.multicast)
                .onAppear {
                    // Ensure window is key and front
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.windows.first?.makeKeyAndOrderFront(nil)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
    }
}
