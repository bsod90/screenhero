import Foundation

/// Input event for mouse and keyboard streaming
/// 24-byte packet format for efficient network transmission
public struct InputEvent: Sendable {
    /// Magic number for packet validation: "SHIP" (ScreenHero Input Protocol)
    public static let magic: UInt32 = 0x53484950

    /// Event types
    public enum EventType: UInt8, Sendable {
        case mouseMove = 1
        case mouseDown = 2
        case mouseUp = 3
        case scroll = 4
        case keyDown = 5
        case keyUp = 6
        case releaseCapture = 7   // Host tells viewer to release mouse capture
        case cursorPosition = 8   // Host sends cursor position for local rendering
    }

    /// Cursor types for local rendering
    public enum CursorType: UInt8, Sendable {
        case arrow = 0
        case iBeam = 1
        case crosshair = 2
        case pointingHand = 3
        case resizeLeftRight = 4
        case resizeUpDown = 5
        case hidden = 255
    }

    /// Mouse button identifiers
    public enum MouseButton: UInt8, Sendable {
        case none = 0
        case left = 1
        case right = 2
        case middle = 3
    }

    /// Modifier key bitmask
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let shift   = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option  = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        /// For mouse events, indicates that x/y contain an explicit normalized pointer position.
        public static let hasPointerPosition = Modifiers(rawValue: 1 << 7)
    }

    public let type: EventType
    public let timestamp: UInt64  // Nanoseconds since epoch
    public let x: Float           // mouseMove: normalized X (0...1), scroll: deltaX
    public let y: Float           // mouseMove: normalized Y (0...1), scroll: deltaY
    public let button: MouseButton
    public let keyCode: UInt16    // CGKeyCode for keyboard events
    public let modifiers: Modifiers

    public init(
        type: EventType,
        timestamp: UInt64 = 0,
        x: Float = 0,
        y: Float = 0,
        button: MouseButton = .none,
        keyCode: UInt16 = 0,
        modifiers: Modifiers = []
    ) {
        self.type = type
        self.timestamp = timestamp != 0 ? timestamp : UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        self.x = x
        self.y = y
        self.button = button
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Create a cursor position update event (host -> viewer)
    /// x, y are absolute normalized top-left coordinates (0...1)
    /// cursorType indicates what cursor image to show
    public static func cursorPosition(x: Float, y: Float, cursorType: CursorType = .arrow) -> InputEvent {
        InputEvent(
            type: .cursorPosition,
            x: x,
            y: y,
            button: MouseButton(rawValue: cursorType.rawValue) ?? .none
        )
    }

    /// Get cursor type from a cursorPosition event
    public var cursorType: CursorType {
        CursorType(rawValue: button.rawValue) ?? .arrow
    }

    /// Packet format (24 bytes total):
    /// - Magic     (4 bytes): 0x53484950 ("SHIP")
    /// - Type      (1 byte):  EventType
    /// - Padding   (3 bytes): Reserved for future use
    /// - Timestamp (8 bytes): Nanoseconds since epoch
    /// - X         (4 bytes): Float32
    /// - Y         (4 bytes): Float32
    /// - Button    (1 byte):  Mouse button
    /// - KeyCode   (2 bytes): CGKeyCode
    /// - Modifiers (1 byte):  Modifier bitmask
    public static let packetSize = 28

    /// Serialize the event to network data
    public func serialize() -> Data {
        var data = Data(capacity: Self.packetSize)

        // Magic (4 bytes, big-endian)
        var magic = Self.magic.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &magic) { Array($0) })

        // Type (1 byte)
        data.append(type.rawValue)

        // Padding (3 bytes)
        data.append(contentsOf: [0, 0, 0])

        // Timestamp (8 bytes, big-endian)
        var ts = timestamp.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &ts) { Array($0) })

        // X (4 bytes, IEEE 754)
        var xVal = x.bitPattern.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &xVal) { Array($0) })

        // Y (4 bytes, IEEE 754)
        var yVal = y.bitPattern.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &yVal) { Array($0) })

        // Button (1 byte)
        data.append(button.rawValue)

        // KeyCode (2 bytes, big-endian)
        var kc = keyCode.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &kc) { Array($0) })

        // Modifiers (1 byte)
        data.append(modifiers.rawValue)

        return data
    }

    /// Deserialize an event from network data
    public static func deserialize(from data: Data) -> InputEvent? {
        guard data.count >= packetSize else { return nil }

        // Read magic (bytes 0-3)
        let magic = readUInt32(from: data, at: 0)
        guard magic == Self.magic else { return nil }

        // Read type (byte 4)
        guard let type = EventType(rawValue: data[4]) else { return nil }

        // Skip padding (bytes 5-7)

        // Read timestamp (bytes 8-15)
        let timestamp = readUInt64(from: data, at: 8)

        // Read X (bytes 16-19)
        let xBits = readUInt32(from: data, at: 16)
        let x = Float(bitPattern: xBits)

        // Read Y (bytes 20-23)
        let yBits = readUInt32(from: data, at: 20)
        let y = Float(bitPattern: yBits)

        // Read button (byte 24)
        let button = MouseButton(rawValue: data[24]) ?? .none

        // Read keyCode (bytes 25-26)
        let keyCode = readUInt16(from: data, at: 25)

        // Read modifiers (byte 27)
        let modifiers = Modifiers(rawValue: data[27])

        return InputEvent(
            type: type,
            timestamp: timestamp,
            x: x,
            y: y,
            button: button,
            keyCode: keyCode,
            modifiers: modifiers
        )
    }

    // Helper functions to read values without alignment issues
    private static func readUInt16(from data: Data, at offset: Int) -> UInt16 {
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        return UInt32(data[offset]) << 24 |
               UInt32(data[offset + 1]) << 16 |
               UInt32(data[offset + 2]) << 8 |
               UInt32(data[offset + 3])
    }

    private static func readUInt64(from data: Data, at offset: Int) -> UInt64 {
        return UInt64(data[offset]) << 56 |
               UInt64(data[offset + 1]) << 48 |
               UInt64(data[offset + 2]) << 40 |
               UInt64(data[offset + 3]) << 32 |
               UInt64(data[offset + 4]) << 24 |
               UInt64(data[offset + 5]) << 16 |
               UInt64(data[offset + 6]) << 8 |
               UInt64(data[offset + 7])
    }
}

