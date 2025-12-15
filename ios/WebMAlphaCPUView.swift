import UIKit
import AVFoundation
import ffmpegkit

/**
 * WebMAlphaCPUView - CPU-based VP9+Alpha WebM player for iOS
 *
 * Adapted from the proven AlphaWebMView implementation with NSDictionary source handling,
 * DispatchQueue-based playback timing, and frame caching.
 */

// MARK: - Shared Resources

/// Shared serial queue to limit concurrent FFmpeg operations (memory intensive)
private let sharedFFmpegQueue = DispatchQueue(label: "com.webmalphaplayer.ffmpeg", qos: .userInitiated)

/// Cache for decoded frame data (keyed by source URL hash)
private var frameCache = NSCache<NSString, FrameCacheEntry>()

/// Frame cache entry containing all decoded frames
private class FrameCacheEntry {
    let frames: [Data]
    let width: Int
    let height: Int
    let frameRate: Double

    init(frames: [Data], width: Int, height: Int, frameRate: Double) {
        self.frames = frames
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }
}

// Configure cache limits
private func configureFrameCache() {
    frameCache.countLimit = 10 // Max 10 videos cached
    frameCache.totalCostLimit = 100 * 1024 * 1024 // 100MB total limit
}

@objc(WebMAlphaCPUView)
public class WebMAlphaCPUView: UIView {

    private var imageView: UIImageView!

    private var source: String?
    private var sourceHash: String?
    private var autoPlay: Bool = true
    private var loop: Bool = true
    private var paused: Bool = false
    @objc public var cacheKey: String?

    private var isPlaying = false
    private var isDecoding = false
    private var shouldStop = false

    private var playbackQueue: DispatchQueue?
    private var downloadTask: URLSessionDataTask?

    // Video metadata
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0
    private var frameRate: Double = 30.0
    private var totalFrames: Int = 0

