import AppKit
import Combine
import QuartzCore
import SwiftUI
import Testing
@testable import Alas

/// Frame-rate benchmark for the ACP transcript pane. Opt-in: it opens a real
/// on-screen window and runs for tens of seconds, so it only runs with
/// `TEST_RUNNER_ALAS_TRANSCRIPT_BENCH=1` in the `xcodebuild` environment.
///
/// Frames are paced by the window's display link, so a frame that blows the
/// budget shows up as a late tick exactly as it would for a user. The goal is
/// 60fps at p95: the 95th-percentile tick interval must fit in 1/60 s.
///
/// Transcripts come from `ACPTranscriptBenchmarkCorpus`, whose composition was
/// fitted to a week of real sessions on the author's machine (Alas session
/// stores plus the Claude Code and Codex logs those sessions drive).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ALAS_TRANSCRIPT_BENCH"] == "1"))
struct ACPTranscriptFrameRateBenchmark {
    /// Display-link intervals are vsync-quantized: a dropped frame reads as
    /// ~33ms, an on-time one as ~16.7ms plus jitter. A p95 under 1.25 frames
    /// therefore means fewer than 5% of frames dropped, i.e. 60fps at p95.
    static let budgetMs = 1.25 * 1000.0 / 60.0

    @Test(arguments: [false, true])
    func flingThroughHistory(collapsesFinishedToolCalls: Bool) async throws {
        let corpus = ACPTranscriptBenchmarkCorpus(seed: 7, messageCount: 650)
        let bench = try BenchWindow(messages: corpus.messages, collapsesFinishedToolCalls: collapsesFinishedToolCalls)
        defer { bench.close() }
        try await bench.settle()

        // A brisk trackpad fling: ~2400pt/s up to the top of history and back.
        var direction: CGFloat = -1
        var idleTicksAtTop = 0
        let stats = await bench.drive(maxFrames: 2400) { dt in
            let scroller = bench.scroller
            let travel = 2400 * CGFloat(dt) * direction
            let maxY = max(0, scroller.contentHeight - scroller.viewportHeight)
            let target = min(max(0, scroller.scrollY + travel), maxY)
            bench.liveScroll(to: target)
            if direction < 0, target <= 0 {
                // Head pagination grafts older rows above; keep going until
                // the window reaches the first message.
                idleTicksAtTop = bench.session.transcript.visibleHead == 0 ? idleTicksAtTop + 1 : 0
                if idleTicksAtTop > 30 { direction = 1 }
            }
            return !(direction > 0 && target >= maxY && bench.session.transcript.visibleTailBound == bench.session.transcript.messages.count)
        }
        bench.endLiveScroll()
        stats.report("fling collapse=\(collapsesFinishedToolCalls)")
        #expect(stats.p95 <= Self.budgetMs, "p95 frame \(stats.p95)ms")
    }

    @Test(arguments: [false, true])
    func streamingTurnAtTail(collapsesFinishedToolCalls: Bool) async throws {
        var corpus = ACPTranscriptBenchmarkCorpus(seed: 11, messageCount: 650)
        let bench = try BenchWindow(messages: corpus.messages, collapsesFinishedToolCalls: collapsesFinishedToolCalls)
        defer { bench.close() }
        try await bench.settle()

        let session = bench.session
        session.transcript.streamingState = .streaming
        var script = corpus.liveTurnScript()
        let updateCount = script.count
        var elapsed = 0.0
        var publishTimes: [CFTimeInterval] = [], chunkTimes: [CFTimeInterval] = []
        let observers = [
            session.transcript.objectWillChange.sink { publishTimes.append(CACurrentMediaTime()) },
        ]
        defer { observers.forEach { $0.cancel() } }
        let stats = await bench.drive(maxFrames: 900) { dt in
            elapsed += dt
            while let next = script.first, next.at <= elapsed {
                script.removeFirst()
                if case .agentMessageChunk = next.update { chunkTimes.append(CACurrentMediaTime()) }
                session.apply(next.update)
            }
            return !script.isEmpty
        }
        try await bench.settle()
        #expect(bench.scroller.distanceFromBottom < 1, "streaming left the tail \(bench.scroller.distanceFromBottom)pt below the viewport")
        session.transcript.streamingState = .idle
        stats.report("stream collapse=\(collapsesFinishedToolCalls) transcriptPublishes=\(publishTimes.count) updates=\(updateCount) hitchesWithPublish=\(stats.hitches(containing: publishTimes)) hitchesWithChunk=\(stats.hitches(containing: chunkTimes))")
        #expect(stats.p95 <= Self.budgetMs, "p95 frame \(stats.p95)ms")
    }
}

