import Foundation
import CoreGraphics
import AppKit
import ScreenHeroCore

/// Handles input events from remote viewer and injects them into the system
public class InputEventHandler {
    // MARK: - Properties

    /// Screen bounds for edge detection (in CoreGraphics coordinates - origin at top-left)
    private let screenBounds: CGRect

    /// Current virtual mouse position (in CG coordinates - origin at top-left)
    private var currentPosition: CGPoint

    /// Margin from edge to trigger release (pixels)
    private let edgeMargin: CGFloat = 2

    /// Callback to send events back to viewer (for releaseCapture)
    private var responseSender: ((InputEvent) -> Void)?

    /// Whether we've logged the first event (to avoid spam)
    private var hasLoggedFirstEvent = false

    // MARK: - Initialization

    public init(displayID: CGDirectDisplayID? = nil) {
        // Get display bounds in CoreGraphics coordinates
        let targetDisplayID = displayID ?? CGMainDisplayID()
        let displayBounds = CGDisplayBounds(targetDisplayID)
        screenBounds = displayBounds

        // Start at center of screen
        currentPosition = CGPoint(x: displayBounds.midX, y: displayBounds.midY)

        print("[InputHandler] Initialized for display \(targetDisplayID)")
        print("[InputHandler] Screen bounds: \(screenBounds)")
        print("[InputHandler] Starting position: \(currentPosition)")

        // Check accessibility permissions
        checkAccessibilityPermissions()
    }

    private func checkAccessibilityPermissions() {
        let trusted = AXIsProcessTrusted()
        if trusted {
            print("[InputHandler] Accessibility permissions: GRANTED")
        } else {
            print("[InputHandler] WARNING: Accessibility permissions NOT granted!")
            print("[InputHandler] Mouse/keyboard injection will NOT work.")
            print("[InputHandler] Please grant accessibility permissions in:")
            print("[InputHandler]   System Settings → Privacy & Security → Accessibility")

            // Prompt for permissions
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
    }

    /// Set the callback for sending responses back to viewer
    public func setResponseSender(_ sender: @escaping (InputEvent) -> Void) {
        responseSender = sender
    }

    // MARK: - Event Handling

    /// Handle an input event and optionally return a response event
    public func handleEvent(_ event: InputEvent) -> InputEvent? {
        // Debug log for all non-move events, and periodic move events
        if event.type == .mouseMove {
            // Log mouse moves periodically to avoid spam
            if !hasLoggedFirstEvent || (abs(event.x) > 5 || abs(event.y) > 5) {
                print("[InputHandler] mouseMove: dx=\(event.x), dy=\(event.y) -> pos=(\(currentPosition.x + CGFloat(event.x)), \(currentPosition.y + CGFloat(event.y)))")
                hasLoggedFirstEvent = true
            }
        } else {
            print("[InputHandler] EVENT: \(event.type) at pos=\(currentPosition)")
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

        case .cursorPosition:
            // This is sent FROM host TO viewer, not received by host
            return nil
        }
    }

    // MARK: - Mouse Movement

    private func handleMouseMove(deltaX: Float, deltaY: Float) -> InputEvent? {
        // Update position with delta
        // deltaX positive = right, deltaY positive = down (matches CG coordinate system)
        currentPosition.x += CGFloat(deltaX)
        currentPosition.y += CGFloat(deltaY)

        // Check if cursor hit screen edge (before clamping)
        let hitEdge = checkEdgeHit()

        // Clamp to screen bounds
        currentPosition.x = max(screenBounds.minX, min(screenBounds.maxX - 1, currentPosition.x))
        currentPosition.y = max(screenBounds.minY, min(screenBounds.maxY - 1, currentPosition.y))

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
        return currentPosition.x <= screenBounds.minX + edgeMargin ||
               currentPosition.x >= screenBounds.maxX - edgeMargin ||
               currentPosition.y <= screenBounds.minY + edgeMargin ||
               currentPosition.y >= screenBounds.maxY - edgeMargin
    }

    private func injectMouseMove(to point: CGPoint) {
        // Point is already in CoreGraphics coordinates (origin at top-left)
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            print("[InputHandler] ERROR: Failed to create mouse move event")
            return
        }

        // Log first injection to confirm it's working
        if !hasLoggedFirstEvent {
            print("[InputHandler] Injecting first mouse move to \(point)")
        }

        event.post(tap: .cghidEventTap)
    }

    // MARK: - Mouse Buttons

    private func injectMouseButton(_ event: InputEvent, isDown: Bool) {
        let (mouseType, mouseButton) = getMouseTypeAndButton(event.button, isDown: isDown)

        // currentPosition is already in CoreGraphics coordinates
        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseType,
            mouseCursorPosition: currentPosition,
            mouseButton: mouseButton
        ) else {
            print("[InputHandler] Failed to create mouse button event")
            return
        }

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
