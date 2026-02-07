import SwiftUI
import ScreenHeroCore
import AppKit

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

    var body: some Scene {
        WindowGroup {
            HostMainView()
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
