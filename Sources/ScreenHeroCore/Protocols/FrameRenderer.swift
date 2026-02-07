import CoreVideo
import Foundation

/// Protocol for rendering decoded frames
public protocol FrameRenderer: Actor {
    /// Render a decoded pixel buffer
    func render(_ pixelBuffer: CVPixelBuffer) async

    /// Current frames per second being rendered
    var currentFPS: Double { get }

    /// Total frames rendered
    var framesRendered: UInt64 { get }
}
