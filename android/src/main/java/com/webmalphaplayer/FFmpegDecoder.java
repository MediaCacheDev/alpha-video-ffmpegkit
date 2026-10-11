package com.webmalphaplayer;

import android.content.Context;

import com.arthenica.ffmpegkit.FFmpegKit;
import com.arthenica.ffmpegkit.FFmpegSession;
import com.arthenica.ffmpegkit.FFprobeKit;
import com.arthenica.ffmpegkit.FFprobeSession;
import com.arthenica.ffmpegkit.ReturnCode;

import java.io.File;
import java.io.IOException;

/** The two FFmpegKit runs both views make: probe the video stream, then decode every frame. */
final class FFmpegDecoder {

    private static final int OUTPUT_TAIL_CHARS = 600;

    private FFmpegDecoder() {}

    static final class VideoInfo {
        final int width;
        final int height;
        final double frameRate;

        VideoInfo(int width, int height, double frameRate) {
            this.width = width;
            this.height = height;
            this.frameRate = frameRate;
        }
    }

    static VideoInfo probe(Context context, WebMSource source) throws IOException {
        try (FFmpegInput input = FFmpegInput.open(context, source)) {
            FFprobeSession session = FFprobeKit.execute(
                "-v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=p=0 "
                    + quote(input.argument()));
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
            // libvpx-vp9 is the decoder that reads the alpha plane; FFmpeg's native vp9 ignores it.
            FFmpegSession session = FFmpegKit.execute(
                "-c:v libvpx-vp9 -i " + quote(input.argument()) + " " + outputOptions + " "
                    + quote(output.getAbsolutePath()));
            if (!ReturnCode.isSuccess(session.getReturnCode())) {
                throw new IOException("FFmpeg decode failed: " + tail(session.getOutput()));
            }
        }
    }

    private static VideoInfo parseProbe(String output) throws IOException {
        String[] lines = output.trim().split("\n");
        String[] parts = lines[lines.length - 1].trim().split(",");
        if (parts.length < 3) throw new IOException("Unexpected FFprobe output: " + tail(output));
        try {
            int width = Integer.parseInt(parts[0].trim());
            int height = Integer.parseInt(parts[1].trim());
            if (width <= 0 || height <= 0) throw new IOException("No video size in FFprobe output: " + tail(output));
            return new VideoInfo(width, height, parseFrameRate(parts[2].trim()));
        } catch (NumberFormatException e) {
            throw new IOException("Unexpected FFprobe output: " + tail(output));
        }
    }

    private static double parseFrameRate(String rate) {
        if (!rate.contains("/")) return Double.parseDouble(rate);
        String[] fraction = rate.split("/");
        double num = Double.parseDouble(fraction[0]);
        double den = Double.parseDouble(fraction[1]);
        return den > 0 ? num / den : 30.0;
    }

    private static String quote(String path) {
        return "\"" + path.replace("\"", "\\\"") + "\"";
    }

    private static String tail(String output) {
        if (output == null) return "(no output)";
        String trimmed = output.trim();
        return trimmed.length() <= OUTPUT_TAIL_CHARS ? trimmed : "…" + trimmed.substring(trimmed.length() - OUTPUT_TAIL_CHARS);
    }
}
