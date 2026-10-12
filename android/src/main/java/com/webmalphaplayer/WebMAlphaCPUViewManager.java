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
 * View Manager for the CPU-based WebM Alpha Player.
 *
 * Props are passed straight to the view, which resolves the source itself (see {@link WebMSource}).
 * Events: onLoad, onError, onEnd.
 */
public class WebMAlphaCPUViewManager extends SimpleViewManager<WebMAlphaCPUView> {
    public static final String REACT_CLASS = "WebMAlphaCPUView";
    
    public WebMAlphaCPUViewManager(ReactApplicationContext reactContext) {
    }
    
    @NonNull
    @Override
    public String getName() {
        return REACT_CLASS;
    }
    
    @NonNull
    @Override
    protected WebMAlphaCPUView createViewInstance(@NonNull ThemedReactContext context) {
        WebMAlphaCPUView view = new WebMAlphaCPUView(context);
        view.setCallback(new PlayerEventForwarder(view));
        return view;
    }
    
    /** {@code { uri, cacheKey? }}; a cacheKey here is the same as the cacheKey prop. */
    @ReactProp(name = "source")
    public void setSource(WebMAlphaCPUView view, @Nullable ReadableMap source) {
        String uri = source != null && source.hasKey("uri") && !source.isNull("uri") ? source.getString("uri") : null;
        if (source != null && source.hasKey("cacheKey") && !source.isNull("cacheKey")) {
            view.setCacheKey(source.getString("cacheKey"));
        }
        view.setSource(uri == null || uri.isEmpty() ? null : uri);
    }
    
    @ReactProp(name = "cacheKey")
    public void setCacheKey(WebMAlphaCPUView view, @Nullable String cacheKey) {
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
    
    @ReactProp(name = "verbose", defaultBoolean = false)
    public void setVerbose(WebMAlphaCPUView view, boolean verbose) {
        view.setVerbose(verbose);
    }

    @ReactProp(name = "mode")
    public void setMode(WebMAlphaCPUView view, @Nullable String mode) {
        view.setMode(mode);
    }

    @ReactProp(name = "streamBufferFrames", defaultInt = StreamMode.DEFAULT_BUFFER_FRAMES)
    public void setStreamBufferFrames(WebMAlphaCPUView view, int frames) {
        view.setStreamBufferFrames(frames);
    }
    
    /** TextureView can't have a background drawable; setting one throws. */
    @ReactProp(name = "backgroundColor", customType = "Color")
    public void setBackgroundColor(WebMAlphaCPUView view, @Nullable Integer color) {
    }
    
    @Nullable
    @Override
    public Map<String, Object> getExportedCustomDirectEventTypeConstants() {
        return PlayerEventForwarder.exportedEvents();
    }
}
