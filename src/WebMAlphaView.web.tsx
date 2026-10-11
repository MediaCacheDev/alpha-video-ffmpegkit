/**
 * WebMAlphaView - Web Implementation
 * 
 * Uses native HTML5 <video> element for WebM playback on web.
 * WebM with VP9+Alpha is natively supported in Chrome, Edge, and Firefox.
 */

import React, { useRef, useEffect, useCallback, useState, useMemo } from 'react';
import { View, StyleSheet, Platform } from 'react-native';

export interface SourceType {
  uri?: string;
  /** @deprecated use uri */
  path?: string;
  cacheKey?: string;
}

export interface WebMAlphaViewWebProps {
  source?: SourceType | string | null;
  autoPlay?: boolean;
  loop?: boolean;
  paused?: boolean;
  useGPU?: boolean; // Ignored on web, kept for API compatibility
  cacheKey?: string; // Ignored on web, browser handles caching
  verbose?: boolean; // Ignored on web
  style?: any;
  onLoad?: (event: { totalFrames: number; width: number; height: number }) => void;
  onError?: (event: { error: string }) => void;
  onEnd?: (event: {}) => void;
}

/** asset://path is served from the site root, like files bundled with a native app. */
function resolveWebUri(uri: string): string {
  return uri.startsWith('asset://') ? '/' + uri.slice('asset://'.length).replace(/^\/+/, '') : uri;
}

export const WebMAlphaViewWeb: React.FC<WebMAlphaViewWebProps> = ({
  source,
  autoPlay = true,
  loop = true,
  paused = false,
  style,
  onLoad,
  onError,
  onEnd,
}) => {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [isReady, setIsReady] = useState(false);

  // Normalize source to get URI
  const videoSrc = useMemo(() => {
    const uri = typeof source === 'string' ? source : source?.uri || source?.path;
    return uri ? resolveWebUri(uri) : null;
  }, [source]);

  // Handle video loaded
  const handleLoadedData = useCallback((e: React.SyntheticEvent<HTMLVideoElement, Event>) => {
    const video = e.currentTarget;
    setIsReady(true);
    // The browser doesn't expose a frame count; this assumes 30 fps.
    onLoad?.({
      totalFrames: Math.floor(video.duration * 30),
      width: video.videoWidth,
      height: video.videoHeight,
    });
  }, [onLoad]);

  // Handle video error
  const handleError = useCallback((e: React.SyntheticEvent<HTMLVideoElement, Event>) => {
    const video = e.currentTarget;
    const error = video.error;
    onError?.({ error: error?.message || 'Video playback error' });
  }, [onError]);

  // Handle video ended
  const handleEnded = useCallback(() => {
    onEnd?.({});
  }, [onEnd]);

  // Handle autoPlay
  useEffect(() => {
    const video = videoRef.current;
    if (!video || !isReady) return;

    if (autoPlay && !paused) {
      video.play().catch((err) => {
        // Autoplay may be blocked by browser policy
        console.warn('[WebMAlphaView] Autoplay blocked:', err.message);
      });
    }
  }, [autoPlay, isReady, paused]);

  // Handle pause/play state changes
  useEffect(() => {
    const video = videoRef.current;
    if (!video || !isReady) return;

    if (paused) {
      video.pause();
    } else {
      video.play().catch(() => {});
    }
  }, [paused, isReady]);

  // Handle loop changes
  useEffect(() => {
    const video = videoRef.current;
    if (video) {
      video.loop = loop;
    }
  }, [loop]);

  // Get dimensions from style
  const dimensions = useMemo(() => {
    const flatStyle = StyleSheet.flatten(style) || {};
    return {
      width: flatStyle.width || '100%',
      height: flatStyle.height || '100%',
    };
  }, [style]);

  if (!videoSrc) {
    return <View style={style} />;
  }

  return (
    <View style={[styles.container, style]}>
      <video
        ref={videoRef}
        src={videoSrc}
        autoPlay={autoPlay && !paused}
        loop={loop}
        muted // Required for autoplay in most browsers
        playsInline // Required for iOS Safari
        onLoadedData={handleLoadedData}
        onError={handleError}
        onEnded={handleEnded}
        style={{
          width: typeof dimensions.width === 'number' ? dimensions.width : dimensions.width,
          height: typeof dimensions.height === 'number' ? dimensions.height : dimensions.height,
          objectFit: 'contain',
          backgroundColor: 'transparent',
        }}
      />
    </View>
  );
};

// CPU and GPU views are the same on web - just use the video element
export const WebMAlphaCPUViewWeb = WebMAlphaViewWeb;
export const WebMAlphaGPUViewWeb = WebMAlphaViewWeb;

const styles = StyleSheet.create({
  container: {
    overflow: 'hidden',
  },
});

WebMAlphaViewWeb.displayName = 'WebMAlphaViewWeb';

export default WebMAlphaViewWeb;
