import SwiftUI

enum AppKitDiffReviewRowID {
    static func header(fileID: DiffReviewFileID) -> String { "file:\(fileID.rawValue):header" }
    static func placeholder(fileID: DiffReviewFileID) -> String { "file:\(fileID.rawValue):placeholder" }
    static func image(fileID: DiffReviewFileID) -> String { "file:\(fileID.rawValue):image" }
    static func contextError(fileID: DiffReviewFileID) -> String { "file:\(fileID.rawValue):context-error" }
    static func groupHeader(fileID: DiffReviewFileID, groupID: String) -> String { "file:\(fileID.rawValue):group:\(groupID):header" }
    static func segment(fileID: DiffReviewFileID, segmentID: String, blockID: String) -> String { "file:\(fileID.rawValue):segment:\(segmentID):rows:\(blockID)" }
    static func composer(fileID: DiffReviewFileID, segmentID: String) -> String { "file:\(fileID.rawValue):composer:\(segmentID)" }
    static func spacing(fileID: DiffReviewFileID) -> String { "file:\(fileID.rawValue):spacing" }
    static func inlineFeedbackMore(fileID: DiffReviewFileID, scopeID: String) -> String {
        "file:\(fileID.rawValue):feedback-more:\(scopeID)"
    }

    static func inlineFeedback(_ target: DiffReviewInlineFeedbackTargetID) -> String {
        "file:\(target.fileID.rawValue):feedback:\(target.feedbackID)"
    }

    static func draftComment(_ target: DiffReviewDraftCommentTargetID) -> String {
        "file:\(target.fileID.rawValue):draft:\(target.commentID)"
    }

    static func thread(fileID: DiffReviewFileID, threadID: String) -> String { "file:\(fileID.rawValue):thread:\(threadID)" }
    static func annotation(fileID: DiffReviewFileID, annotationID: String) -> String { "file:\(fileID.rawValue):annotation:\(annotationID)" }
}

struct AppKitDiffReviewActionPresence: Equatable {
    var canOpenFile = false
    var canUnstageFile = false
    var canCreateDraftComment = false
    var canReply = false
    var canResolve = false
    var canAddToReview = false
    var canUnstageHunk = false
    var hunkUnstageEnabled = false
}

struct AppKitDiffReviewRowToken: Equatable {
    let rowID: String
    let contentSignature: Int
    let layoutMode: DiffLayoutMode
    let wrapLines: Bool
    let showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let theme: Theme
    let lspWorktreeID: String?
    let lspRelativePath: String?
    let lspLanguage: String?
    let lspManagerIdentity: ObjectIdentifier?
    let inlineFeedbackAvailability: DiffReviewInlineFeedbackActionAvailability?
    let draftCommentAvailability: ReviewDraftCommentActionAvailability?
    let reviewFeedbackTarget: ReviewFeedbackTarget?
    let hoveredInlineFeedbackID: String?
    let hoveredDraftCommentID: String?
    let focusedFeedbackID: String?
    let focusedDraftCommentID: String?
    let activeThreadID: String?
    let draftComposerFocused: Bool
    let actionPresence: AppKitDiffReviewActionPresence
}

@MainActor
struct AppKitDiffReviewRowInput {
    let file: DiffReviewFileSectionModel
    var inlineFeedback: [DiffReviewInlineFeedback] = []
    var draftComments: [ReviewDraftComment] = []
    var threads: [DiffInlineCommentThread] = []
    var annotations: [DiffInlineAnnotation] = []
    let state: AppKitDiffReviewFileState
    let theme: Theme
    var layoutMode: DiffLayoutMode = .split
    var wrapLines = false
    var showWhitespace = false
    var codeFontFamily = "SF Mono"
    var codeFontSize: CGFloat = 13
    var showsSourceBadge = false
    var automaticallyRendersDiff = true
    var showsBottomSpacing = true
    var focusedFeedbackID: String?
    var focusedDraftCommentID: String?
    var allowsDraftCommentCreation = true
    var actionPresence = AppKitDiffReviewActionPresence()
    var lspContext: DiffPaneLSPContext?
    var reviewFeedbackTarget: ReviewFeedbackTarget?
    var draftCommentActions: ReviewDraftCommentActions?
    init(
        file: DiffReviewFileSectionModel,
        inlineFeedback: [DiffReviewInlineFeedback] = [],
        draftComments: [ReviewDraftComment] = [],
        threads: [DiffInlineCommentThread] = [],
        annotations: [DiffInlineAnnotation] = [],
        state: AppKitDiffReviewFileState,
        theme: Theme,
        layoutMode: DiffLayoutMode = .split,
        wrapLines: Bool = false,
        showWhitespace: Bool = false,
        codeFontFamily: String = "SF Mono",
        codeFontSize: CGFloat = 13,
        showsSourceBadge: Bool = false,
        automaticallyRendersDiff: Bool = true,
        showsBottomSpacing: Bool = true,
        focusedFeedbackID: String? = nil,
        focusedDraftCommentID: String? = nil,
        allowsDraftCommentCreation: Bool = true,
        actionPresence: AppKitDiffReviewActionPresence = .init(),
        lspContext: DiffPaneLSPContext? = nil,
        reviewFeedbackTarget: ReviewFeedbackTarget? = nil,
        draftCommentActions: ReviewDraftCommentActions? = nil,
        onContextExpansionActivated: (() -> Void)? = nil
    ) {
        self.file = file
        self.inlineFeedback = inlineFeedback
        self.draftComments = draftComments
        self.threads = threads
        self.annotations = annotations
        self.state = state
        self.theme = theme
        self.layoutMode = layoutMode
        self.wrapLines = wrapLines
        self.showWhitespace = showWhitespace
        self.codeFontFamily = codeFontFamily
        self.codeFontSize = codeFontSize
        self.showsSourceBadge = showsSourceBadge
        self.automaticallyRendersDiff = automaticallyRendersDiff
        self.showsBottomSpacing = showsBottomSpacing
        self.focusedFeedbackID = focusedFeedbackID
        self.focusedDraftCommentID = focusedDraftCommentID
        self.allowsDraftCommentCreation = allowsDraftCommentCreation
        self.actionPresence = actionPresence
        self.lspContext = lspContext
        self.reviewFeedbackTarget = reviewFeedbackTarget
        self.draftCommentActions = draftCommentActions
        if let onContextExpansionActivated {
            state.actionRelay.update(onContextExpansionActivated: onContextExpansionActivated)
        }
    }

