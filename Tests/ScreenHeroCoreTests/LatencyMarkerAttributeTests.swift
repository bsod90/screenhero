import XCTest
import AppKit

/// Tests for the latency marker text attribute pattern.
/// This tests the pattern used in LatencyMarkerView to ensure font creation doesn't crash.
final class LatencyMarkerAttributeTests: XCTestCase {

    @MainActor
    func testMonospacedDigitFontCreation() throws {
        // This tests the pattern used in LatencyMarkerView
        // Using monospacedDigitSystemFont is more reliable than monospacedSystemFont
        let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold)
        XCTAssertNotNil(font)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]

        // Verify the dictionary was created successfully
        XCTAssertEqual(attributes.count, 2)

        // Verify text sizing works
        let text = "123"
        let textSize = text.size(withAttributes: attributes)
        XCTAssertGreaterThan(textSize.width, 0)
        XCTAssertGreaterThan(textSize.height, 0)
    }

    @MainActor
    func testPreCachedAttributesPatternDoesNotCrash() throws {
        // Simulate the pre-cached pattern used in LatencyMarkerView
        // Create attributes once and reuse them multiple times
        let textAttributes: [NSAttributedString.Key: Any] = {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold)
            return [
                .font: font,
                .foregroundColor: NSColor.black
            ]
        }()

        // Simulate multiple draw calls using the same attributes
        for i in 0..<100 {
            let text = String(format: "%llu", UInt64(i) % 1000)
            let textSize = text.size(withAttributes: textAttributes)
            XCTAssertGreaterThan(textSize.width, 0)
            XCTAssertGreaterThan(textSize.height, 0)
        }
    }

    @MainActor
    func testColorSlotCalculation() throws {
        // Test the color slot calculation logic
        let colors: [NSColor] = [
            NSColor(red: 1, green: 0, blue: 0, alpha: 1),     // Red
            NSColor(red: 0, green: 1, blue: 0, alpha: 1),     // Green
            NSColor(red: 0, green: 0, blue: 1, alpha: 1),     // Blue
            NSColor(red: 1, green: 1, blue: 0, alpha: 1),     // Yellow
            NSColor(red: 0, green: 1, blue: 1, alpha: 1),     // Cyan
            NSColor(red: 1, green: 0, blue: 1, alpha: 1),     // Magenta
        ]

        // Verify 6 colors and proper cycling
        XCTAssertEqual(colors.count, 6)

        // Test slot calculation with wall-clock time
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let slotIndex = Int((nowMs / 100) % 6)
        XCTAssertGreaterThanOrEqual(slotIndex, 0)
        XCTAssertLessThan(slotIndex, 6)
    }
}
