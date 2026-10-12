import Foundation
import QuartzCore

/// Paces playback at the clip's frame rate. If the decoder falls more than a frame behind, the
/// clock restarts from now instead of rushing through frames to catch up.
struct FrameClock {
    private let interval: CFTimeInterval
    private var next: CFTimeInterval

    init(frameRate: Double) {
        interval = 1.0 / frameRate
        next = CACurrentMediaTime() + interval
    }

    /// The next frame is due one interval from now, as after a pause or a seek.
    mutating func restart() {
        next = CACurrentMediaTime() + interval
    }

    /// Sleeps until the next frame is due.
    mutating func awaitNextFrame() {
        let now = CACurrentMediaTime()
        if now - next > interval { next = now }
        let sleep = next - now
        next += interval
        if sleep > 0 { Thread.sleep(forTimeInterval: sleep) }
    }
}

/// Decides which frame shows when, for `FFmpegKitAlphaCPUView` in both modes. Frames advance at
/// the clip's rate while `playing` is true; while it's false the current frame stays up, and
/// seeks still show their frame. A clip that played to its end without looping starts again
/// from the first frame when playing turns true again, or from wherever a seek puts it.
///
/// The play methods run on the view's playback queue; seeks can come from any thread.
final class Playhead {
    private static let idleSeconds: TimeInterval = 0.01

    private let frameRate: Double
    private let playing: () -> Bool
    private let loop: () -> Bool
    private let stopped: () -> Bool
    private let lock = NSLock()
    private var seekRequest: Int?
    /// 0 until the first frame shows; seeks before then are ignored.
    private var frameCount = 0

    init(frameRate: Double, playing: @escaping () -> Bool, loop: @escaping () -> Bool,
         stopped: @escaping () -> Bool) {
        self.frameRate = frameRate
        self.playing = playing
        self.loop = loop
        self.stopped = stopped
    }

    /// Clamped to the clip; ignored until it has loaded.
    func seekToFrame(_ frame: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard frameCount > 0 else { return }
        seekRequest = min(max(frame, 0), frameCount - 1)
    }

    /// Seeks to the frame showing at `seconds`.
    func seekToTime(_ seconds: Double) {
        let frame = (seconds > 0 ? seconds : 0) * frameRate + 1e-6
        seekToFrame(Int(min(frame, Double(Int32.max))))
    }

    /// Preload mode: any frame can be shown straight away. `onLoad` runs once the first frame
    /// has shown. Returns once stopped.
    func playPreloaded(frames: Int, show: (Int) -> Void, onLoad: () -> Void, onEnd: () -> Void) {
        var frame = 0
        show(frame)
        setFrameCount(frames)
        onLoad()
        var clock = FrameClock(frameRate: frameRate)
        var ended = false
        var wasPlaying = false
        while !stopped() {
            let play = playing()
            var seek = takeSeek()
            if seek == nil && ended && play && !wasPlaying { seek = 0 }
            wasPlaying = play
            if let seek = seek {
                frame = seek
                ended = false
                show(frame)
                clock.restart()
                continue
            }
            if !play || ended {
                Thread.sleep(forTimeInterval: Self.idleSeconds)
                clock.restart()
                continue
            }
            clock.awaitNextFrame()
            if seekPending || !playing() { continue }
            if frame + 1 < frames {
                frame += 1
            } else if loop() {
                frame = 0
            } else {
                ended = true
                onEnd()
                continue
            }
            show(frame)
        }
    }

    /// Stream mode. A frame shows even while paused when one is owed: the first, and each
    /// seek's. A seek decodes again from its frame. `onLoad` runs once the first frame has shown.
    ///
    /// - Parameters:
    ///   - estimatedFrames: the clip's length for clamping seeks; 0 if unknown, which turns
    ///     seeking off
    ///   - open: starts decoding with the first frame at or after a time in seconds
    /// - Returns: false if the clip ended before a single frame decoded
    func playStream(estimatedFrames: Int, open: (Double) -> FrameStream, show: (StreamFrame) -> Void,
                    onLoad: () -> Void, onEnd: () -> Void) throws -> Bool {
        var frames = open(0)
        defer { frames.close() }
        let interrupted = { [unowned self] in self.stopped() || self.seekPending }
        var clock = FrameClock(frameRate: frameRate)
        var loaded = false
        var ended = false
        var wasPlaying = false
        var frameOwed = true
        while !stopped() {
            let play = playing()
            var seek = takeSeek()
            if seek == nil && ended && play && !wasPlaying { seek = 0 }
            wasPlaying = play
            if let seek = seek {
                frames.close()
                frames = open(seek > 0 ? (Double(seek) - 0.5) / frameRate : 0)
                ended = false
                frameOwed = true
            }
            if !frameOwed {
                if !play || ended {
                    Thread.sleep(forTimeInterval: Self.idleSeconds)
                    clock.restart()
                    continue
                }
                clock.awaitNextFrame()
                if seekPending || !playing() { continue }
            }
            guard let frame = try frames.next(isCancelled: interrupted) else {
                if interrupted() { continue }
                if !loaded { return false }
                ended = true
                frameOwed = false
                onEnd()
                continue
            }
            show(frame)
            frames.recycle(frame)
            frameOwed = false
            if !loaded {
                loaded = true
                setFrameCount(estimatedFrames)
                onLoad()
                clock.restart()
            }
        }
        return true
    }

    private var seekPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return seekRequest != nil
    }

    private func takeSeek() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let seek = seekRequest
        seekRequest = nil
        return seek
    }

    private func setFrameCount(_ count: Int) {
        lock.lock()
        frameCount = count
        lock.unlock()
    }
}
