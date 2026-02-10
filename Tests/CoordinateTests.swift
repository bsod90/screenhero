import Foundation
import CoreGraphics

/// Test coordinate transformations for mouse input
///
/// Coordinate systems:
/// - AppKit view: Y=0 at BOTTOM, increases UP
/// - Stream/CG: Y=0 at TOP, increases DOWN
/// - Metal renders video with Y-flip, so stream Y=0 appears at TOP of view
///
/// Therefore: AppKit view Y and stream Y are INVERTED

func assertEqual(_ a: CGFloat, _ b: CGFloat, accuracy: CGFloat = 1, _ msg: String = "") {
    if abs(a - b) > accuracy {
        print("❌ FAILED: \(a) != \(b) (accuracy: \(accuracy)) \(msg)")
        exit(1)
    }
}

func assertTrue(_ condition: Bool, _ msg: String = "") {
    if !condition {
        print("❌ FAILED: condition was false - \(msg)")
        exit(1)
    }
}

// Simulate viewer's viewToStreamCoordinates
func viewToStream(
    viewX: CGFloat, viewY: CGFloat,
    videoRect: CGRect,
    streamWidth: CGFloat, streamHeight: CGFloat
) -> (x: CGFloat, y: CGFloat) {
    // Clamp to video rect
    let clampedX = max(videoRect.minX, min(videoRect.maxX, viewX))
    let clampedY = max(videoRect.minY, min(videoRect.maxY, viewY))

    // Normalized position in video rect (0-1)
    let normalizedX = (clampedX - videoRect.minX) / videoRect.width
    let normalizedY = (clampedY - videoRect.minY) / videoRect.height

    // Convert to stream coordinates
    // X is the same direction
    // Y is INVERTED: view top (high Y) = stream top (low Y)
    let streamX = normalizedX * streamWidth
    let streamY = (1.0 - normalizedY) * streamHeight  // INVERT Y

    return (streamX, streamY)
}

// Simulate host's stream to screen conversion
func streamToScreen(
    streamX: CGFloat, streamY: CGFloat,
    streamWidth: CGFloat, streamHeight: CGFloat,
    screenBounds: CGRect
) -> CGPoint {
    // Stream coords: (0,0) at top-left
    // Screen coords (CG): screenBounds.origin at top-left
    let screenX = screenBounds.minX + (streamX / streamWidth) * screenBounds.width
    let screenY = screenBounds.minY + (streamY / streamHeight) * screenBounds.height
    return CGPoint(x: screenX, y: screenY)
}

print("=== Coordinate System Tests ===\n")

// Test 1: Click at view center
print("Test 1: Click at View Center")
do {
    let streamWidth: CGFloat = 1920
    let streamHeight: CGFloat = 1080
    let videoRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let screenBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    // AppKit: Y=540 is middle (0 at bottom, 1080 at top)
    let viewX: CGFloat = 960
    let viewY: CGFloat = 540

    let stream = viewToStream(viewX: viewX, viewY: viewY, videoRect: videoRect,
                               streamWidth: streamWidth, streamHeight: streamHeight)

    print("  View (\(Int(viewX)), \(Int(viewY))) -> Stream (\(Int(stream.x)), \(Int(stream.y)))")

    assertEqual(stream.x, 960, accuracy: 1, "stream X should be center")
    assertEqual(stream.y, 540, accuracy: 1, "stream Y should be center")

    let screen = streamToScreen(streamX: stream.x, streamY: stream.y,
                                 streamWidth: streamWidth, streamHeight: streamHeight,
                                 screenBounds: screenBounds)

    print("  Stream (\(Int(stream.x)), \(Int(stream.y))) -> Screen (\(Int(screen.x)), \(Int(screen.y)))")

    assertEqual(screen.x, 960, accuracy: 1, "screen X should be center")
    assertEqual(screen.y, 540, accuracy: 1, "screen Y should be center")
    print("  ✅ PASSED\n")
}

// Test 2: Click at view TOP (high Y in AppKit)
print("Test 2: Click at View Top")
do {
    let streamWidth: CGFloat = 1920
    let streamHeight: CGFloat = 1080
    let videoRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let screenBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    // AppKit: Y=1080 is TOP of view
    let viewX: CGFloat = 960
    let viewY: CGFloat = 1080

    let stream = viewToStream(viewX: viewX, viewY: viewY, videoRect: videoRect,
                               streamWidth: streamWidth, streamHeight: streamHeight)

    print("  View (\(Int(viewX)), \(Int(viewY))) -> Stream (\(Int(stream.x)), \(Int(stream.y)))")

    assertEqual(stream.x, 960, accuracy: 1, "stream X should be center")
    assertEqual(stream.y, 0, accuracy: 1, "stream Y should be TOP (0)")  // Inverted!

    let screen = streamToScreen(streamX: stream.x, streamY: stream.y,
                                 streamWidth: streamWidth, streamHeight: streamHeight,
                                 screenBounds: screenBounds)

    print("  Stream (\(Int(stream.x)), \(Int(stream.y))) -> Screen (\(Int(screen.x)), \(Int(screen.y)))")

    assertEqual(screen.x, 960, accuracy: 1, "screen X should be center")
    assertEqual(screen.y, 0, accuracy: 1, "screen Y should be TOP in CG (0)")
    print("  ✅ PASSED\n")
}

