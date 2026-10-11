import React, { useMemo } from 'react';
import { Platform, View, StyleSheet } from 'react-native';

// Platform-specific imports
let NativeWebMAlphaCPUView;
let NativeWebMAlphaGPUView;
let WebMAlphaViewWeb;

if (Platform.OS === 'web') {
  // Web implementation using HTML5 video element
  const webModule = require('./WebMAlphaView.web');
  WebMAlphaViewWeb = webModule.default;
} else {
  // Native implementation using codegenNativeComponent
  // This supports both New Architecture (Fabric) and Legacy Architecture (auto-fallback)
  NativeWebMAlphaCPUView = require('./WebMAlphaCPUViewNativeComponent').default;
  NativeWebMAlphaGPUView = require('./WebMAlphaGPUViewNativeComponent').default;
}

/**
 * WebMAlphaView - React Native component for playing VP9+Alpha WebM files
 * 
 * Features:
 * - Supports WebM files with VP9 video codec and alpha channel
 * - Two rendering modes: CPU (simpler) and GPU (faster)
 * - GPU mode uses OpenGL ES on Android and Metal on iOS
 * - On web, uses native HTML5 video element (VP9+Alpha supported in Chrome/Firefox/Edge)
 * - Automatic URL downloading and caching
 * - Looping and pause controls
 * - Frame caching with cacheKey for repeated animations
 * 
 * @param {Object} props - Component props
 * @param {string} props.source - URL or local file path to the WebM file
 * @param {boolean} [props.autoPlay=true] - Start playing automatically
 * @param {boolean} [props.loop=true] - Loop the animation
 * @param {boolean} [props.paused=false] - Pause the animation
 * @param {boolean} [props.useGPU=true] - Use GPU acceleration (OpenGL ES/Metal) - ignored on web
 * @param {string} [props.cacheKey] - Cache key for downloaded files - ignored on web (browser handles caching)
 * @param {Object} [props.style] - View style
 */
export const WebMAlphaView = React.memo(({
  source,
  autoPlay = true,
  loop = true,
  paused = false,
  useGPU = true,
  cacheKey,
  style,
  onLoad,
  onError,
  onEnd,
  ...otherProps
}) => {
  // Web implementation
  if (Platform.OS === 'web') {
    return (
      <WebMAlphaViewWeb
        source={source}
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

  // Native implementation - choose the appropriate native component
  const NativeComponent = useGPU ? NativeWebMAlphaGPUView : NativeWebMAlphaCPUView;

  // Memoize props to prevent unnecessary re-renders
  const nativeProps = useMemo(() => ({
    source,
    autoPlay,
    loop,
    paused,
    cacheKey,
  }), [source, autoPlay, loop, paused, cacheKey]);

  if (!source) {
    return <View style={style} />;
  }

  return (
    <NativeComponent
      {...nativeProps}
      style={[styles.container, style]}
      {...otherProps}
    />
  );
});

WebMAlphaView.displayName = 'WebMAlphaView';

/**
 * CPU-only WebM Alpha View
 * Use this if you're experiencing GPU issues or want simpler rendering
 * On web, uses HTML5 video element (same as GPU view)
 */
export const WebMAlphaCPUView = React.memo(({
  source,
  autoPlay = true,
  loop = true,
  paused = false,
  cacheKey,
  style,
  onLoad,
  onError,
  onEnd,
  ...otherProps
}) => {
  // Web implementation
  if (Platform.OS === 'web') {
    return (
      <WebMAlphaViewWeb
        source={source}
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

  const nativeProps = useMemo(() => ({
    source,
    autoPlay,
    loop,
    paused,
    cacheKey,
  }), [source, autoPlay, loop, paused, cacheKey]);

  if (!source) {
    return <View style={style} />;
  }

  return (
    <NativeWebMAlphaCPUView
      {...nativeProps}
      style={[styles.container, style]}
      {...otherProps}
    />
  );
});

WebMAlphaCPUView.displayName = 'WebMAlphaCPUView';

/**
 * GPU-accelerated WebM Alpha View
 * Uses OpenGL ES on Android and Metal on iOS for better performance
 * On web, uses HTML5 video element (same as CPU view)
 */
export const WebMAlphaGPUView = React.memo(({
  source,
  autoPlay = true,
  loop = true,
  paused = false,
  cacheKey,
  style,
  onLoad,
  onError,
  onEnd,
  ...otherProps
}) => {
  // Web implementation
  if (Platform.OS === 'web') {
    return (
      <WebMAlphaViewWeb
        source={source}
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

  const nativeProps = useMemo(() => ({
    source,
    autoPlay,
    loop,
    paused,
    cacheKey,
  }), [source, autoPlay, loop, paused, cacheKey]);

  if (!source) {
    return <View style={style} />;
  }

  return (
    <NativeWebMAlphaGPUView
      {...nativeProps}
      style={[styles.container, style]}
      {...otherProps}
    />
  );
});

WebMAlphaGPUView.displayName = 'WebMAlphaGPUView';

// Backward compatibility alias
export const WebMAlphaMetalView = WebMAlphaGPUView;

const styles = StyleSheet.create({
  container: {
    // Note: backgroundColor not supported on TextureView/GLSurfaceView
  },
});

// Default export is the main component with GPU/CPU selection
export default WebMAlphaView;
