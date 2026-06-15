import SwiftUI

struct ReviewSessionTabLoadToken: Equatable {
    private let id = UUID()
}

struct ReviewSessionTabLoadCoordinator {
    private(set) var activeToken: ReviewSessionTabLoadToken?

    mutating func begin() -> ReviewSessionTabLoadToken {
        let token = ReviewSessionTabLoadToken()
        activeToken = token
        return token
    }

    func canPublish(_ token: ReviewSessionTabLoadToken) -> Bool {
        activeToken == token
    }

    mutating func finish(_ token: ReviewSessionTabLoadToken) {
        guard activeToken == token else { return }
        activeToken = nil
    }
}

struct ReviewSessionTabLoadPublication {
    let record: ReviewSessionRecord
    let loaded: ReviewSessionLoadedContext
    let selectedFileID: DiffReviewFileID?
    let focusedDraftCommentID: String?
    let shouldPersistSelectionState: Bool

    static func initial(
        record: ReviewSessionRecord,
        loaded: ReviewSessionLoadedContext
    ) -> ReviewSessionTabLoadPublication {
        let fileIDs = loaded.session.summary.files.map(\.id)
        return ReviewSessionTabLoadPublication(
            record: record,
            loaded: loaded,
            selectedFileID: DiffReviewSurfaceSelectionSync.synchronizedSelection(
                current: record.selectedFileID,
                fileIDs: fileIDs
            ),
            focusedDraftCommentID: record.focusedCommentID,
            shouldPersistSelectionState: false
        )
    }
}

struct ReviewSessionTabView: View {
    let worktree: Worktree?
    let tabState: ReviewSessionTabState
    let appState: AppState?
    var sessionStore: ReviewSessionStore
    var draftCommentStore: ReviewDraftCommentStore
    var loader: ReviewSessionLoader
    var feedbackSender: ReviewFeedbackAgentSender
    var loadsOnAppear: Bool
    var persistsState: Bool
    var now: () -> Date

    @Environment(\.theme) private var theme
    @State private var record: ReviewSessionRecord?
    @State private var loaded: ReviewSessionLoadedContext?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedFileID: DiffReviewFileID?
    @State private var railCollapsed = false
    @State private var reviewSummaryCollapsed = false
    @State private var localLayoutMode = DiffLayoutMode.split
    @State private var localWrapLines = false
    @State private var localShowWhitespace = false
    @State private var draftCommentController: ReviewDraftCommentController?
    @State private var loadedDraftSessionID: ReviewDraftSessionID?
    @State private var focusedDraftCommentID: String?
    @State private var draftCommentScrollCommand: DiffReviewDraftCommentScrollCommand?
    @State private var draftCommentScrollController = DiffReviewDraftCommentScrollController()
    @State private var loadCoordinator = ReviewSessionTabLoadCoordinator()
    @State private var loadGeneration = 0

    init(worktree: Worktree, tabState: ReviewSessionTabState, appState: AppState) {
        self.worktree = worktree
        self.tabState = tabState
        self.appState = appState
        self.sessionStore = ReviewSessionStore()
        self.draftCommentStore = ReviewDraftCommentStore()
        self.loader = ReviewSessionLoader.production(appState: appState, worktree: worktree)
        self.feedbackSender = ReviewFeedbackAgentSender.production(appState: appState, worktreeID: worktree.id)
        self.loadsOnAppear = true
        self.persistsState = true
        self.now = Date.init
        self._selectedFileID = State(initialValue: tabState.selectedFileID)
        self._focusedDraftCommentID = State(initialValue: tabState.focusedCommentID)
    }

