import XCTest
import CoreGraphics
import ScreenHeroCore
@testable import ScreenHeroHost

final class InputEventHandlerTests: XCTestCase {
    func testMouseMoveInjectionKindWhenNoButtonsHeld() {
        let kind = InputEventHandler.mouseMoveInjectionKind(
            leftDown: false,
            rightDown: false,
            middleDown: false
        )

        XCTAssertEqual(kind.type, .mouseMoved)
        XCTAssertEqual(kind.button, .left)
    }

    func testMouseMoveInjectionKindWhenLeftHeld() {
        let kind = InputEventHandler.mouseMoveInjectionKind(
            leftDown: true,
            rightDown: false,
            middleDown: false
        )

        XCTAssertEqual(kind.type, .leftMouseDragged)
        XCTAssertEqual(kind.button, .left)
    }

    func testMouseMoveInjectionKindWhenRightHeld() {
        let kind = InputEventHandler.mouseMoveInjectionKind(
            leftDown: false,
            rightDown: true,
            middleDown: false
        )

        XCTAssertEqual(kind.type, .rightMouseDragged)
        XCTAssertEqual(kind.button, .right)
    }

    func testMouseMoveInjectionKindWhenMiddleHeld() {
        let kind = InputEventHandler.mouseMoveInjectionKind(
            leftDown: false,
            rightDown: false,
            middleDown: true
        )

        XCTAssertEqual(kind.type, .otherMouseDragged)
        XCTAssertEqual(kind.button, .center)
    }

    func testMouseMoveInjectionKindPrioritizesLeftWhenMultipleHeld() {
        let kind = InputEventHandler.mouseMoveInjectionKind(
            leftDown: true,
            rightDown: true,
            middleDown: true
        )

        XCTAssertEqual(kind.type, .leftMouseDragged)
        XCTAssertEqual(kind.button, .left)
    }

    func testPointerPositionIfPresentReturnsNilWithoutFlag() {
        let event = InputEvent.mouseDown(button: .left)
        let point = InputEventHandler.pointerPositionIfPresent(
            event,
            screenBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )

        XCTAssertNil(point)
    }

    func testPointerPositionIfPresentMapsNormalizedCoordinates() {
        let event = InputEvent.mouseDown(button: .left, normalizedX: 0.25, normalizedY: 0.75)
        let point = InputEventHandler.pointerPositionIfPresent(
            event,
            screenBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )

        XCTAssertNotNil(point)
        XCTAssertEqual(point?.x ?? -1, 480, accuracy: 0.5)
        XCTAssertEqual(point?.y ?? -1, 810, accuracy: 0.5)
    }

    func testPointerPositionIfPresentClampsOutOfRangeCoordinates() {
        let event = InputEvent.mouseDown(button: .left, normalizedX: 1.4, normalizedY: -0.2)
        let point = InputEventHandler.pointerPositionIfPresent(
            event,
            screenBounds: CGRect(x: 10, y: 20, width: 100, height: 80)
        )

        XCTAssertNotNil(point)
        XCTAssertEqual(point?.x ?? -1, 109, accuracy: 0.001)
        XCTAssertEqual(point?.y ?? -1, 20, accuracy: 0.001)
    }
}