// Test 3: Click at view BOTTOM (low Y in AppKit)
print("Test 3: Click at View Bottom")
do {
    let streamWidth: CGFloat = 1920
    let streamHeight: CGFloat = 1080
    let videoRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let screenBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    // AppKit: Y=0 is BOTTOM of view
    let viewX: CGFloat = 960
    let viewY: CGFloat = 0

    let stream = viewToStream(viewX: viewX, viewY: viewY, videoRect: videoRect,
                               streamWidth: streamWidth, streamHeight: streamHeight)

    print("  View (\(Int(viewX)), \(Int(viewY))) -> Stream (\(Int(stream.x)), \(Int(stream.y)))")

    assertEqual(stream.x, 960, accuracy: 1, "stream X should be center")
    assertEqual(stream.y, 1080, accuracy: 1, "stream Y should be BOTTOM (1080)")  // Inverted!

    let screen = streamToScreen(streamX: stream.x, streamY: stream.y,
                                 streamWidth: streamWidth, streamHeight: streamHeight,
                                 screenBounds: screenBounds)

    print("  Stream (\(Int(stream.x)), \(Int(stream.y))) -> Screen (\(Int(screen.x)), \(Int(screen.y)))")

    assertEqual(screen.x, 960, accuracy: 1, "screen X should be center")
    assertEqual(screen.y, 1080, accuracy: 1, "screen Y should be BOTTOM in CG (1080)")
    print("  ✅ PASSED\n")
}

// Test 4: Mouse move UP
print("Test 4: Mouse Move Up (deltaY positive in AppKit)")
do {
    var virtualY: CGFloat = 540  // Start at center in stream coords
    let deltaY: CGFloat = 100  // Mouse moved UP (positive in AppKit)

    // When moving UP in AppKit, cursor should move UP on screen
    // In stream/CG coords, UP = decreasing Y
    // So we SUBTRACT deltaY (but wait, we also need to think about the direction)

    // Actually: AppKit deltaY positive = mouse physically moved forward = cursor UP
    // Stream Y=0 is TOP, so UP = decrease Y
    // But the delta is in AppKit space where UP = positive
    // So: virtualY -= deltaY would decrease Y, moving cursor UP
    // But that assumes the delta and stream Y have opposite conventions

    // Hmm, let me think differently. The delta is RAW mouse movement.
    // When mouse moves forward (up), the raw delta is positive.
    // In CG/stream, moving up = Y decreases.
    // So: newY = oldY - delta

    // But wait, is deltaY really positive for "up"? Let me check...
    // NSEvent.deltaY: positive values indicate movement toward the top of the screen

    // So: deltaY positive = move up = decrease stream Y
    virtualY -= deltaY  // 540 - 100 = 440

    print("  Start Y=540, deltaY=+100 (move UP)")
    print("  New virtualY = \(Int(virtualY))")

    assertEqual(virtualY, 440, accuracy: 1, "Y should decrease when moving up")
    assertTrue(virtualY < 540, "Moving up should decrease stream Y (toward 0)")
    print("  Stream Y decreased from 540 to 440 -> cursor moved UP")
    print("  ✅ PASSED\n")
}

// Test 5: Mouse move DOWN
print("Test 5: Mouse Move Down (deltaY negative in AppKit)")
do {
    var virtualY: CGFloat = 540  // Start at center in stream coords
    let deltaY: CGFloat = -100  // Mouse moved DOWN (negative in AppKit)

    virtualY -= deltaY  // 540 - (-100) = 640

    print("  Start Y=540, deltaY=-100 (move DOWN)")
    print("  New virtualY = \(Int(virtualY))")

    assertEqual(virtualY, 640, accuracy: 1, "Y should increase when moving down")
    assertTrue(virtualY > 540, "Moving down should increase stream Y (toward 1080)")
    print("  Stream Y increased from 540 to 640 -> cursor moved DOWN")
    print("  ✅ PASSED\n")
}

// Test 6: Different resolutions
print("Test 6: Different Resolutions (Stream: 1920x1080, Display: 1512x982)")
do {
    let streamWidth: CGFloat = 1920
    let streamHeight: CGFloat = 1080
    let screenBounds = CGRect(x: 0, y: 0, width: 1512, height: 982)

    // Stream center
    let streamX: CGFloat = 960
    let streamY: CGFloat = 540

    let screen = streamToScreen(streamX: streamX, streamY: streamY,
                                 streamWidth: streamWidth, streamHeight: streamHeight,
                                 screenBounds: screenBounds)

    print("  Stream center (960, 540) -> Screen (\(Int(screen.x)), \(Int(screen.y)))")

    assertEqual(screen.x, 756, accuracy: 1, "screen X should be display center")
    assertEqual(screen.y, 491, accuracy: 1, "screen Y should be display center")
    print("  ✅ PASSED\n")
}

// Test 7: Multi-monitor with offset
print("Test 7: Multi-monitor with Screen Offset (origin: 3164, 0)")
do {
    let streamWidth: CGFloat = 1920
    let streamHeight: CGFloat = 1080
    let screenBounds = CGRect(x: 3164, y: 0, width: 1512, height: 982)

    // Stream top-left
    let streamX: CGFloat = 0
    let streamY: CGFloat = 0

    let screen = streamToScreen(streamX: streamX, streamY: streamY,
                                 streamWidth: streamWidth, streamHeight: streamHeight,
                                 screenBounds: screenBounds)

    print("  Stream (0, 0) -> Screen (\(Int(screen.x)), \(Int(screen.y)))")

    assertEqual(screen.x, 3164, accuracy: 1, "screen X should be at display origin")
    assertEqual(screen.y, 0, accuracy: 1, "screen Y should be at display origin")
    print("  ✅ PASSED\n")
}

print("=== All tests passed! ===")
