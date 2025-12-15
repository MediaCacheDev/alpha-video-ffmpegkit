# react-native-webm-alpha-player

A React Native library for playing VP9+Alpha WebM videos with transparency support.

## Features

- 🎬 **VP9 + Alpha channel support** - Play WebM videos with transparency
- ⚡ **GPU acceleration** - OpenGL ES (Android) / Metal (iOS) for fast YUV→RGB conversion
- 🔄 **CPU fallback** - Bitmap/UIImage-based rendering for maximum compatibility
- 📦 **Automatic caching** - Downloads and caches remote videos
- 🔁 **Loop & pause controls** - Full playback control
- 📱 **Cross-platform** - Works on both Android and iOS

## Installation

```bash
npm install react-native-webm-alpha-player
# or
yarn add react-native-webm-alpha-player
```

### iOS Setup

```bash
cd ios && pod install
```

### Android Setup

No additional setup needed - the AAR is bundled.

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
import { WebMAlphaView } from 'react-native-webm-alpha-player';

function MyComponent() {
  return (
    <WebMAlphaView
      source="https://example.com/animation.webm"
      style={{ width: 200, height: 200 }}
    />
  );
}
```

### CPU Mode (simpler, more compatible)

```jsx
import { WebMAlphaView } from 'react-native-webm-alpha-player';

function MyComponent() {
  return (
    <WebMAlphaView
      source="https://example.com/animation.webm"
      useGPU={false}
      style={{ width: 200, height: 200 }}
    />
  );
}
```

### With Playback Controls

```jsx
import { WebMAlphaView } from 'react-native-webm-alpha-player';
import { useState } from 'react';

function MyComponent() {
  const [paused, setPaused] = useState(false);

  return (
    <>
      <WebMAlphaView
        source="https://example.com/animation.webm"
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
import { WebMAlphaGPUView } from 'react-native-webm-alpha-player';

// Use CPU view directly
import { WebMAlphaCPUView } from 'react-native-webm-alpha-player';
```

## Props

| Prop | Type | Default | Description |
|------|------|---------|-------------|
| `source` | `string` | required | URL or local file path to WebM file |
| `autoPlay` | `boolean` | `true` | Start playing automatically |
| `loop` | `boolean` | `true` | Loop the animation |
| `paused` | `boolean` | `false` | Pause the animation |
| `useGPU` | `boolean` | `true` | Use GPU acceleration |
| `style` | `ViewStyle` | - | View style |

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
- **Protocols:** HTTP, HTTPS, file://

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
