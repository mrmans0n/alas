import SwiftUI

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
    @State private var renderedFileIDs: Set<DiffReviewFileID> = []
    @State private var contextExpandedFileIDs: Set<DiffReviewFileID> = []
    @State private var synchronizedFileSetKey: String?

    private static let scrollCoordinateSpace = "diff-review-scroll"

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
            mainReviewStream(session, firstFileID: firstFileID)
            if shouldShowReviewSummaryRail {
                ReviewDraftSummaryRail(
                    comments: allDraftComments,
                    bundle: reviewFeedbackBundle,
                    collapsed: $reviewSummaryCollapsed,
                    focusedDraftCommentID: focusedDraftCommentID,
                    draftCommentActions: draftCommentActions,
                    onSelectDraftComment: onSelectDraftComment
                )
            }
        }
    }

    private func mainReviewStream(_ session: DiffReviewLoadedSession, firstFileID: DiffReviewFileID) -> some View {
        GeometryReader { viewport in
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        let renderedIDs = effectiveRenderedFileIDs(firstFileID: firstFileID)
                        ForEach(session.files) { file in
                            fileSection(file, isRendered: renderedIDs.contains(file.id))
                                .id(file.summary.id.rawValue)
                                .background(sectionFrameReader(for: file.summary.id))
                        }
                    }
                    .padding(16)
                }
                .coordinateSpace(name: Self.scrollCoordinateSpace)
                .onPreferenceChange(DiffReviewSectionFramePreferenceKey.self) { frames in
                    updateSelectedFileFromScroll(frames: frames, viewportHeight: viewport.size.height)
                    updateRenderedFileIDs(
                        frames: frames,
                        viewportHeight: viewport.size.height,
                        firstFileID: firstFileID
                    )
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
                        Task { @MainActor in
                            scrollToInlineFeedback(command, scrollProxy: scrollProxy, animated: false)
                        }
                    }
                    if let draftCommand = draftCommentScrollCommand {
                        Task { @MainActor in
                            scrollToDraftComment(draftCommand, scrollProxy: scrollProxy, animated: false)
                        }
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
        }
        .background(theme.color("bg-1"))
    }

    @ViewBuilder
    private func fileSection(_ file: DiffReviewFileSectionModel, isRendered: Bool) -> some View {
        let inlineFeedback = inlineFeedbackByFileID[file.id] ?? []
        let draftComments = draftCommentsByFileID[file.id] ?? []
        if isRendered {
            DiffReviewFileSection(
                file: file,
                inlineFeedback: inlineFeedback,
                focusedFeedbackID: focusedFeedbackID,
                inlineFeedbackScrollTargetID: inlineFeedbackScrollTargetID(for: file.id),
                draftComments: draftComments,
                focusedDraftCommentID: focusedDraftCommentID,
                layoutMode: $layoutMode,
                wrapLines: $wrapLines,
                showWhitespace: $showWhitespace,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                showsSourceBadge: showsSourceBadges,
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
                threads: inlineThreads(for: file.summary.path),
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
            )
        } else {
            DiffReviewFileSectionPlaceholder(
                file: file,
                estimatedHeight: DiffReviewFileSectionHeightEstimator.estimatedHeight(
                    for: file,
                    inlineFeedback: inlineFeedback,
                    draftComments: draftComments
                ),
                showsSourceBadge: showsSourceBadges,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize
            )
        }
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
        if animated {
            withAnimation(.easeInOut(duration: 0.18)) {
                scrollProxy.scrollTo(command.targetID, anchor: .center)
            }
        } else {
            scrollProxy.scrollTo(command.targetID, anchor: .center)
        }
    }

    private func scrollToDraftComment(
        _ command: DiffReviewDraftCommentScrollCommand,
        scrollProxy: ScrollViewProxy,
        animated: Bool
    ) {
        selectedFileID = command.fileID
        if animated {
            withAnimation(.easeInOut(duration: 0.18)) {
                scrollProxy.scrollTo(command.targetID, anchor: .center)
            }
        } else {
            scrollProxy.scrollTo(command.targetID, anchor: .center)
        }
    }

    private func effectiveRenderedFileIDs(firstFileID: DiffReviewFileID) -> Set<DiffReviewFileID> {
        DiffReviewRenderWindow.renderedFileIDs(
            current: renderedFileIDs,
            frames: [],
            viewportHeight: 0,
            selectedFileID: selectedFileID,
            programmaticTarget: DiffReviewSurfaceSelectionSync.renderedTargetFileID(
                fileScrollTarget: programmaticScroll.target,
                inlineFeedbackScrollCommand: inlineFeedbackScrollCommand,
                draftCommentScrollCommand: draftCommentScrollCommand
            ),
            firstFileID: firstFileID
        ).union(contextExpandedFileIDs)
    }

    private func sectionFrameReader(for id: DiffReviewFileID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: DiffReviewSectionFramePreferenceKey.self,
                value: [
                    DiffReviewSectionFrame(
                        id: id,
                        minY: proxy.frame(in: .named(Self.scrollCoordinateSpace)).minY,
                        maxY: proxy.frame(in: .named(Self.scrollCoordinateSpace)).maxY
                    ),
                ]
            )
        }
    }

    private func updateSelectedFileFromScroll(frames: [DiffReviewSectionFrame], viewportHeight: CGFloat) {
        guard let updated = DiffReviewActiveFileSelection.updatedSelection(
            current: selectedFileID,
            frames: frames,
            viewportHeight: viewportHeight,
            programmaticScroll: programmaticScroll
        ) else { return }

        selectedFileID = updated
    }

    private func updateRenderedFileIDs(
        frames: [DiffReviewSectionFrame],
        viewportHeight: CGFloat,
        firstFileID: DiffReviewFileID
    ) {
        let updated = DiffReviewRenderWindow.renderedFileIDs(
            current: renderedFileIDs,
            frames: frames,
            viewportHeight: viewportHeight,
            selectedFileID: selectedFileID,
            programmaticTarget: DiffReviewSurfaceSelectionSync.renderedTargetFileID(
                fileScrollTarget: programmaticScroll.target,
                inlineFeedbackScrollCommand: inlineFeedbackScrollCommand,
                draftCommentScrollCommand: draftCommentScrollCommand
            ),
            firstFileID: firstFileID
        ).union(contextExpandedFileIDs)
        guard updated != renderedFileIDs else { return }

        renderedFileIDs = updated
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
        renderedFileIDs = []
        contextExpandedFileIDs.formIntersection(Set(fileIDs))
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
        let token = programmaticScroll.beginProgrammaticScroll(to: id)
        scrollCommand = scrollCommandController.command(to: id)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            programmaticScroll.finishProgrammaticScroll(token)
        }
    }

    private func inlineAnnotations(for filePath: String) -> [DiffInlineAnnotation] {
        annotations
            .filter { $0.path == filePath }
            .map { DiffInlineAnnotation.from($0) }
    }

    private func inlineThreads(for filePath: String) -> [DiffInlineCommentThread] {
        threads
            .filter { $0.path == filePath && !$0.isFileLevel && !$0.isOutdated }
            .compactMap { thread in
                let isOldSide: Bool
                if let side = thread.diffSide {
                    isOldSide = side.uppercased() == "LEFT"
                } else {
                    isOldSide = thread.line == nil && thread.originalLine != nil
                }
                guard let line = thread.line ?? thread.originalLine else { return nil }
                return DiffInlineCommentThread(
                    id: thread.id,
                    filePath: thread.path ?? "",
                    newLine: line,
                    isOldSide: isOldSide,
                    isResolved: thread.isResolved,
                    isOutdated: thread.isOutdated,
                    comments: thread.comments.map { c in
                        DiffInlineComment(
                            id: c.id,
                            author: c.author ?? "unknown",
                            body: c.body,
                            viewerCanUpdate: c.viewerCanUpdate,
                            viewerCanDelete: c.viewerCanDelete
                        )
                    },
                    viewerCanReply: thread.viewerCanReply,
                    viewerCanResolve: thread.viewerCanResolve,
                    viewerCanUnresolve: thread.viewerCanUnresolve
                )
            }
    }
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

struct DiffReviewSectionFramePreferenceKey: PreferenceKey {
    static var defaultValue: [DiffReviewSectionFrame] = []

    static func reduce(value: inout [DiffReviewSectionFrame], nextValue: () -> [DiffReviewSectionFrame]) {
        value.append(contentsOf: nextValue())
    }
}

private struct DiffReviewFileSectionPlaceholder: View {
    let file: DiffReviewFileSectionModel
    let estimatedHeight: CGFloat
    let showsSourceBadge: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: estimatedHeight, maxHeight: estimatedHeight)
        .background(theme.color("bg-1"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.color("line"), lineWidth: 0.75)
        )
        .accessibilityIdentifier("diff-review-file-section-placeholder-\(file.id.rawValue)")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(file.summary.status.glyph)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(statusColor(file.summary.status))
                .frame(width: 16)
            Text(file.summary.path)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize))
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
                .truncationMode(.middle)
            sourceBadge
            Spacer(minLength: 12)
            if file.summary.additions > 0 {
                Text("+\(file.summary.additions)")
                    .foregroundColor(theme.color("add"))
            }
            if file.summary.deletions > 0 {
                Text("-\(file.summary.deletions)")
                    .foregroundColor(theme.color("del"))
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
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
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
