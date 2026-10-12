import AppKit
import SwiftUI

/// Top-level view for the 3-way merge editor. Composes:
/// - A header naming each column and its branch.
/// - Three text panes: LOCAL (`MergeSidePane`), RESULT
///   (`MergeResultPane`), REMOTE (`MergeSidePane`).
/// - Two action gutters (`MergeActionGutter`) with ribbons between the panes.
/// - The existing `MergeConflictMinimap` on the far right edge.
///
/// All panes report to a single `MergeScrollCoordinator`, which keeps
/// corresponding content aligned while any of them scrolls.
struct MergeView3Way: View {
    @Bindable var model: MergeConflictTabModel
    let fileExtension: String
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let showBase: Bool
    let onJumpToConflict: (Int) -> Void

    @State private var coordinator = MergeScrollCoordinator()
    @State private var highlighter = MergeSyntaxHighlighter()
    @State private var wordMarkCache = MergeWordMarkCache()
    @Environment(\.theme) var theme

    /// Whether the model's last MEANINGFUL region's RENDERED content
    /// ends with `\n`. Mirrors `renderMarkerlessBuffer`'s LOCAL → (BASE
    /// if `showBase`) → REMOTE order — the last visible side is
    /// whichever non-empty side comes last in that walk. Skips
    /// trailing zero-length `.text("")` regions (the parser emits one
    /// for files whose merged content ends with `\n`; reading from it
    /// directly would falsely report no-EOF-newline).
    private var lastRegionEndsWithNewline: Bool {
        guard let last = model.regions.last(where: { region in
            if case .text(let t) = region { return !t.isEmpty }
            return true
        }) else { return false }
        switch last {
        case .text(let t):
            return t.hasSuffix("\n")
        case .conflict(let block):
            var trailing: Bool? = nil
            if !block.local.isEmpty { trailing = block.local.hasSuffix("\n") }
            if showBase, let base = block.base, !base.isEmpty {
                trailing = base.hasSuffix("\n")
            }
            if !block.remote.isEmpty { trailing = block.remote.hasSuffix("\n") }
            return trailing ?? false
        }
    }

