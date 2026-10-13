import XCTest
@testable import AlphaVideoFFmpegKit

final class YuvaLayoutTests: XCTestCase {

    // Bytes per frame of `ffmpeg -f rawvideo -pix_fmt yuva420p`, measured with FFmpeg 8.
    private let ffmpegFrameSizes = [
        (383, 217, 208_078), (256, 256, 163_840), (255, 131, 83_706), (1920, 1080, 5_184_000), (1, 1, 4),
    ]

    func testFrameSizeMatchesFFmpeg() {
        for (w, h, bytes) in ffmpegFrameSizes {
            XCTAssertEqual(YuvaLayout(width: w, height: h).frameSize, bytes, "\(w)x\(h)")
        }
    }

    func testOddSizesRoundChromaUp() {
        let l = YuvaLayout(width: 383, height: 217)
        XCTAssertEqual(l.uvWidth, 192)
        XCTAssertEqual(l.uvHeight, 109)
        XCTAssertEqual(l.uOffset, 383 * 217)
        XCTAssertEqual(l.vOffset, 383 * 217 + 192 * 109)
        XCTAssertEqual(l.aOffset, 383 * 217 + 2 * 192 * 109)
    }
}