    func beginPendingDraft(at anchor: DiffReviewLineAnchor) {
        state.pendingDraftAnchor = anchor
        state.pendingDraftBody = ""
        state.draftComposerFocusRequestGeneration &+= 1
    }

    func clearPendingDraft() {
        state.pendingDraftAnchor = nil
        state.pendingDraftBody = ""
        state.isDraftComposerFocused = false
    }

    func savePendingDraft() {
        guard let anchor = state.pendingDraftAnchor else { return }
        let groups = currentDisplayGroups
        let canonicalAnchor = ReviewDraftCommentRowSegmentation.canonicalPendingAnchor(anchor, in: groups)
        let body = state.pendingDraftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let rowKeys = Set(groups.flatMap(ReviewDraftCommentPlacement.allRowKeys))
        guard rowKeys.contains(ReviewDraftCommentPlacement.RowKey(
            side: canonicalAnchor.side,
            line: canonicalAnchor.draftPlacementLine
        )) else {
            clearPendingDraft()
            return
        }
        state.actionRelay.saveDraftComment(canonicalAnchor, body: body)
        clearPendingDraft()
    }

    func loadContextAndExpand(
        _ key: DiffContextExpansionKey,
        mode: DiffContextExpansionMode,
        edge: DiffContextExpansionEdge?
    ) {
        guard let provider = file.contextProvider else { return }
        state.actionRelay.contextExpansionActivated()
        if state.contextSnapshot != nil {
            applyContextExpansion(key, mode: mode, edge: edge)
            return
        }
        state.pendingContextExpansions.append(.init(key: key, mode: mode, edge: edge))
        guard state.contextLoadTask == nil else { return }
        let fileID = file.id
        let signature = contextStateSignature
        let generation = state.beginContextLoad(fileID: fileID, signature: signature)
        state.contextLoadError = nil
        state.contextLoadTask = Task {
            do {
                let snapshot = try await provider.snapshot()
                try Task.checkCancellation()
                guard state.acceptsContextResult(fileID: fileID, generation: generation),
                      state.contextLoadSignature == signature
                else { return }
                state.contextSnapshot = snapshot
                state.contextLoadTask = nil
                state.contextLoadFileID = nil
                state.contextLoadSignature = nil
                let pending = state.pendingContextExpansions
                state.pendingContextExpansions = []
                for expansion in pending {
                    applyContextExpansion(expansion.key, mode: expansion.mode, edge: expansion.edge)
                }
            } catch {
                guard state.acceptsContextResult(fileID: fileID, generation: generation),
                      state.contextLoadSignature == signature
                else { return }
                state.contextLoadError = error.localizedDescription
                state.contextLoadTask = nil
                state.contextLoadFileID = nil
                state.contextLoadSignature = nil
                state.pendingContextExpansions = []
            }
        }
    }

    func activeHighlight(for rows: [DiffDisplayRow]) -> DiffReviewCommentHighlight? {
        let candidates = DiffReviewActiveCommentIDs(
            hoveredDraftCommentID: state.hoveredDraftCommentID,
            focusedDraftCommentID: focusedDraftCommentID,
            hoveredInlineFeedbackID: state.hoveredInlineFeedbackID,
            focusedFeedbackID: focusedFeedbackID,
            activeThreadID: state.activeThreadID
        ).orderedCandidates
        let highlight = candidates.lazy.compactMap(activeHighlight(for:)).first
        guard let highlight,
              rows.contains(where: { highlight.matchesVisibleSourceLine($0.old) || highlight.matchesVisibleSourceLine($0.new) })
        else { return nil }
        return highlight
    }

    private var currentDisplayGroups: [DiffDisplayGroup] {
        guard let displayModel = file.displayModel else { return [] }
        return state.renderContextCache.reviewContext(
            fileID: file.id, displayModel: displayModel,
            contextSnapshot: state.contextSnapshot,
            contextProviderAvailable: file.contextProvider != nil,
            contextExpansion: state.contextExpansion,
            inlineFeedback: inlineFeedback, draftComments: draftComments,
            pendingDraftAnchor: state.pendingDraftAnchor,
            canCreateDraftComment: allowsDraftCommentCreation,
            threads: threads, annotations: annotations
        ).groups.map(\.displayGroup)
    }

    private var contextStateSignature: DiffReviewContextStateSignature {
        .init(
            fileID: file.id.rawValue,
            providerID: file.contextProvider?.id.uuidString ?? "no-context-provider",
            structuralHash: file.displayModel?.structuralHash
        )
    }

    private func applyContextExpansion(
        _ key: DiffContextExpansionKey,
        mode: DiffContextExpansionMode,
        edge: DiffContextExpansionEdge?
    ) {
        guard let displayModel = file.displayModel else { return }
        let available = DiffContextExpandedDisplayBuilder.availableLineCount(
            key: key, groups: displayModel.groups, snapshot: state.contextSnapshot
        )
        if let edge {
            state.contextExpansion.expand(key, available: available, mode: mode, edge: edge)
        } else {
            state.contextExpansion.expand(key, available: available, mode: mode)
        }
    }

    private func activeHighlight(for candidate: DiffReviewActiveCommentCandidate) -> DiffReviewCommentHighlight? {
        switch candidate {
        case .draft(let id):
            guard let comment = draftComments.first(where: { $0.id == id }), comment.state != .dismissed else { return nil }
            return .init(path: comment.path, side: comment.side, lineRange: comment.normalizedLineRange)
        case .inlineFeedback(let id):
            guard let item = inlineFeedback.first(where: { $0.id == id }), let line = item.anchor.line else { return nil }
            return .init(path: item.anchor.path, side: item.anchor.side, line: line)
        case .thread(let id):
            guard let thread = threads.first(where: { $0.id == id }) else { return nil }
            return .init(path: thread.filePath, side: thread.isOldSide ? .old : .new, lineRange: thread.lineRange)
        }
    }
}

struct AppKitDiffReviewRowPlan {
    let corePlan: AppKitDiffRowPlan
    let fallbackByTargetID: [String: String]
    let headerByFileID: [DiffReviewFileID: String]
    let placeholderByFileID: [DiffReviewFileID: String]
}

@MainActor
enum AppKitDiffReviewRowPlanBuilder {
    static func build(inputs: [AppKitDiffReviewRowInput]) -> AppKitDiffReviewRowPlan {
        build(inputs: inputs, maxAutomaticallyRenderedRows: DiffReviewRenderBudget.maxRenderedRows)
    }

