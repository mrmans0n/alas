import AppKit
import Combine
import QuartzCore
import SwiftUI
import Testing
@testable import Alas

/// Frame-rate benchmark for the ACP transcript pane. Opt-in: it opens a real
/// on-screen window and runs for tens of seconds, so it only runs with
/// `TEST_RUNNER_ALAS_TRANSCRIPT_BENCH=1` in the `xcodebuild` environment.
/// Pacing and the 60fps-at-p95 budget come from `FrameRateBenchmark`.
///
/// Transcripts come from `ACPTranscriptBenchmarkCorpus`, whose composition was
/// fitted to a week of real sessions on the author's machine (Alas session
/// stores plus the Claude Code and Codex logs those sessions drive).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ALAS_TRANSCRIPT_BENCH"] == "1"))
struct ACPTranscriptFrameRateBenchmark {
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
        stats.report("fling collapse=\(collapsesFinishedToolCalls)", label: "TRANSCRIPT-BENCH", envPrefix: "ALAS_TRANSCRIPT_BENCH")
        #expect(stats.p95 <= FrameRateBenchmark.budgetMs, "p95 frame \(stats.p95)ms")
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
        stats.report("stream collapse=\(collapsesFinishedToolCalls) transcriptPublishes=\(publishTimes.count) updates=\(updateCount) hitchesWithPublish=\(stats.hitches(containing: publishTimes)) hitchesWithChunk=\(stats.hitches(containing: chunkTimes))", label: "TRANSCRIPT-BENCH", envPrefix: "ALAS_TRANSCRIPT_BENCH")
        #expect(stats.p95 <= FrameRateBenchmark.budgetMs, "p95 frame \(stats.p95)ms")
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
        window.contentView = hosting
        FrameRateBenchmark.show(window)
        scroller = try #require(FrameRateBenchmark.find(ACPTranscriptScrollerView.self, in: hosting))
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    /// Lets hydration, first layout, and any deferred work finish so the
    /// measured frames start from a steady state: the document has content
    /// and its geometry has stopped changing.
    func settle() async throws {
        var last: (height: CGFloat, offset: CGFloat)?
        var stablePolls = 0
        try await eventually("transcript layout to settle") {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            let now = (height: scroller.contentHeight, offset: scroller.scrollY)
            let unchanged = last.map { $0 == now } ?? false
            stablePolls = unchanged && now.height > 0 ? stablePolls + 1 : 0
            last = now
            return stablePolls >= 10
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

    func drive(maxFrames: Int, _ step: @escaping (Double) -> Bool) async -> FrameStats {
        await FrameRateBenchmark.drive(on: hosting, envPrefix: "ALAS_TRANSCRIPT_BENCH", maxFrames: maxFrames, step)
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
        messages.append(.user(id: UUID(), messageId: nil, text: prose(chars: rng.lognormal(p50: 400, p90: 700, cap: 7000)), attachments: []))
        for _ in 0..<Int(rng.uniform(3, 9)) {
            if rng.chance(0.25) {
                messages.append(.thought(id: UUID(), messageId: nil, StreamingText(prose(chars: rng.lognormal(p50: 220, p90: 400, cap: 1200)))))
            }
            if rng.chance(0.7) {
                messages.append(.agent(
                    id: UUID(), messageId: nil,
                    StreamingText(agentText(chars: rng.lognormal(p50: 150, p90: 700, cap: 3000)), phase: .commentary)
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
            StreamingText(markdownAnswer(chars: rng.lognormal(p50: 600, p90: 1800, cap: 5000)), phase: .finalAnswer)
        ))
    }

    private mutating func toolRunLength() -> Int {
        min(25, max(1, rng.lognormal(p50: 2, p90: 5, cap: 25)))
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
        let chars = rng.lognormal(p50: 1100, p90: 8000, cap: 40000)
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
}
