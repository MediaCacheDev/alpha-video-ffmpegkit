import React, { useMemo } from 'react';
import { Platform, View, StyleSheet } from 'react-native';

// Platform-specific imports
let NativeWebMAlphaCPUView;
let NativeWebMAlphaGPUView;
let WebMAlphaViewWeb;

if (Platform.OS === 'web') {
  // Web implementation using HTML5 video element
  WebMAlphaViewWeb = require('./WebMAlphaView.web').default;
} else {
  NativeWebMAlphaCPUView = require('./WebMAlphaCPUViewNativeComponent').default;
  NativeWebMAlphaGPUView = require('./WebMAlphaGPUViewNativeComponent').default;
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
 * Builds a player component. `pickNative(useGPU)` returns the native view to render.
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
  const Player = React.memo(({
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
  }) => {
    const uri = sourceUri(source);
    const key = cacheKey ?? (typeof source === 'object' ? source?.cacheKey : undefined) ?? undefined;
    const nativeSource = useMemo(
      () => (uri ? (key ? { uri, cacheKey: key } : { uri }) : null),
      [uri, key],
    );

    if (Platform.OS === 'web') {
      return (
        <WebMAlphaViewWeb
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

    const NativeComponent = pickNative(useGPU);
    return (
      <NativeComponent
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
  });
  Player.displayName = displayName;
  return Player;
}

/**
 * VP9+Alpha WebM player. `useGPU` (default true) picks OpenGL ES / Metal rendering over
 * Bitmap / UIImage rendering. On web this is an HTML5 <video>.
 */
export const WebMAlphaView = createPlayer('WebMAlphaView', (useGPU) =>
  useGPU ? NativeWebMAlphaGPUView : NativeWebMAlphaCPUView,
);

/** CPU rendering (Bitmap on Android, UIImage on iOS). */
export const WebMAlphaCPUView = createPlayer('WebMAlphaCPUView', () => NativeWebMAlphaCPUView);

/** GPU rendering (OpenGL ES on Android, Metal on iOS). */
export const WebMAlphaGPUView = createPlayer('WebMAlphaGPUView', () => NativeWebMAlphaGPUView);

// Backward compatibility alias
export const WebMAlphaMetalView = WebMAlphaGPUView;

const styles = StyleSheet.create({
  container: {
    // Note: backgroundColor not supported on TextureView/GLSurfaceView
  },
});

// Default export is the main component with GPU/CPU selection
export default WebMAlphaView;
