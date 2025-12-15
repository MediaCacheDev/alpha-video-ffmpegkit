import UIKit
import Metal
import MetalKit
import simd
import ffmpegkit

/**
 * WebMAlphaMetalView - GPU-accelerated VP9+Alpha WebM player using Metal
 *
 * Adapted from the proven AlphaWebMMetalView implementation with NSDictionary source handling,
 * DispatchQueue-based playback timing, and frame caching.
 */

// MARK: - Shared Metal Resources

private var sharedMetalDevice: MTLDevice?
private var sharedPipelineState: MTLRenderPipelineState?
private var sharedCommandQueue: MTLCommandQueue?
private var metalInitialized = false

/// Initialize shared Metal resources once
private func initializeMetalResources() -> Bool {
    guard !metalInitialized else { return sharedMetalDevice != nil }
    metalInitialized = true

    guard let device = MTLCreateSystemDefaultDevice() else {
        print("[WebMAlphaMetalView] Metal not available on this device")
        return false
    }
    sharedMetalDevice = device
    sharedCommandQueue = device.makeCommandQueue()

    // Create shader library
    let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    // Full-screen quad vertices
    constant float2 quadVertices[] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1), float2(1, -1), float2(1, 1)
    };

    constant float2 quadTexCoords[] = {
        float2(0, 1), float2(1, 1), float2(0, 0),
        float2(0, 0), float2(1, 1), float2(1, 0)
    };

    vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
        VertexOut out;
        out.position = float4(quadVertices[vertexID], 0, 1);
        out.texCoord = quadTexCoords[vertexID];
        return out;
    }

    fragment float4 fragmentShader(
        VertexOut in [[stage_in]],
        texture2d<float> yTexture [[texture(0)]],
        texture2d<float> uTexture [[texture(1)]],
        texture2d<float> vTexture [[texture(2)]],
        texture2d<float> aTexture [[texture(3)]]
    ) {
        // Use nearest sampling to avoid smearing when upscaling small glow textures
        constexpr sampler textureSampler(mag_filter::nearest, min_filter::nearest);

        float y = yTexture.sample(textureSampler, in.texCoord).r;
        float u = uTexture.sample(textureSampler, in.texCoord).r - 0.5;
        float v = vTexture.sample(textureSampler, in.texCoord).r - 0.5;
        float a = aTexture.sample(textureSampler, in.texCoord).r;

        // BT.601 YUV to RGB conversion (standard for web video)
        float r = y + 1.402 * v;
        float g = y - 0.344136 * u - 0.714136 * v;
        float b = y + 1.772 * u;

        // Premultiply alpha for correct compositing
        return float4(r * a, g * a, b * a, a);
    }
    """

    do {
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let vertexFunction = library.makeFunction(name: "vertexShader")
        let fragmentFunction = library.makeFunction(name: "fragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Enable alpha blending
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        sharedPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        print("[WebMAlphaMetalView] Metal pipeline initialized successfully")
        return true
    } catch {
        print("[WebMAlphaMetalView] Failed to create Metal pipeline: \(error)")
        return false
    }
}

// MARK: - Frame Data for YUV planes

private class YUVAFrame {
    let yPlane: Data
    let uPlane: Data
    let vPlane: Data
    let aPlane: Data
    let width: Int
    let height: Int

    init(yPlane: Data, uPlane: Data, vPlane: Data, aPlane: Data, width: Int, height: Int) {
        self.yPlane = yPlane
        self.uPlane = uPlane
        self.vPlane = vPlane
        self.aPlane = aPlane
        self.width = width
        self.height = height
    }
}

/// Cache for decoded YUVA frames
private var yuvFrameCache = NSCache<NSString, NSArray>()

private func configureYUVCache() {
    yuvFrameCache.countLimit = 10
    yuvFrameCache.totalCostLimit = 150 * 1024 * 1024 // 150MB - YUV is smaller than RGBA
}

@objc(WebMAlphaMetalView)
public class WebMAlphaMetalView: UIView, MTKViewDelegate {

    private var metalView: MTKView!

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
    private var currentFrameIndex = 0
    private var frames: [YUVAFrame] = []
    private var frameRate: Double = 30.0

    // Metal textures for current frame
    private var yTexture: MTLTexture?
    private var uTexture: MTLTexture?
    private var vTexture: MTLTexture?
    private var aTexture: MTLTexture?

    // Video dimensions
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0

    private let decodeQueue = DispatchQueue(label: "com.webmalphaplayer.metal.decode", qos: .userInitiated)
    private var hasLoggedFirstFrame = false
    private var lastLoggedFramesCount: Int = -1

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false

        // Initialize Metal resources if not already done
        if !initializeMetalResources() {
            print("[WebMAlphaMetalView] Failed to initialize Metal resources")
            return
        }

        // Configure YUV cache if not already done
        configureYUVCache()

        // Create MTKView
        guard let device = sharedMetalDevice else { return }
        metalView = MTKView(frame: bounds, device: device)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.backgroundColor = .clear
        metalView.isOpaque = false
        metalView.framebufferOnly = false
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.enableSetNeedsDisplay = true
        metalView.isPaused = true
        metalView.isUserInteractionEnabled = false
        metalView.delegate = self
        addSubview(metalView)

        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Create playback queue
        playbackQueue = DispatchQueue(label: "com.webmalphaplayer.metal.playback", qos: .userInteractive)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
        // Ensure drawableSize matches view size and scale for correct sampling
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalView.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    deinit {
        stop()
        cleanupTextures()
    }

    // MARK: - Property Setters

    @objc func setSource(_ value: NSDictionary?) {
        guard let dict = value as? [String: Any] else {
            print("[WebMAlphaMetalView] Invalid source dictionary")
            return
        }

        guard let uri = dict["uri"] as? String else {
            print("[WebMAlphaMetalView] No URI in source dictionary")
            return
        }

        let newSource = uri
        let newSourceHash = String(uri.hashValue)

        // Check if source changed
        if newSource == source && newSourceHash == sourceHash {
            return
        }

        source = newSource
        sourceHash = newSourceHash

        // Extract other properties
        if let autoPlayVal = dict["autoPlay"] as? Bool {
            autoPlay = autoPlayVal
        }
        if let loopVal = dict["loop"] as? Bool {
            loop = loopVal
        }
        if let pausedVal = dict["paused"] as? Bool {
            paused = pausedVal
        }

        // Stop current playback and start new one
        stop()
        loadAndPlay()
    }

    @objc func setAutoPlay(_ value: Bool) {
        autoPlay = value
        if autoPlay && !isPlaying && !paused {
            startPlayback()
        } else if !autoPlay {
            stop()
        }
    }

    @objc func setLoop(_ value: Bool) {
        loop = value
    }

    @objc func setPaused(_ value: Bool) {
        paused = value
        if paused {
            stopPlayback()
        } else if autoPlay {
            startPlayback()
        }
    }

    // MARK: - Playback Control

    private func loadAndPlay() {
        guard let _ = source, !isDecoding else { return }
        shouldStop = false

        decodeQueue.async { [weak self] in
            self?.decodeVideo()
        }
    }

    private func startPlayback() {
        guard !frames.isEmpty else { return }
        if isPlaying { return }
        isPlaying = true
        shouldStop = false
        metalView.isPaused = false
        playbackQueue?.async { [weak self] in
            self?.playLoop()
        }
    }

    private func stopPlayback() {
        shouldStop = true
        isPlaying = false
        metalView.isPaused = true
    }

    private func stop() {
        stopPlayback()
        isDecoding = false
        currentFrameIndex = 0
        frames.removeAll()
        cleanupTextures()
    }

    // MARK: - Video Decoding

    private func decodeVideo() {
        guard let source = source else { return }
        isDecoding = true

        var localPath = source

        // Handle URLs - download first
        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            guard let downloaded = downloadToCache(urlString: source) else {
                print("[WebMAlphaMetalView] Failed to download video")
                isDecoding = false
                isPlaying = false
                return
            }
            localPath = downloaded
        } else if source.hasPrefix("file://") {
            localPath = String(source.dropFirst(7))
        }

        // Check cache first (automatic caching based on source hash)
        if let sourceHash = sourceHash,
           let cachedFrames = yuvFrameCache.object(forKey: sourceHash as NSString) as? [YUVAFrame] {
            print("[WebMAlphaMetalView] Using cached frames for \(sourceHash.prefix(8))")
            frames = cachedFrames
            isDecoding = false
            if autoPlay && !paused {
                startPlayback()
            }
            return
        }

        // Probe video metadata
        guard probeVideo(path: localPath) else {
            print("[WebMAlphaMetalView] Failed to probe video")
            isDecoding = false
            isPlaying = false
            return
        }

        // Decode frames
        guard decodeFrames(path: localPath) else {
            print("[WebMAlphaMetalView] Failed to decode frames")
            isDecoding = false
            isPlaying = false
            return
        }

        // Cache frames automatically using source hash
        if let sourceHash = sourceHash {
            yuvFrameCache.setObject(frames as NSArray, forKey: sourceHash as NSString)
        }

        isDecoding = false

        if autoPlay && !paused {
            startPlayback()
        }
    }

    private func decodeFrames(path: String) -> Bool {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("webm-yuva-\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            print("[WebMAlphaMetalView] Failed to create temp directory: \(error)")
            return false
        }

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // FFmpeg command to extract YUVA frames
        let yuvaPath = tempDir.appendingPathComponent("frame_%04d.yuva").path
        let command = "-i \"\(path)\" -f rawvideo -pix_fmt yuva420p -vf scale=\(videoWidth):\(videoHeight) \"\(yuvaPath)\""

        guard let session = FFmpegKit.execute(command) else {
            print("[WebMAlphaMetalView] FFmpeg session creation failed")
            return false
        }

        if !ReturnCode.isSuccess(session.getReturnCode()) {
            print("[WebMAlphaMetalView] FFmpeg decode failed: \(session.getOutput() ?? "no output")")
            return false
        }

        // Read decoded frames
        let ySize = videoWidth * videoHeight
        let uvSize = (videoWidth / 2) * (videoHeight / 2)

        do {
            let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "yuva" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            for fileURL in files {
                let data = try Data(contentsOf: fileURL)
                guard data.count >= ySize + 2 * uvSize + uvSize else { continue }

                let yPlane = data.subdata(in: 0..<ySize)
                let uPlane = data.subdata(in: ySize..<ySize + uvSize)
                let vPlane = data.subdata(in: ySize + uvSize..<ySize + 2 * uvSize)
                let aPlane = data.subdata(in: ySize + 2 * uvSize..<ySize + 3 * uvSize)

                let frame = YUVAFrame(yPlane: yPlane, uPlane: uPlane, vPlane: vPlane, aPlane: aPlane,
                                     width: videoWidth, height: videoHeight)
                frames.append(frame)
            }
        } catch {
            print("[WebMAlphaMetalView] Failed to read decoded frames: \(error)")
            return false
        }

        return !frames.isEmpty
    }

    private func playLoop() {
        guard let _ = playbackQueue else { return }

        // Simple frame-timer loop: upload textures on main thread, request draw, then sleep
        while !shouldStop {
            autoreleasepool {
                guard !frames.isEmpty else {
                    Thread.sleep(forTimeInterval: 0.05)
                    return
                }

                let frameTime = 1.0 / frameRate

                // Capture index and frame for this tick
                let idx = currentFrameIndex
                let frame = frames[idx]

                // Upload textures and request draw synchronously on main thread
                DispatchQueue.main.sync { [weak self] in
                    guard let self = self, !self.shouldStop else { return }
                    self.createTexturesForFrame(frame)
                    self.metalView.setNeedsDisplay()
                }

                // Sleep until next frame
                Thread.sleep(forTimeInterval: frameTime)

                // Advance index
                currentFrameIndex += 1
                if currentFrameIndex >= frames.count {
                    if loop {
                        currentFrameIndex = 0
                    } else {
                        shouldStop = true
                        isPlaying = false
                    }
                }
            }
        }
    }

    // MARK: - Metal Rendering

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle drawable size changes if needed
    }

    public func draw(in view: MTKView) {
                // Light diagnostic: only log on first render or when frame count changes
                if !hasLoggedFirstFrame || lastLoggedFramesCount != frames.count {
                    print("[WebMAlphaMetalView] draw(in:) — frames= \(frames.count) index= \(currentFrameIndex) drawableSize= \(view.drawableSize)")
                }

                // Ensure we have frames to render
                guard !frames.isEmpty, currentFrameIndex < frames.count else { return }

                // If textures are missing (fallback), upload for the current frame once
                if yTexture == nil || uTexture == nil || vTexture == nil || aTexture == nil {
                    let frame = frames[currentFrameIndex]
                    createTexturesForFrame(frame)
                }

                // Use the MTKView-provided renderPassDescriptor when available
                guard let pipeline = sharedPipelineState,
                            let commandQueue = sharedCommandQueue,
                            let drawable = view.currentDrawable,
                            let renderPassDescriptor = view.currentRenderPassDescriptor,
                            let yTex = yTexture,
                            let uTex = uTexture,
                            let vTex = vTexture,
                            let aTex = aTexture else {
                        return
                }

        // Log first successful Metal render
        if !hasLoggedFirstFrame {
            hasLoggedFirstFrame = true
            print("[WebMAlphaMetalView] 🚀 First frame rendered via Metal GPU shader")
        }

        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(yTex, index: 0)
        encoder.setFragmentTexture(uTex, index: 1)
        encoder.setFragmentTexture(vTex, index: 2)
        encoder.setFragmentTexture(aTex, index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func renderCurrentFrame() {
        guard currentFrameIndex < frames.count,
              let drawable = metalView?.currentDrawable,
              let commandQueue = sharedCommandQueue,
              let pipelineState = sharedPipelineState else {
            return
        }

        let frame = frames[currentFrameIndex]

        // Create textures for current frame
        createTexturesForFrame(frame)

        guard let yTexture = yTexture,
              let uTexture = uTexture,
              let vTexture = vTexture,
              let aTexture = aTexture else {
            return
        }

        let commandBuffer = commandQueue.makeCommandBuffer()
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer?.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setFragmentTexture(yTexture, index: 0)
        renderEncoder.setFragmentTexture(uTexture, index: 1)
        renderEncoder.setFragmentTexture(vTexture, index: 2)
        renderEncoder.setFragmentTexture(aTexture, index: 3)

        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        commandBuffer?.present(drawable)
        commandBuffer?.commit()
    }
    private func createOrReuseTexture(_ existing: MTLTexture?, pixelFormat: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
        guard let device = sharedMetalDevice else { return nil }
        if let tex = existing, tex.width == width, tex.height == height, tex.pixelFormat == pixelFormat {
            return tex
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    private func uploadData(_ data: Data, to texture: MTLTexture, width: Int, height: Int) {
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: base, bytesPerRow: width)
        }
    }

    private func createTexturesForFrame(_ frame: YUVAFrame) {
        guard let _ = sharedMetalDevice else { return }

        // Reuse existing textures where possible to avoid allocations each frame
        let yW = frame.width
        let yH = frame.height
        let uvW = max(1, frame.width / 2)
        let uvH = max(1, frame.height / 2)

        // Alpha plane may be full resolution or half (some encoders). detect from data length.
        let aIsFullRes = frame.aPlane.count == (frame.width * frame.height)
        let aW = aIsFullRes ? frame.width : uvW
        let aH = aIsFullRes ? frame.height : uvH

        yTexture = createOrReuseTexture(yTexture, pixelFormat: .r8Unorm, width: yW, height: yH)
        uTexture = createOrReuseTexture(uTexture, pixelFormat: .r8Unorm, width: uvW, height: uvH)
        vTexture = createOrReuseTexture(vTexture, pixelFormat: .r8Unorm, width: uvW, height: uvH)
        aTexture = createOrReuseTexture(aTexture, pixelFormat: .r8Unorm, width: aW, height: aH)

        // Upload plane data into the (reused) textures
        if let yTex = yTexture {
            uploadData(frame.yPlane, to: yTex, width: yW, height: yH)
        }
        if let uTex = uTexture {
            uploadData(frame.uPlane, to: uTex, width: uvW, height: uvH)
        }
        if let vTex = vTexture {
            uploadData(frame.vPlane, to: vTex, width: uvW, height: uvH)
        }
        if let aTex = aTexture {
            uploadData(frame.aPlane, to: aTex, width: aW, height: aH)
        }

        // Light diagnostic: log only when frames count changes or first time
        if lastLoggedFramesCount != frames.count {
            lastLoggedFramesCount = frames.count
            print("[WebMAlphaMetalView] textures updated: video= \(frame.width)x\(frame.height) yTex=\(yTexture != nil) uTex=\(uTexture != nil) vTex=\(vTexture != nil) aTex=\(aTexture != nil)")
        }
    }

    private func cleanupTextures() {
        yTexture = nil
        uTexture = nil
        vTexture = nil
        aTexture = nil
    }

    // MARK: - Video Probing

    private func probeVideo(path: String) -> Bool {
        let command = "-v quiet -print_format json -show_format -show_streams \"\(path)\""

        guard let output = executeFFprobe(command: command),
              let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]] else {
            return false
        }

        for stream in streams {
            if let codecType = stream["codec_type"] as? String, codecType == "video" {
                videoWidth = stream["width"] as? Int ?? 0
                videoHeight = stream["height"] as? Int ?? 0

                if let frameRateStr = stream["r_frame_rate"] as? String,
                   let frameRateVal = parseFrameRate(frameRateStr) {
                    frameRate = frameRateVal
                }

                return videoWidth > 0 && videoHeight > 0
            }
        }

        return false
    }

    private func parseFrameRate(_ rateStr: String) -> Double? {
        let components = rateStr.split(separator: "/").compactMap { Double($0) }
        guard components.count == 2, components[1] != 0 else { return nil }
        return components[0] / components[1]
    }

    // MARK: - File Handling

    private func downloadToCache(urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

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
        
        print("[WebMAlphaMetalView] Cache key for '\(url.path)' -> \(cacheFile.path)")
        
        // Check cache
        if FileManager.default.fileExists(atPath: cacheFile.path) {
            print("[WebMAlphaMetalView] Using cached: \(cacheFile.path)")
            return cacheFile.path
        }
        
        // Download and cache
        do {
            try data.write(to: cacheFile)
            print("[WebMAlphaMetalView] Downloaded and cached: \(cacheFile.path)")
            return cacheFile.path
        } catch {
            print("[WebMAlphaMetalView] Failed to save downloaded file: \(error)")
            return nil
        }
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