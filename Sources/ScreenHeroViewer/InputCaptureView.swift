import AppKit
import CoreGraphics
import ScreenHeroCore

/// View that captures mouse and keyboard input and streams to host
/// Wraps the MetalVideoDisplayView and handles input capture state
public class InputCaptureView: NSView {
    // MARK: - Constants

    /// Escape key code - ALWAYS releases capture, cannot be remapped
    private let escapeKeyCode: UInt16 = 53

    /// Border width when captured
    private let capturedBorderWidth: CGFloat = 3

    /// Border color when captured (green)
    private let capturedBorderColor = NSColor.systemGreen

    // MARK: - Properties

    /// The video display view
    private let videoView: MetalVideoDisplayView

    /// Whether mouse is currently captured
    private(set) var isCaptured = false

    /// Whether input capture is enabled (--enable-input flag)
    private(set) var inputEnabled = false

    /// Callback to send input events to network
    private var inputSender: ((InputEvent) -> Void)?

    /// Track last mouse location for delta calculation
    private var lastMouseLocation: CGPoint = .zero

    /// Border layer for visual indicator
    private var borderLayer: CAShapeLayer?

    /// Cursor layer for local cursor rendering
    private var cursorLayer: CALayer?

    /// Remote video dimensions (stream resolution) used for aspect-fit calculations
    private var remoteVideoWidth: CGFloat = 1920
    private var remoteVideoHeight: CGFloat = 1080

    /// Current cursor type
    private var currentCursorType: InputEvent.CursorType = .arrow

    /// Virtual mouse position as normalized top-left coordinates (0...1)
    private var virtualMouseX: CGFloat = 0.5
    private var virtualMouseY: CGFloat = 0.5

    // MARK: - Initialization

    public init(frame: NSRect, videoView: MetalVideoDisplayView) {
        self.videoView = videoView
        super.init(frame: frame)
        setupView()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        // Add video view as subview
        videoView.frame = bounds
        videoView.autoresizingMask = [.width, .height]
        addSubview(videoView)

        // Enable layer-backed view for border
        wantsLayer = true

        // Set up cursor layer for local rendering
        setupCursorLayer()

        // Set up tracking area for mouse events
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    private func setupCursorLayer() {
        let cursor = CALayer()
        cursor.bounds = CGRect(x: 0, y: 0, width: 16, height: 24)
        cursor.anchorPoint = CGPoint(x: 0, y: 0)  // Hot spot at top-left for arrow
        cursor.position = CGPoint(x: 0, y: 0)
        cursor.zPosition = 1000  // Above everything
        cursor.isHidden = true  // Hidden by default, shown when captured

        // Create arrow cursor image
        let cursorImage = createCursorImage(type: .arrow)
        cursor.contents = cursorImage

        layer?.addSublayer(cursor)
        cursorLayer = cursor
    }

    private func createCursorImage(type: InputEvent.CursorType) -> CGImage? {
        // Get system cursor image
        let cursor: NSCursor
        switch type {
        case .arrow:
            cursor = NSCursor.arrow
        case .iBeam:
            cursor = NSCursor.iBeam
        case .crosshair:
            cursor = NSCursor.crosshair
        case .pointingHand:
            cursor = NSCursor.pointingHand
        case .resizeLeftRight:
            cursor = NSCursor.resizeLeftRight
        case .resizeUpDown:
            cursor = NSCursor.resizeUpDown
        case .hidden:
            return nil
        }

        // Get the cursor image
        let image = cursor.image
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: - Public API

    /// Enable input capture with the given sender callback
    public func enableInput(sender: @escaping (InputEvent) -> Void) {
        inputEnabled = true
        inputSender = sender
        print("[InputCapture] Input capture enabled - click inside window to capture mouse")
    }

    /// Disable input capture
    public func disableInput() {
        if isCaptured {
            releaseMouse()
        }
        inputEnabled = false
        inputSender = nil
    }

    /// Display a pixel buffer (proxy to video view)
    public func displayPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        videoView.displayPixelBuffer(pixelBuffer)
    }

    /// Handle release capture event from host
    public func handleReleaseCaptureFromHost() {
        if isCaptured {
            releaseMouse()
        }
    }

    /// Set remote video dimensions for cursor coordinate mapping
    public func setRemoteVideoSize(width: Int, height: Int) {
        remoteVideoWidth = CGFloat(width)
        remoteVideoHeight = CGFloat(height)
    }

    /// Backward-compatible wrapper; now interpreted as remote video size.
    public func setRemoteScreenSize(width: Int, height: Int) {
        setRemoteVideoSize(width: width, height: height)
    }

    /// Calculate the actual video display rect within the view
    /// This accounts for aspect-ratio scaling (letterbox/pillarbox)
    private func calculateVideoRect() -> CGRect {
        MouseCoordinateTransform.aspectFitRect(
            container: bounds,
            contentWidth: remoteVideoWidth,
            contentHeight: remoteVideoHeight
        )
    }

    /// Update cursor position from host (for local cursor rendering)
    public func updateCursorPosition(_ event: InputEvent) {
        guard event.type == .cursorPosition else { return }

        // Calculate the actual video display rect (accounting for aspect-ratio scaling)
        let videoRect = calculateVideoRect()

        // Cursor payload uses normalized top-left coordinates.
        let localPoint = MouseCoordinateTransform.normalizedTopLeftToViewPoint(
            CGPoint(x: CGFloat(event.x), y: CGFloat(event.y)),
            in: videoRect
        )
        let localX = localPoint.x
        let localY = localPoint.y

        // Log cursor positions periodically
        struct PositionLogger {
            static var count = 0
        }
        PositionLogger.count += 1
        if PositionLogger.count <= 5 || PositionLogger.count % 60 == 0 {
            print("[Cursor] normalized=(\(String(format: "%.3f", event.x)), \(String(format: "%.3f", event.y))) -> local=(\(Int(localX)), \(Int(localY))) | videoRect=\(Int(videoRect.minX)),\(Int(videoRect.minY))-\(Int(videoRect.maxX)),\(Int(videoRect.maxY)) | remoteVideo=\(Int(remoteVideoWidth))x\(Int(remoteVideoHeight)) | viewBounds=\(Int(bounds.width))x\(Int(bounds.height))")
        }

        // Update cursor layer position (disable implicit animations for smooth tracking)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer?.position = CGPoint(x: localX, y: localY)
        CATransaction.commit()

        // Update cursor type if changed
        let newType = event.cursorType
        if newType != currentCursorType {
            currentCursorType = newType
            if newType == .hidden {
                cursorLayer?.isHidden = true
            } else {
                cursorLayer?.isHidden = false
                if let newImage = createCursorImage(type: newType) {
                    cursorLayer?.contents = newImage
                }
            }
        }
    }

    // MARK: - Responder Chain

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        return true
    }

