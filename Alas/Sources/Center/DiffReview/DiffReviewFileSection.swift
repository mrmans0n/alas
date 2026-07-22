import AppKit
import SwiftUI

private struct PendingContextExpansion {
    let key: DiffContextExpansionKey
    let mode: DiffContextExpansionMode
    let edge: DiffContextExpansionEdge?
}

/// O(1) signal that clears a pending draft when the file's structural layout
/// changes. `structuralHash` is `nil` while the display model is still a
/// placeholder. Backed by the digest precomputed on `DiffDisplayModel`.
struct DiffReviewDraftCommentDisplaySignature: Equatable {
    let fileID: String
    let structuralHash: Int?
}

/// O(1) signal that resets loaded context state when the file, its context
/// provider, or its structural layout changes.
struct DiffReviewContextStateSignature: Equatable {
    let fileID: String
    let providerID: String
    let structuralHash: Int?
}

enum DiffReviewActiveCommentCandidate: Equatable {
    case draft(String)
    case inlineFeedback(String)
    case thread(String)
}

enum DiffReviewHunkFusionResolver {
    static func states(for groups: [DiffReviewRenderContext.Group]) -> [DiffPaneHunkFusionState] {
        var states = DiffPaneHunkFusionResolver.states(for: groups.map(\.displayGroup))
        guard states.count == groups.count else { return states }

        for index in groups.indices.dropLast()
            where states[index].fusedWithNext && !groups[index + 1].inlineFeedback.isEmpty {
            states[index] = DiffPaneHunkFusionState(
                fusedWithPrevious: states[index].fusedWithPrevious,
                fusedWithNext: false
            )
            states[index + 1] = DiffPaneHunkFusionState(
                fusedWithPrevious: false,
                fusedWithNext: states[index + 1].fusedWithNext
            )
        }

        return states
    }
}

private struct DiffReviewRenderableGroup: Identifiable {
    let group: DiffReviewRenderContext.Group
    let fusion: DiffPaneHunkFusionState

    var id: String { group.id }
}

struct DiffReviewActiveCommentIDs {
    var hoveredDraftCommentID: String?
    var focusedDraftCommentID: String?
    var hoveredInlineFeedbackID: String?
    var focusedFeedbackID: String?
    var activeThreadID: String?

    var orderedCandidates: [DiffReviewActiveCommentCandidate] {
        [
            hoveredDraftCommentID.map(DiffReviewActiveCommentCandidate.draft),
            hoveredInlineFeedbackID.map(DiffReviewActiveCommentCandidate.inlineFeedback),
            activeThreadID.map(DiffReviewActiveCommentCandidate.thread),
            focusedDraftCommentID.map(DiffReviewActiveCommentCandidate.draft),
            focusedFeedbackID.map(DiffReviewActiveCommentCandidate.inlineFeedback),
        ].compactMap(\.self)
    }
}

struct DiffReviewFileSection: View {
    let file: DiffReviewFileSectionModel
    var inlineFeedback: [DiffReviewInlineFeedback] = []
    var focusedFeedbackID: String? = nil
    var inlineFeedbackScrollTargetID: String? = nil
    var draftComments: [ReviewDraftComment] = []
    var focusedDraftCommentID: String? = nil
    var draftCommentScrollTargetID: String? = nil
    @Binding var layoutMode: DiffLayoutMode
    @Binding var wrapLines: Bool
    @Binding var showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let showsSourceBadge: Bool
    var lspContext: DiffPaneLSPContext? = nil
    var inlineFeedbackActions = DiffReviewInlineFeedbackActions()
    var onSelectInlineFeedback: (DiffReviewInlineFeedback) -> Void = { _ in }
    var draftCommentActions = ReviewDraftCommentActions()
    var onSelectDraftComment: (ReviewDraftComment) -> Void = { _ in }
    var onSaveDraftComment: (DiffReviewLineAnchor, String) -> Void = { _, _ in }
    var allowsDraftCommentCreation: Bool = true
    var onContextExpansionActivated: () -> Void = {}
    var reviewFeedbackTarget: ReviewFeedbackTarget?
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
    #if DEBUG
    var onRenderContextCacheMissForTesting: (() -> Void)? = nil
    #endif

    @Environment(\.theme) private var theme
    @StateObject private var copyFeedback = CopyFeedbackState()
    @StateObject private var renderContextCache = DiffReviewRenderContextCache()
    @State private var pendingDraftAnchor: DiffReviewLineAnchor?
    @State private var pendingDraftBody = ""
    @State private var expandedCollapsedRowIDs: Set<String> = []
    @State private var contextSnapshot: DiffReviewFileContextSnapshot?
    @State private var contextExpansion = DiffContextExpansionState()
    @State private var contextLoadTask: Task<Void, Never>?
    @State private var contextLoadFileID: DiffReviewFileID?
    @State private var contextLoadSignature: DiffReviewContextStateSignature?
    @State private var contextLoadGeneration = 0
    @State private var contextLoadError: String?
    @State private var pendingContextExpansions: [PendingContextExpansion] = []
    @State private var hoveredInlineFeedbackID: String?
    @State private var hoveredDraftCommentID: String?
    @State private var activeThreadID: String?
    @State private var showFullDiffOverride = false
    @FocusState private var draftComposerFocused: Bool

    private var isOverRenderBudget: Bool {
        guard let displayModel = file.displayModel else { return false }
        return DiffReviewRenderBudget.isOverBudget(displayModel)
    }

