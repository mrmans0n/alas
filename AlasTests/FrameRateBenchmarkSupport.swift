import AppKit
import QuartzCore
import Testing

/// Shared pacing and statistics for the opt-in on-screen frame-rate
/// benchmarks (`ACPTranscriptFrameRateBenchmark`,
/// `DiffReviewFrameRateBenchmark`).
///
/// Frames are paced by the window's display link, so a frame that blows the
/// budget shows up as a late tick exactly as it would for a user. The goal is
/// 60fps at p95: the 95th-percentile tick interval must fit in 1/60 s.
@MainActor
enum FrameRateBenchmark {
    /// Display-link intervals are vsync-quantized: a dropped frame reads as
    /// ~33ms, an on-time one as ~16.7ms plus jitter. A p95 under 1.25 frames
    /// therefore means fewer than 5% of frames dropped, i.e. 60fps at p95.
    static let budgetMs = budgetMs(fps: 60)

    /// The p95 budget for `fps`: 1.25 frames, the same allowance for vsync
    /// quantization as the 60fps budget.
    static func budgetMs(fps: Double) -> Double { 1.25 * 1000 / fps }

    /// Orders `window` front and active. A covered window gets no
    /// display-link ticks.
    static func show(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.layoutIfNeeded()
    }

    /// Calls `step` once per display-link tick of `view`'s screen with the
    /// elapsed time since the previous tick, until it returns false or
    /// `maxFrames` ticks pass.
    ///
    /// `<envPrefix>_CLOCK=runloop` paces frames with a 60Hz timer instead, for
    /// a locked or sleeping display where no display link fires.
    static func drive(
        on view: NSView,
        envPrefix: String,
        maxFrames: Int,
        _ step: @escaping (Double) -> Bool
    ) async -> FrameStats {
        let cpuAtStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var stats = await paced(on: view, envPrefix: envPrefix, maxFrames: maxFrames, step)
        stats.mainThreadCPUMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuAtStart) / 1e6
        return stats
    }

    private static func paced(
        on view: NSView,
        envPrefix: String,
        maxFrames: Int,
        _ step: @escaping (Double) -> Bool
    ) async -> FrameStats {
        if ProcessInfo.processInfo.environment["\(envPrefix)_CLOCK"] == "runloop" {
            return await RunLoopFrameDriver(maxFrames: maxFrames, step: step).run()
        }
        return await withCheckedContinuation { continuation in
            let driver = DisplayLinkFrameDriver(maxFrames: maxFrames, step: step) { intervals, times in
                continuation.resume(returning: FrameStats(intervalsMs: intervals, tickTimes: times))
            }
            driver.start(on: view)
            driver.failIfSilent(after: 5)
        }
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }
}

@MainActor
private final class DisplayLinkFrameDriver: NSObject {
    private let maxFrames: Int
    private let step: (Double) -> Bool
    private let completion: ([Double], [CFTimeInterval]) -> Void
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var intervals: [Double] = []
    private var tickTimes: [CFTimeInterval] = []
    private var retainSelf: DisplayLinkFrameDriver?

    init(maxFrames: Int, step: @escaping (Double) -> Bool, completion: @escaping ([Double], [CFTimeInterval]) -> Void) {
        self.maxFrames = maxFrames
        self.step = step
        self.completion = completion
    }

