import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware-accelerated video encoder using VideoToolbox
public actor VideoToolboxEncoder: VideoEncoder {
    public private(set) var config: StreamConfig?
    private var compressionSession: VTCompressionSession?
    private var frameCount: UInt64 = 0
    private var formatDescription: CMFormatDescription?

    // Thread-safe continuation storage for callback optimization (avoids Task hop)
    private let continuationLock = NSLock()
    private var continuationStorage: [UInt64: (captureTimestamp: UInt64, continuation: CheckedContinuation<EncodedPacket, Error>)] = [:]

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

        // Limit short-term bitrate spikes to reduce UDP burst loss
        // DataRateLimits expects [bytesPerSecond, durationSeconds]
        let bytesPerSecond = max(1, config.bitrate / 8)
        let burstBytesPerSecond = Int(Double(bytesPerSecond) * 1.25)
        let dataRateLimits: [Int] = [burstBytesPerSecond, 1]
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: dataRateLimits as CFArray
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

            // Eliminate encoder output buffering for single-frame latency
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_MaxFrameDelayCount,
                value: 0 as CFNumber
            )
        }

        // H.264 specific settings
        if config.codec == .h264 {
            // Use High 4:4:4 Predictive profile for full color mode (sharper text/UI)
            // Falls back to High profile if 4:4:4 encoding is not supported
            let profileLevel: CFString
            if config.fullColorMode {
                // High 4:4:4 Predictive profile enables 4:4:4 chroma subsampling
                // This preserves full color resolution for sharp text rendering
                profileLevel = kVTProfileLevel_H264_High_AutoLevel  // Note: macOS uses High profile
                // Enable 4:4:4 via color properties instead since High 4:4:4 Predictive
                // may not be available on all hardware

                // Request full-range video (0-255 instead of 16-235)
                VTSessionSetProperty(
                    session,
                    key: kVTCompressionPropertyKey_ColorPrimaries,
                    value: kCMFormatDescriptionColorPrimaries_ITU_R_709_2
                )
                VTSessionSetProperty(
                    session,
                    key: kVTCompressionPropertyKey_TransferFunction,
                    value: kCMFormatDescriptionTransferFunction_ITU_R_709_2
                )
                VTSessionSetProperty(
                    session,
                    key: kVTCompressionPropertyKey_YCbCrMatrix,
                    value: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
                )
            } else {
                profileLevel = kVTProfileLevel_H264_High_AutoLevel
            }

            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ProfileLevel,
                value: profileLevel
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
            // For HEVC, Main profile supports 4:2:0
            // Main 4:4:4 requires specific encoder support which may not be available
            // on all hardware. We use Main10 as a compromise for better color depth.
            let profileLevel: CFString
            if config.fullColorMode {
                // Use Main10 profile for better color precision
                // True 4:4:4 HEVC (RExt profile) has limited hardware support
                profileLevel = kVTProfileLevel_HEVC_Main10_AutoLevel

                // Configure for best possible color accuracy
                VTSessionSetProperty(
                    session,
                    key: kVTCompressionPropertyKey_ColorPrimaries,
                    value: kCMFormatDescriptionColorPrimaries_ITU_R_709_2
                )
                VTSessionSetProperty(
                    session,
                    key: kVTCompressionPropertyKey_TransferFunction,
                    value: kCMFormatDescriptionTransferFunction_ITU_R_709_2
                )
                VTSessionSetProperty(
                    session,
                    key: kVTCompressionPropertyKey_YCbCrMatrix,
                    value: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
                )
            } else {
                profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel
            }

            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ProfileLevel,
                value: profileLevel
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

        // ScreenCaptureKit can emit sample buffers without image data (status frames)
        // Skip these silently
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw VideoEncoderError.noImageBuffer
        }

        // Validate pixel buffer dimensions
        let pbWidth = CVPixelBufferGetWidth(imageBuffer)
        let pbHeight = CVPixelBufferGetHeight(imageBuffer)
        if pbWidth == 0 || pbHeight == 0 {
            throw VideoEncoderError.noImageBuffer
        }

        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        // Use wall-clock time for cross-machine compatibility (NTP-synchronized)
        let captureTimestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let currentFrameId = frameCount
        frameCount += 1

        // Force keyframe at interval (or first frame)
        var properties: CFDictionary? = nil
        let shouldForceKeyframe = currentFrameId == 0 || (currentFrameId % UInt64(config.keyframeInterval) == 0)
        if shouldForceKeyframe {
            properties = [
                kVTEncodeFrameOptionKey_ForceKeyFrame: true
            ] as CFDictionary
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Store in thread-safe storage for direct callback access
            self.continuationLock.lock()
            self.continuationStorage[currentFrameId] = (captureTimestamp, continuation)
            self.continuationLock.unlock()

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

                // Resume continuation directly without Task hop
                self.continuationLock.lock()
                guard let pending = self.continuationStorage.removeValue(forKey: currentFrameId) else {
                    self.continuationLock.unlock()
                    return
                }
                self.continuationLock.unlock()

                if status != noErr {
                    pending.continuation.resume(
                        throwing: VideoEncoderError.encodingFailed("Encoding callback error: \(status)")
                    )
                    return
                }

                guard let sampleBuffer = sampleBuffer else {
                    pending.continuation.resume(
                        throwing: VideoEncoderError.encodingFailed("No sample buffer in callback")
                    )
                    return
                }

                do {
                    let packet = try self.createEncodedPacketSync(
                        from: sampleBuffer,
                        frameId: currentFrameId,
                        captureTimestamp: pending.captureTimestamp
                    )
                    pending.continuation.resume(returning: packet)
                } catch {
                    pending.continuation.resume(throwing: error)
                }
            }

            if encodeStatus != noErr {
                self.continuationLock.lock()
                self.continuationStorage.removeValue(forKey: currentFrameId)
                self.continuationLock.unlock()
                continuation.resume(throwing: VideoEncoderError.encodingFailed("VTCompressionSessionEncodeFrame failed: \(encodeStatus)"))
            }
        }
    }

    private func createEncodedPacket(
        from sampleBuffer: CMSampleBuffer,
        frameId: UInt64,
        captureTimestamp: UInt64
    ) throws -> EncodedPacket {
        try createEncodedPacketSync(from: sampleBuffer, frameId: frameId, captureTimestamp: captureTimestamp)
    }

    /// Synchronous version for callback use - nonisolated to avoid actor hops
    private nonisolated func createEncodedPacketSync(
        from sampleBuffer: CMSampleBuffer,
        frameId: UInt64,
        captureTimestamp: UInt64
    ) throws -> EncodedPacket {
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
        let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
        var codec: VideoCodec = .hevc
        var width = 1920
        var height = 1080

        if let formatDesc = formatDesc {
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc)
            width = Int(dimensions.width)
            height = Int(dimensions.height)

            // Determine codec from format description
            let codecType = CMFormatDescriptionGetMediaSubType(formatDesc)
            codec = codecType == kCMVideoCodecType_H264 ? .h264 : .hevc

            if isKeyframe {
                parameterSets = extractParameterSetsSync(from: formatDesc, codec: codec)
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsNs = UInt64(CMTimeGetSeconds(pts) * 1_000_000_000)

        return EncodedPacket(
            frameId: frameId,
            data: data,
            presentationTimeNs: ptsNs,
            isKeyframe: isKeyframe,
            codec: codec,
            width: width,
            height: height,
            captureTimestamp: captureTimestamp,
            encodeTimestamp: DispatchTime.now().uptimeNanoseconds,
            parameterSets: parameterSets
        )
    }

    private nonisolated func extractParameterSetsSync(from formatDescription: CMFormatDescription, codec: VideoCodec) -> Data? {
        extractParameterSetsImpl(from: formatDescription, codec: codec)
    }

    private func extractParameterSets(from formatDescription: CMFormatDescription, codec: VideoCodec) -> Data? {
        extractParameterSetsImpl(from: formatDescription, codec: codec)
    }

    private nonisolated func extractParameterSetsImpl(from formatDescription: CMFormatDescription, codec: VideoCodec) -> Data? {
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
        guard config != nil else {
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
        // Use wall-clock time for cross-machine compatibility (NTP-synchronized)
        let captureTimestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)

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
