import Observation
import QuartzCore

struct FrameReport {
    var fps: Double
    var hitchMsPerSecond: Double
    var worstFrameMs: Double
    var openMs: Double?
}

/// Measures frame pacing with a display link. The report refreshes once a second so the HUD
/// that shows it does not add a per-frame SwiftUI update to what it measures.
@MainActor @Observable
final class FrameMeter {
    private(set) var report = FrameReport(fps: 0, hitchMsPerSecond: 0, worstFrameMs: 0, openMs: nil)

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var previousTimestamp: CFTimeInterval?
    @ObservationIgnored private var previousTarget: CFTimeInterval = 0
    @ObservationIgnored private var windowStart: CFTimeInterval = 0
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var lateness: CFTimeInterval = 0
    @ObservationIgnored private var worst: CFTimeInterval = 0
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
        guard let previousTimestamp else {
            windowStart = link.timestamp
            return
        }
        ticks += 1
        lateness += max(0, link.timestamp - previousTarget)
        worst = max(worst, link.timestamp - previousTimestamp)
        let elapsed = link.timestamp - windowStart
        guard elapsed >= 1 else { return }
        report.fps = Double(ticks) / elapsed
        report.hitchMsPerSecond = lateness * 1000 / elapsed
        report.worstFrameMs = worst * 1000
        windowStart = link.timestamp
        ticks = 0
        lateness = 0
        worst = 0
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
