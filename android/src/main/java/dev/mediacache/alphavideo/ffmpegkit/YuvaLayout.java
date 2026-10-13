package dev.mediacache.alphavideo.ffmpegkit;

/**
 * Where each plane sits in one frame of FFmpeg's {@code -f rawvideo -pix_fmt yuva420p} output:
 * Y, U, V and A back to back with no row padding. The chroma planes are half size rounded up,
 * so an odd width or height still gets its last column and row.
 */
final class YuvaLayout {

    final int width;
    final int height;
    final int uvWidth;
    final int uvHeight;
    final int ySize;
    final int uvSize;
    final int uOffset;
    final int vOffset;
    final int aOffset;
    final int frameSize;

    YuvaLayout(int width, int height) {
        this.width = width;
        this.height = height;
        uvWidth = (width + 1) / 2;
        uvHeight = (height + 1) / 2;
        ySize = width * height;
        uvSize = uvWidth * uvHeight;
        uOffset = ySize;
        vOffset = uOffset + uvSize;
        aOffset = vOffset + uvSize;
        frameSize = aOffset + ySize;
    }
}
