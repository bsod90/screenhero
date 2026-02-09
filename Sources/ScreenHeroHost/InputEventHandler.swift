import Foundation
import CoreGraphics
import AppKit
import ScreenHeroCore

/// Handles input events from remote viewer and injects them into the system
public class InputEventHandler {
    // MARK: - Properties

    /// Screen bounds for edge detection
    private let screenBounds: CGRect

    /// Current virtual mouse position
    private var currentPosition: CGPoint

    /// Margin from edge to trigger release (pixels)
    private let edgeMargin: CGFloat = 2

    /// Callback to send events back to viewer (for releaseCapture)
    private var responseSender: ((InputEvent) -> Void)?

    // MARK: - Initialization

    public init() {
        screenBounds = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        currentPosition = CGPoint(x: screenBounds.midX, y: screenBounds.midY)
    }

    /// Set the callback for sending responses back to viewer
    public func setResponseSender(_ sender: @escaping (InputEvent) -> Void) {
        responseSender = sender
    }

    // MARK: - Event Handling

    /// Handle an input event and optionally return a response event
    public func handleEvent(_ event: InputEvent) -> InputEvent? {
        // Debug log
        if event.type == .mouseMove {
            if abs(event.x) > 0.1 || abs(event.y) > 0.1 {
                print("[InputHandler] Received mouseMove: dx=\(event.x), dy=\(event.y)")
            }
        } else {
            print("[InputHandler] Received event: \(event.type)")
        }

        switch event.type {
        case .mouseMove:
            return handleMouseMove(deltaX: event.x, deltaY: event.y)

        case .mouseDown:
            injectMouseButton(event, isDown: true)
            return nil

        case .mouseUp:
            injectMouseButton(event, isDown: false)
            return nil

        case .scroll:
            injectScroll(deltaX: event.x, deltaY: event.y)
            return nil

        case .keyDown:
            injectKey(event, isDown: true)
            return nil

        case .keyUp:
            injectKey(event, isDown: false)
            return nil

        case .releaseCapture:
            // This is sent TO viewer, not handled by host
            return nil
        }
    }

    // MARK: - Mouse Movement

    private func handleMouseMove(deltaX: Float, deltaY: Float) -> InputEvent? {
        // Update position with delta
        currentPosition.x += CGFloat(deltaX)
        currentPosition.y += CGFloat(deltaY)

        // Check if cursor hit screen edge
        let hitEdge = checkEdgeHit()

        // Clamp to screen bounds
        currentPosition.x = max(0, min(screenBounds.width - 1, currentPosition.x))
        currentPosition.y = max(0, min(screenBounds.height - 1, currentPosition.y))

        // Inject the mouse move
        injectMouseMove(to: currentPosition)

        // If hit edge, tell viewer to release capture
        if hitEdge {
            print("[InputHandler] Edge hit at \(currentPosition), releasing capture")
            return InputEvent.releaseCapture()
        }

        return nil
    }

    private func checkEdgeHit() -> Bool {
        return currentPosition.x <= edgeMargin ||
               currentPosition.x >= screenBounds.width - edgeMargin ||
               currentPosition.y <= edgeMargin ||
               currentPosition.y >= screenBounds.height - edgeMargin
    }

    private func injectMouseMove(to point: CGPoint) {
        // Convert to screen coordinates (CoreGraphics uses top-left origin)
        let cgPoint = CGPoint(x: point.x, y: screenBounds.height - point.y)

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: cgPoint,
            mouseButton: .left
        ) else { return }

        event.post(tap: .cghidEventTap)
    }

    // MARK: - Mouse Buttons

    private func injectMouseButton(_ event: InputEvent, isDown: Bool) {
        let (mouseType, mouseButton) = getMouseTypeAndButton(event.button, isDown: isDown)

        // Convert to screen coordinates
        let cgPoint = CGPoint(x: currentPosition.x, y: screenBounds.height - currentPosition.y)

        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseType,
            mouseCursorPosition: cgPoint,
            mouseButton: mouseButton
        ) else { return }

        cgEvent.post(tap: .cghidEventTap)
    }

    private func getMouseTypeAndButton(_ button: InputEvent.MouseButton, isDown: Bool) -> (CGEventType, CGMouseButton) {
        switch button {
        case .left:
            return (isDown ? .leftMouseDown : .leftMouseUp, .left)
        case .right:
            return (isDown ? .rightMouseDown : .rightMouseUp, .right)
        case .middle:
            return (isDown ? .otherMouseDown : .otherMouseUp, .center)
        case .none:
            return (isDown ? .leftMouseDown : .leftMouseUp, .left)
        }
    }

    // MARK: - Scroll

    private func injectScroll(deltaX: Float, deltaY: Float) {
        // CGEvent scroll uses integer delta values
        // Multiply by scale factor for reasonable scroll speed
        let scrollX = Int32(deltaX * 3)
        let scrollY = Int32(deltaY * 3)

        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: scrollY,
            wheel2: scrollX,
            wheel3: 0
        ) else { return }

        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    private func injectKey(_ event: InputEvent, isDown: Bool) {
        guard let cgEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(event.keyCode),
            keyDown: isDown
        ) else { return }

        // Apply modifier flags
        var flags = CGEventFlags()
        if event.modifiers.contains(.shift) {
            flags.insert(.maskShift)
        }
        if event.modifiers.contains(.control) {
            flags.insert(.maskControl)
        }
        if event.modifiers.contains(.option) {
            flags.insert(.maskAlternate)
        }
        if event.modifiers.contains(.command) {
            flags.insert(.maskCommand)
        }
        cgEvent.flags = flags

        cgEvent.post(tap: .cghidEventTap)
    }

    // MARK: - Position Reset

    /// Reset mouse position to center of screen
    public func resetPosition() {
        currentPosition = CGPoint(x: screenBounds.midX, y: screenBounds.midY)
    }

    /// Get current virtual mouse position
    public var position: CGPoint {
        currentPosition
    }
}
