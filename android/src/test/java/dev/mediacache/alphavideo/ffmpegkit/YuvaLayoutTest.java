package dev.mediacache.alphavideo.ffmpegkit;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class YuvaLayoutTest {

    // Bytes per frame of `ffmpeg -f rawvideo -pix_fmt yuva420p`, measured with FFmpeg 8.
    private static final int[][] FFMPEG_FRAME_SIZES = {
        {383, 217, 208078}, {256, 256, 163840}, {255, 131, 83706}, {1920, 1080, 5184000}, {1, 1, 4},
    };

    @Test
    public void frameSizeMatchesFFmpeg() {
        for (int[] c : FFMPEG_FRAME_SIZES) {
            assertEquals(c[0] + "x" + c[1], c[2], new YuvaLayout(c[0], c[1]).frameSize);
        }
    }

    @Test
    public void oddSizesRoundChromaUp() {
        YuvaLayout l = new YuvaLayout(383, 217);
        assertEquals(192, l.uvWidth);
        assertEquals(109, l.uvHeight);
        assertEquals(383 * 217, l.uOffset);
        assertEquals(383 * 217 + 192 * 109, l.vOffset);
        assertEquals(383 * 217 + 2 * 192 * 109, l.aOffset);
    }
}