    private init(
        tabState: ReviewSessionTabState,
        record: ReviewSessionRecord?,
        loaded: ReviewSessionLoadedContext?,
        sessionStore: ReviewSessionStore = ReviewSessionStore(),
        draftCommentStore: ReviewDraftCommentStore = ReviewDraftCommentStore(),
        loader: ReviewSessionLoader = ReviewSessionLoader(),
        feedbackSender: ReviewFeedbackAgentSender,
        loadsOnAppear: Bool,
        persistsState: Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.worktree = nil
        self.tabState = tabState
        self.appState = nil
        self.sessionStore = sessionStore
        self.draftCommentStore = draftCommentStore
        self.loader = loader
        self.feedbackSender = feedbackSender
        self.loadsOnAppear = loadsOnAppear
        self.persistsState = persistsState
        self.now = now
        self._record = State(initialValue: record)
        self._loaded = State(initialValue: loaded)
        self._selectedFileID = State(initialValue: record?.selectedFileID ?? tabState.selectedFileID)
        self._focusedDraftCommentID = State(initialValue: record?.focusedCommentID ?? tabState.focusedCommentID)
    }

    static func preview(record: ReviewSessionRecord, loaded: ReviewSessionLoadedContext) -> some View {
        ReviewSessionTabView(
            tabState: ReviewSessionTabState(worktreeId: record.target.worktreeID, record: record),
            record: record,
            loaded: loaded,
            feedbackSender: ReviewFeedbackAgentSender(availableTargets: { [] }, send: { _, _ in }),
            loadsOnAppear: false,
            persistsState: false
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.color("line"))
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
        .task(id: loadTaskID) {
            guard loadsOnAppear else { return }
            let token = beginLoadReviewSession()
            await loadReviewSession(token: token)
        }
    }