    static func build(
        inputs: [AppKitDiffReviewRowInput],
        maxAutomaticallyRenderedRows: Int
    ) -> AppKitDiffReviewRowPlan {
        var rows: [AppKitDiffRowSpec] = []
        var fallbackByTargetID: [String: String] = [:]
        var headerByFileID: [DiffReviewFileID: String] = [:]
        var placeholderByFileID: [DiffReviewFileID: String] = [:]
        let eligibility = DiffReviewRenderEligibility.renderRows(
            ordered: inputs.map(\.file.id),
            renderedRowCounts: inputs.map { $0.file.displayModel.map(DiffReviewRenderBudget.renderedRowCount) },
            maxAutomaticallyRenderedRows: maxAutomaticallyRenderedRows
        )

        for (index, input) in inputs.enumerated() {
            input.state.actionRelay.update(
                stagedMutationActions: input.file.stagedMutationActions,
                openFile: input.file.openFile
            )
            let fileID = input.file.id
            let headerID = AppKitDiffReviewRowID.header(fileID: fileID)
            headerByFileID[fileID] = headerID
            append(&rows, id: headerID, input: input, signature: headerSignature(input), height: 45) {
                AnyView(AppKitDiffReviewHeaderRowBody(input: input))
            }
            if let contextLoadError = input.state.contextLoadError {
                append(
                    &rows,
                    id: AppKitDiffReviewRowID.contextError(fileID: fileID),
                    input: input,
                    signature: contextLoadError.hashValue,
                    height: 34
                ) {
                    AnyView(DiffReviewContextErrorRowBody(
                        fileID: fileID,
                        message: contextLoadError,
                        theme: input.theme
                    ))
                }
            }

            let individuallyDeferred = input.file.displayModel.map(DiffReviewRenderBudget.isOverBudget) ?? false
            let isDeferred = (!input.automaticallyRendersDiff || !eligibility[index].automaticallyRendersDiff || individuallyDeferred)
                && !input.state.showFullDiffOverride
            if isDeferred || (input.file.displayModel == nil && input.file.imageProvider == nil) {
                let placeholderID = AppKitDiffReviewRowID.placeholder(fileID: fileID)
                placeholderByFileID[fileID] = placeholderID
                append(&rows, id: placeholderID, input: input, signature: placeholderSignature(input, deferred: isDeferred), height: 88) {
                    AnyView(AppKitDiffReviewPlaceholderRowBody(input: input, isDeferred: isDeferred))
                }
                mapTargets(input, to: placeholderID, into: &fallbackByTargetID)
            } else if input.file.imageProvider != nil {
                appendFileAccessories(input, context: nil, rows: &rows, fallbacks: &fallbackByTargetID)
                appendImageFeedback(input, rows: &rows)
                let imageID = AppKitDiffReviewRowID.image(fileID: fileID)
                append(&rows, id: imageID, input: input, signature: input.file.imageProvider?.id.hashValue ?? 0, height: 360) {
                    AnyView(AppKitDiffReviewImageRowBody(input: input, loadsImage: true))
                }
                mapTargetsDirectly(input, into: &fallbackByTargetID)
            } else if let context = renderContext(for: input) {
                appendFileAccessories(input, context: context, rows: &rows, fallbacks: &fallbackByTargetID)
                appendTextRows(context, input: input, into: &rows, fallbacks: &fallbackByTargetID)
            }

            if input.showsBottomSpacing,
               !isDeferred,
               input.file.imageProvider == nil,
               input.file.displayModel != nil {
                append(&rows, id: AppKitDiffReviewRowID.spacing(fileID: fileID), input: input, signature: 0, height: 14) {
                    AnyView(Color.clear.frame(height: 14))
                }
            }
        }
        return AppKitDiffReviewRowPlan(
            corePlan: .init(rows: rows), fallbackByTargetID: fallbackByTargetID,
            headerByFileID: headerByFileID, placeholderByFileID: placeholderByFileID
        )
    }

    private static func renderContext(for input: AppKitDiffReviewRowInput) -> DiffReviewRenderContext? {
        guard let displayModel = input.file.displayModel else { return nil }
        return input.state.renderContextCache.reviewContext(
            fileID: input.file.id, displayModel: displayModel,
            contextSnapshot: input.state.contextSnapshot,
            contextProviderAvailable: input.file.contextProvider != nil,
            contextExpansion: input.state.contextExpansion,
            inlineFeedback: input.inlineFeedback, draftComments: input.draftComments,
            pendingDraftAnchor: input.state.pendingDraftAnchor,
            canCreateDraftComment: input.allowsDraftCommentCreation,
            threads: input.threads, annotations: input.annotations
        )
    }

    private static func appendFileAccessories(
        _ input: AppKitDiffReviewRowInput,
        context: DiffReviewRenderContext?,
        rows: inout [AppKitDiffRowSpec],
        fallbacks: inout [String: String]
    ) {
        let feedback = context?.fileLevelInlineFeedback ?? input.inlineFeedback
        let drafts = context?.fileLevelDraftComments
            ?? ReviewDraftCommentPlacement.position(input.draftComments, in: []).fileLevel
        for comment in drafts { appendDraft(comment, input: input, rows: &rows, fallbacks: &fallbacks) }
        appendFeedback(feedback, scopeID: "file", input: input, rows: &rows, fallbacks: &fallbacks)
    }

