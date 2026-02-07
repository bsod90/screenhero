import CoreVideo
import Foundation

/// Protocol for video decoders
public protocol VideoDecoder: Actor {
    /// Decode an encoded packet into a pixel buffer
    func decode(_ packet: EncodedPacket) async throws -> CVPixelBuffer

    /// Configure the decoder based on stream config
    func configure(_ config: StreamConfig) async throws

    /// Flush any pending frames
    func flush() async throws
}

/// Errors that can occur during decoding
public enum VideoDecoderError: Error, Sendable {
    case notConfigured
    case decodingFailed(String)
    case invalidData
    case sessionCreationFailed
    case formatDescriptionMissing
    case waitingForKeyframe  // Silently skip frames until keyframe with SPS/PPS arrives
}
