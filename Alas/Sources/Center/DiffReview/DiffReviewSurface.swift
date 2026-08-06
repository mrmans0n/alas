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
    var onSaveDraftComment: (DiffReviewFileID, String?, DiffReviewLineAnchor, String) -> Void = { _, _, _, _ in }
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
    @State private var appKitScrollerEnabled = AppKitDiffScrollerFlag.isEnabled
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
        onSaveDraftComment: @escaping (DiffReviewFileID, String?, DiffReviewLineAnchor, String) -> Void = { _, _, _, _ in },
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
        .onReceive(NotificationCenter.default.publisher(for: AppKitDiffScrollerFlag.overrideDidChangeNotification)) { _ in
            appKitScrollerEnabled = AppKitDiffScrollerFlag.isEnabled
            resetScrollCommandBookkeeping()
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
            Group {
                if Self.usesAppKitScroller(flagEnabled: appKitScrollerEnabled) {
                    appKitMainReviewStream(session)
                } else {
                    legacyMainReviewStream(session, firstFileID: firstFileID)
                }
            }
            .id(appKitScrollerEnabled)
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

    private func legacyMainReviewStream(_ session: DiffReviewLoadedSession, firstFileID: DiffReviewFileID) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let renderRows = DiffReviewRenderEligibility.renderRows(
                        ordered: session.files.map(\.id),
                        renderedRowCounts: session.files.map { file in
                            file.displayModel.map(DiffReviewRenderBudget.renderedRowCount)
                        },
                        maxAutomaticallyRenderedRows: DiffReviewRenderBudget.maxRenderedRows
                    )
                    ForEach(renderRows) { row in
                        let file = session.files[row.index]
                        Color.clear
                            .frame(height: 1)
                            .id(DiffReviewSurfaceSelectionSync.topVisibilityTargetID(for: row.id))
                            .accessibilityHidden(true)
                        fileSection(file, automaticallyRendersDiff: row.automaticallyRendersDiff)
                            .id(DiffReviewSurfaceSelectionSync.sectionVisibilityTargetID(for: row.id))
                        Color.clear
                            .frame(height: row.showsBottomSpacing ? 14 : 0)
                            .accessibilityHidden(true)
                    }
                }
                .padding(16)
                .scrollTargetLayout()
            }
            .onScrollTargetVisibilityChange(
                idType: String.self,
                threshold: DiffReviewSurfaceSelectionSync.visibilityThreshold
            ) { ids in
                updateSelectedFileFromVisibility(ids)
            }
            .onChange(of: scrollCommand) { _, command in
                guard let command else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    scrollProxy.scrollTo(command.id.rawValue, anchor: .top)
                }
                scrollCommand = DiffReviewScrollCommandConsumption.consume(
                    current: scrollCommand,
                    consumed: command
                )
            }
            .onAppear {
                if let command = scrollCommand {
                    scrollProxy.scrollTo(command.id.rawValue, anchor: .top)
                    scrollCommand = DiffReviewScrollCommandConsumption.consume(
                        current: scrollCommand,
                        consumed: command
                    )
                }
                if let command = inlineFeedbackScrollCommand {
                    scrollToInlineFeedback(command, scrollProxy: scrollProxy, animated: false)
                }
                if let draftCommand = draftCommentScrollCommand {
                    scrollToDraftComment(draftCommand, scrollProxy: scrollProxy, animated: false)
                }
            }
            .onChange(of: inlineFeedbackScrollCommand) { _, command in
                guard let command else { return }
                scrollToInlineFeedback(command, scrollProxy: scrollProxy, animated: true)
            }
            .onChange(of: draftCommentScrollCommand) { _, command in
                guard let command else { return }
                scrollToDraftComment(command, scrollProxy: scrollProxy, animated: true)
            }
        }
        .background(theme.color("bg-1"))
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
        session.files.map { file in
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
                    onSaveDraftComment(file.id, file.summary.originalPath, anchor, body)
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
                reviewFeedbackTarget: effectiveReviewFeedbackTarget,
                draftCommentActions: appKitDraftActions,
                onContextExpansionActivated: { contextExpandedFileIDs.insert(file.id) }
            )
        }
    }

    @ViewBuilder
    private func fileSection(
        _ file: DiffReviewFileSectionModel,
        automaticallyRendersDiff: Bool
    ) -> some View {
        let inlineFeedback = inlineFeedbackByFileID[file.id] ?? []
        let draftComments = draftCommentsByFileID[file.id] ?? []
        EquatableDiffReviewFileSection(
            section: DiffReviewFileSection(
                file: file,
                inlineFeedback: inlineFeedback,
                focusedFeedbackID: focusedFeedbackID,
                inlineFeedbackScrollTargetID: inlineFeedbackScrollTargetID(for: file.id),
                draftComments: draftComments,
                focusedDraftCommentID: focusedDraftCommentID,
                draftCommentScrollTargetID: draftCommentScrollTargetID(for: file.id),
                layoutMode: $layoutMode,
                wrapLines: $wrapLines,
                showWhitespace: $showWhitespace,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                showsSourceBadge: showsSourceBadges,
                automaticallyRendersDiff: automaticallyRendersDiff,
                lspContext: lspContextForFile(file),
                inlineFeedbackActions: inlineFeedbackActions,
                onSelectInlineFeedback: onSelectInlineFeedback,
                draftCommentActions: draftCommentActions,
                onSelectDraftComment: onSelectDraftComment,
                onSaveDraftComment: { anchor, body in
                    onSaveDraftComment(file.id, file.summary.originalPath, anchor, body)
                },
                allowsDraftCommentCreation: allowsDraftCommentCreation,
                onContextExpansionActivated: {
                    contextExpandedFileIDs.insert(file.id)
                },
                reviewFeedbackTarget: effectiveReviewFeedbackTarget,
                threads: DiffReviewProviderFeedbackResolver.threads(
                    threads,
                    for: file.summary.path,
                    includeFileLevel: file.imageProvider != nil
                ),
                annotations: inlineAnnotations(for: file.summary.path),
                onReply: onReply,
                onResolve: onResolve,
                onUnresolve: onUnresolve,
                onEdit: onEdit,
                onDelete: onDelete,
                canReply: canReply,
                canResolve: canResolve,
                onStageReply: onStageReply,
                canAddToReview: canAddToReview
            ),
            layoutMode: layoutMode,
            wrapLines: wrapLines,
            showWhitespace: showWhitespace,
            draftCommentAvailability: draftComments.map(draftCommentActions.availability),
            inlineFeedbackAvailability: inlineFeedback.map { inlineFeedbackActions.availability($0, file.summary) },
            draftCommentAgentTargets: draftCommentActions.agentTargets()
        )
        .equatable()
    }

    private func inlineFeedbackScrollTargetID(for fileID: DiffReviewFileID) -> String? {
        guard let command = inlineFeedbackScrollCommand,
              command.fileID == fileID
        else { return nil }

        return command.feedbackID
    }

    private func draftCommentScrollTargetID(for fileID: DiffReviewFileID) -> String? {
        guard let command = draftCommentScrollCommand,
              command.fileID == fileID
        else { return nil }

        return command.commentID
    }

    private func scrollToInlineFeedback(
        _ command: DiffReviewInlineFeedbackScrollCommand,
        scrollProxy: ScrollViewProxy,
        animated: Bool
    ) {
        selectedFileID = command.fileID
        scrollToReviewItem(
            fileID: command.fileID,
            targetID: command.targetID,
            scrollProxy: scrollProxy,
            animated: animated
        )
    }

    private func scrollToDraftComment(
        _ command: DiffReviewDraftCommentScrollCommand,
        scrollProxy: ScrollViewProxy,
        animated: Bool
    ) {
        selectedFileID = command.fileID
        scrollToReviewItem(
            fileID: command.fileID,
            targetID: command.targetID,
            scrollProxy: scrollProxy,
            animated: animated
        )
    }

    /// Scrolls the review stream to a specific inline item — a draft comment
    /// or provider feedback card.
    ///
    /// The card is nested inside its file section, which is a lazy child of
    /// the review stream's `LazyVStack`. When the item's file isn't currently
    /// realized (the reviewer was looking at another file), a direct
    /// `scrollTo(cardID)` silently no-ops because the card view isn't in the
    /// tree yet. Mirror the file-rail scroll for that case: first land on the
    /// file section (a direct lazy child SwiftUI reliably realizes), let
    /// layout settle, then scroll to the nested card. `DiffReviewFileSection`
    /// keeps a commanded card's hunk realized when its normal hunk stack is
    /// lazy. When the file is already in view, a direct scroll reaches the card
    /// without a detour through the file header.
    ///
    /// A programmatic-scroll token suppresses the scrollspy during the move so
    /// it doesn't snap the selection back to whichever file ends up at the top
    /// of the viewport.
    private func scrollToReviewItem(
        fileID: DiffReviewFileID,
        targetID: some Hashable,
        scrollProxy: ScrollViewProxy,
        animated: Bool
    ) {
        let fileAlreadyVisible = scrollSpyActiveFileID == fileID
        selectedFileID = fileID
        // Lock the scrollspy's active file to the destination now. The visibility
        // callback early-returns once `selectedFileID` already matches (and is
        // suppressed during the programmatic scroll), so without this the
        // active-file tracker would stay on the previous file and a later
        // same-file-shortcut click on that now-off-screen file would no-op.
        scrollSpyActiveFileID = fileID
        let token = programmaticScroll.beginProgrammaticScroll(to: fileID)

        func scrollToCard() {
            if animated {
                withAnimation(.easeInOut(duration: 0.18)) {
                    scrollProxy.scrollTo(targetID, anchor: .center)
                }
            } else {
                scrollProxy.scrollTo(targetID, anchor: .center)
            }
        }

        if fileAlreadyVisible {
            scrollToCard()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                programmaticScroll.finishProgrammaticScroll(token)
            }
            return
        }

        let sectionID = DiffReviewSurfaceSelectionSync.sectionVisibilityTargetID(for: fileID)
        scrollProxy.scrollTo(sectionID, anchor: .top)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard programmaticScroll.isCurrent(token) else { return }
            scrollToCard()
            try? await Task.sleep(nanoseconds: 250_000_000)
            programmaticScroll.finishProgrammaticScroll(token)
        }
    }

    private func updateSelectedFileFromVisibility(_ visibleRawIDs: [String]) {
        guard let updated = DiffReviewSurfaceSelectionSync.updatedSelectionFromVisibility(
            current: selectedFileID,
            visibleRawIDs: visibleRawIDs,
            fileIDs: fileIDs,
            programmaticScroll: programmaticScroll
        ) else { return }

        selectedFileID = updated
        scrollSpyActiveFileID = updated
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

        guard !appKitScrollerEnabled else { return }

        let token = programmaticScroll.beginProgrammaticScroll(to: id)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            programmaticScroll.finishProgrammaticScroll(token)
        }
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

    private func resetScrollCommandBookkeeping() {
        scrollCommand = nil
        scrollCommandController.reset()
        programmaticScroll = DiffReviewProgrammaticScrollController()
        appKitProgrammaticScroll = nil
        appKitScrollCompletionGate = AppKitDiffReviewScrollCompletionGate()
        scrollSpyActiveFileID = nil
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

extension DiffReviewSurface {
    static func usesAppKitScroller(flagEnabled: Bool) -> Bool { flagEnabled }
}

enum DiffReviewSurfaceSelectionSync {
    static let visibilityThreshold: CGFloat = 0

    struct Result {
        let selectedFileID: DiffReviewFileID?
        let fileSetKey: String
        let programmaticScroll: DiffReviewProgrammaticScrollController
    }

    private struct VisibilityLookupCache {
        let topTargetLookup: [String: DiffReviewFileID]
        let sectionTargetLookup: [String: DiffReviewFileID]
    }

    private static var visibilityLookupCache: (key: String, value: VisibilityLookupCache)?

    static func fileSetKey(for fileIDs: [DiffReviewFileID]) -> String {
        fileIDs.map { "\($0.rawValue.count):\($0.rawValue)" }.joined(separator: "|")
    }

    static func sectionVisibilityTargetID(for fileID: DiffReviewFileID) -> String {
        fileID.rawValue
    }

    static func topVisibilityTargetID(for fileID: DiffReviewFileID) -> String {
        "\(fileID.rawValue.count):\(fileID.rawValue):top"
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

    static func updatedSelectionFromVisibility(
        current: DiffReviewFileID?,
        visibleRawIDs: [String],
        fileIDs: [DiffReviewFileID],
        programmaticScroll: DiffReviewProgrammaticScrollController
    ) -> DiffReviewFileID? {
        let key = fileSetKey(for: fileIDs)
        let cache: VisibilityLookupCache
        if let cached = visibilityLookupCache, cached.key == key {
            cache = cached.value
        } else {
            let topTargetLookup = Dictionary(uniqueKeysWithValues: fileIDs.map {
                (topVisibilityTargetID(for: $0), $0)
            })
            let sectionTargetLookup = Dictionary(uniqueKeysWithValues: fileIDs.map {
                (sectionVisibilityTargetID(for: $0), $0)
            })
            cache = VisibilityLookupCache(topTargetLookup: topTargetLookup, sectionTargetLookup: sectionTargetLookup)
            visibilityLookupCache = (key, cache)
        }
        let visibleTopTarget = visibleRawIDs.lazy.compactMap { cache.topTargetLookup[$0] }.first
        let currentIsVisible = current.map { current in
            visibleRawIDs.contains(topVisibilityTargetID(for: current))
                || visibleRawIDs.contains(sectionVisibilityTargetID(for: current))
        } ?? false
        guard visibleTopTarget != nil || !currentIsVisible else { return nil }

        let active = visibleTopTarget
            ?? visibleRawIDs.lazy.compactMap { cache.sectionTargetLookup[$0] }.first
        guard let active,
              active != current,
              programmaticScroll.acceptsScrollSpyUpdate(for: active)
        else { return nil }

        return active
    }

    static func renderedTargetFileID(
        fileScrollTarget: DiffReviewFileID?,
        inlineFeedbackScrollCommand: DiffReviewInlineFeedbackScrollCommand?
    ) -> DiffReviewFileID? {
        renderedTargetFileID(
            fileScrollTarget: fileScrollTarget,
            inlineFeedbackScrollCommand: inlineFeedbackScrollCommand,
            draftCommentScrollCommand: nil
        )
    }

    static func renderedTargetFileID(
        fileScrollTarget: DiffReviewFileID?,
        inlineFeedbackScrollCommand: DiffReviewInlineFeedbackScrollCommand?,
        draftCommentScrollCommand: DiffReviewDraftCommentScrollCommand?
    ) -> DiffReviewFileID? {
        draftCommentScrollCommand?.fileID ?? inlineFeedbackScrollCommand?.fileID ?? fileScrollTarget
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