    // MARK: - Mouse Capture

    /// Convert a point in view coordinates to normalized top-left coordinates.
    private func viewToNormalizedCoordinates(_ viewPoint: CGPoint) -> CGPoint {
        MouseCoordinateTransform.viewPointToNormalizedTopLeft(
            viewPoint,
            in: calculateVideoRect()
        )
    }

    private func captureMouse(at viewPoint: CGPoint) {
        guard !isCaptured else { return }

        isCaptured = true

        // Initialize virtual mouse position from click location.
        let normalized = viewToNormalizedCoordinates(viewPoint)
        virtualMouseX = normalized.x
        virtualMouseY = normalized.y

        print("[InputCapture] Capture started at view=(\(Int(viewPoint.x)), \(Int(viewPoint.y))) -> normalized=(\(String(format: "%.3f", virtualMouseX)), \(String(format: "%.3f", virtualMouseY)))")

        // DEBUG: Don't hide system cursor so we can compare positions
        // NSCursor.hide()

        // Show local cursor layer (receives position from host)
        cursorLayer?.isHidden = false

        // DEBUG: Don't disassociate so we can see both cursors
        // CGAssociateMouseAndMouseCursorPosition(0)

        // Get current mouse location
        if let window = window {
            lastMouseLocation = NSEvent.mouseLocation
            _ = window.convertPoint(fromScreen: lastMouseLocation)
        }

        // Show visual indicator (green border)
        showCapturedBorder()

        print("[InputCapture] Mouse captured - press Escape to release")
    }

    private func releaseMouse() {
        guard isCaptured else { return }

        isCaptured = false

        // DEBUG: Cursor wasn't hidden
        // NSCursor.unhide()

        // Hide local cursor layer (system cursor takes over)
        cursorLayer?.isHidden = true

        // DEBUG: Wasn't disassociated
        // CGAssociateMouseAndMouseCursorPosition(1)

        // Remove visual indicator
        hideCapturedBorder()

        print("[InputCapture] Mouse released")
    }

    private func showCapturedBorder() {
        if borderLayer == nil {
            let layer = CAShapeLayer()
            layer.fillColor = nil
            layer.strokeColor = capturedBorderColor.cgColor
            layer.lineWidth = capturedBorderWidth
            self.layer?.addSublayer(layer)
            borderLayer = layer
        }

        updateBorderPath()
        borderLayer?.isHidden = false
    }

    private func hideCapturedBorder() {
        borderLayer?.isHidden = true
    }

    private func updateBorderPath() {
        let inset = capturedBorderWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        borderLayer?.path = CGPath(rect: rect, transform: nil)
        borderLayer?.frame = bounds
    }

    public override func layout() {
        super.layout()
        updateBorderPath()
    }

    // MARK: - Mouse Events

