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
        // CRITICAL: Use linear filtering for smooth rendering (not nearest)
        constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);

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

// MARK: - GPU Texture Cache

/// Stores all frames as GPU textures - no CPU data retained after upload
private class GPUTextureCache {
    let yTextures: [MTLTexture]
    let uTextures: [MTLTexture]
    let vTextures: [MTLTexture]
    let aTextures: [MTLTexture]
    let frameCount: Int
    let width: Int
    let height: Int
    let frameRate: Double
    
    init(yTextures: [MTLTexture], uTextures: [MTLTexture], vTextures: [MTLTexture], aTextures: [MTLTexture], 
         width: Int, height: Int, frameRate: Double) {
        self.yTextures = yTextures
        self.uTextures = uTextures
        self.vTextures = vTextures
        self.aTextures = aTextures
        self.frameCount = yTextures.count
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }
    
    var gpuMemoryBytes: Int {
        let ySize = width * height
        let uvSize = (width / 2) * (height / 2)
        let aSize = width * height
        return (ySize + uvSize * 2 + aSize) * frameCount
    }
}

/// Cache for GPU texture arrays - keyed by source hash
private var gpuTextureCache = NSCache<NSString, GPUTextureCache>()

private func configureGPUCache() {
    gpuTextureCache.countLimit = 10
    // GPU memory is managed separately, this just limits number of cached videos
}

@objc(WebMAlphaGPUView)
public class WebMAlphaGPUView: UIView, MTKViewDelegate {

    private var metalView: MTKView!

    private var source: String?
    private var sourceHash: String?
    @objc public var autoPlay: Bool = true
    @objc public var loop: Bool = true
    @objc public var cacheKey: String?
    
    // Expose paused to React Native
    @objc public var paused: Bool = false {
        didSet {
            print("[WebMAlphaMetalView] Paused state changed to: \(paused)")
        }
    }

    private var isPlaying = false
    private var isDecoding = false
    private var shouldStop = false

    // CADisplayLink for frame-synchronized rendering
    private var displayLink: CADisplayLink?
    private var currentFrameIndex = 0
    private var frameRate: Double = 30.0
    private var lastFrameTime: CFTimeInterval = 0
    private var frameInterval: CFTimeInterval = 1.0 / 30.0

    // GPU texture cache for current video - all frames live on GPU
    private var currentTextureCache: GPUTextureCache?

    // Video dimensions
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0

    private let decodeQueue = DispatchQueue(label: "com.webmalphaplayer.metal.decode", qos: .userInitiated)
    private var hasLoggedFirstFrame = false

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

        // Configure GPU cache if not already done
        configureGPUCache()

        // Create MTKView
        guard let device = sharedMetalDevice else { return }
        metalView = MTKView(frame: bounds, device: device)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.backgroundColor = .clear
        metalView.isOpaque = false
        metalView.layer.isOpaque = false
        metalView.framebufferOnly = false
        metalView.colorPixelFormat = .bgra8Unorm
        // Use setNeedsDisplay mode - we trigger redraws via CADisplayLink
        metalView.enableSetNeedsDisplay = true
        metalView.isPaused = true
        metalView.delegate = self
        metalView.isUserInteractionEnabled = false

        addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    deinit {
        stop()
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Public API

    @objc public func setSource(_ sourceDict: NSDictionary) {
        guard let uri = sourceDict["uri"] as? String else {
            print("[WebMAlphaMetalView] Invalid source: missing 'uri'")
            return
        }

        // Stop current playback
        stop()

        source = uri
        sourceHash = String(uri.hashValue)

        if autoPlay {
            play()
        }
    }

    @objc public func play() {
        guard !isPlaying, let source = source, let hash = sourceHash else { 
            print("[WebMAlphaMetalView] Cannot play: isPlaying=\(isPlaying), source=\(source ?? "nil"), hash=\(sourceHash ?? "nil")")
            return 
        }

        shouldStop = false
        paused = false
        
        print("[WebMAlphaMetalView] Starting playback for source: \(source)")

        // Check GPU texture cache first - instant playback if cached
        if let cachedTextures = gpuTextureCache.object(forKey: hash as NSString) {
            print("[WebMAlphaMetalView] ⚡ Using GPU-cached textures: \(cachedTextures.frameCount) frames, \(cachedTextures.gpuMemoryBytes / 1024)KB GPU memory")
            self.currentTextureCache = cachedTextures
            self.frameRate = cachedTextures.frameRate
            self.frameInterval = 1.0 / frameRate
            self.currentFrameIndex = 0
            self.isPlaying = true
            startDisplayLink()
            return
        }

        // Decode in background
        isDecoding = true
        decodeQueue.async { [weak self] in
            self?.decodeAndCache(source: source, hash: hash)
        }
    }

    @objc public func stop() {
        print("[WebMAlphaMetalView] Stopping playback")
        shouldStop = true
        isPlaying = false
        isDecoding = false
        currentFrameIndex = 0
        stopDisplayLink()
    }
    
    private func startDisplayLink() {
        guard displayLink == nil else { return }
        
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: Float(frameRate), preferred: Float(frameRate))
        displayLink?.add(to: .main, forMode: .common)
        lastFrameTime = CACurrentMediaTime()
        frameInterval = 1.0 / frameRate
        print("[WebMAlphaMetalView] CADisplayLink started at \(frameRate)fps")
    }
    
    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard isPlaying, !shouldStop, !paused, let cache = currentTextureCache else {
            return
        }
        