    private var shouldDeferRender: Bool {
        isOverRenderBudget && !showFullDiffOverride
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            contextLoadErrorRow
            if shouldDeferRender {
                renderBudgetPlaceholder
            } else {
                let renderContext = renderContext
                fileLevelDraftCommentStack(renderContext: renderContext)
                fileLevelInlineFeedbackStack(renderContext: renderContext)
                content(renderContext: renderContext)
            }
        }
        .background(theme.color("bg-1"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .copyFeedbackOverlay(message: copyFeedback.message)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.color("line"), lineWidth: 0.75)
        )
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-file-section-\(file.id.rawValue)",
                label: file.summary.path
            )
        )
        .background(copyFeedbackMarker)
        .onChange(of: draftCommentDisplaySignature) { _, _ in
            clearPendingDraft()
        }
        .onChange(of: file.id) { _, _ in
            showFullDiffOverride = false
            resetContextState()
        }
        .onChange(of: renderBudgetResetSignal) { _, _ in
            // Re-arm the render budget whenever the same file reloads with new
            // content under an unchanged file.id. Keyed off `contentHash`, which
            // captures text-only edits (unlike `structuralHash`); context
            // expansion never mutates `file.displayModel`, so an opened large
            // diff stays open while the reviewer expands context.
            showFullDiffOverride = false
        }
        .onChange(of: contextStateSignature) { _, _ in
            resetContextState()
        }
        .onChange(of: pendingDraftAnchor) { _, anchor in
            guard allowsDraftCommentCreation, anchor != nil else { return }
            Task { @MainActor in
                draftComposerFocused = true
            }
        }
    }

    @ViewBuilder
    private var copyFeedbackMarker: some View {
        if let message = copyFeedback.message {
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-copy-feedback-\(file.id.rawValue)",
                label: message
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(file.summary.status.glyph)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(statusColor(file.summary.status))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.summary.path)
                    .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let originalPath = file.summary.originalPath {
                    Text("from \(originalPath)")
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.color("fg-faint"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            sourceBadge
            Spacer(minLength: 12)
            if shouldShowChangeSummary(additions: file.summary.additions, deletions: file.summary.deletions) {
                HStack(spacing: 9) {
                    Text("+\(file.summary.additions)")
                        .foregroundColor(theme.color("add"))
                    Text("-\(file.summary.deletions)")
                        .foregroundColor(theme.color("del"))
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            if let openFile = file.openFile,
               let openFileTitle = DiffReviewFileSectionActions.openFileButtonTitle(for: file) {
                Button(action: openFile) {
                    Text(openFileTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.color("fg-muted"))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(theme.color("bg-3"))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(openFileTitle)
                .accessibilityIdentifier("diff-review-open-file-\(file.id.rawValue)")
                .accessibilityLabel(openFileTitle)
            }
            if let unstageFile = file.stagedMutationActions?.unstageFile {
                Button("Unstage") {
                    unstageFile()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.color("fg-muted"))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("diff-review-unstage-file-\(file.id.rawValue)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }

    private var effectiveReviewFeedbackTarget: ReviewFeedbackTarget {
        if let reviewFeedbackTarget {
            return reviewFeedbackTarget
        }
        return ReviewFeedbackTarget(
            title: file.summary.path,
            repositoryPath: nil,
            providerDescription: nil,
            sourceDescription: "Local draft comment"
        )
    }

    private var feedbackDraftCommentActions: ReviewDraftCommentActions {
        ReviewDraftCommentActions(
            availability: draftCommentActions.availability,
            edit: draftCommentActions.edit,
            delete: draftCommentActions.delete,
            resolve: draftCommentActions.resolve,
            dismiss: draftCommentActions.dismiss,
            copyPrompt: { bundle in
                draftCommentActions.copyPrompt(bundle)
                copyFeedback.show("Copied prompt")
            },
            publishProvider: draftCommentActions.publishProvider,
            agent: draftCommentActions.agent,
            agentTargets: draftCommentActions.agentTargets,
            sendToAgent: draftCommentActions.sendToAgent
        )
    }

    @ViewBuilder
    private var contextLoadErrorRow: some View {
        if let contextLoadError {
            Text("Could not load surrounding context: \(contextLoadError)")
                .font(.system(size: 11))
                .foregroundColor(theme.color("warn"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(theme.color("bg-2"))
                .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
                .background(
                    DiffReviewAccessibilityMarker(
                        identifier: "diff-review-context-error-\(file.id.rawValue)",
                        label: "Could not load surrounding context: \(contextLoadError)"
                    )
                )
        }
    }

    @ViewBuilder
    private func fileLevelDraftCommentStack(renderContext: DiffReviewRenderContext?) -> some View {
        let fileLevel = fileLevelDraftComments(renderContext: renderContext)
        if !fileLevel.isEmpty {
            fullWidthDraftCommentStack(fileLevel)
        }
    }

    @ViewBuilder
    private func fullWidthDraftCommentStack(_ comments: [ReviewDraftComment]) -> some View {
        if !comments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(comments) { comment in
                    draftCommentCard(comment)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.color("bg-1"))
            .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
        }
    }

    @ViewBuilder
    private func draftCommentStack(
        _ comments: [ReviewDraftComment],
        rows: [DiffDisplayRow]
    ) -> some View {
        if !comments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(comments) { comment in
                    DiffFeedbackLaneView(
                        lane: DiffFeedbackLaneResolver.lane(for: comment),
                        layoutMode: layoutMode,
                        rows: rows
                    ) {
                        draftCommentCard(comment)
                            .padding(.horizontal, 14)
                    }
                }
            }
            .padding(.vertical, 10)
            .background(theme.color("bg-1"))
            .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
        }
    }

    private func draftCommentCard(_ comment: ReviewDraftComment) -> some View {
        ReviewDraftCommentCard(
            comment: comment,
            file: file.summary,
            isFocused: comment.id == focusedDraftCommentID,
            actions: feedbackDraftCommentActions,
            reviewFeedbackTarget: effectiveReviewFeedbackTarget,
            onSelect: onSelectDraftComment,
            onHoverChange: { isHovered in
                hoveredDraftCommentID = isHovered ? comment.id : (hoveredDraftCommentID == comment.id ? nil : hoveredDraftCommentID)
            }
        )
        .id(DiffReviewDraftCommentTargetID.targetID(commentID: comment.id, fileID: file.id))
    }

    @ViewBuilder
    private func fileLevelInlineFeedbackStack(renderContext: DiffReviewRenderContext?) -> some View {
        let fileLevel = fileLevelInlineFeedback(renderContext: renderContext)
        if !fileLevel.isEmpty {
            inlineFeedbackStack(fileLevel, file: file.summary)
        }
    }

    @ViewBuilder
    private func inlineFeedbackStack(
        _ items: [DiffReviewInlineFeedback],
        file: DiffReviewFileSummary,
        rows: [DiffDisplayRow]? = nil
    ) -> some View {
        if !items.isEmpty {
            let display = DiffReviewInlineFeedbackDisplayPolicy.display(
                for: items,
                includingRequiredIDs: requiredInlineFeedbackIDs
            )
            if let rows {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(display.visibleItems) { item in
                        DiffFeedbackLaneView(
                            lane: DiffFeedbackLaneResolver.lane(for: item),
                            layoutMode: layoutMode,
                            rows: rows
                        ) {
                            inlineFeedbackCard(item, file: file)
                                .padding(.horizontal, 14)
                        }
                    }
                    if display.hiddenCount > 0 {
                        DiffReviewInlineFeedbackMoreRow(hiddenCount: display.hiddenCount)
                            .padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 10)
                .background(theme.color("bg-1"))
                .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(display.visibleItems) { item in
                        inlineFeedbackCard(item, file: file)
                    }
                    if display.hiddenCount > 0 {
                        DiffReviewInlineFeedbackMoreRow(hiddenCount: display.hiddenCount)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(theme.color("bg-1"))
                .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
            }
        }
    }

    private func inlineFeedbackCard(
        _ item: DiffReviewInlineFeedback,
        file: DiffReviewFileSummary
    ) -> some View {
        DiffReviewInlineFeedbackCard(
            item: item,
            file: file,
            isFocused: item.id == focusedFeedbackID,
            actions: inlineFeedbackActions,
            onSelect: onSelectInlineFeedback,
            onHoverChange: { isHovered in
                hoveredInlineFeedbackID = isHovered ? item.id : (hoveredInlineFeedbackID == item.id ? nil : hoveredInlineFeedbackID)
            }
        )
        .id(DiffReviewInlineFeedbackTargetID.targetID(feedbackID: item.id, fileID: file.id))
    }

    private var requiredInlineFeedbackIDs: Set<String> {
        Set([focusedFeedbackID, inlineFeedbackScrollTargetID].compactMap(\.self))
    }

    private var commandedInlineFeedbackIDs: Set<String> {
        Set([inlineFeedbackScrollTargetID].compactMap(\.self))
    }

    private var commandedDraftCommentIDs: Set<String> {
        Set([draftCommentScrollTargetID].compactMap(\.self))
    }

    private func fileLevelInlineFeedback(renderContext: DiffReviewRenderContext?) -> [DiffReviewInlineFeedback] {
        guard let renderContext else { return inlineFeedback }
        return renderContext.fileLevelInlineFeedback
    }

    private func fileLevelDraftComments(renderContext: DiffReviewRenderContext?) -> [ReviewDraftComment] {
        guard let renderContext else {
            return ReviewDraftCommentPlacement.position(draftComments, in: []).fileLevel
        }
        return renderContext.fileLevelDraftComments
    }

    private var renderContext: DiffReviewRenderContext? {
        guard let displayModel = file.displayModel else { return nil }
        let key = DiffReviewRenderContextKey(
            fileID: file.id,
            displayModel: displayModel,
            contextSnapshot: contextSnapshot,
            contextProviderAvailable: file.contextProvider != nil,
            contextExpansion: contextExpansion,
            inlineFeedback: inlineFeedback,
            draftComments: draftComments,
            pendingDraftAnchor: pendingDraftAnchor,
            canCreateDraftComment: allowsDraftCommentCreation,
            threads: threads,
            annotations: annotations
        )
        return renderContextCache.context(key: key) {
            #if DEBUG
            onRenderContextCacheMissForTesting?()
            #endif
            return DiffReviewRenderContextBuilder.build(
                fileID: file.id,
                displayModel: displayModel,
                contextSnapshot: contextSnapshot,
                contextProviderAvailable: file.contextProvider != nil,
                contextExpansion: contextExpansion,
                inlineFeedback: inlineFeedback,
                draftComments: draftComments,
                pendingDraftAnchor: pendingDraftAnchor,
                canCreateDraftComment: allowsDraftCommentCreation,
                threads: threads,
                annotations: annotations
            )
        }
    }

    private var currentDisplayGroups: [DiffDisplayGroup]? {
        renderContext?.groups.map(\.displayGroup)
    }

    /// Review annotations that the placeholder hides while the diff is deferred.
    /// Computed from the cheap input arrays so it never forces a `renderContext` build.
    private var hiddenReviewItemCount: Int {
        draftComments.count + inlineFeedback.count + threads.count
    }

    private var renderBudgetPlaceholder: some View {
        let changedLines = file.summary.additions + file.summary.deletions
        let hiddenItems = hiddenReviewItemCount
        return VStack(alignment: .leading, spacing: 8) {
            Text("Large diff hidden for performance")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Text("\(changedLines.formatted()) changed lines. Rendering may be slow.")
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
            if hiddenItems > 0 {
                Text("^[\(hiddenItems) comment](inflect: true) hidden — show the full diff to view.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                    .accessibilityIdentifier("diff-review-render-budget-hidden-comments-\(file.id.rawValue)")
            }
            Button {
                showFullDiffOverride = true
            } label: {
                Text("Show full diff")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.color("fg-muted"))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(theme.color("bg-3"))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("diff-review-show-full-diff-\(file.id.rawValue)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
        .background(theme.color("bg-1"))
        .background(renderBudgetScrollAnchors)
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-render-budget-\(file.id.rawValue)",
                label: "Large diff hidden for performance"
            )
        )
    }

    /// Zero-size anchors carrying the same target IDs the rendered comment views
    /// would, so the summary-rail / comment-selection scroll flow resolves a
    /// target even while the diff body is deferred. Scrolling lands on the
    /// placeholder (with its "N comments hidden" hint) instead of silently
    /// no-oping; the reviewer can then choose "Show full diff".
    private var renderBudgetScrollAnchors: some View {
        VStack(spacing: 0) {
            ForEach(draftComments, id: \.id) { comment in
                Color.clear
                    .frame(height: 0)
                    .id(DiffReviewDraftCommentTargetID.targetID(commentID: comment.id, fileID: file.id))
            }
            ForEach(inlineFeedback, id: \.id) { item in
                Color.clear
                    .frame(height: 0)
                    .id(DiffReviewInlineFeedbackTargetID.targetID(feedbackID: item.id, fileID: file.id))
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(renderContext: DiffReviewRenderContext?) -> some View {
        if let displayModel = file.displayModel, let renderContext {
            let groups = renderContext.groups
            let fusionStates = DiffReviewHunkFusionResolver.states(for: groups)
            let renderableGroups = zip(groups, fusionStates).map { pair in
                DiffReviewRenderableGroup(group: pair.0, fusion: pair.1)
            }
            let renderableGroupsByID = Dictionary(uniqueKeysWithValues: renderableGroups.map { ($0.id, $0) })
            let requiredGroupIDs = DiffReviewRequiredGroupResolver.groupIDs(
                in: groups,
                inlineFeedbackIDs: commandedInlineFeedbackIDs,
                draftCommentIDs: commandedDraftCommentIDs
            )
            if !requiredGroupIDs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(DiffReviewGroupRenderRun.runs(in: groups, requiredGroupIDs: requiredGroupIDs)) { run in
                        switch run.content {
                        case .lazy(let groups):
                            lazyGroupStack(
                                groups.compactMap { renderableGroupsByID[$0.id] },
                                displayModel: displayModel
                            )
                        case .required(let group):
                            // Keep commanded card IDs available without eagerly rendering unrelated hunks.
                            if let renderableGroup = renderableGroupsByID[group.id] {
                                groupContent(renderableGroup, displayModel: displayModel)
                            }
                        }
                    }
                }
            } else {
                lazyGroupStack(renderableGroups, displayModel: displayModel)
            }
        } else {
            let message = file.placeholderMessage ?? "This file cannot be rendered in the review view."
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 18)
                .background(theme.color("bg-1"))
                .background(
                    DiffReviewAccessibilityMarker(
                        identifier: "diff-review-placeholder-\(file.id.rawValue)",
                        label: message
                    )
                )
        }
    }

    private func lazyGroupStack(
        _ groups: [DiffReviewRenderableGroup],
        displayModel: DiffDisplayModel
    ) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(groups) { group in
                groupContent(group, displayModel: displayModel)
            }
        }
    }

    private func groupContent(
        _ renderableGroup: DiffReviewRenderableGroup,
        displayModel: DiffDisplayModel
    ) -> some View {
        let group = renderableGroup.group
        return VStack(spacing: 0) {
            if !group.inlineFeedback.isEmpty {
                inlineFeedbackStack(
                    group.inlineFeedback,
                    file: file.summary,
                    rows: group.displayGroup.rows
                )
            }
            reviewGroup(group, displayModel: displayModel, fusion: renderableGroup.fusion)
        }
    }

    @ViewBuilder
    private func reviewGroup(
        _ group: DiffReviewRenderContext.Group,
        displayModel: DiffDisplayModel,
        fusion: DiffPaneHunkFusionState
    ) -> some View {
        let displayGroup = group.displayGroup
        if group.containsLocalAccessories {
            VStack(alignment: .leading, spacing: 0) {
                segmentedHunkHeader(displayGroup)
                ForEach(group.segments) { segment in
                    if !segment.rows.isEmpty {
                        ForEach(segment.blocks) { block in
                            switch block {
                            case .rows(let rowSeg):
                                DiffPaneTextDocumentView(
                                    group: DiffDisplayGroup(
                                        id: "\(segment.id)-\(rowSeg.id)",
                                        header: displayGroup.header,
                                        sourceHunk: displayGroup.sourceHunk,
                                        rows: rowSeg.rows,
                                        rowsSignature: rowSeg.rowsSignature
                                    ),
                                    expandedCollapsedRowIDs: expandedCollapsedRowIDs,
                                    layoutMode: layoutMode,
                                    wrapLines: wrapLines,
                                    showWhitespace: showWhitespace,
                                    fileExtension: LanguageRegistry.highlighterExtension(forPath: file.summary.path),
                                    codeFontFamily: codeFontFamily,
                                    codeFontSize: codeFontSize,
                                    theme: theme,
                                    lspContext: lspContext,
                                    activeCommentHighlight: activeHighlight(for: rowSeg.rows),
                                    allowsReviewLineSelection: allowsDraftCommentCreation,
                                    onReviewLineSelected: { anchor in
                                        pendingDraftAnchor = anchor
                                        pendingDraftBody = ""
                                    },
                                    onContextExpansion: loadContextAndExpand
                                )
                                .fixedSize(horizontal: false, vertical: true)
                            case .thread(let thread):
                                DiffFeedbackLaneView(
                                    lane: DiffFeedbackLaneResolver.lane(for: thread),
                                    layoutMode: layoutMode,
                                    rows: segment.rows
                                ) {
                                    DiffInlineCommentCard(
                                        thread: thread,
                                        onReply: { body in onReply(thread, body) },
                                        onStageReply: { body in onStageReply(thread, body) },
                                        onResolve: { onResolve(thread) },
                                        onUnresolve: { onUnresolve(thread) },
                                        onEdit: { comment, newBody in onEdit(thread, comment, newBody) },
                                        onDelete: { comment in onDelete(thread, comment) },
                                        canReply: canReply && thread.viewerCanReply,
                                        canResolve: canResolve && (thread.viewerCanResolve || thread.viewerCanUnresolve),
                                        canAddToReview: canAddToReview,
                                        onActiveChange: { active in
                                            activeThreadID = active ? thread.id : (activeThreadID == thread.id ? nil : activeThreadID)
                                        }
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            case .annotation(let annotation):
                                DiffFeedbackLaneView(
                                    lane: DiffFeedbackLaneResolver.lane(for: annotation),
                                    layoutMode: layoutMode,
                                    rows: segment.rows
                                ) {
                                    DiffInlineAnnotationCard(annotation: annotation)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                    if !segment.draftComments.isEmpty {
                        draftCommentStack(segment.draftComments, rows: segment.rows)
                    }
                    if segment.showsComposer {
                        draftComposer(rows: segment.rows)
                    }
                }
            }
            .background(theme.color("bg-1"))
            .clipShape(DiffPaneHunkCardShape(fusion: fusion))
            .overlay(
                DiffPaneHunkCardShape(fusion: fusion)
                    .stroke(theme.color("line"), lineWidth: 0.75)
            )
            .padding(.bottom, fusion.bottomPadding)
        } else {
            DiffPaneView(
                model: DiffDisplayModel(filePath: displayModel.filePath, groups: [displayGroup]),
                fileExtension: LanguageRegistry.highlighterExtension(forPath: file.summary.path),
                layoutMode: $layoutMode,
                wrapLines: $wrapLines,
                showWhitespace: $showWhitespace,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                showsToolbar: false,
                verticalScrollMode: .staticHeight,
                lspContext: lspContext,
                activeCommentHighlight: activeHighlight(for: displayGroup.rows),
                allowsReviewLineSelection: allowsDraftCommentCreation,
                onReviewLineSelected: { anchor in
                    pendingDraftAnchor = anchor
                    pendingDraftBody = ""
                },
                onContextExpansion: loadContextAndExpand,
                threads: threads,
                annotations: annotations,
                onReply: onReply,
                onResolve: onResolve,
                onUnresolve: onUnresolve,
                onEdit: onEdit,
                onDelete: onDelete,
                canReply: canReply,
                canResolve: canResolve,
                onStageReply: onStageReply,
                canAddToReview: canAddToReview,
                hunkFusionStates: [fusion],
                hunkActions: { hunk in
                    let enabled = file.stagedMutationActions?.isHunkUnstageEnabled?(hunk) ?? false
                    return DiffPaneHunkActions(
                        dropFromCommit: enabled ? { file.stagedMutationActions?.unstageHunk?(hunk) } : nil
                    )
                }
            )
        }
    }

    private func activeHighlight(for rows: [DiffDisplayRow]) -> DiffReviewCommentHighlight? {
        let highlight = activeCommentIDs.orderedCandidates.lazy.compactMap(activeHighlight(for:)).first
        guard let highlight, rowsContainHighlight(highlight, rows: rows) else { return nil }
        return highlight
    }

    private var activeCommentIDs: DiffReviewActiveCommentIDs {
        DiffReviewActiveCommentIDs(
            hoveredDraftCommentID: hoveredDraftCommentID,
            focusedDraftCommentID: focusedDraftCommentID,
            hoveredInlineFeedbackID: hoveredInlineFeedbackID,
            focusedFeedbackID: focusedFeedbackID,
            activeThreadID: activeThreadID
        )
    }

    private func activeHighlight(for candidate: DiffReviewActiveCommentCandidate) -> DiffReviewCommentHighlight? {
        switch candidate {
        case .draft(let id):
            return draftCommentHighlight(id: id)
        case .inlineFeedback(let id):
            return inlineFeedbackHighlight(id: id)
        case .thread(let id):
            return threadHighlight(id: id)
        }
    }

    private func draftCommentHighlight(id: String) -> DiffReviewCommentHighlight? {
        guard let comment = draftComments.first(where: { $0.id == id }),
              comment.state != .dismissed
        else { return nil }
        return DiffReviewCommentHighlight(
            path: comment.path,
            side: comment.side,
            lineRange: comment.normalizedLineRange
        )
    }

    private func inlineFeedbackHighlight(id: String) -> DiffReviewCommentHighlight? {
        guard let item = inlineFeedback.first(where: { $0.id == id }),
              let line = item.anchor.line
        else { return nil }
        return DiffReviewCommentHighlight(path: item.anchor.path, side: item.anchor.side, line: line)
    }

    private func threadHighlight(id: String) -> DiffReviewCommentHighlight? {
        guard let activeThread = threads.first(where: { $0.id == id }) else { return nil }
        return DiffReviewCommentHighlight(
            path: activeThread.filePath,
            side: activeThread.isOldSide ? .old : .new,
            lineRange: activeThread.lineRange
        )
    }

    private func rowsContainHighlight(_ highlight: DiffReviewCommentHighlight, rows: [DiffDisplayRow]) -> Bool {
        rows.contains { row in
            rowContainsHighlight(highlight, row: row)
        }
    }

    private func rowContainsHighlight(_ highlight: DiffReviewCommentHighlight, row: DiffDisplayRow) -> Bool {
        highlight.matchesVisibleSourceLine(row.old) || highlight.matchesVisibleSourceLine(row.new)
    }

    private func segmentedHunkHeader(_ group: DiffDisplayGroup) -> some View {
        HStack(spacing: 8) {
            Text(group.header)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 1))
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
            Spacer(minLength: 12)
            if !DiffCollapsedContextController.collapsedRowIDs(in: group).isEmpty {
                let expanded = DiffCollapsedContextController.isExpanded(group, expandedIDs: expandedCollapsedRowIDs)
                Button {
                    expandedCollapsedRowIDs = DiffCollapsedContextController.toggled(
                        group,
                        expandedIDs: expandedCollapsedRowIDs
                    )
                } label: {
                    Image(systemName: expanded ? "minus.square" : "plus.square")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.color("fg-muted"))
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse context" : "Expand context")
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder
    private func draftComposer(rows: [DiffDisplayRow]) -> some View {
        if allowsDraftCommentCreation, let pendingDraftAnchor {
            DiffFeedbackLaneView(
                lane: DiffFeedbackLaneResolver.lane(for: pendingDraftAnchor),
                layoutMode: layoutMode,
                rows: rows
            ) {
                draftComposerBody
            }
        }
    }

    @ViewBuilder
    private var draftComposerBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReviewDraftComposerTextEditor(
                text: $pendingDraftBody,
                theme: theme,
                isFocused: $draftComposerFocused,
                onSave: savePendingDraft,
                onCancel: clearPendingDraft
            )
            .frame(minHeight: 76, maxHeight: 104)
            .background(focusedComposerMarker)
            .onAppear {
                draftComposerFocused = true
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(theme.color("accent").opacity(0.65), lineWidth: 0.75)
            )
            .accessibilityIdentifier("diff-review-draft-composer")

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Cancel") {
                    clearPendingDraft()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.color("fg-muted"))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityIdentifier("diff-review-draft-composer-cancel")

                Button("Save") {
                    savePendingDraft()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.color("bg-1"))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(theme.color("accent"))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityIdentifier("diff-review-draft-composer-save")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.color("bg-1"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-draft-composer-marker",
                label: "Draft comment composer"
            )
        )
    }

    @ViewBuilder
    private var focusedComposerMarker: some View {
        if draftComposerFocused {
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-draft-composer-focused",
                label: "Draft comment composer focused"
            )
        }
    }

    private func savePendingDraft() {
        guard let pendingDraftAnchor else { return }
        let canonicalAnchor = ReviewDraftCommentRowSegmentation.canonicalPendingAnchor(
            pendingDraftAnchor,
            in: currentDisplayGroups ?? []
        )
        let body = pendingDraftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        guard currentDraftRowKeys.contains(ReviewDraftCommentPlacement.RowKey(
            side: canonicalAnchor.side,
            line: canonicalAnchor.draftPlacementLine
        )) else {
            clearPendingDraft()
            return
        }

        onSaveDraftComment(canonicalAnchor, body)
        clearPendingDraft()
    }

    private func clearPendingDraft() {
        pendingDraftAnchor = nil
        pendingDraftBody = ""
        draftComposerFocused = false
    }

    private var currentDraftRowKeys: Set<ReviewDraftCommentPlacement.RowKey> {
        guard let groups = currentDisplayGroups else { return [] }
        return Set(groups.flatMap(ReviewDraftCommentPlacement.allRowKeys))
    }

    /// Coarse structural fingerprint of the current display model, read in O(1)
    /// from the digest precomputed at model-build time. `.onChange` re-evaluates
    /// its value on every body pass, so this must never walk the rows.
    private var displayStructuralHash: Int? {
        file.displayModel?.structuralHash
    }

    /// Content-level fingerprint (includes row text) used to re-arm the render
    /// budget on same-file reloads. Unlike `structuralHash`, it changes on
    /// pure text edits; unlike `file.id`, it changes when a same-path file
    /// reloads with new content.
    private var renderBudgetResetSignal: Int? {
        file.displayModel?.contentHash
    }

    private var draftCommentDisplaySignature: DiffReviewDraftCommentDisplaySignature {
        DiffReviewDraftCommentDisplaySignature(
            fileID: file.id.rawValue,
            structuralHash: displayStructuralHash
        )
    }

    private var contextStateSignature: DiffReviewContextStateSignature {
        DiffReviewContextStateSignature(
            fileID: file.id.rawValue,
            providerID: file.contextProvider?.id.uuidString ?? "no-context-provider",
            structuralHash: displayStructuralHash
        )
    }

    private func loadContextAndExpand(
        _ key: DiffContextExpansionKey,
        mode: DiffContextExpansionMode,
        edge: DiffContextExpansionEdge?
    ) {
        guard let provider = file.contextProvider else { return }
        onContextExpansionActivated()
        if contextSnapshot != nil {
            applyContextExpansion(key, mode: mode, edge: edge)
            return
        }
        pendingContextExpansions.append(PendingContextExpansion(key: key, mode: mode, edge: edge))
        guard contextLoadTask == nil else { return }
        let fileID = file.id
        let loadSignature = contextStateSignature
        contextLoadGeneration += 1
        let loadGeneration = contextLoadGeneration
        contextLoadError = nil
        contextLoadFileID = fileID
        contextLoadSignature = loadSignature
        contextLoadTask = Task {
            do {
                let snapshot = try await provider.snapshot()
                try Task.checkCancellation()
                await MainActor.run {
                    guard contextLoadGeneration == loadGeneration,
                          contextLoadFileID == fileID,
                          contextLoadSignature == loadSignature
                    else { return }
                    contextSnapshot = snapshot
                    contextLoadTask = nil
                    contextLoadFileID = nil
                    contextLoadSignature = nil
                    let pendingExpansions = pendingContextExpansions
                    pendingContextExpansions = []
                    for expansion in pendingExpansions {
                        applyContextExpansion(expansion.key, mode: expansion.mode, edge: expansion.edge)
                    }
                }
            } catch {
                await MainActor.run {
                    guard contextLoadGeneration == loadGeneration,
                          contextLoadFileID == fileID,
                          contextLoadSignature == loadSignature
                    else { return }
                    contextLoadError = error.localizedDescription
                    contextLoadTask = nil
                    contextLoadFileID = nil
                    contextLoadSignature = nil
                    pendingContextExpansions = []
                }
            }
        }
    }

    private func applyContextExpansion(
        _ key: DiffContextExpansionKey,
        mode: DiffContextExpansionMode,
        edge: DiffContextExpansionEdge?
    ) {
        guard let displayModel = file.displayModel else { return }
        let available = DiffContextExpandedDisplayBuilder.availableLineCount(
            key: key,
            groups: displayModel.groups,
            snapshot: contextSnapshot
        )
        if let edge {
            contextExpansion.expand(key, available: available, mode: mode, edge: edge)
        } else {
            contextExpansion.expand(key, available: available, mode: mode)
        }
    }

    private func resetContextState() {
        contextLoadTask?.cancel()
        contextLoadGeneration += 1
        contextSnapshot = nil
        contextExpansion = DiffContextExpansionState()
        contextLoadTask = nil
        contextLoadFileID = nil
        contextLoadSignature = nil
        contextLoadError = nil
        pendingContextExpansions = []
    }

    @ViewBuilder
    private var sourceBadge: some View {
        if showsSourceBadge, let title = file.summary.groupTitle {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(sourceColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(sourceColor.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .background(
                    DiffReviewAccessibilityMarker(
                        identifier: "diff-review-source-badge-\(file.id.rawValue)",
                        label: title.uppercased()
                    )
                )
        }
    }

    private var sourceColor: Color {
        switch file.summary.groupID ?? file.summary.namespace {
        case "unstaged":
            theme.color("warn")
        case "staged":
            theme.color("info")
        default:
            theme.color("accent")
        }
    }

    private func statusColor(_ status: DiffReviewFileStatus) -> Color {
        switch status {
        case .added:
            theme.color("add")
        case .deleted:
            theme.color("del")
        case .renamed, .copied:
            theme.color("accent")
        case .conflicted:
            theme.color("warn")
        case .modified, .unknown:
            theme.color("fg-dim")
        }
    }
}

enum DiffReviewRequiredGroupResolver {
    static func groupIDs(
        in groups: [DiffReviewRenderContext.Group],
        inlineFeedbackIDs: Set<String>,
        draftCommentIDs: Set<String>
    ) -> Set<String> {
        Set(groups.compactMap { group in
            let isRequired = group.inlineFeedback.contains { inlineFeedbackIDs.contains($0.id) }
                || group.segments.contains { segment in
                    segment.draftComments.contains { draftCommentIDs.contains($0.id) }
                }
            return isRequired ? group.id : nil
        })
    }
}

private struct DiffReviewGroupRenderRun: Identifiable {
    enum Content {
        case lazy([DiffReviewRenderContext.Group])
        case required(DiffReviewRenderContext.Group)
    }

    let id: String
    let content: Content

    static func runs(
        in groups: [DiffReviewRenderContext.Group],
        requiredGroupIDs: Set<String>
    ) -> [DiffReviewGroupRenderRun] {
        var runs: [DiffReviewGroupRenderRun] = []
        var lazyGroups: [DiffReviewRenderContext.Group] = []

        func appendLazyRun() {
            guard let first = lazyGroups.first, let last = lazyGroups.last else { return }
            runs.append(DiffReviewGroupRenderRun(
                id: "lazy:\(first.id):\(last.id)",
                content: .lazy(lazyGroups)
            ))
            lazyGroups.removeAll(keepingCapacity: true)
        }

        for group in groups {
            if requiredGroupIDs.contains(group.id) {
                appendLazyRun()
                runs.append(DiffReviewGroupRenderRun(id: "required:\(group.id)", content: .required(group)))
            } else {
                lazyGroups.append(group)
            }
        }
        appendLazyRun()
        return runs
    }
}

/// Wraps `DiffReviewFileSection` for `.equatable()`, with `layoutMode`,
/// `wrapLines`, and `showWhitespace` captured as plain values rather than
/// compared as live `@Binding`s, plus per-item action-availability
/// snapshots for draft comments and inline feedback.
///
/// `DiffReviewFileSection` itself deliberately does NOT conform to
/// `Equatable`: comparing a `@Binding`'s `wrappedValue` inside `==` doesn't
/// work for render-equality — the previously-rendered struct and a
/// freshly-constructed one both read through to the SAME live external
/// storage, so `lhs.layoutMode == rhs.layoutMode` always reports the
/// CURRENT (post-change) value on both sides regardless of what actually
/// changed between renders. Concretely: toggling split/stacked layout,
/// line wrap, or whitespace display would silently do nothing, because the
/// gate would report "unchanged" even though the setting changed. Plain
/// snapshots, captured once by the caller at construction time (not read
/// through a binding), are what actually distinguish "before" from
/// "after".
///
/// The same problem applies to `draftCommentActions.availability`,
/// `inlineFeedbackActions.availability`, and `draftCommentActions.agentTargets()`:
/// the comment/feedback lists they're applied to can stay unchanged while
/// what's available for them (or the send-to-agent target list itself)
/// changes, and `ReviewDraftCommentCard` / `DiffReviewInlineFeedbackCard`
/// render their action rows from that result. The closures aren't
/// comparable, so the caller evaluates them once and passes the plain
/// `Equatable` results instead.
struct EquatableDiffReviewFileSection: View, Equatable {
    let section: DiffReviewFileSection
    let layoutMode: DiffLayoutMode
    let wrapLines: Bool
    let showWhitespace: Bool
    let draftCommentAvailability: [ReviewDraftCommentActionAvailability]
    let inlineFeedbackAvailability: [DiffReviewInlineFeedbackActionAvailability]
    /// Snapshot of `draftCommentActions.agentTargets()`. `sendToAgentControl`
    /// renders this list live (as a single button or a menu with per-target
    /// titles) independent of the `canSendToAgent`/`canShowSendToAgent`
    /// booleans already captured above — the target set (or a target's
    /// title) can change while availability stays true, and the closure
    /// itself isn't comparable.
    let draftCommentAgentTargets: [ReviewFeedbackAgentTarget]

    var body: some View { section }

    /// Render-relevant equality so SwiftUI can skip this subtree — which hosts
    /// one `NSViewRepresentable` per diff segment — when a parent body storm
    /// (watcher refresh, keystroke, unrelated observable write) did not change
    /// anything visible here. Closure inputs (action structs, selection
    /// callbacks) are intentionally excluded: an older closure generation
    /// stays correct because they read live values through `@State` /
    /// `@Observable` storage or capture per-file constants that the content
    /// comparison already covers. `@State` / `@StateObject` / `@Environment`
    /// dependencies are tracked by SwiftUI independently of this comparison.
    static func == (lhs: EquatableDiffReviewFileSection, rhs: EquatableDiffReviewFileSection) -> Bool {
        lhs.layoutMode == rhs.layoutMode
            && lhs.wrapLines == rhs.wrapLines
            && lhs.showWhitespace == rhs.showWhitespace
            && lhs.draftCommentAvailability == rhs.draftCommentAvailability
            && lhs.inlineFeedbackAvailability == rhs.inlineFeedbackAvailability
            && lhs.draftCommentAgentTargets == rhs.draftCommentAgentTargets
            && lhs.section.file.hasSameRenderableContent(as: rhs.section.file)
            && lhs.section.inlineFeedback == rhs.section.inlineFeedback
            && lhs.section.focusedFeedbackID == rhs.section.focusedFeedbackID
            && lhs.section.inlineFeedbackScrollTargetID == rhs.section.inlineFeedbackScrollTargetID
            && lhs.section.draftComments == rhs.section.draftComments
            && lhs.section.focusedDraftCommentID == rhs.section.focusedDraftCommentID
            && lhs.section.draftCommentScrollTargetID == rhs.section.draftCommentScrollTargetID
            && lhs.section.codeFontFamily == rhs.section.codeFontFamily
            && lhs.section.codeFontSize == rhs.section.codeFontSize
            && lhs.section.showsSourceBadge == rhs.section.showsSourceBadge
            && DiffPaneLSPContext.rendersEqual(lhs.section.lspContext, rhs.section.lspContext)
            && lhs.section.allowsDraftCommentCreation == rhs.section.allowsDraftCommentCreation
            && lhs.section.reviewFeedbackTarget == rhs.section.reviewFeedbackTarget
            && lhs.section.threads == rhs.section.threads
            && lhs.section.annotations == rhs.section.annotations
            && lhs.section.canReply == rhs.section.canReply
            && lhs.section.canResolve == rhs.section.canResolve
            && lhs.section.canAddToReview == rhs.section.canAddToReview
    }
}

enum ReviewDraftComposerKeyboardAction: Equatable {
    case save
    case cancel

    static func resolve(key: String, modifiers: NSEvent.ModifierFlags) -> Self? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if key == "\r", flags.contains(.command) {
            return .save
        }
        if key == "\u{1b}" {
            return .cancel
        }
        return nil
    }
}

struct ReviewDraftComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let theme: Theme
    let isFocused: FocusState<Bool>.Binding
    let focusRequestGeneration: Int
    let onSave: () -> Void
    let onCancel: () -> Void

    init(
        text: Binding<String>,
        theme: Theme,
        isFocused: FocusState<Bool>.Binding,
        focusRequestGeneration: Int = 0,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _text = text
        self.theme = theme
        self.isFocused = isFocused
        self.focusRequestGeneration = focusRequestGeneration
        self.onSave = onSave
        self.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        let textView = ReviewDraftComposerNSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 9)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.onKeyboardAction = context.coordinator.perform
        textView.onWindowChanged = { [weak coordinator = context.coordinator] in
            coordinator?.requestFocusIfNeeded()
        }
        scrollView.documentView = textView
        context.coordinator.textView = textView
        applyTheme(to: scrollView, textView: textView)
        context.coordinator.requestFocusIfNeeded()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ReviewDraftComposerNSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.onKeyboardAction = context.coordinator.perform
        textView.onWindowChanged = { [weak coordinator = context.coordinator] in
            coordinator?.requestFocusIfNeeded()
        }
        applyTheme(to: scrollView, textView: textView)
        context.coordinator.requestFocusIfNeeded()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelScheduledFocusRequest()
        guard let textView = scrollView.documentView as? ReviewDraftComposerNSTextView else { return }
        textView.onKeyboardAction = nil
        textView.onWindowChanged = nil
        textView.delegate = nil
    }

    private func applyTheme(to scrollView: NSScrollView, textView: NSTextView) {
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = NSColor(theme.color("bg-2")).cgColor
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = NSColor(theme.color("fg"))
        textView.insertionPointColor = NSColor(theme.color("accent"))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReviewDraftComposerTextEditor
        weak var textView: NSTextView?
        private var latestFulfilledFocusRequestGeneration = 0
        private var scheduledFocusRequestGeneration: Int?
        private var scheduledFocusTask: Task<Void, Never>?

        init(_ parent: ReviewDraftComposerTextEditor) {
            self.parent = parent
        }

        deinit {
            scheduledFocusTask?.cancel()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = false
        }

        func requestFocusIfNeeded() {
            let generation = parent.focusRequestGeneration
            let hasExplicitRequest = generation > latestFulfilledFocusRequestGeneration
            let hasLegacyRequest = generation == 0 && parent.isFocused.wrappedValue
            guard hasExplicitRequest || hasLegacyRequest else {
                cancelScheduledFocusRequest()
                return
            }
            guard scheduledFocusRequestGeneration != generation else { return }

            cancelScheduledFocusRequest()
            scheduledFocusRequestGeneration = generation
            scheduledFocusTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                defer {
                    if self.scheduledFocusRequestGeneration == generation {
                        self.scheduledFocusRequestGeneration = nil
                        self.scheduledFocusTask = nil
                    }
                }

                guard self.parent.focusRequestGeneration == generation else { return }
                if generation == 0 {
                    guard self.parent.isFocused.wrappedValue else { return }
                } else {
                    guard generation > self.latestFulfilledFocusRequestGeneration else { return }
                }
                guard let textView = self.textView,
                      let window = textView.window
                else { return }

                if window.firstResponder !== textView {
                    guard window.makeFirstResponder(textView) else { return }
                }
                if generation > 0 {
                    self.latestFulfilledFocusRequestGeneration = generation
                }
            }
        }

        func cancelScheduledFocusRequest() {
            scheduledFocusTask?.cancel()
            scheduledFocusTask = nil
            scheduledFocusRequestGeneration = nil
        }

        func perform(_ action: ReviewDraftComposerKeyboardAction) {
            switch action {
            case .save:
                parent.onSave()
            case .cancel:
                parent.onCancel()
            }
        }
    }
}

private final class ReviewDraftComposerNSTextView: NSTextView {
    var onKeyboardAction: (@MainActor (ReviewDraftComposerKeyboardAction) -> Void)?
    var onWindowChanged: (@MainActor () -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?()
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers ?? event.characters ?? ""
        if let action = ReviewDraftComposerKeyboardAction.resolve(key: key, modifiers: event.modifierFlags) {
            onKeyboardAction?(action)
            return
        }
        super.keyDown(with: event)
    }
}

enum ReviewDraftCommentPlacement {
    struct RowKey: Hashable, Equatable {
        let side: DiffReviewInlineFeedbackSide
        let line: Int
    }

    struct Result: Equatable {
        let fileLevel: [ReviewDraftComment]
        let byRowAnchor: [RowKey: [ReviewDraftComment]]
        let groupIDByCommentID: [String: String]
    }

    static func position(
        _ comments: [ReviewDraftComment],
        in groups: [DiffDisplayGroup]
    ) -> Result {
        let visibleKeys = Set(groups.flatMap(allRowKeys))
        let groupIDByKey = firstGroupIDByRowKey(in: groups)
        var fileLevel: [ReviewDraftComment] = []
        var byRowAnchor: [RowKey: [ReviewDraftComment]] = [:]
        var groupIDByCommentID: [String: String] = [:]

        for comment in comments where comment.state != .dismissed {
            let key = RowKey(side: comment.side, line: comment.normalizedLineRange.upperBound)
            if visibleKeys.contains(key) {
                byRowAnchor[key, default: []].append(comment)
                if let groupID = groupIDByKey[key] {
                    groupIDByCommentID[comment.id] = groupID
                }
            } else {
                fileLevel.append(comment)
            }
        }

        return Result(
            fileLevel: sorted(fileLevel),
            byRowAnchor: byRowAnchor.mapValues(sorted),
            groupIDByCommentID: groupIDByCommentID
        )
    }

    private static func firstGroupIDByRowKey(in groups: [DiffDisplayGroup]) -> [RowKey: String] {
        var output: [RowKey: String] = [:]
        for group in groups {
            for key in allRowKeys(in: group) where output[key] == nil {
                output[key] = group.id
            }
        }
        return output
    }

    static func visibleRowKeys(in group: DiffDisplayGroup) -> [RowKey] {
        group.rows.flatMap { row -> [RowKey] in
            visibleRowKeys(in: row)
        }
    }

    static func allRowKeys(in group: DiffDisplayGroup) -> [RowKey] {
        group.rows.flatMap(allRowKeys)
    }

    static func visibleRowKeys(in row: DiffDisplayRow) -> [RowKey] {
        var keys: [RowKey] = []
        if let oldLine = row.old?.lineNumber {
            keys.append(RowKey(side: .old, line: oldLine))
        }
        if let newLine = row.new?.lineNumber {
            keys.append(RowKey(side: .new, line: newLine))
        }
        for line in Set([row.old?.lineNumber, row.new?.lineNumber].compactMap(\.self)).sorted() {
            keys.append(RowKey(side: .unknown, line: line))
        }
        return keys
    }

    static func allRowKeys(in row: DiffDisplayRow) -> [RowKey] {
        visibleRowKeys(in: row) + row.collapsedRows.flatMap(allRowKeys)
    }

    static func sorted(_ comments: [ReviewDraftComment]) -> [ReviewDraftComment] {
        comments.sorted { lhs, rhs in
            if lhs.path != rhs.path {
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            if lhs.normalizedLineRange.lowerBound != rhs.normalizedLineRange.lowerBound {
                return lhs.normalizedLineRange.lowerBound < rhs.normalizedLineRange.lowerBound
            }
            if lhs.normalizedLineRange.upperBound != rhs.normalizedLineRange.upperBound {
                return lhs.normalizedLineRange.upperBound < rhs.normalizedLineRange.upperBound
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    static func comments(
        matching keys: [RowKey],
        in placement: Result,
        groupID: String? = nil,
        excludingIDs excludedIDs: Set<String> = []
    ) -> [ReviewDraftComment] {
        var seenIDs = excludedIDs
        var comments: [ReviewDraftComment] = []
        for key in keys {
            for comment in placement.byRowAnchor[key] ?? [] {
                if let groupID, placement.groupIDByCommentID[comment.id] != groupID {
                    continue
                }
                guard seenIDs.insert(comment.id).inserted else { continue }
                comments.append(comment)
            }
        }
        return sorted(comments)
    }
}

enum ReviewDraftCommentRowSegmentation {
    struct Segment: Equatable, Identifiable {
        let id: String
        let rows: [DiffDisplayRow]
        let rowsSignature: DiffDisplayRowsSignature
        let draftComments: [ReviewDraftComment]
        let showsComposer: Bool

        init(
            id: String,
            rows: [DiffDisplayRow],
            rowsSignature: DiffDisplayRowsSignature? = nil,
            draftComments: [ReviewDraftComment],
            showsComposer: Bool
        ) {
            self.id = id
            self.rows = rows
            self.rowsSignature = rowsSignature ?? DiffDisplayRowsSignature(rows)
            self.draftComments = draftComments
            self.showsComposer = showsComposer
        }

        static func == (lhs: Segment, rhs: Segment) -> Bool {
            lhs.id == rhs.id
                && lhs.rowsSignature == rhs.rowsSignature
                && lhs.draftComments == rhs.draftComments
                && lhs.showsComposer == rhs.showsComposer
        }
    }

    struct Result: Equatable {
        let items: [Segment]

        var containsLocalAccessories: Bool {
            items.contains { !$0.draftComments.isEmpty || $0.showsComposer }
        }
    }

    static func segments(
        for group: DiffDisplayGroup,
        placement: ReviewDraftCommentPlacement.Result,
        pendingAnchor: DiffReviewLineAnchor?,
        canCreateDraftComment: Bool = true
    ) -> Result {
        let pendingKey = pendingAnchor.flatMap { pendingRowKey(for: $0, in: group) }
        let duplicatePendingKey = pendingKey.map { key in
            group.rows.filter { ReviewDraftCommentPlacement.allRowKeys(in: $0).contains(key) }.count > 1
        } ?? false
        var segments: [Segment] = []
        var bufferedRows: [DiffDisplayRow] = []
        var emittedCommentIDs: Set<String> = []

        for row in group.rows {
            bufferedRows.append(row)
            let keys = ReviewDraftCommentPlacement.allRowKeys(in: row)
            let comments = ReviewDraftCommentPlacement.comments(
                matching: keys,
                in: placement,
                groupID: group.id,
                excludingIDs: emittedCommentIDs
            )
            emittedCommentIDs.formUnion(comments.map(\.id))
            let showsComposer = canCreateDraftComment && (pendingKey.map { key in
                guard keys.contains(key) else { return false }
                guard duplicatePendingKey, let pendingAnchor else { return true }
                return rowContainsDisplayRowIndex(pendingAnchor.endRowIndex, row: row)
            } ?? false)
            guard !comments.isEmpty || showsComposer else { continue }

            segments.append(Segment(
                id: "\(group.id)-segment-\(segments.count)",
                rows: bufferedRows,
                draftComments: comments,
                showsComposer: showsComposer
            ))
            bufferedRows = []
        }

        if !bufferedRows.isEmpty {
            segments.append(Segment(
                id: "\(group.id)-segment-\(segments.count)",
                rows: bufferedRows,
                draftComments: [],
                showsComposer: false
            ))
        }

        return Result(items: segments)
    }

    static func canonicalPendingAnchor(
        _ anchor: DiffReviewLineAnchor,
        in groups: [DiffDisplayGroup]
    ) -> DiffReviewLineAnchor {
        guard anchor.side == .unknown else { return anchor }
        guard groups.contains(where: { canPlaceUnknownAnchor(anchor, in: $0) }) else { return anchor }

        if let range = selectedLineRange(anchor.selectedLines, side: .new, requiresChange: true) {
            return DiffReviewLineAnchor(
                path: anchor.path,
                side: .new,
                line: range.lowerBound,
                endLine: range.lowerBound == range.upperBound ? nil : range.upperBound,
                rowIndex: anchor.rowIndex,
                endRowIndex: anchor.endRowIndex,
                selectedLines: anchor.selectedLines,
                selectedText: anchor.selectedText
            )
        }

        if let range = selectedLineRange(anchor.selectedLines, side: .old, requiresChange: true) {
            return DiffReviewLineAnchor(
                path: anchor.path,
                side: .old,
                line: range.lowerBound,
                endLine: range.lowerBound == range.upperBound ? nil : range.upperBound,
                rowIndex: anchor.rowIndex,
                endRowIndex: anchor.endRowIndex,
                selectedLines: anchor.selectedLines,
                selectedText: anchor.selectedText
            )
        }

        return anchor
    }

    static func sourceIndexedAnchor(
        _ anchor: DiffReviewLineAnchor,
        in rows: [DiffDisplayRow]
    ) -> DiffReviewLineAnchor {
        let rowIndex = sourceRowIndex(for: anchor.rowIndex, side: anchor.side, in: rows) ?? anchor.rowIndex
        let endRowIndex = sourceRowIndex(for: anchor.endRowIndex, side: anchor.side, in: rows) ?? anchor.endRowIndex
        guard rowIndex != anchor.rowIndex || endRowIndex != anchor.endRowIndex else { return anchor }

        return DiffReviewLineAnchor(
            path: anchor.path,
            side: anchor.side,
            line: anchor.line,
            endLine: anchor.endLine,
            rowIndex: rowIndex,
            endRowIndex: endRowIndex,
            selectedLines: anchor.selectedLines,
            selectedText: anchor.selectedText
        )
    }

    private static func pendingRowKey(
        for anchor: DiffReviewLineAnchor,
        in group: DiffDisplayGroup
    ) -> ReviewDraftCommentPlacement.RowKey? {
        guard anchor.side == .unknown else {
            return ReviewDraftCommentPlacement.RowKey(side: anchor.side, line: anchor.draftPlacementLine)
        }

        guard canPlaceUnknownAnchor(anchor, in: group) else { return nil }
        let canonicalAnchor = canonicalPendingAnchor(anchor, in: [group])
        return ReviewDraftCommentPlacement.RowKey(
            side: canonicalAnchor.side,
            line: canonicalAnchor.draftPlacementLine
        )
    }

    private static func canPlaceUnknownAnchor(
        _ anchor: DiffReviewLineAnchor,
        in group: DiffDisplayGroup
    ) -> Bool {
        let keys = Set(ReviewDraftCommentPlacement.allRowKeys(in: group))
        return keys.contains(ReviewDraftCommentPlacement.RowKey(side: .unknown, line: anchor.draftPlacementLine))
            || keys.contains(ReviewDraftCommentPlacement.RowKey(side: .unknown, line: anchor.line))
    }

    private static func rowContainsDisplayRowIndex(_ rowIndex: Int, row: DiffDisplayRow) -> Bool {
        row.old?.anchor.rowIndex == rowIndex
            || row.new?.anchor.rowIndex == rowIndex
            || row.collapsedRows.contains { rowContainsDisplayRowIndex(rowIndex, row: $0) }
    }

    private static func sourceRowIndex(
        for localRowIndex: Int,
        side: DiffReviewInlineFeedbackSide,
        in rows: [DiffDisplayRow]
    ) -> Int? {
        guard rows.indices.contains(localRowIndex) else { return nil }
        let row = rows[localRowIndex]
        switch side {
        case .old:
            return row.old?.anchor.rowIndex ?? row.new?.anchor.rowIndex
        case .new:
            return row.new?.anchor.rowIndex ?? row.old?.anchor.rowIndex
        case .unknown:
            return row.old?.anchor.rowIndex ?? row.new?.anchor.rowIndex
        }
    }

    private static func selectedLineRange(
        _ selectedLines: [DiffReviewLineAnchor.SelectedLine],
        side: DiffReviewInlineFeedbackSide,
        requiresChange: Bool
    ) -> ClosedRange<Int>? {
        let lines = selectedLines.compactMap { line -> Int? in
            guard line.side == side else { return nil }
            guard !requiresChange || line.isChange else { return nil }
            return line.line
        }
        guard let lower = lines.min(), let upper = lines.max() else { return nil }
        return lower...upper
    }
}

enum DiffReviewInlineFeedbackPlacement {
    struct Result: Equatable {
        let fileLevel: [DiffReviewInlineFeedback]
        let byGroupID: [String: [DiffReviewInlineFeedback]]
    }

    static func position(
        _ items: [DiffReviewInlineFeedback],
        in groups: [DiffDisplayGroup]
    ) -> Result {
        var fileLevel: [DiffReviewInlineFeedback] = []
        var byGroupID: [String: [DiffReviewInlineFeedback]] = [:]

        for item in items {
            guard let line = item.anchor.line,
                  let group = groups.first(where: { contains(line: line, side: item.anchor.side, in: $0) })
            else {
                fileLevel.append(item)
                continue
            }
            byGroupID[group.id, default: []].append(item)
        }

        return Result(fileLevel: fileLevel, byGroupID: byGroupID)
    }

    private static func contains(
        line: Int,
        side: DiffReviewInlineFeedbackSide,
        in group: DiffDisplayGroup
    ) -> Bool {
        group.rows.contains { row in
            contains(line: line, side: side, in: row)
        }
    }

    private static func contains(
        line: Int,
        side: DiffReviewInlineFeedbackSide,
        in row: DiffDisplayRow
    ) -> Bool {
        if rowMatches(line: line, side: side, row: row) {
            return true
        }
        return row.collapsedRows.contains { collapsedRow in
            contains(line: line, side: side, in: collapsedRow)
        }
    }

    private static func rowMatches(
        line: Int,
        side: DiffReviewInlineFeedbackSide,
        row: DiffDisplayRow
    ) -> Bool {
        switch side {
        case .new:
            return row.new?.lineNumber == line
        case .old:
            return row.old?.lineNumber == line
        case .unknown:
            return row.new?.lineNumber == line || row.old?.lineNumber == line
        }
    }
}

enum ReviewDraftCommentDisplayPolicy {
    static let cardMinimumHeight: CGFloat = 86
    private static let estimatedBodyCharactersPerLine = 86
    private static let estimatedBodyLineHeight: CGFloat = 15.5
    private static let cardNonBodyHeight: CGFloat = 52
    private static let stackVerticalPadding: CGFloat = 20
    private static let rowSpacing: CGFloat = 6

    static func estimatedHeight(for comments: [ReviewDraftComment]) -> CGFloat {
        guard !comments.isEmpty else { return 0 }

        let visibleHeights = comments.reduce(CGFloat(0)) { total, comment in
            total + estimatedCardHeight(for: comment)
        }
        let spacingHeight = CGFloat(max(0, comments.count - 1)) * rowSpacing
        return stackVerticalPadding + visibleHeights + spacingHeight
    }

    static func estimatedCardHeight(for comment: ReviewDraftComment) -> CGFloat {
        let bodyLineCount = estimatedLineCount(for: comment.bodyMarkdown)
        let bodyHeight = CGFloat(bodyLineCount) * estimatedBodyLineHeight

        return max(cardMinimumHeight, cardNonBodyHeight + bodyHeight)
    }

    private static func estimatedLineCount(for source: String) -> Int {
        let logicalLines = source.split(separator: "\n", omittingEmptySubsequences: false)
        return logicalLines.reduce(0) { total, line in
            total + max(1, Int(ceil(Double(line.count) / Double(estimatedBodyCharactersPerLine))))
        }
    }
}

enum DiffReviewInlineFeedbackDisplayPolicy {
    static let maximumVisibleCards = 3
    static let cardMinimumHeight: CGFloat = 78
    static let moreRowEstimatedHeight: CGFloat = 20
    private static let estimatedBodyCharactersPerLine = 86
    private static let estimatedBodyLineHeight: CGFloat = 15.5
    private static let cardNonBodyHeight: CGFloat = 46
    private static let stackVerticalPadding: CGFloat = 20
    private static let rowSpacing: CGFloat = 6

    struct Display {
        let visibleItems: [DiffReviewInlineFeedback]
        let hiddenCount: Int
    }

    static func display(for items: [DiffReviewInlineFeedback]) -> Display {
        display(for: items, includingRequiredIDs: [])
    }

    static func display(
        for items: [DiffReviewInlineFeedback],
        includingRequiredIDs requiredIDs: Set<String>
    ) -> Display {
        let visibleItems = Array(items.prefix(maximumVisibleCards))
        let visibleIDs = Set(visibleItems.map(\.id))
        let requiredItems = items.filter { requiredIDs.contains($0.id) && !visibleIDs.contains($0.id) }
        let visible = visibleItems + requiredItems
        return Display(
            visibleItems: visible,
            hiddenCount: max(0, items.count - visible.count)
        )
    }

    static func estimatedHeight(for itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }

        let visibleCount = min(itemCount, maximumVisibleCards)
        let hiddenCount = max(0, itemCount - visibleCount)
        let rowCount = visibleCount + (hiddenCount > 0 ? 1 : 0)
        let rowHeights = CGFloat(visibleCount) * cardMinimumHeight
            + (hiddenCount > 0 ? moreRowEstimatedHeight : 0)
        let spacingHeight = CGFloat(max(0, rowCount - 1)) * rowSpacing

        return stackVerticalPadding + rowHeights + spacingHeight
    }

    static func estimatedHeight(for items: [DiffReviewInlineFeedback]) -> CGFloat {
        guard !items.isEmpty else { return 0 }

        let display = display(for: items)
        let visibleHeights = display.visibleItems.reduce(CGFloat(0)) { total, item in
            total + estimatedCardHeight(for: item)
        }
        let rowCount = display.visibleItems.count + (display.hiddenCount > 0 ? 1 : 0)
        let moreHeight = display.hiddenCount > 0 ? moreRowEstimatedHeight : 0
        let spacingHeight = CGFloat(max(0, rowCount - 1)) * rowSpacing

        return stackVerticalPadding + visibleHeights + moreHeight + spacingHeight
    }

    static func estimatedCardHeight(for item: DiffReviewInlineFeedback) -> CGFloat {
        let bodyLineCount = estimatedLineCount(for: item.bodyPreview)
        let bodyHeight = CGFloat(bodyLineCount) * estimatedBodyLineHeight

        return max(cardMinimumHeight, cardNonBodyHeight + bodyHeight)
    }

    private static func estimatedLineCount(for source: String) -> Int {
        let logicalLines = source.split(separator: "\n", omittingEmptySubsequences: false)
        return logicalLines.reduce(0) { total, line in
            total + max(1, Int(ceil(Double(line.count) / Double(estimatedBodyCharactersPerLine))))
        }
    }
}

enum DiffReviewInlineFeedbackMarkdown {
    private static let typography = ACPChatTypography(fontFamily: "", fontSize: 11)

    static func view(_ source: String) -> some View {
        ACPMarkdownText(raw: source, typography: typography, showsCodeBlockCopyButton: false)
    }

    @MainActor
    static func plainText(_ source: String) -> String {
        ACPMarkdownText.parse(source).compactMap { block -> String? in
            switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text):
                return ACPMarkdownInlineRenderer.plainText(text)
            case .code(_, let body), .streamingCode(_, let body):
                return body
            case .table(let header, let rows):
                return ([header] + rows).map { row in
                    row.map { ACPMarkdownInlineRenderer.plainText($0) }.joined(separator: " ")
                }.joined(separator: " ")
            }
        }.joined(separator: " ")
    }
}

struct ReviewDraftCommentCard: View {
    let comment: ReviewDraftComment
    let file: DiffReviewFileSummary
    let isFocused: Bool
    let actions: ReviewDraftCommentActions
    let reviewFeedbackTarget: ReviewFeedbackTarget
    let onSelect: (ReviewDraftComment) -> Void
    var onHoverChange: (Bool) -> Void = { _ in }

    @Environment(\.theme) private var theme
    @State private var isEditing = false
    @State private var editingBody = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditing {
                cardContent
            } else {
                Button {
                    onSelect(comment)
                } label: {
                    cardContent
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("diff-review-draft-comment-select-\(comment.id)")
            }

            actionRow
        }
        .padding(8)
        .frame(minHeight: ReviewDraftCommentDisplayPolicy.cardMinimumHeight, alignment: .top)
        .background(isFocused ? theme.color("accent-soft") : theme.color("bg-2"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused ? theme.color("accent") : statusColor.opacity(0.65), lineWidth: isFocused ? 1 : 0.75)
        )
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-draft-comment-\(comment.id)",
                label: accessibilityLabel
            )
        )
        .background(focusedMarker)
        .onHover { hovering in
            onHoverChange(Self.reportsHover(isHovered: hovering, isFocused: isFocused))
        }
    }

    static func reportsHover(isHovered: Bool, isFocused: Bool) -> Bool {
        isHovered
    }

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(statusColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(draftLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(statusColor)

                    Text(lineDescription)
                        .font(.system(size: 10))
                        .foregroundColor(theme.color("fg-faint"))

                    if comment.state == .resolved {
                        Text(resolvedLabel)
                            .font(.system(size: 10))
                            .foregroundColor(theme.color("fg-faint"))
                    }
                }
                .lineLimit(1)

                ForEach(providerStateLabels.indices, id: \.self) { index in
                    let label = providerStateLabels[index]
                    Text(label.text)
                        .font(.system(size: 10))
                        .foregroundColor(label.color)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isEditing {
                    ReviewDraftComposerTextEditor(
                        text: $editingBody,
                        theme: theme,
                        isFocused: $editorFocused,
                        onSave: saveEditingComment,
                        onCancel: cancelEditingComment
                    )
                    .frame(minHeight: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.color("line"), lineWidth: 0.75)
                    )
                    .accessibilityIdentifier("diff-review-draft-comment-editor-\(comment.id)")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        DiffReviewInlineFeedbackMarkdown.view(comment.bodyMarkdown)

                        ForEach(comment.allReplies) { reply in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(reply.author.displayName)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.color("fg-faint"))
                                DiffReviewInlineFeedbackMarkdown.view(reply.bodyMarkdown)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(theme.color("line"))
                                    .frame(width: 2)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var focusedMarker: some View {
        if isFocused {
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-draft-comment-focused-\(comment.id)",
                label: accessibilityLabel
            )
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        let availability = actions.availability(comment)
        if availability.canEdit
            || availability.canDelete
            || availability.canResolve
            || availability.canDismiss
            || availability.canCopyPrompt
            || availability.canShowSendToAgent
            || availability.canPublishProvider
        {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if isEditing {
                    actionButton(id: "save", title: "Save") {
                        saveEditingComment()
                    }
                    actionButton(id: "cancel", title: "Cancel") {
                        cancelEditingComment()
                    }
                } else if availability.canEdit {
                    actionButton(id: "edit", title: "Edit") {
                        editingBody = comment.bodyMarkdown
                        isEditing = true
                        editorFocused = true
                    }
                }
                if availability.canDelete {
                    actionButton(id: "delete", title: "Delete") {
                        actions.delete(comment)
                    }
                }
                if availability.canResolve {
                    actionButton(id: "resolve", title: "Resolve") {
                        actions.resolve(comment)
                    }
                }
                if availability.canDismiss {
                    actionButton(id: "dismiss", title: "Dismiss") {
                        actions.dismiss(comment)
                    }
                }
                if availability.canCopyPrompt {
                    actionButton(id: "copy", title: "Copy") {
                        actions.copyPrompt(feedbackBundle)
                    }
                }
                if availability.canPublishProvider {
                    actionButton(id: "publish", title: "Publish") {
                        actions.publishProvider(comment)
                    }
                }
                if availability.canShowSendToAgent {
                    sendToAgentControl(isEnabled: availability.canSendToAgent)
                }
            }
        }
    }

    @ViewBuilder
    private func sendToAgentControl(isEnabled: Bool) -> some View {
        let targets = actions.agentTargets()
        if targets.count > 1 {
            Menu {
                let existingTargets = targets.filter { !$0.isNewChat }
                let newChatTargets = targets.filter { $0.isNewChat }
                ForEach(existingTargets) { target in
                    Button {
                        actions.sendToAgent(feedbackBundle, target)
                    } label: {
                        sendToAgentTargetLabel(target)
                    }
                }
                if !existingTargets.isEmpty, !newChatTargets.isEmpty {
                    Divider()
                }
                ForEach(newChatTargets) { target in
                    Button {
                        actions.sendToAgent(feedbackBundle, target)
                    } label: {
                        sendToAgentTargetLabel(target)
                    }
                }
            } label: {
                sendActionLabel(enabled: isEnabled, showsMenuIndicator: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(!isEnabled)
            .help("Send")
            .accessibilityIdentifier("diff-review-draft-comment-action-send-\(comment.id)")
            .accessibilityLabel("Send")
        } else {
            sendActionButton(enabled: isEnabled) {
                guard let target = targets.first else { return }
                actions.sendToAgent(feedbackBundle, target)
            }
        }
    }

    private func sendToAgentTargetLabel(_ target: ReviewFeedbackAgentTarget) -> some View {
        Label {
            Text(target.title)
        } icon: {
            if let agent = actions.agent(target) {
                Image(nsImage: AgentLogoView.menuImage(for: agent, size: 14))
            } else {
                Image(systemName: "sparkle")
            }
        }
    }

    private func sendActionButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            sendActionLabel(enabled: enabled, showsMenuIndicator: false)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("Send")
        .accessibilityIdentifier(accessibilityIdentifier(forActionID: "send"))
        .accessibilityLabel("Send")
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "\(markerIdentifier(forActionID: "send"))-label",
                label: "Send"
            )
        )
        .background(
            ReviewDraftCommentActionPressMarker(
                identifier: markerIdentifier(forActionID: "send"),
                label: "Send",
                isEnabled: enabled,
                action: action
            )
        )
    }

    private func sendActionLabel(enabled: Bool, showsMenuIndicator: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 9.5, weight: .semibold))
            Text("Send")
                .font(.system(size: 10, weight: .semibold))
            if showsMenuIndicator {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .padding(.leading, 1)
            }
        }
        .foregroundColor(enabled ? theme.color("bg-0") : theme.color("fg-faint"))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(enabled ? theme.color("accent") : theme.color("bg-3"))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func actionButton(
        id: String,
        title: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(enabled ? theme.color("fg-muted") : theme.color("fg-faint"))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(title)
        .accessibilityIdentifier(accessibilityIdentifier(forActionID: id))
        .accessibilityLabel(title)
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "\(markerIdentifier(forActionID: id))-label",
                label: title
            )
        )
        .background(
            ReviewDraftCommentActionPressMarker(
                identifier: markerIdentifier(forActionID: id),
                label: title,
                isEnabled: enabled,
                action: action
            )
        )
    }

    private func accessibilityIdentifier(forActionID id: String) -> String {
        return "diff-review-draft-comment-button-\(id)-\(comment.id)"
    }

    private func markerIdentifier(forActionID id: String) -> String {
        if id == "publish" {
            return "diff-review-draft-comment-publish-\(comment.id)"
        }
        return "diff-review-draft-comment-action-\(id)-\(comment.id)"
    }

    private func saveEditingComment() {
        actions.edit(comment, editingBody)
        cancelEditingComment()
    }

    private func cancelEditingComment() {
        isEditing = false
        editingBody = ""
        editorFocused = false
    }

    private var feedbackBundle: ReviewFeedbackBundle {
        ReviewFeedbackBundle(
            target: reviewFeedbackTarget,
            comments: [comment]
        )
    }

    private var lineDescription: String {
        let range = comment.normalizedLineRange
        if range.lowerBound == range.upperBound {
            return "line \(range.lowerBound)"
        }
        return "lines \(range.lowerBound)-\(range.upperBound)"
    }

    private var draftLabel: String {
        let author = comment.effectiveAuthor
        return author.isAgent ? "\(author.displayName) draft" : "Local draft"
    }

    private var resolvedLabel: String {
        if let resolvedBy = comment.resolvedBy, resolvedBy.isAgent {
            return "resolved by \(resolvedBy.displayName)"
        }
        return "resolved"
    }

    private var accessibilityLabel: String {
        [
            "Local draft",
            lineDescription,
            comment.state == .resolved ? "resolved" : nil,
            providerStateLabels.map(\.text).joined(separator: ", "),
            DiffReviewInlineFeedbackMarkdown.plainText(comment.bodyMarkdown),
        ]
        .compactMap { part in
            guard let part, !part.isEmpty else { return nil }
            return part
        }
        .joined(separator: ", ")
    }

    private var providerStateLabels: [(text: String, color: Color)] {
        var labels: [(text: String, color: Color)] = []
        if let publish = comment.providerPublish {
            labels.append(("published to \(publish.provider.displayName)", theme.color("fg-faint")))
        }
        if let error = comment.providerError {
            labels.append(("\(error.provider.displayName) error: \(error.message)", theme.color("warn")))
        }
        return labels
    }

    private var statusColor: Color {
        switch comment.state {
        case .active:
            theme.color("warn")
        case .resolved:
            theme.color("add")
        case .dismissed:
            theme.color("fg-muted")
        }
    }
}

private extension DiffReviewLineAnchor {
    var draftPlacementLine: Int {
        endLine ?? line
    }
}

struct ReviewDraftCommentActionPressMarker: NSViewRepresentable {
    let identifier: String
    let label: String
    var isEnabled = true
    let action: () -> Void

    func makeNSView(context: Context) -> ReviewDraftCommentActionPressView {
        let view = ReviewDraftCommentActionPressView(frame: .zero)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityRole(.button)
        view.setAccessibilityEnabled(isEnabled)
        view.isEnabled = isEnabled
        view.action = action
        return view
    }

    func updateNSView(_ view: ReviewDraftCommentActionPressView, context: Context) {
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityRole(.button)
        view.setAccessibilityEnabled(isEnabled)
        view.isEnabled = isEnabled
        view.action = action
    }
}

final class ReviewDraftCommentActionPressView: NSView {
    var isEnabled = true
    var action: () -> Void = {}

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action()
        return true
    }
}

