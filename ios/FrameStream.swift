import Foundation
import ffmpegkit

/// One decoded frame, in a buffer that `FrameStream` reuses once it's handed back.
final class StreamFrame {
    let bytes: UnsafeMutableRawPointer
    let count: Int

    init(count: Int) {
        self.bytes = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        self.count = count
    }

    deinit {
        bytes.deallocate()
    }
}

/// Decodes a local file while it plays, for stream mode.
///
/// FFmpeg writes raw frames into an FFmpegKit named pipe, and a reader thread fills a fixed
/// pool of frame buffers. When every buffer is waiting to be shown, the reader stops reading,
/// the pipe fills and FFmpeg blocks, so memory stays at `bufferFrames × frameSize` however long
/// the clip is. A looping clip is decoded again from the start for each pass; the buffered
/// frames cover the restart.
///
/// FFmpeg runs on a thread of its own rather than through FFmpegKit's async queue: a stream
/// holds its session for as long as it plays.
final class FrameStream {

    static let defaultBufferFrames = 15

    enum Poll {
        case frame(StreamFrame)
        /// The decoder is behind; keep showing the last frame.
        case waiting
        /// A clip that doesn't loop has been shown to the end.
        case ended
    }

    private let path: String
    private let outputOptions: String
    private let frameSize: Int
    private let loop: () -> Bool

    private let condition = NSCondition()
    private var free: [StreamFrame]
    private var ready: [StreamFrame] = []
    private var ended = false
    private var failure: String?
    private var closed = false
    private var session: FFmpegSession?

    /// - Parameters:
    ///   - outputOptions: FFmpeg options for the raw output, e.g. `-f rawvideo -pix_fmt yuva420p`
    ///   - loop: read at the end of each pass: whether to decode the clip again
    init(path: String, outputOptions: String, frameSize: Int, bufferFrames: Int, loop: @escaping () -> Bool) {
        self.path = path
        self.outputOptions = outputOptions
        self.frameSize = frameSize
        self.loop = loop
        self.free = (0..<max(1, bufferFrames)).map { _ in StreamFrame(count: frameSize) }
        let reader = Thread { [self] in run() }
        reader.name = "WebMAlphaStream"
        reader.start()
    }

    /// The next frame if one is decoded, without waiting. Throws if decoding failed.
    func poll() throws -> Poll {
        condition.lock()
        defer { condition.unlock() }
        if !ready.isEmpty { return .frame(ready.removeFirst()) }
        guard ended else { return .waiting }
        if let failure = failure { throw WebMSourceError(message: failure) }
        return .ended
    }

    /// The next frame, waiting for the decoder if it's behind. Returns nil once a clip that
    /// doesn't loop has ended, or when cancelled. Throws if decoding failed.
    func next(isCancelled: () -> Bool) throws -> StreamFrame? {
        condition.lock()
        defer { condition.unlock() }
        while ready.isEmpty && !ended && !closed {
            if isCancelled() { return nil }
            condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        if closed || isCancelled() { return nil }
        if !ready.isEmpty { return ready.removeFirst() }
        if let failure = failure { throw WebMSourceError(message: failure) }
        return nil
    }

    func recycle(_ frame: StreamFrame) {
        condition.lock()
        free.append(frame)
        condition.signal()
        condition.unlock()
    }

    /// Returns at once; the reader thread stops FFmpeg and exits on its own.
    func close() {
        condition.lock()
        closed = true
        let current = session
        condition.broadcast()
        condition.unlock()
        if let current = current { FFmpegKit.cancel(current.getId()) }
    }

    private var isClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed
    }

    private func run() {
        var failure: String?
        while failure == nil && !isClosed {
            failure = decodePass()
            if !loop() { break }
        }
        condition.lock()
        ended = true
        if !closed { self.failure = failure }
        condition.broadcast()
        condition.unlock()
    }

    /// Decodes the clip once, from the start, into `ready`. Returns an error message.
    private func decodePass() -> String? {
        guard let pipe = FFmpegKitConfig.registerNewFFmpegPipe() else { return "Cannot create an FFmpeg pipe" }
        defer { FFmpegKitConfig.closeFFmpegPipe(pipe) }

        // libvpx-vp9 is the decoder that reads the alpha plane; FFmpeg's native vp9 ignores it.
        // -y: the pipe already exists, and FFmpeg would otherwise refuse to overwrite it.
        let command = "-c:v libvpx-vp9 -i \"\(path)\" -an \(outputOptions) -y \"\(pipe)\""
        guard let pass = FFmpegSession.create(FFmpegKitConfig.parseArguments(command)) else {
            return "FFmpeg did not start"
        }
        condition.lock()
        session = pass
        condition.unlock()

        let gate = ReaderGate(pipe: pipe)
        let decoded = DispatchSemaphore(value: 0)
        let decoder = Thread {
            FFmpegKitConfig.ffmpegExecute(pass)
            gate.releaseReader()
            decoded.signal()
        }
        decoder.name = "WebMAlphaDecode"
        decoder.start()
        readFrames(from: pipe, gate: gate, session: pass)
        decoded.wait()

        if isClosed { return nil }
        guard ReturnCode.isSuccess(pass.getReturnCode()) else {
            return "FFmpeg decode failed: \((pass.getOutput() ?? "").suffix(600))"
        }
        return nil
    }

    private func readFrames(from pipe: String, gate: ReaderGate, session: FFmpegSession) {
        // Opening a pipe for reading blocks until FFmpeg opens it for writing.
        let fd = open(pipe, O_RDONLY)
        gate.markOpened()
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }

        while let frame = takeFreeFrame() {
            guard readFully(fd, into: frame) else {
                recycle(frame)
                return
            }
            condition.lock()
            ready.append(frame)
            condition.broadcast()
            condition.unlock()
        }
        // Closed. FFmpeg may be blocked writing into the full pipe; closing the pipe under it
        // would raise SIGPIPE, so cancel it and read what's left until it exits.
        FFmpegKit.cancel(session.getId())
        drain(fd)
    }

    /// Nil once closed.
    private func takeFreeFrame() -> StreamFrame? {
        condition.lock()
        defer { condition.unlock() }
        while free.isEmpty && !closed { condition.wait() }
        return closed ? nil : free.removeLast()
    }

    /// False at the end of the output; a partial last frame is dropped.
    private func readFully(_ fd: Int32, into frame: StreamFrame) -> Bool {
        var filled = 0
        while filled < frameSize {
            let n = read(fd, frame.bytes + filled, frameSize - filled)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            filled += n
        }
        return true
    }

    private func drain(_ fd: Int32) {
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = scratch.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
        }
    }
}

/// If FFmpeg fails before it opens its output, the reader stays blocked opening the pipe.
/// When FFmpeg is done, a short-lived writer lets that open return, and the reader then sees
/// the end of the output.
private final class ReaderGate {
    private static let attempts = 50
    private static let waitMicroseconds: useconds_t = 20_000

    private let pipe: String
    private let lock = NSLock()
    private var opened = false

    init(pipe: String) {
        self.pipe = pipe
    }

    func markOpened() {
        lock.lock()
        opened = true
        lock.unlock()
    }

    func releaseReader() {
        for _ in 0..<Self.attempts {
            if isOpened { return }
            let fd = open(pipe, O_WRONLY | O_NONBLOCK)
            if fd >= 0 {
                Darwin.close(fd)
                return
            }
            // ENXIO: the reader hasn't opened the pipe yet.
            usleep(Self.waitMicroseconds)
        }
    }

    private var isOpened: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }
}
