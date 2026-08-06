import AppKit
import SwiftUI

@MainActor
final class DiffPanePresentationState: ObservableObject {
    @Published private(set) var expandedCollapsedRowIDs: Set<String> = []
    @Published private(set) var activeThreadID: String?

    func toggleCollapsedContext(in group: DiffDisplayGroup) {
        expandedCollapsedRowIDs = DiffCollapsedContextController.toggled(
            group,
            expandedIDs: expandedCollapsedRowIDs
        )
    }

    func setThreadActive(_ threadID: String, active: Bool) {
        activeThreadID = active ? threadID : (activeThreadID == threadID ? nil : activeThreadID)
    }
}

struct DiffPaneHunkActionPresence: Equatable {
    let canStage: Bool
    let canDiscard: Bool
    let canDropFromCommit: Bool

    init(_ actions: DiffPaneHunkActions) {
        canStage = actions.stage != nil
        canDiscard = actions.discard != nil
        canDropFromCommit = actions.dropFromCommit != nil
    }
}

struct DiffPaneHunkRowToken: Equatable {
    let groupID: String
    let rowsSignature: DiffDisplayRowsSignature
    let fusion: DiffPaneHunkFusionState
    let layoutMode: DiffLayoutMode
    let wrapLines: Bool
    let showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let threadSignatures: [DiffInlineCommentThread]
    let annotations: [DiffInlineAnnotation]
    let activeHighlight: DiffReviewCommentHighlight?
    let actionPresence: DiffPaneHunkActionPresence
}

struct DiffPaneRowPlanInput {
    let model: DiffDisplayModel
    let fileExtension: String
    let layoutMode: DiffLayoutMode
    let wrapLines: Bool
    let showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let theme: Theme
    var lspContext: DiffPaneLSPContext? = nil
    var activeCommentHighlight: DiffReviewCommentHighlight? = nil
    var allowsReviewLineSelection: Bool = true
    var onReviewLineSelected: (DiffReviewLineAnchor) -> Void = { _ in }
    var onContextExpansion: DiffContextExpansionHandler = { _, _, _ in }
    var threads: [DiffInlineCommentThread] = []
    var annotations: [DiffInlineAnnotation] = []
    var onReply: (DiffInlineCommentThread, String) -> Void = { _, _ in }
    var onResolve: (DiffInlineCommentThread) -> Void = { _ in }
    var onUnresolve: (DiffInlineCommentThread) -> Void = { _ in }
    var onEdit: (DiffInlineCommentThread, DiffInlineComment, String) -> Void = { _, _, _ in }
    var onDelete: (DiffInlineCommentThread, DiffInlineComment) -> Void = { _, _ in }
    var canReply: Bool = false
    var canResolve: Bool = false
    var onStageReply: (DiffInlineCommentThread, String) -> Void = { _, _ in }
    var canAddToReview: Bool = false
    var hunkFusionStates: [DiffPaneHunkFusionState]? = nil
    let hunkActions: (ParsedDiff.Hunk) -> DiffPaneHunkActions
}

enum DiffPaneRowPlanBuilder {
    @MainActor
    static func build(input: DiffPaneRowPlanInput, state: DiffPanePresentationState) -> AppKitDiffRowPlan {
        let fusions = resolvedFusions(for: input)
        let rows = input.model.groups.enumerated().map { index, group in
            let fusion = fusions[index]
            let visibleRows = DiffPaneRowProjection.visibleRowsSnapshot(
                in: group,
                expandedCollapsedRowIDs: state.expandedCollapsedRowIDs
            )
            let hunkThreads = threads(for: visibleRows.rows, from: input.threads)
            let hunkAnnotations = annotations(for: visibleRows.rows, from: input.annotations)
            let actions = input.hunkActions(group.sourceHunk)
            let token = DiffPaneHunkRowToken(
                groupID: group.id,
                rowsSignature: visibleRows.signature,
                fusion: fusion,
                layoutMode: input.layoutMode,
                wrapLines: input.wrapLines,
                showWhitespace: input.showWhitespace,
                codeFontFamily: input.codeFontFamily,
                codeFontSize: input.codeFontSize,
                threadSignatures: hunkThreads,
                annotations: hunkAnnotations,
                activeHighlight: input.activeCommentHighlight,
                actionPresence: .init(actions)
            )
            return AppKitDiffRowSpec(
                id: "diff-hunk-\(group.id)",
                ownerID: group.id,
                equalityToken: .init(token),
                estimatedHeight: estimatedHeight(for: group, input: input, fusion: fusion)
            ) {
                AnyView(DiffPaneHunkRow(group: group, fusion: fusion, input: input, state: state))
            }
        }
        return AppKitDiffRowPlan(rows: rows)
    }

