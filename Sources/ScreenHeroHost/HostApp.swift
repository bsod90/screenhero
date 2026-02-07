import SwiftUI
import ScreenHeroCore

@main
@available(macOS 13.0, *)
struct HostApp: App {
    var body: some Scene {
        WindowGroup {
            HostMainView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 500, height: 600)
    }
}
