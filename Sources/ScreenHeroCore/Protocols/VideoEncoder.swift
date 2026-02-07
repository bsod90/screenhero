import CoreMedia
import Foundation

/// Protocol for video encoders (H.264, HEVC, passthrough)
public protocol VideoEncoder: Actor {
    /// Encode a sample buffer into an encoded packet
    func encode(_ sampleBuffer: CMSampleBuffer) async throws -> EncodedPacket

    /// Configure the encoder with stream settings
    func configure(_ config: StreamConfig) async throws

    /// Flush any pending frames
    func flush() async throws

    /// Current encoder configuration
    var config: StreamConfig? { get }
}

/// Errors that can occur during encoding
public enum VideoEncoderError: Error, Sendable {
    case notConfigured
    case encodingFailed(String)
    case invalidInput
    case sessionCreationFailed
    case unsupportedCodec
    case noImageBuffer  // Sample buffer has no image data (skip silently)
}
