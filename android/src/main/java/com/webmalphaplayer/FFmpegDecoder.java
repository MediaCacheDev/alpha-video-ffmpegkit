package com.webmalphaplayer;

import android.content.Context;

import com.arthenica.ffmpegkit.FFmpegKit;
import com.arthenica.ffmpegkit.FFmpegSession;
import com.arthenica.ffmpegkit.FFprobeKit;
import com.arthenica.ffmpegkit.FFprobeSession;
import com.arthenica.ffmpegkit.ReturnCode;

import androidx.annotation.Nullable;

import java.io.File;
import java.io.IOException;
import java.util.HashMap;
import java.util.Map;

/** The FFmpegKit runs both views make: probe the video stream, then decode its frames. */
final class FFmpegDecoder {

    private static final int OUTPUT_TAIL_CHARS = 600;
    private static final double DEFAULT_FRAME_RATE = 30.0;

    private FFmpegDecoder() {}

    static final class VideoInfo {
        final int width;
        final int height;
        final double frameRate;
        /** 0 if the container doesn't say. */
        final double durationSeconds;

        VideoInfo(int width, int height, double frameRate, double durationSeconds) {
            this.width = width;
            this.height = height;
            this.frameRate = frameRate;
            this.durationSeconds = durationSeconds;
        }

        /** Frame count from the duration, for stream mode, which reports onLoad before decoding the clip. */
        int estimatedFrames() {
            return (int) Math.round(durationSeconds * frameRate);
        }
    }

    static VideoInfo probe(Context context, WebMSource source) throws IOException {
        try (FFmpegInput input = FFmpegInput.open(context, source)) {
            FFprobeSession session = FFprobeKit.execute(
                "-v error -select_streams v:0"
                    + " -show_entries stream=width,height,avg_frame_rate,r_frame_rate:format=duration"
                    + " -of default=noprint_wrappers=1 " + quote(input.argument()));
            if (!ReturnCode.isSuccess(session.getReturnCode())) {
                throw new IOException("FFprobe failed: " + tail(session.getOutput()));
            }
            return parseProbe(session.getOutput());
        }
    }

    /**
     * Decodes every frame of {@code source} into {@code output}.
     *
     * @param outputOptions FFmpeg options between the input and the output file, e.g. the pixel format
     */
    static void decode(Context context, WebMSource source, String outputOptions, File output) throws IOException {
        try (FFmpegInput input = FFmpegInput.open(context, source)) {
            FFmpegSession session = FFmpegKit.execute(
                decodeCommand(input.argument(), outputOptions, output.getAbsolutePath()));
            if (!ReturnCode.isSuccess(session.getReturnCode())) {
                throw new IOException("FFmpeg decode failed: " + tail(session.getOutput()));
            }
        }
    }

    static String decodeCommand(String input, String outputOptions, String output) {
        // libvpx-vp9 is the decoder that reads the alpha plane; FFmpeg's native vp9 ignores it.
        return "-c:v libvpx-vp9 -i " + quote(input) + " -an " + outputOptions + " " + quote(output);
    }

    /**
     * {@code key=value} lines. The frame rate is the stream's average rate, or failing that the
     * rate its timestamps are based on (both from the file), and 30 only if the file gives neither.
     */
    private static VideoInfo parseProbe(String output) throws IOException {
        Map<String, String> values = new HashMap<>();
        for (String line : output.trim().split("\n")) {
            int equals = line.indexOf('=');
            if (equals > 0) values.put(line.substring(0, equals).trim(), line.substring(equals + 1).trim());
        }
        int width = parseInt(values.get("width"));
        int height = parseInt(values.get("height"));
        if (width <= 0 || height <= 0) throw new IOException("No video size in FFprobe output: " + tail(output));
        double frameRate = parseRate(values.get("avg_frame_rate"));
        if (frameRate <= 0) frameRate = parseRate(values.get("r_frame_rate"));
        if (frameRate <= 0) frameRate = DEFAULT_FRAME_RATE;
        return new VideoInfo(width, height, frameRate, Math.max(0, parseDouble(values.get("duration"))));
    }

    /** {@code "30000/1001"} or {@code "30"}; 0 for {@code "0/0"}, "N/A" and anything else unusable. */
    private static double parseRate(@Nullable String rate) {
        if (rate == null) return 0;
        int slash = rate.indexOf('/');
        if (slash < 0) return parseDouble(rate);
        double num = parseDouble(rate.substring(0, slash));
        double den = parseDouble(rate.substring(slash + 1));
        return num > 0 && den > 0 ? num / den : 0;
    }

    private static int parseInt(@Nullable String value) {
        try {
            return value == null ? 0 : Integer.parseInt(value);
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    private static double parseDouble(@Nullable String value) {
        try {
            return value == null ? 0 : Double.parseDouble(value);
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    private static String quote(String path) {
        return "\"" + path.replace("\"", "\\\"") + "\"";
    }

    static String tail(String output) {
        if (output == null) return "(no output)";
        String trimmed = output.trim();
        return trimmed.length() <= OUTPUT_TAIL_CHARS ? trimmed : "…" + trimmed.substring(trimmed.length() - OUTPUT_TAIL_CHARS);
    }
}
