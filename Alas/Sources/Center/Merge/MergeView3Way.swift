import AppKit
import SwiftUI

/// Top-level coordinator view for the 3-way merge editor. Replaces
/// the old `body3Columns` HStack. Composes:
/// - Outer line-number gutters (LOCAL's source numbers + REMOTE's
///   source numbers) on the far left and far right.
/// - Three text panes: LOCAL (`MergeSidePane`), RESULT
///   (`MergeResultPane`), REMOTE (`MergeSidePane`).
/// - Two action gutters (`MergeActionGutter`) between the panes.
/// - The existing `MergeConflictMinimap` on the far right edge.
///
/// All children read scroll state from a single
/// `MergeScrollCoordinator` instance so scrolling stays in lockstep.
struct MergeView3Way: View {
    @Bindable var model: MergeConflictTabModel
    let fileExtension: String
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let showBase: Bool
    let onJumpToConflict: (Int) -> Void

    @State private var coordinator = MergeScrollCoordinator()
    @Environment(\.theme) var theme

    private var layout: MergeRegionVisualLayout.Layout {
        MergeRegionVisualLayout.compute(regions: model.regions, showBase: showBase)
    }

    /// Whether the model's last MEANINGFUL region's RENDERED content
    /// ends with `\n`. Mirrors `renderMarkerlessBuffer`'s LOCAL → (BASE
    /// if `showBase`) → REMOTE order — the last visible side is
    /// whichever non-empty side comes last in that walk. Skips
    /// trailing zero-length `.text("")` regions (the parser emits one
    /// for files whose merged content ends with `\n`; reading from it
    /// directly would falsely report no-EOF-newline).
    private var lastRegionEndsWithNewline: Bool {
        // Find the index of the last meaningful region.
        var idx = model.regions.count - 1
        while idx >= 0 {
            switch model.regions[idx] {
            case .text(let t):
                if !t.isEmpty { break }
            case .conflict:
                break  // conflicts always meaningful
            }
            // .text("") fall-through: keep walking back.
            if case .text(let t) = model.regions[idx], t.isEmpty {
                idx -= 1
                continue
            }
            break
        }
        guard idx >= 0 else { return false }
        switch model.regions[idx] {
        case .text(let t):
            return t.hasSuffix("\n")
        case .conflict(let block):
            // Walk render order LOCAL → BASE (if showBase) → REMOTE;
            // the last non-empty side determines the EOF newline state.
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
        let layout = self.layout
        let hunkPairs = model.allConflictBlocks().map { (local: $0.local, remote: $0.remote) }
        HStack(spacing: 0) {
            lineNumberGutter(rows: layout.local, alignment: .trailing)
            MergeSidePane(
                side: .local,
                rows: layout.local,
                hunkRanges: layout.conflictRanges.map(\.localRows),
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                coordinator: coordinator
            )
            .frame(maxWidth: .infinity)
            MergeActionGutter(
                side: .localToResult,
                conflictRanges: layout.conflictRanges,
                coordinator: coordinator,
                onAccept: { ordinal in acceptLocal(at: ordinal) },
                onReject: { ordinal in acceptRemote(at: ordinal) }
            )
            .frame(width: 28)
            MergeResultPane(
                rows: layout.result,
                conflictRanges: layout.conflictRanges,
                hunkPairs: hunkPairs,
                wordDiffMode: model.wordDiffMode,
                fileExtension: fileExtension,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                coordinator: coordinator,
                endsWithNewline: lastRegionEndsWithNewline,
                onEditFullText: { newText in
                    model.applyEditedFullText(newText, showBase: showBase)
                }
            )
            .frame(maxWidth: .infinity)
            MergeActionGutter(
                side: .resultToRemote,
                conflictRanges: layout.conflictRanges,
                coordinator: coordinator,
                onAccept: { ordinal in acceptRemote(at: ordinal) },
                onReject: { ordinal in acceptLocal(at: ordinal) }
            )
            .frame(width: 28)
            MergeSidePane(
                side: .remote,
                rows: layout.remote,
                hunkRanges: layout.conflictRanges.map(\.remoteRows),
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                coordinator: coordinator
            )
            .frame(maxWidth: .infinity)
            lineNumberGutter(rows: layout.remote, alignment: .leading)
            MergeConflictMinimap(
                conflictCount: model.conflictCount,
                resolvedCount: max(model.initialConflictCount - model.conflictCount, 0),
                currentConflictIndex: model.currentConflictIndex,
                onJump: onJumpToConflict
            )
        }
        .onChange(of: model.currentConflictIndex, initial: true) { _, _ in
            scrollToCurrentConflict()
        }
    }

    private func scrollToCurrentConflict() {
        guard let ordinal = model.currentConflictIndex else { return }
        let layout = MergeRegionVisualLayout.compute(regions: model.regions, showBase: showBase)
        guard ordinal < layout.conflictRanges.count else { return }
        let row = layout.conflictRanges[ordinal].resultRows.lowerBound
        coordinator.setLogicalRow(row)
        coordinator.onSyncLocal?(row)
        coordinator.onSyncResult?(row)
        coordinator.onSyncRemote?(row)
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

    private func lineNumberGutter(rows: [MergeRegionVisualLayout.VisualRow], alignment: HorizontalAlignment) -> some View {
        // Wrapped in a top-aligned container that clips overflow and
        // offset by -coordinator.paneY() so the numbers track the
        // synchronized scroll position of the three text panes. The
        // gutter rows are still all materialised; the clip + offset
        // is the cheap way to align them without a NSScrollView for
        // a read-only column.
        VStack(alignment: alignment, spacing: 0) {
            VStack(alignment: alignment, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Text(row.sourceLineNumber.map(String.init) ?? "")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.color("fg-faint"))
                        .frame(height: coordinator.rowHeight, alignment: alignment == .trailing ? .trailing : .leading)
                        .padding(.horizontal, 4)
                }
            }
            .offset(y: -coordinator.paneY())
            Spacer(minLength: 0)
        }
        .frame(width: 28)
        .background(theme.color("bg-2"))
        .clipped()
    }
}
