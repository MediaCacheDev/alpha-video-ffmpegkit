import { ViewStyle, StyleProp } from 'react-native';

export interface WebMAlphaViewProps {
  /**
   * URL or local file path to the WebM file with VP9+Alpha
   * Supports: http://, https://, file://
   */
  source: {
    uri?: string;
    path?: string;
  };

  /**
   * Start playing automatically when source is set
   * @default true
   */
  autoPlay?: boolean;

  /**
   * Loop the animation infinitely
   * @default true
   */
  loop?: boolean;

  /**
   * Pause the animation
   * @default false
   */
  paused?: boolean;

  /**
   * Use GPU acceleration (OpenGL ES on Android, Metal on iOS)
   * GPU mode is faster but may have compatibility issues on some devices
   * @default true
   */
  useGPU?: boolean;

  /**
   * Cache key for storing downloaded files
   * If provided, downloaded WebM files will be saved to this path under the cache directory
   * Useful for controlling cache location and avoiding re-downloads
   * If not provided, files are cached using an auto-generated hash of the URL
   */
  cacheKey?: string;

  /**
   * View style
   */
  style?: StyleProp<ViewStyle>;
}

/**
 * WebMAlphaView - React Native component for playing VP9+Alpha WebM files
 * 
 * Uses FFmpegKit for decoding VP9 video with alpha channel support.
 * Supports both CPU-based and GPU-accelerated rendering.
 */
export const WebMAlphaView: React.FC<WebMAlphaViewProps>;

/**
 * CPU-only WebM Alpha View
 * Simpler rendering using Bitmap/UIImage, no GPU shaders
 */
export const WebMAlphaCPUView: React.FC<Omit<WebMAlphaViewProps, 'useGPU'>>;

/**
 * GPU-accelerated WebM Alpha View
 * Uses OpenGL ES (Android) or Metal (iOS) for YUV→RGB conversion
 */
export const WebMAlphaGPUView: React.FC<Omit<WebMAlphaViewProps, 'useGPU'>>;

export default WebMAlphaView;
