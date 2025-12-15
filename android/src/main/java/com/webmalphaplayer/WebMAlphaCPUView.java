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

import com.arthenica.ffmpegkit.FFmpegKit;
import com.arthenica.ffmpegkit.FFmpegSession;
import com.arthenica.ffmpegkit.FFprobeKit;
import com.arthenica.ffmpegkit.FFprobeSession;
import com.arthenica.ffmpegkit.ReturnCode;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.RandomAccessFile;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * WebMAlphaCPUView - CPU-based VP9+Alpha WebM player using FFmpegKit
 * 
 * Decodes VP9 videos with native alpha channel support and renders
 * frames to a transparent TextureView using CPU-based RGBA conversion.
 * 
 * Features:
 * - True VP9+alpha decoding via FFmpeg's libvpx
 * - Memory-efficient frame extraction to raw RGBA
 * - Caching for remote videos
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
    
    public void setSource(@Nullable String source) {
        Log.d(TAG, "setSource: " + (source != null ? source.substring(0, Math.min(80, source.length())) : "null"));
        
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
        Log.d(TAG, "setCacheKey: " + cacheKey);
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
        
        shouldStop.set(false);
        isPlaying.set(true);
        
        try {
            getOrCreateExecutor().execute(() -> {
                try {
                    playVideo(sourcePath);
                } catch (Exception e) {
                    Log.e(TAG, "Playback error", e);
                } finally {
                    isPlaying.set(false);
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
        String localPath = source;
        
        // Download remote URLs to cache
        if (source.startsWith("http://") || source.startsWith("https://")) {
            localPath = downloadToCache(source);
            if (localPath == null) {
                Log.e(TAG, "Failed to download video");
                return;
            }
        } else if (source.startsWith("file://")) {
            localPath = source.substring(7);
        }
        
        // Get video metadata
        if (!probeVideo(localPath)) {
            Log.e(TAG, "Failed to probe video");
            return;
        }
        
        // Create temp directory for frames
        File framesDir = new File(getContext().getCacheDir(), "webm-frames-" + System.currentTimeMillis());
        framesDir.mkdirs();
        
        try {
            // Extract all frames as RGBA using FFmpeg
            // CRITICAL: Use -c:v libvpx-vp9 to force VP9 decoder that supports alpha
            File rawFile = new File(framesDir, "frames.rgba");
            
            String ffmpegCmd = String.format(
                "-c:v libvpx-vp9 -i %s -vf format=rgba -f rawvideo %s",
                escapePath(localPath), escapePath(rawFile.getAbsolutePath())
            );
            
            Log.d(TAG, "FFmpeg command: " + ffmpegCmd);
            
            FFmpegSession session = FFmpegKit.execute(ffmpegCmd);
            
            if (!ReturnCode.isSuccess(session.getReturnCode())) {
                Log.e(TAG, "FFmpeg failed: " + session.getOutput());
                return;
            }
            
            // Calculate frame size
            int frameSize = videoWidth * videoHeight * 4; // RGBA = 4 bytes per pixel
            long fileSize = rawFile.length();
            totalFrames = (int) (fileSize / frameSize);
            
            Log.d(TAG, "Decoded " + totalFrames + " frames, " + videoWidth + "x" + videoHeight);
            
            if (totalFrames > 0) {
                playFrames(rawFile, frameSize);
            }
            
        } finally {
            deleteRecursive(framesDir);
        }
    }
    
    private String escapePath(String path) {
        return "\"" + path.replace("\"", "\\\"") + "\"";
    }
    
    private boolean probeVideo(String path) {
        String probeCmd = String.format(
            "-v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=p=0 %s",
            escapePath(path)
        );
        
        FFprobeSession probeSession = FFprobeKit.execute(probeCmd);
        
        if (!ReturnCode.isSuccess(probeSession.getReturnCode())) {
            Log.e(TAG, "FFprobe failed: " + probeSession.getOutput());
            return false;
        }
        
        String output = probeSession.getOutput().trim();
        
        try {
            String[] lines = output.split("\n");
            String lastLine = lines[lines.length - 1].trim();
            String[] parts = lastLine.split(",");
            
            if (parts.length >= 3) {
                videoWidth = Integer.parseInt(parts[0].trim());
                videoHeight = Integer.parseInt(parts[1].trim());
                
                String fps = parts[2].trim();
                if (fps.contains("/")) {
                    String[] fpsParts = fps.split("/");
                    double num = Double.parseDouble(fpsParts[0]);
                    double den = Double.parseDouble(fpsParts[1]);
                    if (den > 0) {
                        frameRate = num / den;
                    }
                } else {
                    frameRate = Double.parseDouble(fps);
                }
                
                Log.d(TAG, "Video: " + videoWidth + "x" + videoHeight + " @ " + frameRate + "fps");
                return videoWidth > 0 && videoHeight > 0;
            }
        } catch (Exception e) {
            Log.e(TAG, "Failed to parse video metadata", e);
        }
        
        return false;
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
                
                while (!shouldStop.get() && !isDestroyed.get() && frameIndex < totalFrames) {
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
                
            } while (loop && !shouldStop.get() && !isDestroyed.get());
            
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
    
    private String downloadToCache(String urlString) {
        try {
            File cacheFile;
            String tempSuffix;
            
            // Use custom cacheKey if provided, otherwise fall back to URL hash
            if (cacheKey != null && !cacheKey.isEmpty()) {
                // Use custom cache path - create parent directories as needed
                cacheFile = new File(getContext().getCacheDir(), cacheKey);
                File parentDir = cacheFile.getParentFile();
                if (parentDir != null && !parentDir.exists()) {
                    parentDir.mkdirs();
                }
                tempSuffix = String.valueOf(cacheKey.hashCode());
                Log.d(TAG, "📁 Using custom cacheKey: " + cacheKey);
            } else {
                // Fall back to URL hash-based cache key
                MessageDigest md = MessageDigest.getInstance("MD5");
                byte[] hashBytes = md.digest(urlString.getBytes());
                StringBuilder sb = new StringBuilder();
                for (byte b : hashBytes) {
                    sb.append(String.format("%02x", b));
                }
                String hash = sb.toString().substring(0, 16);
                
                File cacheDir = new File(getContext().getCacheDir(), "webm-cache");
                if (!cacheDir.exists()) {
                    cacheDir.mkdirs();
                }
                
                cacheFile = new File(cacheDir, hash + ".webm");
                tempSuffix = hash;
            }
            
            if (cacheFile.exists()) {
                Log.d(TAG, "📦 Using cached: " + cacheFile.getAbsolutePath());
                return cacheFile.getAbsolutePath();
            }
            
            URL url = new URL(urlString);
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setConnectTimeout(15000);
            conn.setReadTimeout(30000);
            conn.setRequestProperty("User-Agent", "WebMAlphaPlayer/1.0");
            
            int responseCode = conn.getResponseCode();
            if (responseCode != HttpURLConnection.HTTP_OK) {
                Log.e(TAG, "❌ Download failed: HTTP " + responseCode);
                return null;
            }
            
            // Download to temp file first, then rename (atomic operation)
            File tempFile = new File(getContext().getCacheDir(), "webm_tmp_" + tempSuffix + ".webm");
            
            try (InputStream in = conn.getInputStream();
                 FileOutputStream out = new FileOutputStream(tempFile)) {
                byte[] buffer = new byte[8192];
                int bytesRead;
                int totalBytes = 0;
                while ((bytesRead = in.read(buffer)) != -1) {
                    if (shouldStop.get()) {
                        tempFile.delete();
                        return null;
                    }
                    out.write(buffer, 0, bytesRead);
                    totalBytes += bytesRead;
                }
                Log.d(TAG, "✅ Downloaded " + totalBytes + " bytes");
            }
            
            // Atomic rename to final cache location
            if (tempFile.renameTo(cacheFile)) {
                return cacheFile.getAbsolutePath();
            } else {
                // Rename failed, use temp file directly
                Log.w(TAG, "Failed to rename, using temp file");
                return tempFile.getAbsolutePath();
            }
            
        } catch (Exception e) {
            Log.e(TAG, "Download failed", e);
            return null;
        }
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
