package dev.mediacache.alphavideo.ffmpegkit.reactnative;

import android.view.View;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.facebook.react.bridge.ReadableArray;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.uimanager.SimpleViewManager;

/**
 * Old architecture: the same methods as the interface codegen generates for the new one, so the
 * manager compiles against either. Props arrive through its {@code @ReactProp} setters.
 */
public abstract class FFmpegKitAlphaCPUViewManagerSpec<T extends View> extends SimpleViewManager<T> {

    public abstract void setSource(T view, @Nullable ReadableMap value);
    public abstract void setAutoPlay(T view, boolean value);
    public abstract void setLoop(T view, boolean value);
    public abstract void setPaused(T view, boolean value);
    public abstract void setCacheKey(T view, @Nullable String value);
    public abstract void setVerbose(T view, boolean value);
    public abstract void setMode(T view, @Nullable String value);
    public abstract void setStreamBufferFrames(T view, int value);

    public abstract void seekToFrame(T view, int frame);
    public abstract void seekToTime(T view, double seconds);

    @Override
    public void receiveCommand(@NonNull T view, String commandName, @Nullable ReadableArray args) {
        if (args == null || args.size() == 0) return;
        switch (commandName) {
            case "seekToFrame":
                seekToFrame(view, args.getInt(0));
                break;
            case "seekToTime":
                seekToTime(view, args.getDouble(0));
                break;
        }
    }
}
