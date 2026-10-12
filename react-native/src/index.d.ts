import { ViewStyle, StyleProp } from 'react-native';

export interface FFmpegKitAlphaSource {
  /**
   * Where the WebM (VP9 + alpha) comes from:
   * - `https://…`, `http://…`: downloaded once into the app cache (see `cacheKey`)
   * - `file:///abs/path` or `/abs/path`: a local file, used in place
   * - `asset://relative/path`: Android APK assets, the iOS app bundle, or the site root on web
   * - Android only: `content://…`, or a bare `res/raw` resource name such as `"intro"`
   */
  uri: string;
  /** @deprecated use `uri` */
  path?: string;
  /** Same as the `cacheKey` prop; the prop wins if both are set. */
  cacheKey?: string;
}

export interface FFmpegKitAlphaLoadEvent {
  totalFrames: number;
  width: number;
  height: number;
}

export interface FFmpegKitAlphaErrorEvent {
  error: string;
}

export interface FFmpegKitAlphaViewProps {
  /** A `FFmpegKitAlphaSource` or just its `uri`. */
  source: FFmpegKitAlphaSource | string | null | undefined;

  /**
   * Start playing automatically when source is set. Off, the first frame shows and stays.
   * @default true
   */
  autoPlay?: boolean;

  /**
   * Loop the animation infinitely
   * @default true
   */
  loop?: boolean;

  /**
   * Hold the current frame; playback carries on from it when unpaused. A clip that starts
   * paused still loads and shows its first frame.
   * @default false
   */
  paused?: boolean;

  /**
   * Use GPU acceleration (OpenGL ES on Android, Metal on iOS)
   * Ignored on web (uses HTML5 video element)
   * @default true
   */
  useGPU?: boolean;

  /**
   * File name for the downloaded copy of an http(s) source, relative to the app's cache
   * directory (e.g. `"animations/intro.webm"`); it must stay inside that directory. Without
   * one the file is named from a SHA-256 of the URL, so a URL that changes (presigned links)
   * downloads again. Also names the decoded-frame cache on iOS.
   * Ignored on web (browser handles caching)
   */
  cacheKey?: string;

  /**
   * Log progress to logcat / the iOS console. Errors are always logged.
   * @default false
   */
  verbose?: boolean;

  /**
   * - `'stream'`: decode while playing, holding `streamBufferFrames` frames ahead. Playback
   *   starts after the first frame and memory stays flat however long the clip is, but decoding
   *   runs for as long as the clip plays, and each loop decodes the clip again.
   * - `'preload'`: decode every frame before playing (to a raw file on Android CPU, into
   *   textures on Android GPU, into memory on iOS). Loops cost nothing, but memory and the wait
   *   before the first frame grow with the clip. Suits short clips that loop for a long time.
   *
   * An http(s) source is still downloaded completely first. Ignored on web.
   * @default 'stream'
   */
  mode?: 'preload' | 'stream';

  /**
   * Decoded frames held ahead of playback in `'stream'` mode. Each costs width × height × 4
   * bytes on the CPU views and width × height × 2.5 on the GPU views. More frames absorb decoder
   * hiccups and the restart at each loop. Applies from the next start.
   * @default 15
   */
  streamBufferFrames?: number;

  /**
   * View style
   */
  style?: StyleProp<ViewStyle>;

  /**
   * Playback is starting: in `'preload'` mode all frames are decoded; in `'stream'` mode the
   * first one is, and totalFrames is estimated from the duration. On web, totalFrames assumes 30 fps.
   */
  onLoad?: (event: FFmpegKitAlphaLoadEvent) => void;

  /** The source could not be resolved, downloaded or decoded. */
  onError?: (event: FFmpegKitAlphaErrorEvent) => void;

  /** A non-looping clip played to the end. */
  onEnd?: (event: {}) => void;
}

/**
 * Seeks show the frame (clamped to the clip) and keep playing, or stay paused. They are ignored
 * until `onLoad`, and in `'stream'` mode when the file doesn't give a duration. A `'stream'`
 * seek decodes again from the keyframe before the target, so it takes longer than a
 * `'preload'` one. On web the frame rate is assumed to be 30 fps.
 */
export interface FFmpegKitAlphaViewRef {
  seekToFrame: (frame: number) => void;
  /** Seeks to the frame showing at that time, in seconds. */
  seekToTime: (seconds: number) => void;
}

/**
 * Plays VP9+Alpha WebM, decoded by FFmpegKit. `useGPU` (default true) picks OpenGL ES / Metal
 * rendering over Bitmap / UIImage rendering. On web this is an HTML5 <video>.
 */
export const FFmpegKitAlphaView: React.ForwardRefExoticComponent<
  FFmpegKitAlphaViewProps & React.RefAttributes<FFmpegKitAlphaViewRef>
>;

/**
 * CPU-only WebM Alpha View
 * Simpler rendering using Bitmap/UIImage, no GPU shaders
 */
export const FFmpegKitAlphaCPUView: React.ForwardRefExoticComponent<
  Omit<FFmpegKitAlphaViewProps, 'useGPU'> & React.RefAttributes<FFmpegKitAlphaViewRef>
>;

/**
 * GPU-accelerated WebM Alpha View
 * Uses OpenGL ES (Android) or Metal (iOS) for YUV→RGB conversion
 */
export const FFmpegKitAlphaGPUView: React.ForwardRefExoticComponent<
  Omit<FFmpegKitAlphaViewProps, 'useGPU'> & React.RefAttributes<FFmpegKitAlphaViewRef>
>;
