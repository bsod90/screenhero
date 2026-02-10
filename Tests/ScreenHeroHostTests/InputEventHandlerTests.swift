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

    func testMouseDeltaUsesTopLeftCoordinatesWithUpPositiveY() {
        let delta = InputEventHandler.mouseDelta(
            from: CGPoint(x: 100, y: 100),
            to: CGPoint(x: 130, y: 80)
        )

        XCTAssertEqual(delta.dx, 30)
        XCTAssertEqual(delta.dy, 20)
    }

    func testEffectiveClickStateUsesExplicitEncodedCount() {
        let event = InputEvent.mouseDown(
            button: .left,
            normalizedX: 0.5,
            normalizedY: 0.5,
            clickCount: 2
        )
        XCTAssertEqual(InputEventHandler.effectiveClickState(for: event), 2)
    }

    func testEffectiveClickStateFallsBackToSingleClick() {
        let event = InputEvent.mouseDown(button: .left)
        XCTAssertEqual(InputEventHandler.effectiveClickState(for: event), 1)
    }

    func testShouldUseRelativeDragModeWhenPointerIsStuckDuringInputMovement() {
        XCTAssertTrue(
            InputEventHandler.shouldUseRelativeDragMode(
                anyButtonDown: true,
                inputTravel: 8,
                hostTravel: 0.1,
                stuckStreak: 3
            )
        )
    }

    func testShouldNotUseRelativeDragModeWhenNoButtonsHeld() {
        XCTAssertFalse(
            InputEventHandler.shouldUseRelativeDragMode(
                anyButtonDown: false,
                inputTravel: 8,
                hostTravel: 0.1,
                stuckStreak: 3
            )
        )
    }

    func testShouldNotUseRelativeDragModeWhenInputMovementIsSmall() {
        XCTAssertFalse(
            InputEventHandler.shouldUseRelativeDragMode(
                anyButtonDown: true,
                inputTravel: 0.2,
                hostTravel: 0.0,
                stuckStreak: 10
            )
        )
    }

    func testShouldNotUseRelativeDragModeWhenHostPointerIsMoving() {
        XCTAssertFalse(
            InputEventHandler.shouldUseRelativeDragMode(
                anyButtonDown: true,
                inputTravel: 8,
                hostTravel: 4,
                stuckStreak: 10
            )
        )
    }

    func testShouldNotUseRelativeDragModeBeforeStreakThreshold() {
        XCTAssertFalse(
            InputEventHandler.shouldUseRelativeDragMode(
                anyButtonDown: true,
                inputTravel: 8,
                hostTravel: 0.1,
                stuckStreak: 2
            )
        )
    }
}
