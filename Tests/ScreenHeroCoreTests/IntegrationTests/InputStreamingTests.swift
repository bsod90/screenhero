import XCTest
@testable import ScreenHeroCore

/// Integration tests for input event streaming between client and server
final class InputStreamingTests: XCTestCase {

    // MARK: - Basic Input Event Transmission

    func testInputEventRoundTrip() async throws {
        // Create server and client
        let serverPort: UInt16 = 15000

        let server = UDPStreamServer(port: serverPort)
        let client = UDPStreamClient(serverHost: "127.0.0.1", serverPort: serverPort)

        // Track received events
        var receivedEvents: [InputEvent] = []
        let eventReceived = XCTestExpectation(description: "Input event received")
        eventReceived.expectedFulfillmentCount = 3

        // Set up input event handler on server
        await server.setInputEventHandler { event in
            receivedEvents.append(event)
            eventReceived.fulfill()
            return nil // No response needed
        }

        // Start both
        try await server.start()
        try await client.start()

        // Wait for connection to establish
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Send input events from client
        let events = [
            InputEvent.mouseMove(deltaX: 10, deltaY: 20),
            InputEvent.mouseDown(button: .left),
            InputEvent.keyDown(keyCode: 0, modifiers: [.command])
        ]

        for event in events {
            await client.sendInputEvent(event)
        }

        // Wait for events to be received
        await fulfillment(of: [eventReceived], timeout: 2.0)

        // Verify events were received correctly
        XCTAssertEqual(receivedEvents.count, 3)
        XCTAssertEqual(receivedEvents[0].type, .mouseMove)
        XCTAssertEqual(receivedEvents[0].x, 10)
        XCTAssertEqual(receivedEvents[0].y, 20)
        XCTAssertEqual(receivedEvents[1].type, .mouseDown)
        XCTAssertEqual(receivedEvents[1].button, .left)
        XCTAssertEqual(receivedEvents[2].type, .keyDown)
        XCTAssertEqual(receivedEvents[2].keyCode, 0)
        XCTAssertTrue(receivedEvents[2].modifiers.contains(.command))

        // Cleanup
        await client.stop()
        await server.stop()
    }

    // MARK: - Release Capture Response

    func testReleaseCaptureResponse() async throws {
        let serverPort: UInt16 = 15001

        let server = UDPStreamServer(port: serverPort)
        let client = UDPStreamClient(serverHost: "127.0.0.1", serverPort: serverPort)

        // Track release capture events received by client
        let releaseReceived = XCTestExpectation(description: "Release capture received")
        var clientReceivedReleaseCapture = false

        // Server sends releaseCapture in response to mouseMove
        await server.setInputEventHandler { event in
            if event.type == .mouseMove {
                return InputEvent.releaseCapture()
            }
            return nil
        }

        // Client handles incoming events
        await client.setInputEventHandler { event in
            if event.type == .releaseCapture {
                clientReceivedReleaseCapture = true
                releaseReceived.fulfill()
            }
        }

        try await server.start()
        try await client.start()

        // Wait for connection
        try await Task.sleep(nanoseconds: 100_000_000)

        // Send mouse move (should trigger releaseCapture response)
        await client.sendInputEvent(InputEvent.mouseMove(deltaX: 100, deltaY: 100))

        // Wait for response
        await fulfillment(of: [releaseReceived], timeout: 2.0)

        XCTAssertTrue(clientReceivedReleaseCapture, "Client should have received releaseCapture")

        await client.stop()
        await server.stop()
    }

    // MARK: - Many Events Stress Test

    func testManyInputEvents() async throws {
        let serverPort: UInt16 = 15002

        let server = UDPStreamServer(port: serverPort)
        let client = UDPStreamClient(serverHost: "127.0.0.1", serverPort: serverPort)

        var receivedCount = 0
        let allReceived = XCTestExpectation(description: "All events received")
        let totalEvents = 100

        await server.setInputEventHandler { _ in
            receivedCount += 1
            if receivedCount >= totalEvents {
                allReceived.fulfill()
            }
            return nil
        }

        try await server.start()
        try await client.start()

        // Wait for connection
        try await Task.sleep(nanoseconds: 100_000_000)

        // Send many events
        for i in 0..<totalEvents {
            let event = InputEvent.mouseMove(deltaX: Float(i), deltaY: Float(i))
            await client.sendInputEvent(event)
        }

        await fulfillment(of: [allReceived], timeout: 5.0)

        XCTAssertEqual(receivedCount, totalEvents, "All events should be received")

        await client.stop()
        await server.stop()
    }

    // MARK: - Event Types

    func testAllEventTypesTransmission() async throws {
        let serverPort: UInt16 = 15003

        let server = UDPStreamServer(port: serverPort)
        let client = UDPStreamClient(serverHost: "127.0.0.1", serverPort: serverPort)

        var receivedTypes: Set<InputEvent.EventType> = []
        let allReceived = XCTestExpectation(description: "All event types received")
        let expectedTypes: Set<InputEvent.EventType> = [.mouseMove, .mouseDown, .mouseUp, .scroll, .keyDown, .keyUp]

        await server.setInputEventHandler { event in
            receivedTypes.insert(event.type)
            if receivedTypes == expectedTypes {
                allReceived.fulfill()
            }
            return nil
        }

        try await server.start()
        try await client.start()

        try await Task.sleep(nanoseconds: 100_000_000)

        // Send one of each type
        await client.sendInputEvent(InputEvent.mouseMove(deltaX: 1, deltaY: 1))
        await client.sendInputEvent(InputEvent.mouseDown(button: .left))
        await client.sendInputEvent(InputEvent.mouseUp(button: .left))
        await client.sendInputEvent(InputEvent.scroll(deltaX: 1, deltaY: 1))
        await client.sendInputEvent(InputEvent.keyDown(keyCode: 0, modifiers: []))
        await client.sendInputEvent(InputEvent.keyUp(keyCode: 0, modifiers: []))

        await fulfillment(of: [allReceived], timeout: 2.0)

        XCTAssertEqual(receivedTypes, expectedTypes)

        await client.stop()
        await server.stop()
    }
}
