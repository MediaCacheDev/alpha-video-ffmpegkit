package dev.mediacache.alphavideo.ffmpegkit;

import android.content.Context;
import android.graphics.SurfaceTexture;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.opengl.GLES20;
import android.os.Handler;
import android.os.Looper;
import android.util.AttributeSet;
import android.util.Log;
import android.view.TextureView;

import androidx.annotation.Nullable;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * FFmpegKitAlphaGPUView - GPU-accelerated VP9+Alpha WebM player using OpenGL ES
 * 
 * Instead of CPU-based RGBA conversion, this implementation:
 * 1. Decodes VP9 to raw yuva420p planes using FFmpeg (CPU - unavoidable)
 * 2. Uploads Y, U, V, A planes as separate textures to GPU
 * 3. Uses an OpenGL ES shader to convert YUV→RGB with alpha (GPU - FAST)
 * 4. Renders directly to a TextureView via EGL
 *
 * This provides ~3-5x better performance for the color conversion step
 * compared to the CPU-based RGBA conversion.
 *
 * In preload mode every frame is uploaded to its own textures before playback starts. In stream
 * mode frames are decoded while playing (see {@link FrameStream}) and uploaded one at a time.
 */
public class FFmpegKitAlphaGPUView extends TextureView implements TextureView.SurfaceTextureListener {
    private static final String TAG = "FFmpegKitAlphaGPUView";
    
    private String sourcePath;
    private String cacheKey;  // Custom cache key from props
    private boolean autoPlay = true;
    private boolean loop = true;
    private boolean paused = false;
    private boolean stream = true;
    private int streamBufferFrames = StreamMode.DEFAULT_BUFFER_FRAMES;
    
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
    
    // Video metadata
    private int videoWidth = 0;
    private int videoHeight = 0;
    private double frameRate = 30.0;
    private int totalFrames = 0;
    
    // OpenGL ES resources
    private EGLDisplay eglDisplay;
    private EGLContext eglContext;
    private EGLSurface eglSurface;
    private int program;
    private FloatBuffer vertexBuffer;
    private FloatBuffer texCoordBuffer;
    
    // GPU texture cache - all frames pre-uploaded to GPU
    private int[][] frameTextures; // [frameIndex][0=Y, 1=U, 2=V, 3=A]
    private int currentFrameIndex = 0;
    
    private boolean hasLoggedFirstFrame = false;
    
    // Vertex shader - simple pass-through
    private static final String VERTEX_SHADER = 
        "attribute vec4 aPosition;\n" +
        "attribute vec2 aTexCoord;\n" +
        "varying vec2 vTexCoord;\n" +
        "void main() {\n" +
        "    gl_Position = aPosition;\n" +
        "    vTexCoord = aTexCoord;\n" +
        "}\n";
    
    // Fragment shader - YUV to RGB conversion with alpha
    private static final String FRAGMENT_SHADER =
        "precision mediump float;\n" +
        "varying vec2 vTexCoord;\n" +
        "uniform sampler2D yTexture;\n" +
        "uniform sampler2D uTexture;\n" +
        "uniform sampler2D vTexture;\n" +
        "uniform sampler2D aTexture;\n" +
        "void main() {\n" +
        "    float y = texture2D(yTexture, vTexCoord).r;\n" +
        "    float u = texture2D(uTexture, vTexCoord).r - 0.5;\n" +
        "    float v = texture2D(vTexture, vTexCoord).r - 0.5;\n" +
        "    float a = texture2D(aTexture, vTexCoord).r;\n" +
        "    // BT.601 YUV to RGB conversion (standard for web video)\n" +
        "    float r = y + 1.402 * v;\n" +
        "    float g = y - 0.344136 * u - 0.714136 * v;\n" +
        "    float b = y + 1.772 * u;\n" +
        "    // Premultiply alpha for correct compositing\n" +
        "    gl_FragColor = vec4(r * a, g * a, b * a, a);\n" +
        "}\n";
    
    private static final float[] VERTEX_DATA = {
        -1.0f, -1.0f,
         1.0f, -1.0f,
        -1.0f,  1.0f,
         1.0f,  1.0f
    };
    
