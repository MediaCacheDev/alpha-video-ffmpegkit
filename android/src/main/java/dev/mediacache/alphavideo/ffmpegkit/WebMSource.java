package dev.mediacache.alphavideo.ffmpegkit;

import android.content.Context;
import android.content.res.Resources;
import android.net.Uri;

import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.util.regex.Pattern;

/**
 * A local video: a file, an APK asset, a raw resource, or a content:// URI.
 *
 * Files are handed to FFmpeg by path. The other kinds aren't files of their own, so they are
 * streamed to FFmpeg through a pipe ({@link FFmpegInput}) instead of being copied out first.
 * Remote URLs are not sources; {@link WebMDownloader} fetches them and they play as files.
 */
final class WebMSource {

    private enum Kind { FILE, ASSET, RAW, CONTENT }

    private static final String ASSET_SCHEME = "asset://";
    // What Image.resolveAssetSource(require(...)) gives in a release build: a res/raw name
    private static final Pattern RAW_RESOURCE_NAME = Pattern.compile("[A-Za-z_][A-Za-z0-9_]*");

    private final Kind kind;
    private final String location;

    private WebMSource(Kind kind, String location) {
        this.kind = kind;
        this.location = location;
    }

    static WebMSource file(String path) {
        return new WebMSource(Kind.FILE, path);
    }

    /**
     * Parses {@code file:///abs/path}, {@code /abs/path}, {@code asset://relative/path},
     * {@code content://...}, or a bare res/raw resource name.
     *
     * @throws IllegalArgumentException for anything else
     */
    static WebMSource parse(String uri) {
        if (uri.startsWith(ASSET_SCHEME)) {
            String path = Uri.decode(uri.substring(ASSET_SCHEME.length()));
            while (path.startsWith("/")) path = path.substring(1);
            if (path.isEmpty()) throw new IllegalArgumentException("Empty asset path: " + uri);
            return new WebMSource(Kind.ASSET, path);
        }
        if (uri.startsWith("content://")) {
            return new WebMSource(Kind.CONTENT, uri);
        }
        if (uri.startsWith("file://")) {
            String path = Uri.parse(uri).getPath();
            if (path == null || path.isEmpty()) throw new IllegalArgumentException("Bad file URI: " + uri);
            return file(path);
        }
        if (uri.startsWith("/")) {
            return file(uri);
        }
        if (RAW_RESOURCE_NAME.matcher(uri).matches()) {
            return new WebMSource(Kind.RAW, uri);
        }
        throw new IllegalArgumentException(
            "Unsupported source '" + uri + "'. Use https://, file://, an absolute path, asset:// or content://");
    }

    boolean isFile() {
        return kind == Kind.FILE;
    }

    /** Only meaningful for {@link #isFile()} sources. */
    String path() {
        return location;
    }

    InputStream openStream(Context context) throws IOException {
        switch (kind) {
            case ASSET:
                return context.getAssets().open(location);
            case RAW: {
                Resources resources = context.getResources();
                int id = resources.getIdentifier(location, "raw", context.getPackageName());
                if (id == 0) throw new FileNotFoundException("No res/raw resource named " + location);
                return resources.openRawResource(id);
            }
            case CONTENT: {
                InputStream in = context.getContentResolver().openInputStream(Uri.parse(location));
                if (in == null) throw new FileNotFoundException("Cannot open " + location);
                return in;
            }
            default:
                return new FileInputStream(location);
        }
    }

    @Override
    public String toString() {
        switch (kind) {
            case ASSET: return ASSET_SCHEME + location;
            case RAW: return "res/raw/" + location;
            default: return location;
        }
    }
}
