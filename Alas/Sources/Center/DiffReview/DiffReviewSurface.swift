import SwiftUI

enum DiffReviewProviderFeedbackResolver {
    static func threads(
        _ threads: [ReviewThread],
        for filePath: String,
        includeFileLevel: Bool
    ) -> [DiffInlineCommentThread] {
        threads
            .filter {
                $0.path == filePath
                    && !$0.isOutdated
                    && (includeFileLevel || !$0.isFileLevel)
            }
            .compactMap { thread in
                let isOldSide: Bool
                if let side = thread.diffSide {
                    isOldSide = side.uppercased() == "LEFT"
                } else {
                    isOldSide = thread.line == nil && thread.originalLine != nil
                }
                guard includeFileLevel || thread.line != nil || thread.originalLine != nil else {
                    return nil
                }
                return DiffInlineCommentThread(
                    id: thread.id,
                    filePath: thread.path ?? "",
                    newLine: thread.line ?? thread.originalLine ?? 1,
                    startLine: thread.rangeStartLine(isOldSide: isOldSide),
                    isOldSide: isOldSide,
                    isResolved: thread.isResolved,
                    isOutdated: thread.isOutdated,
                    comments: thread.comments.map { comment in
                        DiffInlineComment(
                            id: comment.id,
                            author: comment.author ?? "unknown",
                            body: comment.body,
                            viewerCanUpdate: comment.viewerCanUpdate,
                            viewerCanDelete: comment.viewerCanDelete
                        )
                    },
                    viewerCanReply: thread.viewerCanReply,
                    viewerCanResolve: thread.viewerCanResolve,
                    viewerCanUnresolve: thread.viewerCanUnresolve
                )
            }
    }
}

struct DiffReviewSurface: View {
    let session: DiffReviewLoadedSession
    @Binding var selectedFileID: DiffReviewFileID?
    @Binding var railCollapsed: Bool
    @Binding var reviewSummaryCollapsed: Bool
    @Binding var layoutMode: DiffLayoutMode
    @Binding var wrapLines: Bool
    @Binding var showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat
    var showsSourceBadges: Bool = true
    var showsRailDisplayControls: Bool = false
    var showsDraftSummaryRail: Bool = false
    var allowsDraftCommentCreation: Bool = true
    var allowsNonLineDraftCommentCreation: Bool = true
    var lspContextForFile: (DiffReviewFileSectionModel) -> DiffPaneLSPContext? = { _ in nil }
    var inlineFeedbackByFileID: [DiffReviewFileID: [DiffReviewInlineFeedback]] = [:]
    var focusedFeedbackID: String? = nil
    var inlineFeedbackScrollCommand: DiffReviewInlineFeedbackScrollCommand? = nil
    var inlineFeedbackActions = DiffReviewInlineFeedbackActions()
    var onSelectInlineFeedback: (DiffReviewInlineFeedback) -> Void = { _ in }
    var reviewFeedbackTargetOverride: ReviewFeedbackTarget? = nil
    var draftCommentsByFileID: [DiffReviewFileID: [ReviewDraftComment]] = [:]
    var focusedDraftCommentID: String? = nil
    var draftCommentScrollCommand: DiffReviewDraftCommentScrollCommand? = nil
    var draftCommentActions = ReviewDraftCommentActions()
    var onSelectDraftComment: (ReviewDraftComment) -> Void = { _ in }
    var onSaveDraftComment: (DiffReviewFileID, String, String?, ReviewDraftCommentAnchor, String) -> Void = { _, _, _, _, _ in }
    var threads: [ReviewThread] = []
    var onReply: (DiffInlineCommentThread, String) -> Void = { _, _ in }
    var onResolve: (DiffInlineCommentThread) -> Void = { _ in }
    var onUnresolve: (DiffInlineCommentThread) -> Void = { _ in }
    var onEdit: (DiffInlineCommentThread, DiffInlineComment, String) -> Void = { _, _, _ in }
    var onDelete: (DiffInlineCommentThread, DiffInlineComment) -> Void = { _, _ in }
    var annotations: [CheckAnnotation] = []
    var canReply: Bool = false
    var canResolve: Bool = false
    var onStageReply: (DiffInlineCommentThread, String) -> Void = { _, _ in }
    var canAddToReview: Bool = false