    private static final float[] TEXCOORD_DATA = {
        0.0f, 1.0f,
        1.0f, 1.0f,
        0.0f, 0.0f,
        1.0f, 0.0f
    };
    
    public FFmpegKitAlphaGPUView(Context context) {
        super(context);
        init();
    }
    
    public FFmpegKitAlphaGPUView(Context context, @Nullable AttributeSet attrs) {
        super(context, attrs);
        init();
    }
    
    public FFmpegKitAlphaGPUView(Context context, @Nullable AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
        init();
    }
    
    private void init() {
        setSurfaceTextureListener(this);
        setOpaque(false);
        isDestroyed.set(false);
        
        // Don't intercept touches - let them pass through to views behind
        setClickable(false);
        setFocusable(false);
        setFocusableInTouchMode(false);
        
        vertexBuffer = ByteBuffer.allocateDirect(VERTEX_DATA.length * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .put(VERTEX_DATA);
        vertexBuffer.position(0);
        
        texCoordBuffer = ByteBuffer.allocateDirect(TEXCOORD_DATA.length * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .put(TEXCOORD_DATA);
        texCoordBuffer.position(0);
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
        hasLoggedFirstFrame = false;
        
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
        if (!isPlaying.get()) return;
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
                    cleanupGL();
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
        
        SurfaceTexture surfaceTexture = getSurfaceTexture();
        if (surfaceTexture == null || !initGL(surfaceTexture)) {
            if (!stopRequested()) reportError("Failed to initialize OpenGL ES");
            return;
        }
        if (stream) {
            totalFrames = info.estimatedFrames();
            playStream(local, source);
            return;
        }
        
        // Decode to temp file, upload to GPU, delete immediately
        File rawFile = new File(getContext().getCacheDir(), "webm_decode_" + System.currentTimeMillis() + ".yuva");
        
        try {
            try {
                FFmpegDecoder.decode(getContext(), local, "-f rawvideo -pix_fmt yuva420p", rawFile);
            } catch (IOException e) {
                if (!stopRequested()) reportError("Failed to decode " + source + ": " + e.getMessage());
                return;
            }
            
            int ySize = videoWidth * videoHeight;
            int uvSize = (videoWidth / 2) * (videoHeight / 2);
            int aSize = videoWidth * videoHeight;
            int frameSize = ySize + uvSize + uvSize + aSize;
            
            long fileSize = rawFile.length();
            totalFrames = (int) (fileSize / frameSize);
            
            double gpuMemoryMB = (double)(frameSize * totalFrames) / 1024.0 / 1024.0;
            logD(String.format("Uploading %d frames to GPU (%.2f MB GPU memory, 0 MB RAM)", 
                totalFrames, gpuMemoryMB));
            
            if (totalFrames == 0) {
                if (!stopRequested()) reportError("No frames decoded from " + source);
                return;
            }
            // Upload ALL frames to GPU textures first, then play with no per-frame upload
            if (uploadAllFramesToGPU(rawFile, ySize, uvSize, aSize, frameSize)) {
                reportLoad();
                playFromGPUCache();
            }
            
        } finally {
            // Delete temp file immediately after GPU upload
            rawFile.delete();
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
    
    private boolean initGL(SurfaceTexture surfaceTexture) {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) {
            Log.e(TAG, "Unable to get EGL display");
            return false;
        }
        
        int[] version = new int[2];
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
            Log.e(TAG, "Unable to initialize EGL");
            return false;
        }
        
        int[] configAttribs = {
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
            EGL14.EGL_NONE
        };
        
        EGLConfig[] configs = new EGLConfig[1];
        int[] numConfigs = new int[1];
        if (!EGL14.eglChooseConfig(eglDisplay, configAttribs, 0, configs, 0, 1, numConfigs, 0)) {
            Log.e(TAG, "Unable to choose EGL config");
            return false;
        }
        
        int[] contextAttribs = {
            EGL14.EGL_CONTEXT_CLIENT_VERSION, 2,
            EGL14.EGL_NONE
        };
        eglContext = EGL14.eglCreateContext(eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT, contextAttribs, 0);
        if (eglContext == EGL14.EGL_NO_CONTEXT) {
            Log.e(TAG, "Unable to create EGL context");
            return false;
        }
        
        int[] surfaceAttribs = { EGL14.EGL_NONE };
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, configs[0], surfaceTexture, surfaceAttribs, 0);
        if (eglSurface == EGL14.EGL_NO_SURFACE) {
            Log.e(TAG, "Unable to create EGL surface");
            return false;
        }
        
        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            Log.e(TAG, "Unable to make EGL context current");
            return false;
        }
        
        program = createProgram();
        if (program == 0) {
            Log.e(TAG, "Unable to create shader program");
            return false;
        }
        
        // Textures will be created per-frame in uploadAllFramesToGPU
        GLES20.glEnable(GLES20.GL_BLEND);
        GLES20.glBlendFunc(GLES20.GL_ONE, GLES20.GL_ONE_MINUS_SRC_ALPHA);
        
        logD("OpenGL ES initialized");
        return true;
    }
    
