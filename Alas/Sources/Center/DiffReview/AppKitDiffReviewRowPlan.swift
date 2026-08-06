import SwiftUI

enum AppKitDiffReviewRowID {
    static func header(fileID: DiffReviewFileID) -> String { "file:\(fileID.rawValue):header" }
    static func placeholder(fileID: DiffReviewFileID) -> String { "file:\(fileID.rawValue):placeholder" }
    static func image(fileID: DiffReviewFileID) -> String { "file:\(fileID.rawValue):image" }
    static func groupHeader(fileID: DiffReviewFileID, groupID: String) -> String { "file:\(fileID.rawValue):group:\(groupID):header" }
    static func segment(fileID: DiffReviewFileID, segmentID: String, blockID: String) -> String { "file:\(fileID.rawValue):segment:\(segmentID):rows:\(blockID)" }
    static func composer(fileID: DiffReviewFileID, segmentID: String) -> String { "file:\(fileID.rawValue):composer:\(segmentID)" }
    static func spacing(fileID: DiffReviewFileID) -> String { "file:\(fileID.rawValue):spacing" }

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
}

struct AppKitDiffReviewRowToken: Equatable {
    let rowID: String
    let contentSignature: Int
    let layoutMode: DiffLayoutMode
    let wrapLines: Bool
    let showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let inlineFeedbackAvailability: DiffReviewInlineFeedbackActionAvailability?
    let draftCommentAvailability: ReviewDraftCommentActionAvailability?
    let hoveredInlineFeedbackID: String?
    let hoveredDraftCommentID: String?
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
    var automaticallyRendersDiff = true
    var showsBottomSpacing = true
    var focusedFeedbackID: String?
    var focusedDraftCommentID: String?
    var allowsDraftCommentCreation = true
    var actionPresence = AppKitDiffReviewActionPresence()

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
        automaticallyRendersDiff: Bool = true,
        showsBottomSpacing: Bool = true,
        focusedFeedbackID: String? = nil,
        focusedDraftCommentID: String? = nil,
        allowsDraftCommentCreation: Bool = true,
        actionPresence: AppKitDiffReviewActionPresence = .init()
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
        self.automaticallyRendersDiff = automaticallyRendersDiff
        self.showsBottomSpacing = showsBottomSpacing
        self.focusedFeedbackID = focusedFeedbackID
        self.focusedDraftCommentID = focusedDraftCommentID
        self.allowsDraftCommentCreation = allowsDraftCommentCreation
        self.actionPresence = actionPresence
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
            let fileID = input.file.id
            let headerID = AppKitDiffReviewRowID.header(fileID: fileID)
            headerByFileID[fileID] = headerID
            append(&rows, id: headerID, input: input, signature: headerSignature(input), height: 45) {
                AnyView(AppKitDiffReviewHeaderRowBody(input: input))
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
                let imageID = AppKitDiffReviewRowID.image(fileID: fileID)
                append(&rows, id: imageID, input: input, signature: input.file.imageProvider?.id.hashValue ?? 0, height: 360) {
                    AnyView(AppKitDiffReviewImageRowBody(input: input))
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
        for item in feedback { appendFeedback(item, input: input, rows: &rows, fallbacks: &fallbacks) }
    }

    private static func appendTextRows(
        _ context: DiffReviewRenderContext,
        input: AppKitDiffReviewRowInput,
        into rows: inout [AppKitDiffRowSpec],
        fallbacks: inout [String: String]
    ) {
        let fusions = DiffReviewHunkFusionResolver.states(for: context.groups)
        for (groupIndex, group) in context.groups.enumerated() {
            for item in group.inlineFeedback { appendFeedback(item, input: input, rows: &rows, fallbacks: &fallbacks) }
            let groupID = AppKitDiffReviewRowID.groupHeader(fileID: input.file.id, groupID: group.id)
            if !group.containsLocalAccessories {
                let rowInput = hunkInput(group: group, context: context, input: input, fusion: fusions[groupIndex])
                let hunkPlan = DiffPaneRowPlanBuilder.build(input: rowInput, state: input.state.hunkPresentationState)
                guard let hunk = hunkPlan.rows.first else { continue }
                append(&rows, id: groupID, input: input, signature: String(reflecting: group.displayGroup.rowsSignature).hashValue, height: hunk.estimatedHeight) {
                    hunk.build()
                }
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
                        append(&rows, id: blockID, input: input, signature: String(reflecting: rowBlock.rowsSignature).hashValue, height: segmentHeight(rowBlock.rows.count, input: input)) {
                            AnyView(AppKitDiffReviewSegmentRowBody(rows: rowBlock.rows, rowsSignature: rowBlock.rowsSignature, group: group.displayGroup, input: input))
                        }
                    case let .thread(thread):
                        let threadID = AppKitDiffReviewRowID.thread(fileID: input.file.id, threadID: thread.id)
                        append(&rows, id: threadID, input: input, signature: String(reflecting: thread).hashValue, height: 112) {
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
                    append(&rows, id: composerID, input: input, signature: input.state.draftComposerFocusRequestGeneration, height: 132, retention: .pinned) {
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
            allowsReviewLineSelection: input.allowsDraftCommentCreation,
            onReviewLineSelected: { anchor in
                input.state.pendingDraftAnchor = anchor
                input.state.draftComposerFocusRequestGeneration &+= 1
            },
            onContextExpansion: { _, _, _ in input.state.actionRelay.contextExpansionActivated() },
            threads: input.threads, annotations: input.annotations,
            onReply: { input.state.actionRelay.reply(to: $0, body: $1) },
            onResolve: input.state.actionRelay.resolve,
            onUnresolve: input.state.actionRelay.unresolve,
            onEdit: { input.state.actionRelay.edit($1, in: $0, body: $2) },
            onDelete: { input.state.actionRelay.delete($1, in: $0) },
            canReply: input.actionPresence.canReply, canResolve: input.actionPresence.canResolve,
            onStageReply: { input.state.actionRelay.stageReply(to: $0, body: $1) },
            canAddToReview: input.actionPresence.canAddToReview,
            hunkFusionStates: [fusion], hunkActions: { _ in .init() }
        )
    }

    private static func appendFeedback(
        _ item: DiffReviewInlineFeedback,
        input: AppKitDiffReviewRowInput,
        rows: inout [AppKitDiffRowSpec],
        fallbacks: inout [String: String]
    ) {
        let target = DiffReviewInlineFeedbackTargetID.targetID(feedbackID: item.id, fileID: input.file.id)
        let id = AppKitDiffReviewRowID.inlineFeedback(target)
        append(&rows, id: id, input: input, signature: String(reflecting: item).hashValue, height: 96, inlineAvailability: input.state.actionRelay.inlineFeedbackAvailability(for: item, file: input.file.summary)) {
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
        append(&rows, id: id, input: input, signature: String(reflecting: comment).hashValue, height: 112, draftAvailability: input.state.actionRelay.draftCommentAvailability(for: comment)) {
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
        build: @escaping () -> AnyView
    ) {
        let token = AppKitDiffReviewRowToken(
            rowID: id, contentSignature: signature, layoutMode: input.layoutMode,
            wrapLines: input.wrapLines, showWhitespace: input.showWhitespace,
            codeFontFamily: input.codeFontFamily, codeFontSize: input.codeFontSize,
            inlineFeedbackAvailability: inlineAvailability, draftCommentAvailability: draftAvailability,
            hoveredInlineFeedbackID: input.state.hoveredInlineFeedbackID,
            hoveredDraftCommentID: input.state.hoveredDraftCommentID,
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

private struct AppKitDiffReviewHeaderRowBody: View {
    let input: AppKitDiffReviewRowInput

    var body: some View {
        HStack(spacing: 10) {
            Text(input.file.summary.status.glyph)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(input.theme.color("fg-muted"))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(input.file.summary.path)
                    .font(CenterTypography.codeFont(family: input.codeFontFamily, size: input.codeFontSize))
                    .lineLimit(1).truncationMode(.middle)
                if let originalPath = input.file.summary.originalPath {
                    Text("from \(originalPath)").font(.system(size: 10.5)).foregroundColor(input.theme.color("fg-faint"))
                }
            }
            Spacer(minLength: 12)
            Text("+\(input.file.summary.additions)  -\(input.file.summary.deletions)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(input.theme.color("bg-2"))
        .overlay(Rectangle().fill(input.theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }
}

private struct AppKitDiffReviewPlaceholderRowBody: View {
    let input: AppKitDiffReviewRowInput
    let isDeferred: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isDeferred ? "Large review diff deferred for performance" : (input.file.placeholderMessage ?? "This file cannot be rendered in the review view."))
                .font(.system(size: 12, weight: isDeferred ? .semibold : .regular))
            if isDeferred {
                Text("\((input.file.summary.additions + input.file.summary.deletions).formatted()) changed lines. Rendering may be slow.")
                    .font(.system(size: 12)).foregroundColor(input.theme.color("fg-dim"))
                Button("Show full diff") { input.state.showFullDiffOverride = true }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 18).background(input.theme.color("bg-1"))
    }
}

private struct AppKitDiffReviewImageRowBody: View {
    let input: AppKitDiffReviewRowInput

    var body: some View {
        Group {
            if let pair = input.state.imageState.pair ?? input.file.imageProvider.flatMap({ DiffReviewImagePairCache.shared.pair(for: $0.id) }) {
                ImageDiffComparisonContent(pair: pair, state: input.state.imageState.presentation, boundedHeight: 360)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
        }
        .background(input.theme.color("bg-1"))
    }
}

private struct AppKitDiffReviewInlineFeedbackRowBody: View {
    let item: DiffReviewInlineFeedback
    let input: AppKitDiffReviewRowInput

    var body: some View {
        DiffReviewInlineFeedbackCard(
            item: item, file: input.file.summary, isFocused: item.id == input.focusedFeedbackID,
            actions: input.state.actionRelay.inlineFeedbackActionsForRow,
            onSelect: input.state.actionRelay.selectInlineFeedback,
            onHoverChange: { hovering in input.state.hoveredInlineFeedbackID = hovering ? item.id : nil }
        )
        .padding(.horizontal, 14).padding(.vertical, 10).background(input.theme.color("bg-1"))
    }
}

private struct AppKitDiffReviewDraftCommentRowBody: View {
    let comment: ReviewDraftComment
    let input: AppKitDiffReviewRowInput

    var body: some View {
        ReviewDraftCommentCard(
            comment: comment, file: input.file.summary,
            isFocused: comment.id == input.focusedDraftCommentID,
            actions: input.state.actionRelay.draftCommentActionsForRow,
            reviewFeedbackTarget: .init(title: input.file.summary.path, repositoryPath: nil, providerDescription: nil, sourceDescription: "Local draft comment"),
            onSelect: input.state.actionRelay.selectDraftComment,
            onHoverChange: { hovering in input.state.hoveredDraftCommentID = hovering ? comment.id : nil }
        )
        .padding(.horizontal, 14).padding(.vertical, 10).background(input.theme.color("bg-1"))
    }
}

private struct AppKitDiffReviewGroupHeaderRowBody: View {
    let group: DiffDisplayGroup
    let input: AppKitDiffReviewRowInput

    var body: some View {
        HStack(spacing: 8) {
            Text(group.header).font(CenterTypography.codeFont(family: input.codeFontFamily, size: input.codeFontSize - 1)).lineLimit(1)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 13).padding(.vertical, 8).background(input.theme.color("bg-2"))
        .overlay(Rectangle().fill(input.theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }
}

private struct AppKitDiffReviewSegmentRowBody: View {
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
            lspContext: nil,
            allowsReviewLineSelection: input.allowsDraftCommentCreation,
            onReviewLineSelected: { anchor in input.state.pendingDraftAnchor = anchor },
            onContextExpansion: { _, _, _ in input.state.actionRelay.contextExpansionActivated() }
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AppKitDiffReviewThreadRowBody: View {
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
                onActiveChange: { input.state.activeThreadID = $0 ? thread.id : nil }
            )
        }
    }
}

private struct AppKitDiffReviewAnnotationRowBody: View {
    let annotation: DiffInlineAnnotation
    let rows: [DiffDisplayRow]
    let input: AppKitDiffReviewRowInput

    var body: some View {
        DiffFeedbackLaneView(lane: DiffFeedbackLaneResolver.lane(for: annotation), layoutMode: input.layoutMode, rows: rows) {
            DiffInlineAnnotationCard(annotation: annotation)
        }
    }
}

private struct AppKitDiffReviewComposerRowBody: View {
    let rows: [DiffDisplayRow]
    let input: AppKitDiffReviewRowInput

    var body: some View {
        DiffFeedbackLaneView(lane: input.state.pendingDraftAnchor.map(DiffFeedbackLaneResolver.lane) ?? .full, layoutMode: input.layoutMode, rows: rows) {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: Binding(get: { input.state.pendingDraftBody }, set: { input.state.pendingDraftBody = $0 }))
                    .frame(minHeight: 76, maxHeight: 104)
                HStack {
                    Spacer()
                    Button("Cancel") { input.state.pendingDraftAnchor = nil; input.state.pendingDraftBody = "" }
                    Button("Save") {
                        guard let anchor = input.state.pendingDraftAnchor else { return }
                        input.state.actionRelay.saveDraftComment(anchor, body: input.state.pendingDraftBody)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12).background(input.theme.color("bg-1"))
        }
    }
}
