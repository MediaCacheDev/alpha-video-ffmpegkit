import React, { useMemo } from 'react';
import { Platform, View, StyleSheet } from 'react-native';

// Import native components using codegenNativeComponent
// This supports both New Architecture (Fabric) and Legacy Architecture (auto-fallback)
import NativeWebMAlphaCPUView from './WebMAlphaCPUViewNativeComponent';
import NativeWebMAlphaGPUView from './WebMAlphaGPUViewNativeComponent';

/**
 * WebMAlphaView - React Native component for playing VP9+Alpha WebM files
 * 
 * Features:
 * - Supports WebM files with VP9 video codec and alpha channel
 * - Two rendering modes: CPU (simpler) and GPU (faster)
 * - GPU mode uses OpenGL ES on Android and Metal on iOS
 * - Automatic URL downloading and caching
 * - Looping and pause controls
 * - Frame caching with cacheKey for repeated animations
 * 
 * @param {Object} props - Component props
 * @param {string} props.source - URL or local file path to the WebM file
 * @param {boolean} [props.autoPlay=true] - Start playing automatically
 * @param {boolean} [props.loop=true] - Loop the animation
 * @param {boolean} [props.paused=false] - Pause the animation
 * @param {boolean} [props.useGPU=true] - Use GPU acceleration (OpenGL ES/Metal)
 * @param {string} [props.cacheKey] - Cache key for downloaded files (controls where WebM files are saved in cache)
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
  ...otherProps
}) => {
  // Choose the appropriate native component
  const NativeComponent = useMemo(() => {
    return useGPU ? NativeWebMAlphaGPUView : NativeWebMAlphaCPUView;
  }, [useGPU]);

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
 */
export const WebMAlphaCPUView = React.memo(({
  source,
  autoPlay = true,
  loop = true,
  paused = false,
  cacheKey,
  style,
  ...otherProps
}) => {
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
 */

export const WebMAlphaGPUView = React.memo(({
  source,
  autoPlay = true,
  loop = true,
  paused = false,
  cacheKey,
  style,
  ...otherProps
}) => {
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
