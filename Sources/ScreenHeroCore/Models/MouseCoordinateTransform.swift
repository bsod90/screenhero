import CoreGraphics

/// Shared coordinate transforms for remote mouse input and cursor rendering.
///
/// Canonical wire format:
/// - normalized coordinates (`0...1`)
/// - origin at top-left
/// - X increases right, Y increases down
public enum MouseCoordinateTransform {
    /// Clamp normalized point into `0...1` range.
    public static func clampNormalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: clamp01(point.x), y: clamp01(point.y))
    }

    /// Convert a point in a bottom-left-origin rect (AppKit-style) to normalized top-left coordinates.
    public static func viewPointToNormalizedTopLeft(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return CGPoint(x: 0, y: 0) }

        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let normalizedX = (clampedX - rect.minX) / rect.width
        let normalizedY = (rect.maxY - clampedY) / rect.height
        return clampNormalized(CGPoint(x: normalizedX, y: normalizedY))
    }

    /// Convert normalized top-left coordinates into a point in a bottom-left-origin rect (AppKit-style).
    public static func normalizedTopLeftToViewPoint(_ normalized: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return CGPoint(x: rect.minX, y: rect.maxY) }

        let clamped = clampNormalized(normalized)
        return CGPoint(
            x: rect.minX + clamped.x * rect.width,
            y: rect.maxY - clamped.y * rect.height
        )
    }

    /// Convert raw AppKit delta (X right, Y up) into normalized top-left delta.
    public static func appKitDeltaToNormalizedTopLeft(deltaX: CGFloat, deltaY: CGFloat, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(
            x: deltaX / rect.width,
            y: -deltaY / rect.height
        )
    }

    /// Convert an AppKit global display point (bottom-left origin) to normalized top-left coordinates.
    public static func appKitDisplayPointToNormalizedTopLeft(_ point: CGPoint, displayBounds: CGRect) -> CGPoint {
        viewPointToNormalizedTopLeft(point, in: displayBounds)
    }

    /// Convert normalized top-left coordinates to CoreGraphics display coordinates (top-left origin).
    public static func normalizedTopLeftToCGDisplayPoint(_ normalized: CGPoint, displayBounds: CGRect) -> CGPoint {
        guard displayBounds.width > 0, displayBounds.height > 0 else { return displayBounds.origin }

        let clamped = clampNormalized(normalized)
        return CGPoint(
            x: displayBounds.minX + clamped.x * displayBounds.width,
            y: displayBounds.minY + clamped.y * displayBounds.height
        )
    }

    /// Compute an aspect-fit rect for content inside a container rect.
    public static func aspectFitRect(container: CGRect, contentWidth: CGFloat, contentHeight: CGFloat) -> CGRect {
        guard container.width > 0,
              container.height > 0,
              contentWidth > 0,
              contentHeight > 0 else {
            return container
        }

        let containerAspect = container.width / container.height
        let contentAspect = contentWidth / contentHeight

        if contentAspect > containerAspect {
            let fittedHeight = container.width / contentAspect
            let yOffset = (container.height - fittedHeight) / 2
            return CGRect(
                x: container.minX,
                y: container.minY + yOffset,
                width: container.width,
                height: fittedHeight
            )
        }

        let fittedWidth = container.height * contentAspect
        let xOffset = (container.width - fittedWidth) / 2
        return CGRect(
            x: container.minX + xOffset,
            y: container.minY,
            width: fittedWidth,
            height: container.height
        )
    }

    private static func clamp01(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}
