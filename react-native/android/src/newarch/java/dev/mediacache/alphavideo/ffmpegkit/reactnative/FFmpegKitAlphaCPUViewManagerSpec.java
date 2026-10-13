package dev.mediacache.alphavideo.ffmpegkit.reactnative;

import android.view.View;

import androidx.annotation.Nullable;

import com.facebook.react.uimanager.SimpleViewManager;
import com.facebook.react.uimanager.ViewManagerDelegate;
import com.facebook.react.viewmanagers.RNFFmpegKitAlphaCPUViewManagerDelegate;
import com.facebook.react.viewmanagers.RNFFmpegKitAlphaCPUViewManagerInterface;

/** New architecture: props and commands arrive through the delegate generated from the codegen spec. */
public abstract class FFmpegKitAlphaCPUViewManagerSpec<T extends View> extends SimpleViewManager<T>
        implements RNFFmpegKitAlphaCPUViewManagerInterface<T> {

    private final ViewManagerDelegate<T> delegate = new RNFFmpegKitAlphaCPUViewManagerDelegate<>(this);

    @Nullable
    @Override
    protected ViewManagerDelegate<T> getDelegate() {
        return delegate;
    }
}
