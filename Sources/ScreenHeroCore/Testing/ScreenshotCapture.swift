import AppKit
import CoreGraphics

/// Captures screenshots from NSView or NSWindow for testing
@MainActor
public struct ScreenshotCapture {

    /// Capture a view as a CGImage
    public static func captureView(_ view: NSView) -> CGImage? {
        guard let bitmapRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: bitmapRep)
        return bitmapRep.cgImage
    }

    /// Capture a window as a CGImage
    public static func captureWindow(_ window: NSWindow) -> CGImage? {
        guard let contentView = window.contentView else {
            return nil
        }
        return captureView(contentView)
    }

    /// Capture a view by forcing a redraw first
    public static func captureViewAfterRedraw(_ view: NSView) -> CGImage? {
        view.display()
        return captureView(view)
    }
}
