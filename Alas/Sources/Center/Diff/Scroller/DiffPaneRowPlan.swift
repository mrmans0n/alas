import AppKit
import SwiftUI

@MainActor
final class DiffPanePresentationState: ObservableObject {
    let actionRelay = DiffPaneActionRelay()
    @Published private(set) var expandedCollapsedRowIDs: Set<String> = []
    @Published private(set) var activeThreadID: String?
    private var prewarmedHighlightSignatures: Set<Int> = []

    /// Records that a highlight prewarm for `signature` was scheduled.
    /// Returns true only the first time a signature is seen so plan rebuilds
    /// don't re-enqueue identical background work.
    func registerHighlightPrewarm(signature: Int) -> Bool {
        if prewarmedHighlightSignatures.count > 512 {
            prewarmedHighlightSignatures.removeAll(keepingCapacity: true)
        }
        return prewarmedHighlightSignatures.insert(signature).inserted
    }

    func toggleCollapsedContext(in group: DiffDisplayGroup) {
        expandedCollapsedRowIDs = DiffCollapsedContextController.toggled(
            group,
            expandedIDs: expandedCollapsedRowIDs
        )
    }

    func setExpandedCollapsedRowIDs(_ rowIDs: Set<String>) {
        expandedCollapsedRowIDs = rowIDs
    }

    func setThreadActive(_ threadID: String, active: Bool) {
        activeThreadID = active ? threadID : (activeThreadID == threadID ? nil : activeThreadID)
    }
}

@MainActor
final class DiffPaneActionRelay {
    private var onReviewLineSelected: (DiffReviewLineAnchor) -> Void = { _ in }
    private var onContextExpansion: DiffContextExpansionHandler = { _, _, _ in }
    private var onReply: (DiffInlineCommentThread, String) -> Void = { _, _ in }
    private var onResolve: (DiffInlineCommentThread) -> Void = { _ in }
    private var onUnresolve: (DiffInlineCommentThread) -> Void = { _ in }
    private var onEdit: (DiffInlineCommentThread, DiffInlineComment, String) -> Void = { _, _, _ in }
    private var onDelete: (DiffInlineCommentThread, DiffInlineComment) -> Void = { _, _ in }
    private var onStageReply: (DiffInlineCommentThread, String) -> Void = { _, _ in }
    private var hunkActions: (ParsedDiff.Hunk) -> DiffPaneHunkActions = { _ in .init() }

    func update(from input: DiffPaneRowPlanInput) {
        onReviewLineSelected = input.onReviewLineSelected
        onContextExpansion = input.onContextExpansion
        onReply = input.onReply
        onResolve = input.onResolve
        onUnresolve = input.onUnresolve
        onEdit = input.onEdit
        onDelete = input.onDelete
        onStageReply = input.onStageReply
        hunkActions = input.hunkActions
    }

    func reviewLineSelected(_ anchor: DiffReviewLineAnchor) { onReviewLineSelected(anchor) }
    func expandContext(_ key: DiffContextExpansionKey, _ mode: DiffContextExpansionMode, _ edge: DiffContextExpansionEdge?) {
        onContextExpansion(key, mode, edge)
    }
    func reply(to thread: DiffInlineCommentThread, body: String) { onReply(thread, body) }
    func resolve(_ thread: DiffInlineCommentThread) { onResolve(thread) }
    func unresolve(_ thread: DiffInlineCommentThread) { onUnresolve(thread) }
    func edit(_ thread: DiffInlineCommentThread, _ comment: DiffInlineComment, body: String) { onEdit(thread, comment, body) }
    func delete(_ thread: DiffInlineCommentThread, _ comment: DiffInlineComment) { onDelete(thread, comment) }
    func stageReply(to thread: DiffInlineCommentThread, body: String) { onStageReply(thread, body) }
    func hunkActions(for hunk: ParsedDiff.Hunk) -> DiffPaneHunkActions { hunkActions(hunk) }
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

struct DiffPaneLSPContextToken: Equatable {
    let worktreeId: String
    let worktreeRoot: URL
    let relativePath: String
    let language: String
    let lspManagerIdentity: ObjectIdentifier

    init(_ context: DiffPaneLSPContext) {
        worktreeId = context.worktreeId
        worktreeRoot = context.worktreeRoot
        relativePath = context.relativePath
        language = context.language
        lspManagerIdentity = ObjectIdentifier(context.lsp)
    }
}

struct DiffPaneHunkRowToken: Equatable {
    let groupID: String
    let rowsSignature: DiffDisplayRowsSignature
    let fusion: DiffPaneHunkFusionState
    let layoutMode: DiffLayoutMode
    let wrapLines: Bool
    let showWhitespace: Bool
    let fileExtension: String
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let theme: Theme
    let lspContext: DiffPaneLSPContextToken?
    let threadSignatures: [DiffInlineCommentThread]
    let annotations: [DiffInlineAnnotation]
    let activeHighlight: DiffReviewCommentHighlight?
    let allowsReviewLineSelection: Bool
    let canReply: Bool
    let canResolve: Bool
    let canAddToReview: Bool
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
        state.actionRelay.update(from: input)
        prewarmHighlightsIfNeeded(input: input, state: state)
        let fusions = resolvedFusions(for: input)
        let rows = input.model.groups.enumerated().map { index, group in
            let fusion = fusions[index]
            let visibleRows = DiffPaneRowProjection.visibleRowsSnapshot(
                in: group,
                expandedCollapsedRowIDs: state.expandedCollapsedRowIDs
            )
            let hunkThreads = threads(for: visibleRows.rows, from: input.threads)
            let hunkAnnotations = annotations(for: visibleRows.rows, from: input.annotations)
            let actions = state.actionRelay.hunkActions(for: group.sourceHunk)
            let token = DiffPaneHunkRowToken(
                groupID: group.id,
                rowsSignature: visibleRows.signature,
                fusion: fusion,
                layoutMode: input.layoutMode,
                wrapLines: input.wrapLines,
                showWhitespace: input.showWhitespace,
                fileExtension: input.fileExtension,
                codeFontFamily: input.codeFontFamily,
                codeFontSize: input.codeFontSize,
                theme: input.theme,
                lspContext: input.lspContext.map(DiffPaneLSPContextToken.init),
                threadSignatures: hunkThreads,
                annotations: hunkAnnotations,
                activeHighlight: input.activeCommentHighlight,
                allowsReviewLineSelection: input.allowsReviewLineSelection,
                canReply: input.canReply,
                canResolve: input.canResolve,
                canAddToReview: input.canAddToReview,
                actionPresence: .init(actions)
            )
            return AppKitDiffRowSpec(
                id: "diff-hunk-\(group.id)",
                ownerID: group.id,
                equalityToken: .init(token),
                estimatedHeight: estimatedHeight(
                    for: group,
                    input: input,
                    fusion: fusion,
                    expandedCollapsedRowIDs: state.expandedCollapsedRowIDs
                ),
                retention: hunkRetention(for: hunkThreads, state: state)
            ) {
                AnyView(DiffPaneHunkRow(group: group, fusion: fusion, input: input, state: state))
            }
        }
        return AppKitDiffRowPlan(rows: rows)
    }