// MARK: - Convenience initializers

extension InputEvent {
    /// Create a mouse move event with absolute normalized position.
    public static func mouseMove(normalizedX: Float, normalizedY: Float) -> InputEvent {
        InputEvent(type: .mouseMove, x: normalizedX, y: normalizedY)
    }

    /// Backward-compatible alias. The payload is interpreted as absolute normalized position.
    public static func mouseMove(deltaX: Float, deltaY: Float) -> InputEvent {
        mouseMove(normalizedX: deltaX, normalizedY: deltaY)
    }

    /// Create a mouse button down event
    public static func mouseDown(button: MouseButton, x: Float = 0, y: Float = 0) -> InputEvent {
        InputEvent(type: .mouseDown, x: x, y: y, button: button)
    }

    /// Create a mouse button down event with explicit normalized pointer position.
    public static func mouseDown(button: MouseButton, normalizedX: Float, normalizedY: Float) -> InputEvent {
        InputEvent(
            type: .mouseDown,
            x: normalizedX,
            y: normalizedY,
            button: button,
            modifiers: [.hasPointerPosition]
        )
    }

    /// Create a mouse button up event
    public static func mouseUp(button: MouseButton, x: Float = 0, y: Float = 0) -> InputEvent {
        InputEvent(type: .mouseUp, x: x, y: y, button: button)
    }

    /// Create a mouse button up event with explicit normalized pointer position.
    public static func mouseUp(button: MouseButton, normalizedX: Float, normalizedY: Float) -> InputEvent {
        InputEvent(
            type: .mouseUp,
            x: normalizedX,
            y: normalizedY,
            button: button,
            modifiers: [.hasPointerPosition]
        )
    }

    /// Create a scroll event
    public static func scroll(deltaX: Float, deltaY: Float) -> InputEvent {
        InputEvent(type: .scroll, x: deltaX, y: deltaY)
    }

    /// Create a key down event
    public static func keyDown(keyCode: UInt16, modifiers: Modifiers = []) -> InputEvent {
        InputEvent(type: .keyDown, keyCode: keyCode, modifiers: modifiers)
    }

    /// Create a key up event
    public static func keyUp(keyCode: UInt16, modifiers: Modifiers = []) -> InputEvent {
        InputEvent(type: .keyUp, keyCode: keyCode, modifiers: modifiers)
    }

    /// Create a release capture event (sent from host to viewer)
    public static func releaseCapture() -> InputEvent {
        InputEvent(type: .releaseCapture)
    }
}
