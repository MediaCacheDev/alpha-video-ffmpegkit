package dev.mediacache.alphavideo.ffmpegkit;

import android.content.Context;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;

import com.arthenica.ffmpegkit.FFmpegKit;
import com.arthenica.ffmpegkit.FFmpegKitConfig;
import com.arthenica.ffmpegkit.FFmpegSession;
import com.arthenica.ffmpegkit.ReturnCode;

import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.function.BooleanSupplier;

/**
 * Decodes a source while it plays, for stream mode.
 *
 * FFmpeg writes raw frames into an FFmpegKit named pipe, and a reader thread fills a fixed pool
 * of frame buffers. When every buffer is waiting to be shown, the reader stops reading, the pipe
 * fills and FFmpeg blocks, so memory stays at {@code bufferFrames × frameSize} however long the
 * clip is. A looping clip is decoded again from the start for each pass; the buffered frames
 * cover the restart.
 *
 * FFmpeg runs on a thread of its own rather than through FFmpegKit's async pool, which is
 * shared and capped at a few sessions: a stream holds its session for as long as it plays.
 */
final class FrameStream implements AutoCloseable {

    private static final Object END = new Object();
    private static final long POLL_MS = 50;
    private static final int UNBLOCK_ATTEMPTS = 50;
    private static final long UNBLOCK_WAIT_MS = 20;
    private static final long CLOSE_WAIT_MS = 2000;

    private final Context context;
    private final WebMSource source;
    private final String outputOptions;
    private final int frameSize;
    private final BooleanSupplier loop;
    private final BooleanSupplier cancelled;
    private final ArrayBlockingQueue<byte[]> free;
    private final ArrayBlockingQueue<Object> ready;
    private final Thread reader;

    private volatile boolean closed;
    private volatile FFmpegSession session;
    private volatile IOException failure;

    private FrameStream(Context context, WebMSource source, String outputOptions, int frameSize,
                        int bufferFrames, BooleanSupplier loop, BooleanSupplier cancelled) {
        this.context = context;
        this.source = source;
        this.outputOptions = outputOptions;
        this.frameSize = frameSize;
        this.loop = loop;
        this.cancelled = cancelled;
        this.free = new ArrayBlockingQueue<>(bufferFrames);
        // One more slot than there are buffers, so END always fits.
        this.ready = new ArrayBlockingQueue<>(bufferFrames + 1);
        for (int i = 0; i < bufferFrames; i++) free.add(new byte[frameSize]);
        this.reader = new Thread(this::run, "FFmpegKitAlphaStream");
    }

    /**
     * @param outputOptions FFmpeg options for the raw output, e.g. {@code "-f rawvideo -pix_fmt yuva420p"}
     * @param loop          read at the end of each pass: whether to decode the clip again
     * @param cancelled     polled while waiting for a frame; {@link #next()} returns null once it's true
     */
    static FrameStream start(Context context, WebMSource source, String outputOptions, int frameSize,
                             int bufferFrames, BooleanSupplier loop, BooleanSupplier cancelled) {
        FrameStream stream = new FrameStream(
            context, source, outputOptions, frameSize, Math.max(1, bufferFrames), loop, cancelled);
        stream.reader.start();
        return stream;
    }

    /**
     * The next frame, waiting for the decoder if it's behind. Returns null once a clip that
     * doesn't loop has ended, or when cancelled. Hand each frame back with {@link #recycle}.
     */
    byte[] next() throws IOException {
        while (!closed && !cancelled.getAsBoolean()) {
            Object item;
            try {
                item = ready.poll(POLL_MS, TimeUnit.MILLISECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return null;
            }
            if (item == null) continue;
            if (item == END) {
                if (failure != null) throw failure;
                return null;
            }
            return (byte[]) item;
        }
        return null;
    }

    void recycle(byte[] frame) {
        free.offer(frame);
    }

    @Override
    public void close() {
        closed = true;
        FFmpegSession current = session;
        if (current != null) FFmpegKit.cancel(current.getSessionId());
        // The reader may be waiting for a free buffer. Once it stops, it closes the pipe, and
        // FFmpeg's next write fails, so FFmpeg exits even if it's blocked on a full pipe.
        reader.interrupt();
        try {
            reader.join(CLOSE_WAIT_MS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private void run() {
        try {
            do {
                decodePass();
            } while (!closed && loop.getAsBoolean());
        } catch (IOException e) {
            if (!closed) failure = e;
        } catch (InterruptedException ignored) {
        } finally {
            ready.offer(END);
        }
    }

    /** Decodes the clip once, from the start, into {@link #ready}. */
    private void decodePass() throws IOException, InterruptedException {
        String pipe = FFmpegKitConfig.registerNewFFmpegPipe(context);
        if (pipe == null) throw new IOException("Cannot create an FFmpeg pipe");
        try (FFmpegInput input = FFmpegInput.open(context, source)) {
            // -y: the pipe already exists, and FFmpeg would otherwise refuse to overwrite it.
            FFmpegSession pass = FFmpegSession.create(FFmpegKitConfig.parseArguments(
                FFmpegDecoder.decodeCommand(input.argument(), outputOptions + " -y", pipe)));
            session = pass;
            ReaderGate gate = new ReaderGate();
            Thread decoder = new Thread(() -> {
                FFmpegKitConfig.ffmpegExecute(pass);
                gate.releaseReader(pipe);
            }, "FFmpegKitAlphaDecode");
            decoder.start();
            try {
                readFrames(pipe, gate);
            } finally {
                if (closed) FFmpegKit.cancel(pass.getSessionId());
                decoder.join();
            }
            if (!closed && !ReturnCode.isSuccess(pass.getReturnCode())) {
                throw new IOException("FFmpeg decode failed: " + FFmpegDecoder.tail(pass.getOutput()));
            }
        } finally {
            FFmpegKitConfig.closeFFmpegPipe(pipe);
        }
    }

    private void readFrames(String pipe, ReaderGate gate) throws IOException, InterruptedException {
        // Opening a pipe for reading blocks until FFmpeg opens it for writing.
        try (InputStream in = new FileInputStream(pipe)) {
            gate.readerOpened = true;
            while (!closed) {
                byte[] frame = free.take();
                if (!readFully(in, frame)) {
                    free.offer(frame);
                    return;
                }
                ready.put(frame);
            }
        }
    }

    /** False at the end of the output; a partial last frame is dropped. */
    private boolean readFully(InputStream in, byte[] frame) throws IOException {
        int filled = 0;
        while (filled < frameSize) {
            int n = in.read(frame, filled, frameSize - filled);
            if (n < 0) return false;
            filled += n;
        }
        return true;
    }

    /**
     * If FFmpeg fails before it opens its output, the reader stays blocked opening the pipe.
     * When FFmpeg is done, a short-lived writer lets that open return, and the reader then sees
     * the end of the output.
     */
    private static final class ReaderGate {
        volatile boolean readerOpened;

        void releaseReader(String pipe) {
            for (int i = 0; !readerOpened && i < UNBLOCK_ATTEMPTS; i++) {
                try {
                    FileDescriptor fd = Os.open(pipe, OsConstants.O_WRONLY | OsConstants.O_NONBLOCK, 0);
                    Os.close(fd);
                    return;
                } catch (ErrnoException e) {
                    // ENXIO: the reader hasn't opened the pipe yet.
                }
                try {
                    Thread.sleep(UNBLOCK_WAIT_MS);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return;
                }
            }
        }
    }
}
