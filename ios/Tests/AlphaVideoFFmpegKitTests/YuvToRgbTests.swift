import XCTest
@testable import AlphaVideoFFmpegKit

final class YuvToRgbTests: XCTestCase {

    /// Channel `c` (0 R, 1 G, 2 B) of the matrix applied to 8-bit Y'CbCr, in 0-255 levels.
    private func apply(_ m: [Float], _ y: Int, _ u: Int, _ v: Int, _ c: Int) -> Double {
        let input = [Double(y) / 255, Double(u) / 255, Double(v) / 255, 1]
        return (0..<4).reduce(0) { $0 + Double(m[$1 * 4 + c]) * input[$1] } * 255
    }

    func testMapsBlackAndWhiteInBothRanges() {
        let limited = YuvToRgb.matrix(colorRange: "tv", colorSpace: "smpte170m", width: 383, height: 217)
        let full = YuvToRgb.matrix(colorRange: "pc", colorSpace: "smpte170m", width: 383, height: 217)
        for c in 0..<3 {
            XCTAssertEqual(apply(limited, 16, 128, 128, c), 0, accuracy: 0.05)
            XCTAssertEqual(apply(limited, 235, 128, 128, c), 255, accuracy: 0.05)
            XCTAssertEqual(apply(full, 0, 128, 128, c), 0, accuracy: 0.05)
            XCTAssertEqual(apply(full, 255, 128, 128, c), 255, accuracy: 0.05)
        }
    }

    func testUsesTheClipsMatrix() {
        // Limited-range red (255, 0, 0) is Y'CbCr 81, 90, 240 in BT.601 and 63, 102, 240 in BT.709.
        let bt601 = YuvToRgb.matrix(colorRange: "tv", colorSpace: "smpte170m", width: 383, height: 217)
        XCTAssertEqual(apply(bt601, 81, 90, 240, 0), 255, accuracy: 1.5)
        XCTAssertEqual(apply(bt601, 81, 90, 240, 1), 0, accuracy: 1.5)
        let bt709 = YuvToRgb.matrix(colorRange: "tv", colorSpace: "bt709", width: 1920, height: 1080)
        XCTAssertEqual(apply(bt709, 63, 102, 240, 0), 255, accuracy: 1.5)
        XCTAssertEqual(apply(bt709, 63, 102, 240, 2), 0, accuracy: 1.5)
    }

    func testUntaggedIsLimitedBt601ForSdAndBt709Above() {
        XCTAssertEqual(YuvToRgb.matrix(colorRange: "unknown", colorSpace: "unknown", width: 640, height: 480),
                       YuvToRgb.matrix(colorRange: "tv", colorSpace: "smpte170m", width: 640, height: 480))
        XCTAssertEqual(YuvToRgb.matrix(colorRange: "unknown", colorSpace: "unknown", width: 1920, height: 1080),
                       YuvToRgb.matrix(colorRange: "tv", colorSpace: "bt709", width: 1920, height: 1080))
        XCTAssertEqual(YuvToRgb.matrix(colorRange: nil, colorSpace: nil, width: 1920, height: 1080),
                       YuvToRgb.matrix(colorRange: "tv", colorSpace: "bt709", width: 1920, height: 1080))
    }

    func testIsColumnMajorWithAnIdentityLastRow() {
        let m = YuvToRgb.matrix(colorRange: "tv", colorSpace: "bt709", width: 1920, height: 1080)
        XCTAssertEqual(m.count, 16)
        XCTAssertEqual([m[3], m[7], m[11], m[15]], [0, 0, 0, 1])
    }
}