    private int createProgram() {
        int vertexShader = compileShader(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER);
        if (vertexShader == 0) return 0;
        
        int fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER);
        if (fragmentShader == 0) {
            GLES20.glDeleteShader(vertexShader);
            return 0;
        }
        
        int prog = GLES20.glCreateProgram();
        GLES20.glAttachShader(prog, vertexShader);
        GLES20.glAttachShader(prog, fragmentShader);
        GLES20.glLinkProgram(prog);
        
        int[] linkStatus = new int[1];
        GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, linkStatus, 0);
        if (linkStatus[0] != GLES20.GL_TRUE) {
            Log.e(TAG, "Program link error: " + GLES20.glGetProgramInfoLog(prog));
            GLES20.glDeleteProgram(prog);
            return 0;
        }
        
        GLES20.glDeleteShader(vertexShader);
        GLES20.glDeleteShader(fragmentShader);
        
        return prog;
    }
    
    private int compileShader(int type, String source) {
        int shader = GLES20.glCreateShader(type);
        GLES20.glShaderSource(shader, source);
        GLES20.glCompileShader(shader);
        
        int[] compileStatus = new int[1];
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, compileStatus, 0);
        if (compileStatus[0] != GLES20.GL_TRUE) {
            Log.e(TAG, "Shader compile error: " + GLES20.glGetShaderInfoLog(shader));
            GLES20.glDeleteShader(shader);
            return 0;
        }
        
        return shader;
    }
    
    /**
     * Upload ALL frames to GPU textures upfront.
     * After this, CPU frame data is discarded - playback is 100% GPU.
     */
    private boolean uploadAllFramesToGPU(File rawFile, int ySize, int uvSize, int aSize, int frameSize) {
        int uvWidth = videoWidth / 2;
        int uvHeight = videoHeight / 2;
        
        // Allocate texture IDs for all frames (4 textures per frame: Y, U, V, A)
        frameTextures = new int[totalFrames][4];
        
        byte[] frameBuffer = new byte[frameSize];
        ByteBuffer yBuffer = ByteBuffer.allocateDirect(ySize).order(ByteOrder.nativeOrder());
        ByteBuffer uBuffer = ByteBuffer.allocateDirect(uvSize).order(ByteOrder.nativeOrder());
        ByteBuffer vBuffer = ByteBuffer.allocateDirect(uvSize).order(ByteOrder.nativeOrder());
        ByteBuffer aBuffer = ByteBuffer.allocateDirect(aSize).order(ByteOrder.nativeOrder());
        
        GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1);
        
        try (RandomAccessFile raf = new RandomAccessFile(rawFile, "r")) {
            for (int frameIdx = 0; frameIdx < totalFrames; frameIdx++) {
                if (stopRequested()) {
                    return false;
                }
                
                int bytesRead = raf.read(frameBuffer);
                if (bytesRead != frameSize) {
                    Log.e(TAG, "Failed to read frame " + frameIdx);
                    return false;
                }
                
                // Generate 4 textures for this frame
                int[] texIds = new int[4];
                GLES20.glGenTextures(4, texIds, 0);
                frameTextures[frameIdx] = texIds;
                
                // Upload Y plane
                yBuffer.clear();
                yBuffer.put(frameBuffer, 0, ySize);
                yBuffer.position(0);
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texIds[0]);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
                GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE,
                    videoWidth, videoHeight, 0, GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, yBuffer);
                
                // Upload U plane
                uBuffer.clear();
                uBuffer.put(frameBuffer, ySize, uvSize);
                uBuffer.position(0);
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texIds[1]);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
                GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE,
                    uvWidth, uvHeight, 0, GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, uBuffer);
                
                // Upload V plane
                vBuffer.clear();
                vBuffer.put(frameBuffer, ySize + uvSize, uvSize);
                vBuffer.position(0);
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texIds[2]);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
                GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE,
                    uvWidth, uvHeight, 0, GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, vBuffer);
                
                // Upload A plane
                aBuffer.clear();
                aBuffer.put(frameBuffer, ySize + uvSize + uvSize, aSize);
                aBuffer.position(0);
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texIds[3]);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
                GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE,
                    videoWidth, videoHeight, 0, GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, aBuffer);
            }
            
            logD("Uploaded " + totalFrames + " frames to GPU");
            return true;
            
        } catch (Exception e) {
            Log.e(TAG, "Error uploading frames to GPU", e);
            return false;
        }
    }
    
    /**
     * Play from GPU texture cache - zero per-frame upload!
     * Just bind pre-uploaded textures and render.
     */
    private void playFromGPUCache() {
        long frameIntervalNs = (long) (1_000_000_000.0 / frameRate);
        int uvWidth = videoWidth / 2;
        int uvHeight = videoHeight / 2;
        
        do {
            long startTime = System.nanoTime();
            currentFrameIndex = 0;
            
            while (!stopRequested() && currentFrameIndex < totalFrames) {
                renderFrameFromGPU(currentFrameIndex, uvWidth, uvHeight);
                
                currentFrameIndex++;
                
                long targetTimeNs = startTime + (currentFrameIndex * frameIntervalNs);
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
    }

    /**
     * Stream mode: each frame is uploaded into the same four textures just before it's drawn.
     * onLoad comes with the first frame, and totalFrames is estimated from the duration.
     */
    private void playStream(WebMSource local, String source) {
        int uvWidth = videoWidth / 2;
        int uvHeight = videoHeight / 2;
        int ySize = videoWidth * videoHeight;
        int uvSize = uvWidth * uvHeight;
        int frameSize = ySize + uvSize + uvSize + ySize;

        int[] texIds = new int[4];
        GLES20.glGenTextures(4, texIds, 0);
        createPlaneTexture(texIds[0], videoWidth, videoHeight);
        createPlaneTexture(texIds[1], uvWidth, uvHeight);
        createPlaneTexture(texIds[2], uvWidth, uvHeight);
        createPlaneTexture(texIds[3], videoWidth, videoHeight);
        ByteBuffer planeBuffer = ByteBuffer.allocateDirect(ySize).order(ByteOrder.nativeOrder());
        GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1);

        boolean loaded = false;
        try (FrameStream frames = FrameStream.start(getContext(), local, "-f rawvideo -pix_fmt yuva420p",
                frameSize, streamBufferFrames, () -> loop, this::stopRequested)) {
            FrameClock clock = new FrameClock(frameRate);
            byte[] frame;
            while ((frame = frames.next()) != null) {
                uploadPlane(texIds[0], planeBuffer, frame, 0, videoWidth, videoHeight);
                uploadPlane(texIds[1], planeBuffer, frame, ySize, uvWidth, uvHeight);
                uploadPlane(texIds[2], planeBuffer, frame, ySize + uvSize, uvWidth, uvHeight);
                uploadPlane(texIds[3], planeBuffer, frame, ySize + uvSize + uvSize, videoWidth, videoHeight);
                frames.recycle(frame);
                if (!loaded) {
                    reportLoad();
                    loaded = true;
                }
                drawPlanes(texIds);
                if (!clock.awaitNextFrame()) return;
            }
            if (stopRequested()) return;
            if (loaded) {
                reportEnd();
            } else {
                reportError("No frames decoded from " + source);
            }
        } catch (IOException e) {
            if (!stopRequested()) reportError("Failed to decode " + source + ": " + e.getMessage());
        } finally {
            GLES20.glDeleteTextures(4, texIds, 0);
        }
    }

    private static void createPlaneTexture(int texId, int width, int height) {
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texId);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
        GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE,
            width, height, 0, GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, null);
    }

    /** Copies one plane of {@code frame}, starting at {@code offset}, into its texture. */
    private static void uploadPlane(int texId, ByteBuffer scratch, byte[] frame, int offset, int width, int height) {
        scratch.clear();
        scratch.put(frame, offset, width * height);
        scratch.position(0);
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texId);
        GLES20.glTexSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0,
            width, height, GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, scratch);
    }
    
    /**
     * Render a single frame from GPU cache - NO texture upload, just bind and draw!
     */
    private void renderFrameFromGPU(int frameIdx, int uvWidth, int uvHeight) {
        if (eglDisplay == null || eglSurface == null || frameTextures == null) return;
        if (frameIdx >= frameTextures.length) return;
        
        int[] texIds = frameTextures[frameIdx];
        
        if (!hasLoggedFirstFrame) {
            hasLoggedFirstFrame = true;
            logD("First frame rendered from the GPU texture cache");
        }
        drawPlanes(texIds);
    }

    /** Draws one frame from its Y, U, V and A textures and swaps it onto the view. */
    private void drawPlanes(int[] texIds) {
        GLES20.glClearColor(0, 0, 0, 0);
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
        GLES20.glViewport(0, 0, getWidth(), getHeight());
        GLES20.glUseProgram(program);
        
        // Bind pre-uploaded textures - NO glTexImage2D call!
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texIds[0]);
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "yTexture"), 0);
        
        GLES20.glActiveTexture(GLES20.GL_TEXTURE1);
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texIds[1]);
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uTexture"), 1);
        
        GLES20.glActiveTexture(GLES20.GL_TEXTURE2);
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texIds[2]);
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "vTexture"), 2);
        
        GLES20.glActiveTexture(GLES20.GL_TEXTURE3);
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texIds[3]);
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "aTexture"), 3);
        
        int positionHandle = GLES20.glGetAttribLocation(program, "aPosition");
        GLES20.glEnableVertexAttribArray(positionHandle);
        GLES20.glVertexAttribPointer(positionHandle, 2, GLES20.GL_FLOAT, false, 0, vertexBuffer);
        
        int texCoordHandle = GLES20.glGetAttribLocation(program, "aTexCoord");
        GLES20.glEnableVertexAttribArray(texCoordHandle);
        GLES20.glVertexAttribPointer(texCoordHandle, 2, GLES20.GL_FLOAT, false, 0, texCoordBuffer);
        
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);
        
        GLES20.glDisableVertexAttribArray(positionHandle);
        GLES20.glDisableVertexAttribArray(texCoordHandle);
        
        EGL14.eglSwapBuffers(eglDisplay, eglSurface);
    }
    
    private void cleanupGL() {
        if (eglDisplay != null && eglDisplay != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT);
            
            // Delete all frame textures from GPU cache
            if (frameTextures != null) {
                for (int[] texIds : frameTextures) {
                    if (texIds != null && texIds[0] != 0) {
                        GLES20.glDeleteTextures(4, texIds, 0);
                    }
                }
                frameTextures = null;
            }
            
            if (program != 0) {
                GLES20.glDeleteProgram(program);
                program = 0;
            }
            
            if (eglSurface != null && eglSurface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglDestroySurface(eglDisplay, eglSurface);
                eglSurface = null;
            }
            
            if (eglContext != null && eglContext != EGL14.EGL_NO_CONTEXT) {
                EGL14.eglDestroyContext(eglDisplay, eglContext);
                eglContext = null;
            }
            
            EGL14.eglTerminate(eglDisplay);
            eglDisplay = null;
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
    }
    
    @Override
    protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        isDestroyed.set(false);
    }
}
