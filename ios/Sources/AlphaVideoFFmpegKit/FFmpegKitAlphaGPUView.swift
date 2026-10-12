import UIKit
import Metal
import MetalKit
import simd
import ffmpegkit

/**
 * FFmpegKitAlphaGPUView - VP9+Alpha WebM player that converts YUVA to RGBA in a Metal shader.
 *
 * FFmpegKit decodes the clip to raw YUVA420P frames, either while playing (stream mode) or all
 * up front into textures (preload mode). A CADisplayLink paces playback at the clip's frame rate.
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
        NSLog("[FFmpegKitAlphaGPUView] Metal not available on this device")
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
        return true
    } catch {
        NSLog("[FFmpegKitAlphaGPUView] Failed to create Metal pipeline: %@", "\(error)")
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

/// The Y, U, V and A planes of one frame.
private struct PlaneTextures {
    let y: MTLTexture
    let u: MTLTexture
    let v: MTLTexture
    let a: MTLTexture
}

/// Cache for GPU texture arrays - keyed by source hash
private var gpuTextureCache = NSCache<NSString, GPUTextureCache>()

private func configureGPUCache() {
    gpuTextureCache.countLimit = 10
    // GPU memory is managed separately, this just limits number of cached videos
}

@objc(FFmpegKitAlphaGPUView)
public class FFmpegKitAlphaGPUView: UIView, MTKViewDelegate {

    private var metalView: MTKView!

    /// `https://`, `http://` (downloaded once into Caches), `file://`, an absolute path, or
    /// `asset://relative/path` (the app bundle). Playback starts on the next main-queue turn, so
    /// the other properties can be set after this one.
    @objc public var source: String? {
        didSet { sourceChanged(from: oldValue) }
    }
    /// Name for the downloaded copy of an http(s) source, relative to Caches; it must stay inside
    /// that directory. Also names the texture cache, which views showing the same clip share.
    @objc public var cacheKey: String?
    @objc public var autoPlay: Bool = true
    @objc public var loop: Bool = true
    @objc public var paused: Bool = false
    /// Log progress. Errors are always logged.
    @objc public var verbose: Bool = false
    /// `"stream"` (the default, also for nil) or `"preload"`; changing it restarts playback.
    @objc public var mode: String? {
        didSet { modeChanged(from: oldValue) }
    }
    /// Decoded frames held ahead of playback in stream mode; applies from the next start.
    @objc public var streamBufferFrames: Int = FrameStream.defaultBufferFrames

    /// Playback is starting. In stream mode totalFrames is estimated from the duration.
    @objc public var onLoad: ((_ totalFrames: Int, _ width: Int, _ height: Int) -> Void)?
    /// The source could not be resolved, downloaded or decoded.
    @objc public var onError: ((_ error: String) -> Void)?
    /// A clip with `loop` off played to the end.
    @objc public var onEnd: (() -> Void)?

    /// Textures are shared between views showing the same clip.
    private var sourceHash: String? {
        source.map { WebMSourceResolver.identity(for: $0, cacheKey: cacheKey) }
    }
    private var stream: Bool { mode != "preload" }

    private var isPlaying = false
    private var isDecoding = false
    private var shouldStop = false
    /// Bumped by every play(), so a decode left over from an earlier source can't take over.
    private var generation = 0

    // CADisplayLink for frame-synchronized rendering
    private var displayLink: CADisplayLink?
    private var currentFrameIndex = 0
    private var frameRate: Double = 30.0
    private var lastFrameTime: CFTimeInterval = 0
    private var frameInterval: CFTimeInterval = 1.0 / 30.0

    // GPU texture cache for current video - all frames live on GPU
    private var currentTextureCache: GPUTextureCache?

    // Stream mode: frames are uploaded in turn into a few texture sets, so the one being
    // written isn't one the GPU may still be drawing.
    private static let streamTextureSets = 3
    private var frameStream: FrameStream?
    private var streamTextures: [PlaneTextures] = []
    private var nextStreamSet = 0
    private var currentStreamTextures: PlaneTextures?
    private var streamLoaded = false

    // Video dimensions
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0
    /// 0 if the container doesn't say.
    private var durationSeconds: Double = 0

    private let decodeQueue = DispatchQueue(label: "dev.mediacache.alphavideo.ffmpegkit.decode", qos: .userInitiated)

    // MARK: - Initialization

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false

        // Initialize Metal resources if not already done
        if !initializeMetalResources() {
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

    private func sourceChanged(from oldValue: String?) {
        guard source != oldValue else { return }
        stop()
        guard source != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.autoPlay else { return }
            self.play()
        }
    }

    private func modeChanged(from oldValue: String?) {
        guard (oldValue != "preload") != stream, isPlaying || isDecoding else { return }
        stop()
        play()
    }

    /// Starts playback of `source`; does nothing while it is already playing or decoding.
    @objc public func play() {
        guard !isPlaying, !isDecoding, let source = source, let hash = sourceHash else { return }

        shouldStop = false
        generation += 1
        let gen = generation
        let key = cacheKey

        if stream {
            startStream(source: source, cacheKey: key, gen: gen)
            return
        }

        // Check GPU texture cache first - instant playback if cached
        if let cachedTextures = gpuTextureCache.object(forKey: hash as NSString) {
            log("Using GPU-cached textures: \(cachedTextures.frameCount) frames, \(cachedTextures.gpuMemoryBytes / 1024)KB")
            startPlaying(cachedTextures)
            return
        }

        isDecoding = true
        decodeQueue.async { [weak self] in
            guard let self = self, !self.isStopped(gen) else { return }
            do {
                let textures = try self.decodeToTextures(source: source, cacheKey: key, gen: gen)
                gpuTextureCache.setObject(textures, forKey: hash as NSString)
                DispatchQueue.main.async {
                    guard !self.isStopped(gen) else { return }
                    self.isDecoding = false
                    self.startPlaying(textures)
                }
            } catch {
                self.reportDecodeError(error, source: source, gen: gen)
            }
        }
    }

    private func reportDecodeError(_ error: Error, source: String, gen: Int) {
        guard !isStopped(gen) else { return }
        let message = "Failed to play \(source): \(error.localizedDescription)"
        NSLog("[FFmpegKitAlphaGPUView] %@", message)
        DispatchQueue.main.async {
            guard !self.isStopped(gen) else { return }
            self.isDecoding = false
            self.onError?(message)
        }
    }

    /// Stream mode: resolve and probe on the decode queue, then decode while the display link
    /// shows frames. onLoad comes with the first frame, and totalFrames is estimated from the duration.
    private func startStream(source: String, cacheKey: String?, gen: Int) {
        isDecoding = true
        let bufferFrames = streamBufferFrames
        decodeQueue.async { [weak self] in
            guard let self = self, !self.isStopped(gen) else { return }
            do {
                let filePath = try WebMSourceResolver.localPath(for: source, cacheKey: cacheKey) { [weak self] in
                    self?.isStopped(gen) ?? true
                }
                guard self.probeVideo(path: filePath) else {
                    throw WebMSourceError(message: "Could not read video size and frame rate")
                }
                self.log("Streaming: \(self.videoWidth)x\(self.videoHeight) @ \(self.frameRate)fps")
                let uvSize = (self.videoWidth / 2) * (self.videoHeight / 2)
                let frames = FrameStream(
                    path: filePath, outputOptions: "-f rawvideo -pix_fmt yuva420p",
                    frameSize: self.videoWidth * self.videoHeight * 2 + uvSize * 2, bufferFrames: bufferFrames,
                    loop: { [weak self] in self?.loop ?? false })
                DispatchQueue.main.async {
                    guard !self.isStopped(gen) else {
                        frames.close()
                        return
                    }
                    self.isDecoding = false
                    self.startStreaming(frames, source: source)
                }
            } catch {
                self.reportDecodeError(error, source: source, gen: gen)
            }
        }
    }

    private func startStreaming(_ frames: FrameStream, source: String) {
        guard let device = sharedMetalDevice, let textureSets = makeStreamTextures(device: device) else {
            frames.close()
            onError?("Failed to play \(source): could not create Metal textures")
            return
        }
        frameStream = frames
        streamTextures = textureSets
        nextStreamSet = 0
        currentStreamTextures = nil
        streamLoaded = false
        frameInterval = 1.0 / frameRate
        isPlaying = true
        startDisplayLink()
    }

    private func makeStreamTextures(device: MTLDevice) -> [PlaneTextures]? {
        var sets: [PlaneTextures] = []
        for _ in 0..<Self.streamTextureSets {
            guard let y = createTexture(device: device, width: videoWidth, height: videoHeight),
                  let u = createTexture(device: device, width: videoWidth / 2, height: videoHeight / 2),
                  let v = createTexture(device: device, width: videoWidth / 2, height: videoHeight / 2),
                  let a = createTexture(device: device, width: videoWidth, height: videoHeight) else {
                return nil
            }
            sets.append(PlaneTextures(y: y, u: u, v: v, a: a))
        }
        return sets
    }

    /// Called on display link ticks when a frame is due. If the decoder is behind, the last
    /// frame stays on screen.
    private func showNextStreamFrame(_ frames: FrameStream) {
        let poll: FrameStream.Poll
        do {
            poll = try frames.poll()
        } catch {
            let message = "Failed to play \(source ?? ""): \(error.localizedDescription)"
            NSLog("[FFmpegKitAlphaGPUView] %@", message)
            stop()
            onError?(message)
            return
        }

        switch poll {
        case .waiting:
            return
        case .ended:
            let played = streamLoaded
            stop()
            if played {
                onEnd?()
            } else {
                onError?("No frames decoded from \(source ?? "")")
            }
        case .frame(let frame):
            let textures = streamTextures[nextStreamSet]
            nextStreamSet = (nextStreamSet + 1) % streamTextures.count
            upload(frame, into: textures)
            frames.recycle(frame)
            currentStreamTextures = textures
            if !streamLoaded {
                streamLoaded = true
                let totalFrames = Int((durationSeconds * frameRate).rounded())
                onLoad?(totalFrames, videoWidth, videoHeight)
            }
            metalView.setNeedsDisplay()
        }
    }

    private func upload(_ frame: StreamFrame, into textures: PlaneTextures) {
        let uvWidth = videoWidth / 2
        let uvHeight = videoHeight / 2
        let ySize = videoWidth * videoHeight
        let uvSize = uvWidth * uvHeight
        let base = UnsafeRawPointer(frame.bytes)
        textures.y.replace(region: MTLRegionMake2D(0, 0, videoWidth, videoHeight), mipmapLevel: 0,
                           withBytes: base, bytesPerRow: videoWidth)
        textures.u.replace(region: MTLRegionMake2D(0, 0, uvWidth, uvHeight), mipmapLevel: 0,
                           withBytes: base + ySize, bytesPerRow: uvWidth)
        textures.v.replace(region: MTLRegionMake2D(0, 0, uvWidth, uvHeight), mipmapLevel: 0,
                           withBytes: base + ySize + uvSize, bytesPerRow: uvWidth)
        textures.a.replace(region: MTLRegionMake2D(0, 0, videoWidth, videoHeight), mipmapLevel: 0,
                           withBytes: base + ySize + uvSize * 2, bytesPerRow: videoWidth)
    }

    private func closeStream() {
        frameStream?.close()
        frameStream = nil
        streamTextures = []
        currentStreamTextures = nil
    }

    private func startPlaying(_ textures: GPUTextureCache) {
        currentTextureCache = textures
        frameRate = textures.frameRate
        frameInterval = 1.0 / frameRate
        currentFrameIndex = 0
        isPlaying = true
        onLoad?(textures.frameCount, textures.width, textures.height)
        startDisplayLink()
    }

    private func isStopped(_ gen: Int) -> Bool {
        return shouldStop || gen != generation
    }

    @objc public func stop() {
        shouldStop = true
        isPlaying = false
        isDecoding = false
        currentFrameIndex = 0
        stopDisplayLink()
        closeStream()
    }
    
    private func startDisplayLink() {
        guard displayLink == nil else { return }
        
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        // The display link only has to tick as often as the clip's frames change.
        let rate = Float(frameRate)
        if #available(iOS 15.0, *) {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: min(rate, 30), maximum: rate, preferred: rate)
        } else {
            displayLink?.preferredFramesPerSecond = Int(rate.rounded(.up))
        }
        displayLink?.add(to: .main, forMode: .common)
        lastFrameTime = CACurrentMediaTime()
        frameInterval = 1.0 / frameRate
    }
    
    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard isPlaying, !shouldStop, !paused, frameStream != nil || currentTextureCache != nil else {
            return
        }
        
        let currentTime = link.timestamp
        let elapsed = currentTime - lastFrameTime
        
        // Check if enough time has passed for next frame
        if elapsed >= frameInterval {
            lastFrameTime = currentTime - (elapsed.truncatingRemainder(dividingBy: frameInterval))

            if let frames = frameStream {
                showNextStreamFrame(frames)
                return
            }
            guard let cache = currentTextureCache else { return }
            
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
                    onEnd?()
                }
            }
        }
    }

    // MARK: - Decoding

    private func decodeToTextures(source: String, cacheKey: String?, gen: Int) throws -> GPUTextureCache {
        guard let device = sharedMetalDevice else {
            throw WebMSourceError(message: "Metal is not available")
        }

        let filePath = try WebMSourceResolver.localPath(for: source, cacheKey: cacheKey) { [weak self] in
            self?.isStopped(gen) ?? true
        }

        guard probeVideo(path: filePath) else {
            throw WebMSourceError(message: "Could not read video size and frame rate")
        }
        log("Decoding: \(videoWidth)x\(videoHeight) @ \(frameRate)fps")

        // FFmpegKit can't pipe raw output, so frames go through a temp file and onto the GPU.
        let rawFile = NSTemporaryDirectory() + "webm_decode_\(UUID().uuidString).yuva"
        defer { try? FileManager.default.removeItem(atPath: rawFile) }

        // CRITICAL: Use libvpx-vp9 codec for proper VP9 alpha decoding
        let command = "-c:v libvpx-vp9 -i \"\(filePath)\" -an -f rawvideo -pix_fmt yuva420p \"\(rawFile)\""
        guard let session = FFmpegKit.execute(command) else {
            throw WebMSourceError(message: "FFmpeg did not start")
        }
        guard ReturnCode.isSuccess(session.getReturnCode()) else {
            let output = session.getOutput() ?? ""
            throw WebMSourceError(message: "FFmpeg decode failed: \(output.suffix(600))")
        }

        // Calculate frame sizes for yuva420p
        let ySize = videoWidth * videoHeight
        let uvSize = (videoWidth / 2) * (videoHeight / 2)
        let aSize = ySize
        let frameSize = ySize + uvSize + uvSize + aSize
        let uvWidth = videoWidth / 2
        let uvHeight = videoHeight / 2

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: rawFile)[.size] as? Int) ?? 0
        let totalFrames = fileSize / frameSize
        log("Uploading \(totalFrames) frames, \(String(format: "%.2f", Double(frameSize * totalFrames) / 1024.0 / 1024.0)) MB GPU memory")

        guard totalFrames > 0, let fileHandle = FileHandle(forReadingAtPath: rawFile) else {
            throw WebMSourceError(message: "No frames decoded")
        }
        defer { try? fileHandle.close() }

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
        for _ in 0..<totalFrames {
            guard !isStopped(gen) else { break }

            autoreleasepool {
                let frameData = fileHandle.readData(ofLength: frameSize)
                guard frameData.count == frameSize else {
                    return
                }

                guard let yTex = createTexture(device: device, width: videoWidth, height: videoHeight),
                      let uTex = createTexture(device: device, width: uvWidth, height: uvHeight),
                      let vTex = createTexture(device: device, width: uvWidth, height: uvHeight),
                      let aTex = createTexture(device: device, width: videoWidth, height: videoHeight) else {
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
        }

        guard !isStopped(gen) else { throw WebMSourceError(message: "Stopped") }
        guard yTextures.count == totalFrames else {
            throw WebMSourceError(message: "Uploaded \(yTextures.count) of \(totalFrames) frames")
        }

        return GPUTextureCache(
            yTextures: yTextures,
            uTextures: uTextures,
            vTextures: vTextures,
            aTextures: aTextures,
            width: videoWidth,
            height: videoHeight,
            frameRate: frameRate
        )
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

    /// The latest streamed frame, or the current frame of the texture cache.
    private func texturesToDraw() -> PlaneTextures? {
        if let streamed = currentStreamTextures { return streamed }
        guard let cache = currentTextureCache, currentFrameIndex < cache.frameCount else { return nil }
        return PlaneTextures(
            y: cache.yTextures[currentFrameIndex],
            u: cache.uTextures[currentFrameIndex],
            v: cache.vTextures[currentFrameIndex],
            a: cache.aTextures[currentFrameIndex])
    }

    public func draw(in view: MTKView) {
        guard let pipeline = sharedPipelineState,
              let commandQueue = sharedCommandQueue,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let textures = texturesToDraw() else {
            return
        }
        let yTex = textures.y
        let uTex = textures.u
        let vTex = textures.v
        let aTex = textures.a

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

        durationSeconds = (json["format"] as? [String: Any])
            .flatMap { $0["duration"] as? String }
            .flatMap(Double.init) ?? 0

        for stream in streams {
            if let codecType = stream["codec_type"] as? String, codecType == "video" {
                videoWidth = stream["width"] as? Int ?? 0
                videoHeight = stream["height"] as? Int ?? 0

                frameRate = VideoProbe.frameRate(
                    average: stream["avg_frame_rate"] as? String, base: stream["r_frame_rate"] as? String)

                return videoWidth > 0 && videoHeight > 0
            }
        }

        return false
    }

    private func log(_ message: @autoclosure () -> String) {
        if verbose { NSLog("[FFmpegKitAlphaGPUView] %@", message()) }
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