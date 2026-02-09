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
        case releaseCapture = 7  // Host tells viewer to release mouse capture
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
    }

    public let type: EventType
    public let timestamp: UInt64  // Nanoseconds since epoch
    public let x: Float           // Mouse X position or scroll delta X
    public let y: Float           // Mouse Y position or scroll delta Y
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

        var offset = 0

        // Read magic
        let magic = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(fromByteOffset: offset, as: UInt32.self).bigEndian
        }
        guard magic == Self.magic else { return nil }
        offset += 4

        // Read type
        guard let type = EventType(rawValue: data[offset]) else { return nil }
        offset += 1

        // Skip padding
        offset += 3

        // Read timestamp
        let timestamp = data.withUnsafeBytes { ptr -> UInt64 in
            ptr.load(fromByteOffset: offset, as: UInt64.self).bigEndian
        }
        offset += 8

        // Read X
        let xBits = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(fromByteOffset: offset, as: UInt32.self).bigEndian
        }
        let x = Float(bitPattern: xBits)
        offset += 4

        // Read Y
        let yBits = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(fromByteOffset: offset, as: UInt32.self).bigEndian
        }
        let y = Float(bitPattern: yBits)
        offset += 4

        // Read button
        let button = MouseButton(rawValue: data[offset]) ?? .none
        offset += 1

        // Read keyCode
        let keyCode = data.withUnsafeBytes { ptr -> UInt16 in
            ptr.load(fromByteOffset: offset, as: UInt16.self).bigEndian
        }
        offset += 2

        // Read modifiers
        let modifiers = Modifiers(rawValue: data[offset])

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
}

// MARK: - Convenience initializers

extension InputEvent {
    /// Create a mouse move event with delta movement
    public static func mouseMove(deltaX: Float, deltaY: Float) -> InputEvent {
        InputEvent(type: .mouseMove, x: deltaX, y: deltaY)
    }

    /// Create a mouse button down event
    public static func mouseDown(button: MouseButton, x: Float = 0, y: Float = 0) -> InputEvent {
        InputEvent(type: .mouseDown, x: x, y: y, button: button)
    }

    /// Create a mouse button up event
    public static func mouseUp(button: MouseButton, x: Float = 0, y: Float = 0) -> InputEvent {
        InputEvent(type: .mouseUp, x: x, y: y, button: button)
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