    @Environment(\.theme) private var theme
    @State private var programmaticScroll = DiffReviewProgrammaticScrollController()
    @State private var scrollCommandController = DiffReviewScrollCommandController()
    @State private var scrollCommand: DiffReviewScrollCommand?
    @State private var appKitProgrammaticScroll: AppKitDiffReviewProgrammaticScroll?
    @State private var appKitScrollCompletionGate = AppKitDiffReviewScrollCompletionGate()
    @State private var contextExpandedFileIDs: Set<DiffReviewFileID> = []
    @State private var synchronizedFileSetKey: String?
    @StateObject private var appKitPresentationStore = AppKitDiffReviewPresentationStore()
    /// The file the scrollspy last reported as scrolled into view. Used to tell
    /// cross-file comment navigation (file section not yet realized → needs a
    /// two-phase scroll) from same-file navigation (section already realized →
    /// a direct scroll suffices and avoids a detour through the file header).
    @State private var scrollSpyActiveFileID: DiffReviewFileID?

    init(
        session: DiffReviewLoadedSession,
        selectedFileID: Binding<DiffReviewFileID?>,
        railCollapsed: Binding<Bool>,
        reviewSummaryCollapsed: Binding<Bool> = .constant(false),
        layoutMode: Binding<DiffLayoutMode>,
        wrapLines: Binding<Bool>,
        showWhitespace: Binding<Bool>,
        codeFontFamily: String,
        codeFontSize: CGFloat,
        showsSourceBadges: Bool = true,
        showsRailDisplayControls: Bool = false,
        showsDraftSummaryRail: Bool = false,
        allowsDraftCommentCreation: Bool = true,
        allowsNonLineDraftCommentCreation: Bool = true,
        lspContextForFile: @escaping (DiffReviewFileSectionModel) -> DiffPaneLSPContext? = { _ in nil },
        inlineFeedbackByFileID: [DiffReviewFileID: [DiffReviewInlineFeedback]] = [:],
        focusedFeedbackID: String? = nil,
        inlineFeedbackScrollCommand: DiffReviewInlineFeedbackScrollCommand? = nil,
        inlineFeedbackActions: DiffReviewInlineFeedbackActions = DiffReviewInlineFeedbackActions(),
        onSelectInlineFeedback: @escaping (DiffReviewInlineFeedback) -> Void = { _ in },
        reviewFeedbackTarget: ReviewFeedbackTarget? = nil,
        draftCommentsByFileID: [DiffReviewFileID: [ReviewDraftComment]] = [:],
        focusedDraftCommentID: String? = nil,
        draftCommentScrollCommand: DiffReviewDraftCommentScrollCommand? = nil,
        draftCommentActions: ReviewDraftCommentActions = ReviewDraftCommentActions(),
        onSelectDraftComment: @escaping (ReviewDraftComment) -> Void = { _ in },
        onSaveDraftComment: @escaping (DiffReviewFileID, String, String?, ReviewDraftCommentAnchor, String) -> Void = { _, _, _, _, _ in },
        threads: [ReviewThread] = [],
        onReply: @escaping (DiffInlineCommentThread, String) -> Void = { _, _ in },
        onResolve: @escaping (DiffInlineCommentThread) -> Void = { _ in },
        onUnresolve: @escaping (DiffInlineCommentThread) -> Void = { _ in },
        onEdit: @escaping (DiffInlineCommentThread, DiffInlineComment, String) -> Void = { _, _, _ in },
        onDelete: @escaping (DiffInlineCommentThread, DiffInlineComment) -> Void = { _, _ in },
        annotations: [CheckAnnotation] = [],
        canReply: Bool = false,
        canResolve: Bool = false,
        onStageReply: @escaping (DiffInlineCommentThread, String) -> Void = { _, _ in },
        canAddToReview: Bool = false
    ) {
        self.session = session
        self._selectedFileID = selectedFileID
        self._railCollapsed = railCollapsed
        self._reviewSummaryCollapsed = reviewSummaryCollapsed
        self._layoutMode = layoutMode
        self._wrapLines = wrapLines
        self._showWhitespace = showWhitespace
        self.codeFontFamily = codeFontFamily
        self.codeFontSize = codeFontSize
        self.showsSourceBadges = showsSourceBadges
        self.showsRailDisplayControls = showsRailDisplayControls
        self.showsDraftSummaryRail = showsDraftSummaryRail
        self.allowsDraftCommentCreation = allowsDraftCommentCreation
        self.allowsNonLineDraftCommentCreation = allowsDraftCommentCreation && allowsNonLineDraftCommentCreation
        self.lspContextForFile = lspContextForFile
        self.inlineFeedbackByFileID = inlineFeedbackByFileID
        self.focusedFeedbackID = focusedFeedbackID
        self.inlineFeedbackScrollCommand = inlineFeedbackScrollCommand
        self.inlineFeedbackActions = inlineFeedbackActions
        self.onSelectInlineFeedback = onSelectInlineFeedback
        self.reviewFeedbackTargetOverride = reviewFeedbackTarget
        self.draftCommentsByFileID = draftCommentsByFileID
        self.focusedDraftCommentID = focusedDraftCommentID
        self.draftCommentScrollCommand = draftCommentScrollCommand
        self.draftCommentActions = draftCommentActions
        self.onSelectDraftComment = onSelectDraftComment
        self.onSaveDraftComment = onSaveDraftComment
        self.threads = threads
        self.onReply = onReply
        self.onResolve = onResolve
        self.onUnresolve = onUnresolve
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.annotations = annotations
        self.canReply = canReply
        self.canResolve = canResolve
        self.onStageReply = onStageReply
        self.canAddToReview = canAddToReview
    }