// MARK: - Harness

@MainActor
private final class BenchWindow {
    let session: ACPSession
    let window: NSWindow
    let scroller: ACPTranscriptScrollerView
    private let hosting: NSView
    private var isLiveScrolling = false

    init(messages: [ACPMessage], collapsesFinishedToolCalls: Bool) throws {
        session = ACPSession(id: "bench", agentId: "claude", worktreeId: "bench", title: "Bench")
        session.followsTranscriptTail = true
        session.transcript.messages = messages
        session.transcript.resetWindowToTail()

        let size = NSSize(width: 980, height: 1100)
        let host = ACPTranscriptScroller(
            session: session,
            transcript: session.transcript,
            contentMaxWidth: ACPChatLayout.contentMaxWidth(forChatColumnWidth: size.width),
            typography: .default,
            trustedImageRoot: nil,
            onOpenDiff: { _ in },
            onLoadFullToolCallContent: { _ in nil },
            forkTargets: [],
            onFork: { _, _ in },
            rememberedScrollAnchor: { nil },
            onRememberScrollAnchor: { _, _, _ in },
            onOpenTranscriptLink: { _ in true },
            policy: nil,
            scopeKey: "bench",
            onUserInputResponse: { _, _ in },
            onPlanResponse: { _, _ in },
            onOpenElicitationURL: { _ in true },
            onDismissElicitationURLWait: { _ in },
            onQueueEdit: { _ in },
            onQueueForceSend: { _ in },
            onQueuePromote: { _ in },
            onQueueRemove: { _ in },
            onQueueRetry: { _ in },
            onQueueReorder: { _, _ in },
            onQueueClearAll: {},
            onRetryContextRecovery: {},
            onOpenForkSource: { _ in },
            agentDisplayName: { $0 },
            collapsesFinishedToolCalls: collapsesFinishedToolCalls
        )
        hosting = NSHostingView(rootView: host.frame(width: size.width, height: size.height))
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // A covered window gets no display-link ticks.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        scroller = try #require(Self.find(ACPTranscriptScrollerView.self, in: hosting))
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    /// Lets hydration, first layout, and any deferred work finish so the
    /// measured frames start from a steady state.
    func settle() async throws {
        for _ in 0..<20 {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func liveScroll(to y: CGFloat) {
        if !isLiveScrolling {
            isLiveScrolling = true
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroller)
        }
        scroller.contentView.setBoundsOrigin(NSPoint(x: scroller.contentView.bounds.origin.x, y: y))
        scroller.reflectScrolledClipView(scroller.contentView)
    }

    func endLiveScroll() {
        guard isLiveScrolling else { return }
        isLiveScrolling = false
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroller)
    }

    /// Calls `step` once per display-link tick with the elapsed time since
    /// the previous tick, until it returns false or `maxFrames` ticks pass.
    ///
    /// `ALAS_TRANSCRIPT_BENCH_CLOCK=runloop` paces frames with a 60Hz timer
    /// instead, for a locked or sleeping display where no display link fires.
    func drive(maxFrames: Int, _ step: @escaping (Double) -> Bool) async -> FrameStats {
        if ProcessInfo.processInfo.environment["ALAS_TRANSCRIPT_BENCH_CLOCK"] == "runloop" {
            return await RunLoopDriver(maxFrames: maxFrames, step: step).run()
        }
        return await withCheckedContinuation { continuation in
            let driver = DisplayLinkDriver(maxFrames: maxFrames, step: step) { intervals, times in
                continuation.resume(returning: FrameStats(intervalsMs: intervals, tickTimes: times))
            }
            driver.start(on: hosting)
            driver.failIfSilent(after: 5)
        }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }
}

@MainActor
private final class DisplayLinkDriver: NSObject {
    private let maxFrames: Int
    private let step: (Double) -> Bool
    private let completion: ([Double], [CFTimeInterval]) -> Void
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var intervals: [Double] = []
    private(set) var tickTimes: [CFTimeInterval] = []
    private var retainSelf: DisplayLinkDriver?

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
private final class RunLoopDriver {
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
    var hitches: Int { intervalsMs.filter { $0 > 1.5 * 1000 / 60 }.count }
    /// Vsyncs missed in total: a 50ms tick at 60Hz drops two frames.
    var dropped: Int { intervalsMs.reduce(0) { $0 + Swift.max(0, Int(($1 / (1000 / 60)).rounded()) - 1) } }

