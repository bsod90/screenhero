import CoreMedia
import CoreVideo
import Foundation

/// A passthrough encoder for testing that doesn't actually encode
/// Just wraps raw pixel data in EncodedPacket format
public actor PassthroughEncoder: VideoEncoder {
    public private(set) var config: StreamConfig?
    private var frameCount: UInt64 = 0

    public init() {}

    public func configure(_ config: StreamConfig) async throws {
        self.config = config
        frameCount = 0
    }

    public func encode(_ sampleBuffer: CMSampleBuffer) async throws -> EncodedPacket {
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
        // Nothing to flush for passthrough
    }
}
