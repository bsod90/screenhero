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

    /// Display bounds in CoreGraphics global coordinates (origin at top-left)
    private var screenBounds: CGRect = .zero

    public init() {}

    /// Set the callback for cursor updates
    public func setUpdateHandler(_ handler: @escaping (InputEvent) -> Void) {
        onCursorUpdate = handler
    }

    /// Track first cursor send for logging
    private var hasLoggedFirstCursor = false

    /// Start tracking cursor position.
    /// - Parameter screenBounds: The display bounds being captured (in CoreGraphics display coordinates).
    public func start(screenBounds: CGRect) {
        guard !isRunning else { return }
        isRunning = true
        self.screenBounds = screenBounds

        // Get initial position
        lastPosition = currentPointerLocation()
        print("[CursorTracker] Started with bounds: \(screenBounds)")
        print("[CursorTracker] Initial mouse position: \(lastPosition)")

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
            // Get current cursor position in CoreGraphics global coordinates.
            let globalPosition = currentPointerLocation()
            let currentType = getCurrentCursorType()

            // Check if changed
            let positionChanged = abs(globalPosition.x - lastPosition.x) > 0.5 ||
                                  abs(globalPosition.y - lastPosition.y) > 0.5
            let typeChanged = currentType != lastCursorType

            if positionChanged || typeChanged {
                lastPosition = globalPosition

                // Only send if cursor is within the captured display bounds.
                if globalPosition.x >= screenBounds.minX && globalPosition.x <= screenBounds.maxX &&
                   globalPosition.y >= screenBounds.minY && globalPosition.y <= screenBounds.maxY {
                    lastCursorType = currentType

                    // Convert to normalized top-left coordinates for the wire format.
                    let normalized = MouseCoordinateTransform.cgDisplayPointToNormalizedTopLeft(
                        globalPosition,
                        displayBounds: screenBounds
                    )

                    // Log first cursor update
                    if !hasLoggedFirstCursor {
                        print("[CursorTracker] First cursor: global=\(globalPosition), normalized=(\(String(format: "%.3f", normalized.x)), \(String(format: "%.3f", normalized.y)))")
                        hasLoggedFirstCursor = true
                    }

                    let event = InputEvent.cursorPosition(
                        x: Float(normalized.x),
                        y: Float(normalized.y),
                        cursorType: currentType
                    )

                    onCursorUpdate?(event)
                }
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

    private nonisolated func currentPointerLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
