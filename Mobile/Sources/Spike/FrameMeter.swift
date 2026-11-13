import SwiftUI
import UIKit

struct FrameReport {
    var fps: Double
    var hitchMsPerSecond: Double
    var worstFrameMs: Double
    var openMs: Double?
    /// The same three figures since the last `resetRun()`, so a whole scenario reads as one number.
    var run = FrameStats()
}

struct FrameStats {
    var fps: Double = 0
    var hitchMsPerSecond: Double = 0
    var worstFrameMs: Double = 0
}

/// Ticks, lateness and worst frame accumulated over a span of display-link time.
private struct FrameTotals {
    var start: CFTimeInterval = 0
    var ticks = 0
    var lateness: CFTimeInterval = 0
    var worst: CFTimeInterval = 0

    mutating func add(lateness late: CFTimeInterval, frame: CFTimeInterval) {
        ticks += 1
        lateness += late
        worst = max(worst, frame)
    }

    func stats(at now: CFTimeInterval) -> FrameStats {
        let elapsed = now - start
        guard elapsed > 0 else { return FrameStats() }
        return FrameStats(fps: Double(ticks) / elapsed, hitchMsPerSecond: lateness * 1000 / elapsed, worstFrameMs: worst * 1000)
    }
}

/// Measures frame pacing with a display link. It sees main-thread and commit lateness only, not
/// render-server or GPU hitches (glass blur, for one); confirm those with Instruments. The report
/// refreshes once a second so the HUD does not add a per-frame SwiftUI update to what it measures.
@MainActor @Observable
final class FrameMeter {
    private(set) var report = FrameReport(fps: 0, hitchMsPerSecond: 0, worstFrameMs: 0, openMs: nil)

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var previousTimestamp: CFTimeInterval?
    @ObservationIgnored private var previousTarget: CFTimeInterval = 0
    @ObservationIgnored private var window = FrameTotals()
    @ObservationIgnored private var run = FrameTotals()
    @ObservationIgnored private var runResetPending = true
    @ObservationIgnored private var openStart: CFTimeInterval?
    @ObservationIgnored private var laidOut = false

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: Ticker(meter: self), selector: #selector(Ticker.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        previousTimestamp = nil
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    func markOpened(at start: CFTimeInterval) {
        openStart = start
        laidOut = false
        report.openMs = nil
    }

    /// Starts the run totals over from the next tick.
    func resetRun() {
        runResetPending = true
        report.run = FrameStats()
    }

    /// Pass as the scroller's `onFirstLayout`; the next tick closes the open measurement.
    func markFirstLayout() {
        laidOut = true
    }

    fileprivate func tick(_ link: CADisplayLink) {
        defer {
            previousTimestamp = link.timestamp
            previousTarget = link.targetTimestamp
        }
        if laidOut, let openStart {
            report.openMs = (CACurrentMediaTime() - openStart) * 1000
            self.openStart = nil
        }
        // A reset starts the run at this tick, so this tick's frame belongs to the span before it.
        let runStarts = runResetPending
        if runStarts {
            run = FrameTotals(start: link.timestamp)
            runResetPending = false
        }
        guard let previousTimestamp else {
            window = FrameTotals(start: link.timestamp)
            return
        }
        let late = max(0, link.timestamp - previousTarget)
        let frame = link.timestamp - previousTimestamp
        window.add(lateness: late, frame: frame)
        if !runStarts { run.add(lateness: late, frame: frame) }
        guard link.timestamp - window.start >= 1 else { return }
        let second = window.stats(at: link.timestamp)
        report.fps = second.fps
        report.hitchMsPerSecond = second.hitchMsPerSecond
        report.worstFrameMs = second.worstFrameMs
        report.run = run.stats(at: link.timestamp)
        window = FrameTotals(start: link.timestamp)
    }
}

/// The display link retains its target; this keeps the meter itself out of that cycle.
@MainActor
private final class Ticker: NSObject {
    weak var meter: FrameMeter?

    init(meter: FrameMeter) {
        self.meter = meter
    }

    @objc func tick(_ link: CADisplayLink) {
        meter?.tick(link)
    }
}
