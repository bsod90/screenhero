import XCTest
import CoreGraphics
import Foundation
@testable import ScreenHeroCore

/// End-to-end tests for viewer -> UDP -> host -> UDP -> viewer coordinate translation.
final class MouseCoordinateE2ETests: XCTestCase {
    private final class HostReceiver: @unchecked Sendable {
        let displayBounds: CGRect
        private let lock = NSLock()
        private var acceptedMoveCount = 0
        private var lastTimestamp: UInt64 = 0
        private var lastScreenPoint: CGPoint?

        init(displayBounds: CGRect) {
            self.displayBounds = displayBounds
        }

        func receive(_ event: InputEvent) -> InputEvent? {
            guard event.type == .mouseMove else { return nil }

            lock.lock()
            defer { lock.unlock() }

            guard event.timestamp >= lastTimestamp else { return nil }

            lastTimestamp = event.timestamp
            lastScreenPoint = MouseCoordinateTransform.normalizedTopLeftToCGDisplayPoint(
                CGPoint(x: CGFloat(event.x), y: CGFloat(event.y)),
                displayBounds: displayBounds
            )
            acceptedMoveCount += 1

            // Echo authoritative host cursor position back to the viewer using
            // the same CG display coordinate system as real host cursor tracking.
            let echoedNormalized = MouseCoordinateTransform.cgDisplayPointToNormalizedTopLeft(
                lastScreenPoint ?? .zero,
                displayBounds: displayBounds
            )
            return InputEvent.cursorPosition(
                x: Float(echoedNormalized.x),
                y: Float(echoedNormalized.y),
                cursorType: .arrow
            )
        }

        func snapshot() -> (count: Int, timestamp: UInt64, point: CGPoint?) {
            lock.lock()
            defer { lock.unlock() }
            return (acceptedMoveCount, lastTimestamp, lastScreenPoint)
        }
    }

    private final class ViewerCursorReceiver: @unchecked Sendable {
        private let lock = NSLock()
        private var cursorEventCount = 0
        private var lastCursorEvent: InputEvent?

        func receive(_ event: InputEvent) {
            guard event.type == .cursorPosition else { return }

            lock.lock()
            defer { lock.unlock() }
            cursorEventCount += 1
            lastCursorEvent = event
        }

        func snapshot() -> (count: Int, event: InputEvent?) {
            lock.lock()
            defer { lock.unlock() }
            return (cursorEventCount, lastCursorEvent)
        }
    }

    private struct ViewerHarness {
        var containerBounds: CGRect
        var remoteVideoWidth: CGFloat
        var remoteVideoHeight: CGFloat
        var normalizedPosition: CGPoint = CGPoint(x: 0.5, y: 0.5)

        // Non-trivial hot-spot to validate cursor image origin math.
        var cursorImageSize: CGSize = CGSize(width: 20, height: 30)
        var cursorHotSpotTopLeft: CGPoint = CGPoint(x: 4, y: 6)

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

        func localHotSpotPoint(for cursorEvent: InputEvent) -> CGPoint {
            MouseCoordinateTransform.normalizedTopLeftToViewPoint(
                CGPoint(x: CGFloat(cursorEvent.x), y: CGFloat(cursorEvent.y)),
                in: videoRect
            )
        }

        func cursorImageOrigin(for cursorEvent: InputEvent) -> CGPoint {
            MouseCoordinateTransform.cursorImageOriginForHotSpotPosition(
                hotSpotPosition: localHotSpotPoint(for: cursorEvent),
                imageSize: cursorImageSize,
                hotSpotTopLeft: cursorHotSpotTopLeft
            )
        }

        func reconstructedHotSpot(from cursorImageOrigin: CGPoint) -> CGPoint {
            CGPoint(
                x: cursorImageOrigin.x + cursorHotSpotTopLeft.x,
                y: cursorImageOrigin.y + (cursorImageSize.height - cursorHotSpotTopLeft.y)
            )
        }
    }

