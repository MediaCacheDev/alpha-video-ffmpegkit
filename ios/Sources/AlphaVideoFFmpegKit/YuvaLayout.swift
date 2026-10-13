import Foundation

/// Where each plane sits in one frame of FFmpeg's `-f rawvideo -pix_fmt yuva420p` output:
/// Y, U, V and A back to back with no row padding. The chroma planes are half size rounded up,
/// so an odd width or height still gets its last column and row.
struct YuvaLayout {
    let width: Int
    let height: Int
    let uvWidth: Int
    let uvHeight: Int
    let ySize: Int
    let uvSize: Int
    let uOffset: Int
    let vOffset: Int
    let aOffset: Int
    let frameSize: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        uvWidth = (width + 1) / 2
        uvHeight = (height + 1) / 2
        ySize = width * height
        uvSize = uvWidth * uvHeight
        uOffset = ySize
        vOffset = uOffset + uvSize
        aOffset = vOffset + uvSize
        frameSize = aOffset + ySize
    }
}

/// The GPU view's YUV to RGB: rgb = m * (y, u, v, 1), with y, u and v the texture samples (0..1).
/// Same maths as the C++ player's `webm::yuvToRgbFor`.
enum YuvToRgb {

    /// A column-major float4x4, from FFprobe's `color_range` (`tv`, `pc`) and `color_space`
    /// (`bt709`, `smpte170m`, ...). An unknown range is limited, which VP9 video almost always is.
    /// An unknown matrix is BT.601 up to 720x576 and BT.709 above, Android's default for untagged video.
    static func matrix(colorRange: String?, colorSpace: String?, width: Int, height: Int) -> [Float] {
        var kr = 0.299, kb = 0.114
        let sd = width <= 720 && height <= 576
        let space = colorSpace ?? "unknown"
        if space == "bt709" || (space == "unknown" && !sd) {
            kr = 0.2126
            kb = 0.0722
        } else if space.hasPrefix("bt2020") {
            kr = 0.2627
            kb = 0.0593
        }
        let kg = 1 - kr - kb
        let rv = 2 * (1 - kr)
        let bu = 2 * (1 - kb)
        let gu = 2 * kb * (1 - kb) / kg
        let gv = 2 * kr * (1 - kr) / kg

        let full = colorRange == "pc"
        let ys = full ? 1 : 255.0 / 219, yo = full ? 0 : 16.0 / 255
        let cs = full ? 1 : 255.0 / 224, co = 128.0 / 255

        let rows: [[Double]] = [
            [ys, 0, rv * cs, -ys * yo - rv * cs * co],
            [ys, -gu * cs, -gv * cs, -ys * yo + (gu + gv) * cs * co],
            [ys, bu * cs, 0, -ys * yo - bu * cs * co],
        ]
        var m = [Float](repeating: 0, count: 16)
        for col in 0..<4 {
            for row in 0..<3 { m[col * 4 + row] = Float(rows[row][col]) }
        }
        m[15] = 1
        return m
    }
}
