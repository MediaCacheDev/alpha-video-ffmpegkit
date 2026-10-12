package com.webmalphaplayer;

import androidx.annotation.Nullable;

/** The {@code mode} and {@code streamBufferFrames} props, which both views take. */
final class StreamMode {

    static final int DEFAULT_BUFFER_FRAMES = 15;

    private StreamMode() {}

    /** Anything other than {@code "preload"}, including no value, means stream. */
    static boolean isStream(@Nullable String mode) {
        return !"preload".equals(mode);
    }
}
