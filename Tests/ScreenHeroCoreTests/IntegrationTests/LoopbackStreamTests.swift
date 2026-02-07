import XCTest
import CoreMedia
import CoreVideo
@testable import ScreenHeroCore

final class LoopbackStreamTests: XCTestCase {

    // MARK: - Loopback Transport Tests

    func testLoopbackTransportSendReceive() async throws {
        let transport = LoopbackTransport()
        let sender = transport.senderSide
        let receiver = transport.receiverSide

        try await sender.start()
        try await receiver.start()

        let testPacket = EncodedPacket(
            frameId: 42,
            data: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            presentationTimeNs: 123456,
            isKeyframe: true,
            codec: .h264,
            width: 1920,
            height: 1080,
            captureTimestamp: 100,
            encodeTimestamp: 200
        )

        // Get packets stream before sending
        let packets = await receiver.getPackets()

        // Send packet
        try await sender.send(testPacket)

        // Receive packet
        var receivedPacket: EncodedPacket?
        for await packet in packets {
            receivedPacket = packet
            break
        }

        XCTAssertNotNil(receivedPacket)
        XCTAssertEqual(receivedPacket?.frameId, 42)
        XCTAssertEqual(receivedPacket?.data, Data([0xDE, 0xAD, 0xBE, 0xEF]))

        await sender.stop()
        await receiver.stop()
    }

    func testLoopbackTransportMultiplePackets() async throws {
        let transport = LoopbackTransport()
        let sender = transport.senderSide
        let receiver = transport.receiverSide

        try await sender.start()
        try await receiver.start()

        let packetsToSend = 10
        let packets = await receiver.getPackets()

        // Send multiple packets
        Task {
            for i in 0..<packetsToSend {
                let packet = EncodedPacket(
                    frameId: UInt64(i),
                    data: Data([UInt8(i)]),
                    presentationTimeNs: UInt64(i * 16_666_666),
                    isKeyframe: i == 0,
                    codec: .h264,
                    width: 1920,
                    height: 1080,
                    captureTimestamp: DispatchTime.now().uptimeNanoseconds,
                    encodeTimestamp: DispatchTime.now().uptimeNanoseconds
                )
                try await sender.send(packet)
            }
        }

        // Receive packets
        var receivedCount = 0
        for await packet in packets {
            XCTAssertEqual(packet.frameId, UInt64(receivedCount))
            receivedCount += 1
            if receivedCount == packetsToSend {
                break
            }
        }

        XCTAssertEqual(receivedCount, packetsToSend)

        await sender.stop()
        await receiver.stop()
    }

    // MARK: - Full Pipeline Tests

    func testFullPipelineLoopback() async throws {
        // Use synthetic frames instead of ScreenCaptureKit
        let source = SyntheticFrameSource(
            config: StreamConfig.testing,
            pattern: .colorBars
        )

        // Use passthrough encoder/decoder for simplicity
        let encoder = PassthroughEncoder()
        let decoder = PassthroughDecoder()

        // Use loopback transport
        let transport = LoopbackTransport()
        let sender = transport.senderSide
        let receiver = transport.receiverSide

        try await encoder.configure(StreamConfig.testing)
        try await decoder.configure(StreamConfig.testing)
        try await sender.start()
        try await receiver.start()

        // Get frames stream before starting
        let framesStream = await source.getFrames()
        try await source.start()

        let packets = await receiver.getPackets()

        var framesReceived = 0
        var latencies: [Double] = []

        // Pipeline: source -> encode -> send -> receive -> decode
        Task {
            for await sampleBuffer in framesStream {
                do {
                    let encoded = try await encoder.encode(sampleBuffer)
                    try await sender.send(encoded)
                } catch {
                    print("Pipeline error: \(error)")
                }

                // Stop after some frames
                if framesReceived >= 30 {
                    break
                }
            }
        }

        // Receive and decode
        for await packet in packets {
            let receiveTime = DispatchTime.now().uptimeNanoseconds
            let latencyNs = receiveTime - packet.captureTimestamp
            let latencyMs = Double(latencyNs) / 1_000_000

            latencies.append(latencyMs)

            _ = try await decoder.decode(packet)
            framesReceived += 1

            if framesReceived >= 30 {
                break
            }
        }

        await source.stop()
        await sender.stop()
        await receiver.stop()

        XCTAssertGreaterThanOrEqual(framesReceived, 30)

        if !latencies.isEmpty {
            let avgLatency = latencies.reduce(0, +) / Double(latencies.count)
            print("Average loopback latency: \(avgLatency)ms")
            // Loopback should be very fast
            XCTAssertLessThan(avgLatency, 100, "Loopback latency should be under 100ms")
        }
    }

