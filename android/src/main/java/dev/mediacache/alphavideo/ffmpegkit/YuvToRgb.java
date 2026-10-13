package dev.mediacache.alphavideo.ffmpegkit;

/**
 * The GPU view's YUV to RGB: rgb = m * (y, u, v, 1), with y, u and v the texture samples (0..1).
 * Same maths as the C++ player's {@code webm::yuvToRgbFor}.
 */
final class YuvToRgb {

    private YuvToRgb() {}

    /**
     * A column-major mat4 for {@code glUniformMatrix4fv}, from FFprobe's {@code color_range}
     * ({@code tv}, {@code pc}) and {@code color_space} ({@code bt709}, {@code smpte170m}, ...).
     * An unknown range is limited, which VP9 video almost always is. An unknown matrix is BT.601
     * up to 720x576 and BT.709 above, Android's default for untagged video.
     */
    static float[] matrix(String colorRange, String colorSpace, int width, int height) {
        double kr = 0.299, kb = 0.114;
        boolean sd = width <= 720 && height <= 576;
        String space = colorSpace == null ? "unknown" : colorSpace;
        if (space.equals("bt709") || (space.equals("unknown") && !sd)) {
            kr = 0.2126;
            kb = 0.0722;
        } else if (space.startsWith("bt2020")) {
            kr = 0.2627;
            kb = 0.0593;
        }
        double kg = 1 - kr - kb;
        double rv = 2 * (1 - kr);
        double bu = 2 * (1 - kb);
        double gu = 2 * kb * (1 - kb) / kg;
        double gv = 2 * kr * (1 - kr) / kg;

        boolean full = "pc".equals(colorRange);
        double ys = full ? 1 : 255.0 / 219, yo = full ? 0 : 16.0 / 255;
        double cs = full ? 1 : 255.0 / 224, co = 128.0 / 255;

        double[][] rows = {
            {ys, 0, rv * cs, -ys * yo - rv * cs * co},
            {ys, -gu * cs, -gv * cs, -ys * yo + (gu + gv) * cs * co},
            {ys, bu * cs, 0, -ys * yo - bu * cs * co},
        };
        float[] m = new float[16];
        for (int col = 0; col < 4; col++) {
            for (int row = 0; row < 3; row++) m[col * 4 + row] = (float) rows[row][col];
        }
        m[15] = 1;
        return m;
    }
}
