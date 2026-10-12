package dev.mediacache.alphavideo.ffmpegkit;

import androidx.annotation.Nullable;

/** The {@code mode} and {@code streamBufferFrames} props, which both views take. */
public final class StreamMode {

    public static final int DEFAULT_BUFFER_FRAMES = 15;

    private StreamMode() {}

    /** Anything other than {@code "preload"}, including no value, means stream. */
    static boolean isStream(@Nullable String mode) {
        return !"preload".equals(mode);
    }
}
