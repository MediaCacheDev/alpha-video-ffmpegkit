package dev.mediacache.alphavideo.ffmpegkit;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BooleanSupplier;
import org.junit.After;
import org.junit.Test;

public class PlayheadTest {

    private static final double FPS = 200;
    private static final int FRAMES = 20;

    private final AtomicBoolean playing = new AtomicBoolean(false);
    private final AtomicBoolean loop = new AtomicBoolean(false);
    private final AtomicBoolean stopped = new AtomicBoolean(false);
    private final AtomicInteger loads = new AtomicInteger();
    private final AtomicInteger ends = new AtomicInteger();
    private final List<Integer> shown = new ArrayList<>();
    private final Playhead playhead = new Playhead(FPS, playing::get, loop::get, stopped::get);
    private Thread thread;

    private void startPreloaded() {
        thread = new Thread(() -> {
            try {
                playhead.playPreloaded(FRAMES, this::show, loads::incrementAndGet, ends::incrementAndGet);
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        });
        thread.start();
        waitFor(() -> loads.get() == 1, "onLoad");
    }

    private synchronized void show(int frame) {
        shown.add(frame);
    }

    private synchronized List<Integer> shown() {
        return new ArrayList<>(shown);
    }

    private synchronized int last() {
        return shown.isEmpty() ? -1 : shown.get(shown.size() - 1);
    }

    private synchronized void clearShown() {
        shown.clear();
    }

    private static void waitFor(BooleanSupplier condition, String what) {
        long deadline = System.currentTimeMillis() + 3000;
        while (!condition.getAsBoolean()) {
            assertTrue("timed out waiting for " + what, System.currentTimeMillis() < deadline);
            try {
                Thread.sleep(2);
            } catch (InterruptedException e) {
                throw new RuntimeException(e);
            }
        }
    }

    private static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            throw new RuntimeException(e);
        }
    }

    @After
    public void stop() throws InterruptedException {
        stopped.set(true);
        if (thread != null) thread.join(2000);
    }

    @Test
    public void showsTheFirstFrameBeforeOnLoadAndHoldsItWhilePaused() {
        startPreloaded();
        assertEquals(List.of(0), shown());
        sleep(100);
        assertEquals(List.of(0), shown());
    }

    @Test
    public void playsEveryFrameInOrderThenEndsOnceWithoutLooping() {
        startPreloaded();
        playing.set(true);
        waitFor(() -> ends.get() == 1, "onEnd");
        List<Integer> expected = new ArrayList<>();
        for (int i = 0; i < FRAMES; i++) expected.add(i);
        assertEquals(expected, shown());
        sleep(50);
        assertEquals(1, ends.get());
        assertEquals(FRAMES - 1, last());
    }

    @Test
    public void loopsBackToTheFirstFrame() {
        loop.set(true);
        startPreloaded();
        playing.set(true);
        waitFor(() -> shown().size() > FRAMES + 3, "a second pass");
        List<Integer> frames = shown();
        assertEquals(Integer.valueOf(FRAMES - 1), frames.get(FRAMES - 1));
        assertEquals(Integer.valueOf(0), frames.get(FRAMES));
        assertEquals(Integer.valueOf(1), frames.get(FRAMES + 1));
        assertEquals(0, ends.get());
    }

    @Test
    public void playingAgainAfterTheEndStartsFromTheFirstFrame() {
        startPreloaded();
        playing.set(true);
        waitFor(() -> ends.get() == 1, "onEnd");
        playing.set(false);
        sleep(30);
        clearShown();
        playing.set(true);
        waitFor(() -> shown().size() >= 3, "playback to restart");
        assertEquals(List.of(0, 1, 2), shown().subList(0, 3));
    }

    @Test
    public void seeksShowTheirFrameWhilePausedAndClampToTheClip() {
        startPreloaded();
        int[][] cases = {{7, 7}, {-3, 0}, {1000, FRAMES - 1}, {12, 12}};
        for (int[] c : cases) {
            playhead.seekToFrame(c[0]);
            waitFor(() -> last() == c[1], "seekToFrame(" + c[0] + ") to show " + c[1]);
        }
        sleep(50);
        assertEquals(12, last());
    }

    @Test
    public void seekToTimeShowsTheFrameShowingAtThatTime() {
        startPreloaded();
        double[][] cases = {{5 / FPS, 5}, {(5 / FPS) * 0.999, 4}, {0, 0}, {-1, 0}, {Double.NaN, 0}, {60, FRAMES - 1}};
        for (double[] c : cases) {
            playhead.seekToFrame(FRAMES / 2);
            waitFor(() -> last() == FRAMES / 2, "reset");
            playhead.seekToTime(c[0]);
            waitFor(() -> last() == (int) c[1], "seekToTime(" + c[0] + ") to show " + (int) c[1]);
        }
    }

    @Test
    public void seeksBeforeLoadAreIgnored() throws Exception {
        Playhead fresh = new Playhead(FPS, playing::get, loop::get, stopped::get);
        fresh.seekToFrame(5);
        thread = new Thread(() -> {
            try {
                fresh.playPreloaded(FRAMES, this::show, loads::incrementAndGet, ends::incrementAndGet);
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        });
        thread.start();
        waitFor(() -> loads.get() == 1, "onLoad");
        sleep(50);
        assertEquals(List.of(0), shown());
    }

    @Test
    public void aSeekAfterTheEndPlaysOnFromThere() {
        startPreloaded();
        playing.set(true);
        waitFor(() -> ends.get() == 1, "onEnd");
        clearShown();
        playhead.seekToFrame(15);
        waitFor(() -> last() == FRAMES - 1 && shown().size() >= FRAMES - 15, "playback from 15 to the end");
        assertEquals(List.of(15, 16, 17, 18, 19), shown());
        waitFor(() -> ends.get() == 2, "a second onEnd");
    }

    @Test
    public void stopsWhenStopped() throws InterruptedException {
        startPreloaded();
        playing.set(true);
        stopped.set(true);
        thread.join(1000);
        assertTrue("playPreloaded returned", !thread.isAlive());
    }
}
