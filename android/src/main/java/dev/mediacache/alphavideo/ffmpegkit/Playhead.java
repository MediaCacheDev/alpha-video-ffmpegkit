package dev.mediacache.alphavideo.ffmpegkit;

import java.io.IOException;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BooleanSupplier;

/**
 * Decides which frame shows when, for both views and both modes. Frames advance at the clip's
 * rate while {@code playing} is true; while it's false the current frame stays up, and seeks
 * still show their frame. A clip that played to its end without looping starts again from the
 * first frame when playing turns true again, or from wherever a seek puts it.
 *
 * The play methods run on the view's playback thread; {@link #seekToFrame} and
 * {@link #seekToTime} can be called from any thread.
 */
final class Playhead {

    /** Shows the preloaded frame at an index. */
    interface FrameDisplay {
        void show(int frame) throws IOException;
    }

    /** Shows a decoded stream frame; the buffer goes back to the stream afterwards. */
    interface StreamDisplay {
        void show(byte[] frame);
    }

    /** Starts decoding with the first frame at or after {@code startSeconds}. */
    interface StreamOpener {
        FrameStream open(double startSeconds, BooleanSupplier cancelled);
    }

    private static final long IDLE_MS = 10;

    private final double frameRate;
    private final BooleanSupplier playing;
    private final BooleanSupplier loop;
    private final BooleanSupplier stopped;
    private final AtomicInteger seekRequest = new AtomicInteger(-1);
    /** 0 until the first frame shows; seeks before then are ignored. */
    private volatile int frameCount;

    Playhead(double frameRate, BooleanSupplier playing, BooleanSupplier loop, BooleanSupplier stopped) {
        this.frameRate = frameRate;
        this.playing = playing;
        this.loop = loop;
        this.stopped = stopped;
    }

    /** Clamped to the clip; ignored until it has loaded. */
    void seekToFrame(int frame) {
        int count = frameCount;
        if (count <= 0) return;
        seekRequest.set(Math.max(0, Math.min(frame, count - 1)));
    }

    /** Seeks to the frame showing at {@code seconds}. */
    void seekToTime(double seconds) {
        seekToFrame((int) Math.floor((seconds > 0 ? seconds : 0) * frameRate + 1e-6));
    }

    /**
     * Preload mode: any frame can be shown straight away. {@code onLoad} runs once the first
     * frame has shown. Returns once stopped.
     */
    void playPreloaded(int frames, FrameDisplay display, Runnable onLoad, Runnable onEnd) throws IOException {
        int frame = 0;
        display.show(frame);
        frameCount = frames;
        onLoad.run();
        FrameClock clock = new FrameClock(frameRate);
        boolean ended = false;
        boolean wasPlaying = false;
        while (!stopped.getAsBoolean()) {
            boolean play = playing.getAsBoolean();
            int seek = seekRequest.getAndSet(-1);
            if (seek < 0 && ended && play && !wasPlaying) seek = 0;
            wasPlaying = play;
            if (seek >= 0) {
                frame = seek;
                ended = false;
                display.show(frame);
                clock.restart();
                continue;
            }
            if (!play || ended) {
                if (!idle()) return;
                clock.restart();
                continue;
            }
            if (!clock.awaitNextFrame()) return;
            if (seekRequest.get() >= 0 || !playing.getAsBoolean()) continue;
            if (frame + 1 < frames) {
                frame++;
            } else if (loop.getAsBoolean()) {
                frame = 0;
            } else {
                ended = true;
                onEnd.run();
                continue;
            }
            display.show(frame);
        }
    }

    /**
     * Stream mode. A frame shows even while paused when one is owed: the first, and each seek's.
     * A seek decodes again from its frame. {@code onLoad} runs once the first frame has shown.
     *
     * @param estimatedFrames the clip's length for clamping seeks; 0 if unknown, which turns
     *                        seeking off
     * @return false if the clip ended before a single frame decoded
     */
    boolean playStream(int estimatedFrames, StreamOpener opener, StreamDisplay display,
                       Runnable onLoad, Runnable onEnd) throws IOException {
        BooleanSupplier interrupted = () -> stopped.getAsBoolean() || seekRequest.get() >= 0;
        FrameStream frames = opener.open(0, interrupted);
        try {
            FrameClock clock = new FrameClock(frameRate);
            boolean loaded = false;
            boolean ended = false;
            boolean wasPlaying = false;
            boolean frameOwed = true;
            while (!stopped.getAsBoolean()) {
                boolean play = playing.getAsBoolean();
                int seek = seekRequest.getAndSet(-1);
                if (seek < 0 && ended && play && !wasPlaying) seek = 0;
                wasPlaying = play;
                if (seek >= 0) {
                    frames.close();
                    frames = opener.open(seek > 0 ? (seek - 0.5) / frameRate : 0, interrupted);
                    ended = false;
                    frameOwed = true;
                }
                if (!frameOwed) {
                    if (!play || ended) {
                        if (!idle()) return true;
                        clock.restart();
                        continue;
                    }
                    if (!clock.awaitNextFrame()) return true;
                    if (seekRequest.get() >= 0 || !playing.getAsBoolean()) continue;
                }
                byte[] frame = frames.next();
                if (frame == null) {
                    if (interrupted.getAsBoolean()) continue;
                    if (!loaded) return false;
                    ended = true;
                    frameOwed = false;
                    onEnd.run();
                    continue;
                }
                display.show(frame);
                frames.recycle(frame);
                frameOwed = false;
                if (!loaded) {
                    loaded = true;
                    frameCount = estimatedFrames;
                    onLoad.run();
                    clock.restart();
                }
            }
            return true;
        } finally {
            frames.close();
        }
    }

    /** False if the thread was interrupted. */
    private static boolean idle() {
        try {
            Thread.sleep(IDLE_MS);
            return true;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
        }
    }
}