struct DiffReviewInlineFeedbackCard: View {
    let item: DiffReviewInlineFeedback
    let file: DiffReviewFileSummary
    let isFocused: Bool
    let actions: DiffReviewInlineFeedbackActions
    let onSelect: (DiffReviewInlineFeedback) -> Void
    var onHoverChange: (Bool) -> Void = { _ in }

    @Environment(\.theme) private var theme
    @State private var replyEditor = DiffReviewInlineFeedbackReplyEditorState()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                DiffReviewInlineFeedbackCardInteraction.select(item, onSelect: onSelect)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(statusColor)
                        .frame(width: 3)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.providerName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(statusColor)

                            if let author = item.author, !author.isEmpty {
                                Text(author)
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.color("fg-muted"))
                            }

                            if let line = item.anchor.line {
                                Text("line \(line)")
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.color("fg-faint"))
                            }
                        }
                        .lineLimit(1)

                        DiffReviewInlineFeedbackMarkdown.view(item.bodyPreview)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("diff-review-inline-feedback-select-\(item.id)")

            actionRow
        }
        .padding(8)
        .frame(minHeight: DiffReviewInlineFeedbackDisplayPolicy.cardMinimumHeight, alignment: .top)
        .background(isFocused ? theme.color("accent-soft") : theme.color("bg-2"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused ? theme.color("accent") : theme.color("line"), lineWidth: isFocused ? 1 : 0.5)
        )
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-inline-feedback-\(item.id)",
                label: accessibilityLabel
            )
        )
        .background(focusedMarker)
        .onHover { hovering in
            onHoverChange(Self.reportsHover(isHovered: hovering, isFocused: isFocused))
        }
    }

    static func reportsHover(isHovered: Bool, isFocused: Bool) -> Bool {
        isHovered
    }

    @ViewBuilder
    private var focusedMarker: some View {
        if isFocused {
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-inline-feedback-focused-\(item.id)",
                label: accessibilityLabel
            )
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        let availability = actions.availability(item, file)
        if replyEditor.isReplying {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Reply", text: $replyEditor.body, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.color("fg"))
                    .padding(7)
                    .background(theme.color("bg-1"))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .accessibilityIdentifier("diff-review-inline-feedback-reply-\(item.id)")

                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    inlineActionButton(id: "reply-save", title: "Save") {
                        _ = replyEditor.save(item) { feedback, body in
                            actions.replyProvider(feedback, file, body)
                        }
                    }
                    inlineActionButton(id: "reply-cancel", title: "Cancel") {
                        replyEditor.cancel()
                    }
                }
            }
        } else if availability.canOpenProvider
            || availability.canCopyContext
            || availability.canSendToAgent
            || availability.canReplyProvider
            || availability.canResolveProvider
            || availability.canUnresolveProvider {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if availability.canOpenProvider {
                    inlineActionButton(id: "open", title: "Open") {
                        DiffReviewInlineFeedbackCardInteraction.open(item) { feedback in
                            actions.openProvider(feedback, file)
                        }
                    }
                }
                if availability.canCopyContext {
                    inlineActionButton(id: "copy", title: "Copy") {
                        DiffReviewInlineFeedbackCardInteraction.copy(item) { feedback in
                            actions.copyContext(feedback, file)
                        }
                    }
                }
                if availability.canSendToAgent {
                    inlineActionButton(id: "send", title: "Send") {
                        DiffReviewInlineFeedbackCardInteraction.send(item) { feedback in
                            actions.sendToAgent(feedback, file)
                        }
                    }
                }
                if availability.canReplyProvider {
                    inlineActionButton(id: "reply", title: "Reply") {
                        replyEditor.start()
                    }
                }
                if availability.canResolveProvider {
                    inlineActionButton(id: "resolve", title: "Resolve") {
                        actions.resolveProvider(item, file)
                    }
                }
                if availability.canUnresolveProvider {
                    inlineActionButton(id: "unresolve", title: "Unresolve") {
                        actions.unresolveProvider(item, file)
                    }
                }
            }
        }
    }

    private func inlineActionButton(id: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.color("fg-muted"))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityIdentifier("diff-review-inline-feedback-\(id)-\(item.id)")
        .accessibilityLabel(title)
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "diff-review-inline-feedback-action-\(id)-\(item.id)",
                label: title
            )
        )
        .background(
            ReviewDraftCommentActionPressMarker(
                identifier: "diff-review-inline-feedback-action-\(id)-\(item.id)",
                label: title,
                action: action
            )
        )
    }

    private var accessibilityLabel: String {
        [
            item.providerName,
            item.author,
            item.anchor.line.map { "line \($0)" },
            DiffReviewInlineFeedbackMarkdown.plainText(item.bodyPreview),
        ]
        .compactMap { part in
            guard let part, !part.isEmpty else { return nil }
            return part
        }
        .joined(separator: ", ")
    }

    private var statusColor: Color {
        switch item.status {
        case .actionable, .pending:
            theme.color("accent")
        case .failed:
            theme.color("del")
        case .passed, .resolved:
            theme.color("add")
        case .cancelled, .unknown:
            theme.color("fg-muted")
        }
    }
}

