package dev.mediacache.alphavideo.ffmpegkit;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.PorterDuff;
import android.graphics.Rect;
import android.graphics.SurfaceTexture;
import android.os.Handler;
import android.os.Looper;
import android.util.AttributeSet;
import android.util.Log;
import android.view.TextureView;

import androidx.annotation.Nullable;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * FFmpegKitAlphaCPUView - CPU-based VP9+Alpha WebM player using FFmpegKit
 * 
 * Decodes VP9 videos with native alpha channel support and renders
 * frames to a transparent TextureView using CPU-based RGBA conversion.
 * 
 * Features:
 * - True VP9+alpha decoding via FFmpeg's libvpx
 * - Preload mode: frames are decoded once to a raw RGBA file in the cache and read back one at a time
 * - Stream mode: frames are decoded while playing, into a few reused buffers (see {@link FrameStream})
 * - Sources: https (downloaded to the cache), files, asset://, res/raw names and content://
 * - Looping support
 * 
 * For GPU-accelerated rendering, use FFmpegKitAlphaGPUView instead.
 */
public class FFmpegKitAlphaCPUView extends TextureView implements TextureView.SurfaceTextureListener {
    private static final String TAG = "FFmpegKitAlphaCPUView";
    
    private String sourcePath;
    private String cacheKey;  // Custom cache key from props
    private volatile boolean autoPlay = true;
    private volatile boolean loop = true;
    private volatile boolean paused = false;
    private boolean stream = true;
    private int streamBufferFrames = StreamMode.DEFAULT_BUFFER_FRAMES;
    
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private ExecutorService executor;
    // A job loads the source and shows it, playing or paused, until it's stopped.
    private final AtomicBoolean isRunning = new AtomicBoolean(false);
    private final AtomicBoolean shouldStop = new AtomicBoolean(false);
    private final AtomicBoolean isDestroyed = new AtomicBoolean(false);
    // Bumped by every start, so a job left over from an earlier source stops itself.
    private final AtomicInteger generation = new AtomicInteger();
    private volatile int runningGeneration;
    private volatile Playhead playhead;
    private PlayerCallback callback;
    private volatile boolean verbose = false;
    
    // Frame data
    private Bitmap frameBitmap;
    private final Object bitmapLock = new Object();
    
    // Video metadata
    private int videoWidth = 0;
    private int videoHeight = 0;
    private double frameRate = 30.0;
    private int totalFrames = 0;
    
    public FFmpegKitAlphaCPUView(Context context) {
        super(context);
        init();
    }
    
    public FFmpegKitAlphaCPUView(Context context, @Nullable AttributeSet attrs) {
        super(context, attrs);
        init();
    }
    
    public FFmpegKitAlphaCPUView(Context context, @Nullable AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
        init();
    }
    
    private void init() {
        setSurfaceTextureListener(this);
        setOpaque(false); // Critical for transparency
        isDestroyed.set(false);
        
        // Don't intercept touches - let them pass through to views behind
        setClickable(false);
        setFocusable(false);
        setFocusableInTouchMode(false);
    }
    
    private synchronized ExecutorService getOrCreateExecutor() {
        if (executor == null || executor.isShutdown()) {
            executor = Executors.newSingleThreadExecutor();
        }
        return executor;
    }
    
    private synchronized void shutdownExecutor() {
        if (executor != null && !executor.isShutdown()) {
            executor.shutdownNow();
            executor = null;
        }
    }
    
    public void setCallback(@Nullable PlayerCallback callback) {
        this.callback = callback;
    }

    public void setVerbose(boolean verbose) {
        this.verbose = verbose;
    }

    public void setSource(@Nullable String source) {
        if (source != null && source.equals(sourcePath)) return;
        logD("setSource: " + (source != null ? source.substring(0, Math.min(80, source.length())) : "null"));
        
        stopPlayback();
        this.sourcePath = source;
        
        if (source != null && isAvailable()) {
            startPlayback();
        }
    }
    