    var body: some View {
        let layout = MergeRegionVisualLayout.compute(regions: model.regions, showBase: showBase)
        let current = model.currentConflictIndex
        let bands = MergeView3WayDecorations.bands(for: layout.conflictRanges, current: current)
        let marks = wordMarkCache.marks(for: layout, mode: model.wordDiffMode)
        let syntaxInput = MergeSyntaxHighlighter.Input(
            local: layout.local.map(\.content),
            remote: layout.remote.map(\.content),
            base: showBase ? layout.base.map(\.content) : [],
            fileExtension: fileExtension
        )
        let _ = highlighter.revision
        let localLines = highlighter.lines(for: syntaxInput.local, pane: .local)
        let remoteLines = highlighter.lines(for: syntaxInput.remote, pane: .remote)
        let baseLines = showBase ? highlighter.lines(for: syntaxInput.base, pane: nil) : []
        let resultLines = MergeSyntaxHighlighter.resultLines(
            origins: layout.resultOrigins,
            local: localLines,
            remote: remoteLines,
            base: baseLines
        )
        let labels = branchLabels
        VStack(spacing: 0) {
            MergeThreeWayLayout {
                MergePaneHeader(
                    title: "Local",
                    branch: labels.local,
                    detail: "ours",
                    tint: Color(nsColor: MergePalette(theme: theme).local)
                )
                headerSpacer
                MergePaneHeader(
                    title: "Result",
                    branch: nil,
                    detail: model.conflictCount == 0 ? "all resolved" : "\(model.conflictCount) unresolved",
                    tint: nil
                )
                headerSpacer
                MergePaneHeader(
                    title: "Remote",
                    branch: labels.remote,
                    detail: "theirs",
                    tint: Color(nsColor: MergePalette(theme: theme).remote)
                )
                headerSpacer
            }
            .frame(height: 26)
            .overlay(Divider(), alignment: .bottom)
            MergeThreeWayLayout {
                MergeSidePane(
                    side: .local,
                    rows: layout.local,
                    bands: bands.local,
                    lineSpans: localLines,
                    wordMarks: marks.local,
                    codeFontFamily: codeFontFamily,
                    codeFontSize: codeFontSize,
                    coordinator: coordinator
                )
                MergeActionGutter(
                    side: .localToResult,
                    conflictRanges: layout.conflictRanges,
                    currentOrdinal: current,
                    codeFontFamily: codeFontFamily,
                    codeFontSize: codeFontSize,
                    coordinator: coordinator,
                    onAccept: { ordinal in acceptLocal(at: ordinal) },
                    onReject: { ordinal in acceptRemote(at: ordinal) }
                )
                MergeResultPane(
                    rows: layout.result,
                    bands: bands.result,
                    lineSpans: resultLines,
                    wordMarks: marks.result,
                    codeFontFamily: codeFontFamily,
                    codeFontSize: codeFontSize,
                    coordinator: coordinator,
                    endsWithNewline: lastRegionEndsWithNewline,
                    onEditFullText: { newText in
                        model.applyEditedFullText(newText, showBase: showBase)
                    }
                )
                MergeActionGutter(
                    side: .resultToRemote,
                    conflictRanges: layout.conflictRanges,
                    currentOrdinal: current,
                    codeFontFamily: codeFontFamily,
                    codeFontSize: codeFontSize,
                    coordinator: coordinator,
                    onAccept: { ordinal in acceptRemote(at: ordinal) },
                    onReject: { ordinal in acceptLocal(at: ordinal) }
                )
                MergeSidePane(
                    side: .remote,
                    rows: layout.remote,
                    bands: bands.remote,
                    lineSpans: remoteLines,
                    wordMarks: marks.remote,
                    codeFontFamily: codeFontFamily,
                    codeFontSize: codeFontSize,
                    coordinator: coordinator
                )
                MergeConflictMinimap(
                    conflictCount: model.conflictCount,
                    resolvedCount: max(model.initialConflictCount - model.conflictCount, 0),
                    currentConflictIndex: model.currentConflictIndex,
                    onJump: onJumpToConflict
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onChange(of: layout, initial: true) { _, newLayout in
            coordinator.layout = newLayout
        }
        .onChange(of: model.currentConflictIndex, initial: true) { _, _ in
            // Defer one turn so a freshly loaded document is laid out
            // before the panes are asked to scroll into it.
            Task { @MainActor in
                await Task.yield()
                scrollToCurrentConflict()
            }
        }
        .task(id: syntaxInput) {
            if highlighter.hasResults {
                // Debounce re-parses while the user types in RESULT.
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
            }
            await highlighter.update(syntaxInput)
        }
    }

    private var headerSpacer: some View {
        Color(nsColor: MergePalette(theme: theme).gutterBackground)
    }

    private var branchLabels: (local: String?, remote: String?) {
        guard let block = model.allConflictBlocks().first else { return (nil, nil) }
        return (block.localLabel.isEmpty ? nil : block.localLabel, block.remoteLabel.isEmpty ? nil : block.remoteLabel)
    }

    private func scrollToCurrentConflict() {
        guard let ordinal = model.currentConflictIndex,
              let layout = coordinator.layout,
              ordinal < layout.conflictRanges.count
        else { return }
        let row = layout.conflictRanges[ordinal].resultRows.lowerBound
        let top = MergePaneMetrics.contentInset.height
            + CGFloat(row) * MergePaneMetrics(fontFamily: codeFontFamily, fontSize: codeFontSize).rowHeight
        // Park the hunk a third of the way down so the lines leading into
        // it stay visible.
        coordinator.scroll(.result, toY: top - coordinator.viewportHeight / 3)
    }

    private func acceptLocal(at ordinal: Int) {
        let blocks = model.allConflictBlocks()
        guard ordinal < blocks.count else { return }
        model.acceptLocal(for: blocks[ordinal])
    }

    private func acceptRemote(at ordinal: Int) {
        let blocks = model.allConflictBlocks()
        guard ordinal < blocks.count else { return }
        model.acceptRemote(for: blocks[ordinal])
    }
}

enum MergeView3WayDecorations {
    struct PaneBands: Equatable {
        var local: [MergeBand] = []
        var result: [MergeBand] = []
        var remote: [MergeBand] = []
    }

    static func bands(
        for ranges: [MergeRegionVisualLayout.VisualConflictRange],
        current: Int?
    ) -> PaneBands {
        var bands = PaneBands()
        for range in ranges {
            let isCurrent = range.conflictOrdinal == current
            bands.local.append(MergeBand(rows: range.localRows, kind: .local, isCurrent: isCurrent))
            bands.remote.append(MergeBand(rows: range.remoteRows, kind: .remote, isCurrent: isCurrent))
            bands.result.append(MergeBand(rows: range.resultLocalRows, kind: .local, isCurrent: isCurrent))
            if !range.baseRows.isEmpty {
                bands.result.append(MergeBand(rows: range.baseRows, kind: .base, isCurrent: isCurrent))
            }
            bands.result.append(MergeBand(rows: range.resultRemoteRows, kind: .remote, isCurrent: isCurrent))
        }
        return bands
    }
}

/// Memoizes intra-line change marks: they run an LCS per hunk line pair,
/// which is too slow to repeat on every scroll-driven body evaluation.
@MainActor
final class MergeWordMarkCache {
    struct Marks {
        var local: [Int: MergePaneText.WordMark] = [:]
        var result: [Int: MergePaneText.WordMark] = [:]
        var remote: [Int: MergePaneText.WordMark] = [:]
    }

    private var key: (layout: MergeRegionVisualLayout.Layout, mode: MergeWordDiff.Mode)?
    private var cached = Marks()

    func marks(for layout: MergeRegionVisualLayout.Layout, mode: MergeWordDiff.Mode) -> Marks {
        if let key, key.mode == mode, key.layout == layout { return cached }
        var marks = Marks()
        for range in layout.conflictRanges {
            let hunk = MergeWordDiff.hunk(
                local: range.localRows.map { layout.local[$0].content },
                remote: range.remoteRows.map { layout.remote[$0].content },
                mode: mode
            )
            for (index, ranges) in hunk.local.enumerated() where !ranges.isEmpty {
                let mark = MergePaneText.WordMark(ranges: ranges, kind: .local)
                marks.local[range.localRows.lowerBound + index] = mark
                marks.result[range.resultLocalRows.lowerBound + index] = mark
            }
            for (index, ranges) in hunk.remote.enumerated() where !ranges.isEmpty {
                let mark = MergePaneText.WordMark(ranges: ranges, kind: .remote)
                marks.remote[range.remoteRows.lowerBound + index] = mark
                marks.result[range.resultRemoteRows.lowerBound + index] = mark
            }
        }
        key = (layout, mode)
        cached = marks
        return marks
    }
}

private struct MergePaneHeader: View {
    let title: String
    let branch: String?
    let detail: String
    let tint: Color?
    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 6) {
            if let tint {
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint)
                    .frame(width: 8, height: 8)
            }
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(theme.color("fg-muted"))
            if let branch {
                Text(branch)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(theme.color("fg-faint"))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-2"))
    }
}

private struct MergeThreeWayLayout: Layout {
    private let actionGutterWidth = MergeActionGutter.width
    private let minimapWidth: CGFloat = 13

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        CGSize(
            width: proposal.width ?? 900,
            height: proposal.height ?? 600
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 6 else { return }
        let fixedWidth = actionGutterWidth * 2 + minimapWidth
        let paneWidth = max((bounds.width - fixedWidth) / 3, 0)
        let widths = [
            paneWidth,
            actionGutterWidth,
            paneWidth,
            actionGutterWidth,
            paneWidth,
            minimapWidth,
        ]

        var x = bounds.minX
        for (index, width) in widths.enumerated() {
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width
        }
    }
}
