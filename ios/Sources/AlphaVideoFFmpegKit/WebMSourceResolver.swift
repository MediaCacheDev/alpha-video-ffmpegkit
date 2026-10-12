import Foundation
import CryptoKit

struct WebMSourceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Turns a source URI into a local file path FFmpeg can open.
///
/// - `https://` / `http://`: downloaded once into Caches, named by `cacheKey` or a SHA-256 of the URL
/// - `file:///abs/path`, `/abs/path`: used in place
/// - `asset://relative/path`: the app bundle's resource folder, used in place
enum WebMSourceResolver {

    /// Names a clip for the decoded-frame caches. Query strings are left out of http(s) URLs so
    /// presigned links that change per request still hit.
    static func identity(for uri: String, cacheKey: String?) -> String {
        if let key = cacheKey, !key.isEmpty { return key }
        if uri.hasPrefix("https://") || uri.hasPrefix("http://"),
           let url = URL(string: uri), let host = url.host {
            return host + url.path
        }
        return uri
    }

    /// Blocks while downloading, so call it off the main thread.
    static func localPath(for uri: String, cacheKey: String?, isCancelled: () -> Bool) throws -> String {
        let path: String
        if uri.hasPrefix("https://") || uri.hasPrefix("http://") {
            path = try download(uri, cacheKey: cacheKey, isCancelled: isCancelled)
        } else if uri.hasPrefix("asset://") {
            let relative = String(uri.dropFirst("asset://".count)).removingPercentEncoding ?? ""
            let trimmed = relative.drop(while: { $0 == "/" })
            guard !trimmed.isEmpty, let resources = Bundle.main.resourcePath else {
                throw WebMSourceError(message: "Bad asset URI: \(uri)")
            }
            path = (resources as NSString).appendingPathComponent(String(trimmed))
        } else if uri.hasPrefix("file://") {
            guard let url = URL(string: uri), url.isFileURL else {
                throw WebMSourceError(message: "Bad file URI: \(uri)")
            }
            path = url.path
        } else if uri.hasPrefix("/") {
            path = uri
        } else {
            throw WebMSourceError(message: "Unsupported source '\(uri)'. Use https://, file://, an absolute path or asset://")
        }

        guard FileManager.default.fileExists(atPath: path) else {
            throw WebMSourceError(message: "File not found: \(uri)")
        }
        return path
    }

    private static func download(_ uri: String, cacheKey: String?, isCancelled: () -> Bool) throws -> String {
        guard let url = URL(string: uri) else { throw WebMSourceError(message: "Bad URL: \(uri)") }
        let cacheFile = try cacheFileURL(for: uri, cacheKey: cacheKey)
        let fileManager = FileManager.default
        if let size = (try? fileManager.attributesOfItem(atPath: cacheFile.path))?[.size] as? Int, size > 0 {
            return cacheFile.path
        }
        try fileManager.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)

        let semaphore = DispatchSemaphore(value: 0)
        var failure: String?
        let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
            defer { semaphore.signal() }
            if let error = error {
                failure = error.localizedDescription
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let tempURL = tempURL else {
                failure = "HTTP \(status) for \(uri)"
                return
            }
            // The temp file is deleted when this handler returns, so it has to move now. Another
            // view may have finished the same download first; its file is just as good.
            do {
                try fileManager.moveItem(at: tempURL, to: cacheFile)
            } catch {
                if !fileManager.fileExists(atPath: cacheFile.path) { failure = error.localizedDescription }
            }
        }
        task.resume()
        while semaphore.wait(timeout: .now() + 0.25) == .timedOut {
            if isCancelled() {
                task.cancel()
                semaphore.wait()
                throw WebMSourceError(message: "Download cancelled")
            }
        }
        if let failure = failure { throw WebMSourceError(message: "Download failed: \(failure)") }
        return cacheFile.path
    }

    private static func cacheFileURL(for uri: String, cacheKey: String?) throws -> URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].standardizedFileURL
        guard let key = cacheKey, !key.isEmpty else {
            let digest = SHA256.hash(data: Data(uri.utf8)).map { String(format: "%02x", $0) }.joined()
            return cacheDir.appendingPathComponent("webm_\(digest).webm")
        }
        let file = cacheDir.appendingPathComponent(key).standardizedFileURL
        guard file.path.hasPrefix(cacheDir.path + "/") else {
            throw WebMSourceError(message: "cacheKey must stay inside the cache directory: \(key)")
        }
        return file
    }
}
