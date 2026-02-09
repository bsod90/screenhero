import AppKit
import CoreVideo
import CoreImage

/// A testable version of VideoDisplayView with observable state
public class TestableVideoDisplayView: NSView {
    private var currentImage: CGImage?
    private let ciContext = CIContext()

    // Observable test state
    public private(set) var displayCallCount: UInt64 = 0
    public private(set) var cgImageSuccessCount: UInt64 = 0
    public private(set) var cgImageFailCount: UInt64 = 0
    public private(set) var drawCallCount: UInt64 = 0
    public private(set) var lastPixelBufferWidth: Int = 0
    public private(set) var lastPixelBufferHeight: Int = 0
    public private(set) var lastCGImageWidth: Int = 0
    public private(set) var lastCGImageHeight: Int = 0

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    /// Display a pixel buffer - the main entry point
    public func displayPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        displayCallCount += 1
        lastPixelBufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        lastPixelBufferHeight = CVPixelBufferGetHeight(pixelBuffer)

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
            cgImageSuccessCount += 1
            lastCGImageWidth = cgImage.width
            lastCGImageHeight = cgImage.height
            currentImage = cgImage

            // Force immediate redraw
            display()
        } else {
            cgImageFailCount += 1
        }
    }

    /// Check if the view has received and processed at least one frame
    public var hasReceivedFrame: Bool {
        displayCallCount > 0
    }

    /// Check if CGImage creation is working
    public var isCGImageCreationWorking: Bool {
        cgImageSuccessCount > 0
    }

    /// Check if draw() is being called
    public var isDrawing: Bool {
        drawCallCount > 0
    }

    /// Get the current displayed image for testing
    public var currentDisplayedImage: CGImage? {
        currentImage
    }

    /// Reset all counters for a fresh test
    public func resetCounters() {
        displayCallCount = 0
        cgImageSuccessCount = 0
        cgImageFailCount = 0
        drawCallCount = 0
    }

    public override func draw(_ dirtyRect: NSRect) {
        drawCallCount += 1

        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        // Fill with black
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)

        // Draw image if available
        guard let image = currentImage else {
            return
        }

        let imageSize = CGSize(width: image.width, height: image.height)
        let viewSize = bounds.size

        // Calculate aspect-fit rect
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height

        var drawRect: CGRect
        if imageAspect > viewAspect {
            let height = viewSize.width / imageAspect
            drawRect = CGRect(x: 0, y: (viewSize.height - height) / 2, width: viewSize.width, height: height)
        } else {
            let width = viewSize.height * imageAspect
            drawRect = CGRect(x: (viewSize.width - width) / 2, y: 0, width: width, height: viewSize.height)
        }

        context.draw(image, in: drawRect)
    }
}