    func start(on view: NSView) {
        retainSelf = self
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Ends the run if the display link never ticks (a hidden window or a
    /// sleeping display), rather than leaving the test waiting forever.
    func failIfSilent(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.link != nil, self.lastTimestamp == nil else { return }
            Issue.record("no display-link ticks after \(seconds)s; is the window visible and the display awake?")
            self.link?.invalidate()
            self.link = nil
            self.completion([], [])
            self.retainSelf = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTimestamp.map { now - $0 } ?? (1.0 / 60.0)
        if lastTimestamp != nil {
            intervals.append(dt * 1000)
            tickTimes.append(now)
        }
        lastTimestamp = now
        if !step(dt) || intervals.count >= maxFrames {
            link.invalidate()
            self.link = nil
            completion(intervals, tickTimes)
            retainSelf = nil
        }
    }
}

/// Display-independent pacing: a 60Hz timer drives the frames while a run
/// loop observer records every main-thread busy stretch (wake to sleep, which
/// includes SwiftUI updates and the Core Animation commit). A stretch longer
/// than a frame is reported the way a display link reports it: one late
/// tick spanning ⌈duration / frame⌉ vsyncs, with the vsyncs it swallowed
/// never delivered.
@MainActor
private final class RunLoopFrameDriver {
    private static let frame = 1.0 / 60.0
    private let maxFrames: Int
    private let step: (Double) -> Bool
    private var timer: Timer?

    init(maxFrames: Int, step: @escaping (Double) -> Bool) {
        self.maxFrames = maxFrames
        self.step = step
    }

    func run() async -> FrameStats {
        var stretches: [(start: CFTimeInterval, end: CFTimeInterval)] = []
        var wokeAt: CFTimeInterval?
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity([.afterWaiting, .beforeWaiting]).rawValue, true, 0
        ) { _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting {
                wokeAt = now
            } else if let start = wokeAt {
                stretches.append((start, now))
                wokeAt = nil
            }
        }

        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }

        let started = CACurrentMediaTime()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var frames = 0
            var last = started
            let timer = Timer(timeInterval: Self.frame, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let now = CACurrentMediaTime()
                    frames += 1
                    let keepGoing = self.step(now - last)
                    last = now
                    if !keepGoing || frames >= self.maxFrames {
                        self.timer?.invalidate()
                        continuation.resume()
                    }
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        let elapsed = CACurrentMediaTime() - started

        var intervals: [Double] = []
        var tickTimes: [CFTimeInterval] = []
        var covered = 0
        for stretch in stretches where stretch.end - stretch.start > Self.frame {
            let frames = Int((stretch.end - stretch.start) / Self.frame) + 1
            intervals.append(Double(frames) * Self.frame * 1000)
            tickTimes.append(stretch.end)
            covered += frames
        }
        let total = Int(elapsed / Self.frame)
        // One delivered tick per long stretch, plus every vsync no stretch swallowed.
        for _ in 0..<max(0, total - covered) {
            intervals.append(Self.frame * 1000)
            tickTimes.append(0)
        }
        return FrameStats(intervalsMs: intervals, tickTimes: tickTimes)
    }
}

struct FrameStats {
    let intervalsMs: [Double]
    var tickTimes: [CFTimeInterval] = []
    /// Main-thread CPU time spent during the run. Frame intervals swing with
    /// whatever else the machine is doing; this tracks the work itself, so it
    /// is the steadier number for comparing two builds.
    var mainThreadCPUMs: Double = 0

    /// Dropped frames whose interval contains at least one of `events`.
    func hitches(containing events: [CFTimeInterval]) -> Int {
        zip(intervalsMs, tickTimes).filter { interval, end in
            interval > 1.5 * 1000 / 60 && events.contains { $0 <= end && $0 > end - interval / 1000 }
        }.count
    }

    private func percentile(_ p: Double) -> Double {
        let sorted = intervalsMs.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    var p50: Double { percentile(0.5) }
    var p95: Double { percentile(0.95) }
    var p99: Double { percentile(0.99) }
    var max: Double { intervalsMs.max() ?? 0 }
    /// The display's effective refresh rate during the run. ProMotion panels
    /// switch between 60 and 120Hz, so compare runs only at matching rates.
    var observedHz: Double {
        let elapsed = intervalsMs.reduce(0, +)
        return elapsed > 0 ? Double(intervalsMs.count) * 1000 / elapsed : 0
    }
    var hitches: Int { intervalsMs.filter { $0 > 1.5 * 1000 / 60 }.count }
    /// Vsyncs missed in total: a 50ms tick at 60Hz drops two frames.
    var dropped: Int { intervalsMs.reduce(0) { $0 + Swift.max(0, Int(($1 / (1000 / 60)).rounded()) - 1) } }

    /// Prints one summary line tagged `label`, and appends it to the file
    /// named by `<envPrefix>_OUT` when set.
    func report(_ name: String, label: String, envPrefix: String) {
        let line = String(
            format: "%@ %@ hz=%.0f cpu=%.0fms frames=%d p50=%.1fms p95=%.1fms p99=%.1fms max=%.1fms hitches=%d dropped=%d",
            label, name, observedHz, mainThreadCPUMs, intervalsMs.count, p50, p95, p99, max, hitches, dropped
        )
        print(line)
        if let path = ProcessInfo.processInfo.environment["\(envPrefix)_OUT"],
           let handle = FileHandle(forWritingAtPath: path) ?? {
               FileManager.default.createFile(atPath: path, contents: nil)
               return FileHandle(forWritingAtPath: path)
           }() {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
    }
}

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * Double(next() >> 11) / Double(1 << 53)
    }

    mutating func chance(_ p: Double) -> Bool { uniform(0, 1) < p }

    /// A log-normal sample with the given median and 90th percentile.
    mutating func lognormal(p50: Double, p90: Double, cap: Int) -> Int {
        let sigma = log(p90 / p50) / 1.2816
        let u1 = Swift.max(uniform(0, 1), 1e-9), u2 = uniform(0, 1)
        let z = sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        return Swift.min(cap, Swift.max(1, Int(p50 * exp(sigma * z))))
    }
}