    static func resolvedFusions(for input: DiffPaneRowPlanInput) -> [DiffPaneHunkFusionState] {
        if let states = input.hunkFusionStates, states.count == input.model.groups.count {
            return states
        }
        return DiffPaneHunkFusionResolver.states(for: input.model.groups)
    }

    private static func estimatedHeight(
        for group: DiffDisplayGroup,
        input: DiffPaneRowPlanInput,
        fusion: DiffPaneHunkFusionState
    ) -> CGFloat {
        DiffPaneStaticHeightEstimator.estimatedHeight(
            for: .init(filePath: input.model.filePath, groups: [group]),
            layoutMode: input.layoutMode,
            expandedCollapsedRowIDs: [],
            codeFont: CenterTypography.resolveCodeFont(family: input.codeFontFamily, size: input.codeFontSize),
            headerFont: CenterTypography.resolveCodeFont(family: input.codeFontFamily, size: input.codeFontSize - 1),
            wrapLines: input.wrapLines,
            showWhitespace: input.showWhitespace,
            fusionStates: [fusion]
        )
    }

    static func threads(for rows: [DiffDisplayRow], from threads: [DiffInlineCommentThread]) -> [DiffInlineCommentThread] {
        let oldLines = Set(rows.compactMap { $0.old?.anchor.oldLine })
        let newLines = Set(rows.compactMap { $0.new?.anchor.newLine })
        return threads.filter { thread in
            thread.isOldSide
                ? oldLines.contains(where: { thread.lineRange.contains($0) })
                : newLines.contains(where: { thread.lineRange.contains($0) })
        }
    }

    static func annotations(for rows: [DiffDisplayRow], from annotations: [DiffInlineAnnotation]) -> [DiffInlineAnnotation] {
        let newLines = Set(rows.compactMap { $0.new?.anchor.newLine })
        return annotations.filter { newLines.contains($0.newLine) }
    }
}

struct DiffPaneHunkRow: View {
    let group: DiffDisplayGroup
    let fusion: DiffPaneHunkFusionState
    let input: DiffPaneRowPlanInput
    @ObservedObject var state: DiffPanePresentationState

