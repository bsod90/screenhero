import SwiftUI
import ScreenHeroCore

@main
struct ViewerApp: App {
    var body: some Scene {
        WindowGroup {
            ViewerMainView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
    }
}