    func testMouseCoordinatesRoundTripOverUDPWithResolutionChange() async throws {
        let port: UInt16 = 17610
        let server = UDPInputServer(port: port)
        let client = UDPInputClient(serverHost: "127.0.0.1", serverPort: port)

        let displayBounds = CGRect(x: 300, y: 40, width: 1512, height: 982)
        let host = HostReceiver(displayBounds: displayBounds)
        let viewerCursor = ViewerCursorReceiver()

        await server.setInputEventHandler { event in
            host.receive(event)
        }

        await client.setInputEventHandler { event in
            viewerCursor.receive(event)
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
        let capturePoint = CGPoint(x: 640, y: 400)
        let captureEvent = viewer.capture(at: capturePoint, timestamp: 1_000)
        await client.sendInputEvent(captureEvent)
        try await waitForMoveCount(host: host, expected: 1)
        try await waitForCursorCount(viewerCursor: viewerCursor, expected: 1)
        assertHostPoint(host: host, expected: CGPoint(x: 1056.0, y: 531.0))
        assertViewerCursorHotSpot(viewer: viewer, viewerCursor: viewerCursor, expected: capturePoint)
        let captureSnapshot = host.snapshot()

        // Step 2: move right and up in local AppKit space (Y increases upward).
        let moveUpPoint = CGPoint(x: 768, y: 490)
        let moveUp = viewer.move(to: moveUpPoint, timestamp: 2_000)
        await client.sendInputEvent(moveUp)
        try await waitForMoveCount(host: host, expected: 2)
        try await waitForCursorCount(viewerCursor: viewerCursor, expected: 2)
        assertHostPoint(host: host, expected: CGPoint(x: 1207.2, y: 408.25))
        assertViewerCursorHotSpot(viewer: viewer, viewerCursor: viewerCursor, expected: moveUpPoint)

        let moveUpSnapshot = host.snapshot()
        if let startY = captureSnapshot.point?.y, let movedY = moveUpSnapshot.point?.y {
            XCTAssertLessThan(movedY, startY, "moving up locally must decrease host Y (top-left coordinates)")
        }

        // Step 3: move down locally and ensure host Y increases.
        let moveDownPoint = CGPoint(x: 768, y: 430)
        let moveDown = viewer.move(to: moveDownPoint, timestamp: 2_500)
        await client.sendInputEvent(moveDown)
        try await waitForMoveCount(host: host, expected: 3)
        try await waitForCursorCount(viewerCursor: viewerCursor, expected: 3)
        assertHostPoint(host: host, expected: CGPoint(x: 1207.2, y: 490.083))
        assertViewerCursorHotSpot(viewer: viewer, viewerCursor: viewerCursor, expected: moveDownPoint)

        let moveDownSnapshot = host.snapshot()
        if let upY = moveUpSnapshot.point?.y, let downY = moveDownSnapshot.point?.y {
            XCTAssertGreaterThan(downY, upY, "moving down locally must increase host Y")
        }

        // Step 4: stream resolution changes to 4:3. Viewer recomputes aspect-fit rect.
        viewer.updateRemoteVideoSize(width: 1280, height: 960)
        let postChangeRect = viewer.videoRect
        XCTAssertEqual(postChangeRect.height, 800, accuracy: 0.001)
        XCTAssertEqual(postChangeRect.width, 1066.666, accuracy: 0.01)

        // Step 5: move to an absolute point in the resized video rect.
        let moveAfterResizePoint = CGPoint(x: 853.333, y: 420)
        let moveAfterResize = viewer.move(to: moveAfterResizePoint, timestamp: 3_000)
        await client.sendInputEvent(moveAfterResize)
        try await waitForMoveCount(host: host, expected: 4)
        try await waitForCursorCount(viewerCursor: viewerCursor, expected: 4)
        assertHostPoint(host: host, expected: CGPoint(x: 1358.4, y: 506.45))
        assertViewerCursorHotSpot(viewer: viewer, viewerCursor: viewerCursor, expected: moveAfterResizePoint)

        // Step 6: out-of-order packet should not rewind host OR viewer cursor.
        let stale = InputEvent(type: .mouseMove, timestamp: 2_500, x: 0.05, y: 0.95)
        await client.sendInputEvent(stale)
        try await Task.sleep(nanoseconds: 150_000_000)

        let hostSnapshot = host.snapshot()
        XCTAssertEqual(hostSnapshot.count, 4, "stale packet must be ignored by host")
        XCTAssertEqual(hostSnapshot.timestamp, 3_000, "latest timestamp must stay unchanged")
        if let point = hostSnapshot.point {
            XCTAssertEqual(point.x, 1358.4, accuracy: 1.0)
            XCTAssertEqual(point.y, 506.45, accuracy: 1.0)
        } else {
            XCTFail("expected host point after stale packet")
        }

        let viewerSnapshot = viewerCursor.snapshot()
        XCTAssertEqual(viewerSnapshot.count, 4, "stale packet should not produce a new cursor echo")
        assertViewerCursorHotSpot(viewer: viewer, viewerCursor: viewerCursor, expected: moveAfterResizePoint)
    }

    private func waitForMoveCount(host: HostReceiver, expected: Int, timeout: TimeInterval = 2.0) async throws {
        let deadline = Date().timeIntervalSince1970 + timeout
        while true {
            let snapshot = host.snapshot()
            if snapshot.count >= expected { return }
            if Date().timeIntervalSince1970 > deadline {
                XCTFail("timed out waiting for \(expected) host moves; got \(snapshot.count)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func waitForCursorCount(viewerCursor: ViewerCursorReceiver, expected: Int, timeout: TimeInterval = 2.0) async throws {
        let deadline = Date().timeIntervalSince1970 + timeout
        while true {
            let snapshot = viewerCursor.snapshot()
            if snapshot.count >= expected { return }
            if Date().timeIntervalSince1970 > deadline {
                XCTFail("timed out waiting for \(expected) cursor echoes; got \(snapshot.count)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func assertHostPoint(host: HostReceiver, expected: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        let snapshot = host.snapshot()
        guard let point = snapshot.point else {
            XCTFail("expected host point", file: file, line: line)
            return
        }
        XCTAssertEqual(point.x, expected.x, accuracy: 1.0, file: file, line: line)
        XCTAssertEqual(point.y, expected.y, accuracy: 1.0, file: file, line: line)
    }

    private func assertViewerCursorHotSpot(
        viewer: ViewerHarness,
        viewerCursor: ViewerCursorReceiver,
        expected: CGPoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let snapshot = viewerCursor.snapshot()
        guard let cursorEvent = snapshot.event else {
            XCTFail("expected cursor echo event", file: file, line: line)
            return
        }

        let origin = viewer.cursorImageOrigin(for: cursorEvent)
        let reconstructedHotSpot = viewer.reconstructedHotSpot(from: origin)
        XCTAssertEqual(reconstructedHotSpot.x, expected.x, accuracy: 0.75, file: file, line: line)
        XCTAssertEqual(reconstructedHotSpot.y, expected.y, accuracy: 0.75, file: file, line: line)
    }
}