    private static func appendTextRows(
        _ context: DiffReviewRenderContext,
        input: AppKitDiffReviewRowInput,
        into rows: inout [AppKitDiffRowSpec],
        fallbacks: inout [String: String]
    ) {
        let fusions = DiffReviewHunkFusionResolver.states(for: context.groups)
        for (groupIndex, group) in context.groups.enumerated() {
            appendFeedback(group.inlineFeedback, scopeID: group.id, input: input, rows: &rows, fallbacks: &fallbacks)
            let groupID = AppKitDiffReviewRowID.groupHeader(fileID: input.file.id, groupID: group.id)
            if !group.containsLocalAccessories {
                let rowInput = hunkInput(group: group, context: context, input: input, fusion: fusions[groupIndex])
                let hunkPlan = DiffPaneRowPlanBuilder.build(input: rowInput, state: input.state.hunkPresentationState)
                guard let hunk = hunkPlan.rows.first else { continue }
                rows.append(.init(
                    id: groupID,
                    ownerID: input.file.id.rawValue,
                    equalityToken: hunk.equalityToken,
                    estimatedHeight: hunk.estimatedHeight
                ) {
                    hunk.build()
                })
                continue
            }

            append(&rows, id: groupID, input: input, signature: group.displayGroup.header.hashValue, height: 37) {
                AnyView(AppKitDiffReviewGroupHeaderRowBody(group: group.displayGroup, input: input))
            }
            for segment in group.segments {
                for block in segment.blocks {
                    switch block {
                    case let .rows(rowBlock):
                        let blockID = AppKitDiffReviewRowID.segment(fileID: input.file.id, segmentID: segment.id, blockID: rowBlock.id)
                        append(&rows, id: blockID, input: input, signature: String(reflecting: rowBlock.rowsSignature).hashValue, height: segmentHeight(rowBlock.rows.count, input: input), includesActiveHighlight: true) {
                            AnyView(AppKitDiffReviewSegmentRowBody(rows: rowBlock.rows, rowsSignature: rowBlock.rowsSignature, group: group.displayGroup, input: input))
                        }
                    case let .thread(thread):
                        let threadID = AppKitDiffReviewRowID.thread(fileID: input.file.id, threadID: thread.id)
                        append(
                            &rows, id: threadID, input: input, signature: String(reflecting: thread).hashValue,
                            height: 112, retention: input.state.activeThreadID == thread.id ? .pinned : .recyclable
                        ) {
                            AnyView(AppKitDiffReviewThreadRowBody(thread: thread, rows: segment.rows, input: input))
                        }
                    case let .annotation(annotation):
                        let annotationID = AppKitDiffReviewRowID.annotation(fileID: input.file.id, annotationID: annotation.id)
                        append(&rows, id: annotationID, input: input, signature: String(reflecting: annotation).hashValue, height: 52) {
                            AnyView(AppKitDiffReviewAnnotationRowBody(annotation: annotation, rows: segment.rows, input: input))
                        }
                    }
                }
                for comment in segment.draftComments { appendDraft(comment, input: input, rows: &rows, fallbacks: &fallbacks) }
                if segment.showsComposer {
                    let composerID = AppKitDiffReviewRowID.composer(fileID: input.file.id, segmentID: segment.id)
                    append(
                        &rows,
                        id: composerID,
                        input: input,
                        signature: input.state.draftComposerFocusRequestGeneration,
                        height: 132,
                        retention: input.state.isDraftComposerFocused ? .pinned : .recyclable
                    ) {
                        AnyView(AppKitDiffReviewComposerRowBody(rows: segment.rows, input: input))
                    }
                }
            }
        }
        mapTargetsDirectly(input, into: &fallbacks)
    }

    private static func hunkInput(
        group: DiffReviewRenderContext.Group,
        context: DiffReviewRenderContext,
        input: AppKitDiffReviewRowInput,
        fusion: DiffPaneHunkFusionState
    ) -> DiffPaneRowPlanInput {
        DiffPaneRowPlanInput(
            model: .init(filePath: input.file.summary.path, groups: [group.displayGroup]),
            fileExtension: LanguageRegistry.highlighterExtension(forPath: input.file.summary.path),
            layoutMode: input.layoutMode, wrapLines: input.wrapLines,
            showWhitespace: input.showWhitespace, codeFontFamily: input.codeFontFamily,
            codeFontSize: input.codeFontSize, theme: input.theme,
            lspContext: input.lspContext,
            activeCommentHighlight: input.activeHighlight(for: group.displayGroup.rows),
            allowsReviewLineSelection: input.allowsDraftCommentCreation,
            onReviewLineSelected: input.beginPendingDraft,
            onContextExpansion: input.loadContextAndExpand,
            threads: input.threads, annotations: input.annotations,
            onReply: { input.state.actionRelay.reply(to: $0, body: $1) },
            onResolve: input.state.actionRelay.resolve,
            onUnresolve: input.state.actionRelay.unresolve,
            onEdit: { input.state.actionRelay.edit($1, in: $0, body: $2) },
            onDelete: { input.state.actionRelay.delete($1, in: $0) },
            canReply: input.actionPresence.canReply, canResolve: input.actionPresence.canResolve,
            onStageReply: { input.state.actionRelay.stageReply(to: $0, body: $1) },
            canAddToReview: input.actionPresence.canAddToReview,
            hunkFusionStates: [fusion],
            hunkActions: input.state.actionRelay.hunkActions
        )
    }

    private static func appendImageFeedback(
        _ input: AppKitDiffReviewRowInput,
        rows: inout [AppKitDiffRowSpec]
    ) {
        for thread in input.threads {
            append(
                &rows,
                id: AppKitDiffReviewRowID.thread(fileID: input.file.id, threadID: thread.id),
                input: input,
                signature: String(reflecting: thread).hashValue,
                height: 112,
                retention: input.state.activeThreadID == thread.id ? .pinned : .recyclable
            ) {
                AnyView(AppKitDiffReviewImageThreadRowBody(thread: thread, input: input))
            }
        }
        for annotation in input.annotations {
            append(
                &rows,
                id: AppKitDiffReviewRowID.annotation(fileID: input.file.id, annotationID: annotation.id),
                input: input,
                signature: String(reflecting: annotation).hashValue,
                height: 52
            ) {
                AnyView(AppKitDiffReviewImageAnnotationRowBody(annotation: annotation, input: input))
            }
        }
    }

    private static func appendFeedback(
        _ items: [DiffReviewInlineFeedback],
        scopeID: String,
        input: AppKitDiffReviewRowInput,
        rows: inout [AppKitDiffRowSpec],
        fallbacks: inout [String: String]
    ) {
        let display = DiffReviewInlineFeedbackDisplayPolicy.display(
            for: items, includingRequiredIDs: Set([input.focusedFeedbackID].compactMap(\.self))
        )
        for item in display.visibleItems {
            appendFeedback(item, input: input, rows: &rows, fallbacks: &fallbacks)
        }
        guard display.hiddenCount > 0 else { return }
        append(
            &rows, id: AppKitDiffReviewRowID.inlineFeedbackMore(fileID: input.file.id, scopeID: scopeID),
            input: input, signature: display.hiddenCount, height: DiffReviewInlineFeedbackDisplayPolicy.moreRowEstimatedHeight
        ) {
            AnyView(DiffReviewInlineFeedbackMoreRow(hiddenCount: display.hiddenCount))
        }
    }

    private static func appendFeedback(
        _ item: DiffReviewInlineFeedback,
        input: AppKitDiffReviewRowInput,
        rows: inout [AppKitDiffRowSpec],
        fallbacks: inout [String: String]
    ) {
        let target = DiffReviewInlineFeedbackTargetID.targetID(feedbackID: item.id, fileID: input.file.id)
        let id = AppKitDiffReviewRowID.inlineFeedback(target)
        append(
            &rows, id: id, input: input, signature: String(reflecting: item).hashValue, height: 96,
            retention: input.state.activeInlineFeedbackEditorID == item.id ? .pinned : .recyclable,
            inlineAvailability: input.state.actionRelay.inlineFeedbackAvailability(for: item, file: input.file.summary)
        ) {
            AnyView(AppKitDiffReviewInlineFeedbackRowBody(item: item, input: input))
        }
        fallbacks[id] = id
    }