    private var fileIDs: [DiffReviewFileID] {
        session.summary.files.map(\.id)
    }

    private var allDraftComments: [ReviewDraftComment] {
        let commentsForSessionFiles = session.summary.files.flatMap { draftCommentsByFileID[$0.id] ?? [] }
        let sessionFileIDs = Set(session.summary.files.map(\.id))
        let orphanComments = draftCommentsByFileID
            .filter { !sessionFileIDs.contains($0.key) }
            .flatMap(\.value)
        return ReviewDraftCommentPlacement.sorted(commentsForSessionFiles + orphanComments)
    }

    private var shouldShowReviewSummaryRail: Bool {
        showsDraftSummaryRail || !allDraftComments.isEmpty
    }

    private var reviewFeedbackBundle: ReviewFeedbackBundle {
        ReviewFeedbackBundle(target: effectiveReviewFeedbackTarget, comments: allDraftComments)
    }

    private var effectiveReviewFeedbackTarget: ReviewFeedbackTarget {
        if let reviewFeedbackTargetOverride {
            return reviewFeedbackTargetOverride
        }
        return ReviewFeedbackTarget(
            title: reviewFeedbackTargetTitle,
            repositoryPath: nil,
            providerDescription: nil,
            sourceDescription: reviewFeedbackSourceDescription
        )
    }

    private var reviewFeedbackTargetTitle: String {
        if session.summary.files.count == 1, let path = session.summary.files.first?.path {
            return path
        }
        return "\(session.summary.fileCount) changed \(session.summary.fileCount == 1 ? "file" : "files")"
    }

    private var reviewFeedbackSourceDescription: String {
        let sources = Set(session.summary.files.map { $0.groupTitle ?? $0.groupID ?? $0.namespace })
        let sortedSources = sources.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return sortedSources.isEmpty ? "Diff review" : sortedSources.joined(separator: ", ")
    }

    private var fileSetKey: String {
        DiffReviewSurfaceSelectionSync.fileSetKey(for: fileIDs)
    }

