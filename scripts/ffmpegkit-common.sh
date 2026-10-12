#!/bin/bash
#
# Shared by build-ffmpeg-android.sh and build-ffmpeg-ios.sh. Source it, don't run it.
#
# Builds the archived arthenica/ffmpeg-kit at a fixed commit (FFmpeg 6.0, libvpx 1.13.0),
# configured with only what the player runs:
#
#   ffmpeg  -c:v libvpx-vp9 -i <file|pipe> -an [-vf format=rgba | -pix_fmt yuva420p] -f rawvideo <file>
#   ffprobe -select_streams v:0 -show_entries stream=width,height,r_frame_rate <file|pipe>
#

FFMPEG_KIT_REPO="https://github.com/arthenica/ffmpeg-kit.git"
FFMPEG_KIT_COMMIT="1036d3cff1dff74a8ef55b71dd08d2495fdb386a"

# Where the exact sources of a published build can be downloaded (LGPL-3.0 section 4).
FFMPEGKIT_VP9_SOURCE_URL="${FFMPEGKIT_VP9_SOURCE_URL:-https://github.com/danielkpl2/react-native-webm-alpha-player-java-swift/releases}"

# Appended after ffmpeg-kit's own configure options, so --disable-everything comes after its
# --enable-libvpx. That's fine: --disable-everything only turns off FFmpeg's built-in
# components (codecs, formats, filters, protocols...), not external libraries.
# ffmpeg's CLI builds its filter graphs from buffer/buffersink/format/null/scale and the
# rotation/trim filters, so those stay in even though the player never names them.
MINIMAL_CONFIGURE_FLAGS="--disable-everything --disable-network \
--enable-demuxer=matroska \
--enable-parser=vp9 \
--enable-decoder=libvpx_vp9 \
--enable-encoder=rawvideo --enable-muxer=rawvideo \
--enable-filter=buffer,buffersink,format,null,scale,trim,transpose,hflip,vflip,abuffer,abuffersink,aformat,anull,aresample,atrim \
--enable-protocol=file,pipe"

# Clones ffmpeg-kit into ./ffmpeg-kit (if missing) and checks out the pinned commit.
checkout_ffmpeg_kit() {
    if [ ! -d ffmpeg-kit ]; then
        echo "📥 Cloning FFmpegKit..."
        git clone --filter=blob:none "$FFMPEG_KIT_REPO" ffmpeg-kit
    fi
    if [ "$(git -C ffmpeg-kit rev-parse HEAD)" != "$FFMPEG_KIT_COMMIT" ]; then
        git -C ffmpeg-kit fetch --filter=blob:none origin "$FFMPEG_KIT_COMMIT"
        git -C ffmpeg-kit checkout -q "$FFMPEG_KIT_COMMIT"
    fi
}

# $1: android | apple. Run from inside ffmpeg-kit/.
apply_minimal_config() {
    local script="scripts/$1/ffmpeg.sh"
    git checkout -q -- "$script"
    # Both platforms end their ./configure call with this exact line.
    sed -i '' 's|^  \${CONFIGURE_POSTFIX} 1>>"\${BASEDIR}"/build.log 2>&1$|  ${CONFIGURE_POSTFIX} '"$MINIMAL_CONFIGURE_FLAGS"' 1>>"${BASEDIR}"/build.log 2>\&1|' "$script"
    if ! grep -q -- "--disable-everything" "$script"; then
        echo "❌ Could not add the minimal configure flags to $script"
        exit 1
    fi
}

# ffmpeg-kit ships tools/source/SOURCE (as source.txt in the AAR, SOURCE in the frameworks),
# which points at arthenica. Whoever distributes the binaries has to offer the source.
# $1: android|apple. cpu_features is only part of the Android build.
write_source_notice() {
    local cpu_features=""
    if [ "$1" = "android" ]; then
        cpu_features="
  cpu_features  Apache-2.0         0.8.0"
    fi
    cat > tools/source/SOURCE <<EOF
This package contains FFmpegKit, FFmpeg and libvpx, built and distributed as
dev.mediacache:ffmpegkit-vp9 (Android) and the ffmpegkit-vp9 XCFrameworks (iOS).

  FFmpegKit     LGPL-3.0           commit ${FFMPEG_KIT_COMMIT}
  FFmpeg        LGPL-3.0-or-later  6.0
  libvpx        BSD-3-Clause       1.13.0${cpu_features}

The complete corresponding source code, including the build scripts and the
configure options used, is available at:

  ${FFMPEGKIT_VP9_SOURCE_URL}
EOF
}
