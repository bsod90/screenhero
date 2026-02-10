import XCTest
import CoreGraphics
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
}
