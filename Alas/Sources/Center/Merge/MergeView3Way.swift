import AppKit
import SwiftUI

/// Top-level coordinator view for the 3-way merge editor. Replaces
/// the old `body3Columns` HStack. Composes:
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
        MergeThreeWayLayout {
            MergeSidePane(
                side: .local,
                rows: layout.local,
                hunkRanges: layout.conflictRanges.map(\.localRows),
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                coordinator: coordinator
            )
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
            MergeConflictMinimap(
                conflictCount: model.conflictCount,
                resolvedCount: max(model.initialConflictCount - model.conflictCount, 0),
                currentConflictIndex: model.currentConflictIndex,
                onJump: onJumpToConflict
            )
            .frame(width: 13)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
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
        let y = coordinator.paneY()
        coordinator.onSyncLocal?(y)
        coordinator.onSyncResult?(y)
        coordinator.onSyncRemote?(y)
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

private struct MergeThreeWayLayout: Layout {
    private let actionGutterWidth: CGFloat = 28
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
