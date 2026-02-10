import XCTest
import CoreGraphics
@testable import ScreenHeroViewer

final class ViewerBehaviorTests: XCTestCase {
    func testShouldConsumeEscapeOnlyWhenCapturedAndInputEnabled() {
        XCTAssertTrue(InputCaptureView.shouldConsumeEscape(isCaptured: true, inputEnabled: true))
        XCTAssertFalse(InputCaptureView.shouldConsumeEscape(isCaptured: false, inputEnabled: true))
        XCTAssertFalse(InputCaptureView.shouldConsumeEscape(isCaptured: true, inputEnabled: false))
        XCTAssertFalse(InputCaptureView.shouldConsumeEscape(isCaptured: false, inputEnabled: false))
    }

    func testDrawableSizeScalesByBackingFactor() {
        let size = MetalVideoDisplayView.drawableSize(
            for: CGRect(x: 0, y: 0, width: 1280, height: 720),
            backingScaleFactor: 2.0
        )

        XCTAssertEqual(size.width, 2560, accuracy: 0.001)
        XCTAssertEqual(size.height, 1440, accuracy: 0.001)
    }

    func testDrawableSizeNeverReturnsZero() {
        let size = MetalVideoDisplayView.drawableSize(
            for: .zero,
            backingScaleFactor: 2.0
        )

        XCTAssertEqual(size.width, 1, accuracy: 0.001)
        XCTAssertEqual(size.height, 1, accuracy: 0.001)
    }
}
