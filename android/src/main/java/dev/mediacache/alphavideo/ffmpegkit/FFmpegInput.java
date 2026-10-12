package dev.mediacache.alphavideo.ffmpegkit;

import android.content.Context;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;

import com.arthenica.ffmpegkit.FFmpegKitConfig;

import java.io.File;
import java.io.FileDescriptor;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * The {@code -i} argument for one FFmpeg or FFprobe run over a {@link WebMSource}.
 *
 * A file is passed by path. Assets, raw resources and content URIs have no path of their own, so
 * they are written into an FFmpegKit named pipe by a background thread while FFmpeg reads it.
 * Each run needs its own instance, because a pipe can only be read once.
 */
final class FFmpegInput implements AutoCloseable {

    private static final int UNBLOCK_ATTEMPTS = 50;
    private static final long UNBLOCK_WAIT_MS = 20;

    private final String argument;
    private final String pipe;
    private Thread writer;
    private volatile boolean closed;

    private FFmpegInput(String argument, String pipe) {
        this.argument = argument;
        this.pipe = pipe;
    }

    static FFmpegInput open(Context context, WebMSource source) throws IOException {
        if (source.isFile()) {
            if (!new File(source.path()).isFile()) throw new FileNotFoundException("File not found: " + source.path());
            return new FFmpegInput(source.path(), null);
        }

        InputStream in = source.openStream(context);
        String pipe = FFmpegKitConfig.registerNewFFmpegPipe(context);
        if (pipe == null) {
            in.close();
            throw new IOException("Cannot create an FFmpeg pipe");
        }
        FFmpegInput input = new FFmpegInput(pipe, pipe);
        input.writer = new Thread(() -> input.copy(in), "FFmpegKitAlphaPipe");
        input.writer.start();
        return input;
    }

    String argument() {
        return argument;
    }

    private void copy(InputStream source) {
        // Opening a pipe for writing blocks until FFmpeg opens it for reading. FFmpeg stops
        // reading early when it has seen enough (ffprobe), which ends the copy with EPIPE.
        try (InputStream in = source; OutputStream out = new FileOutputStream(pipe)) {
            byte[] buffer = new byte[64 * 1024];
            int n;
            while (!closed && (n = in.read(buffer)) != -1) {
                out.write(buffer, 0, n);
            }
        } catch (IOException ignored) {
        }
    }

    @Override
    public void close() {
        if (pipe == null) return;
        closed = true;
        // If FFmpeg failed before opening the pipe, the writer is still blocked opening it. A
        // short-lived reader lets that open return, and the next write then fails with EPIPE.
        for (int i = 0; writer.isAlive() && i < UNBLOCK_ATTEMPTS; i++) {
            unblockWriter();
            try {
                writer.join(UNBLOCK_WAIT_MS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }
        FFmpegKitConfig.closeFFmpegPipe(pipe);
    }

    private void unblockWriter() {
        try {
            FileDescriptor fd = Os.open(pipe, OsConstants.O_RDONLY | OsConstants.O_NONBLOCK, 0);
            Os.close(fd);
        } catch (ErrnoException ignored) {
        }
    }
}
