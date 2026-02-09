import XCTest
@testable import ScreenHeroCore

@available(macOS 12.3, *)
final class UDPInputTests: XCTestCase {

    actor TestState {
        var receivedEvent: InputEvent?
        var gotResponse: Bool = false

        func setReceived(_ event: InputEvent) {
            receivedEvent = event
        }

        func setResponse() {
            gotResponse = true
        }
    }

    func testInputServerClientRoundTrip() async throws {
        let port: UInt16 = 16000
        let server = UDPInputServer(port: port)
        let client = UDPInputClient(serverHost: "127.0.0.1", serverPort: port)
        let state = TestState()

        await server.setInputEventHandler { event in
            Task { await state.setReceived(event) }
            return InputEvent.releaseCapture()
        }

        await client.setInputEventHandler { event in
            if event.type == .releaseCapture {
                Task { await state.setResponse() }
            }
        }

        try await server.start()
        try await client.start()

        // Give connection time to become ready
        try await Task.sleep(nanoseconds: 100_000_000)

        await client.sendInputEvent(InputEvent(type: .mouseDown, button: .left))

        // Wait for roundtrip
        try await Task.sleep(nanoseconds: 300_000_000)

        let received = await state.receivedEvent
        let gotResponse = await state.gotResponse

        XCTAssertNotNil(received, "Server should receive input event")
        XCTAssertEqual(received?.type, .mouseDown)
        XCTAssertTrue(gotResponse, "Client should receive response event")

        await client.stop()
        await server.stop()
    }
}
