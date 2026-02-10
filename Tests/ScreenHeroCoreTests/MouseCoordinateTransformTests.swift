import XCTest
import CoreGraphics
@testable import ScreenHeroCore

final class MouseCoordinateTransformTests: XCTestCase {
    func testViewPointRoundTripIsStable() {
        let rect = CGRect(x: 40, y: 20, width: 1200, height: 700)
        let viewPoint = CGPoint(x: 370, y: 540)

        let normalized = MouseCoordinateTransform.viewPointToNormalizedTopLeft(viewPoint, in: rect)
        let reconstructed = MouseCoordinateTransform.normalizedTopLeftToViewPoint(normalized, in: rect)

        XCTAssertEqual(reconstructed.x, viewPoint.x, accuracy: 0.001)
        XCTAssertEqual(reconstructed.y, viewPoint.y, accuracy: 0.001)
    }

    func testCursorImageOriginUsesTopLeftHotSpot() {
        let hotSpotPosition = CGPoint(x: 100, y: 200)
        let imageSize = CGSize(width: 20, height: 30)
        let hotSpotTopLeft = CGPoint(x: 4, y: 6)

        let origin = MouseCoordinateTransform.cursorImageOriginForHotSpotPosition(
            hotSpotPosition: hotSpotPosition,
            imageSize: imageSize,
            hotSpotTopLeft: hotSpotTopLeft
        )

        XCTAssertEqual(origin.x, 96, accuracy: 0.001)
        XCTAssertEqual(origin.y, 176, accuracy: 0.001)
    }

    func testCursorImageOriginClampsOutOfRangeHotSpot() {
        let hotSpotPosition = CGPoint(x: 100, y: 200)
        let imageSize = CGSize(width: 20, height: 30)
        let hotSpotTopLeft = CGPoint(x: -10, y: 45) // Should clamp to (0, 30)

        let origin = MouseCoordinateTransform.cursorImageOriginForHotSpotPosition(
            hotSpotPosition: hotSpotPosition,
            imageSize: imageSize,
            hotSpotTopLeft: hotSpotTopLeft
        )

        XCTAssertEqual(origin.x, 100, accuracy: 0.001)
        XCTAssertEqual(origin.y, 200, accuracy: 0.001)
    }

    func testCGDisplayPointRoundTripIsStable() {
        let displayBounds = CGRect(x: 300, y: 40, width: 1512, height: 982)
        let cgPoint = CGPoint(x: 1680, y: 770)

        let normalized = MouseCoordinateTransform.cgDisplayPointToNormalizedTopLeft(
            cgPoint,
            displayBounds: displayBounds
        )
        let reconstructed = MouseCoordinateTransform.normalizedTopLeftToCGDisplayPoint(
            normalized,
            displayBounds: displayBounds
        )

        XCTAssertEqual(reconstructed.x, cgPoint.x, accuracy: 0.001)
        XCTAssertEqual(reconstructed.y, cgPoint.y, accuracy: 0.001)
    }
}