    private static func appendDraft(
        _ comment: ReviewDraftComment,
        input: AppKitDiffReviewRowInput,
        rows: inout [AppKitDiffRowSpec],
        fallbacks: inout [String: String]
    ) {
        let target = DiffReviewDraftCommentTargetID.targetID(commentID: comment.id, fileID: input.file.id)
        let id = AppKitDiffReviewRowID.draftComment(target)
        append(
            &rows, id: id, input: input, signature: String(reflecting: comment).hashValue, height: 112,
            retention: input.state.activeDraftCommentEditorID == comment.id ? .pinned : .recyclable,
            draftAvailability: input.state.actionRelay.draftCommentAvailability(for: comment),
            reviewFeedbackTarget: input.reviewFeedbackTarget
        ) {
            AnyView(AppKitDiffReviewDraftCommentRowBody(comment: comment, input: input))
        }
        fallbacks[id] = id
    }

    private static func mapTargets(_ input: AppKitDiffReviewRowInput, to rowID: String, into fallbacks: inout [String: String]) {
        for item in input.inlineFeedback {
            fallbacks[AppKitDiffReviewRowID.inlineFeedback(.targetID(feedbackID: item.id, fileID: input.file.id))] = rowID
        }
        for comment in input.draftComments {
            fallbacks[AppKitDiffReviewRowID.draftComment(.targetID(commentID: comment.id, fileID: input.file.id))] = rowID
        }
    }

    private static func mapTargetsDirectly(_ input: AppKitDiffReviewRowInput, into fallbacks: inout [String: String]) {
        for item in input.inlineFeedback {
            let id = AppKitDiffReviewRowID.inlineFeedback(.targetID(feedbackID: item.id, fileID: input.file.id))
            fallbacks[id] = id
        }
        for comment in input.draftComments {
            let id = AppKitDiffReviewRowID.draftComment(.targetID(commentID: comment.id, fileID: input.file.id))
            fallbacks[id] = id
        }
    }

    private static func append(
        _ rows: inout [AppKitDiffRowSpec], id: String, input: AppKitDiffReviewRowInput,
        signature: Int, height: CGFloat, retention: AppKitDiffRowRetention = .recyclable,
        inlineAvailability: DiffReviewInlineFeedbackActionAvailability? = nil,
        draftAvailability: ReviewDraftCommentActionAvailability? = nil,
        reviewFeedbackTarget: ReviewFeedbackTarget? = nil,
        includesActiveHighlight: Bool = false,
        build: @escaping () -> AnyView
    ) {
        let token = AppKitDiffReviewRowToken(
            rowID: id, contentSignature: signature, layoutMode: input.layoutMode,
            wrapLines: input.wrapLines, showWhitespace: input.showWhitespace,
            codeFontFamily: input.codeFontFamily, codeFontSize: input.codeFontSize,
            theme: input.theme,
            lspWorktreeID: input.lspContext?.worktreeId,
            lspRelativePath: input.lspContext?.relativePath,
            lspLanguage: input.lspContext?.language,
            lspManagerIdentity: input.lspContext.map { ObjectIdentifier($0.lsp) },
            inlineFeedbackAvailability: inlineAvailability, draftCommentAvailability: draftAvailability,
            reviewFeedbackTarget: reviewFeedbackTarget,
            hoveredInlineFeedbackID: includesActiveHighlight ? input.state.hoveredInlineFeedbackID : nil,
            hoveredDraftCommentID: includesActiveHighlight ? input.state.hoveredDraftCommentID : nil,
            focusedFeedbackID: input.focusedFeedbackID,
            focusedDraftCommentID: input.focusedDraftCommentID,
            activeThreadID: input.state.activeThreadID,
            draftComposerFocused: input.state.isDraftComposerFocused,
            actionPresence: input.actionPresence
        )
        rows.append(.init(id: id, ownerID: input.file.id.rawValue, equalityToken: .init(token), estimatedHeight: height, retention: retention, build: build))
    }

    private static func headerSignature(_ input: AppKitDiffReviewRowInput) -> Int {
        var hasher = Hasher()
        hasher.combine(input.file.id)
        hasher.combine(input.file.summary.path)
        hasher.combine(input.file.summary.originalPath)
        hasher.combine(input.file.summary.status)
        hasher.combine(input.file.summary.additions)
        hasher.combine(input.file.summary.deletions)
        return hasher.finalize()
    }

    private static func placeholderSignature(_ input: AppKitDiffReviewRowInput, deferred: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(input.file.placeholderMessage)
        hasher.combine(input.file.summary.additions)
        hasher.combine(input.file.summary.deletions)
        hasher.combine(input.inlineFeedback.count + input.draftComments.count + input.threads.count)
        hasher.combine(deferred)
        return hasher.finalize()
    }

    private static func segmentHeight(_ rowCount: Int, input: AppKitDiffReviewRowInput) -> CGFloat {
        max(22, CGFloat(rowCount) * max(18, input.codeFontSize + 6))
    }
}

struct AppKitDiffReviewHeaderRowBody: View {
    let input: AppKitDiffReviewRowInput

