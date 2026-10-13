package dev.mediacache.alphavideo.ffmpegkit;

import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class FrameClockTest {

    private static final double FPS = 100;
    private static final long INTERVAL_MS = 10;

    private static long elapsedMs(Runnable r) {
        long start = System.nanoTime();
        r.run();
        return (System.nanoTime() - start) / 1_000_000;
    }

    private static void frames(FrameClock clock, int n) {
        for (int i = 0; i < n; i++) assertTrue(clock.awaitNextFrame());
    }

    @Test
    public void pacesFramesAtTheFrameRate() {
        FrameClock clock = new FrameClock(FPS);
        long ms = elapsedMs(() -> frames(clock, 20));
        // 20 intervals; sleeps can overrun, but the clock keeps the average.
        assertTrue("20 frames took " + ms + " ms", ms >= 20 * INTERVAL_MS - 2 && ms < 20 * INTERVAL_MS + 60);
    }

    @Test
    public void doesNotRushToCatchUpAfterAStall() throws InterruptedException {
        FrameClock clock = new FrameClock(FPS);
        frames(clock, 2);
        Thread.sleep(10 * INTERVAL_MS);
        // The stall is dropped: the next frame is due now and the ones after keep the rate,
        // rather than ten frames firing back to back.
        long ms = elapsedMs(() -> frames(clock, 5));
        assertTrue("5 frames after a stall took " + ms + " ms", ms >= 4 * INTERVAL_MS - 2);
    }

    @Test
    public void restartMakesTheNextFrameDueOneIntervalFromNow() throws InterruptedException {
        FrameClock clock = new FrameClock(FPS);
        Thread.sleep(3 * INTERVAL_MS);
        clock.restart();
        long ms = elapsedMs(() -> frames(clock, 1));
        assertTrue("the first frame after restart took " + ms + " ms", ms >= INTERVAL_MS - 2);
    }

    @Test
    public void returnsFalseWhenInterrupted() {
        FrameClock clock = new FrameClock(1);
        Thread.currentThread().interrupt();
        assertTrue(!clock.awaitNextFrame());
        assertTrue(Thread.interrupted());
    }
}
