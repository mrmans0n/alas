import AppKit
import SwiftUI
import Testing
@testable import Alas

/// Frame-rate benchmark for the multi-file diff review surface shared by the
/// commit, staged, review-changes, PR review, review-request and review
/// session tabs. Opt-in: it opens a real on-screen window and runs for tens
/// of seconds, so it only runs with `TEST_RUNNER_ALAS_DIFF_BENCH=1` in the
/// `xcodebuild` environment. Pacing and the 60fps-at-p95 budget come from
/// `FrameRateBenchmark`.
///
/// Reviews come from `DiffReviewBenchmarkCorpus`, whose shape was fitted to
/// the last 800 squash-merged commits of this repository.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ALAS_DIFF_BENCH"] == "1"))
struct DiffReviewFrameRateBenchmark {
    struct Scenario: CustomTestStringConvertible, Sendable {
        let fileCount: Int
        let lineCount: Int
        let layoutMode: DiffLayoutMode
        let wrapLines: Bool
        let seed: UInt64

        var testDescription: String {
            "files=\(fileCount) lines~\(lineCount) layout=\(layoutMode.rawValue) wrap=\(wrapLines)"
        }
    }

    /// A p90 commit (23 files, ~2.2k diff lines) in every display mode, and a
    /// p99 one (56 files, ~9k lines) in both layouts. Each scenario has its own
    /// content so highlighting starts cold, as it does for a newly opened
    /// review.
    nonisolated static let scenarios: [Scenario] = [
        .init(fileCount: 23, lineCount: 2200, layoutMode: .split, wrapLines: false, seed: 1),
        .init(fileCount: 23, lineCount: 2200, layoutMode: .stacked, wrapLines: false, seed: 2),
        .init(fileCount: 23, lineCount: 2200, layoutMode: .split, wrapLines: true, seed: 3),
        .init(fileCount: 23, lineCount: 2200, layoutMode: .stacked, wrapLines: true, seed: 4),
        .init(fileCount: 56, lineCount: 9000, layoutMode: .split, wrapLines: false, seed: 5),
        .init(fileCount: 56, lineCount: 9000, layoutMode: .stacked, wrapLines: false, seed: 6),
    ]

    /// A brisk trackpad fling (~2400pt/s) from the first file to the last,
    /// which mounts every row for the first time, then back to the top over
    /// rows the scroller has already measured.
    @Test(arguments: scenarios)
    func flingThroughReview(_ scenario: Scenario) async throws {
        // `ALAS_DIFF_BENCH_ONLY=layout=split` runs only matching scenarios.
        if let only = ProcessInfo.processInfo.environment["ALAS_DIFF_BENCH_ONLY"],
           !scenario.testDescription.contains(only) { return }
        let corpus = DiffReviewBenchmarkCorpus(seed: scenario.seed, fileCount: scenario.fileCount, lineCount: scenario.lineCount)
        let bench = try DiffReviewBenchWindow(
            files: corpus.files, layoutMode: scenario.layoutMode, wrapLines: scenario.wrapLines
        )
        defer { bench.close() }
        try await bench.settle()

        let down = await bench.fling(direction: 1)
        let up = await bench.fling(direction: -1)
        bench.endLiveScroll()

        let all = FrameStats(
            intervalsMs: down.intervalsMs + up.intervalsMs, tickTimes: down.tickTimes + up.tickTimes,
            mainThreadCPUMs: down.mainThreadCPUMs + up.mainThreadCPUMs
        )
        let name = "\(scenario.testDescription) actualLines=\(corpus.lineCount)"
        down.report("\(name) pass=down", label: "DIFF-BENCH", envPrefix: "ALAS_DIFF_BENCH")
        up.report("\(name) pass=up", label: "DIFF-BENCH", envPrefix: "ALAS_DIFF_BENCH")
        all.report("\(name) pass=both selectionWrites=\(bench.selectionWrites)", label: "DIFF-BENCH", envPrefix: "ALAS_DIFF_BENCH")
        #expect(bench.reachedBottom, "the fling never reached the last file")
        #expect(all.p95 <= FrameRateBenchmark.budgetMs, "p95 frame \(all.p95)ms")
    }
}

// MARK: - Harness

@MainActor
private final class DiffReviewBenchWindow {
    let window: NSWindow
    let scroller: AppKitDiffScrollView
    /// Writes to the surface's selected-file binding during the flings. Each
    /// one re-renders the whole surface, so the scroll spy holds them until
    /// scrolling settles.
    private(set) var selectionWrites = 0
    private(set) var reachedBottom = false
    private let hosting: NSView
    private var isLiveScrolling = false

