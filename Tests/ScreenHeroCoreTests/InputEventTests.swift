import XCTest
@testable import ScreenHeroCore

final class InputEventTests: XCTestCase {

    // MARK: - Serialization Tests

    func testSerializeDeserializeMouseMove() throws {
        let event = InputEvent.mouseMove(deltaX: 10.5, deltaY: -20.3)

        let data = event.serialize()
        XCTAssertEqual(data.count, InputEvent.packetSize, "Packet size should be \(InputEvent.packetSize) bytes")

        let decoded = InputEvent.deserialize(from: data)
        XCTAssertNotNil(decoded, "Should deserialize successfully")
        XCTAssertEqual(decoded?.type, .mouseMove)
        XCTAssertEqual(Double(decoded?.x ?? 0), 10.5, accuracy: 0.001)
        XCTAssertEqual(Double(decoded?.y ?? 0), -20.3, accuracy: 0.001)
    }

    func testSerializeDeserializeMouseDown() throws {
        let event = InputEvent.mouseDown(button: .left, x: 100, y: 200)

        let data = event.serialize()
        let decoded = InputEvent.deserialize(from: data)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .mouseDown)
        XCTAssertEqual(decoded?.button, .left)
        XCTAssertEqual(decoded?.x, 100)
        XCTAssertEqual(decoded?.y, 200)
    }

    func testSerializeDeserializeMouseUp() throws {
        let event = InputEvent.mouseUp(button: .right)

        let data = event.serialize()
        let decoded = InputEvent.deserialize(from: data)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .mouseUp)
        XCTAssertEqual(decoded?.button, .right)
    }

    func testSerializeDeserializeScroll() throws {
        let event = InputEvent.scroll(deltaX: 5.0, deltaY: -10.0)

        let data = event.serialize()
        let decoded = InputEvent.deserialize(from: data)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .scroll)
        XCTAssertEqual(decoded?.x, 5.0)
        XCTAssertEqual(decoded?.y, -10.0)
    }

    func testSerializeDeserializeKeyDown() throws {
        let event = InputEvent.keyDown(keyCode: 0x00, modifiers: [.command, .shift])

        let data = event.serialize()
        let decoded = InputEvent.deserialize(from: data)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .keyDown)
        XCTAssertEqual(decoded?.keyCode, 0x00)
        XCTAssertTrue(decoded?.modifiers.contains(.command) ?? false)
        XCTAssertTrue(decoded?.modifiers.contains(.shift) ?? false)
        XCTAssertFalse(decoded?.modifiers.contains(.control) ?? true)
        XCTAssertFalse(decoded?.modifiers.contains(.option) ?? true)
    }

    func testSerializeDeserializeKeyUp() throws {
        let event = InputEvent.keyUp(keyCode: 53, modifiers: [])

        let data = event.serialize()
        let decoded = InputEvent.deserialize(from: data)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .keyUp)
        XCTAssertEqual(decoded?.keyCode, 53) // Escape
    }

    func testSerializeDeserializeReleaseCapture() throws {
        let event = InputEvent.releaseCapture()

        let data = event.serialize()
        let decoded = InputEvent.deserialize(from: data)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .releaseCapture)
    }

    // MARK: - Magic Number Tests

    func testMagicNumber() {
        let event = InputEvent.mouseMove(deltaX: 0, deltaY: 0)
        let data = event.serialize()

        // First 4 bytes should be the magic number "SHIP"
        let magic = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(as: UInt32.self).bigEndian
        }
        XCTAssertEqual(magic, InputEvent.magic)
        XCTAssertEqual(magic, 0x53484950) // "SHIP"
    }

    func testDeserializeInvalidMagic() {
        var data = Data(repeating: 0, count: InputEvent.packetSize)
        // Set invalid magic
        data[0] = 0xFF
        data[1] = 0xFF
        data[2] = 0xFF
        data[3] = 0xFF

        let decoded = InputEvent.deserialize(from: data)
        XCTAssertNil(decoded, "Should fail with invalid magic number")
    }

    func testDeserializeTooShort() {
        let data = Data(repeating: 0, count: 10) // Too short

        let decoded = InputEvent.deserialize(from: data)
        XCTAssertNil(decoded, "Should fail with too short data")
    }

    // MARK: - Timestamp Tests

    func testTimestampIsSet() {
        let before = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let event = InputEvent.mouseMove(deltaX: 0, deltaY: 0)
        let after = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)

        XCTAssertGreaterThanOrEqual(event.timestamp, before)
        XCTAssertLessThanOrEqual(event.timestamp, after)
    }

    func testTimestampPreserved() {
        let customTimestamp: UInt64 = 123456789
        let event = InputEvent(type: .mouseMove, timestamp: customTimestamp)

        let data = event.serialize()
        let decoded = InputEvent.deserialize(from: data)

        XCTAssertEqual(decoded?.timestamp, customTimestamp)
    }

    // MARK: - All Event Types

    func testAllEventTypes() {
        let eventTypes: [InputEvent.EventType] = [
            .mouseMove, .mouseDown, .mouseUp, .scroll, .keyDown, .keyUp, .releaseCapture
        ]

        for eventType in eventTypes {
            let event = InputEvent(type: eventType)
            let data = event.serialize()
            let decoded = InputEvent.deserialize(from: data)

            XCTAssertNotNil(decoded, "Should deserialize \(eventType)")
            XCTAssertEqual(decoded?.type, eventType, "Type should match for \(eventType)")
        }
    }

    // MARK: - Modifier Tests

    func testAllModifiers() {
        let modifiers: InputEvent.Modifiers = [.shift, .control, .option, .command]
        let event = InputEvent.keyDown(keyCode: 0, modifiers: modifiers)

        let data = event.serialize()
        let decoded = InputEvent.deserialize(from: data)

        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded?.modifiers.contains(.shift) ?? false)
        XCTAssertTrue(decoded?.modifiers.contains(.control) ?? false)
        XCTAssertTrue(decoded?.modifiers.contains(.option) ?? false)
        XCTAssertTrue(decoded?.modifiers.contains(.command) ?? false)
    }

    // MARK: - Button Tests

    func testAllMouseButtons() {
        let buttons: [InputEvent.MouseButton] = [.none, .left, .right, .middle]

        for button in buttons {
            let event = InputEvent.mouseDown(button: button)
            let data = event.serialize()
            let decoded = InputEvent.deserialize(from: data)

            XCTAssertNotNil(decoded, "Should deserialize button \(button)")
            XCTAssertEqual(decoded?.button, button, "Button should match for \(button)")
        }
    }

    // MARK: - Edge Case Tests

    func testNegativeDeltas() {
        let event = InputEvent.mouseMove(deltaX: -1000.5, deltaY: -2000.75)

        let data = event.serialize()
        let decoded = InputEvent.deserialize(from: data)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(Double(decoded?.x ?? 0), -1000.5, accuracy: 0.001)
        XCTAssertEqual(Double(decoded?.y ?? 0), -2000.75, accuracy: 0.001)
    }

    func testLargeKeyCode() {
        let event = InputEvent.keyDown(keyCode: 0xFFFF, modifiers: [])

        let data = event.serialize()
        let decoded = InputEvent.deserialize(from: data)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.keyCode, 0xFFFF)
    }

    func testZeroValues() {
        let event = InputEvent(type: .mouseMove, timestamp: 0, x: 0, y: 0, button: .none, keyCode: 0, modifiers: [])

        let data = event.serialize()
        let decoded = InputEvent.deserialize(from: data)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.x, 0)
        XCTAssertEqual(decoded?.y, 0)
        XCTAssertEqual(decoded?.keyCode, 0)
        XCTAssertTrue(decoded?.modifiers.isEmpty ?? false)
    }
}
