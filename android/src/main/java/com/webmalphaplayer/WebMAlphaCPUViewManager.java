package com.webmalphaplayer;

import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.uimanager.SimpleViewManager;
import com.facebook.react.uimanager.ThemedReactContext;
import com.facebook.react.uimanager.annotations.ReactProp;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * View Manager for the CPU-based WebM Alpha Player
 * 
 * Supports multiple source formats:
 * - HTTP/HTTPS URLs: Downloaded and cached
 * - file:// URIs: Local file paths
 * - asset:// URIs: Android assets
 * - Plain paths: Direct file paths
 */
public class WebMAlphaCPUViewManager extends SimpleViewManager<WebMAlphaCPUView> {
    private static final String TAG = "WebMAlphaCPUViewMgr";
    public static final String REACT_CLASS = "WebMAlphaCPUView";
    
    private final ReactApplicationContext reactContext;
    private final ExecutorService assetExecutor = Executors.newFixedThreadPool(2);
    
    public WebMAlphaCPUViewManager(ReactApplicationContext reactContext) {
        this.reactContext = reactContext;
    }
    
    @NonNull
    @Override
    public String getName() {
        return REACT_CLASS;
    }
    
    @NonNull
    @Override
    protected WebMAlphaCPUView createViewInstance(@NonNull ThemedReactContext context) {
        return new WebMAlphaCPUView(context);
    }
    
    /**
     * Accept source as { uri: string } or { path: string }
     * Handles multiple URI schemes: http(s)://, file://, asset://, or plain paths
     */
    @ReactProp(name = "source")
    public void setSource(WebMAlphaCPUView view, @Nullable ReadableMap source) {
        String sourceUri = null;
        if (source != null) {
            if (source.hasKey("uri") && !source.isNull("uri")) {
                sourceUri = source.getString("uri");
            } else if (source.hasKey("path") && !source.isNull("path")) {
                sourceUri = source.getString("path");
            }
        }
        
        if (sourceUri == null || sourceUri.isEmpty()) {
            Log.d(TAG, "setSource: null or empty");
            view.setSource(null);
            return;
        }
        
        Log.d(TAG, "setSource: " + sourceUri.substring(0, Math.min(80, sourceUri.length())) + "...");
        
        // Handle different URI schemes like the C++ version
        if (sourceUri.startsWith("http://") || sourceUri.startsWith("https://")) {
            // HTTP URLs are handled by the View's internal download logic
            view.setSource(sourceUri);
        } else if (sourceUri.startsWith("file://")) {
            // Strip file:// prefix for local files
            String path = sourceUri.substring(7);
            view.setSource(path);
        } else if (sourceUri.startsWith("asset://") || sourceUri.startsWith("asset:/")) {
            // Load from Android assets
            loadFromAsset(view, sourceUri);
        } else {
            // Plain path - pass directly
            view.setSource(sourceUri);
        }
    }
    
    /**
     * Load WebM from Android assets by copying to cache first
     */
    private void loadFromAsset(WebMAlphaCPUView view, String assetUri) {
        final String assetPath = assetUri.replace("asset://", "").replace("asset:/", "")
            .replaceFirst("^/", "");
        
        assetExecutor.execute(() -> {
            try {
                File tempFile = new File(reactContext.getCacheDir(), 
                    "webm_asset_" + assetPath.hashCode() + ".webm");
                
                if (!tempFile.exists()) {
                    InputStream is = reactContext.getAssets().open(assetPath);
                    FileOutputStream fos = new FileOutputStream(tempFile);
                    byte[] buffer = new byte[8192];
                    int read;
                    while ((read = is.read(buffer)) != -1) {
                        fos.write(buffer, 0, read);
                    }
                    fos.close();
                    is.close();
                    Log.d(TAG, "Copied asset to cache: " + tempFile.getAbsolutePath());
                }
                
                view.post(() -> view.setSource(tempFile.getAbsolutePath()));
            } catch (Exception e) {
                Log.e(TAG, "Failed to load asset: " + assetPath, e);
            }
        });
    }
    
    @ReactProp(name = "cacheKey")
    public void setCacheKey(WebMAlphaCPUView view, @Nullable String cacheKey) {
        // Pass cacheKey directly to the View so it can use it for downloads
        view.setCacheKey(cacheKey);
    }
    
    @ReactProp(name = "autoPlay", defaultBoolean = true)
    public void setAutoPlay(WebMAlphaCPUView view, boolean autoPlay) {
        view.setAutoPlay(autoPlay);
    }
    
    @ReactProp(name = "loop", defaultBoolean = true)
    public void setLoop(WebMAlphaCPUView view, boolean loop) {
        view.setLoop(loop);
    }
    
    @ReactProp(name = "paused", defaultBoolean = false)
    public void setPaused(WebMAlphaCPUView view, boolean paused) {
        view.setPaused(paused);
    }
    
    /**
     * Override backgroundColor to ignore it - TextureView doesn't support background drawables.
     * This prevents the "TextureView doesn't support displaying a background drawable" crash.
     */
    @ReactProp(name = "backgroundColor", customType = "Color")
    public void setBackgroundColor(WebMAlphaCPUView view, @Nullable Integer color) {
        // Intentionally ignored - TextureView cannot have a background
        Log.d(TAG, "setBackgroundColor ignored - TextureView doesn't support backgrounds");
    }
    
    @Override
    public void onDropViewInstance(@NonNull WebMAlphaCPUView view) {
        Log.d(TAG, "onDropViewInstance");
        super.onDropViewInstance(view);
    }
}