    var body: some View {
        Group {
            if let firstFileID = session.summary.files.first?.id {
                reviewSurface(firstFileID: firstFileID)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.color("bg-1"))
            }
        }
        .onAppear {
            synchronizeSelectionWithSession()
        }
        .onChange(of: fileSetKey) { _, _ in
            synchronizeSelectionWithSession()
        }
    }

    private func reviewSurface(firstFileID: DiffReviewFileID) -> some View {
        let selectedBinding = Binding<DiffReviewFileID>(
            get: { selectedFileID ?? firstFileID },
            set: { selectedFileID = $0 }
        )

        return HStack(spacing: 0) {
            DiffReviewRail(
                session: session.summary,
                selectedFileID: selectedBinding,
                collapsed: $railCollapsed,
                displayControls: showsRailDisplayControls ? DiffReviewDisplayControlBindings(
                    layoutMode: $layoutMode,
                    wrapLines: $wrapLines,
                    showWhitespace: $showWhitespace
                ) : nil,
                threads: threads,
                onSelectFile: scrollToFile
            )
            appKitMainReviewStream(session)
            if shouldShowReviewSummaryRail {
                ReviewDraftSummaryRail(
                    comments: allDraftComments,
                    bundle: reviewFeedbackBundle,
                    collapsed: $reviewSummaryCollapsed,
                    focusedDraftCommentID: focusedDraftCommentID,
                    draftCommentActions: draftCommentActions,
                    onSelectDraftComment: onSelectDraftComment,
                    inlineFeedbackByFileID: inlineFeedbackByFileID,
                    focusedFeedbackID: focusedFeedbackID,
                    onSelectInlineFeedback: onSelectInlineFeedback
                )
            }
        }
    }

    private func appKitMainReviewStream(_ session: DiffReviewLoadedSession) -> some View {
        AppKitDiffReviewScroller(
            inputs: appKitRowInputs(for: session),
            fileCommand: scrollCommand,
            inlineFeedbackCommand: inlineFeedbackScrollCommand,
            draftCommentCommand: draftCommentScrollCommand,
            onNavigationFile: selectAppKitNavigationFile,
            onActiveFileChange: updateSelectedFileFromAppKitViewport,
            onProgrammaticScrollCompletion: finishAppKitProgrammaticScroll
        )
        .background(theme.color("bg-1"))
    }

    private func appKitRowInputs(for session: DiffReviewLoadedSession) -> [AppKitDiffReviewRowInput] {
        // Computed once per input build: without an override this derives a
        // sorted source description from every file, which is quadratic when
        // evaluated inside the per-file map below.
        let feedbackTarget = effectiveReviewFeedbackTarget
        return session.files.map { file in
            let state = appKitPresentationStore.state(for: file)
            state.synchronize(file: file, contextSignature: DiffReviewContextStateSignature(
                fileID: file.id.rawValue,
                providerID: file.contextProvider?.id.uuidString ?? "no-context-provider",
                structuralHash: file.displayModel?.structuralHash
            ))
            state.synchronizeRenderBudget(resetSignal: file.displayModel?.contentHash)
            state.actionRelay.update(
                inlineFeedbackActions: inlineFeedbackActions,
                onSelectInlineFeedback: onSelectInlineFeedback,
                draftCommentActions: draftCommentActions,
                onSelectDraftComment: onSelectDraftComment,
                onSaveDraftComment: { anchor, body in
                    onSaveDraftComment(file.id, file.summary.path, file.summary.originalPath, anchor, body)
                },
                onContextExpansionActivated: { contextExpandedFileIDs.insert(file.id) },
                onReply: onReply,
                onResolve: onResolve,
                onUnresolve: onUnresolve,
                onEdit: onEdit,
                onDelete: onDelete,
                onStageReply: onStageReply
            )
            let relayDraftActions = state.actionRelay.draftCommentActionsForRow
            let appKitDraftActions = ReviewDraftCommentActions(
                availability: relayDraftActions.availability,
                canPublishReview: relayDraftActions.canPublishReview,
                edit: relayDraftActions.edit,
                delete: relayDraftActions.delete,
                resolve: relayDraftActions.resolve,
                dismiss: relayDraftActions.dismiss,
                copyPrompt: { bundle in
                    relayDraftActions.copyPrompt(bundle)
                    state.copyFeedback.show("Copied prompt")
                },
                publishProvider: relayDraftActions.publishProvider,
                publishReview: relayDraftActions.publishReview,
                agent: relayDraftActions.agent,
                agentTargets: relayDraftActions.agentTargets,
                sendToAgent: relayDraftActions.sendToAgent
            )
            return AppKitDiffReviewRowInput(
                file: file,
                inlineFeedback: inlineFeedbackByFileID[file.id] ?? [],
                draftComments: draftCommentsByFileID[file.id] ?? [],
                threads: DiffReviewProviderFeedbackResolver.threads(
                    threads, for: file.summary.path, includeFileLevel: file.imageProvider != nil
                ),
                annotations: inlineAnnotations(for: file.summary.path),
                state: state,
                theme: theme,
                layoutMode: layoutMode,
                wrapLines: wrapLines,
                showWhitespace: showWhitespace,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                showsSourceBadge: showsSourceBadges,
                focusedFeedbackID: focusedFeedbackID,
                inlineFeedbackScrollTargetID: inlineFeedbackScrollTargetID(for: file.id),
                focusedDraftCommentID: focusedDraftCommentID,
                allowsDraftCommentCreation: allowsDraftCommentCreation,
                allowsNonLineDraftCommentCreation: allowsNonLineDraftCommentCreation,
                actionPresence: .init(
                    canOpenFile: file.openFile != nil,
                    canUnstageFile: file.stagedMutationActions?.unstageFile != nil,
                    canCreateDraftComment: allowsDraftCommentCreation,
                    canReply: canReply,
                    canResolve: canResolve,
                    canAddToReview: canAddToReview,
                    canUnstageHunk: file.stagedMutationActions?.unstageHunk != nil,
                    hunkUnstageEnabled: file.stagedMutationActions?.unstageEnabledBase ?? false
                ),
                lspContext: lspContextForFile(file),
                reviewFeedbackTarget: feedbackTarget,
                draftCommentActions: appKitDraftActions,
                onContextExpansionActivated: { contextExpandedFileIDs.insert(file.id) }
            )
        }
    }

    private func inlineFeedbackScrollTargetID(for fileID: DiffReviewFileID) -> String? {
        guard let command = inlineFeedbackScrollCommand,
              command.fileID == fileID
        else { return nil }

        return command.feedbackID
    }

    private func synchronizeSelectionWithSession() {
        let previousFileSetKey = synchronizedFileSetKey
        let previousSelection = selectedFileID
        let result = DiffReviewSurfaceSelectionSync.synchronize(
            current: previousSelection,
            previousFileSetKey: previousFileSetKey,
            fileIDs: fileIDs,
            programmaticScroll: programmaticScroll
        )

        selectedFileID = result.selectedFileID
        synchronizedFileSetKey = result.fileSetKey
        programmaticScroll = result.programmaticScroll
        contextExpandedFileIDs.formIntersection(Set(fileIDs))
        appKitPresentationStore.prune(keeping: Set(fileIDs))
        if DiffReviewSurfaceSelectionSync.shouldScrollRestoredSelection(
            previousFileSetKey: previousFileSetKey,
            previousSelection: previousSelection,
            selectedFileID: result.selectedFileID,
            firstFileID: fileIDs.first
        ), let selectedFileID = result.selectedFileID {
            queueProgrammaticFileScroll(to: selectedFileID)
        }
    }

    private func scrollToFile(_ id: DiffReviewFileID) {
        selectedFileID = id
        queueProgrammaticFileScroll(to: id)
    }

    private func queueProgrammaticFileScroll(to id: DiffReviewFileID) {
        scrollSpyActiveFileID = id
        scrollCommand = scrollCommandController.command(to: id)
    }

    private func updateSelectedFileFromAppKitViewport(_ fileID: DiffReviewFileID) {
        guard programmaticScroll.acceptsScrollSpyUpdate(for: fileID), fileID != selectedFileID else { return }
        selectedFileID = fileID
        scrollSpyActiveFileID = fileID
    }

    private func selectAppKitNavigationFile(_ fileID: DiffReviewFileID, requestGeneration: Int) {
        selectedFileID = fileID
        scrollSpyActiveFileID = fileID
        let token = programmaticScroll.beginProgrammaticScroll(to: fileID)
        appKitProgrammaticScroll = .init(requestGeneration: requestGeneration, token: token)
        appKitScrollCompletionGate.begin(requestGeneration: requestGeneration)
    }

    private func finishAppKitProgrammaticScroll(requestGeneration: Int) {
        guard appKitScrollCompletionGate.consumesCompletion(for: requestGeneration),
              let appKitProgrammaticScroll,
              appKitProgrammaticScroll.requestGeneration == requestGeneration
        else { return }
        programmaticScroll.finishProgrammaticScroll(appKitProgrammaticScroll.token)
        self.appKitProgrammaticScroll = nil
    }

    private func inlineAnnotations(for filePath: String) -> [DiffInlineAnnotation] {
        annotations
            .filter { $0.path == filePath }
            .map { DiffInlineAnnotation.from($0) }
    }

    private func inlineThreads(for filePath: String) -> [DiffInlineCommentThread] {
        DiffReviewProviderFeedbackResolver.threads(
            threads,
            for: filePath,
            includeFileLevel: false
        )
    }
}