    // Memory warning observer
    private var memoryWarningObserver: NSObjectProtocol?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    
    private func commonInit() {
        backgroundColor = .clear
        clipsToBounds = true
        
        imageView = UIImageView(frame: bounds)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
        
        // Each view gets its own playback queue (for frame display timing)
        playbackQueue = DispatchQueue(label: "com.webmalphaplayer.playback.\(ObjectIdentifier(self).hashValue)", qos: .userInitiated)
        
        // Configure shared cache
        configureFrameCache()
        
        // Listen for memory warnings
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[WebMAlphaCPUView] Memory warning - clearing frame cache")
            frameCache.removeAllObjects()
            self?.stopPlayback()
        }
    }
    
    deinit {
        cleanup()
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
    }
    
    public override func removeFromSuperview() {
        cleanup()
        super.removeFromSuperview()
    }
    
    private func cleanup() {
        shouldStop = true
        downloadTask?.cancel()
        downloadTask = nil
        isPlaying = false
        isDecoding = false
    }
    
    @objc func setSource(_ value: NSDictionary?) {
        guard let dict = value else {
            cleanup()
            return
        }
        
        let uri = dict["uri"] as? String ?? dict["path"] as? String
        guard let uriString = uri, !uriString.isEmpty else {
            cleanup()
            return
        }
        
        // Compute hash for caching - use the path only (not query params) for stable keys
        // Extract path from URL to avoid presigned URL query params
        let pathOnly: String
        if let url = URL(string: uriString) {
            pathOnly = url.path
        } else {
            pathOnly = uriString
        }
        
        // Use djb2 hash for consistent, unique keys
        var hashValue: UInt64 = 5381
        for char in pathOnly.utf8 {
            hashValue = ((hashValue << 5) &+ hashValue) &+ UInt64(char)
        }
        let hashString = String(format: "%016llx", hashValue)
        
        print("[WebMAlphaCPUView] Source path: \(pathOnly)")
        print("[WebMAlphaCPUView] Frame cache key: \(hashString)")
        
        // If source changed, stop current playback
        if self.source != uriString {
            cleanup()
            shouldStop = false // Reset for new source
        }
        
        self.source = uriString
        self.sourceHash = hashString
        print("[WebMAlphaCPUView] setSource: \(uriString.prefix(80)), hash=\(hashString.prefix(8)), autoPlay=\(autoPlay), paused=\(paused)")
        
        if autoPlay && !paused && !isPlaying && !isDecoding {
            startPlayback()
        }
    }
    
    @objc func setAutoPlay(_ value: Bool) {
        autoPlay = value
        updatePlaybackState()
    }
    
    @objc func setLoop(_ value: Bool) {
        loop = value
    }
    
    @objc func setPaused(_ value: Bool) {
        paused = value
        updatePlaybackState()
    }
    
    private func updatePlaybackState() {
        print("[WebMAlphaCPUView] updatePlaybackState: paused=\(paused), autoPlay=\(autoPlay), isPlaying=\(isPlaying), isDecoding=\(isDecoding)")
        if paused {
            stopPlayback()
        } else if autoPlay && !isPlaying && !isDecoding && source != nil {
            startPlayback()
        }
    }
    
    private func startPlayback() {
        guard let source = source, let hash = sourceHash else {
            print("[WebMAlphaCPUView] startPlayback: no source")
            return
        }
        
        if isPlaying || isDecoding {
            print("[WebMAlphaCPUView] startPlayback: already playing or decoding")
            return
        }
        
        print("[WebMAlphaCPUView] startPlayback: starting for \(source.prefix(50))")
        
        shouldStop = false
        
        // Check if frames are already cached
        if let cached = frameCache.object(forKey: hash as NSString) {
            print("[WebMAlphaCPUView] Using cached frames for \(hash.prefix(8))")
            isPlaying = true
            videoWidth = cached.width
            videoHeight = cached.height
            frameRate = cached.frameRate
            playbackQueue?.async { [weak self] in
                self?.playFramesFromCache(cached.frames)
                DispatchQueue.main.async {
                    self?.isPlaying = false
                }
            }
            return
        }
        
        // Need to decode - use shared serial queue to prevent memory spikes
        isDecoding = true
        sharedFFmpegQueue.async { [weak self] in
            guard let self = self, !self.shouldStop else {
                DispatchQueue.main.async { self?.isDecoding = false }
                return
            }
            self.decodeAndPlay(source: source, hash: hash)
            DispatchQueue.main.async {
                self.isDecoding = false
            }
        }
    }
    
    private func stopPlayback() {
        shouldStop = true
        isPlaying = false
    }
    
    private func decodeAndPlay(source: String, hash: String) {
        var localPath = source
        
        // Download remote URLs to cache
        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            guard let downloaded = downloadToCache(urlString: source) else {
                print("[WebMAlphaCPUView] Failed to download video")
                return
            }
            localPath = downloaded
        } else if source.hasPrefix("file://") {
            localPath = String(source.dropFirst(7))
        }
        
        guard !shouldStop else { return }
        
        // Get video metadata using ffprobe
        guard probeVideo(path: localPath) else {
            print("[WebMAlphaCPUView] Failed to probe video")
            return
        }
        
        guard !shouldStop else { return }
        
        // Create temp directory for frames
        let framesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("webm-frames-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: framesDir)
        }
        
        // Extract all frames as RGBA using FFmpeg
        // CRITICAL: Use -c:v libvpx-vp9 to force VP9 decoder that supports alpha
        let rawFile = framesDir.appendingPathComponent("frames.rgba")
        
        let ffmpegCmd = "-c:v libvpx-vp9 -i \"\(localPath)\" -vf format=rgba -f rawvideo \"\(rawFile.path)\""
        
        print("[WebMAlphaCPUView] FFmpeg command: ffmpeg \(ffmpegCmd)")
        
        guard executeFFmpeg(command: ffmpegCmd) else {
            print("[WebMAlphaCPUView] FFmpeg failed")
            return
        }
        
        guard !shouldStop else { return }
        
        // Calculate frame info
        guard let fileSize = try? FileManager.default.attributesOfItem(atPath: rawFile.path)[.size] as? Int else {
            print("[WebMAlphaCPUView] Could not get file size")
            return
        }
        
        let frameSize = videoWidth * videoHeight * 4 // RGBA = 4 bytes per pixel
        totalFrames = fileSize / frameSize
        
        print("[WebMAlphaCPUView] Decoded \(totalFrames) frames, \(videoWidth)x\(videoHeight), ~\(fileSize / 1024 / 1024)MB raw")
        
        guard totalFrames > 0, !shouldStop else { return }
        
        // Read all frames into memory and cache them
        guard let fileHandle = try? FileHandle(forReadingFrom: rawFile) else {
            print("[WebMAlphaCPUView] Could not open raw file")
            return
        }
        
        var frames: [Data] = []
        frames.reserveCapacity(totalFrames)
        
        for _ in 0..<totalFrames {
            autoreleasepool {
                if let data = try? fileHandle.readData(ofLength: frameSize), data.count == frameSize {
                    frames.append(data)
                }
            }
        }
        
        try? fileHandle.close()
        
        guard frames.count > 0, !shouldStop else { return }
        
        // Cache the frames
        let cacheEntry = FrameCacheEntry(frames: frames, width: videoWidth, height: videoHeight, frameRate: frameRate)
        let cost = frames.reduce(0) { $0 + $1.count }
        frameCache.setObject(cacheEntry, forKey: hash as NSString, cost: cost)
        print("[WebMAlphaCPUView] Cached \(frames.count) frames for \(hash.prefix(8)), cost=\(cost / 1024)KB")
        
        // Decoding complete - start playback on the view's own playback queue
        // This frees up the shared FFmpeg queue for other videos to decode
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.shouldStop else { return }
            self.isPlaying = true
            self.playbackQueue?.async { [weak self] in
                self?.playFramesFromCache(frames)
                DispatchQueue.main.async {
                    self?.isPlaying = false
                }
            }
        }
    }
    
    private func playFramesFromCache(_ frames: [Data]) {
        let frameInterval: TimeInterval = 1.0 / frameRate
        
        repeat {
            var frameIndex = 0
            let startTime = CACurrentMediaTime()
            
            while !shouldStop && frameIndex < frames.count {
                autoreleasepool {
                    let data = frames[frameIndex]
                    
                    // Convert RGBA to UIImage and display
                    if let image = createImage(from: data) {
                        DispatchQueue.main.async { [weak self] in
                            guard self?.shouldStop != true else { return }
                            self?.imageView.image = image
                        }
                    }
                    
                    frameIndex += 1
                    
                    // Timing control
                    let targetTime = startTime + (Double(frameIndex) * frameInterval)
                    let sleepTime = targetTime - CACurrentMediaTime()
                    
                    if sleepTime > 0.001 { // > 1ms
                        Thread.sleep(forTimeInterval: sleepTime)
                    }
                }
            }
            
        } while loop && !shouldStop
        
        print("[WebMAlphaCPUView] Playback finished")
    }
    
    private func probeVideo(path: String) -> Bool {
        let probeCmd = "-v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=p=0 \"\(path)\""
        
        print("[WebMAlphaCPUView] FFprobe command: ffprobe \(probeCmd)")
        
        guard let output = executeFFprobe(command: probeCmd) else {
            return false
        }
        
        let trimmedOutput = output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else {
            return false
        }
        
        print("[WebMAlphaCPUView] FFprobe output: \(trimmedOutput)")
        
        // Parse output: width,height,fps_num/fps_den
        let lines = trimmedOutput.components(separatedBy: "\n")
        guard let lastLine = lines.last, !lastLine.isEmpty else { return false }
        
        let parts = lastLine.components(separatedBy: ",")
        guard parts.count >= 3 else { return false }
        
        guard let width = Int(parts[0].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)),
              let height = Int(parts[1].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)) else {
            return false
        }
        
        videoWidth = width
        videoHeight = height
        
        // Parse frame rate
        let fps = parts[2].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if fps.contains("/") {
            let fpsParts = fps.components(separatedBy: "/")
            if fpsParts.count == 2,
               let num = Double(fpsParts[0]),
               let den = Double(fpsParts[1]),
               den > 0 {
                frameRate = num / den
            }
        } else if let rate = Double(fps) {
            frameRate = rate
        }
        
        print("[WebMAlphaCPUView] Video: \(videoWidth)x\(videoHeight) @ \(frameRate)fps")
        return videoWidth > 0 && videoHeight > 0
    }
    
    private func createImage(from rgbaData: Data) -> UIImage? {
        let width = videoWidth
        let height = videoHeight
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        
        // FFmpeg outputs straight (non-premultiplied) alpha with format=rgba
        // iOS compositing expects premultiplied alpha for correct blending
        // We need to premultiply the alpha manually for proper glow rendering
        
        var premultipliedData = Data(count: rgbaData.count)
        rgbaData.withUnsafeBytes { srcPtr in
            premultipliedData.withUnsafeMutableBytes { dstPtr in
                let src = srcPtr.bindMemory(to: UInt8.self)
                let dst = dstPtr.bindMemory(to: UInt8.self)
                let pixelCount = width * height
                
                for i in 0..<pixelCount {
                    let offset = i * 4
                    let r = UInt16(src[offset])
                    let g = UInt16(src[offset + 1])
                    let b = UInt16(src[offset + 2])
                    let a = UInt16(src[offset + 3])
                    
                    // Premultiply: RGB = RGB * A / 255
                    dst[offset]     = UInt8((r * a + 127) / 255)
                    dst[offset + 1] = UInt8((g * a + 127) / 255)
                    dst[offset + 2] = UInt8((b * a + 127) / 255)
                    dst[offset + 3] = UInt8(a)
                }
            }
        }
        
        // Create CGContext with premultiplied RGBA data
        guard let provider = CGDataProvider(data: premultipliedData as CFData) else {
            return nil
        }
        
        // Use premultipliedLast for correct iOS compositing
        // This ensures semi-transparent glow edges render at full intensity
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bytesPerPixel * 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }
        
        return UIImage(cgImage: cgImage)
    }
    
    private func downloadToCache(urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        
        // Generate cache path
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        
        // Use cacheKey if provided, otherwise extract just the path component (without query params) for more stable caching
        // This prevents presigned URL expiry from causing re-downloads
        let cacheFile: URL
        if let cacheKey = cacheKey {
            // cacheKey represents the full path from cache directory
            // Create directory structure and file path
            let pathComponents = cacheKey.split(separator: "/").map { String($0) }
            var currentDir = cacheDir
            
            // Create intermediate directories (all parts except the last)
            for component in pathComponents.dropLast() {
                currentDir = currentDir.appendingPathComponent(component)
            }
            
            // Create the directory structure
            try? FileManager.default.createDirectory(at: currentDir, withIntermediateDirectories: true)
            
            // Use the last component as filename
            let fileName = pathComponents.last ?? "unknown"
            cacheFile = currentDir.appendingPathComponent(fileName)
        } else {
            // For hash-based caching, use webm-cache subdirectory
            let webmCacheDir = cacheDir.appendingPathComponent("webm-cache")
            try? FileManager.default.createDirectory(at: webmCacheDir, withIntermediateDirectories: true)
            
            let pathOnly = url.path
            
            // Use djb2 hash of the path to ensure unique cache files per video
            var hashValue: UInt64 = 5381
            for char in pathOnly.utf8 {
                hashValue = ((hashValue << 5) &+ hashValue) &+ UInt64(char)
            }
            let cacheFileName = String(format: "%016llx.webm", hashValue)
            cacheFile = webmCacheDir.appendingPathComponent(cacheFileName)
        }
        
        print("[WebMAlphaCPUView] Cache key for '\(url.path)' -> \(cacheFile.path)")
        
        // Check cache
        if FileManager.default.fileExists(atPath: cacheFile.path) {
            print("[WebMAlphaCPUView] Using cached: \(cacheFile.path)")
            return cacheFile.path
        }
        
        // Download synchronously (we're already on background thread)
        print("[WebMAlphaCPUView] Downloading: \(urlString.prefix(80))...")
        
        let semaphore = DispatchSemaphore(value: 0)
        var downloadedPath: String?
        
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            defer { semaphore.signal() }
            
            guard let data = data, error == nil else {
                print("[WebMAlphaCPUView] Download error: \(error?.localizedDescription ?? "unknown")")
                return
            }
            
            do {
                try data.write(to: cacheFile)
                print("[WebMAlphaCPUView] Downloaded to: \(cacheFile.path)")
                downloadedPath = cacheFile.path
            } catch {
                print("[WebMAlphaCPUView] Save error: \(error)")
            }
        }
        task.resume()
        
        _ = semaphore.wait(timeout: .now() + 60)
        return downloadedPath
    }
    
    // FFmpegKit wrapper functions
    private func executeFFmpeg(command: String) -> Bool {
        guard let session = FFmpegKit.execute(command) else {
            print("[WebMAlphaCPUView] FFmpegKit.execute returned nil")
            return false
        }
        let returnCode = session.getReturnCode()
        return ReturnCode.isSuccess(returnCode)
    }
    
    private func executeFFprobe(command: String) -> String? {
        guard let session = FFprobeKit.execute(command) else {
            return nil
        }
        if ReturnCode.isSuccess(session.getReturnCode()) {
            return session.getOutput()
        }
        return nil
    }
}