    /** Off: the first frame shows and stays until playback is allowed. */
    public void setAutoPlay(boolean autoPlay) {
        this.autoPlay = autoPlay;
    }
    
    public void setLoop(boolean loop) {
        this.loop = loop;
    }
    
    /** Holds the current frame; the clip carries on from it when unpaused. */
    public void setPaused(boolean paused) {
        this.paused = paused;
    }

    /**
     * Shows a frame, clamped to the clip, and plays on from it unless paused. Ignored until the
     * clip has loaded, and in stream mode when the container doesn't give a duration.
     */
    public void seekToFrame(int frame) {
        Playhead current = playhead;
        if (current != null) current.seekToFrame(frame);
    }

    /** Seeks to the frame showing at {@code seconds}, as {@link #seekToFrame}. */
    public void seekToTime(double seconds) {
        Playhead current = playhead;
        if (current != null) current.seekToTime(seconds);
    }

    private boolean shouldPlay() {
        return autoPlay && !paused;
    }

    /** {@code "stream"} (default) or {@code "preload"}; changing it restarts playback. */
    public void setMode(@Nullable String mode) {
        boolean stream = StreamMode.isStream(mode);
        if (stream == this.stream) return;
        this.stream = stream;
        restartPlayback();
    }

    /** Decoded frames held ahead of playback in stream mode; applies from the next start. */
    public void setStreamBufferFrames(int frames) {
        this.streamBufferFrames = frames;
    }

    private void restartPlayback() {
        if (!isRunning.get()) return;
        stopPlayback();
        startPlayback();
    }
    
    /**
     * Set custom cache key for remote downloads.
     * If provided, downloaded files will be saved to this path under the cache directory.
     * Example: 'videos/custom-paths/abc123-60x60.webm'
     * If not provided, files are cached using a hash of the URL.
     */
    public void setCacheKey(@Nullable String cacheKey) {
        this.cacheKey = cacheKey;
    }
    
    private void startPlayback() {
        if (sourcePath == null || !isAvailable() || isRunning.get() || isDestroyed.get()) {
            return;
        }
        
        final int gen = generation.incrementAndGet();
        final String source = sourcePath;
        shouldStop.set(false);
        isRunning.set(true);
        
        try {
            getOrCreateExecutor().execute(() -> {
                runningGeneration = gen;
                try {
                    playVideo(source);
                } catch (Exception e) {
                    Log.e(TAG, "Playback error", e);
                    reportError("Playback failed: " + e.getMessage());
                } finally {
                    if (gen == generation.get()) isRunning.set(false);
                }
            });
        } catch (Exception e) {
            Log.e(TAG, "Failed to start playback", e);
            isRunning.set(false);
        }
    }
    
    private void stopPlayback() {
        shouldStop.set(true);
        isRunning.set(false);
        playhead = null;
    }
    
    private void playVideo(String source) {
        WebMSource local;
        FFmpegDecoder.VideoInfo info;
        try {
            local = resolveSource(source);
            info = FFmpegDecoder.probe(getContext(), local);
        } catch (IOException | IllegalArgumentException e) {
            if (!stopRequested()) reportError("Failed to load " + source + ": " + e.getMessage());
            return;
        }
        videoWidth = info.width;
        videoHeight = info.height;
        frameRate = info.frameRate;
        logD("Video: " + videoWidth + "x" + videoHeight + " @ " + frameRate + "fps");
        if (stopRequested()) return;
        Playhead playhead = new Playhead(frameRate, this::shouldPlay, () -> loop, this::stopRequested);
        this.playhead = playhead;
        if (stream) {
            totalFrames = info.estimatedFrames();
            playStream(local, source, playhead);
            return;
        }
        
        File framesDir = new File(getContext().getCacheDir(), "webm-frames-" + System.currentTimeMillis());
        framesDir.mkdirs();
        
        try {
            File rawFile = new File(framesDir, "frames.rgba");
            try {
                FFmpegDecoder.decode(getContext(), local, "-vf format=rgba -f rawvideo", rawFile);
            } catch (IOException e) {
                if (!stopRequested()) reportError("Failed to decode " + source + ": " + e.getMessage());
                return;
            }
            
            int frameSize = videoWidth * videoHeight * 4; // RGBA = 4 bytes per pixel
            totalFrames = (int) (rawFile.length() / frameSize);
            logD("Decoded " + totalFrames + " frames, " + videoWidth + "x" + videoHeight);
            
            if (totalFrames == 0) {
                if (!stopRequested()) reportError("No frames decoded from " + source);
                return;
            }
            playFrames(rawFile, frameSize, playhead);
        } finally {
            deleteRecursive(framesDir);
        }
    }
    