    @MainActor
    private static func prewarmHighlightsIfNeeded(input: DiffPaneRowPlanInput, state: DiffPanePresentationState) {
        let signature = DiffHighlightPrewarmer.signature(
            groups: input.model.groups,
            expandedCollapsedRowIDs: state.expandedCollapsedRowIDs,
            layoutMode: input.layoutMode,
            fileExtension: input.fileExtension,
            showWhitespace: input.showWhitespace
        )
        guard state.registerHighlightPrewarm(signature: signature) else { return }
        DiffHighlightPrewarmer.prewarm(
            groups: input.model.groups,
            expandedCollapsedRowIDs: state.expandedCollapsedRowIDs,
            layoutMode: input.layoutMode,
            fileExtension: input.fileExtension,
            font: CenterTypography.resolveCodeFont(family: input.codeFontFamily, size: input.codeFontSize),
            showWhitespace: input.showWhitespace,
            theme: input.theme
        )
    }

    @MainActor
    private static func hunkRetention(
        for threads: [DiffInlineCommentThread],
        state: DiffPanePresentationState
    ) -> AppKitDiffRowRetention {
        guard let activeThreadID = state.activeThreadID,
              threads.contains(where: { $0.id == activeThreadID })
        else { return .recyclable }
        return .pinned
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
        fusion: DiffPaneHunkFusionState,
        expandedCollapsedRowIDs: Set<String>
    ) -> CGFloat {
        DiffPaneStaticHeightEstimator.estimatedHeight(
            for: .init(filePath: input.model.filePath, groups: [group]),
            layoutMode: input.layoutMode,
            expandedCollapsedRowIDs: expandedCollapsedRowIDs,
            codeFont: CenterTypography.resolveCodeFont(family: input.codeFontFamily, size: input.codeFontSize),
            headerFont: CenterTypography.resolveCodeFont(family: input.codeFontFamily, size: input.codeFontSize - 1),
            wrapLines: input.wrapLines,
            showWhitespace: input.showWhitespace,
            fusionStates: [fusion]
        )
    }

    static func threads(for rows: [DiffDisplayRow], from threads: [DiffInlineCommentThread]) -> [DiffInlineCommentThread] {
        guard !threads.isEmpty else { return [] }
        let oldLines = Set(rows.compactMap { $0.old?.anchor.oldLine })
        let newLines = Set(rows.compactMap { $0.new?.anchor.newLine })
        return threads.filter { thread in
            thread.isOldSide
                ? oldLines.contains(where: { thread.lineRange.contains($0) })
                : newLines.contains(where: { thread.lineRange.contains($0) })
        }
    }

    static func annotations(for rows: [DiffDisplayRow], from annotations: [DiffInlineAnnotation]) -> [DiffInlineAnnotation] {
        guard !annotations.isEmpty else { return [] }
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
                        onReviewLineSelected: state.actionRelay.reviewLineSelected,
                        onContextExpansion: state.actionRelay.expandContext
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
                            onReply: { state.actionRelay.reply(to: thread, body: $0) },
                            onStageReply: { state.actionRelay.stageReply(to: thread, body: $0) },
                            onResolve: { state.actionRelay.resolve(thread) },
                            onUnresolve: { state.actionRelay.unresolve(thread) },
                            onEdit: { comment, body in state.actionRelay.edit(thread, comment, body: body) },
                            onDelete: { state.actionRelay.delete(thread, $0) },
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
        let actions = state.actionRelay.hunkActions(for: group.sourceHunk)
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
            if actions.stage != nil {
                hunkActionButton(systemName: "plus.square", tooltip: "Stage hunk") {
                    state.actionRelay.hunkActions(for: group.sourceHunk).stage?()
                }
            }
            if actions.discard != nil {
                hunkActionButton(systemName: "trash", tooltip: "Discard hunk") {
                    state.actionRelay.hunkActions(for: group.sourceHunk).discard?()
                }
            }
            if actions.dropFromCommit != nil {
                hunkActionButton(systemName: "minus.circle", tooltip: "Drop from commit") {
                    state.actionRelay.hunkActions(for: group.sourceHunk).dropFromCommit?()
                }
            }
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
