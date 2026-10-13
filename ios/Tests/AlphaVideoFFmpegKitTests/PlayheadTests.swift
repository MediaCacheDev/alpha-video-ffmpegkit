import QuartzCore
import XCTest
@testable import AlphaVideoFFmpegKit

/// A value shared between the test and the playback thread.
private final class Shared<T> {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func update(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
}

final class PlayheadTests: XCTestCase {

    private static let fps = 200.0
    private static let frames = 20

    private let playing = Shared(false)
    private let loop = Shared(false)
    private let stopped = Shared(false)
    private let loads = Shared(0)
    private let ends = Shared(0)
    private let shown = Shared<[Int]>([])
    private let finished = Shared(false)
    private lazy var playhead = makePlayhead()

    private func makePlayhead() -> Playhead {
        Playhead(frameRate: Self.fps, playing: { [playing] in playing.get() }, loop: { [loop] in loop.get() },
                 stopped: { [stopped] in stopped.get() })
    }

    private func startPreloaded(_ p: Playhead? = nil) {
        let p = p ?? playhead
        let (shown, loads, ends, finished) = (shown, loads, ends, finished)
        Thread {
            p.playPreloaded(frames: Self.frames, show: { f in shown.update { $0.append(f) } },
                            onLoad: { loads.update { $0 += 1 } }, onEnd: { ends.update { $0 += 1 } })
            finished.set(true)
        }.start()
        waitFor("onLoad") { loads.get() == 1 }
    }

    private func waitFor(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)", file: file, line: line) }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    private func sleep(_ ms: Double) { Thread.sleep(forTimeInterval: ms / 1000) }
    private var last: Int { shown.get().last ?? -1 }

    override func tearDown() {
        stopped.set(true)
        waitFor("playback to stop") { finished.get() || loads.get() == 0 }
    }

    func testShowsTheFirstFrameBeforeOnLoadAndHoldsItWhilePaused() {
        startPreloaded()
        XCTAssertEqual(shown.get(), [0])
        sleep(100)
        XCTAssertEqual(shown.get(), [0])
    }

    func testPlaysEveryFrameInOrderThenEndsOnceWithoutLooping() {
        startPreloaded()
        playing.set(true)
        waitFor("onEnd") { ends.get() == 1 }
        XCTAssertEqual(shown.get(), Array(0..<Self.frames))
        sleep(50)
        XCTAssertEqual(ends.get(), 1)
        XCTAssertEqual(last, Self.frames - 1)
    }

    func testLoopsBackToTheFirstFrame() {
        loop.set(true)
        startPreloaded()
        playing.set(true)
        waitFor("a second pass") { shown.get().count > Self.frames + 3 }
        let frames = shown.get()
        XCTAssertEqual(Array(frames[(Self.frames - 1)...(Self.frames + 1)]), [Self.frames - 1, 0, 1])
        XCTAssertEqual(ends.get(), 0)
    }

    func testPlayingAgainAfterTheEndStartsFromTheFirstFrame() {
        startPreloaded()
        playing.set(true)
        waitFor("onEnd") { ends.get() == 1 }
        playing.set(false)
        sleep(30)
        shown.set([])
        playing.set(true)
        waitFor("playback to restart") { shown.get().count >= 3 }
        XCTAssertEqual(Array(shown.get().prefix(3)), [0, 1, 2])
    }

    func testSeeksShowTheirFrameWhilePausedAndClampToTheClip() {
        startPreloaded()
        for (target, expected) in [(7, 7), (-3, 0), (1000, Self.frames - 1), (12, 12)] {
            playhead.seekToFrame(target)
            waitFor("seekToFrame(\(target)) to show \(expected)") { last == expected }
        }
        sleep(50)
        XCTAssertEqual(last, 12)
    }

    func testSeekToTimeShowsTheFrameShowingAtThatTime() {
        startPreloaded()
        let cases: [(Double, Int)] = [(5 / Self.fps, 5), (5 / Self.fps * 0.999, 4), (0, 0), (-1, 0), (.nan, 0),
                                      (60, Self.frames - 1)]
        for (time, expected) in cases {
            playhead.seekToFrame(Self.frames / 2)
            waitFor("reset") { last == Self.frames / 2 }
            playhead.seekToTime(time)
            waitFor("seekToTime(\(time)) to show \(expected)") { last == expected }
        }
    }

    func testSeeksBeforeLoadAreIgnored() {
        let fresh = makePlayhead()
        fresh.seekToFrame(5)
        startPreloaded(fresh)
        sleep(50)
        XCTAssertEqual(shown.get(), [0])
    }

    func testASeekAfterTheEndPlaysOnFromThere() {
        startPreloaded()
        playing.set(true)
        waitFor("onEnd") { ends.get() == 1 }
        shown.set([])
        playhead.seekToFrame(15)
        waitFor("playback from 15 to the end") { last == Self.frames - 1 && shown.get().count >= Self.frames - 15 }
        XCTAssertEqual(shown.get(), [15, 16, 17, 18, 19])
        waitFor("a second onEnd") { ends.get() == 2 }
    }

    func testStopsWhenStopped() {
        startPreloaded()
        playing.set(true)
        stopped.set(true)
        waitFor("playPreloaded to return") { finished.get() }
    }
}

final class FrameClockTests: XCTestCase {

    private static let fps = 100.0
    private static let intervalMs = 10.0

    private func elapsedMs(_ body: () -> Void) -> Double {
        let start = CACurrentMediaTime()
        body()
        return (CACurrentMediaTime() - start) * 1000
    }

    func testPacesFramesAtTheFrameRate() {
        var clock = FrameClock(frameRate: Self.fps)
        let ms = elapsedMs { for _ in 0..<20 { clock.awaitNextFrame() } }
        // 20 intervals; sleeps can overrun, but the clock keeps the average.
        XCTAssertGreaterThanOrEqual(ms, 20 * Self.intervalMs - 2)
        XCTAssertLessThan(ms, 20 * Self.intervalMs + 60)
    }

    func testDoesNotRushToCatchUpAfterAStall() {
        var clock = FrameClock(frameRate: Self.fps)
        for _ in 0..<2 { clock.awaitNextFrame() }
        Thread.sleep(forTimeInterval: 10 * Self.intervalMs / 1000)
        // The stall is dropped: the next frame is due now and the ones after keep the rate,
        // rather than ten frames firing back to back.
        let ms = elapsedMs { for _ in 0..<5 { clock.awaitNextFrame() } }
        XCTAssertGreaterThanOrEqual(ms, 4 * Self.intervalMs - 2)
    }

    func testRestartMakesTheNextFrameDueOneIntervalFromNow() {
        var clock = FrameClock(frameRate: Self.fps)
        Thread.sleep(forTimeInterval: 3 * Self.intervalMs / 1000)
        clock.restart()
        let ms = elapsedMs { clock.awaitNextFrame() }
        XCTAssertGreaterThanOrEqual(ms, Self.intervalMs - 2)
    }
}
