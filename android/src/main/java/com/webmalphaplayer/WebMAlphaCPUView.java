package com.webmalphaplayer;

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
 * WebMAlphaCPUView - CPU-based VP9+Alpha WebM player using FFmpegKit
 * 
 * Decodes VP9 videos with native alpha channel support and renders
 * frames to a transparent TextureView using CPU-based RGBA conversion.
 * 
 * Features:
 * - True VP9+alpha decoding via FFmpeg's libvpx
 * - Frames are decoded once to a raw RGBA file in the cache and read back one at a time
 * - Sources: https (downloaded to the cache), files, asset://, res/raw names and content://
 * - Looping support
 * 
 * For GPU-accelerated rendering, use WebMAlphaGPUView instead.
 */
public class WebMAlphaCPUView extends TextureView implements TextureView.SurfaceTextureListener {
    private static final String TAG = "WebMAlphaCPUView";
    
    private String sourcePath;
    private String cacheKey;  // Custom cache key from props
    private boolean autoPlay = true;
    private boolean loop = true;
    private boolean paused = false;
    
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private ExecutorService executor;
    private final AtomicBoolean isPlaying = new AtomicBoolean(false);
    private final AtomicBoolean shouldStop = new AtomicBoolean(false);
    private final AtomicBoolean isDestroyed = new AtomicBoolean(false);
    // Bumped by every start, so a job left over from an earlier source or pause stops itself.
    private final AtomicInteger generation = new AtomicInteger();
    private volatile int runningGeneration;
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
    
    public WebMAlphaCPUView(Context context) {
        super(context);
        init();
    }
    
    public WebMAlphaCPUView(Context context, @Nullable AttributeSet attrs) {
        super(context, attrs);
        init();
    }
    
    public WebMAlphaCPUView(Context context, @Nullable AttributeSet attrs, int defStyleAttr) {
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
        
        if (source != null && autoPlay && !paused && isAvailable()) {
            startPlayback();
        }
    }
    
    public void setAutoPlay(boolean autoPlay) {
        this.autoPlay = autoPlay;
        updatePlaybackState();
    }
    
    public void setLoop(boolean loop) {
        this.loop = loop;
    }
    
    public void setPaused(boolean paused) {
        this.paused = paused;
        updatePlaybackState();
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
    
    private void updatePlaybackState() {
        if (sourcePath == null || !isAvailable()) return;
        
        if (paused) {
            stopPlayback();
        } else if (autoPlay && !isPlaying.get()) {
            startPlayback();
        }
    }
    
    private void startPlayback() {
        if (sourcePath == null || !isAvailable() || isPlaying.get() || isDestroyed.get()) {
            return;
        }
        
        final int gen = generation.incrementAndGet();
        final String source = sourcePath;
        shouldStop.set(false);
        isPlaying.set(true);
        
        try {
            getOrCreateExecutor().execute(() -> {
                runningGeneration = gen;
                try {
                    playVideo(source);
                } catch (Exception e) {
                    Log.e(TAG, "Playback error", e);
                    reportError("Playback failed: " + e.getMessage());
                } finally {
                    if (gen == generation.get()) isPlaying.set(false);
                }
            });
        } catch (Exception e) {
            Log.e(TAG, "Failed to start playback", e);
            isPlaying.set(false);
        }
    }
    
    private void stopPlayback() {
        shouldStop.set(true);
        isPlaying.set(false);
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
            reportLoad();
            playFrames(rawFile, frameSize);
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
    
    private void playFrames(File rawFile, int frameSize) {
        long frameIntervalNs = (long) (1_000_000_000.0 / frameRate);
        byte[] frameBuffer = new byte[frameSize];
        int[] pixelBuffer = new int[videoWidth * videoHeight];
        
        try (RandomAccessFile raf = new RandomAccessFile(rawFile, "r")) {
            do {
                raf.seek(0);
                long startTime = System.nanoTime();
                int frameIndex = 0;
                
                while (!stopRequested() && frameIndex < totalFrames) {
                    int bytesRead = raf.read(frameBuffer);
                    if (bytesRead != frameSize) break;
                    
                    convertRGBAtoARGB(frameBuffer, pixelBuffer);
                    renderFrame(pixelBuffer);
                    
                    frameIndex++;
                    
                    long targetTimeNs = startTime + (frameIndex * frameIntervalNs);
                    long sleepNs = targetTimeNs - System.nanoTime();
                    
                    if (sleepNs > 1_000_000) {
                        try {
                            Thread.sleep(sleepNs / 1_000_000, (int) (sleepNs % 1_000_000));
                        } catch (InterruptedException e) {
                            Thread.currentThread().interrupt();
                            return;
                        }
                    }
                }
                
            } while (loop && !stopRequested());
            
            if (!stopRequested()) reportEnd();
        } catch (Exception e) {
            Log.e(TAG, "Error playing frames", e);
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
        if (sourcePath != null && autoPlay && !paused) {
            startPlayback();
        }
    }
    
    @Override
    public void onSurfaceTextureSizeChanged(SurfaceTexture surface, int width, int height) {}
    
    @Override
    public boolean onSurfaceTextureDestroyed(SurfaceTexture surface) {
        isDestroyed.set(true);
        shouldStop.set(true);
        isPlaying.set(false);
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
