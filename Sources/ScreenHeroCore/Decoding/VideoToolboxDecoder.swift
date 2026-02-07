import CoreVideo
import Foundation
import VideoToolbox

/// Hardware-accelerated video decoder using VideoToolbox
public actor VideoToolboxDecoder: VideoDecoder {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var config: StreamConfig?
    private var pendingDecodes: [UInt64: PendingDecode] = [:]
    private var decodeCounter: UInt64 = 0

    private struct PendingDecode {
        let continuation: CheckedContinuation<CVPixelBuffer, Error>
    }

    public init() {}

    public func configure(_ config: StreamConfig) async throws {
        self.config = config

        // Session will be created on first decode when we have format info
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
    }

    public func decode(_ packet: EncodedPacket) async throws -> CVPixelBuffer {
        // Handle passthrough mode
        if packet.codec == .passthrough {
            return try createPixelBufferFromRaw(packet: packet)
        }

        // Create or update format description if we have parameter sets
        if let paramSets = packet.parameterSets {
            try updateFormatDescription(from: paramSets, codec: packet.codec, width: packet.width, height: packet.height)
        }

        guard let formatDescription = formatDescription else {
            throw VideoDecoderError.formatDescriptionMissing
        }

        // Create session if needed
        if decompressionSession == nil {
            try createDecompressionSession(formatDescription: formatDescription)
        }

        guard let session = decompressionSession else {
            throw VideoDecoderError.sessionCreationFailed
        }

        // Create sample buffer from encoded data
        let sampleBuffer = try createSampleBuffer(from: packet, formatDescription: formatDescription)

        let currentDecodeId = decodeCounter
        decodeCounter += 1

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingDecodes[currentDecodeId] = PendingDecode(continuation: continuation)

            var infoFlags = VTDecodeInfoFlags()
            let decodeFlags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression, ._EnableTemporalProcessing]

            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: decodeFlags,
                infoFlagsOut: &infoFlags
            ) { [weak self] status, flags, imageBuffer, pts, duration in
                guard let self = self else { return }

                Task {
                    await self.handleDecodedFrame(
                        status: status,
                        imageBuffer: imageBuffer,
                        decodeId: currentDecodeId
                    )
                }
            }

            if status != noErr {
                self.pendingDecodes.removeValue(forKey: currentDecodeId)
                continuation.resume(throwing: VideoDecoderError.decodingFailed("VTDecompressionSessionDecodeFrame failed: \(status)"))
            }
        }
    }

    private func handleDecodedFrame(
        status: OSStatus,
        imageBuffer: CVImageBuffer?,
        decodeId: UInt64
    ) async {
        guard let pending = pendingDecodes.removeValue(forKey: decodeId) else {
            return
        }

        if status != noErr {
            pending.continuation.resume(
                throwing: VideoDecoderError.decodingFailed("Decode callback error: \(status)")
            )
            return
        }

        guard let pixelBuffer = imageBuffer else {
            pending.continuation.resume(
                throwing: VideoDecoderError.decodingFailed("No image buffer in callback")
            )
            return
        }

        pending.continuation.resume(returning: pixelBuffer)
    }

    private func updateFormatDescription(from parameterSets: Data, codec: VideoCodec, width: Int, height: Int) throws {
        var paramSetPointers: [UnsafePointer<UInt8>] = []
        var paramSetSizes: [Int] = []

        // Parse NAL units from parameter sets
        var offset = 0
        while offset < parameterSets.count - 4 {
            // Find start code (0x00 0x00 0x00 0x01)
            if parameterSets[offset] == 0 && parameterSets[offset + 1] == 0 &&
               parameterSets[offset + 2] == 0 && parameterSets[offset + 3] == 1 {
                offset += 4

                // Find next start code or end
                var nalEnd = offset
                while nalEnd < parameterSets.count - 3 {
                    if parameterSets[nalEnd] == 0 && parameterSets[nalEnd + 1] == 0 &&
                       parameterSets[nalEnd + 2] == 0 && parameterSets[nalEnd + 3] == 1 {
                        break
                    }
                    nalEnd += 1
                }

                if nalEnd == parameterSets.count - 3 {
                    nalEnd = parameterSets.count
                }

                if nalEnd > offset {
                    parameterSets.withUnsafeBytes { ptr in
                        if let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                            paramSetPointers.append(base.advanced(by: offset))
                            paramSetSizes.append(nalEnd - offset)
                        }
                    }
                }

                offset = nalEnd
            } else {
                offset += 1
            }
        }

        guard !paramSetPointers.isEmpty else {
            throw VideoDecoderError.invalidData
        }

        var newFormatDescription: CMFormatDescription?
        let status: OSStatus

        switch codec {
        case .h264:
            status = paramSetPointers.withUnsafeBufferPointer { pointers in
                paramSetSizes.withUnsafeBufferPointer { sizes in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: paramSetPointers.count,
                        parameterSetPointers: pointers.baseAddress!,
                        parameterSetSizes: sizes.baseAddress!,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &newFormatDescription
                    )
                }
            }

        case .hevc:
            status = paramSetPointers.withUnsafeBufferPointer { pointers in
                paramSetSizes.withUnsafeBufferPointer { sizes in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: paramSetPointers.count,
                        parameterSetPointers: pointers.baseAddress!,
                        parameterSetSizes: sizes.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &newFormatDescription
                    )
                }
            }

        case .passthrough:
            return
        }

        guard status == noErr, let formatDesc = newFormatDescription else {
            throw VideoDecoderError.decodingFailed("Failed to create format description: \(status)")
        }

        // Check if format changed
        if let existing = formatDescription {
            if !CMFormatDescriptionEqual(existing, otherFormatDescription: formatDesc) {
                // Format changed, recreate session
                if let session = decompressionSession {
                    VTDecompressionSessionInvalidate(session)
                    decompressionSession = nil
                }
            }
        }

        formatDescription = formatDesc
    }

    private func createDecompressionSession(formatDescription: CMFormatDescription) throws {
        let destinationAttributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary

        var session: VTDecompressionSession?

        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: destinationAttributes,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            throw VideoDecoderError.sessionCreationFailed
        }

        // Configure for low latency
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        decompressionSession = session
    }

    private func createSampleBuffer(from packet: EncodedPacket, formatDescription: CMFormatDescription) throws -> CMSampleBuffer {
        // VideoToolbox encoder outputs AVCC format (4-byte length prefix)
        // The data should already be in the right format
        let data = packet.data

        // Create a copy of the data that CMBlockBuffer can own
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let buffer = blockBuffer else {
            throw VideoDecoderError.decodingFailed("Failed to create block buffer: \(status)")
        }

        // Copy the data into the block buffer
        status = data.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }

        guard status == noErr else {
            throw VideoDecoderError.decodingFailed("Failed to copy data to block buffer: \(status)")
        }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(packet.presentationTimeNs), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )

        var sampleSize = data.count

        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sample = sampleBuffer else {
            throw VideoDecoderError.decodingFailed("Failed to create sample buffer: \(status)")
        }

        return sample
    }

    private func createPixelBufferFromRaw(packet: EncodedPacket) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            packet.width,
            packet.height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw VideoDecoderError.decodingFailed("Failed to create pixel buffer")
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw VideoDecoderError.decodingFailed("No base address")
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let expectedSize = bytesPerRow * packet.height

        if packet.data.count >= expectedSize {
            packet.data.copyBytes(to: baseAddress.assumingMemoryBound(to: UInt8.self), count: expectedSize)
        }

        return buffer
    }

    public func flush() async throws {
        guard let session = decompressionSession else { return }
        VTDecompressionSessionFinishDelayedFrames(session)
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }

    deinit {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
    }
}