private struct AppKitDiffReviewProgrammaticScroll {
    let requestGeneration: Int
    let token: DiffReviewProgrammaticScrollController.Token
}

enum DiffReviewSurfaceSelectionSync {
    struct Result {
        let selectedFileID: DiffReviewFileID?
        let fileSetKey: String
        let programmaticScroll: DiffReviewProgrammaticScrollController
    }

    static func fileSetKey(for fileIDs: [DiffReviewFileID]) -> String {
        fileIDs.map { "\($0.rawValue.count):\($0.rawValue)" }.joined(separator: "|")
    }

    static func synchronizedSelection(
        current: DiffReviewFileID?,
        fileIDs: [DiffReviewFileID]
    ) -> DiffReviewFileID? {
        guard let first = fileIDs.first else { return nil }

        if let current, fileIDs.contains(current) {
            return current
        }

        return first
    }

    static func synchronize(
        current: DiffReviewFileID?,
        previousFileSetKey: String?,
        fileIDs: [DiffReviewFileID],
        programmaticScroll: DiffReviewProgrammaticScrollController
    ) -> Result {
        let nextFileSetKey = fileSetKey(for: fileIDs)
        let didChangeFileSet = previousFileSetKey != nil && previousFileSetKey != nextFileSetKey

        return Result(
            selectedFileID: synchronizedSelection(current: current, fileIDs: fileIDs),
            fileSetKey: nextFileSetKey,
            programmaticScroll: didChangeFileSet ? DiffReviewProgrammaticScrollController() : programmaticScroll
        )
    }

