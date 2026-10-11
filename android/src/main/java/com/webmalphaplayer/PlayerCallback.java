package com.webmalphaplayer;

/** What a player view reports. Called on the main thread. */
public interface PlayerCallback {
    void onLoad(int totalFrames, int width, int height);

    void onError(String error);

    /** The clip reached its last frame with {@code loop} off. */
    void onEnd();
}