        let currentTime = link.timestamp
        let elapsed = currentTime - lastFrameTime
        
        // Check if enough time has passed for next frame
        if elapsed >= frameInterval {
            lastFrameTime = currentTime - (elapsed.truncatingRemainder(dividingBy: frameInterval))
            
            // Just trigger redraw - textures already on GPU, no upload needed!
            metalView.setNeedsDisplay()
            
            // Advance to next frame
            currentFrameIndex += 1
            
            // Handle loop
            if currentFrameIndex >= cache.frameCount {
                if loop {
                    currentFrameIndex = 0
                } else {
                    isPlaying = false
                    stopDisplayLink()
                    print("[WebMAlphaMetalView] Playback complete")
                }
            }
        }
    }

    // MARK: - Decoding

    private func decodeAndCache(source: String, hash: String) {
        guard let device = sharedMetalDevice else {
            print("[WebMAlphaMetalView] No Metal device")
            return
        }
        
        guard let filePath = downloadToCache(urlString: source) else {
            print("[WebMAlphaMetalView] Failed to download: \(source)")
            return
        }

        guard probeVideo(path: filePath) else {
            print("[WebMAlphaMetalView] Failed to probe video")
            return
        }

        print("[WebMAlphaMetalView] Decoding: \(videoWidth)x\(videoHeight) @ \(frameRate)fps")

        // Decode with FFmpeg - output to pipe (no disk I/O)
        // We still need a temp file because FFmpegKit doesn't support pipe output well
        // But we'll read and upload to GPU immediately, then delete
        let rawFile = NSTemporaryDirectory() + "webm_decode_\(UUID().uuidString).yuva"

        // CRITICAL: Use libvpx-vp9 codec for proper VP9 alpha decoding
        let command = "-c:v libvpx-vp9 -i \"\(filePath)\" -f rawvideo -pix_fmt yuva420p \"\(rawFile)\""

        guard let session = FFmpegKit.execute(command),
              ReturnCode.isSuccess(session.getReturnCode()) else {
            print("[WebMAlphaMetalView] FFmpeg decode failed")
            if let session = FFmpegKit.execute(command) {
                print("[WebMAlphaMetalView] FFmpeg output: \(session.getOutput() ?? "none")")
            }
            try? FileManager.default.removeItem(atPath: rawFile)
            return
        }

        // Calculate frame sizes for yuva420p
        let ySize = videoWidth * videoHeight
        let uvSize = (videoWidth / 2) * (videoHeight / 2)
        let aSize = ySize
        let frameSize = ySize + uvSize + uvSize + aSize
        let uvWidth = videoWidth / 2
        let uvHeight = videoHeight / 2

        guard let fileSize = try? FileManager.default.attributesOfItem(atPath: rawFile)[.size] as? Int,
              fileSize > 0 else {
            print("[WebMAlphaMetalView] Failed to get raw file size")
            try? FileManager.default.removeItem(atPath: rawFile)
            return
        }

        let totalFrames = fileSize / frameSize
        let gpuMemoryMB = Double(frameSize * totalFrames) / 1024.0 / 1024.0

        print("""
        [WebMAlphaMetalView] 🚀 Uploading directly to GPU
        - Resolution: \(videoWidth)x\(videoHeight)
        - Total frames: \(totalFrames)
        - GPU memory: \(String(format: "%.2f", gpuMemoryMB)) MB
        - RAM usage: ~0 MB (frames go straight to GPU)
        """)

        guard totalFrames > 0, !shouldStop else {
            print("[WebMAlphaMetalView] No frames decoded or stopped")
            try? FileManager.default.removeItem(atPath: rawFile)
            return
        }

        guard let fileHandle = FileHandle(forReadingAtPath: rawFile) else {
            print("[WebMAlphaMetalView] Failed to open raw file")
            try? FileManager.default.removeItem(atPath: rawFile)
            return
        }

        // Create GPU textures for ALL frames upfront
        var yTextures: [MTLTexture] = []
        var uTextures: [MTLTexture] = []
        var vTextures: [MTLTexture] = []
        var aTextures: [MTLTexture] = []
        
        yTextures.reserveCapacity(totalFrames)
        uTextures.reserveCapacity(totalFrames)
        vTextures.reserveCapacity(totalFrames)
        aTextures.reserveCapacity(totalFrames)

        // Read each frame and upload directly to GPU texture
        for frameIdx in 0..<totalFrames {
            guard !shouldStop else { break }

            autoreleasepool {
                guard let frameData = try? fileHandle.read(upToCount: frameSize),
                      frameData.count == frameSize else {
                    return
                }

                // Create textures for this frame
                guard let yTex = createTexture(device: device, width: videoWidth, height: videoHeight),
                      let uTex = createTexture(device: device, width: uvWidth, height: uvHeight),
                      let vTex = createTexture(device: device, width: uvWidth, height: uvHeight),
                      let aTex = createTexture(device: device, width: videoWidth, height: videoHeight) else {
                    print("[WebMAlphaMetalView] Failed to create textures for frame \(frameIdx)")
                    return
                }

                // Upload plane data directly to GPU - CPU data is released after this block
                frameData.withUnsafeBytes { ptr in
                    let basePtr = ptr.baseAddress!
                    
                    yTex.replace(
                        region: MTLRegionMake2D(0, 0, videoWidth, videoHeight),
                        mipmapLevel: 0,
                        withBytes: basePtr,
                        bytesPerRow: videoWidth
                    )
                    
                    uTex.replace(
                        region: MTLRegionMake2D(0, 0, uvWidth, uvHeight),
                        mipmapLevel: 0,
                        withBytes: basePtr + ySize,
                        bytesPerRow: uvWidth
                    )
                    
                    vTex.replace(
                        region: MTLRegionMake2D(0, 0, uvWidth, uvHeight),
                        mipmapLevel: 0,
                        withBytes: basePtr + ySize + uvSize,
                        bytesPerRow: uvWidth
                    )
                    
                    aTex.replace(
                        region: MTLRegionMake2D(0, 0, videoWidth, videoHeight),
                        mipmapLevel: 0,
                        withBytes: basePtr + ySize + uvSize + uvSize,
                        bytesPerRow: videoWidth
                    )
                }
                
                yTextures.append(yTex)
                uTextures.append(uTex)
                vTextures.append(vTex)
                aTextures.append(aTex)
            }
            // frameData is released here - no CPU memory retained!
        }

        try? fileHandle.close()
        try? FileManager.default.removeItem(atPath: rawFile)  // Delete temp file immediately

        guard yTextures.count == totalFrames, !shouldStop else {
            print("[WebMAlphaMetalView] Failed to upload all frames or stopped")
            return
        }

        // Create GPU texture cache
        let textureCache = GPUTextureCache(
            yTextures: yTextures,
            uTextures: uTextures,
            vTextures: vTextures,
            aTextures: aTextures,
            width: videoWidth,
            height: videoHeight,
            frameRate: frameRate
        )
        
        // Store in global cache for reuse
        gpuTextureCache.setObject(textureCache, forKey: hash as NSString)
        
        print("[WebMAlphaMetalView] ✅ Uploaded \(totalFrames) frames to GPU (\(textureCache.gpuMemoryBytes / 1024)KB GPU memory, 0KB RAM)")

        // Start playback on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.shouldStop else { return }
            self.currentTextureCache = textureCache
            self.frameRate = textureCache.frameRate
            self.frameInterval = 1.0 / self.frameRate
            self.currentFrameIndex = 0
            self.isPlaying = true
            self.isDecoding = false
            print("[WebMAlphaMetalView] 🎬 Starting GPU-only playback with \(totalFrames) frames")
            self.startDisplayLink()
        }
    }

    // MARK: - Metal Texture Creation

    private func createTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared  // Allows CPU upload, GPU read
        return device.makeTexture(descriptor: descriptor)
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let pipeline = sharedPipelineState,
              let commandQueue = sharedCommandQueue,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let cache = currentTextureCache,
              currentFrameIndex < cache.frameCount else {
            return
        }
        
        // Get textures for current frame from GPU cache - NO upload needed!
        let yTex = cache.yTextures[currentFrameIndex]
        let uTex = cache.uTextures[currentFrameIndex]
        let vTex = cache.vTextures[currentFrameIndex]
        let aTex = cache.aTextures[currentFrameIndex]

        // Log first successful Metal render
        if !hasLoggedFirstFrame {
            hasLoggedFirstFrame = true
            print("[WebMAlphaMetalView] 🚀 First frame rendered via Metal GPU shader (zero-copy from GPU cache)")
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

                print("[WebMAlphaMetalView] Probed video: \(videoWidth)x\(videoHeight) @ \(frameRate)fps")
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
        guard let url = URL(string: urlString) else {
            print("[WebMAlphaMetalView] Invalid URL: \(urlString)")
            return nil
        }
        
        guard let data = try? Data(contentsOf: url) else {
            print("[WebMAlphaMetalView] Failed to download from: \(urlString)")
            return nil
        }

        // Generate cache path
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        
        let cacheFile: URL
        if let cacheKey = cacheKey {
            // cacheKey represents the full path from cache directory
            let pathComponents = cacheKey.split(separator: "/").map { String($0) }
            var currentDir = cacheDir
            
            // Create intermediate directories (all parts except the last)
            for component in pathComponents.dropLast() {
                currentDir = currentDir.appendingPathComponent(component)
            }
            
            try? FileManager.default.createDirectory(at: currentDir, withIntermediateDirectories: true)
            
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