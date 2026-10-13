import XCTest
@testable import AlphaVideoFFmpegKit

final class VideoProbeTests: XCTestCase {

    func testParseRate() {
        XCTAssertEqual(VideoProbe.parseRate("30000/1001"), 30000.0 / 1001, accuracy: 1e-9)
        XCTAssertEqual(VideoProbe.parseRate("30"), 30)
        XCTAssertEqual(VideoProbe.parseRate(" 25 / 1 "), 25)
        for unusable in ["0/0", "N/A", "", "30/0", "-30/1", "abc", nil] as [String?] {
            XCTAssertEqual(VideoProbe.parseRate(unusable), 0, "\(String(describing: unusable))")
        }
    }

    func testFrameRatePrefersTheAverageThenTheBaseThenThirty() {
        XCTAssertEqual(VideoProbe.frameRate(average: "24/1", base: "30/1"), 24)
        XCTAssertEqual(VideoProbe.frameRate(average: "0/0", base: "60/1"), 60)
        XCTAssertEqual(VideoProbe.frameRate(average: nil, base: "N/A"), 30)
    }

    func testKeyValues() {
        let output = "width=383\nheight=217\ncolor_range=tv\n[STREAM]\nduration=2.000000\nr_frame_rate=30/1\n"
        let values = VideoProbe.keyValues(output)
        XCTAssertEqual(values["width"], "383")
        XCTAssertEqual(values["color_range"], "tv")
        XCTAssertEqual(values["duration"], "2.000000")
        XCTAssertEqual(values["r_frame_rate"], "30/1")
        XCTAssertNil(values["[STREAM]"])
    }
}