enum DiffReviewInlineFeedbackCardInteraction {
    static func select(
        _ item: DiffReviewInlineFeedback,
        onSelect: (DiffReviewInlineFeedback) -> Void
    ) {
        onSelect(item)
    }

    static func open(
        _ item: DiffReviewInlineFeedback,
        action: (DiffReviewInlineFeedback) -> Void
    ) {
        action(item)
    }

    static func copy(
        _ item: DiffReviewInlineFeedback,
        action: (DiffReviewInlineFeedback) -> Void
    ) {
        action(item)
    }

    static func send(
        _ item: DiffReviewInlineFeedback,
        action: (DiffReviewInlineFeedback) -> Void
    ) {
        action(item)
    }

    static func reply(
        _ item: DiffReviewInlineFeedback,
        body: String,
        action: (DiffReviewInlineFeedback, String) -> Void
    ) {
        action(item, body)
    }
}

struct DiffReviewInlineFeedbackReplyEditorState: Equatable {
    var isReplying = false
    var body = ""

    mutating func start() {
        body = ""
        isReplying = true
    }

    mutating func cancel() {
        body = ""
        isReplying = false
    }

    @discardableResult
    mutating func save(
        _ item: DiffReviewInlineFeedback,
        action: (DiffReviewInlineFeedback, String) -> Void
    ) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        DiffReviewInlineFeedbackCardInteraction.reply(item, body: trimmed, action: action)
        body = ""
        isReplying = false
        return true
    }
}

private struct DiffReviewInlineFeedbackMoreRow: View {
    let hiddenCount: Int

    @Environment(\.theme) private var theme

    var body: some View {
        Text("+\(hiddenCount) more feedback")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(theme.color("fg-muted"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(theme.color("bg-2"))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .background(
                DiffReviewAccessibilityMarker(
                    identifier: "diff-review-inline-feedback-more",
                    label: "+\(hiddenCount) more feedback"
                )
            )
    }
}

enum DiffReviewFileSectionActions {
    static func openFileButtonTitle(for file: DiffReviewFileSectionModel) -> String? {
        file.openFile == nil ? nil : "Open File"
    }
}
