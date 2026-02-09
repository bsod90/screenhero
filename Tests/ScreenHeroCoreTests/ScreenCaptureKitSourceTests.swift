import XCTest
import ScreenCaptureKit
@testable import ScreenHeroCore

@available(macOS 12.3, *)
final class ScreenCaptureKitSourceTests: XCTestCase {

    func testShouldEmitFrameWithIdleStatus() {
        let info: [SCStreamFrameInfo: Any] = [
            SCStreamFrameInfo.status: SCFrameStatus.idle
        ]
        XCTAssertFalse(ScreenCaptureKitSource.shouldEmitFrame(frameInfo: info))
    }

    func testShouldEmitFrameWithEmptyDirtyRects() {
        let info: [SCStreamFrameInfo: Any] = [
            SCStreamFrameInfo.status: SCFrameStatus.complete,
            SCStreamFrameInfo.dirtyRects: [] as [NSValue]
        ]
        XCTAssertFalse(ScreenCaptureKitSource.shouldEmitFrame(frameInfo: info))
    }

    func testShouldEmitFrameWithDirtyRects() {
        let rect = NSValue(rect: NSRect(x: 0, y: 0, width: 10, height: 10))
        let info: [SCStreamFrameInfo: Any] = [
            SCStreamFrameInfo.status: SCFrameStatus.complete,
            SCStreamFrameInfo.dirtyRects: [rect]
        ]
        XCTAssertTrue(ScreenCaptureKitSource.shouldEmitFrame(frameInfo: info))
    }

    func testShouldEmitFrameWithoutDirtyRects() {
        let info: [SCStreamFrameInfo: Any] = [
            SCStreamFrameInfo.status: SCFrameStatus.complete
        ]
        XCTAssertTrue(ScreenCaptureKitSource.shouldEmitFrame(frameInfo: info))
    }
}