    func testFullPipelineWithVideoToolbox() async throws {
        let source = SyntheticFrameSource(
            config: StreamConfig(
                width: 320,
                height: 240,
                fps: 30,
                codec: .h264,
                bitrate: 1_000_000,
                keyframeInterval: 30,
                lowLatencyMode: true
            ),
            pattern: .gradient
        )

        let encoder = VideoToolboxEncoder()
        let decoder = VideoToolboxDecoder()

        let transport = LoopbackTransport()
        let sender = transport.senderSide
        let receiver = transport.receiverSide

        let config = StreamConfig(
            width: 320,
            height: 240,
            fps: 30,
            codec: .h264,
            bitrate: 1_000_000,
            keyframeInterval: 30,
            lowLatencyMode: true
        )

        try await encoder.configure(config)
        try await decoder.configure(config)
        try await sender.start()
        try await receiver.start()

        // Get frames stream before starting
        let framesStream = await source.getFrames()
        try await source.start()

        let packets = await receiver.getPackets()

        var framesEncoded = 0
        var framesDecoded = 0

        // Encoding pipeline
        Task {
            for await sampleBuffer in framesStream {
                do {
                    let encoded = try await encoder.encode(sampleBuffer)
                    try await sender.send(encoded)
                    framesEncoded += 1
                } catch {
                    print("Encode error: \(error)")
                }

                if framesEncoded >= 15 {
                    break
                }
            }
        }

        // Decoding pipeline
        for await packet in packets {
            do {
                let pixelBuffer = try await decoder.decode(packet)
                XCTAssertEqual(CVPixelBufferGetWidth(pixelBuffer), 320)
                XCTAssertEqual(CVPixelBufferGetHeight(pixelBuffer), 240)
                framesDecoded += 1
            } catch {
                print("Decode error: \(error)")
            }

            if framesDecoded >= 15 {
                break
            }
        }

        await source.stop()
        await sender.stop()
        await receiver.stop()

        XCTAssertGreaterThanOrEqual(framesDecoded, 10)
    }

    // MARK: - Jitter Buffer Integration

    func testPipelineWithJitterBuffer() async throws {
        let transport = LoopbackTransport()
        let sender = transport.senderSide
        let receiver = transport.receiverSide
        let jitterBuffer = JitterBuffer()

        try await sender.start()
        try await receiver.start()

        let packets = await receiver.getPackets()

        // Send packets (simulate out-of-order arrival by shuffling)
        Task {
            var packetsToSend: [EncodedPacket] = []
            for i in 0..<20 {
                let packet = EncodedPacket(
                    frameId: UInt64(i),
                    data: Data([UInt8(i)]),
                    presentationTimeNs: UInt64(i * 16_666_666),
                    isKeyframe: i == 0,
                    codec: .h264,
                    width: 1920,
                    height: 1080,
                    captureTimestamp: DispatchTime.now().uptimeNanoseconds,
                    encodeTimestamp: DispatchTime.now().uptimeNanoseconds
                )
                packetsToSend.append(packet)
            }

            // Shuffle to simulate out-of-order delivery
            packetsToSend.shuffle()

            for packet in packetsToSend {
                try await sender.send(packet)
            }
        }

        // Receive into jitter buffer
        var receivedCount = 0
        for await packet in packets {
            await jitterBuffer.insert(packet)
            receivedCount += 1
            if receivedCount >= 20 {
                break
            }
        }

        // Pop from jitter buffer - should come out in order
        var lastFrameId: UInt64 = 0
        var orderedCount = 0

        for _ in 0..<20 {
            if let packet = await jitterBuffer.pop() {
                XCTAssertGreaterThanOrEqual(packet.frameId, lastFrameId)
                lastFrameId = packet.frameId
                orderedCount += 1
            }
        }

        let stats = await jitterBuffer.statistics
        print("Jitter buffer stats: received=\(stats.packetsReceived), reordered=\(stats.packetsReordered)")

        XCTAssertGreaterThan(orderedCount, 0)

        await sender.stop()
        await receiver.stop()
    }

    // MARK: - Latency Measurement

    func testEndToEndLatency() async throws {
        let transport = LoopbackTransport()
        let sender = transport.senderSide
        let receiver = transport.receiverSide

        try await sender.start()
        try await receiver.start()

        let packets = await receiver.getPackets()
        var latencies: [Double] = []

        // Send packets with timestamps
        Task {
            for i in 0..<50 {
                let packet = EncodedPacket(
                    frameId: UInt64(i),
                    data: Data(repeating: 0, count: 10000), // Moderate size
                    presentationTimeNs: UInt64(i * 16_666_666),
                    isKeyframe: i == 0,
                    codec: .h264,
                    width: 1920,
                    height: 1080,
                    captureTimestamp: DispatchTime.now().uptimeNanoseconds,
                    encodeTimestamp: DispatchTime.now().uptimeNanoseconds
                )
                try await sender.send(packet)

                // Simulate 60fps timing
                try await Task.sleep(nanoseconds: 16_666_666)
            }
        }

        // Measure receive latency
        var count = 0
        for await packet in packets {
            let receiveTime = DispatchTime.now().uptimeNanoseconds
            let latencyNs = receiveTime - packet.captureTimestamp
            let latencyMs = Double(latencyNs) / 1_000_000

            latencies.append(latencyMs)
            count += 1

            if count >= 50 {
                break
            }
        }

        await sender.stop()
        await receiver.stop()

        if !latencies.isEmpty {
            let avg = latencies.reduce(0, +) / Double(latencies.count)
            let max = latencies.max() ?? 0
            let min = latencies.min() ?? 0

            print("Latency (ms): avg=\(avg), min=\(min), max=\(max)")

            // Loopback should have very low latency
            XCTAssertLessThan(avg, 50)
        }
    }
}
