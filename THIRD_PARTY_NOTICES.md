# Third-party notices

The code in this repository is MIT-licensed (see `LICENSE`). The FFmpegKit binaries it uses are not:

| Component | Version | Licence | Where |
|---|---|---|---|
| [FFmpegKit](https://github.com/arthenica/ffmpeg-kit) | commit `1036d3c` | LGPL-3.0 | `ios/Frameworks/ffmpegkit.xcframework`; Android: `dev.mediacache:ffmpegkit-vp9` |
| [FFmpeg](https://ffmpeg.org) (arthenica's fork, tag `n6.0`) | 6.0 | LGPL-3.0-or-later | `ios/Frameworks/lib*.xcframework`; inside `dev.mediacache:ffmpegkit-vp9` |
| [libvpx](https://chromium.googlesource.com/webm/libvpx) (arthenica's fork, tag `v1.13.0`) | 1.13.0 | BSD-3-Clause, plus the WebM patent grant | linked into libavcodec |
| [cpu_features](https://github.com/google/cpu_features) (arthenica's fork, tag `v0.8.0`) | 0.8.0 | Apache-2.0 | Android only, linked into the FFmpegKit libraries |

Licence texts: `licenses/LGPL-3.0.txt`, `licenses/GPL-3.0.txt` (LGPL-3.0 is written as additional permissions on top of GPL-3.0), `licenses/libvpx-LICENSE.txt`, `licenses/libvpx-PATENTS.txt`, `licenses/cpu_features-LICENSE.txt`.

## What the build contains

FFmpeg is configured with `--disable-everything` and only the components the player uses: the Matroska/WebM demuxer, the VP9 parser, the libvpx VP9 decoder, the rawvideo encoder and muxer, the file and pipe protocols, and the filters FFmpeg's command line needs to build a filter graph. No GPL code is enabled (no `--enable-gpl`). The exact options are in `scripts/ffmpegkit-common.sh`, and `scripts/build-ffmpeg-android.sh` and `scripts/build-ffmpeg-ios.sh` reproduce the binaries.

## Source code

The complete corresponding source (ffmpeg-kit at the commit above, FFmpeg 6.0, libvpx 1.13.0 and cpu_features 0.8.0 as fetched by ffmpeg-kit, and these build scripts) is attached to each release at <https://github.com/danielkpl2/react-native-webm-alpha-player-java-swift/releases>.

## Replacing the libraries

On Android the FFmpeg libraries are separate `.so` files in the AAR, and on iOS they are dynamic frameworks, so an app's users can swap in their own builds. LGPL-3.0 also asks for "installation information" on consumer devices where that is otherwise impossible, which applies to iOS App Store apps. If that matters for your app, prefer a player that links LGPL-2.1 FFmpeg.
