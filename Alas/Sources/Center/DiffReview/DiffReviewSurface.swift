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
    @State private var sectionFrames: [DiffReviewSectionFrame] = []
    @State private var scrollProbe = DiffReviewScrollProbe(minY: 0, viewportHeight: 0)
    @State private var contextExpandedFileIDs: Set<DiffReviewFileID> = []
    @State private var synchronizedFileSetKey: String?

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
                    onSelectDraftComment: onSelectDraftComment,
                    inlineFeedbackByFileID: inlineFeedbackByFileID,
                    focusedFeedbackID: focusedFeedbackID,
                    onSelectInlineFeedback: onSelectInlineFeedback
                )
            }
        }
    }

    private func mainReviewStream(_ session: DiffReviewLoadedSession, firstFileID: DiffReviewFileID) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let renderEligibleIDs = DiffReviewRenderEligibility.fileIDs(ordered: session.files.map(\.id))
                    let renderEligibleFiles = session.files.filter { renderEligibleIDs.contains($0.id) }
                    ForEach(renderEligibleFiles.indices, id: \.self) { index in
                        let file = renderEligibleFiles[index]
                        Color.clear
                            .frame(height: 1)
                            .id(DiffReviewSurfaceSelectionSync.topVisibilityTargetID(for: file.summary.id))
                            .accessibilityHidden(true)
                        fileSection(file)
                            .background(DiffReviewSectionFrameReader(fileID: file.summary.id))
                            .id(DiffReviewSurfaceSelectionSync.sectionVisibilityTargetID(for: file.summary.id))
                        if index < renderEligibleFiles.index(before: renderEligibleFiles.endIndex) {
                            Color.clear
                                .frame(height: 14)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .padding(16)
                .coordinateSpace(name: DiffReviewSectionFrameReader.coordinateSpaceName)
                .modifier(DiffReviewFallbackScrollTargetLayout())
            }
            .modifier(DiffReviewScrollTracking(
                onGeometry: { probe in
                    updateSelectedFileFromGeometry(probe)
                },
                onVisibleTargetIDs: { ids in
                    updateSelectedFileFromVisibility(ids)
                }
            ))
            .onPreferenceChange(DiffReviewSectionFramePreferenceKey.self) { frames in
                sectionFrames = frames.sorted {
                    if $0.minY != $1.minY {
                        return $0.minY < $1.minY
                    }
                    return $0.id.rawValue < $1.id.rawValue
                }
                updateSelectedFileFromGeometry()
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
        .background(theme.color("bg-1"))
    }

    @ViewBuilder
    private func fileSection(_ file: DiffReviewFileSectionModel) -> some View {
        let inlineFeedback = inlineFeedbackByFileID[file.id] ?? []
        let draftComments = draftCommentsByFileID[file.id] ?? []
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

    private func updateSelectedFileFromVisibility(_ visibleRawIDs: [String]) {
        guard let updated = DiffReviewSurfaceSelectionSync.updatedSelectionFromVisibility(
            current: selectedFileID,
            visibleRawIDs: visibleRawIDs,
            fileIDs: fileIDs,
            programmaticScroll: programmaticScroll
        ) else { return }

        selectedFileID = updated
    }

    private func updateSelectedFileFromGeometry(_ probe: DiffReviewScrollProbe) {
        scrollProbe = probe
        updateSelectedFileFromGeometry()
    }

    private func updateSelectedFileFromGeometry() {
        guard scrollProbe.viewportHeight > 0 else { return }
        guard let updated = DiffReviewActiveFileSelection.updatedSelection(
            current: selectedFileID,
            frames: sectionFrames,
            viewportMinY: scrollProbe.minY,
            viewportHeight: scrollProbe.viewportHeight,
            programmaticScroll: programmaticScroll
        ) else { return }

        selectedFileID = updated
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

private struct DiffReviewScrollProbe: Equatable {
    let minY: CGFloat
    let viewportHeight: CGFloat
}

private struct DiffReviewScrollTracking: ViewModifier {
    let onGeometry: (DiffReviewScrollProbe) -> Void
    let onVisibleTargetIDs: ([String]) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: DiffReviewScrollProbe.self) { geometry in
                DiffReviewScrollProbe(
                    minY: geometry.visibleRect.minY,
                    viewportHeight: geometry.visibleRect.height
                )
            } action: { _, new in
                onGeometry(new)
            }
        } else {
            content.onScrollTargetVisibilityChange(
                idType: String.self,
                threshold: DiffReviewSurfaceSelectionSync.visibilityThreshold
            ) { ids in
                onVisibleTargetIDs(ids)
            }
        }
    }
}

private struct DiffReviewFallbackScrollTargetLayout: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
        } else {
            content.scrollTargetLayout()
        }
    }
}

private struct DiffReviewSectionFrameReader: View {
    static let coordinateSpaceName = "diff-review-section-frame-space"

    let fileID: DiffReviewFileID

    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: DiffReviewSectionFramePreferenceKey.self,
                value: [
                    DiffReviewSectionFrame(
                        id: fileID,
                        minY: geometry.frame(in: .named(Self.coordinateSpaceName)).minY,
                        maxY: geometry.frame(in: .named(Self.coordinateSpaceName)).maxY
                    ),
                ]
            )
        }
    }
}

private struct DiffReviewSectionFramePreferenceKey: PreferenceKey {
    static let defaultValue: [DiffReviewSectionFrame] = []

    static func reduce(value: inout [DiffReviewSectionFrame], nextValue: () -> [DiffReviewSectionFrame]) {
        value.append(contentsOf: nextValue())
    }
}

enum DiffReviewSurfaceSelectionSync {
    static let visibilityThreshold: CGFloat = 0

    struct Result {
        let selectedFileID: DiffReviewFileID?
        let fileSetKey: String
        let programmaticScroll: DiffReviewProgrammaticScrollController
    }

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
        let topTargetLookup = Dictionary(uniqueKeysWithValues: fileIDs.map {
            (topVisibilityTargetID(for: $0), $0)
        })
        let sectionTargetLookup = Dictionary(uniqueKeysWithValues: fileIDs.map {
            (sectionVisibilityTargetID(for: $0), $0)
        })
        let visibleTopTarget = visibleRawIDs.lazy.compactMap { topTargetLookup[$0] }.first
        let currentIsVisible = current.map { current in
            visibleRawIDs.contains(topVisibilityTargetID(for: current))
                || visibleRawIDs.contains(sectionVisibilityTargetID(for: current))
        } ?? false
        guard visibleTopTarget != nil || !currentIsVisible else { return nil }

        let active = visibleTopTarget
            ?? visibleRawIDs.lazy.compactMap { sectionTargetLookup[$0] }.first
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
