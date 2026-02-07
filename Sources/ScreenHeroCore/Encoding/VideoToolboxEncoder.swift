import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware-accelerated video encoder using VideoToolbox
public actor VideoToolboxEncoder: VideoEncoder {
    public private(set) var config: StreamConfig?
    private var compressionSession: VTCompressionSession?
    private var frameCount: UInt64 = 0
    private var pendingFrames: [UInt64: PendingFrame] = [:]
    private var formatDescription: CMFormatDescription?

    private struct PendingFrame {
        let captureTimestamp: UInt64
        let continuation: CheckedContinuation<EncodedPacket, Error>
    }

    public init() {}

    public func configure(_ config: StreamConfig) async throws {
        // Clean up existing session
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }

        self.config = config
        frameCount = 0

        // Determine codec type
        let codecType: CMVideoCodecType
        switch config.codec {
        case .h264:
            codecType = kCMVideoCodecType_H264
        case .hevc:
            codecType = kCMVideoCodecType_HEVC
        case .passthrough:
            // Passthrough doesn't need a compression session
            return
        }

        // Create compression session
        var session: VTCompressionSession?
        let encoderSpecification: CFDictionary? = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ] as CFDictionary

        let imageBufferAttributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: config.width,
            kCVPixelBufferHeightKey: config.height,
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(config.width),
            height: Int32(config.height),
            codecType: codecType,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: imageBufferAttributes,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            throw VideoEncoderError.sessionCreationFailed
        }

        // Configure session properties
        try configureSession(session, with: config)

        compressionSession = session

        // Prepare to encode
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func configureSession(_ session: VTCompressionSession, with config: StreamConfig) throws {
        // Real-time encoding
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // Average bitrate
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: config.bitrate as CFNumber
        )

        // Expected frame rate
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: config.fps as CFNumber
        )

        // Max keyframe interval
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: config.keyframeInterval as CFNumber
        )

        // Allow frame reordering (B-frames) - disable for low latency
        if config.lowLatencyMode {
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_AllowFrameReordering,
                value: kCFBooleanFalse
            )

            // Enable low-latency mode on newer macOS
            if #available(macOS 13.0, *) {
                VTSessionSetProperty(
                    session,
                    key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                    value: kCFBooleanTrue
                )
            }
        }

        // H.264 specific settings
        if config.codec == .h264 {
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ProfileLevel,
                value: kVTProfileLevel_H264_High_AutoLevel
            )

            // Allow temporal compression
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_AllowTemporalCompression,
                value: kCFBooleanTrue
            )
        }

        // HEVC specific settings
        if config.codec == .hevc {
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ProfileLevel,
                value: kVTProfileLevel_HEVC_Main_AutoLevel
            )
        }
    }

    public func encode(_ sampleBuffer: CMSampleBuffer) async throws -> EncodedPacket {
        guard let config = config else {
            throw VideoEncoderError.notConfigured
        }

        // Handle passthrough mode
        if config.codec == .passthrough {
            return try createPassthroughPacket(from: sampleBuffer)
        }

        guard let session = compressionSession else {
            throw VideoEncoderError.notConfigured
        }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw VideoEncoderError.invalidInput
        }

        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let captureTimestamp = DispatchTime.now().uptimeNanoseconds
        let currentFrameId = frameCount
        frameCount += 1

        // Force keyframe for first frame
        var properties: CFDictionary? = nil
        if currentFrameId == 0 {
            properties = [
                kVTEncodeFrameOptionKey_ForceKeyFrame: true
            ] as CFDictionary
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Store pending frame info
            self.pendingFrames[currentFrameId] = PendingFrame(
                captureTimestamp: captureTimestamp,
                continuation: continuation
            )

            var infoFlags = VTEncodeInfoFlags()

            let encodeStatus = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: imageBuffer,
                presentationTimeStamp: presentationTimeStamp,
                duration: duration,
                frameProperties: properties,
                infoFlagsOut: &infoFlags
            ) { [weak self] status, flags, sampleBuffer in
                guard let self = self else { return }

                Task {
                    await self.handleEncodedFrame(
                        status: status,
                        flags: flags,
                        sampleBuffer: sampleBuffer,
                        frameId: currentFrameId
                    )
                }
            }

            if encodeStatus != noErr {
                self.pendingFrames.removeValue(forKey: currentFrameId)
                continuation.resume(throwing: VideoEncoderError.encodingFailed("VTCompressionSessionEncodeFrame failed: \(encodeStatus)"))
            }
        }
    }

    private func handleEncodedFrame(
        status: OSStatus,
        flags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?,
        frameId: UInt64
    ) async {
        guard let pendingFrame = pendingFrames.removeValue(forKey: frameId) else {
            return
        }

        if status != noErr {
            pendingFrame.continuation.resume(
                throwing: VideoEncoderError.encodingFailed("Encoding callback error: \(status)")
            )
            return
        }

        guard let sampleBuffer = sampleBuffer else {
            pendingFrame.continuation.resume(
                throwing: VideoEncoderError.encodingFailed("No sample buffer in callback")
            )
            return
        }

        do {
            let packet = try createEncodedPacket(
                from: sampleBuffer,
                frameId: frameId,
                captureTimestamp: pendingFrame.captureTimestamp
            )
            pendingFrame.continuation.resume(returning: packet)
        } catch {
            pendingFrame.continuation.resume(throwing: error)
        }
    }

    private func createEncodedPacket(
        from sampleBuffer: CMSampleBuffer,
        frameId: UInt64,
        captureTimestamp: UInt64
    ) throws -> EncodedPacket {
        guard let config = config else {
            throw VideoEncoderError.notConfigured
        }

        // Get encoded data
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw VideoEncoderError.encodingFailed("No data buffer")
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let dataPointer = dataPointer, length > 0 else {
            throw VideoEncoderError.encodingFailed("Empty data buffer")
        }

        let data = Data(bytes: dataPointer, count: length)

        // Check if keyframe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        var isKeyframe = false
        if let attachments = attachments, CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            if let value = CFDictionaryGetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()) {
                let notSync = CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
                isKeyframe = !notSync
            } else {
                isKeyframe = true
            }
        }

        // Extract parameter sets for keyframes
        var parameterSets: Data? = nil
        if isKeyframe {
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                parameterSets = extractParameterSets(from: formatDesc, codec: config.codec)
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsNs = UInt64(CMTimeGetSeconds(pts) * 1_000_000_000)

        return EncodedPacket(
            frameId: frameId,
            data: data,
            presentationTimeNs: ptsNs,
            isKeyframe: isKeyframe,
            codec: config.codec,
            width: config.width,
            height: config.height,
            captureTimestamp: captureTimestamp,
            encodeTimestamp: DispatchTime.now().uptimeNanoseconds,
            parameterSets: parameterSets
        )
    }

    private func extractParameterSets(from formatDescription: CMFormatDescription, codec: VideoCodec) -> Data? {
        var data = Data()

        switch codec {
        case .h264:
            // Extract SPS and PPS
            var spsSize = 0
            var spsCount = 0
            var spsPointer: UnsafePointer<UInt8>?

            var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: &spsPointer,
                parameterSetSizeOut: &spsSize,
                parameterSetCountOut: &spsCount,
                nalUnitHeaderLengthOut: nil
            )

            if status == noErr, let sps = spsPointer {
                // Add start code
                data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                data.append(UnsafeBufferPointer(start: sps, count: spsSize))
            }

            var ppsSize = 0
            var ppsPointer: UnsafePointer<UInt8>?

            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPointer,
                parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )

            if status == noErr, let pps = ppsPointer {
                data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                data.append(UnsafeBufferPointer(start: pps, count: ppsSize))
            }

        case .hevc:
            // Extract VPS, SPS, and PPS for HEVC
            for i in 0..<3 {
                var size = 0
                var pointer: UnsafePointer<UInt8>?

                let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: i,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )

                if status == noErr, let ptr = pointer {
                    data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    data.append(UnsafeBufferPointer(start: ptr, count: size))
                }
            }

        case .passthrough:
            break
        }

        return data.isEmpty ? nil : data
    }

    private func createPassthroughPacket(from sampleBuffer: CMSampleBuffer) throws -> EncodedPacket {
        guard let config = config else {
            throw VideoEncoderError.notConfigured
        }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw VideoEncoderError.invalidInput
        }

        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer) else {
            throw VideoEncoderError.invalidInput
        }

        let data = Data(bytes: baseAddress, count: bytesPerRow * height)

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsNs = UInt64(CMTimeGetSeconds(pts) * 1_000_000_000)
        let captureTimestamp = DispatchTime.now().uptimeNanoseconds

        let currentFrameId = frameCount
        frameCount += 1

        return EncodedPacket(
            frameId: currentFrameId,
            data: data,
            presentationTimeNs: ptsNs,
            isKeyframe: true,
            codec: .passthrough,
            width: width,
            height: height,
            captureTimestamp: captureTimestamp,
            encodeTimestamp: DispatchTime.now().uptimeNanoseconds
        )
    }

    public func flush() async throws {
        guard let session = compressionSession else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    deinit {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
        }
    }
}