    private WebMSource resolveSource(String source) throws IOException {
        if (WebMDownloader.isRemote(source)) {
            return WebMSource.file(
                WebMDownloader.fetch(getContext(), source, cacheKey, this::stopRequested).getAbsolutePath());
        }
        return WebMSource.parse(source);
    }
    
    private boolean stopRequested() {
        return shouldStop.get() || isDestroyed.get() || runningGeneration != generation.get();
    }
    
    /** Preload mode: frames are read back from the decoded file by index. */
    private void playFrames(File rawFile, int frameSize, Playhead playhead) {
        byte[] frameBuffer = new byte[frameSize];
        int[] pixelBuffer = new int[videoWidth * videoHeight];
        
        try (RandomAccessFile raf = new RandomAccessFile(rawFile, "r")) {
            playhead.playPreloaded(totalFrames, frame -> {
                raf.seek((long) frame * frameSize);
                raf.readFully(frameBuffer);
                convertRGBAtoARGB(frameBuffer, pixelBuffer);
                renderFrame(pixelBuffer);
            }, this::reportLoad, this::reportEnd);
        } catch (Exception e) {
            Log.e(TAG, "Error playing frames", e);
        }
    }
    
    /** onLoad comes with the first frame, and totalFrames is estimated from the duration. */
    private void playStream(WebMSource local, String source, Playhead playhead) {
        int frameSize = videoWidth * videoHeight * 4;
        int[] pixelBuffer = new int[videoWidth * videoHeight];
        int bufferFrames = streamBufferFrames;
        try {
            boolean decodedAny = playhead.playStream(totalFrames,
                (startSeconds, cancelled) -> FrameStream.start(getContext(), local,
                    "-vf format=rgba -f rawvideo", frameSize, bufferFrames, startSeconds,
                    () -> loop, cancelled),
                frame -> {
                    convertRGBAtoARGB(frame, pixelBuffer);
                    renderFrame(pixelBuffer);
                },
                this::reportLoad, this::reportEnd);
            if (!decodedAny && !stopRequested()) reportError("No frames decoded from " + source);
        } catch (IOException e) {
            if (!stopRequested()) reportError("Failed to decode " + source + ": " + e.getMessage());
        }
    }
    
    private void convertRGBAtoARGB(byte[] rgba, int[] argb) {
        for (int i = 0, j = 0; i < argb.length; i++, j += 4) {
            int r = rgba[j] & 0xFF;
            int g = rgba[j + 1] & 0xFF;
            int b = rgba[j + 2] & 0xFF;
            int a = rgba[j + 3] & 0xFF;
            argb[i] = (a << 24) | (r << 16) | (g << 8) | b;
        }
    }
    
    private void renderFrame(int[] pixels) {
        ensureBitmap();
        
        synchronized (bitmapLock) {
            if (frameBitmap != null && !frameBitmap.isRecycled()) {
                frameBitmap.setPixels(pixels, 0, videoWidth, 0, 0, videoWidth, videoHeight);
            }
        }
        
        mainHandler.post(this::drawFrame);
    }
    
