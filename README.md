# react-native-webm-alpha-player-js

A React Native library for playing VP9+Alpha WebM videos with transparency support, decoding with [FFmpegKit](https://github.com/arthenica/ffmpeg-kit) from plain Java and Swift.

By default clips are decoded while they play, a few frames ahead, so memory stays flat however long the clip is. `mode="preload"` decodes every frame first instead, which suits short clips that loop for a long time (see [Playback modes](#playback-modes)).

This was the first attempt, and it stays as a reference implementation: the whole player is plain Java and Swift around FFmpeg command lines. For production, use [react-native-webm-alpha-player](https://github.com/danielkpl2/react-native-webm-alpha-player), which shares a C++ decoder between platforms:

| | this package | react-native-webm-alpha-player |
|---|---|---|
| Decoding | FFmpegKit command line, to raw frames | libvpx through FFmpeg's API, in process |
| Playback | stream or preload | stream, preload or both |
| http(s) sources | downloaded in full first | play while downloading (stream modes) |
| FFmpeg licence | LGPL-3.0 (FFmpegKit builds with `--enable-version3`) | LGPL-2.1 |

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

The podspec depends on the `ffmpegkit-vp9` 6.0.0 pod from CocoaPods trunk, a minimal FFmpegKit build. Its XCFrameworks are dynamic, and CocoaPods embeds them in the app.

### Android Setup

FFmpegKit's own binaries are no longer published. The library depends on `dev.mediacache:ffmpegkit-vp9:6.0.0` from Maven Central, a minimal FFmpegKit build with the same `com.arthenica.ffmpegkit` API. It needs `minSdkVersion` 24.

## FFmpegKit build

Both platforms use [ffmpegkit-vp9](https://github.com/MediaCacheDev/ffmpegkit-vp9): the archived [arthenica/ffmpeg-kit](https://github.com/arthenica/ffmpeg-kit) at a fixed commit (FFmpeg 6.0, libvpx 1.13.0), configured with `--disable-everything` plus what the player needs: the WebM demuxer, the libvpx VP9 decoder, rawvideo output, the file and pipe protocols, and a few filters. It is about 4 MB for Android (four ABIs) and 11 MB for iOS, against 31 MB and 60 MB for a default `--enable-libvpx` build. Its build scripts, notices and sources are in that repository.

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
| `cacheKey` | `string` | - | Cache file name for downloads; overrides `source.cacheKey`. Also names the decoded-frame cache on iOS in preload mode. Ignored on web |
| `autoPlay` | `boolean` | `true` | Start playing automatically |
| `loop` | `boolean` | `true` | Loop the animation |
| `paused` | `boolean` | `false` | Pause the animation |
| `useGPU` | `boolean` | `true` | Use GPU acceleration (`WebMAlphaView` only) |
| `mode` | `'stream'` \| `'preload'` | `'stream'` | See [Playback modes](#playback-modes). Changing it restarts playback. Ignored on web |
| `streamBufferFrames` | `number` | `15` | Frames decoded ahead in stream mode. Applies from the next start |
| `verbose` | `boolean` | `false` | Log progress to logcat / the iOS console. Errors are always logged |
| `style` | `ViewStyle` | - | View style |

## Events

| Event | Payload | When |
|---|---|---|
| `onLoad` | `{ totalFrames, width, height }` | The first frame is ready (stream mode) or all frames are decoded (preload mode), and playback is starting. In stream mode `totalFrames` is estimated from the duration and frame rate; on web it assumes 30 fps |
| `onError` | `{ error }` | The source couldn't be resolved, downloaded or decoded |
| `onEnd` | `{}` | A non-looping clip played to the end |

## Playback modes

**Stream** (default): FFmpeg decodes into a fixed pool of `streamBufferFrames` frames and waits whenever the pool is full, so it runs at the clip's frame rate and the first frame shows as soon as it's decoded. Memory stays the same however long the clip is, but FFmpeg runs for as long as the clip plays, and each loop decodes the clip again from the start. A device that can't decode the clip in real time plays it slower rather than dropping frames.

**Preload** (`mode="preload"`): every frame is decoded before playback starts and kept, so loops cost nothing after the first pass. Memory and the wait before the first frame grow with the clip.

In both modes an http(s) source is downloaded in full before decoding starts. Frames are shown at the file's frame rate (`avg_frame_rate`, then `r_frame_rate`, then 30 fps).

## Memory

| View | Stream | Preload |
|---|---|---|
| Android CPU | RAM `W×H×4×streamBufferFrames` | Disk `W×H×4×frames` (raw RGBA file in the cache directory, read a frame at a time) |
| Android GPU | RAM `W×H×2.5×streamBufferFrames`, plus one set of textures | GPU memory `W×H×2.5×frames` |
| iOS CPU | RAM `W×H×4×streamBufferFrames` | RAM `W×H×4×frames` (shared `NSCache`, up to 100 MB) |
| iOS GPU | RAM `W×H×2.5×streamBufferFrames`, plus three sets of textures | Metal textures `W×H×2.5×frames` (shared cache) |

A 1080×1080 clip of 90 frames is about 400 MB as RGBA when preloaded; streamed with the default 15 frames, it's about 70 MB however many frames it has.

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
- Android: minSdkVersion 24; compileSdkVersion and targetSdkVersion come from the app (default 36)
- iOS: iOS 13.0+

## License

The code in this repository is MIT. The FFmpegKit and FFmpeg binaries it depends on are LGPL-3.0, and libvpx is BSD-3-Clause; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

- [FFmpegKit](https://github.com/arthenica/ffmpeg-kit) - FFmpeg for mobile
- [libvpx](https://chromium.googlesource.com/webm/libvpx) - VP9 decoder
