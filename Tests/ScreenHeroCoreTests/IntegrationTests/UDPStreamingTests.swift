import XCTest
@testable import ScreenHeroCore

@available(macOS 14.0, *)
final class UDPStreamingTests: XCTestCase {

    /// Test that UDPStreamServer and UDPStreamClient can communicate
    func testServerClientCommunication() async throws {
        let serverPort: UInt16 = 15000
        let clientListenPort: UInt16 = 15001

        // Create server
        let server = UDPStreamServer(port: serverPort)

        // Start server
        try await server.start()
        print("Server started on port \(serverPort)")

        // Create client
        let client = UDPStreamClient(serverHost: "127.0.0.1", serverPort: serverPort, listenPort: clientListenPort)

        // Start client
        try await client.start()
        print("Client started, listening on port \(clientListenPort)")

        // Wait for subscription to register
        try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 second

        // Check subscriber count
        let subCount = await server.subscriberCount
        print("Server has \(subCount) subscriber(s)")
        XCTAssertGreaterThan(subCount, 0, "Server should have at least one subscriber")

        // Create a test packet
        let testData = Data(repeating: 0xAB, count: 1000)
        let testPacket = EncodedPacket(
            frameId: 1,
            data: testData,
            presentationTimeNs: 0,
            isKeyframe: true,
            codec: .h264,
            width: 1920,
            height: 1080,
            captureTimestamp: DispatchTime.now().uptimeNanoseconds,
            encodeTimestamp: DispatchTime.now().uptimeNanoseconds,
            parameterSets: Data([0x00, 0x00, 0x00, 0x01, 0x67])
        )

        // Send packet from server
        try await server.send(testPacket)
        print("Server sent packet")

        // Get packets stream from client
        let packetsStream = await client.getPackets()

        // Wait for packet with timeout
        let receivedPacket = await withTaskGroup(of: EncodedPacket?.self) { group in
            group.addTask {
                for await packet in packetsStream {
                    return packet
                }
                return nil
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3 second timeout
                return nil
            }

            let result = await group.next()
            group.cancelAll()
            return result ?? nil
        }

        XCTAssertNotNil(receivedPacket, "Client should receive a packet")

        if let packet = receivedPacket {
            print("Client received packet: frameId=\(packet.frameId), size=\(packet.data.count)")
            XCTAssertEqual(packet.frameId, testPacket.frameId)
            XCTAssertEqual(packet.data, testPacket.data)
            XCTAssertEqual(packet.isKeyframe, testPacket.isKeyframe)
        }

        // Cleanup
        await client.stop()
        await server.stop()
        print("Test completed successfully")
    }

    /// Test multiple packets in sequence
    func testMultiplePackets() async throws {
        let serverPort: UInt16 = 15010
        let clientListenPort: UInt16 = 15011

        let server = UDPStreamServer(port: serverPort)
        try await server.start()

        let client = UDPStreamClient(serverHost: "127.0.0.1", serverPort: serverPort, listenPort: clientListenPort)
        try await client.start()

        // Wait for subscription
        try await Task.sleep(nanoseconds: 500_000_000)

        let packetCount = 10
        var receivedCount = 0

        // Start receiving task
        let receiveTask = Task {
            let packetsStream = await client.getPackets()
            for await _ in packetsStream {
                receivedCount += 1
                if receivedCount >= packetCount {
                    break
                }
            }
        }

        // Send packets
        for i in 0..<packetCount {
            let packet = EncodedPacket(
                frameId: UInt64(i),
                data: Data(repeating: UInt8(i), count: 500),
                presentationTimeNs: UInt64(i) * 16_666_666,
                isKeyframe: i == 0,
                codec: .h264,
                width: 1920,
                height: 1080,
                captureTimestamp: DispatchTime.now().uptimeNanoseconds,
                encodeTimestamp: DispatchTime.now().uptimeNanoseconds
            )
            try await server.send(packet)
            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms between packets
        }

        // Wait for receive or timeout
        try await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
        receiveTask.cancel()

        print("Received \(receivedCount) of \(packetCount) packets")
        XCTAssertGreaterThan(receivedCount, 0, "Should receive at least some packets")

        await client.stop()
        await server.stop()
    }

    /// Full E2E test: SyntheticFrameSource -> Encoder -> UDP -> Decoder
    /// This tests the complete streaming pipeline without needing screen capture permissions
    func testFullPipelineE2E() async throws {
        let serverPort: UInt16 = 15020

        let config = StreamConfig(
            width: 640,
            height: 480,
            fps: 30,
            codec: .h264,
            bitrate: 5_000_000,
            keyframeInterval: 15,
            lowLatencyMode: true
        )

        // Create components
        let source = SyntheticFrameSource(config: config, pattern: .colorBars)
        let encoder = VideoToolboxEncoder()
        let server = UDPStreamServer(port: serverPort)
        let client = UDPStreamClient(serverHost: "127.0.0.1", serverPort: serverPort)
        let decoder = VideoToolboxDecoder()

        // Configure encoder and decoder
        try await encoder.configure(config)
        try await decoder.configure(config)

        // Start network
        try await server.start()
        try await client.start()

        // Wait for subscription
        try await Task.sleep(nanoseconds: 500_000_000)

        // Track decoded frames
        var decodedFrames = 0
        let targetFrames = 30  // 1 second at 30fps

        // Start decoder task
        let decoderTask = Task {
            let packetsStream = await client.getPackets()
            for await packet in packetsStream {
                do {
                    _ = try await decoder.decode(packet)
                    decodedFrames += 1
                    if decodedFrames >= targetFrames {
                        break
                    }
                } catch VideoDecoderError.waitingForKeyframe {
                    continue
                } catch {
                    // Ignore other errors
                }
            }
        }

        // Start source and encode/send frames
        try await source.start()
        let framesStream = await source.frames

        var framesSent = 0
        for await sampleBuffer in framesStream {
            do {
                let packet = try await encoder.encode(sampleBuffer)
                try await server.send(packet)
                framesSent += 1

                // Stop after sending enough frames
                if framesSent >= targetFrames + 20 {  // Extra frames to ensure keyframe arrives
                    break
                }
            } catch VideoEncoderError.noImageBuffer {
                continue
            } catch {
                print("Encode error: \(error)")
            }
        }

        // Wait for decoder to finish or timeout
        try await Task.sleep(nanoseconds: 3_000_000_000)  // 3 seconds
        decoderTask.cancel()

        // Cleanup
        await source.stop()
        await client.stop()
        await server.stop()

        print("E2E Test: Sent \(framesSent) frames, decoded \(decodedFrames) frames")
        XCTAssertGreaterThan(decodedFrames, 0, "Should decode at least some frames")
        XCTAssertGreaterThanOrEqual(decodedFrames, targetFrames / 2, "Should decode at least half the target frames")
    }
}
