import XCTest
import CoreGraphics
import Foundation
@testable import ScreenHeroCore

/// End-to-end tests for viewer->network->host mouse coordinate translation.
final class MouseCoordinateE2ETests: XCTestCase {
    private actor HostReceiver {
        let displayBounds: CGRect
        private(set) var acceptedMoveCount = 0
        private(set) var lastTimestamp: UInt64 = 0
        private(set) var lastScreenPoint: CGPoint?

        init(displayBounds: CGRect) {
            self.displayBounds = displayBounds
        }

        func receive(_ event: InputEvent) {
            guard event.type == .mouseMove else { return }
            guard event.timestamp >= lastTimestamp else { return }

            lastTimestamp = event.timestamp
            lastScreenPoint = MouseCoordinateTransform.normalizedTopLeftToCGDisplayPoint(
                CGPoint(x: CGFloat(event.x), y: CGFloat(event.y)),
                displayBounds: displayBounds
            )
            acceptedMoveCount += 1
        }

        func snapshot() -> (count: Int, timestamp: UInt64, point: CGPoint?) {
            (acceptedMoveCount, lastTimestamp, lastScreenPoint)
        }
    }

    private struct ViewerHarness {
        var containerBounds: CGRect
        var remoteVideoWidth: CGFloat
        var remoteVideoHeight: CGFloat
        var normalizedPosition: CGPoint = CGPoint(x: 0.5, y: 0.5)

        var videoRect: CGRect {
            MouseCoordinateTransform.aspectFitRect(
                container: containerBounds,
                contentWidth: remoteVideoWidth,
                contentHeight: remoteVideoHeight
            )
        }

        mutating func updateRemoteVideoSize(width: Int, height: Int) {
            remoteVideoWidth = CGFloat(width)
            remoteVideoHeight = CGFloat(height)
        }

        mutating func capture(at viewPoint: CGPoint, timestamp: UInt64) -> InputEvent {
            normalizedPosition = MouseCoordinateTransform.viewPointToNormalizedTopLeft(
                viewPoint,
                in: videoRect
            )
            return InputEvent(type: .mouseMove, timestamp: timestamp, x: Float(normalizedPosition.x), y: Float(normalizedPosition.y))
        }

        mutating func move(to viewPoint: CGPoint, timestamp: UInt64) -> InputEvent {
            normalizedPosition = MouseCoordinateTransform.viewPointToNormalizedTopLeft(
                viewPoint,
                in: videoRect
            )
            return InputEvent(type: .mouseMove, timestamp: timestamp, x: Float(normalizedPosition.x), y: Float(normalizedPosition.y))
        }
    }

    func testMouseCoordinatesRoundTripOverUDPWithResolutionChange() async throws {
        let port: UInt16 = 17610
        let server = UDPInputServer(port: port)
        let client = UDPInputClient(serverHost: "127.0.0.1", serverPort: port)

        let displayBounds = CGRect(x: 300, y: 40, width: 1512, height: 982)
        let host = HostReceiver(displayBounds: displayBounds)

        await server.setInputEventHandler { event in
            Task { await host.receive(event) }
            return nil
        }

        addTeardownBlock {
            await client.stop()
            await server.stop()
        }

        try await server.start()
        try await client.start()

        try await Task.sleep(nanoseconds: 100_000_000)

        var viewer = ViewerHarness(
            containerBounds: CGRect(x: 0, y: 0, width: 1280, height: 800),
            remoteVideoWidth: 1920,
            remoteVideoHeight: 1080
        )

        // Step 1: click/capture at visual center.
        let captureEvent = viewer.capture(at: CGPoint(x: 640, y: 400), timestamp: 1_000)
        await client.sendInputEvent(captureEvent)
        try await waitForMoveCount(host: host, expected: 1)
        try await assertHostPoint(host: host, expected: CGPoint(x: 1056.0, y: 531.0))
        let captureSnapshot = await host.snapshot()

        // Step 2: move right and up in local AppKit space (Y increases upward).
        let moveUp = viewer.move(to: CGPoint(x: 768, y: 490), timestamp: 2_000)
        await client.sendInputEvent(moveUp)
        try await waitForMoveCount(host: host, expected: 2)
        try await assertHostPoint(host: host, expected: CGPoint(x: 1207.2, y: 408.25))
        let moveUpSnapshot = await host.snapshot()
        if let startY = captureSnapshot.point?.y, let movedY = moveUpSnapshot.point?.y {
            XCTAssertLessThan(movedY, startY, "moving up locally must decrease host Y (top-left coordinates)")
        }

        // Step 3: move down locally and ensure host Y increases.
        let moveDown = viewer.move(to: CGPoint(x: 768, y: 430), timestamp: 2_500)
        await client.sendInputEvent(moveDown)
        try await waitForMoveCount(host: host, expected: 3)
        try await assertHostPoint(host: host, expected: CGPoint(x: 1207.2, y: 490.083))
        let moveDownSnapshot = await host.snapshot()
        if let upY = moveUpSnapshot.point?.y, let downY = moveDownSnapshot.point?.y {
            XCTAssertGreaterThan(downY, upY, "moving down locally must increase host Y")
        }

        // Step 4: stream resolution changes to 4:3. Viewer recomputes aspect-fit rect.
        viewer.updateRemoteVideoSize(width: 1280, height: 960)
        let postChangeRect = viewer.videoRect
        XCTAssertEqual(postChangeRect.height, 800, accuracy: 0.001)
        XCTAssertEqual(postChangeRect.width, 1066.666, accuracy: 0.01)

        // Step 5: move to an absolute point in the resized video rect.
        let moveAfterResize = viewer.move(to: CGPoint(x: 853.333, y: 420), timestamp: 3_000)
        await client.sendInputEvent(moveAfterResize)
        try await waitForMoveCount(host: host, expected: 4)
        try await assertHostPoint(host: host, expected: CGPoint(x: 1358.4, y: 506.45))

        // Step 6: out-of-order packet should not rewind position.
        let stale = InputEvent(type: .mouseMove, timestamp: 2_500, x: 0.05, y: 0.95)
        await client.sendInputEvent(stale)
        try await Task.sleep(nanoseconds: 100_000_000)

        let snapshot = await host.snapshot()
        XCTAssertEqual(snapshot.count, 4, "stale packet must be ignored")
        XCTAssertEqual(snapshot.timestamp, 3_000, "latest timestamp must stay unchanged")
        if let point = snapshot.point {
            XCTAssertEqual(point.x, 1358.4, accuracy: 1.0)
            XCTAssertEqual(point.y, 506.45, accuracy: 1.0)
        } else {
            XCTFail("expected host point after stale packet")
        }
    }

    private func waitForMoveCount(host: HostReceiver, expected: Int, timeout: TimeInterval = 2.0) async throws {
        let deadline = Date().timeIntervalSince1970 + timeout
        while true {
            let snapshot = await host.snapshot()
            if snapshot.count >= expected { return }
            if Date().timeIntervalSince1970 > deadline {
                XCTFail("timed out waiting for \(expected) mouse moves; got \(snapshot.count)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func assertHostPoint(host: HostReceiver, expected: CGPoint) async throws {
        let snapshot = await host.snapshot()
        guard let point = snapshot.point else {
            XCTFail("expected host point")
            return
        }
        XCTAssertEqual(point.x, expected.x, accuracy: 1.0)
        XCTAssertEqual(point.y, expected.y, accuracy: 1.0)
    }
}
