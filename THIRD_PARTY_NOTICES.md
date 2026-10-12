# Third-party notices

The code in this repository is MIT-licensed (see `LICENSE`). The FFmpegKit binaries it uses, [ffmpegkit-vp9](https://github.com/MediaCacheDev/ffmpegkit-vp9) 6.0.0, are not:

| Component | Version | Licence | Where |
|---|---|---|---|
| [FFmpegKit](https://github.com/arthenica/ffmpeg-kit) | commit `1036d3c` | LGPL-3.0 | iOS: `ffmpegkit.xcframework` in the `ffmpegkit-vp9` pod; Android: `dev.mediacache:ffmpegkit-vp9` |
| [FFmpeg](https://ffmpeg.org) (arthenica's fork, tag `n6.0`) | 6.0 | LGPL-3.0-or-later | iOS: `lib*.xcframework` in the `ffmpegkit-vp9` pod; inside `dev.mediacache:ffmpegkit-vp9` |
| [libvpx](https://chromium.googlesource.com/webm/libvpx) (arthenica's fork, tag `v1.13.0`) | 1.13.0 | BSD-3-Clause, plus the WebM patent grant | linked into libavcodec |
| [cpu_features](https://github.com/google/cpu_features) (arthenica's fork, tag `v0.8.0`) | 0.8.0 | Apache-2.0 | Android only, linked into the FFmpegKit libraries |

Licence texts: `licenses/LGPL-3.0.txt`, `licenses/GPL-3.0.txt` (LGPL-3.0 is written as additional permissions on top of GPL-3.0), `licenses/libvpx-LICENSE.txt`, `licenses/libvpx-PATENTS.txt`, `licenses/cpu_features-LICENSE.txt`.

## What the build contains

FFmpeg is configured with `--disable-everything` and only the components the player uses: the Matroska/WebM demuxer, the VP9 parser, the libvpx VP9 decoder, the rawvideo encoder and muxer, the file and pipe protocols, and the filters FFmpeg's command line needs to build a filter graph. No GPL code is enabled (no `--enable-gpl`). The exact options and the scripts that reproduce the binaries are in the [ffmpegkit-vp9](https://github.com/MediaCacheDev/ffmpegkit-vp9) repository.

## Source code

The complete corresponding source (ffmpeg-kit at the commit above, FFmpeg 6.0, libvpx 1.13.0 and cpu_features 0.8.0 as fetched by ffmpeg-kit, and the build scripts) is attached to the release at <https://github.com/MediaCacheDev/ffmpegkit-vp9/releases/tag/6.0.0>.

## Replacing the libraries

On Android the FFmpeg libraries are separate `.so` files in the AAR, and on iOS they are dynamic frameworks, so an app's users can swap in their own builds. LGPL-3.0 also asks for "installation information" on consumer devices where that is otherwise impossible, which applies to iOS App Store apps. If that matters for your app, prefer a player that links LGPL-2.1 FFmpeg.
