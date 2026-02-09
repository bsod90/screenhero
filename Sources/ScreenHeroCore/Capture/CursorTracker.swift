import Foundation
import CoreGraphics
import AppKit

/// Tracks cursor position and type, sends updates to viewer
public actor CursorTracker {
    private var lastPosition: CGPoint = .zero
    private var lastCursorType: InputEvent.CursorType = .arrow
    private var isRunning = false
    private var updateTask: Task<Void, Never>?

    /// Callback for cursor position updates
    private var onCursorUpdate: ((InputEvent) -> Void)?

    /// Screen bounds for coordinate conversion
    private var screenBounds: CGRect = .zero

    public init() {}

    /// Set the callback for cursor updates
    public func setUpdateHandler(_ handler: @escaping (InputEvent) -> Void) {
        onCursorUpdate = handler
    }

    /// Start tracking cursor position
    public func start(screenBounds: CGRect) {
        guard !isRunning else { return }
        isRunning = true
        self.screenBounds = screenBounds

        // Get initial position
        lastPosition = NSEvent.mouseLocation

        updateTask = Task { [weak self] in
            await self?.runTrackingLoop()
        }
    }

    /// Stop tracking
    public func stop() {
        isRunning = false
        updateTask?.cancel()
        updateTask = nil
    }

    private func runTrackingLoop() async {
        while isRunning {
            // Get current cursor position
            let currentPosition = NSEvent.mouseLocation
            let currentType = getCurrentCursorType()

            // Check if changed
            let positionChanged = abs(currentPosition.x - lastPosition.x) > 0.5 ||
                                  abs(currentPosition.y - lastPosition.y) > 0.5
            let typeChanged = currentType != lastCursorType

            if positionChanged || typeChanged {
                lastPosition = currentPosition
                lastCursorType = currentType

                // Convert to screen coordinates (flip Y for top-left origin)
                let screenY = screenBounds.height - currentPosition.y

                let event = InputEvent.cursorPosition(
                    x: Float(currentPosition.x),
                    y: Float(screenY),
                    cursorType: currentType
                )

                onCursorUpdate?(event)
            }

            // Poll at 120Hz for smooth cursor tracking
            try? await Task.sleep(nanoseconds: 8_333_333)  // ~120 fps
        }
    }

    private nonisolated func getCurrentCursorType() -> InputEvent.CursorType {
        // Get current system cursor
        let cursor = NSCursor.current

        // Map to our cursor types
        if cursor == NSCursor.arrow {
            return .arrow
        } else if cursor == NSCursor.iBeam {
            return .iBeam
        } else if cursor == NSCursor.crosshair {
            return .crosshair
        } else if cursor == NSCursor.pointingHand {
            return .pointingHand
        } else if cursor == NSCursor.resizeLeftRight {
            return .resizeLeftRight
        } else if cursor == NSCursor.resizeUpDown {
            return .resizeUpDown
        }

        return .arrow
    }
}