    init(files: [DiffReviewFileSectionModel], layoutMode: DiffLayoutMode, wrapLines: Bool) throws {
        let size = NSSize(width: 1400, height: 1000)
        let theme = try ThemeStore().current
        let session = DiffReviewLoadedSession(
            files: files,
            summary: DiffReviewSessionModel(files: files.map(\.summary), groupsEnabled: false)
        )
        var onSelectionChange: () -> Void = {}
        let root = DiffReviewBenchSurfaceHost(
            session: session,
            selectedFileID: files.first?.id,
            layoutMode: layoutMode,
            wrapLines: wrapLines,
            onSelectionChange: { onSelectionChange() }
        )
        .environment(\.theme, theme)
        .frame(width: size.width, height: size.height)
        hosting = NSHostingView(rootView: root)
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = hosting
        FrameRateBenchmark.show(window)
        scroller = try #require(FrameRateBenchmark.find(AppKitDiffScrollView.self, in: hosting))
        onSelectionChange = { [weak self] in self?.selectionWrites += 1 }
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    /// Lets the first layout, highlighting prewarm, and any deferred work
    /// finish so the measured frames start from a steady state.
    func settle() async throws {
        var last: (height: CGFloat, offset: CGFloat)?
        var stablePolls = 0
        try await eventually("diff review layout to settle") {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            let now = (height: scroller.contentHeight, offset: scroller.scrollY)
            let unchanged = last.map { $0 == now } ?? false
            stablePolls = unchanged && now.height > 0 ? stablePolls + 1 : 0
            last = now
            return stablePolls >= 10
        }
        selectionWrites = 0
    }

    /// Scrolls at fling speed until the document edge in `direction`. Row
    /// measurement grows the document as it goes, so the bottom edge is
    /// re-read every frame.
    func fling(direction: CGFloat) async -> FrameStats {
        await FrameRateBenchmark.drive(on: hosting, envPrefix: "ALAS_DIFF_BENCH", maxFrames: 20000) { [self] dt in
            let maxY = max(0, scroller.contentHeight - scroller.viewportHeight)
            let target = min(max(0, scroller.scrollY + 2400 * CGFloat(dt) * direction), maxY)
            liveScroll(to: target)
            if direction > 0, target >= maxY { reachedBottom = true }
            return direction > 0 ? target < maxY : target > 0
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
}

/// Owns the surface's bindings like a review tab does, so selected-file
/// writes re-render the surface.
private struct DiffReviewBenchSurfaceHost: View {
    let session: DiffReviewLoadedSession
    @State var selectedFileID: DiffReviewFileID?
    @State var layoutMode: DiffLayoutMode
    @State var wrapLines: Bool
    let onSelectionChange: () -> Void
    @State private var railCollapsed = false
    @State private var reviewSummaryCollapsed = false
    @State private var showWhitespace = false

    var body: some View {
        DiffReviewSurface(
            session: session,
            selectedFileID: $selectedFileID,
            railCollapsed: $railCollapsed,
            reviewSummaryCollapsed: $reviewSummaryCollapsed,
            layoutMode: $layoutMode,
            wrapLines: $wrapLines,
            showWhitespace: $showWhitespace,
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadges: false,
            showsRailDisplayControls: true
        )
        .onChange(of: selectedFileID) { onSelectionChange() }
    }
}

// MARK: - Corpus

/// Synthetic reviews shaped like real ones. Fitted on 2026-10-11 to the last
/// 800 first-parent commits of this repository (squash-merged PRs, ~7.2k file
/// diffs, ~22k hunks):
/// - Files per commit: p50 4, p90 23, p99 56.
/// - Hunks per file: p50 1, p90 7. Lines per hunk (3 lines of context): p50
///   10, p90 54; changed lines per hunk p50 4, p90 46.
/// - Hunks: ~51% pure additions, ~5% pure deletions. ~14% of files are new.
/// - Line length: p50 44, p90 92, p99 ~190 characters.
/// - Files: ~81% Swift, ~6% Markdown, then YAML, Rust, JS, JSON, shell.
struct DiffReviewBenchmarkCorpus {
    private(set) var files: [DiffReviewFileSectionModel] = []
    private(set) var lineCount = 0
    private var rng: SplitMix64

    /// A review of `fileCount` files whose diff totals within 20% of
    /// `lineCount` lines: the first such draw from `seed` onwards, so the
    /// scenario is the size its label claims and stays deterministic.
    init(seed: UInt64, fileCount: Int, lineCount target: Int) {
        var draw = seed
        repeat {
            self.init(seed: draw, fileCount: fileCount)
            draw += 1000
        } while abs(lineCount - target) > target / 5
    }

    private init(seed: UInt64, fileCount: Int) {
        rng = SplitMix64(seed: seed)
        for index in 0..<fileCount {
            files.append(makeFile(index: index, seed: seed))
        }
    }

    private mutating func makeFile(index: Int, seed: UInt64) -> DiffReviewFileSectionModel {
        let ext = fileExtension()
        let path = "Sources/Bench\(seed)/Module\(index % 7)/File\(index).\(ext)"
        let isNew = rng.chance(0.14)
        var hunks: [String] = []
        var additions = 0, deletions = 0
        if isNew {
            let count = rng.lognormal(p50: 60, p90: 300, cap: 2000)
            let body = (0..<count).map { _ in "+" + line(ext: ext) }
            additions = count
            lineCount += count
            hunks.append("@@ -0,0 +1,\(count) @@\n" + body.joined(separator: "\n"))
        } else {
            var oldLine = Int(rng.uniform(1, 80))
            var newLine = oldLine
            for _ in 0..<rng.lognormal(p50: 1, p90: 7, cap: 40) {
                var body: [String] = []
                var oldCount = 0, newCount = 0
                func context(_ n: Int) {
                    for _ in 0..<n { body.append(" " + line(ext: ext)) }
                    oldCount += n
                    newCount += n
                }
                context(3)
                let runs = rng.chance(0.3) ? Int(rng.uniform(2, 4)) : 1
                for run in 0..<runs {
                    if run > 0 { context(Int(rng.uniform(1, 5))) }
                    let changed = max(1, rng.lognormal(p50: 4, p90: 46, cap: 800) / runs)
                    let roll = rng.uniform(0, 1)
                    let added = roll < 0.51 ? changed : roll < 0.56 ? 0 : Int(rng.uniform(1, Double(changed)))
                    let deleted = changed - added
                    for _ in 0..<deleted { body.append("-" + line(ext: ext)) }
                    for _ in 0..<added { body.append("+" + line(ext: ext)) }
                    oldCount += deleted
                    newCount += added
                    additions += added
                    deletions += deleted
                }
                context(3)
                lineCount += body.count
                hunks.append("@@ -\(oldLine),\(oldCount) +\(newLine),\(newCount) @@\n" + body.joined(separator: "\n"))
                let gap = Int(rng.uniform(10, 200))
                oldLine += oldCount + gap
                newLine += newCount + gap
            }
        }
        let header = isNew
            ? "diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n"
            : "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n"
        let diff = DiffParser.parse(header + hunks.joined(separator: "\n") + "\n")
        let summary = DiffReviewFileSummary(
            path: path, namespace: "commit", groupID: nil, groupTitle: nil,
            status: isNew ? .added : .modified, additions: additions, deletions: deletions, isRenderable: true
        )
        return DiffReviewFileSectionModel(
            summary: summary, parsedDiff: diff,
            displayModel: DiffDisplayModelBuilder.build(diff: diff, filePath: path),
            placeholderMessage: nil, openFile: nil, contextProvider: nil
        )
    }

    private mutating func fileExtension() -> String {
        switch rng.uniform(0, 1) {
        case ..<0.81: "swift"
        case ..<0.87: "md"
        case ..<0.90: "yml"
        case ..<0.93: "rs"
        case ..<0.95: "js"
        case ..<0.97: "json"
        default: "sh"
        }
    }

    private static let swiftFragments = [
        "let", "var", "guard", "return", "if", "else", "self.", "await", "try", "func", "private", "static",
        "frame", "layoutMode", "contentWidth", "rows", "height", "view", "theme", "id", "plan", "spec",
        "=", "==", "!=", "+", "&&", "?", "{", "}", "(", ")", ":", ",", ".init(", "[", "]", "nil", "true", "0",
        "\"diff-row\"", "\"bg-1\"", "CGFloat", "String", "NSRect", "Int", "max(", "min(", "// keeps the band mounted",
    ]

    private static let proseWords = "the diff review row height scroll file hunk layout split stacked mount band tiling view hosting commit render cache measure".split(separator: " ")

    private mutating func line(ext: String) -> String {
        let length = rng.lognormal(p50: 44, p90: 92, cap: 400)
        switch ext {
        case "md":
            return words(Self.proseWords, length: length)
        case "yml":
            return "  " + words(Self.proseWords, length: max(6, length / 3)).replacingOccurrences(of: " ", with: "_") + ": value"
        case "json":
            return "  \"" + words(Self.proseWords, length: max(6, length / 3)).replacingOccurrences(of: " ", with: "_") + "\": 12,"
        default:
            let indent = String(repeating: " ", count: 4 * Int(rng.uniform(0, 4)))
            return indent + words(Self.swiftFragments, length: max(1, length - indent.count))
        }
    }

    private mutating func words<S: StringProtocol>(_ vocabulary: [S], length: Int) -> String {
        var out = ""
        while out.count < length {
            if !out.isEmpty { out += " " }
            out += vocabulary.randomElement(using: &rng)!
        }
        return out
    }
}
