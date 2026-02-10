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

    /// Convert a cursor hot-spot location to the image origin in AppKit view coordinates.
    ///
    /// Inputs:
    /// - `hotSpotPosition`: cursor hot-spot location in a bottom-left-origin view space.
    /// - `imageSize`: cursor image size in points.
    /// - `hotSpotTopLeft`: hot-spot offset in image space where `(0,0)` is top-left.
    ///
    /// Output:
    /// - image origin (bottom-left) suitable for layer/view positioning.
    public static func cursorImageOriginForHotSpotPosition(
        hotSpotPosition: CGPoint,
        imageSize: CGSize,
        hotSpotTopLeft: CGPoint
    ) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return hotSpotPosition }

        let clampedHotSpotX = min(max(hotSpotTopLeft.x, 0), imageSize.width)
        let clampedHotSpotYFromTop = min(max(hotSpotTopLeft.y, 0), imageSize.height)
        let hotSpotYFromBottom = imageSize.height - clampedHotSpotYFromTop

        return CGPoint(
            x: hotSpotPosition.x - clampedHotSpotX,
            y: hotSpotPosition.y - hotSpotYFromBottom
        )
    }

    /// Convert an AppKit global display point (bottom-left origin) to normalized top-left coordinates.
    public static func appKitDisplayPointToNormalizedTopLeft(_ point: CGPoint, displayBounds: CGRect) -> CGPoint {
        viewPointToNormalizedTopLeft(point, in: displayBounds)
    }

    /// Convert a CoreGraphics display point (top-left origin) to normalized top-left coordinates.
    public static func cgDisplayPointToNormalizedTopLeft(_ point: CGPoint, displayBounds: CGRect) -> CGPoint {
        guard displayBounds.width > 0, displayBounds.height > 0 else { return CGPoint(x: 0, y: 0) }

        let clampedX = min(max(point.x, displayBounds.minX), displayBounds.maxX)
        let clampedY = min(max(point.y, displayBounds.minY), displayBounds.maxY)
        let normalizedX = (clampedX - displayBounds.minX) / displayBounds.width
        let normalizedY = (clampedY - displayBounds.minY) / displayBounds.height
        return clampNormalized(CGPoint(x: normalizedX, y: normalizedY))
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
