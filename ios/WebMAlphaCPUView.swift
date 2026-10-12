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
    @objc public var verbose: Bool = false
    @objc public var onLoad: (([AnyHashable: Any]) -> Void)?
    @objc public var onError: (([AnyHashable: Any]) -> Void)?
    @objc public var onEnd: (([AnyHashable: Any]) -> Void)?

    private var isPlaying = false
    private var isDecoding = false
    private var shouldStop = false
    /// Bumped by every start, so work left over from an earlier source or pause stops itself.
    private var generation = 0

    private var playbackQueue: DispatchQueue?

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
            self?.log("Memory warning - clearing frame cache")
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
        isPlaying = false
        isDecoding = false
    }
    
    @objc func setSource(_ value: NSDictionary?) {
        guard let dict = value else {
            cleanup()
            return
        }
        
        guard let uriString = dict["uri"] as? String, !uriString.isEmpty else {
            cleanup()
            return
        }
        if let key = dict["cacheKey"] as? String, !key.isEmpty {
            cacheKey = key
        }
        
        // Decoded frames are shared between views showing the same clip.
        let identity = WebMSourceResolver.identity(for: uriString, cacheKey: cacheKey)
        var hashValue: UInt64 = 5381
        for char in identity.utf8 {
            hashValue = ((hashValue << 5) &+ hashValue) &+ UInt64(char)
        }
        let hashString = String(format: "%016llx", hashValue)
        
        if self.source != uriString {
            cleanup()
        }
        
        self.source = uriString
        self.sourceHash = hashString
        log("setSource: \(uriString.prefix(80)), frame cache key \(hashString.prefix(8))")
        
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
        if paused {
            stopPlayback()
        } else if autoPlay && !isPlaying && !isDecoding && source != nil {
            startPlayback()
        }
    }
    
    private func startPlayback() {
        guard let source = source, let hash = sourceHash else { return }
        if isPlaying || isDecoding { return }
        
        shouldStop = false
        generation += 1
        let gen = generation
        let key = cacheKey
        
        // Check if frames are already cached
        if let cached = frameCache.object(forKey: hash as NSString) {
            log("Using cached frames for \(hash.prefix(8))")
            isPlaying = true
            videoWidth = cached.width
            videoHeight = cached.height
            frameRate = cached.frameRate
            emitLoad(frames: cached.frames.count, gen: gen)
            playbackQueue?.async { [weak self] in
                self?.playFramesFromCache(cached.frames, gen: gen)
                DispatchQueue.main.async {
                    if self?.generation == gen { self?.isPlaying = false }
                }
            }
            return
        }
        
        // Need to decode - use shared serial queue to prevent memory spikes
        isDecoding = true
        sharedFFmpegQueue.async { [weak self] in
            guard let self = self, !self.isStopped(gen) else {
                DispatchQueue.main.async { self?.isDecoding = false }
                return
            }
            self.decodeAndPlay(source: source, cacheKey: key, hash: hash, gen: gen)
            DispatchQueue.main.async {
                if self.generation == gen { self.isDecoding = false }
            }
        }
    }
    
    private func isStopped(_ gen: Int) -> Bool {
        return shouldStop || gen != generation
    }
    
    private func stopPlayback() {
        shouldStop = true
        isPlaying = false
    }
    
    private func decodeAndPlay(source: String, cacheKey: String?, hash: String, gen: Int) {
        let localPath: String
        do {
            localPath = try WebMSourceResolver.localPath(for: source, cacheKey: cacheKey) { [weak self] in
                self?.isStopped(gen) ?? true
            }
        } catch {
            if !isStopped(gen) { emitError("Failed to load \(source): \(error.localizedDescription)", gen: gen) }
            return
        }
        
        guard !isStopped(gen) else { return }
        
        guard probeVideo(path: localPath) else {
            if !isStopped(gen) { emitError("Failed to probe \(source)", gen: gen) }
            return
        }
        
        guard !isStopped(gen) else { return }
        
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
        
        let ffmpegCmd = "-c:v libvpx-vp9 -i \"\(localPath)\" -an -vf format=rgba -f rawvideo \"\(rawFile.path)\""
        
        guard executeFFmpeg(command: ffmpegCmd) else {
            if !isStopped(gen) { emitError("Failed to decode \(source)", gen: gen) }
            return
        }
        
        guard !isStopped(gen) else { return }
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: rawFile.path)[.size] as? Int) ?? 0
        let frameSize = videoWidth * videoHeight * 4 // RGBA = 4 bytes per pixel
        totalFrames = fileSize / frameSize
        
        log("Decoded \(totalFrames) frames, \(videoWidth)x\(videoHeight), ~\(fileSize / 1024 / 1024)MB raw")
        
        guard !isStopped(gen) else { return }
        guard totalFrames > 0, let fileHandle = try? FileHandle(forReadingFrom: rawFile) else {
            emitError("No frames decoded from \(source)", gen: gen)
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
        
        guard frames.count > 0, !isStopped(gen) else { return }
        
        // Cache the frames
        let cacheEntry = FrameCacheEntry(frames: frames, width: videoWidth, height: videoHeight, frameRate: frameRate)
        let cost = frames.reduce(0) { $0 + $1.count }
        frameCache.setObject(cacheEntry, forKey: hash as NSString, cost: cost)
        log("Cached \(frames.count) frames for \(hash.prefix(8)), cost=\(cost / 1024)KB")
        
        // Decoding complete - start playback on the view's own playback queue
        // This frees up the shared FFmpeg queue for other videos to decode
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isStopped(gen) else { return }
            self.isPlaying = true
            self.emitLoad(frames: frames.count, gen: gen)
            self.playbackQueue?.async { [weak self] in
                self?.playFramesFromCache(frames, gen: gen)
                DispatchQueue.main.async {
                    if self?.generation == gen { self?.isPlaying = false }
                }
            }
        }
    }
    
    private func playFramesFromCache(_ frames: [Data], gen: Int) {
        let frameInterval: TimeInterval = 1.0 / frameRate
        
        repeat {
            var frameIndex = 0
            let startTime = CACurrentMediaTime()
            
            while !isStopped(gen) && frameIndex < frames.count {
                autoreleasepool {
                    let data = frames[frameIndex]
                    
                    // Convert RGBA to UIImage and display
                    if let image = createImage(from: data) {
                        DispatchQueue.main.async { [weak self] in
                            guard self?.isStopped(gen) == false else { return }
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
            
        } while loop && !isStopped(gen)
        
        if !isStopped(gen) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.generation == gen else { return }
                self.onEnd?([:])
            }
        }
    }
    
    private func probeVideo(path: String) -> Bool {
        let probeCmd = "-v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=p=0 \"\(path)\""
        
        guard let output = executeFFprobe(command: probeCmd) else {
            return false
        }
        
        let trimmedOutput = output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else {
            return false
        }
        
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
        
        log("Video: \(videoWidth)x\(videoHeight) @ \(frameRate)fps")
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
    
    // MARK: - Events and logging
    
    private func emitLoad(frames: Int, gen: Int) {
        let body: [AnyHashable: Any] = ["totalFrames": frames, "width": videoWidth, "height": videoHeight]
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.generation == gen else { return }
            self.onLoad?(body)
        }
    }
    
    private func emitError(_ message: String, gen: Int) {
        NSLog("[WebMAlphaCPUView] %@", message)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.generation == gen else { return }
            self.onError?(["error": message])
        }
    }
    
    private func log(_ message: @autoclosure () -> String) {
        if verbose { NSLog("[WebMAlphaCPUView] %@", message()) }
    }
    
    // FFmpegKit wrapper functions
    private func executeFFmpeg(command: String) -> Bool {
        guard let session = FFmpegKit.execute(command) else {
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