    private var loadTaskID: String {
        "\(tabState.sessionID.rawValue):\(loadGeneration)"
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.color("accent"))
            VStack(alignment: .leading, spacing: 2) {
                Text(record?.target.title ?? tabState.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .accessibilityLabel(record?.target.title ?? tabState.title)
                if let sourceDescription = record?.target.sourceDescription {
                    Text(sourceDescription)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-muted"))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let providerDescription = record?.target.providerDescription {
                Text(providerDescription)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(theme.color("bg-2"))
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "review-session-title",
                label: record?.target.title ?? tabState.title
            )
        )
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            stateView(title: "Loading review session...", detail: nil, color: theme.color("fg-dim"), showsRetry: false)
        } else if let loadError {
            stateView(title: "Could not load review session", detail: loadError, color: theme.color("del"), showsRetry: loadsOnAppear)
        } else if let loaded, loaded.session.files.isEmpty {
            stateView(title: "No files to review", detail: "This review session has no file diffs.", color: theme.color("fg-dim"), showsRetry: false)
        } else if let loaded {
            reviewSurface(loaded)
        } else {
            stateView(title: "No review session loaded", detail: nil, color: theme.color("fg-dim"), showsRetry: false)
        }
    }

    private func stateView(title: String, detail: String?, color: Color, showsRetry: Bool) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-muted"))
                    .multilineTextAlignment(.center)
            }
            if showsRetry {
                Button("Retry") {
                    loadGeneration += 1
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
    }

    private func reviewSurface(_ loaded: ReviewSessionLoadedContext) -> some View {
        DiffReviewSurface(
            session: loaded.session,
            selectedFileID: Binding(
                get: { selectedFileID },
                set: { setSelectedFileID($0, persist: true) }
            ),
            railCollapsed: $railCollapsed,
            reviewSummaryCollapsed: $reviewSummaryCollapsed,
            layoutMode: layoutModeBinding,
            wrapLines: wrapLinesBinding,
            showWhitespace: showWhitespaceBinding,
            codeFontFamily: appState?.config.code.fontFamily ?? "",
            codeFontSize: CGFloat(appState?.config.code.fontSize ?? 13),
            showsSourceBadges: true,
            showsRailDisplayControls: true,
            showsDraftSummaryRail: true,
            lspContextForFile: makeLSPContext,
            reviewFeedbackTarget: loaded.feedbackTarget,
            draftCommentsByFileID: ReviewDraftCommentGrouping.commentsByFileID(draftCommentController?.comments ?? []),
            focusedDraftCommentID: focusedDraftCommentID,
            draftCommentScrollCommand: draftCommentScrollCommand,
            draftCommentActions: draftCommentActions(),
            onSelectDraftComment: selectDraftComment,
            onSaveDraftComment: saveDraftComment
        )
        .environment(\.reviewDraftSummaryRailStatus, ReviewDraftSummaryRailStatus(record: record))
    }

    private var layoutModeBinding: Binding<DiffLayoutMode> {
        guard let appState else { return $localLayoutMode }
        return DiffPreferenceBindings(appState: appState).layoutMode
    }

    private var wrapLinesBinding: Binding<Bool> {
        guard let appState else { return $localWrapLines }
        return DiffPreferenceBindings(appState: appState).wrapLines
    }

    private var showWhitespaceBinding: Binding<Bool> {
        guard let appState else { return $localShowWhitespace }
        return DiffPreferenceBindings(appState: appState).showWhitespace
    }

    private func makeLSPContext(_ file: DiffReviewFileSectionModel) -> DiffPaneLSPContext? {
        guard let appState, let worktree else { return nil }
        let relativePath = file.summary.path
        let fileURL = worktree.path.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let language = appState.lsp.language(forFileExtension: (relativePath as NSString).pathExtension)
        else {
            return nil
        }
        return DiffPaneLSPContext(
            worktreeId: worktree.id,
            worktreeRoot: worktree.path,
            relativePath: relativePath,
            language: language,
            lsp: appState.lsp,
            openTarget: { url, line, character in
                openLSPTarget(
                    url: url,
                    originatingRelativePath: relativePath,
                    language: language,
                    line: line,
                    character: character
                )
            }
        )
    }

    private func openLSPTarget(
        url: URL,
        originatingRelativePath: String,
        language: String,
        line: Int,
        character: Int
    ) {
        guard let appState, let worktree else { return }
        let prefix = worktree.path.path + "/"
        if url.path.hasPrefix(prefix) {
            let relativeTarget = String(url.path.dropFirst(prefix.count))
            appState.tabs.openEditor(
                worktreeId: worktree.id,
                relativePath: relativeTarget,
                revealLine: line,
                revealCharacter: character
            )
        } else {
            appState.tabs.openExternalEditor(
                worktreeId: worktree.id,
                absoluteURL: url,
                revealLine: line,
                revealCharacter: character,
                originatingRelativePath: originatingRelativePath,
                originatingWorktreeRoot: worktree.path,
                language: language
            )
        }
    }

    private func beginLoadReviewSession() -> ReviewSessionTabLoadToken {
        let token = loadCoordinator.begin()
        isLoading = true
        loadError = nil
        loaded = nil
        return token
    }

    private func loadReviewSession(token: ReviewSessionTabLoadToken) async {
        do {
            guard let storedRecord = try sessionStore.load(id: tabState.sessionID) else {
                throw ReviewSessionTabError.missingSession(tabState.sessionID)
            }

            let loadedContext = try await loader.load(target: storedRecord.target)
            guard loadCoordinator.canPublish(token) else { return }

            publishInitialLoad(
                ReviewSessionTabLoadPublication.initial(
                    record: storedRecord,
                    loaded: loadedContext
                )
            )
            loadDraftCommentController(for: storedRecord)
            isLoading = false
            loadCoordinator.finish(token)
        } catch is CancellationError {
            guard loadCoordinator.canPublish(token) else { return }
            isLoading = false
            loadCoordinator.finish(token)
        } catch {
            guard loadCoordinator.canPublish(token) else { return }
            loadError = error.localizedDescription
            isLoading = false
            loadCoordinator.finish(token)
        }
    }

    private func publishInitialLoad(_ publication: ReviewSessionTabLoadPublication) {
        record = publication.record
        loaded = publication.loaded
        selectedFileID = publication.selectedFileID
        focusedDraftCommentID = publication.focusedDraftCommentID
    }

    private func loadDraftCommentController(for record: ReviewSessionRecord) {
        let sessionID = record.target.draftSessionID
        if loadedDraftSessionID != sessionID {
            draftCommentController = ReviewDraftCommentController(
                sessionID: sessionID,
                store: draftCommentStore
            )
            loadedDraftSessionID = sessionID
            draftCommentScrollCommand = nil
        }
        do {
            try draftCommentController?.load()
        } catch {
            // Draft comment load failures stay non-blocking; the controller keeps the error.
        }
    }

    private func draftCommentActions() -> ReviewDraftCommentActions {
        ReviewDraftWorkspaceActions.make(
            controller: draftCommentController,
            sender: feedbackSender,
            sessionID: tabState.sessionID,
            recordHandoff: recordSessionHandoff
        )
    }

    private func recordSessionHandoff(_ handoff: ReviewFeedbackHandoff) {
        guard persistsState else {
            if let current = record {
                record = current.recording(handoff: handoff)
            }
            return
        }

        do {
            let current = try sessionStore.load(id: handoff.sessionID) ?? record
            guard let current else { return }
            let updated = current.recording(handoff: handoff)
            try sessionStore.save(updated)
            record = updated
        } catch {
            guard var visibleRecord = record else { return }
            visibleRecord.lastSendError = error.localizedDescription
            visibleRecord.updatedAt = now()
            record = visibleRecord
        }
    }

    private func selectDraftComment(_ comment: ReviewDraftComment) {
        setFocusedDraftCommentID(comment.id, persist: true)
        setSelectedFileID(comment.fileID, persist: true)
        draftCommentScrollCommand = draftCommentScrollController.command(
            commentID: comment.id,
            fileID: comment.fileID
        )
    }

    private func saveDraftComment(fileID: DiffReviewFileID, anchor: DiffReviewLineAnchor, body: String) {
        do {
            try draftCommentController?.add(anchor: anchor, fileID: fileID, bodyMarkdown: body)
        } catch {
            // Draft comment save failures stay non-blocking; the controller keeps the error.
        }
    }

    private func setSelectedFileID(_ fileID: DiffReviewFileID?, persist shouldPersist: Bool) {
        guard selectedFileID != fileID else { return }
        selectedFileID = fileID
        guard shouldPersist else { return }
        persistSelectedFile(fileID)
    }

    private func setFocusedDraftCommentID(_ commentID: String?, persist shouldPersist: Bool) {
        guard focusedDraftCommentID != commentID else { return }
        focusedDraftCommentID = commentID
        guard shouldPersist else { return }
        persistFocusedComment(commentID)
    }

    private func persistSelectedFile(_ fileID: DiffReviewFileID?) {
        guard let current = record else { return }
        guard current.selectedFileID != fileID else { return }
        let updated = current.selectingFile(fileID, now: now())
        persist(updated)
        updateTabState { state in
            state.selectedFileID = fileID
        }
    }

    private func persistFocusedComment(_ commentID: String?) {
        guard let current = record else { return }
        guard current.focusedCommentID != commentID else { return }
        let updated = current.focusingComment(commentID, now: now())
        persist(updated)
        updateTabState { state in
            state.focusedCommentID = commentID
        }
    }

    private func persist(_ updated: ReviewSessionRecord) {
        record = updated
        guard persistsState else { return }
        do {
            try sessionStore.save(updated)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func updateTabState(_ mutate: (inout ReviewSessionTabState) -> Void) {
        guard persistsState, let appState else { return }
        _ = appState.tabs.updateReviewSession(
            worktreeId: tabState.worktreeId,
            tabId: tabState.id,
            mutate: mutate
        )
    }
}

private enum ReviewSessionTabError: LocalizedError {
    case missingSession(ReviewSessionID)

    var errorDescription: String? {
        switch self {
        case .missingSession(let id):
            return "Review session \(id.rawValue) was not found."
        }
    }
}
