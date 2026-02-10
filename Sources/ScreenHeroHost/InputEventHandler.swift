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

    /// Last injected cursor position for explicit drag delta synthesis.
    private var lastInjectedPosition: CGPoint?

    /// Last normalized-absolute input position received from viewer for delta synthesis.
    private var lastInputPosition: CGPoint?

    /// Margin from edge to trigger release (pixels)
    private let edgeMargin: CGFloat = 2

    /// Callback to send events back to viewer (for releaseCapture)
    private var responseSender: ((InputEvent) -> Void)?

    /// Whether we've logged the first event (to avoid spam)
    private var hasLoggedFirstEvent = false

    /// Last accepted mouse move timestamp to drop stale out-of-order packets.
    private var lastMouseMoveTimestamp: UInt64 = 0

    /// Current pressed mouse buttons for drag event synthesis.
    private var isLeftButtonDown = false
    private var isRightButtonDown = false
    private var isMiddleButtonDown = false

    /// Whether host is in relative drag mode (target app hidden/locked cursor).
    private var isRelativeDragMode = false
    private var relativeDragAnchor: CGPoint?
    private var pointerMismatchStreak = 0

    /// Shared event source so injected events carry coherent system state.
    private let eventSource: CGEventSource?

    private static let relativeDragPointerDriftThreshold: CGFloat = 12
    private static let relativeDragActivationStreak = 3

    // MARK: - Initialization

    public init(displayID: CGDirectDisplayID? = nil) {
        // Get display bounds in CoreGraphics coordinates
        let targetDisplayID = displayID ?? CGMainDisplayID()
        let displayBounds = CGDisplayBounds(targetDisplayID)
        screenBounds = displayBounds

        // Start at center of screen
        currentPosition = CGPoint(x: displayBounds.midX, y: displayBounds.midY)
        lastInjectedPosition = currentPosition
        lastInputPosition = currentPosition
        eventSource = CGEventSource(stateID: .combinedSessionState)

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
        // Debug log for all non-move events, and the first move.
        if event.type == .mouseMove {
            if !hasLoggedFirstEvent {
                print("[InputHandler] mouseMove: normalized=(\(String(format: "%.3f", event.x)), \(String(format: "%.3f", event.y)))")
                hasLoggedFirstEvent = true
            }
        } else {
            print("[InputHandler] EVENT: \(event.type) at pos=\(currentPosition)")
        }

        switch event.type {
        case .mouseMove:
            return handleMouseMove(normalizedX: event.x, normalizedY: event.y, timestamp: event.timestamp)

        case .mouseDown:
            updatePositionFromPointerEventIfPresent(event)
            setButtonState(event.button, isDown: true)
            injectMouseButton(event, isDown: true)
            return nil

        case .mouseUp:
            updatePositionFromPointerEventIfPresent(event)
            setButtonState(event.button, isDown: false)
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

    /// Count of mouse moves received (for warm-up period)
    private var mouseMoveCount = 0

    private func handleMouseMove(normalizedX: Float, normalizedY: Float, timestamp: UInt64) -> InputEvent? {
        // Ignore stale or out-of-order events to prevent cursor jumps backwards.
        guard timestamp >= lastMouseMoveTimestamp else { return nil }
        lastMouseMoveTimestamp = timestamp

        mouseMoveCount += 1

        let normalized = CGPoint(x: CGFloat(normalizedX), y: CGFloat(normalizedY))
        let screenPoint = MouseCoordinateTransform.normalizedTopLeftToCGDisplayPoint(
            normalized,
            displayBounds: screenBounds
        )

        // Log first few moves to help debug.
        if mouseMoveCount <= 3 {
            print("[InputHandler] Move #\(mouseMoveCount): normalized=(\(String(format: "%.3f", normalized.x)), \(String(format: "%.3f", normalized.y))) -> screen=(\(Int(screenPoint.x)), \(Int(screenPoint.y)))")
            print("[InputHandler]   screenBounds=\(screenBounds)")
        }

        // Update current position.
        currentPosition = screenPoint

        // Check edge hit (after warm-up period)
        let hitEdge = mouseMoveCount > 5 && checkEdgeHit()

        // Clamp to screen bounds
        currentPosition.x = max(screenBounds.minX, min(screenBounds.maxX - 1, currentPosition.x))
        currentPosition.y = max(screenBounds.minY, min(screenBounds.maxY - 1, currentPosition.y))

        let previousInput = lastInputPosition ?? currentPosition
        let inputDelta = Self.mouseDelta(from: previousInput, to: currentPosition)
        lastInputPosition = currentPosition

        let anyButtonDown = isLeftButtonDown || isRightButtonDown || isMiddleButtonDown
        let hostPointer = currentPointerLocation() ?? currentPosition
        let pointerDrift = hypot(hostPointer.x - currentPosition.x, hostPointer.y - currentPosition.y)

        if anyButtonDown {
            if pointerDrift >= Self.relativeDragPointerDriftThreshold {
                pointerMismatchStreak += 1
            } else {
                pointerMismatchStreak = 0
            }

            let shouldUseRelativeDrag = Self.shouldUseRelativeDragMode(
                anyButtonDown: anyButtonDown,
                pointerDrift: pointerDrift,
                mismatchStreak: pointerMismatchStreak
            )
            if shouldUseRelativeDrag && !isRelativeDragMode {
                isRelativeDragMode = true
                relativeDragAnchor = hostPointer
                print("[InputHandler] Entered relative drag mode (pointer drift: \(Int(pointerDrift)))")
            }
        } else {
            pointerMismatchStreak = 0
            if isRelativeDragMode {
                isRelativeDragMode = false
                relativeDragAnchor = nil
                print("[InputHandler] Exited relative drag mode")
            }
        }

        // Inject mouse motion; synthesize drag events while a button is held.
        let moveInjection = Self.mouseMoveInjectionKind(
            leftDown: isLeftButtonDown,
            rightDown: isRightButtonDown,
            middleDown: isMiddleButtonDown
        )
        let injectionPoint = isRelativeDragMode ? (relativeDragAnchor ?? currentPosition) : currentPosition
        injectMouseMove(
            to: injectionPoint,
            eventType: moveInjection.type,
            mouseButton: moveInjection.button,
            deltaOverride: isRelativeDragMode ? inputDelta : nil
        )

        // Keep relative anchor synced to actual host pointer if it drifts.
        if isRelativeDragMode, let hostPoint = currentPointerLocation() {
            relativeDragAnchor = hostPoint
        }

        // If hit edge, tell viewer to release capture
        if hitEdge && !isRelativeDragMode {
            print("[InputHandler] Edge hit at \(currentPosition), bounds=\(screenBounds), releasing capture")
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

    private func injectMouseMove(
        to point: CGPoint,
        eventType: CGEventType,
        mouseButton: CGMouseButton,
        deltaOverride: (dx: Int64, dy: Int64)? = nil
    ) {
        let previous = lastInjectedPosition ?? point
        let delta = deltaOverride ?? Self.mouseDelta(from: previous, to: point)

        // Point is already in CoreGraphics coordinates (origin at top-left)
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: eventType,
            mouseCursorPosition: point,
            mouseButton: mouseButton
        ) else {
            print("[InputHandler] ERROR: Failed to create mouse move event")
            return
        }

        // Preserve relative deltas for controls that consume drag deltas directly (e.g. DAWs).
        event.setIntegerValueField(.mouseEventDeltaX, value: delta.dx)
        event.setIntegerValueField(.mouseEventDeltaY, value: delta.dy)

        // Log first injection to confirm it's working
        if !hasLoggedFirstEvent {
            print("[InputHandler] Injecting first mouse move to \(point)")
        }

        event.post(tap: .cghidEventTap)
        lastInjectedPosition = point
    }

    static func mouseMoveInjectionKind(
        leftDown: Bool,
        rightDown: Bool,
        middleDown: Bool
    ) -> (type: CGEventType, button: CGMouseButton) {
        if leftDown { return (.leftMouseDragged, .left) }
        if rightDown { return (.rightMouseDragged, .right) }
        if middleDown { return (.otherMouseDragged, .center) }
        return (.mouseMoved, .left)
    }

    private func setButtonState(_ button: InputEvent.MouseButton, isDown: Bool) {
        switch button {
        case .left:
            isLeftButtonDown = isDown
        case .right:
            isRightButtonDown = isDown
        case .middle:
            isMiddleButtonDown = isDown
        case .none:
            break
        }
    }

    private func updatePositionFromPointerEventIfPresent(_ event: InputEvent) {
        guard let pointerPosition = Self.pointerPositionIfPresent(event, screenBounds: screenBounds) else { return }
        currentPosition = pointerPosition
        lastInjectedPosition = pointerPosition
        lastInputPosition = pointerPosition
    }

    static func pointerPositionIfPresent(_ event: InputEvent, screenBounds: CGRect) -> CGPoint? {
        guard event.modifiers.contains(.hasPointerPosition) else { return nil }

        let normalized = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
        var point = MouseCoordinateTransform.normalizedTopLeftToCGDisplayPoint(
            normalized,
            displayBounds: screenBounds
        )
        point.x = max(screenBounds.minX, min(screenBounds.maxX - 1, point.x))
        point.y = max(screenBounds.minY, min(screenBounds.maxY - 1, point.y))
        return point
    }

    static func mouseDelta(from previous: CGPoint, to current: CGPoint) -> (dx: Int64, dy: Int64) {
        // NSEvent-style deltas: positive X is right, positive Y is up.
        let dx = Int64((current.x - previous.x).rounded())
        let dy = Int64((previous.y - current.y).rounded())
        return (dx, dy)
    }

    static func shouldUseRelativeDragMode(
        anyButtonDown: Bool,
        pointerDrift: CGFloat,
        mismatchStreak: Int
    ) -> Bool {
        anyButtonDown &&
        pointerDrift >= relativeDragPointerDriftThreshold &&
        mismatchStreak >= relativeDragActivationStreak
    }

    static func effectiveClickState(for event: InputEvent) -> Int64 {
        Int64(max(1, event.mouseClickCount))
    }

    // MARK: - Mouse Buttons

    private func injectMouseButton(_ event: InputEvent, isDown: Bool) {
        let (mouseType, mouseButton) = getMouseTypeAndButton(event.button, isDown: isDown)

        // currentPosition is already in CoreGraphics coordinates
        guard let cgEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: mouseType,
            mouseCursorPosition: currentPosition,
            mouseButton: mouseButton
        ) else {
            print("[InputHandler] Failed to create mouse button event")
            return
        }

        cgEvent.setIntegerValueField(.mouseEventClickState, value: Self.effectiveClickState(for: event))

        cgEvent.post(tap: .cghidEventTap)
        lastInjectedPosition = currentPosition

        if !isLeftButtonDown && !isRightButtonDown && !isMiddleButtonDown {
            isRelativeDragMode = false
            relativeDragAnchor = nil
            pointerMismatchStreak = 0
        }
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
        lastInjectedPosition = currentPosition
        lastInputPosition = currentPosition
        isRelativeDragMode = false
        relativeDragAnchor = nil
        pointerMismatchStreak = 0
    }

    /// Get current virtual mouse position
    public var position: CGPoint {
        currentPosition
    }

    private nonisolated func currentPointerLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }
}
