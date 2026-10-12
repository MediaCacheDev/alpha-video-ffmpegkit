#!/bin/bash
#
# package-ffmpegkit-sources.sh
# Packs the complete corresponding source of the FFmpegKit binaries (LGPL-3.0 section 4) into
# scripts/build/release-sources/, to attach to the GitHub Release that ships them:
#
#   ffmpeg-kit-<commit>.tar.gz   ffmpeg-kit at the pinned commit
#   ffmpeg-n6.0.tar.gz           FFmpeg as ffmpeg-kit fetched it (arthenica/FFmpeg)
#   libvpx-v1.13.0.tar.gz        libvpx as ffmpeg-kit fetched it (arthenica/libvpx)
#   cpu-features-v0.8.0.tar.gz   cpu_features as ffmpeg-kit fetched it (Android only)
#   build-scripts.tar.gz         the scripts in this directory that configure and build them
#
# ffmpeg-kit's own scripts patch FFmpeg at build time, so the pristine trees plus ffmpeg-kit
# plus these scripts reproduce the binaries. Run after build-ffmpeg-android.sh (or the iOS
# script, which has no cpu_features), which leaves the source checkouts in the build tree.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ffmpegkit-common.sh"

KIT_DIR=""
for platform in android ios; do
    if [ -d "$SCRIPT_DIR/build/$platform/ffmpeg-kit/src/ffmpeg" ]; then
        KIT_DIR="$SCRIPT_DIR/build/$platform/ffmpeg-kit"
        break
    fi
done
if [ -z "$KIT_DIR" ]; then
    echo "❌ No ffmpeg-kit build tree with sources; run build-ffmpeg-ios.sh or build-ffmpeg-android.sh first"
    exit 1
fi

OUT="$SCRIPT_DIR/build/release-sources"
rm -rf "$OUT"
mkdir -p "$OUT"

# $1: repo, $2: ref that must be checked out, $3: archive name
archive_tree() {
    if [ "$(git -C "$1" rev-parse HEAD)" != "$(git -C "$1" rev-parse "$2^{commit}")" ]; then
        echo "❌ $1 is not at $2"
        exit 1
    fi
    git -C "$1" archive --format=tar.gz --prefix="$3/" -o "$OUT/$3.tar.gz" HEAD
    echo "  ✔ $3.tar.gz"
}

archive_tree "$KIT_DIR" "$FFMPEG_KIT_COMMIT" "ffmpeg-kit-${FFMPEG_KIT_COMMIT:0:7}"
archive_tree "$KIT_DIR/src/ffmpeg" "n6.0" "ffmpeg-n6.0"
archive_tree "$KIT_DIR/src/libvpx" "v1.13.0" "libvpx-v1.13.0"
if [ -d "$KIT_DIR/src/cpu-features" ]; then
    archive_tree "$KIT_DIR/src/cpu-features" "v0.8.0" "cpu-features-v0.8.0"
else
    echo "  ⚠️  no cpu-features checkout (iOS tree); run build-ffmpeg-android.sh for the Android source"
fi

tar -czf "$OUT/build-scripts.tar.gz" -C "$SCRIPT_DIR" \
    ffmpegkit-common.sh build-ffmpeg-android.sh build-ffmpeg-ios.sh package-ffmpegkit-sources.sh
echo "  ✔ build-scripts.tar.gz"

(cd "$OUT" && shasum -a 256 *.tar.gz > SHA256SUMS)
echo ""
echo "✅ $OUT"
cat "$OUT/SHA256SUMS"
