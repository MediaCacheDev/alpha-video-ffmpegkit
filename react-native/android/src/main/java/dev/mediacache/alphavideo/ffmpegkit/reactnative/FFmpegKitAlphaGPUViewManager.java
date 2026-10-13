package dev.mediacache.alphavideo.ffmpegkit.reactnative;

import android.graphics.Color;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.uimanager.ThemedReactContext;
import com.facebook.react.uimanager.ViewProps;
import com.facebook.react.uimanager.annotations.ReactProp;

import dev.mediacache.alphavideo.ffmpegkit.FFmpegKitAlphaGPUView;
import dev.mediacache.alphavideo.ffmpegkit.StreamMode;

import java.util.Map;

/**
 * React Native view manager for {@link FFmpegKitAlphaGPUView} (OpenGL ES rendering).
 *
 * Props are passed straight to the view, which resolves the source itself.
 * Events: onLoad, onError, onEnd.
 */
public class FFmpegKitAlphaGPUViewManager extends FFmpegKitAlphaGPUViewManagerSpec<FFmpegKitAlphaGPUView> {
    public static final String REACT_CLASS = "RNFFmpegKitAlphaGPUView";
    
    public FFmpegKitAlphaGPUViewManager(ReactApplicationContext reactContext) {
    }
    
    @NonNull
    @Override
    public String getName() {
        return REACT_CLASS;
    }
    
    @NonNull
    @Override
    protected FFmpegKitAlphaGPUView createViewInstance(@NonNull ThemedReactContext context) {
        FFmpegKitAlphaGPUView view = new FFmpegKitAlphaGPUView(context);
        view.setCallback(new PlayerEventForwarder(view));
        return view;
    }
    
    /** {@code { uri, cacheKey? }}; a cacheKey here is the same as the cacheKey prop. */
    @ReactProp(name = "source")
    @Override
    public void setSource(FFmpegKitAlphaGPUView view, @Nullable ReadableMap source) {
        String uri = source != null && source.hasKey("uri") && !source.isNull("uri") ? source.getString("uri") : null;
        if (source != null && source.hasKey("cacheKey") && !source.isNull("cacheKey")) {
            view.setCacheKey(source.getString("cacheKey"));
        }
        view.setSource(uri == null || uri.isEmpty() ? null : uri);
    }
    
    @ReactProp(name = "cacheKey")
    @Override
    public void setCacheKey(FFmpegKitAlphaGPUView view, @Nullable String cacheKey) {
        view.setCacheKey(cacheKey);
    }
    
    @ReactProp(name = "autoPlay", defaultBoolean = true)
    @Override
    public void setAutoPlay(FFmpegKitAlphaGPUView view, boolean autoPlay) {
        view.setAutoPlay(autoPlay);
    }
    
    @ReactProp(name = "loop", defaultBoolean = true)
    @Override
    public void setLoop(FFmpegKitAlphaGPUView view, boolean loop) {
        view.setLoop(loop);
    }
    
    @ReactProp(name = "paused", defaultBoolean = false)
    @Override
    public void setPaused(FFmpegKitAlphaGPUView view, boolean paused) {
        view.setPaused(paused);
    }
    
    @ReactProp(name = "verbose", defaultBoolean = false)
    @Override
    public void setVerbose(FFmpegKitAlphaGPUView view, boolean verbose) {
        view.setVerbose(verbose);
    }

    @ReactProp(name = "mode")
    @Override
    public void setMode(FFmpegKitAlphaGPUView view, @Nullable String mode) {
        view.setMode(mode);
    }

    @ReactProp(name = "streamBufferFrames", defaultInt = StreamMode.DEFAULT_BUFFER_FRAMES)
    @Override
    public void setStreamBufferFrames(FFmpegKitAlphaGPUView view, int frames) {
        view.setStreamBufferFrames(frames);
    }
    
    /** TextureView can't have a background drawable; setting one throws. */
    @Override
    @ReactProp(name = ViewProps.BACKGROUND_COLOR, defaultInt = Color.TRANSPARENT, customType = "Color")
    public void setBackgroundColor(@NonNull FFmpegKitAlphaGPUView view, int color) {
    }
    
    @Override
    public void seekToFrame(FFmpegKitAlphaGPUView view, int frame) {
        view.seekToFrame(frame);
    }

    @Override
    public void seekToTime(FFmpegKitAlphaGPUView view, double seconds) {
        view.seekToTime(seconds);
    }

    @Nullable
    @Override
    public Map<String, Object> getExportedCustomDirectEventTypeConstants() {
        return PlayerEventForwarder.exportedEvents();
    }
}
