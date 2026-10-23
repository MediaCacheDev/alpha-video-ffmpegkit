# alpha-video-ffmpegkit

<p align="center">
  <img src="docs/alpha-video-ffmpegkit.avif" alt="Transparent WebM videos playing over a checkerboard in the demo app on Android" width="360">
  <br>
  <a href="https://github.com/MediaCacheDev/alpha-video-test">Compare transparent formats in the demo app</a>
</p>

> **For new apps, use [alpha-video](https://github.com/MediaCacheDev/alpha-video).** This package was the first attempt at transparent WebM, and it stays as a reference implementation. It's fully functional, streaming included, but alpha-video far surpasses it: hardware decoding on Android, VP8 and AV1, playing while downloading, and one C++ decoder shared by every platform. See [the comparison](#compared-with-alpha-video).

Plays VP9 WebM videos with an alpha channel (transparent video) on Android and iOS, decoding with [FFmpegKit](https://github.com/arthenica/ffmpeg-kit) from plain Java and Swift. It comes as a React Native component and as standalone Android and iOS libraries.

| Platform | Package | Views |
|---|---|---|
| React Native (Android, iOS, web) | npm `react-native-alpha-video-ffmpegkit` | `FFmpegKitAlphaView`, `FFmpegKitAlphaGPUView`, `FFmpegKitAlphaCPUView` |
| Android | Maven `dev.mediacache:alpha-video-ffmpegkit` | `dev.mediacache.alphavideo.ffmpegkit.FFmpegKitAlphaGPUView`, `…FFmpegKitAlphaCPUView` |
| iOS | Swift Package Manager, product `AlphaVideoFFmpegKit`; CocoaPods `alpha-video-ffmpegkit` | `FFmpegKitAlphaGPUView`, `FFmpegKitAlphaCPUView` |

By default clips are decoded while they play, a few frames ahead, so memory stays flat however long the clip is. `mode="preload"` decodes every frame first instead, which suits short clips that loop for a long time (see [Playback modes](#playback-modes)).

### Compared with alpha-video

The whole player is plain Java and Swift around FFmpeg command lines, which makes it easy to read, and that's why it's kept. [alpha-video](https://github.com/MediaCacheDev/alpha-video) shares a C++ decoder between platforms instead:

| | this package | alpha-video |
|---|---|---|
| Files | VP9 with alpha (YUVA WebM) | VP8 or VP9 with alpha (YUVA WebM), and dual-stream VP8, VP9 or AV1 (8- to 12-bit) |
| Decoding | FFmpegKit command line, to raw frames | libvpx or dav1d in process; on Android, MediaCodec in hardware where it can |
| Playback | stream or preload | stream, preload or both |
| http(s) sources | downloaded in full first | play while downloading (stream modes) |
| Licences | MIT, with FFmpegKit and FFmpeg under LGPL-3.0 (FFmpegKit builds with `--enable-version3`) | MIT, with libvpx, dav1d and libwebm under BSD licences: no FFmpeg on Android or iOS |

For transparent video with no video codec at all, see [alpha-video-gpu](https://github.com/MediaCacheDev/alpha-video-gpu), and the [demo app](#demo-and-related-packages) to compare them all.

## Features

- 🎬 **VP9 + Alpha channel support** - Play WebM videos with transparency
- ⚡ **GPU acceleration** - OpenGL ES (Android) / Metal (iOS) for fast YUV→RGB conversion
- 🔄 **CPU fallback** - Bitmap/UIImage-based rendering for maximum compatibility
- 📦 **Automatic caching** - Downloads remote videos once, into the app cache
- 🔁 **Loop, pause and seek controls**, plus `onLoad` / `onError` / `onEnd` events
- 📱 **Cross-platform** - Android, iOS, and web (through `<video>`)

## Installation

### React Native

**npm**, package `react-native-alpha-video-ffmpegkit`:

```bash
npm install react-native-alpha-video-ffmpegkit
cd ios && pod install
```

```tsx
import { FFmpegKitAlphaView } from 'react-native-alpha-video-ffmpegkit';

<FFmpegKitAlphaView
  source={{ uri: 'https://example.com/video.webm', cacheKey: 'videos/intro.webm' }} // cacheKey: http(s) only
  style={{ width: 200, height: 200 }}
  useGPU={true}                // the default: draws with the GPU; false draws on the CPU
  autoPlay={true}              // the default; false holds the first frame until it's set to true
  loop={true}                  // the default; false plays once, then calls onEnd
  paused={false}               // a hold; the clip carries on from its frame when unpaused
  mode="stream"                // the default; 'preload' decodes every frame first
  streamBufferFrames={15}      // stream: frames decoded ahead
  verbose={false}              // true logs progress; errors always log
  onLoad={({ totalFrames, width, height }) => console.log(totalFrames, width, height)}
  onError={({ error }) => console.warn(error)}
  onEnd={() => console.log('played once')}
/>
```

On iOS the podspec depends on the `ffmpegkit-vp9` 6.0.0 pod from CocoaPods trunk, a minimal FFmpegKit build. Its XCFrameworks are dynamic, and CocoaPods embeds them in the app.

On Android the library depends on `dev.mediacache:ffmpegkit-vp9:6.0.0` from Maven Central, the same minimal build with the `com.arthenica.ffmpegkit` API (FFmpegKit's own binaries are no longer published). It needs `minSdkVersion` 24.

Both views work on both React Native architectures: the new one (Fabric, the default since 0.76) and the old one (`newArchEnabled=false`, up to 0.81). They are tested on 0.83, and on 0.81 with the new architecture turned off.

### Android

**Maven Central**, artifact `dev.mediacache:alpha-video-ffmpegkit`:

```gradle
dependencies {
    implementation 'dev.mediacache:alpha-video-ffmpegkit:1.0.0'
}
```

`FFmpegKitAlphaGPUView` (OpenGL ES) and `FFmpegKitAlphaCPUView` (Bitmap) are `TextureView`s in `dev.mediacache.alphavideo.ffmpegkit`. They take the same sources and options as the React Native component, through setters:

```kotlin
val view = FFmpegKitAlphaGPUView(context)  // or FFmpegKitAlphaCPUView, which draws Bitmaps
view.setCacheKey("videos/intro.webm")  // http(s) only: the cache file's name; default, a hash of the URL
view.setAutoPlay(true)                 // the default; false holds the first frame until it's set to true
view.setLoop(true)                     // the default; false plays once, then calls onEnd
view.setPaused(false)                  // a hold; the clip carries on from its frame when unpaused
view.setMode("stream")                 // the default; "preload" decodes every frame first
view.setStreamBufferFrames(15)         // stream: frames decoded ahead
view.setVerbose(false)                 // true logs progress to Logcat; errors always log
view.setCallback(object : PlayerCallback {
    override fun onLoad(totalFrames: Int, width: Int, height: Int) {}
    override fun onError(error: String) {}
    override fun onEnd() {}
})
view.setSource("https://example.com/video.webm")
container.addView(view)
```

Playback starts once the view's surface exists. `setAutoPlay` and `setPaused` both take effect straight away: the clip plays while `autoPlay` is on and it isn't paused. Detaching the view stops it, and attaching it again starts it over. Callbacks arrive on the main thread. http(s) sources need the `INTERNET` permission in the app's manifest. Needs `minSdk` 24.

### iOS

**CocoaPods**, pod `alpha-video-ffmpegkit`:

```ruby
pod 'alpha-video-ffmpegkit', '1.0.0'
```

**Swift Package Manager**, package `alpha-video-ffmpegkit`, product `AlphaVideoFFmpegKit`:

```swift
.package(url: "https://github.com/MediaCacheDev/alpha-video-ffmpegkit", from: "1.0.0")
// in the target's dependencies:
.product(name: "AlphaVideoFFmpegKit", package: "alpha-video-ffmpegkit")
```

The module is `AlphaVideoFFmpegKit` either way.

Both pull in [ffmpegkit-vp9](https://github.com/MediaCacheDev/ffmpegkit-vp9) 6.0.0 as dynamic XCFrameworks, which are embedded in the app.

```swift
import AlphaVideoFFmpegKit

let view = FFmpegKitAlphaGPUView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))  // or FFmpegKitAlphaCPUView
view.cacheKey = "videos/intro.webm"    // http(s) only: the cache file's name; default, a hash of the URL
view.autoPlay = true                   // the default; false holds the first frame until play()
view.loop = true                       // the default; false plays once, then calls onEnd
view.paused = false                    // a hold; the clip carries on from its frame when unpaused
view.mode = "stream"                   // the default; "preload" decodes every frame first
view.streamBufferFrames = 15           // stream: frames decoded ahead
view.verbose = false                   // true logs progress to the Xcode console; errors always log
view.onLoad = { totalFrames, width, height in }
view.onError = { error in }
view.onEnd = { }
view.source = "https://example.com/video.webm"
container.addSubview(view)
```

Playback starts on the next main-queue turn after `source` is set, so the other properties can be set before or after it. Closures are called on the main queue. `FFmpegKitAlphaCPUView` has the same properties. A clip with `autoPlay` off starts with `play()`, or when `autoPlay` is set to `true`; the CPU view only has the latter. iOS 13 or later.

## Usage

### Basic Usage (GPU-accelerated, recommended)

```jsx
import { FFmpegKitAlphaView } from 'react-native-alpha-video-ffmpegkit';

function MyComponent() {
  return (
    <FFmpegKitAlphaView
      source={{ uri: 'https://example.com/video.webm', cacheKey: 'videos/intro.webm' }} // cacheKey: http(s) only
      style={{ width: 200, height: 200 }}
      useGPU={true}                // the default: draws with the GPU; false draws on the CPU
      autoPlay={true}              // the default; false holds the first frame until it's set to true
      loop={true}                  // the default; false plays once, then calls onEnd
      paused={false}               // a hold; the clip carries on from its frame when unpaused
      mode="stream"                // the default; 'preload' decodes every frame first
      streamBufferFrames={15}      // stream: frames decoded ahead
      verbose={false}              // true logs progress; errors always log
      onLoad={({ totalFrames, width, height }) => console.log(totalFrames, width, height)}
      onError={({ error }) => console.warn(error)}
      onEnd={() => console.log('played once')}
    />
  );
}
```

### CPU Mode (simpler, more compatible)

```jsx
import { FFmpegKitAlphaView } from 'react-native-alpha-video-ffmpegkit';

function MyComponent() {
  return (
    <FFmpegKitAlphaView
      source={{ uri: 'https://example.com/video.webm', cacheKey: 'videos/intro.webm' }} // cacheKey: http(s) only
      style={{ width: 200, height: 200 }}
      useGPU={false}               // draws on the CPU; the default, true, draws with the GPU
      autoPlay={true}              // the default; false holds the first frame until it's set to true
      loop={true}                  // the default; false plays once, then calls onEnd
      paused={false}               // a hold; the clip carries on from its frame when unpaused
      mode="stream"                // the default; 'preload' decodes every frame first
      streamBufferFrames={15}      // stream: frames decoded ahead
      verbose={false}              // true logs progress; errors always log
      onLoad={({ totalFrames, width, height }) => console.log(totalFrames, width, height)}
      onError={({ error }) => console.warn(error)}
      onEnd={() => console.log('played once')}
    />
  );
}
```

### With Playback Controls

```jsx
import { FFmpegKitAlphaView } from 'react-native-alpha-video-ffmpegkit';
import { useRef, useState } from 'react';
import { Button } from 'react-native';

function MyComponent() {
  const player = useRef(null);
  const [paused, setPaused] = useState(false);

  return (
    <>
      <FFmpegKitAlphaView
        ref={player}                 // seekToFrame(frame), seekToTime(seconds)
        source={{ uri: 'https://example.com/video.webm', cacheKey: 'videos/intro.webm' }} // cacheKey: http(s) only
        style={{ width: 200, height: 200 }}
        useGPU={true}                // the default: draws with the GPU; false draws on the CPU
        autoPlay={true}              // the default; false holds the first frame until it's set to true
        loop={true}                  // the default; false plays once, then calls onEnd
        paused={paused}              // a hold; the clip carries on from its frame when unpaused
        mode="stream"                // the default; 'preload' decodes every frame first
        streamBufferFrames={15}      // stream: frames decoded ahead
        verbose={false}              // true logs progress; errors always log
        onLoad={({ totalFrames, width, height }) => console.log(totalFrames, width, height)}
        onError={({ error }) => console.warn(error)}
        onEnd={() => console.log('played once')}
      />
      <Button title={paused ? 'Play' : 'Pause'} onPress={() => setPaused(!paused)} />
      <Button title="Frame 45" onPress={() => player.current?.seekToFrame(45)} />
    </>
  );
}
```

### Direct Component Access

```jsx
// Use GPU view directly
import { FFmpegKitAlphaGPUView } from 'react-native-alpha-video-ffmpegkit';

// Use CPU view directly
import { FFmpegKitAlphaCPUView } from 'react-native-alpha-video-ffmpegkit';
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

Downloads only count as successful on HTTP 200. Without a `cacheKey` the file is named from a SHA-256 of the URL, so presigned URLs that change on every request download again. Give such sources a stable `cacheKey`: a file name relative to the app cache directory (`"videos/intro.webm"`) that must stay inside it. Apps that download files themselves (with their own cache) should pass the local path instead.

## Props

| Prop | Type | Default | Description |
|------|------|---------|-------------|
| `source` | `{ uri, cacheKey? }` \| `string` | required | See [Sources](#sources) |
| `cacheKey` | `string` | - | Cache file name for downloads; overrides `source.cacheKey`. Also names the decoded-frame cache on iOS in preload mode. Ignored on web |
| `autoPlay` | `boolean` | `true` | Start playing automatically. Off, the first frame shows and stays until it's set to `true` |
| `loop` | `boolean` | `true` | Loop the video |
| `paused` | `boolean` | `false` | Hold the current frame; playback carries on from it when unpaused. A clip that starts paused still loads and shows its first frame |
| `useGPU` | `boolean` | `true` | Use GPU acceleration (`FFmpegKitAlphaView` only) |
| `mode` | `'stream'` \| `'preload'` | `'stream'` | See [Playback modes](#playback-modes). Changing it restarts playback. Ignored on web |
| `streamBufferFrames` | `number` | `15` | Frames decoded ahead in stream mode. Applies from the next start |
| `verbose` | `boolean` | `false` | Log progress to logcat / the iOS console. Errors are always logged |
| `style` | `ViewStyle` | - | View style |

## Events

| Event | Payload | When |
|---|---|---|
| `onLoad` | `{ totalFrames, width, height }` | The first frame is ready (stream mode) or all frames are decoded (preload mode), and playback is starting. In stream mode `totalFrames` is estimated from the duration and frame rate; on web it assumes 30 fps |
| `onError` | `{ error }` | The source couldn't be resolved, downloaded or decoded |
| `onEnd` | `{}` | A non-looping clip played to the end. Its last frame stays up; unpausing or seeking plays on |

## Seeking

```jsx
const player = useRef(null);

<FFmpegKitAlphaView ref={player} source={{ uri: 'asset://videos/glow.webm' }} />

player.current?.seekToFrame(45);
player.current?.seekToTime(1.5); // the frame showing at 1.5 s
```

| Ref method | Description |
|---|---|
| `seekToFrame(frame)` | Shows that frame, counted from 0, and keeps playing or stays paused |
| `seekToTime(seconds)` | Seeks to the frame showing at that time: frame `floor(seconds × fps)` |

Frames past either end are clamped to the clip. Seeks are ignored until `onLoad`. In preload mode a seek shows its frame straight away. In stream mode it decodes again from the keyframe before the target, so it takes as long as decoding up to there; it's ignored if the file doesn't give a duration. On web the frame rate is assumed to be 30 fps. The native views have the same methods: `seekToFrame(int)` / `seekToTime(double)` on Android, `seekToFrame(_:)` / `seekToTime(_:)` on iOS.

## Playback modes

**Stream** (default): FFmpeg decodes into a fixed pool of `streamBufferFrames` frames and waits whenever the pool is full, so it runs at the clip's frame rate and the first frame shows as soon as it's decoded. Memory stays the same however long the clip is, but FFmpeg runs for as long as the clip plays, and each loop decodes the clip again from the start. A device that can't decode the clip in real time plays it slower rather than dropping frames.

**Preload** (`mode="preload"`): every frame is decoded before playback starts and kept, so loops cost nothing after the first pass. Memory and the wait before the first frame grow with the clip.

In both modes an http(s) source is downloaded in full before decoding starts. Frames are shown at the file's frame rate (`avg_frame_rate`, then `r_frame_rate`, then 30 fps).

## Memory

| View | Stream | Preload |
|---|---|---|
| Android CPU | RAM `W×H×4×streamBufferFrames` | Disk `W×H×4×frames` (raw RGBA file in the cache directory, read a frame at a time) |
| Android GPU | RAM `W×H×2.5×streamBufferFrames`, plus one set of textures | GPU memory `W×H×2.5×frames` |
| iOS CPU | RAM `W×H×4×streamBufferFrames` | RAM `W×H×4×frames` (shared `NSCache`, up to an eighth of the device's memory) |
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
- **Video Codec:** VP9 with alpha channel (YUVA420P). Files with the alpha in a separate track (dual-stream) play opaque; `react-native-alpha-video` plays those.
- **Colour:** the GPU views use the clip's range and matrix tags (BT.601, BT.709, BT.2020). An untagged clip is taken as limited range, BT.601 up to 720x576 and BT.709 above.
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
│                 FFmpegKitAlphaView                      │
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

## FFmpegKit build

Both platforms use [ffmpegkit-vp9](https://github.com/MediaCacheDev/ffmpegkit-vp9): the archived [arthenica/ffmpeg-kit](https://github.com/arthenica/ffmpeg-kit) at a fixed commit (FFmpeg 6.0, libvpx 1.13.0), configured with `--disable-everything` plus what the player needs: the WebM demuxer, the libvpx VP9 decoder, rawvideo output, the file and pipe protocols, and a few filters. It is about 4 MB for Android (four ABIs) and 11 MB for iOS, against 31 MB and 60 MB for a default `--enable-libvpx` build. Its build scripts, notices and sources are in that repository.

## Repository layout

| Path | What | Package |
|---|---|---|
| `android/` | The Android library: the two views, `PlayerCallback`, source loading, the FFmpegKit pipes. Builds on its own (`./gradlew` in that folder) | `dev.mediacache:alpha-video-ffmpegkit` |
| `ios/Sources/AlphaVideoFFmpegKit/` | The iOS library: the two views and source loading | SwiftPM `AlphaVideoFFmpegKit` (`Package.swift`), CocoaPods `alpha-video-ffmpegkit` (`alpha-video-ffmpegkit.podspec`) |
| `react-native/` | `src/` (the components), `android/` (view managers; its Gradle module compiles `android/` too), `ios/` (subclasses of the iOS views with React props) | npm `react-native-alpha-video-ffmpegkit` (`package.json`, `react-native-alpha-video-ffmpegkit.podspec`) |
| `android/src/test/`, `ios/Tests/` | Unit tests (frame layout, colour matrix, playback clock, source loading): `npm run test:android` (JUnit) and `npm run test:ios` (XCTest on an iPhone simulator; `SIMULATOR_ID` picks one). Not in the npm package | |
| `scripts/publish-android.sh` | `local` publishes the Android library to `~/.m2`; `central` signs it and uploads it to the Maven Central Portal (see the script for the variables) | |

A release is the tag `v<version>`: Swift Package Manager resolves it, and `alpha-video-ffmpegkit.podspec` fetches its sources from it. After pushing the tag, `pod trunk push alpha-video-ffmpegkit.podspec` (only while trunk accepts new versions).

## Requirements

- React Native 0.71+
- Android: minSdkVersion 24; compileSdkVersion and targetSdkVersion come from the app (default 36)
- iOS: iOS 13.0+

## Demo and related packages

[alpha-video-test](https://github.com/MediaCacheDev/alpha-video-test) is a React Native app (Android, iOS and web) that plays the same video in each of these formats side by side, this player included, with FPS, CPU and memory readouts.

- [alpha-video](https://github.com/MediaCacheDev/alpha-video): the recommended WebM player, with the smallest files. Standard alpha WebM in VP8 or VP9, and dual-stream WebM with colour and alpha as separate VP8, VP9 or AV1 tracks. MediaCodec in hardware on Android where it can, a C++ core with libvpx and dav1d on Android and iOS, and `<video>`, WebCodecs or WebAssembly on the web.
- [alpha-video-gpu](https://github.com/MediaCacheDev/alpha-video-gpu): the highest performance. ASTC texture arrays in KTX2 go to the GPU as they are, with nothing to decode, so it uses the least CPU and battery and plays many clips at once. The files are larger than WebM. Android, iOS and web.
- [alpha-video-gpu-encoder](https://github.com/MediaCacheDev/alpha-video-gpu-encoder): makes alpha-video-gpu's KTX2 files from video files or PNG sequences, encoding the frames to ASTC.
- [react-native-apng-avif](https://github.com/MediaCacheDev/react-native-apng-avif): animated APNG and AVIF with alpha, for short clips.
- [alpha-glow-button](https://github.com/MediaCacheDev/alpha-glow-button): buttons whose glow is a transparent video or animated image.

## License

The code in this repository is MIT. The FFmpegKit and FFmpeg binaries it depends on are LGPL-3.0, and libvpx is BSD-3-Clause; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

- [FFmpegKit](https://github.com/arthenica/ffmpeg-kit) - FFmpeg for mobile
- [libvpx](https://chromium.googlesource.com/webm/libvpx) - VP9 decoder