    var body: some View {
        let visibleRowsSnapshot = DiffPaneRowProjection.visibleRowsSnapshot(
            in: group,
            expandedCollapsedRowIDs: state.expandedCollapsedRowIDs
        )
        let visibleRows = visibleRowsSnapshot.rows
        let hunkThreads = DiffPaneRowPlanBuilder.threads(for: visibleRows, from: input.threads)
        let hunkAnnotations = DiffPaneRowPlanBuilder.annotations(for: visibleRows, from: input.annotations)
        let blocks = DiffInlineCommentLayout.blocks(
            visibleRows: visibleRowsSnapshot,
            threads: hunkThreads,
            annotations: hunkAnnotations
        )

        VStack(alignment: .leading, spacing: 0) {
            hunkHeader
            ForEach(blocks) { block in
                switch block {
                case .rows(let segment):
                    DiffPaneSegmentView(
                        rows: segment.rows,
                        rowsSignature: segment.rowsSignature,
                        layoutMode: input.layoutMode,
                        wrapLines: input.wrapLines,
                        showWhitespace: input.showWhitespace,
                        fileExtension: input.fileExtension,
                        codeFontFamily: input.codeFontFamily,
                        codeFontSize: input.codeFontSize,
                        theme: input.theme,
                        lspContext: input.lspContext,
                        activeCommentHighlight: activeHighlight(for: segment.rows),
                        allowsReviewLineSelection: input.allowsReviewLineSelection,
                        onReviewLineSelected: input.onReviewLineSelected,
                        onContextExpansion: input.onContextExpansion
                    )
                    .fixedSize(horizontal: false, vertical: true)
                case .thread(let thread):
                    DiffFeedbackLaneView(
                        lane: DiffFeedbackLaneResolver.lane(for: thread),
                        layoutMode: input.layoutMode,
                        rows: visibleRows
                    ) {
                        DiffInlineCommentCard(
                            thread: thread,
                            onReply: { input.onReply(thread, $0) },
                            onStageReply: { input.onStageReply(thread, $0) },
                            onResolve: { input.onResolve(thread) },
                            onUnresolve: { input.onUnresolve(thread) },
                            onEdit: { comment, body in input.onEdit(thread, comment, body) },
                            onDelete: { input.onDelete(thread, $0) },
                            canReply: input.canReply && thread.viewerCanReply,
                            canResolve: input.canResolve && (thread.viewerCanResolve || thread.viewerCanUnresolve),
                            canAddToReview: input.canAddToReview,
                            onActiveChange: { state.setThreadActive(thread.id, active: $0) }
                        )
                    }
                case .annotation(let annotation):
                    DiffFeedbackLaneView(
                        lane: DiffFeedbackLaneResolver.lane(for: annotation),
                        layoutMode: input.layoutMode,
                        rows: visibleRows
                    ) {
                        DiffInlineAnnotationCard(annotation: annotation)
                    }
                }
            }
        }
        .background(input.theme.color("bg-1"))
        .clipShape(DiffPaneHunkCardShape(fusion: fusion))
        .overlay(DiffPaneHunkCardShape(fusion: fusion).stroke(input.theme.color("line"), lineWidth: 0.75))
        .padding(.bottom, fusion.bottomPadding)
    }

    private var hunkHeader: some View {
        let actions = input.hunkActions(group.sourceHunk)
        return HStack(spacing: 8) {
            Text(group.header)
                .font(CenterTypography.codeFont(family: input.codeFontFamily, size: input.codeFontSize - 1))
                .foregroundColor(input.theme.color("fg-muted"))
                .lineLimit(1)
            Spacer(minLength: 12)
            if !DiffCollapsedContextController.collapsedRowIDs(in: group).isEmpty {
                let expanded = DiffCollapsedContextController.isExpanded(group, expandedIDs: state.expandedCollapsedRowIDs)
                hunkActionButton(systemName: expanded ? "minus.square" : "plus.square", tooltip: expanded ? "Collapse context" : "Expand context") {
                    state.toggleCollapsedContext(in: group)
                }
            }
            if let stage = actions.stage { hunkActionButton(systemName: "plus.square", tooltip: "Stage hunk", action: stage) }
            if let discard = actions.discard { hunkActionButton(systemName: "trash", tooltip: "Discard hunk", action: discard) }
            if let dropFromCommit = actions.dropFromCommit { hunkActionButton(systemName: "minus.circle", tooltip: "Drop from commit", action: dropFromCommit) }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(input.theme.color("bg-2"))
        .overlay(Rectangle().fill(input.theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }

    private func activeHighlight(for rows: [DiffDisplayRow]) -> DiffReviewCommentHighlight? {
        DiffPaneActiveHighlightResolver.activeHighlight(
            parentHighlight: input.activeCommentHighlight,
            threads: input.threads,
            activeThreadID: state.activeThreadID,
            rows: rows
        )
    }

    private func hunkActionButton(systemName: String, tooltip: String, action: @escaping () -> Void) -> some View {
        DiffPaneActionButton(systemName: systemName, tooltip: tooltip, action: action)
            .frame(width: 22, height: 20)
    }
}

struct DiffPaneActionButton: NSViewRepresentable {
    let systemName: String
    let tooltip: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: image(), target: context.coordinator, action: #selector(Coordinator.fire))
        button.bezelStyle = .accessoryBar
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.image = image()
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
    }

    private func image() -> NSImage {
        NSImage(systemSymbolName: systemName, accessibilityDescription: tooltip) ?? NSImage()
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}
