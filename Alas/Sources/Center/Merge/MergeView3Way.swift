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
        VStack(alignment: alignment, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Text(row.sourceLineNumber.map(String.init) ?? "")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.color("fg-faint"))
                    .frame(height: coordinator.rowHeight, alignment: alignment == .trailing ? .trailing : .leading)
                    .padding(.horizontal, 4)
            }
        }
        .frame(width: 28)
        .background(theme.color("bg-2"))
    }
}