    private void ensureBitmap() {
        synchronized (bitmapLock) {
            if (frameBitmap == null || frameBitmap.getWidth() != videoWidth || frameBitmap.getHeight() != videoHeight) {
                if (frameBitmap != null) {
                    frameBitmap.recycle();
                }
                frameBitmap = Bitmap.createBitmap(videoWidth, videoHeight, Bitmap.Config.ARGB_8888);
            }
        }
    }
    
    private void drawFrame() {
        if (!isAvailable() || isDestroyed.get()) return;
        
        Canvas canvas = null;
        try {
            canvas = lockCanvas();
            if (canvas == null) return;
            
            canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR);
            
            synchronized (bitmapLock) {
                if (frameBitmap != null && !frameBitmap.isRecycled()) {
                    float viewRatio = (float) getWidth() / getHeight();
                    float bmpRatio = (float) frameBitmap.getWidth() / frameBitmap.getHeight();
                    
                    Rect destRect;
                    if (viewRatio > bmpRatio) {
                        int drawHeight = getHeight();
                        int drawWidth = (int) (drawHeight * bmpRatio);
                        int left = (getWidth() - drawWidth) / 2;
                        destRect = new Rect(left, 0, left + drawWidth, drawHeight);
                    } else {
                        int drawWidth = getWidth();
                        int drawHeight = (int) (drawWidth / bmpRatio);
                        int top = (getHeight() - drawHeight) / 2;
                        destRect = new Rect(0, top, drawWidth, top + drawHeight);
                    }
                    
                    canvas.drawBitmap(frameBitmap, null, destRect, null);
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "Error drawing frame: " + e.getMessage());
        } finally {
            if (canvas != null) {
                try {
                    unlockCanvasAndPost(canvas);
                } catch (Exception e) {
                    Log.w(TAG, "Error unlocking canvas: " + e.getMessage());
                }
            }
        }
    }
    
    private void reportLoad() {
        final int gen = runningGeneration;
        final int frames = totalFrames, width = videoWidth, height = videoHeight;
        mainHandler.post(() -> {
            if (callback != null && gen == generation.get()) callback.onLoad(frames, width, height);
        });
    }
    
    private void reportEnd() {
        final int gen = runningGeneration;
        mainHandler.post(() -> {
            if (callback != null && gen == generation.get()) callback.onEnd();
        });
    }
    
    private void reportError(String error) {
        Log.e(TAG, error);
        final int gen = runningGeneration;
        mainHandler.post(() -> {
            if (callback != null && gen == generation.get()) callback.onError(error);
        });
    }
    
    private void logD(String message) {
        if (verbose) Log.d(TAG, message);
    }
    
    private void deleteRecursive(File file) {
        if (file.isDirectory()) {
            File[] children = file.listFiles();
            if (children != null) {
                for (File child : children) {
                    deleteRecursive(child);
                }
            }
        }
        file.delete();
    }
    
    @Override
    public void onSurfaceTextureAvailable(SurfaceTexture surface, int width, int height) {
        isDestroyed.set(false);
        if (sourcePath != null) {
            startPlayback();
        }
    }
    
    @Override
    public void onSurfaceTextureSizeChanged(SurfaceTexture surface, int width, int height) {}
    
    @Override
    public boolean onSurfaceTextureDestroyed(SurfaceTexture surface) {
        isDestroyed.set(true);
        shouldStop.set(true);
        isRunning.set(false);
        shutdownExecutor();
        
        synchronized (bitmapLock) {
            if (frameBitmap != null) {
                frameBitmap.recycle();
                frameBitmap = null;
            }
        }
        
        return true;
    }
    
    @Override
    public void onSurfaceTextureUpdated(SurfaceTexture surface) {}
    
    @Override
    protected void onDetachedFromWindow() {
        super.onDetachedFromWindow();
        isDestroyed.set(true);
        shouldStop.set(true);
        shutdownExecutor();
        
        synchronized (bitmapLock) {
            if (frameBitmap != null) {
                frameBitmap.recycle();
                frameBitmap = null;
            }
        }
    }
    
    @Override
    protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        isDestroyed.set(false);
    }
}
