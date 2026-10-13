package dev.mediacache.alphavideo.ffmpegkit;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class YuvToRgbTest {

    /** Channel {@code c} (0 R, 1 G, 2 B) of the matrix applied to 8-bit Y'CbCr, in 0-255 levels. */
    private static double apply(float[] m, int y, int u, int v, int c) {
        double[] in = {y / 255.0, u / 255.0, v / 255.0, 1};
        double sum = 0;
        for (int k = 0; k < 4; k++) sum += m[k * 4 + c] * in[k];
        return sum * 255;
    }

    @Test
    public void mapsBlackAndWhiteInBothRanges() {
        float[] limited = YuvToRgb.matrix("tv", "smpte170m", 383, 217);
        float[] full = YuvToRgb.matrix("pc", "smpte170m", 383, 217);
        for (int c = 0; c < 3; c++) {
            assertEquals(0, apply(limited, 16, 128, 128, c), 0.05);
            assertEquals(255, apply(limited, 235, 128, 128, c), 0.05);
            assertEquals(0, apply(full, 0, 128, 128, c), 0.05);
            assertEquals(255, apply(full, 255, 128, 128, c), 0.05);
        }
    }

    @Test
    public void usesTheClipsMatrix() {
        // Limited-range red (255, 0, 0) is Y'CbCr 81, 90, 240 in BT.601 and 63, 102, 240 in BT.709.
        float[] bt601 = YuvToRgb.matrix("tv", "smpte170m", 383, 217);
        assertEquals(255, apply(bt601, 81, 90, 240, 0), 1.5);
        assertEquals(0, apply(bt601, 81, 90, 240, 1), 1.5);
        float[] bt709 = YuvToRgb.matrix("tv", "bt709", 1920, 1080);
        assertEquals(255, apply(bt709, 63, 102, 240, 0), 1.5);
        assertEquals(0, apply(bt709, 63, 102, 240, 2), 1.5);
    }

    @Test
    public void untaggedIsLimitedBt601ForSdAndBt709Above() {
        assertArrayEquals(YuvToRgb.matrix("tv", "smpte170m", 640, 480), YuvToRgb.matrix("unknown", "unknown", 640, 480), 0);
        assertArrayEquals(YuvToRgb.matrix("tv", "bt709", 1920, 1080), YuvToRgb.matrix("unknown", "unknown", 1920, 1080), 0);
        assertArrayEquals(YuvToRgb.matrix("tv", "bt709", 1920, 1080), YuvToRgb.matrix(null, null, 1920, 1080), 0);
    }
}
