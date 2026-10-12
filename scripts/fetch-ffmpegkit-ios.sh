#!/bin/bash
#
# fetch-ffmpegkit-ios.sh
# Downloads the ffmpegkit-vp9 XCFrameworks (https://github.com/MediaCacheDev/ffmpegkit-vp9)
# into ios/Frameworks, where the podspec vendors them. Run it once after cloning; the npm
# package already contains them. Android gets the same build from Maven Central.
#

set -euo pipefail

VERSION="6.0.0"
SHA256="9902bdcda1e0219c4077ced90c01602ca1c0f63cf7560b2359f034ae2f1573d5"
URL="https://github.com/MediaCacheDev/ffmpegkit-vp9/releases/download/$VERSION/ffmpegkit-vp9-$VERSION-ios-xcframeworks.zip"

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ios" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "📥 $URL"
curl -fsSL -o "$TMP/frameworks.zip" "$URL"
echo "$SHA256  $TMP/frameworks.zip" | shasum -a 256 -c --status || {
    echo "❌ Checksum mismatch"
    exit 1
}

rm -rf "$IOS_DIR/Frameworks"
unzip -q "$TMP/frameworks.zip" -d "$IOS_DIR"
echo "✅ $IOS_DIR/Frameworks"
ls -1 "$IOS_DIR/Frameworks"
