package com.webmalphaplayer;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.uimanager.SimpleViewManager;
import com.facebook.react.uimanager.ThemedReactContext;
import com.facebook.react.uimanager.annotations.ReactProp;

import java.util.Map;

/**
 * View Manager for the GPU-accelerated WebM Alpha Player (OpenGL ES).
 *
 * Props are passed straight to the view, which resolves the source itself (see {@link WebMSource}).
 * Events: onLoad, onError, onEnd.
 */
public class WebMAlphaGPUViewManager extends SimpleViewManager<WebMAlphaGPUView> {
    public static final String REACT_CLASS = "WebMAlphaGPUView";
    
    public WebMAlphaGPUViewManager(ReactApplicationContext reactContext) {
    }
    
    @NonNull
    @Override
    public String getName() {
        return REACT_CLASS;
    }
    
    @NonNull
    @Override
    protected WebMAlphaGPUView createViewInstance(@NonNull ThemedReactContext context) {
        WebMAlphaGPUView view = new WebMAlphaGPUView(context);
        view.setCallback(new PlayerEventForwarder(view));
        return view;
    }
    
    /** {@code { uri, cacheKey? }}; a cacheKey here is the same as the cacheKey prop. */
    @ReactProp(name = "source")
    public void setSource(WebMAlphaGPUView view, @Nullable ReadableMap source) {
        String uri = source != null && source.hasKey("uri") && !source.isNull("uri") ? source.getString("uri") : null;
        if (source != null && source.hasKey("cacheKey") && !source.isNull("cacheKey")) {
            view.setCacheKey(source.getString("cacheKey"));
        }
        view.setSource(uri == null || uri.isEmpty() ? null : uri);
    }
    
    @ReactProp(name = "cacheKey")
    public void setCacheKey(WebMAlphaGPUView view, @Nullable String cacheKey) {
        view.setCacheKey(cacheKey);
    }
    
    @ReactProp(name = "autoPlay", defaultBoolean = true)
    public void setAutoPlay(WebMAlphaGPUView view, boolean autoPlay) {
        view.setAutoPlay(autoPlay);
    }
    
    @ReactProp(name = "loop", defaultBoolean = true)
    public void setLoop(WebMAlphaGPUView view, boolean loop) {
        view.setLoop(loop);
    }
    
    @ReactProp(name = "paused", defaultBoolean = false)
    public void setPaused(WebMAlphaGPUView view, boolean paused) {
        view.setPaused(paused);
    }
    
    @ReactProp(name = "verbose", defaultBoolean = false)
    public void setVerbose(WebMAlphaGPUView view, boolean verbose) {
        view.setVerbose(verbose);
    }

    @ReactProp(name = "mode")
    public void setMode(WebMAlphaGPUView view, @Nullable String mode) {
        view.setMode(mode);
    }

    @ReactProp(name = "streamBufferFrames", defaultInt = StreamMode.DEFAULT_BUFFER_FRAMES)
    public void setStreamBufferFrames(WebMAlphaGPUView view, int frames) {
        view.setStreamBufferFrames(frames);
    }
    
    /** TextureView can't have a background drawable; setting one throws. */
    @ReactProp(name = "backgroundColor", customType = "Color")
    public void setBackgroundColor(WebMAlphaGPUView view, @Nullable Integer color) {
    }
    
    @Nullable
    @Override
    public Map<String, Object> getExportedCustomDirectEventTypeConstants() {
        return PlayerEventForwarder.exportedEvents();
    }
}
