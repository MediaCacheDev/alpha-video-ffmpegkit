package dev.mediacache.alphavideo.ffmpegkit.reactnative;

import android.view.View;

import androidx.annotation.Nullable;

import com.facebook.react.uimanager.SimpleViewManager;
import com.facebook.react.uimanager.ViewManagerDelegate;
import com.facebook.react.viewmanagers.RNFFmpegKitAlphaGPUViewManagerDelegate;
import com.facebook.react.viewmanagers.RNFFmpegKitAlphaGPUViewManagerInterface;

/** New architecture: props and commands arrive through the delegate generated from the codegen spec. */
public abstract class FFmpegKitAlphaGPUViewManagerSpec<T extends View> extends SimpleViewManager<T>
        implements RNFFmpegKitAlphaGPUViewManagerInterface<T> {

    private final ViewManagerDelegate<T> delegate = new RNFFmpegKitAlphaGPUViewManagerDelegate<>(this);

    @Nullable
    @Override
    protected ViewManagerDelegate<T> getDelegate() {
        return delegate;
    }
}