    public override func mouseDown(with event: NSEvent) {
        print("[InputCapture] mouseDown: isCaptured=\(isCaptured), inputEnabled=\(inputEnabled), hasSender=\(inputSender != nil)")

        // Get click position in view coordinates
        let viewPoint = convert(event.locationInWindow, from: nil)

        // If not captured and input enabled, capture on click
        if !isCaptured && inputEnabled {
            captureMouse(at: viewPoint)
            window?.makeFirstResponder(self)

            // Send mouseMove to set initial position, then mouseDown
            let inputEvent = InputEvent.mouseMove(normalizedX: Float(virtualMouseX), normalizedY: Float(virtualMouseY))
            inputSender?(inputEvent)

            let clickEvent = InputEvent.mouseDown(button: .left)
            print("[InputCapture] SENDING initial position and mouseDown after capture")
            inputSender?(clickEvent)
            return
        }

        guard isCaptured && inputEnabled else { return }

        let inputEvent = InputEvent.mouseDown(button: .left)
        print("[InputCapture] SENDING mouseDown")
        inputSender?(inputEvent)
    }

    public override func mouseUp(with event: NSEvent) {
        guard isCaptured && inputEnabled else { return }

        let inputEvent = InputEvent.mouseUp(button: .left)
        inputSender?(inputEvent)
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard isCaptured && inputEnabled else { return }

        let inputEvent = InputEvent.mouseDown(button: .right)
        inputSender?(inputEvent)
    }

    public override func rightMouseUp(with event: NSEvent) {
        guard isCaptured && inputEnabled else { return }

        let inputEvent = InputEvent.mouseUp(button: .right)
        inputSender?(inputEvent)
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard isCaptured && inputEnabled else { return }

        // Button 2 is typically middle mouse
        let inputEvent = InputEvent.mouseDown(button: .middle)
        inputSender?(inputEvent)
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard isCaptured && inputEnabled else { return }

        let inputEvent = InputEvent.mouseUp(button: .middle)
        inputSender?(inputEvent)
    }

    public override func mouseMoved(with event: NSEvent) {
        guard isCaptured && inputEnabled else { return }
        sendAbsolutePosition(from: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isCaptured && inputEnabled else { return }
        sendAbsolutePosition(from: event)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        guard isCaptured && inputEnabled else { return }
        sendAbsolutePosition(from: event)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        guard isCaptured && inputEnabled else { return }
        sendAbsolutePosition(from: event)
    }

    /// Send an absolute normalized mouse position based on current view location.
    private func sendAbsolutePosition(from event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let normalized = viewToNormalizedCoordinates(viewPoint)

        let moved = abs(normalized.x - virtualMouseX) > 0.0005 || abs(normalized.y - virtualMouseY) > 0.0005
        guard moved else { return }

        virtualMouseX = normalized.x
        virtualMouseY = normalized.y

        let inputEvent = InputEvent.mouseMove(normalizedX: Float(virtualMouseX), normalizedY: Float(virtualMouseY))

        if let sender = inputSender {
            // Log occasionally to avoid spam.
            struct MoveCounter { static var count = 0 }
            MoveCounter.count += 1
            if MoveCounter.count <= 3 || MoveCounter.count % 60 == 0 {
                print("[InputCapture] SENDING normalized pos: (\(String(format: "%.3f", virtualMouseX)), \(String(format: "%.3f", virtualMouseY)))")
            }
            sender(inputEvent)
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        guard isCaptured && inputEnabled else { return }

        let deltaX = Float(event.scrollingDeltaX)
        let deltaY = Float(event.scrollingDeltaY)

        let inputEvent = InputEvent.scroll(deltaX: deltaX, deltaY: deltaY)
        inputSender?(inputEvent)
    }

    // MARK: - Keyboard Events

    public override func keyDown(with event: NSEvent) {
        // SAFETY: Escape ALWAYS releases, cannot be overridden
        if event.keyCode == escapeKeyCode {
            releaseMouse()
            return
        }

        guard isCaptured && inputEnabled else { return }

        let modifiers = convertModifiers(event.modifierFlags)
        let inputEvent = InputEvent.keyDown(keyCode: event.keyCode, modifiers: modifiers)
        inputSender?(inputEvent)
    }

    public override func keyUp(with event: NSEvent) {
        // Don't send escape key up
        if event.keyCode == escapeKeyCode { return }

        guard isCaptured && inputEnabled else { return }

        let modifiers = convertModifiers(event.modifierFlags)
        let inputEvent = InputEvent.keyUp(keyCode: event.keyCode, modifiers: modifiers)
        inputSender?(inputEvent)
    }

    public override func flagsChanged(with event: NSEvent) {
        guard isCaptured && inputEnabled else { return }

        // flagsChanged is called when modifier keys are pressed/released
        // We handle this implicitly through the modifiers in key events
    }

    private func convertModifiers(_ flags: NSEvent.ModifierFlags) -> InputEvent.Modifiers {
        var modifiers = InputEvent.Modifiers()

        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if flags.contains(.control) {
            modifiers.insert(.control)
        }
        if flags.contains(.option) {
            modifiers.insert(.option)
        }
        if flags.contains(.command) {
            modifiers.insert(.command)
        }

        return modifiers
    }
}