    static func shouldScrollRestoredSelection(
        previousFileSetKey: String?,
        previousSelection: DiffReviewFileID?,
        selectedFileID: DiffReviewFileID?,
        firstFileID: DiffReviewFileID?
    ) -> Bool {
        guard previousFileSetKey == nil,
              let previousSelection,
              previousSelection == selectedFileID,
              previousSelection != firstFileID
        else {
            return false
        }

        return true
    }
}

extension DiffReviewFileSectionHeightEstimator {
    static func estimatedHeight(for file: DiffReviewFileSectionModel, inlineFeedbackCount: Int) -> CGFloat {
        estimatedHeight(for: file)
            + DiffReviewInlineFeedbackDisplayPolicy.estimatedHeight(for: inlineFeedbackCount)
    }

    static func estimatedHeight(
        for file: DiffReviewFileSectionModel,
        inlineFeedback: [DiffReviewInlineFeedback]
    ) -> CGFloat {
        estimatedHeight(for: file, inlineFeedback: inlineFeedback, draftComments: [])
    }

    static func estimatedHeight(
        for file: DiffReviewFileSectionModel,
        inlineFeedback: [DiffReviewInlineFeedback],
        draftComments: [ReviewDraftComment]
    ) -> CGFloat {
        guard let displayModel = file.displayModel else {
            return estimatedHeight(for: file)
                + DiffReviewInlineFeedbackDisplayPolicy.estimatedHeight(for: inlineFeedback)
                + ReviewDraftCommentDisplayPolicy.estimatedHeight(
                    for: ReviewDraftCommentPlacement.position(draftComments, in: []).fileLevel
                )
        }

        let placement = DiffReviewInlineFeedbackPlacement.position(inlineFeedback, in: displayModel.groups)
        let fileLevelHeight = DiffReviewInlineFeedbackDisplayPolicy.estimatedHeight(for: placement.fileLevel)
        let groupHeights = placement.byGroupID.values.reduce(CGFloat(0)) { total, groupFeedback in
            total + DiffReviewInlineFeedbackDisplayPolicy.estimatedHeight(for: groupFeedback)
        }
        let draftPlacement = ReviewDraftCommentPlacement.position(draftComments, in: displayModel.groups)
        let draftFileLevelHeight = ReviewDraftCommentDisplayPolicy.estimatedHeight(for: draftPlacement.fileLevel)
        let draftGroupHeights = displayModel.groups.reduce(CGFloat(0)) { total, group in
            let rowKeys = ReviewDraftCommentPlacement.allRowKeys(in: group)
            let groupDraftComments = ReviewDraftCommentPlacement.comments(
                matching: rowKeys,
                in: draftPlacement,
                groupID: group.id
            )
            return total + ReviewDraftCommentDisplayPolicy.estimatedHeight(for: groupDraftComments)
        }

        return estimatedHeight(for: file) + fileLevelHeight + groupHeights + draftFileLevelHeight + draftGroupHeights
    }
}