    var body: some View {
        HStack(spacing: 10) {
            Text(input.file.summary.status.glyph)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(statusColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(input.file.summary.path)
                    .font(CenterTypography.codeFont(family: input.codeFontFamily, size: input.codeFontSize))
                    .foregroundColor(input.theme.color("fg"))
                    .lineLimit(1).truncationMode(.middle)
                if let originalPath = input.file.summary.originalPath {
                    Text("from \(originalPath)").font(.system(size: 10.5)).foregroundColor(input.theme.color("fg-faint"))
                }
            }
            if input.showsSourceBadge, let title = input.file.summary.groupTitle {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(sourceColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(sourceColor.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .background(DiffReviewAccessibilityMarker(
                        identifier: "diff-review-source-badge-\(input.file.id.rawValue)",
                        label: title.uppercased()
                    ))
            }
            Spacer(minLength: 12)
            if shouldShowChangeSummary(
                additions: input.file.summary.additions,
                deletions: input.file.summary.deletions
            ) {
                HStack(spacing: 9) {
                    Text("+\(input.file.summary.additions)").foregroundColor(input.theme.color("add"))
                    Text("-\(input.file.summary.deletions)").foregroundColor(input.theme.color("del"))
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            if let pair = displayedImagePair {
                ImageDiffControls(pair: pair, state: input.state.imageState.presentation)
                    .background(DiffReviewAccessibilityMarker(
                        identifier: "diff-review-image-header-\(input.file.id.rawValue)",
                        label: "Image diff controls"
                    ))
            }
            if input.file.openFile != nil,
               let title = DiffReviewFileSectionActions.openFileButtonTitle(for: input.file) {
                Button(action: input.state.actionRelay.openCurrentFile) {
                    Text(title).font(.system(size: 11, weight: .semibold))
                        .foregroundColor(input.theme.color("fg-muted"))
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(input.theme.color("bg-3"))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).help(title)
                .accessibilityIdentifier("diff-review-open-file-\(input.file.id.rawValue)")
                .accessibilityLabel(title)
            }
            if input.file.stagedMutationActions?.unstageFile != nil {
                Button("Unstage", action: input.state.actionRelay.unstageFile)
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                    .foregroundColor(input.theme.color("fg-muted"))
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(input.theme.color("bg-3"))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("diff-review-unstage-file-\(input.file.id.rawValue)")
                    .background(ReviewDraftCommentActionPressMarker(
                        identifier: "diff-review-unstage-file-\(input.file.id.rawValue)",
                        label: "Unstage \(input.file.summary.path)"
                    ) {
                        input.state.actionRelay.unstageFile()
                    })
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(input.theme.color("bg-2"))
        .overlay(Rectangle().fill(input.theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }

    private var displayedImagePair: ImageDiffPair? {
        input.state.imageState.pair
            ?? input.file.imageProvider.flatMap { DiffReviewImagePairCache.shared.pair(for: $0.id) }
    }

    private var sourceColor: Color {
        switch input.file.summary.groupID ?? input.file.summary.namespace {
        case "unstaged": input.theme.color("warn")
        case "staged": input.theme.color("info")
        default: input.theme.color("accent")
        }
    }

    private var statusColor: Color {
        switch input.file.summary.status {
        case .added: input.theme.color("add")
        case .deleted: input.theme.color("del")
        case .renamed, .copied: input.theme.color("accent")
        case .conflicted: input.theme.color("warn")
        case .modified, .unknown: input.theme.color("fg-dim")
        }
    }
}

struct AppKitDiffReviewPlaceholderRowBody: View {
    let input: AppKitDiffReviewRowInput
    let isDeferred: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let title = isDeferred
                ? (input.automaticallyRendersDiff ? "Large diff hidden for performance" : "Large review diff deferred for performance")
                : (input.file.placeholderMessage ?? "This file cannot be rendered in the review view.")
            Text(title)
                .font(.system(size: 12, weight: isDeferred ? .semibold : .regular))
                .foregroundColor(isDeferred ? input.theme.color("fg") : input.theme.color("fg-dim"))
            if isDeferred {
                Text("\((input.file.summary.additions + input.file.summary.deletions).formatted()) changed lines. Rendering may be slow.")
                    .font(.system(size: 12)).foregroundColor(input.theme.color("fg-dim"))
                let hiddenItems = input.inlineFeedback.count + input.draftComments.count + input.threads.count
                if hiddenItems > 0 {
                    Text("^[\(hiddenItems) comment](inflect: true) hidden — show the full diff to view.")
                        .font(.system(size: 12)).foregroundColor(input.theme.color("fg-dim"))
                        .accessibilityIdentifier("diff-review-render-budget-hidden-comments-\(input.file.id.rawValue)")
                }
                Button {
                    input.state.showFullDiffOverride = true
                } label: {
                    Text("Show full diff").font(.system(size: 11, weight: .semibold))
                        .foregroundColor(input.theme.color("fg-muted"))
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(input.theme.color("bg-3"))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("diff-review-show-full-diff-\(input.file.id.rawValue)")
                .background(ReviewDraftCommentActionPressMarker(
                    identifier: "diff-review-show-full-diff-\(input.file.id.rawValue)",
                    label: "Show full diff"
                ) {
                    input.state.showFullDiffOverride = true
                })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 18).background(input.theme.color("bg-1"))
        .background(DiffReviewAccessibilityMarker(
            identifier: isDeferred
                ? "diff-review-render-budget-\(input.file.id.rawValue)"
                : "diff-review-placeholder-\(input.file.id.rawValue)",
            label: isDeferred ? "Large review diff deferred for performance" : (input.file.placeholderMessage ?? "This file cannot be rendered in the review view.")
        ))
    }
}

struct AppKitDiffReviewImageRowBody: View {
    let input: AppKitDiffReviewRowInput
    var loadsImage = false

    var body: some View {
        Group {
            if input.state.imageState.isLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(DiffReviewAccessibilityMarker(
                        identifier: "diff-review-image-loading-\(input.file.id.rawValue)",
                        label: "Loading image diff"
                    ))
            }
            if let pair = input.state.imageState.pair ?? input.file.imageProvider.flatMap({ DiffReviewImagePairCache.shared.pair(for: $0.id) }) {
                ImageDiffComparisonContent(pair: pair, state: input.state.imageState.presentation, boundedHeight: 360)
                if let message = failureMessage(in: pair) {
                    HStack(spacing: 10) {
                        Text(message).font(.system(size: 11)).foregroundColor(input.theme.color("warn"))
                        Spacer()
                        Button("Retry") { Task { await input.state.imageState.retry() } }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                            .foregroundColor(input.theme.color("fg-muted"))
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(input.theme.color("bg-3"))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .accessibilityIdentifier("diff-review-image-retry-\(input.file.id.rawValue)")
                            .background(ReviewDraftCommentActionPressMarker(
                                identifier: "diff-review-image-retry-\(input.file.id.rawValue)",
                                label: "Retry image diff"
                            ) {
                                Task { await input.state.imageState.retry() }
                            })
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(DiffReviewAccessibilityMarker(
                        identifier: "diff-review-image-failure-\(input.file.id.rawValue)", label: message
                    ))
                }
            }
        }
        .background(input.theme.color("bg-1"))
        .task(id: input.file.imageProvider?.id) {
            guard loadsImage else { return }
            guard let provider = input.file.imageProvider else {
                input.state.imageState.clear()
                return
            }
            await input.state.imageState.load(provider: provider)
        }
    }

    private func failureMessage(in pair: ImageDiffPair) -> String? {
        switch (pair.before, pair.after) {
        case (.failed(let failure), _), (_, .failed(let failure)): failure.message
        default: nil
        }
    }
}

struct DiffReviewContextErrorRowBody: View {
    let fileID: DiffReviewFileID
    let message: String
    let theme: Theme

    var body: some View {
        Text("Could not load surrounding context: \(message)")
            .font(.system(size: 11))
            .foregroundColor(theme.color("warn"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(theme.color("bg-2"))
            .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
            .background(DiffReviewAccessibilityMarker(
                identifier: "diff-review-context-error-\(fileID.rawValue)",
                label: "Could not load surrounding context: \(message)"
            ))
    }
}

struct AppKitDiffReviewImageThreadRowBody: View {
    let thread: DiffInlineCommentThread
    let input: AppKitDiffReviewRowInput

    var body: some View {
        DiffInlineCommentCard(
            thread: thread,
            onReply: { input.state.actionRelay.reply(to: thread, body: $0) },
            onStageReply: { input.state.actionRelay.stageReply(to: thread, body: $0) },
            onResolve: { input.state.actionRelay.resolve(thread) },
            onUnresolve: { input.state.actionRelay.unresolve(thread) },
            onEdit: { input.state.actionRelay.edit($0, in: thread, body: $1) },
            onDelete: { input.state.actionRelay.delete($0, in: thread) },
            canReply: input.actionPresence.canReply && thread.viewerCanReply,
            canResolve: input.actionPresence.canResolve && (thread.viewerCanResolve || thread.viewerCanUnresolve),
            canAddToReview: input.actionPresence.canAddToReview,
            onActiveChange: { active in
                input.state.activeThreadID = active
                    ? thread.id
                    : (input.state.activeThreadID == thread.id ? nil : input.state.activeThreadID)
            }
        )
        .background(DiffReviewAccessibilityMarker(
            identifier: "diff-review-image-thread-\(thread.id)",
            label: "Image review thread"
        ))
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(input.theme.color("bg-1"))
    }
}

struct AppKitDiffReviewImageAnnotationRowBody: View {
    let annotation: DiffInlineAnnotation
    let input: AppKitDiffReviewRowInput

    var body: some View {
        DiffInlineAnnotationCard(annotation: annotation)
            .background(DiffReviewAccessibilityMarker(
                identifier: "diff-review-image-annotation-\(annotation.id)",
                label: annotation.message
            ))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(input.theme.color("bg-1"))
    }
}

struct AppKitDiffReviewInlineFeedbackRowBody: View {
    let item: DiffReviewInlineFeedback
    let input: AppKitDiffReviewRowInput
    var rows: [DiffDisplayRow]? = nil

    @ViewBuilder
    var body: some View {
        if let rows {
            DiffFeedbackLaneView(
                lane: DiffFeedbackLaneResolver.lane(for: item),
                layoutMode: input.layoutMode,
                rows: rows
            ) {
                card.padding(.horizontal, 14)
            }
            .padding(.vertical, 10).background(input.theme.color("bg-1"))
            .overlay(Rectangle().fill(input.theme.color("line")).frame(height: 0.5), alignment: .bottom)
        } else {
            card.padding(.horizontal, 14).padding(.vertical, 10).background(input.theme.color("bg-1"))
                .overlay(Rectangle().fill(input.theme.color("line")).frame(height: 0.5), alignment: .bottom)
        }
    }

    private var card: some View {
        DiffReviewInlineFeedbackCard(
            item: item, file: input.file.summary, isFocused: item.id == input.focusedFeedbackID,
            actions: input.state.actionRelay.inlineFeedbackActionsForRow,
            onSelect: input.state.actionRelay.selectInlineFeedback,
            onHoverChange: { hovering in
                input.state.hoveredInlineFeedbackID = hovering
                    ? item.id
                    : (input.state.hoveredInlineFeedbackID == item.id ? nil : input.state.hoveredInlineFeedbackID)
            },
            onEditorActiveChange: { active in
                input.state.activeInlineFeedbackEditorID = active
                    ? item.id
                    : (input.state.activeInlineFeedbackEditorID == item.id ? nil : input.state.activeInlineFeedbackEditorID)
            }
        )
        .id(DiffReviewInlineFeedbackTargetID.targetID(feedbackID: item.id, fileID: input.file.id))
    }
}

struct AppKitDiffReviewDraftCommentRowBody: View {
    let comment: ReviewDraftComment
    let input: AppKitDiffReviewRowInput
    var rows: [DiffDisplayRow]? = nil

    @ViewBuilder
    var body: some View {
        if let rows {
            DiffFeedbackLaneView(
                lane: DiffFeedbackLaneResolver.lane(for: comment),
                layoutMode: input.layoutMode,
                rows: rows
            ) {
                card.padding(.horizontal, 14)
            }
            .padding(.vertical, 10).background(input.theme.color("bg-1"))
            .overlay(Rectangle().fill(input.theme.color("line")).frame(height: 0.5), alignment: .bottom)
        } else {
            card.padding(.horizontal, 14).padding(.vertical, 10).background(input.theme.color("bg-1"))
                .overlay(Rectangle().fill(input.theme.color("line")).frame(height: 0.5), alignment: .bottom)
        }
    }

    private var card: some View {
        ReviewDraftCommentCard(
            comment: comment, file: input.file.summary,
            isFocused: comment.id == input.focusedDraftCommentID,
            actions: input.draftCommentActions ?? input.state.actionRelay.draftCommentActionsForRow,
            reviewFeedbackTarget: input.reviewFeedbackTarget ?? .init(
                title: input.file.summary.path, repositoryPath: nil,
                providerDescription: nil, sourceDescription: "Local draft comment"
            ),
            onSelect: input.state.actionRelay.selectDraftComment,
            onHoverChange: { hovering in
                input.state.hoveredDraftCommentID = hovering
                    ? comment.id
                    : (input.state.hoveredDraftCommentID == comment.id ? nil : input.state.hoveredDraftCommentID)
            },
            onEditorActiveChange: { active in
                input.state.activeDraftCommentEditorID = active
                    ? comment.id
                    : (input.state.activeDraftCommentEditorID == comment.id ? nil : input.state.activeDraftCommentEditorID)
            }
        )
        .id(DiffReviewDraftCommentTargetID.targetID(commentID: comment.id, fileID: input.file.id))
    }
}

struct AppKitDiffReviewGroupHeaderRowBody: View {
    let group: DiffDisplayGroup
    let input: AppKitDiffReviewRowInput

    var body: some View {
        HStack(spacing: 8) {
            Text(group.header)
                .font(CenterTypography.codeFont(family: input.codeFontFamily, size: input.codeFontSize - 1))
                .foregroundColor(input.theme.color("fg-muted")).lineLimit(1)
            Spacer(minLength: 12)
            if !DiffCollapsedContextController.collapsedRowIDs(in: group).isEmpty {
                let expanded = DiffCollapsedContextController.isExpanded(
                    group, expandedIDs: input.state.expandedCollapsedRowIDs
                )
                Button {
                    input.state.expandedCollapsedRowIDs = DiffCollapsedContextController.toggled(
                        group, expandedIDs: input.state.expandedCollapsedRowIDs
                    )
                } label: {
                    Image(systemName: expanded ? "minus.square" : "plus.square")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(input.theme.color("fg-muted"))
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain).help(expanded ? "Collapse context" : "Expand context")
                .accessibilityIdentifier("diff-review-context-toggle-\(input.file.id.rawValue)-\(group.id)")
                .overlay(ReviewDraftCommentActionPressMarker(
                    identifier: "diff-review-context-toggle-\(input.file.id.rawValue)-\(group.id)",
                    label: expanded ? "Collapse context" : "Expand context"
                ) {
                    input.state.expandedCollapsedRowIDs = DiffCollapsedContextController.toggled(
                        group, expandedIDs: input.state.expandedCollapsedRowIDs
                    )
                })
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 8).background(input.theme.color("bg-2"))
        .overlay(Rectangle().fill(input.theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }
}

struct AppKitDiffReviewSegmentRowBody: View {
    let rows: [DiffDisplayRow]
    let rowsSignature: DiffDisplayRowsSignature
    let group: DiffDisplayGroup
    let input: AppKitDiffReviewRowInput

    var body: some View {
        DiffPaneTextDocumentView(
            group: .init(id: group.id, header: group.header, sourceHunk: group.sourceHunk, rows: rows, rowsSignature: rowsSignature),
            expandedCollapsedRowIDs: input.state.expandedCollapsedRowIDs,
            layoutMode: input.layoutMode, wrapLines: input.wrapLines, showWhitespace: input.showWhitespace,
            fileExtension: LanguageRegistry.highlighterExtension(forPath: input.file.summary.path),
            codeFontFamily: input.codeFontFamily, codeFontSize: input.codeFontSize, theme: input.theme,
            lspContext: input.lspContext,
            activeCommentHighlight: input.activeHighlight(for: rows),
            allowsReviewLineSelection: input.allowsDraftCommentCreation,
            onReviewLineSelected: input.beginPendingDraft,
            onContextExpansion: input.loadContextAndExpand
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct AppKitDiffReviewThreadRowBody: View {
    let thread: DiffInlineCommentThread
    let rows: [DiffDisplayRow]
    let input: AppKitDiffReviewRowInput

    var body: some View {
        DiffFeedbackLaneView(lane: DiffFeedbackLaneResolver.lane(for: thread), layoutMode: input.layoutMode, rows: rows) {
            DiffInlineCommentCard(
                thread: thread, onReply: { input.state.actionRelay.reply(to: thread, body: $0) },
                onStageReply: { input.state.actionRelay.stageReply(to: thread, body: $0) },
                onResolve: { input.state.actionRelay.resolve(thread) }, onUnresolve: { input.state.actionRelay.unresolve(thread) },
                onEdit: { input.state.actionRelay.edit($0, in: thread, body: $1) },
                onDelete: { input.state.actionRelay.delete($0, in: thread) },
                canReply: input.actionPresence.canReply && thread.viewerCanReply,
                canResolve: input.actionPresence.canResolve && (thread.viewerCanResolve || thread.viewerCanUnresolve),
                canAddToReview: input.actionPresence.canAddToReview,
                onActiveChange: { active in
                    input.state.activeThreadID = active
                        ? thread.id
                        : (input.state.activeThreadID == thread.id ? nil : input.state.activeThreadID)
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AppKitDiffReviewAnnotationRowBody: View {
    let annotation: DiffInlineAnnotation
    let rows: [DiffDisplayRow]
    let input: AppKitDiffReviewRowInput

    var body: some View {
        DiffFeedbackLaneView(lane: DiffFeedbackLaneResolver.lane(for: annotation), layoutMode: input.layoutMode, rows: rows) {
            DiffInlineAnnotationCard(annotation: annotation).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AppKitDiffReviewComposerRowBody: View {
    let rows: [DiffDisplayRow]
    let input: AppKitDiffReviewRowInput
    @FocusState private var isFocused: Bool

    var body: some View {
        DiffFeedbackLaneView(lane: input.state.pendingDraftAnchor.map(DiffFeedbackLaneResolver.lane) ?? .full, layoutMode: input.layoutMode, rows: rows) {
            VStack(alignment: .leading, spacing: 10) {
                ReviewDraftComposerTextEditor(
                    text: Binding(
                        get: { input.state.pendingDraftBody },
                        set: { input.state.pendingDraftBody = $0 }
                    ),
                    theme: input.theme,
                    isFocused: $isFocused,
                    focusRequestGeneration: input.state.draftComposerFocusRequestGeneration,
                    onSave: input.savePendingDraft,
                    onCancel: input.clearPendingDraft
                )
                    .frame(minHeight: 76, maxHeight: 104)
                    .background {
                        if input.state.isDraftComposerFocused {
                            DiffReviewAccessibilityMarker(
                                identifier: "diff-review-draft-composer-focused",
                                label: "Draft comment composer focused"
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(input.theme.color("accent").opacity(0.65), lineWidth: 0.75))
                    .accessibilityIdentifier("diff-review-draft-composer")
                HStack {
                    Spacer()
                    Button("Cancel", action: input.clearPendingDraft)
                        .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                        .foregroundColor(input.theme.color("fg-muted"))
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(input.theme.color("bg-3"))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .accessibilityIdentifier("diff-review-draft-composer-cancel")
                    Button("Save", action: input.savePendingDraft)
                        .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                        .foregroundColor(input.theme.color("bg-1"))
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(input.theme.color("accent"))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .accessibilityIdentifier("diff-review-draft-composer-save")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12).background(input.theme.color("bg-1"))
            .overlay(Rectangle().fill(input.theme.color("line")).frame(height: 0.5), alignment: .bottom)
            .background(DiffReviewAccessibilityMarker(
                identifier: "diff-review-draft-composer-marker", label: "Draft comment composer"
            ))
            .onChange(of: isFocused) { _, focused in input.state.isDraftComposerFocused = focused }
            .onChange(of: input.state.isDraftComposerFocused) { _, focused in isFocused = focused }
            .onAppear { isFocused = input.state.isDraftComposerFocused }
        }
    }
}
