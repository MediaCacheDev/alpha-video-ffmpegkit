import React, { forwardRef, useImperativeHandle, useMemo, useRef } from 'react';
import { Platform, View, StyleSheet, UIManager, findNodeHandle } from 'react-native';

const CPU_VIEW = 'RNFFmpegKitAlphaCPUView';
const GPU_VIEW = 'RNFFmpegKitAlphaGPUView';

// Platform-specific imports
const nativeViews = {};
let WebView;

if (Platform.OS === 'web') {
  // Web implementation using HTML5 video element
  WebView = require('./FFmpegKitAlphaView.web').default;
} else {
  nativeViews[CPU_VIEW] = require('./FFmpegKitAlphaCPUViewNativeComponent').default;
  nativeViews[GPU_VIEW] = require('./FFmpegKitAlphaGPUViewNativeComponent').default;
}

function sourceUri(source) {
  if (!source) return null;
  if (typeof source === 'string') return source;
  return source.uri || source.path || null;
}

function unwrap(handler) {
  return handler ? (event) => handler(event.nativeEvent) : undefined;
}

/**
 * Builds a player component. `pickNative(useGPU)` names the native view to render.
 *
 * Ref: seekToFrame(frame) and seekToTime(seconds) show that frame (clamped to the clip) and
 * keep playing or stay paused. Ignored until onLoad.
 *
 * Props:
 * - source: `{ uri, cacheKey? }` or a URI string. URIs: https://, http://, file://, an absolute
 *   path, asset://relative/path, and on Android content:// or a res/raw resource name.
 * - cacheKey: file name for the downloaded copy, relative to the cache directory. Overrides
 *   source.cacheKey. Ignored on web.
 * - autoPlay (true), loop (true), paused (false), verbose (false: only errors are logged)
 * - mode: 'stream' (default: decode while playing, holding streamBufferFrames (15) frames ahead)
 *   or 'preload' (decode every frame, then play). Ignored on web.
 * - onLoad({ totalFrames, width, height }), onError({ error }), onEnd({})
 */
function createPlayer(displayName, pickNative) {
  const Player = React.memo(forwardRef(({
    source,
    autoPlay = true,
    loop = true,
    paused = false,
    useGPU = true,
    cacheKey,
    verbose = false,
    mode = 'stream',
    streamBufferFrames = 15,
    style,
    onLoad,
    onError,
    onEnd,
    ...otherProps
  }, ref) => {
    const uri = sourceUri(source);
    const key = cacheKey ?? (typeof source === 'object' ? source?.cacheKey : undefined) ?? undefined;
    const nativeSource = useMemo(
      () => (uri ? (key ? { uri, cacheKey: key } : { uri }) : null),
      [uri, key],
    );
    const viewName = pickNative(useGPU);
    const nativeRef = useRef(null);

    useImperativeHandle(ref, () => {
      if (Platform.OS === 'web') {
        return {
          seekToFrame: (frame) => nativeRef.current?.seekToFrame(frame),
          seekToTime: (seconds) => nativeRef.current?.seekToTime(seconds),
        };
      }
      const sendCommand = (name, args) => {
        const handle = nativeRef.current ? findNodeHandle(nativeRef.current) : null;
        if (!handle) return;
        UIManager.dispatchViewManagerCommand(
          handle,
          UIManager.getViewManagerConfig(viewName)?.Commands?.[name] ?? name,
          args,
        );
      };
      return {
        seekToFrame: (frame) => sendCommand('seekToFrame', [frame]),
        seekToTime: (seconds) => sendCommand('seekToTime', [seconds]),
      };
    }, [viewName]);

    if (Platform.OS === 'web') {
      return (
        <WebView
          ref={nativeRef}
          source={uri}
          autoPlay={autoPlay}
          loop={loop}
          paused={paused}
          style={style}
          onLoad={onLoad}
          onError={onError}
          onEnd={onEnd}
          {...otherProps}
        />
      );
    }

    if (!nativeSource) {
      return <View style={style} />;
    }

    const NativeComponent = nativeViews[viewName];
    return (
      <NativeComponent
        ref={nativeRef}
        source={nativeSource}
        cacheKey={key}
        autoPlay={autoPlay}
        loop={loop}
        paused={paused}
        verbose={verbose}
        mode={mode}
        streamBufferFrames={streamBufferFrames}
        onLoad={unwrap(onLoad)}
        onError={unwrap(onError)}
        onEnd={unwrap(onEnd)}
        style={[styles.container, style]}
        {...otherProps}
      />
    );
  }));
  Player.displayName = displayName;
  return Player;
}

/**
 * VP9+Alpha WebM player. `useGPU` (default true) picks OpenGL ES / Metal rendering over
 * Bitmap / UIImage rendering. On web this is an HTML5 <video>.
 */
export const FFmpegKitAlphaView = createPlayer('FFmpegKitAlphaView', (useGPU) =>
  useGPU ? GPU_VIEW : CPU_VIEW,
);

/** CPU rendering (Bitmap on Android, UIImage on iOS). */
export const FFmpegKitAlphaCPUView = createPlayer('FFmpegKitAlphaCPUView', () => CPU_VIEW);

/** GPU rendering (OpenGL ES on Android, Metal on iOS). */
export const FFmpegKitAlphaGPUView = createPlayer('FFmpegKitAlphaGPUView', () => GPU_VIEW);

const styles = StyleSheet.create({
  container: {
    // Note: backgroundColor not supported on TextureView/GLSurfaceView
  },
});
