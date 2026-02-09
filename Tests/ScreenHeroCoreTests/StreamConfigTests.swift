import XCTest
@testable import ScreenHeroCore

final class StreamConfigTests: XCTestCase {

    func testDefaultFullColorModeDisabled() {
        let config = StreamConfig()
        XCTAssertFalse(config.fullColorMode, "Full color mode should be disabled by default")
    }

    func testFullColorModeEnabled() {
        let config = StreamConfig(fullColorMode: true)
        XCTAssertTrue(config.fullColorMode, "Full color mode should be enabled when specified")
    }

    func testFullColorPresetHasFullColorEnabled() {
        let config = StreamConfig.fullColor1080p
        XCTAssertTrue(config.fullColorMode, "fullColor1080p preset should have fullColorMode enabled")
        XCTAssertEqual(config.bitrate, 40_000_000, "fullColor1080p should have higher bitrate for 4:4:4")
    }

    func testStandardPresetsHaveFullColorDisabled() {
        XCTAssertFalse(StreamConfig.hd1080p60.fullColorMode)
        XCTAssertFalse(StreamConfig.uhd4k60.fullColorMode)
        XCTAssertFalse(StreamConfig.screenShare.fullColorMode)
        XCTAssertFalse(StreamConfig.highQuality4K.fullColorMode)
        XCTAssertFalse(StreamConfig.testing.fullColorMode)
    }

    func testConfigCodable() throws {
        let original = StreamConfig(
            width: 1920,
            height: 1080,
            fps: 60,
            codec: .h264,
            bitrate: 40_000_000,
            keyframeInterval: 30,
            lowLatencyMode: true,
            fullColorMode: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(StreamConfig.self, from: data)

        XCTAssertEqual(decoded.fullColorMode, original.fullColorMode)
        XCTAssertEqual(decoded.width, original.width)
        XCTAssertEqual(decoded.height, original.height)
        XCTAssertEqual(decoded.bitrate, original.bitrate)
    }
}
