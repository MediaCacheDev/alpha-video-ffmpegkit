#!/bin/bash
#
# build-ffmpeg-android.sh
# Builds FFmpegKit for Android with minimal VP9-only config
# Produces an AAR with Java bindings for FFmpegKit API
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/build/android"
OUTPUT_DIR="$PROJECT_DIR/android/libs"

# Check prerequisites
if [ -z "$ANDROID_SDK_ROOT" ]; then
    # Try common locations
    if [ -n "$ANDROID_HOME" ]; then
        export ANDROID_SDK_ROOT="$ANDROID_HOME"
    elif [ -d "$HOME/Library/Android/sdk" ]; then
        export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
    elif [ -d "$HOME/Android/Sdk" ]; then
        export ANDROID_SDK_ROOT="$HOME/Android/Sdk"
    fi
fi

if [ -z "$ANDROID_SDK_ROOT" ] || [ ! -d "$ANDROID_SDK_ROOT" ]; then
    echo "❌ Android SDK not found"
    echo "   Set ANDROID_SDK_ROOT to your SDK installation path"
    exit 1
fi

if [ -z "$ANDROID_NDK_HOME" ]; then
    # Try to find NDK in common locations
    if [ -d "$ANDROID_SDK_ROOT/ndk" ]; then
        export ANDROID_NDK_HOME=$(ls -d "$ANDROID_SDK_ROOT/ndk"/*/ 2>/dev/null | head -1 | sed 's:/$::')
    elif [ -d "$ANDROID_HOME/ndk" ]; then
        export ANDROID_NDK_HOME=$(ls -d "$ANDROID_HOME/ndk"/*/ 2>/dev/null | head -1 | sed 's:/$::')
    fi
fi

if [ -z "$ANDROID_NDK_HOME" ] || [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "❌ Android NDK not found"
    echo "   Set ANDROID_NDK_HOME to your NDK installation path"
    exit 1
fi

# FFmpegKit uses ANDROID_NDK_ROOT instead of ANDROID_NDK_HOME
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"

echo "========================================"
echo "Building FFmpegKit for Android (VP9 only)"
echo "========================================"
echo "SDK: $ANDROID_SDK_ROOT"
echo "NDK: $ANDROID_NDK_HOME"
echo "Build dir: $BUILD_DIR"
echo "Output: $OUTPUT_DIR"
echo ""

mkdir -p "$BUILD_DIR"
mkdir -p "$OUTPUT_DIR"

cd "$BUILD_DIR"

# Clone FFmpegKit if needed
if [ ! -d "ffmpeg-kit" ]; then
    echo "📥 Cloning FFmpegKit..."
    git clone --depth 1 https://github.com/arthenica/ffmpeg-kit.git
fi

cd ffmpeg-kit

# Patch Android.mk to fix NDK 26+ compatibility
# (newer NDK treats certain warnings as errors)
if [ -f "android/jni/Android.mk" ]; then
    echo "🔧 Patching Android.mk for NDK 26+ compatibility..."
    sed -i '' 's/-Werror/-Wno-error/g' android/jni/Android.mk
fi

echo ""
echo "🔨 Building FFmpegKit (this may take 30-60 minutes)..."
echo ""
echo "Configuration:"
echo "  - VP9 decoder (libvpx)"
echo "  - WebM/Matroska demuxer"
echo "  - File protocol"
echo ""

# Build with libvpx enabled for VP9 decoding
# Disable x86 (32-bit) since it's rarely used
# Keep: arm64-v8a, armeabi-v7a, armeabi-v7a-neon, x86_64
./android.sh \
    --enable-libvpx \
    --disable-x86

# Find and copy the built AAR
echo ""
echo "📦 Copying AAR to output directory..."

AAR_PATH=$(find ./prebuilt -name "ffmpeg-kit*.aar" -type f 2>/dev/null | head -1)

if [ -z "$AAR_PATH" ]; then
    # Try alternative locations
    AAR_PATH=$(find . -path "*/outputs/aar/*.aar" -type f 2>/dev/null | head -1)
fi

if [ -n "$AAR_PATH" ]; then
    cp "$AAR_PATH" "$OUTPUT_DIR/ffmpegkit.aar"
    echo "✅ Built: $OUTPUT_DIR/ffmpegkit.aar"
    echo "   Size: $(du -h "$OUTPUT_DIR/ffmpegkit.aar" | cut -f1)"
else
    echo "❌ Error: Could not find built AAR"
    echo "Looking for AAR files..."
    find . -name "*.aar" -type f 2>/dev/null | head -10
    exit 1
fi

echo ""
echo "========================================"
echo "✅ Android FFmpegKit build complete!"
echo "========================================"
echo ""
echo "AAR location: $OUTPUT_DIR/ffmpegkit.aar"
echo ""
echo "Architectures:"
echo "  - arm64-v8a"
echo "  - armeabi-v7a"
echo "  - x86_64"
echo ""
echo "To use this AAR instead of Maven dependency:"
echo "1. In android/build.gradle, comment out the Maven dependency"
echo "2. Uncomment: implementation fileTree(dir: 'libs', include: ['*.aar'])"
echo ""
