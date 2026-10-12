package com.webmalphaplayer;

/**
 * Paces stream-mode playback at the clip's frame rate. If the decoder falls more than a frame
 * behind, the clock restarts from now instead of rushing through frames to catch up.
 */
final class FrameClock {

    private final long intervalNs;
    private long nextNs;

    FrameClock(double frameRate) {
        intervalNs = (long) (1_000_000_000.0 / frameRate);
        nextNs = System.nanoTime() + intervalNs;
    }

    /** Sleeps until the next frame is due. False if the thread was interrupted. */
    boolean awaitNextFrame() {
        long now = System.nanoTime();
        if (now - nextNs > intervalNs) nextNs = now;
        long sleepNs = nextNs - now;
        nextNs += intervalNs;
        if (sleepNs <= 0) return true;
        try {
            Thread.sleep(sleepNs / 1_000_000, (int) (sleepNs % 1_000_000));
            return true;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
        }
    }
}
