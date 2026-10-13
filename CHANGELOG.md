# Changelog

The packages built from this repository share one version: `react-native-alpha-video-ffmpegkit` on npm, `dev.mediacache:alpha-video-ffmpegkit` on Maven Central, and the `AlphaVideoFFmpegKit` Swift package and `alpha-video-ffmpegkit` pod.

## 1.0.0 - Unreleased

First public release.

- Plays VP9 WebM with alpha on Android and iOS, decoding with FFmpegKit from plain Java and Swift. It uses a minimal FFmpegKit 6.0 build, `ffmpegkit-vp9` (Maven Central and CocoaPods trunk).
- Two views: GPU (OpenGL ES on Android, Metal on iOS, converting YUV on the GPU) and CPU (bitmaps).
- The GPU views convert with the clip's range and matrix (limited or full; BT.601, BT.709 or BT.2020), so blacks, whites and saturated colours match FFmpeg's own conversion. Odd frame sizes play correctly.
- Playback modes: `stream`, the default, decodes a few frames ahead with flat memory; `preload` decodes every frame first.
- Sources: `https://` (downloaded once into the cache, under `cacheKey`), `file://`, absolute paths, `asset://` (Android assets, the iOS bundle, the web root), and on Android `content://` and `res/raw` names. Bundled and `content://` sources are piped to FFmpeg, so nothing is copied to disk.
- Playback control: `seekToFrame` and `seekToTime`, plus `paused`, `autoPlay` and `loop`. Pausing holds the current frame. Events: `onLoad`, `onError` and `onEnd`.
- React Native: `FFmpegKitAlphaView`, `FFmpegKitAlphaGPUView` and `FFmpegKitAlphaCPUView`, on both the new architecture (Fabric) and the old one. On react-native-web they render a `<video>`.
- Standalone Android and iOS libraries with no React Native dependency.
- MIT, with FFmpegKit and FFmpeg under LGPL-3.0-or-later. Their notices are in `THIRD_PARTY_NOTICES.md`.
