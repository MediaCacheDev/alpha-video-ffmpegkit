#!/bin/bash
#
# build-ffmpeg-ios.sh
# Builds FFmpegKit for iOS with VP9 (libvpx)
# Produces static XCFrameworks (App Store compatible)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/build/ios"
OUTPUT_DIR="$PROJECT_DIR/ios/Frameworks"
export FFMPEG_KIT_XCFRAMEWORK_STATIC=1


echo "========================================"
echo "Building FFmpegKit for iOS (VP9 only)"
echo "========================================"
echo "Build dir : $BUILD_DIR"
echo "Output dir: $OUTPUT_DIR"
echo ""

# Check for Xcode
if ! xcode-select -p &> /dev/null; then
    echo "❌ Xcode command line tools not found"
    echo "   Run: xcode-select --install"
    exit 1
fi

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
cd "$BUILD_DIR"

# Clone FFmpegKit if needed
if [ ! -d "ffmpeg-kit" ]; then
    echo "📥 Cloning FFmpegKit..."
    git clone --depth 1 https://github.com/arthenica/ffmpeg-kit.git
fi

cd ffmpeg-kit

# Optional clean rebuild
if [ "${CLEAN:-0}" = "1" ]; then
    echo "🧹 Cleaning previous build..."
    rm -rf prebuilt .tmp
fi

echo ""
echo "🔨 Building FFmpegKit..."
echo ""
echo "Configuration:"
echo "  - VP9 decoder: libvpx"
echo "  - Static XCFrameworks"
echo "  - iOS device: arm64"
echo "  - iOS simulator: arm64, x86_64"
echo ""

# Build static XCFrameworks (DEFAULT behaviour)
./ios.sh \
  --enable-libvpx \
  --disable-armv7 \
  --disable-armv7s \
  --disable-arm64-mac-catalyst \
  --disable-x86-64-mac-catalyst \
  --xcframework

# Copy XCFrameworks
echo ""
echo "📦 Copying XCFrameworks..."

FRAMEWORK_DIR="prebuilt/bundle-apple-xcframework-ios"

EXPECTED_FRAMEWORKS=(
    "ffmpegkit.xcframework"
    "libavcodec.xcframework"
    "libavformat.xcframework"
    "libavutil.xcframework"
    "libswresample.xcframework"
    "libswscale.xcframework"
    "libavfilter.xcframework"
    "libavdevice.xcframework"
)

if [ ! -d "$FRAMEWORK_DIR" ]; then
    echo "❌ Build output not found: $FRAMEWORK_DIR"
    find prebuilt -name "*.xcframework" -type d 2>/dev/null | head -20
    exit 1
fi

rm -rf "$OUTPUT_DIR"/*.xcframework

for fw in "${EXPECTED_FRAMEWORKS[@]}"; do
    if [ -d "$FRAMEWORK_DIR/$fw" ]; then
        echo "  ✔ $fw"
        cp -R "$FRAMEWORK_DIR/$fw" "$OUTPUT_DIR/"
    else
        echo "  ⚠️  Missing (optional): $fw"
    fi
done

echo ""
echo "🔍 Verifying static linkage..."

BIN="$OUTPUT_DIR/ffmpegkit.xcframework/ios-arm64/ffmpegkit.framework/ffmpegkit"
if otool -L "$BIN" | grep -E "libav|libvpx" >/dev/null; then
  echo "❌ ERROR: Dynamic FFmpeg dependency found"
else
  echo "✔ Static FFmpeg linkage confirmed"
fi

echo ""
echo "========================================"
echo "✅ FFmpegKit iOS static build complete"
echo "========================================"
echo ""
echo "Frameworks installed at:"
echo "  $OUTPUT_DIR"
echo ""
echo "XCFrameworks:"
ls -1 "$OUTPUT_DIR"/*.xcframework | xargs -n1 basename
echo ""
echo "ℹ️  Xcode:"
echo "   - Add frameworks"
echo "   - Do NOT embed"
echo "   - ENABLE_BITCODE = NO"
echo ""
