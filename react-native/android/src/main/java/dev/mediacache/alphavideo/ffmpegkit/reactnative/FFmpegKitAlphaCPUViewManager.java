package dev.mediacache.alphavideo.ffmpegkit.reactnative;

import android.graphics.Color;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.uimanager.ThemedReactContext;
import com.facebook.react.uimanager.ViewProps;
import com.facebook.react.uimanager.annotations.ReactProp;

import dev.mediacache.alphavideo.ffmpegkit.FFmpegKitAlphaCPUView;
import dev.mediacache.alphavideo.ffmpegkit.StreamMode;

import java.util.Map;

/**
 * React Native view manager for {@link FFmpegKitAlphaCPUView} (Bitmap rendering).
 *
 * Props are passed straight to the view, which resolves the source itself.
 * Events: onLoad, onError, onEnd.
 */
public class FFmpegKitAlphaCPUViewManager extends FFmpegKitAlphaCPUViewManagerSpec<FFmpegKitAlphaCPUView> {
    public static final String REACT_CLASS = "RNFFmpegKitAlphaCPUView";
    
    public FFmpegKitAlphaCPUViewManager(ReactApplicationContext reactContext) {
    }
    
    @NonNull
    @Override
    public String getName() {
        return REACT_CLASS;
    }
    
    @NonNull
    @Override
    protected FFmpegKitAlphaCPUView createViewInstance(@NonNull ThemedReactContext context) {
        FFmpegKitAlphaCPUView view = new FFmpegKitAlphaCPUView(context);
        view.setCallback(new PlayerEventForwarder(view));
        return view;
    }
    
    /** {@code { uri, cacheKey? }}; a cacheKey here is the same as the cacheKey prop. */
    @ReactProp(name = "source")
    @Override
    public void setSource(FFmpegKitAlphaCPUView view, @Nullable ReadableMap source) {
        String uri = source != null && source.hasKey("uri") && !source.isNull("uri") ? source.getString("uri") : null;
        if (source != null && source.hasKey("cacheKey") && !source.isNull("cacheKey")) {
            view.setCacheKey(source.getString("cacheKey"));
        }
        view.setSource(uri == null || uri.isEmpty() ? null : uri);
    }
    
    @ReactProp(name = "cacheKey")
    @Override
    public void setCacheKey(FFmpegKitAlphaCPUView view, @Nullable String cacheKey) {
        view.setCacheKey(cacheKey);
    }
    
    @ReactProp(name = "autoPlay", defaultBoolean = true)
    @Override
    public void setAutoPlay(FFmpegKitAlphaCPUView view, boolean autoPlay) {
        view.setAutoPlay(autoPlay);
    }
    
    @ReactProp(name = "loop", defaultBoolean = true)
    @Override
    public void setLoop(FFmpegKitAlphaCPUView view, boolean loop) {
        view.setLoop(loop);
    }
    
    @ReactProp(name = "paused", defaultBoolean = false)
    @Override
    public void setPaused(FFmpegKitAlphaCPUView view, boolean paused) {
        view.setPaused(paused);
    }
    
    @ReactProp(name = "verbose", defaultBoolean = false)
    @Override
    public void setVerbose(FFmpegKitAlphaCPUView view, boolean verbose) {
        view.setVerbose(verbose);
    }

    @ReactProp(name = "mode")
    @Override
    public void setMode(FFmpegKitAlphaCPUView view, @Nullable String mode) {
        view.setMode(mode);
    }

    @ReactProp(name = "streamBufferFrames", defaultInt = StreamMode.DEFAULT_BUFFER_FRAMES)
    @Override
    public void setStreamBufferFrames(FFmpegKitAlphaCPUView view, int frames) {
        view.setStreamBufferFrames(frames);
    }
    
    /** TextureView can't have a background drawable; setting one throws. */
    @Override
    @ReactProp(name = ViewProps.BACKGROUND_COLOR, defaultInt = Color.TRANSPARENT, customType = "Color")
    public void setBackgroundColor(@NonNull FFmpegKitAlphaCPUView view, int color) {
    }
    
    @Override
    public void seekToFrame(FFmpegKitAlphaCPUView view, int frame) {
        view.seekToFrame(frame);
    }

    @Override
    public void seekToTime(FFmpegKitAlphaCPUView view, double seconds) {
        view.seekToTime(seconds);
    }

    @Nullable
    @Override
    public Map<String, Object> getExportedCustomDirectEventTypeConstants() {
        return PlayerEventForwarder.exportedEvents();
    }
}