    func report(_ name: String) {
        let line = String(
            format: "TRANSCRIPT-BENCH %@ frames=%d p50=%.1fms p95=%.1fms p99=%.1fms max=%.1fms hitches=%d dropped=%d",
            name, intervalsMs.count, p50, p95, p99, max, hitches, dropped
        )
        print(line)
        if let path = ProcessInfo.processInfo.environment["ALAS_TRANSCRIPT_BENCH_OUT"],
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

// MARK: - Corpus

/// Synthetic transcripts shaped like real ones. Fitted on 2026-10-02…09 to
/// 349 Alas-rendered messages, 49 Claude Code sessions (17k rows) and 62
/// Codex sessions:
/// - Rows: tool calls ~60%, agent text ~22%, thoughts ~10%, user ~6%.
/// - Session length: p50 ~80 rows, p90 ~650, max ~4.9k.
/// - Tool kinds: execute 60%, think 20%, read 8%, edit 6%, other 6%.
/// - Tool output: p50 ~1.1KB, p90 ~8KB. Runs of tool calls: p50 2, p90 5.
/// - Agent text: p50 ~150 chars, p90 ~700, p99 ~3k; ~10% contain lists.
/// - User prompts: p50 ~400 chars, p90 ~700.
@MainActor
struct ACPTranscriptBenchmarkCorpus {
    struct ScriptedUpdate {
        let at: Double
        let update: ACPSessionUpdate
    }

    private(set) var messages: [ACPMessage] = []
    private var rng: SplitMix64
    private var toolSerial = 0

    init(seed: UInt64, messageCount: Int) {
        rng = SplitMix64(seed: seed)
        while messages.count < messageCount {
            appendTurn()
        }
    }

    /// One live turn (~15s) delivered as ACP updates: commentary streamed in
    /// chunks, tool calls that start and finish, and a final answer.
    mutating func liveTurnScript() -> [ScriptedUpdate] {
        var script: [ScriptedUpdate] = []
        var t = 0.05
        script.append(.init(at: t, update: .userMessageChunk(.init(messageId: "live-user", content: .text(prose(chars: 400))))))
        for step in 0..<6 {
            t += 0.2
            t = stream(prose(chars: 220), messageId: "live-commentary-\(step)", into: &script, from: t)
            for _ in 0..<toolRunLength() {
                toolSerial += 1
                let id = "live-tool-\(toolSerial)"
                let kind = toolKind()
                script.append(.init(at: t, update: .toolCall(.init(
                    toolCallId: id, title: toolTitle(kind: kind), kind: kind, status: "in_progress"
                ))))
                t += rng.uniform(0.15, 0.9)
                script.append(.init(at: t, update: .toolCallUpdate(.init(
                    toolCallId: id, status: "completed",
                    content: [.content(.text(toolOutput(kind: kind)))]
                ))))
                t += 0.05
            }
        }
        _ = stream(markdownAnswer(chars: 1400), messageId: "live-answer", into: &script, from: t + 0.2)
        return script
    }

    /// Agents emit ~3-6 tokens per chunk, roughly every 30ms.
    private mutating func stream(_ text: String, messageId: String, into script: inout [ScriptedUpdate], from start: Double) -> Double {
        var t = start
        var remaining = Substring(text)
        while !remaining.isEmpty {
            let chunk = remaining.prefix(Int(rng.uniform(10, 24)))
            remaining = remaining.dropFirst(chunk.count)
            script.append(.init(at: t, update: .agentMessageChunk(.init(messageId: messageId, content: .text(String(chunk))))))
            t += rng.uniform(0.02, 0.045)
        }
        return t
    }

    private mutating func appendTurn() {
        messages.append(.user(id: UUID(), messageId: nil, text: prose(chars: lognormal(p50: 400, p90: 700, cap: 7000)), attachments: []))
        for _ in 0..<Int(rng.uniform(3, 9)) {
            if rng.chance(0.25) {
                messages.append(.thought(id: UUID(), messageId: nil, StreamingText(prose(chars: lognormal(p50: 220, p90: 400, cap: 1200)))))
            }
            if rng.chance(0.7) {
                messages.append(.agent(
                    id: UUID(), messageId: nil,
                    StreamingText(agentText(chars: lognormal(p50: 150, p90: 700, cap: 3000)), phase: .commentary)
                ))
            }
            for _ in 0..<toolRunLength() {
                toolSerial += 1
                let kind = toolKind()
                let output = toolOutput(kind: kind)
                messages.append(.toolCall(.init(
                    toolCallId: "tool-\(toolSerial)", title: toolTitle(kind: kind), kind: kind,
                    status: rng.chance(0.04) ? "failed" : "completed", content: output,
                    preview: output.split(separator: "\n", maxSplits: 1).first.map(String.init)
                )))
            }
        }
        messages.append(.agent(
            id: UUID(), messageId: nil,
            StreamingText(markdownAnswer(chars: lognormal(p50: 600, p90: 1800, cap: 5000)), phase: .finalAnswer)
        ))
    }

    private mutating func toolRunLength() -> Int {
        min(25, max(1, lognormal(p50: 2, p90: 5, cap: 25)))
    }

    private mutating func toolKind() -> String {
        let roll = rng.uniform(0, 1)
        switch roll {
        case ..<0.60: return "execute"
        case ..<0.80: return "think"
        case ..<0.88: return "read"
        case ..<0.94: return "edit"
        default: return "other"
        }
    }

    private mutating func toolTitle(kind: String) -> String {
        switch kind {
        case "execute": ["git status --short", "xcodebuild -scheme Alas build", "rg -n \"layoutMountedRows\" Alas", "ls -la", "gh pr view --json state"].randomElement(using: &rng)!
        case "read": "Read Alas/Sources/ACP/UI/Scroller/ACPTranscriptScroller.swift"
        case "edit": "Edit Alas/Sources/ACP/UI/ACPToolCallCard.swift"
        case "think": "Agent"
        default: "Load skill: superpowers:brainstorming"
        }
    }

    private mutating func toolOutput(kind: String) -> String {
        if kind == "other", rng.chance(0.5) { return "" }
        let chars = lognormal(p50: 1100, p90: 8000, cap: 40000)
        var lines: [String] = []
        var count = 0
        var lineNumber = 1
        while count < chars {
            let line: String = switch kind {
            case "read": "\(lineNumber)\t    let value\(lineNumber) = transcript.rowLayout(at: index).minY + spacing"
            case "edit": (rng.chance(0.5) ? "+" : "-") + "        reconciler.layoutMountedRows(pinToTail: \(lineNumber % 2 == 0))"
            default: "drwxr-xr-x@ 17 mrm  staff   544 Oct  9 09:04 module-\(lineNumber)"
            }
            lines.append(line)
            count += line.count + 1
            lineNumber += 1
        }
        return lines.joined(separator: "\n")
    }

    private mutating func agentText(chars: Int) -> String {
        rng.chance(0.1) ? markdownAnswer(chars: chars) : prose(chars: chars)
    }

    private mutating func markdownAnswer(chars: Int) -> String {
        var parts: [String] = [prose(chars: min(chars, 240))]
        var count = parts[0].count
        while count < chars {
            let block: String
            switch rng.uniform(0, 1) {
            case ..<0.55: block = (0..<Int(rng.uniform(2, 6))).map { _ in "- " + prose(chars: 90) }.joined(separator: "\n")
            case ..<0.85: block = prose(chars: 260)
            case ..<0.93: block = "```swift\nlet height = view.measuredHeight(forWidth: contentWidth)\nif applyHeightToTiling(id: id, height: height) { pendingRelayout = true }\n```"
            default: block = "| Scenario | p95 |\n|---|---|\n| fling | 12ms |\n| stream | 9ms |"
            }
            parts.append(block)
            count += block.count
        }
        return parts.joined(separator: "\n\n")
    }

    private static let words = "the transcript row height measure layout scroll window mount band tiling view hosting update stream chunk tool call agent session reconciler pool `ACPTranscriptScroller` **frame** budget commit render cache".split(separator: " ")

    private mutating func prose(chars: Int) -> String {
        var out = ""
        while out.count < chars {
            if !out.isEmpty { out += " " }
            out += Self.words.randomElement(using: &rng)!
        }
        return out + "."
    }

    private mutating func lognormal(p50: Double, p90: Double, cap: Int) -> Int {
        let sigma = log(p90 / p50) / 1.2816
        let u1 = max(rng.uniform(0, 1), 1e-9), u2 = rng.uniform(0, 1)
        let z = sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        return min(cap, max(1, Int(p50 * exp(sigma * z))))
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
}
