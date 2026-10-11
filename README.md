# react-native-webm-alpha-player-js

A React Native library for playing VP9+Alpha WebM videos with transparency support, decoding with [FFmpegKit](https://github.com/arthenica/ffmpeg-kit) from plain Java and Swift.

Every clip is decoded in full before the first frame is shown, and all frames are kept for playback (see [Memory](#memory)). That suits short UI animations; it doesn't suit long or large clips.

## Features

- 🎬 **VP9 + Alpha channel support** - Play WebM videos with transparency
- ⚡ **GPU acceleration** - OpenGL ES (Android) / Metal (iOS) for fast YUV→RGB conversion
- 🔄 **CPU fallback** - Bitmap/UIImage-based rendering for maximum compatibility
- 📦 **Automatic caching** - Downloads remote videos once, into the app cache
- 🔁 **Loop & pause controls**, plus `onLoad` / `onError` / `onEnd` events
- 📱 **Cross-platform** - Android, iOS, and web (through `<video>`)

## Installation

```bash
npm install react-native-webm-alpha-player-js
# or
yarn add react-native-webm-alpha-player-js
```

### iOS Setup

```bash
cd ios && pod install
```

The FFmpegKit XCFrameworks are in `ios/Frameworks` and ship with the package.

### Android Setup

FFmpegKit's own binaries are no longer published, and the AAR this library needs is **not** in the repo or the npm package yet. Build it with `scripts/build-ffmpeg-android.sh` (see below), which writes `android/libs/ffmpegkit.aar`; `android/build.gradle` picks it up from there.

## Building FFmpeg (Development Only)

If you need to rebuild FFmpegKit from source:

### Android
```bash
# Set your NDK path
export ANDROID_NDK_HOME=/path/to/android-ndk

# Build
./scripts/build-ffmpeg-android.sh
```

### iOS
```bash
./scripts/build-ffmpeg-ios.sh
```

## Usage

### Basic Usage (GPU-accelerated, recommended)

```jsx
import { WebMAlphaView } from 'react-native-webm-alpha-player-js';

function MyComponent() {
  return (
    <WebMAlphaView
      source={{ uri: 'https://example.com/animation.webm' }}
      style={{ width: 200, height: 200 }}
      onLoad={({ totalFrames, width, height }) => console.log(totalFrames, width, height)}
      onError={({ error }) => console.warn(error)}
    />
  );
}
```

### CPU Mode (simpler, more compatible)

```jsx
import { WebMAlphaView } from 'react-native-webm-alpha-player-js';

function MyComponent() {
  return (
    <WebMAlphaView
      source={{ uri: 'https://example.com/animation.webm' }}
      useGPU={false}
      style={{ width: 200, height: 200 }}
    />
  );
}
```

### With Playback Controls

```jsx
import { WebMAlphaView } from 'react-native-webm-alpha-player-js';
import { useState } from 'react';

function MyComponent() {
  const [paused, setPaused] = useState(false);

  return (
    <>
      <WebMAlphaView
        source={{ uri: 'https://example.com/animation.webm' }}
        autoPlay={true}
        loop={true}
        paused={paused}
        style={{ width: 200, height: 200 }}
      />
      <Button 
        title={paused ? "Play" : "Pause"} 
        onPress={() => setPaused(!paused)} 
      />
    </>
  );
}
```

### Direct Component Access

```jsx
// Use GPU view directly
import { WebMAlphaGPUView } from 'react-native-webm-alpha-player-js';

// Use CPU view directly
import { WebMAlphaCPUView } from 'react-native-webm-alpha-player-js';
```

## Sources

`source` is `{ uri, cacheKey? }`, or just the `uri` string.

| `uri` | Android | iOS | Web |
|---|---|---|---|
| `https://…`, `http://…` | Downloaded once into the cache | Downloaded once into the cache | Loaded by the browser |
| `file:///abs/path`, `/abs/path` | Used in place | Used in place | – |
| `asset://relative/path` | APK `assets/` | App bundle resources | Site root (`/relative/path`) |
| `content://…` | Through `ContentResolver` | – | – |
| `intro` (bare name) | `res/raw/intro.webm` | – | – |

Anything else is reported through `onError`. Assets, `res/raw` and `content://` sources are streamed to FFmpeg through a named pipe, so nothing is copied to disk first and compressed APK entries work too.

For a `require()`d file, pass `Image.resolveAssetSource(require('./glow.webm')).uri`. In debug builds that's a Metro `http://localhost:8081` URL (downloaded like any other); in release builds it's a file path on iOS and a `res/raw` resource name on Android.

Downloads only count as successful on HTTP 200. Without a `cacheKey` the file is named from a SHA-256 of the URL, so presigned URLs that change on every request download again. Give such sources a stable `cacheKey`: a file name relative to the app cache directory (`"animations/intro.webm"`) that must stay inside it. Apps that download files themselves (with their own cache) should pass the local path instead.

## Props

| Prop | Type | Default | Description |
|------|------|---------|-------------|
| `source` | `{ uri, cacheKey? }` \| `string` | required | See [Sources](#sources) |
| `cacheKey` | `string` | - | Cache file name for downloads; overrides `source.cacheKey`. Also names the decoded-frame cache on iOS. Ignored on web |
| `autoPlay` | `boolean` | `true` | Start playing automatically |
| `loop` | `boolean` | `true` | Loop the animation |
| `paused` | `boolean` | `false` | Pause the animation |
| `useGPU` | `boolean` | `true` | Use GPU acceleration (`WebMAlphaView` only) |
| `verbose` | `boolean` | `false` | Log progress to logcat / the iOS console. Errors are always logged |
| `style` | `ViewStyle` | - | View style |

## Events

| Event | Payload | When |
|---|---|---|
| `onLoad` | `{ totalFrames, width, height }` | All frames are decoded and playback is starting. On web, `totalFrames` assumes 30 fps |
| `onError` | `{ error }` | The source couldn't be resolved, downloaded or decoded |
| `onEnd` | `{}` | A non-looping clip played to the end |

## Memory

The whole clip is decoded before playback starts, and every frame is kept:

| View | Where the frames live | Size |
|---|---|---|
| Android CPU | Raw RGBA file in the cache directory, read a frame at a time | Disk `W×H×4×frames` |
| Android GPU | OpenGL textures | GPU memory `W×H×2.5×frames` |
| iOS CPU | RAM (shared `NSCache`, up to 100 MB) | `W×H×4×frames` |
| iOS GPU | Metal textures (shared cache) | `W×H×2.5×frames` |

A 1080×1080 clip of 90 frames is about 400 MB as RGBA, so keep clips short and small.

## GPU vs CPU Mode

### GPU Mode (default)
- Uses OpenGL ES shaders (Android) or Metal shaders (iOS)
- YUV→RGB conversion happens on GPU (faster)
- ~3-5x faster rendering for the color conversion step
- May have issues on some older devices

### CPU Mode
- Uses Bitmap (Android) or UIImage (iOS)
- All processing on CPU
- More compatible with older devices
- Simpler implementation

## Supported Formats

- **Container:** WebM, Matroska
- **Video Codec:** VP9 with alpha channel (YUVA420P)
- **Sources:** see [Sources](#sources)

## Creating VP9+Alpha WebM Files

Use FFmpeg to encode videos with alpha:

```bash
# From PNG sequence with alpha
ffmpeg -framerate 30 -i frame_%04d.png -c:v libvpx-vp9 -pix_fmt yuva420p output.webm

# From video with green screen (chroma key)
ffmpeg -i input.mp4 -vf "chromakey=0x00ff00:0.1:0.2" -c:v libvpx-vp9 -pix_fmt yuva420p output.webm
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    React Native                         │
│                   WebMAlphaView                         │
│              (useGPU prop selects mode)                 │
└─────────────────────────────────────────────────────────┘
                           │
           ┌───────────────┴───────────────┐
           ▼                               ▼
┌─────────────────────────┐   ┌─────────────────────────┐
│      CPU Mode           │   │      GPU Mode           │
├─────────────────────────┤   ├─────────────────────────┤
│ Android:                │   │ Android:                │
│   TextureView + Bitmap  │   │   TextureView + OpenGL  │
│   FFmpeg → RGBA → Draw  │   │   FFmpeg → YUVA → GPU   │
├─────────────────────────┤   ├─────────────────────────┤
│ iOS:                    │   │ iOS:                    │
│   UIImageView           │   │   MTKView + Metal       │
│   FFmpeg → RGBA → Draw  │   │   FFmpeg → YUVA → GPU   │
└─────────────────────────┘   └─────────────────────────┘
```

## Requirements

- React Native 0.70+
- Android: minSdkVersion 21, compileSdkVersion 34
- iOS: iOS 13.0+

## License

MIT

## Credits

- [FFmpegKit](https://github.com/arthenica/ffmpeg-kit) - FFmpeg for mobile
- [libvpx](https://chromium.googlesource.com/webm/libvpx) - VP9 decoder
