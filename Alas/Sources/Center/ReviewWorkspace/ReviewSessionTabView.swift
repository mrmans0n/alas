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

struct ProviderReviewPublishConfirmationState: Equatable {
    let commentID: String?
    let providerName: String
    let reviewIdentity: String
    let commentCount: Int
    let unpublishableMessages: [String]
    let allowedDecisions: [ProviderReviewDecision]
}

struct ReviewSessionTabView: View {
    let worktree: Worktree?
    let tabState: ReviewSessionTabState
    let appState: AppState?
    var onStartupRecoveryReady: () -> Void = {}
    var sessionStore: ReviewSessionStore
    var draftCommentStore: ReviewDraftCommentStore
    var loader: ReviewSessionLoader
    var feedbackSender: ReviewFeedbackAgentSender
    var providerRegistry: CodeHostProviderRegistry
    var loadsOnAppear: Bool
    var persistsState: Bool
    var now: () -> Date

    @Environment(\.theme) private var theme
    @State private var record: ReviewSessionRecord?
    @State private var loaded: ReviewSessionLoadedContext?
    @State private var loadedTrackedResolvedSHA: String?
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
    @State private var focusedFeedbackID: String?
    @State private var inlineFeedbackScrollCommand: DiffReviewInlineFeedbackScrollCommand?
    @State private var inlineFeedbackScrollController = DiffReviewInlineFeedbackScrollController()
    @State private var loadCoordinator = ReviewSessionTabLoadCoordinator()
    @State private var loadGeneration = 0
    @State private var selectionPersister = ReviewSessionSelectionPersister()
    @State private var providerPublishConfirmation: ProviderReviewPublishConfirmationState?
    @State private var selectedProviderDecision = ProviderReviewDecision.comment
    @State private var providerReviewSummaryBody = ""
    @State private var isProviderPublishing = false
    @State private var providerPublishError: String?

    init(
        worktree: Worktree,
        tabState: ReviewSessionTabState,
        appState: AppState,
        onStartupRecoveryReady: @escaping () -> Void = {}
    ) {
        self.worktree = worktree
        self.tabState = tabState
        self.appState = appState
        self.onStartupRecoveryReady = onStartupRecoveryReady
        self.sessionStore = ReviewSessionStore()
        self.draftCommentStore = ReviewDraftCommentStore()
        self.loader = ReviewSessionLoader.production(appState: appState, worktree: worktree)
        self.feedbackSender = ReviewFeedbackAgentSender.production(appState: appState, worktreeID: worktree.id)
        self.providerRegistry = .live()
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
        providerRegistry: CodeHostProviderRegistry = .live(),
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
        self.providerRegistry = providerRegistry
        self.loadsOnAppear = loadsOnAppear
        self.persistsState = persistsState
        self.now = now
        self._record = State(initialValue: record)
        self._loaded = State(initialValue: loaded)
        self._loadedTrackedResolvedSHA = State(initialValue: Self.trackedResolvedSHA(in: record))
        self._selectedFileID = State(initialValue: record?.selectedFileID ?? tabState.selectedFileID)
        self._focusedDraftCommentID = State(initialValue: record?.focusedCommentID ?? tabState.focusedCommentID)
        if let record {
            let controller = ReviewDraftCommentController(
                sessionID: record.target.draftSessionID,
                store: draftCommentStore
            )
            try? controller.load()
            self._draftCommentController = State(initialValue: controller)
            self._loadedDraftSessionID = State(initialValue: record.target.draftSessionID)
        }
    }

    static func preview(record: ReviewSessionRecord, loaded: ReviewSessionLoadedContext) -> some View {
        ReviewSessionTabView(
            tabState: ReviewSessionTabState(worktreeId: record.target.worktreeID, record: record),
            record: record,
            loaded: loaded,
            feedbackSender: ReviewFeedbackAgentSender(availableTargets: { [] }, send: { _, _, _ in }),
            loadsOnAppear: false,
            persistsState: false
        )
    }

    static func testView(
        record: ReviewSessionRecord,
        loaded: ReviewSessionLoadedContext,
        sessionStore: ReviewSessionStore = ReviewSessionStore(),
        draftCommentStore: ReviewDraftCommentStore = ReviewDraftCommentStore(),
        provider: any CodeHostProvider
    ) -> some View {
        ReviewSessionTabView(
            tabState: ReviewSessionTabState(worktreeId: record.target.worktreeID, record: record),
            record: record,
            loaded: loaded,
            sessionStore: sessionStore,
            draftCommentStore: draftCommentStore,
            feedbackSender: ReviewFeedbackAgentSender(availableTargets: { [] }, send: { _, _, _ in }),
            providerRegistry: CodeHostProviderRegistry(providers: [provider.kind: provider]),
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
        .overlay(providerPublishConfirmationOverlay)
        .task(id: loadTaskID) {
            guard loadsOnAppear else { return }
            let token = beginLoadReviewSession()
            if await loadReviewSession(token: token) {
                onStartupRecoveryReady()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .alasReviewDraftCommentsDidChangeExternally)) { _ in
            selectionPersister.flush()
            try? draftCommentController?.load()
            if let refreshed = try? sessionStore.load(id: tabState.sessionID) {
                record = refreshed
            }
        }
        .onChange(of: tabState.sessionID) { _, _ in
            rekeyDraftControllerForCurrentSession()
        }
        .onDisappear {
            selectionPersister.flush()
        }
    }

    private var loadTaskID: String {
        let revisionGeneration: Int
        if let appState, case .trackedCommit = record?.target.payload {
            revisionGeneration = appState.revisionChangeGeneration(worktreeID: tabState.worktreeId)
        } else {
            revisionGeneration = 0
        }
        let retargetGeneration = appState?.reviewSessionRetargetGeneration(sessionID: tabState.sessionID) ?? 0
        return "\(tabState.sessionID.rawValue):\(loadGeneration):\(revisionGeneration):\(retargetGeneration)"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            if showsTrackedRevisionRow {
                trackedRevisionRow.padding(.top, 8)
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

    private var trackedRevision: TrackedRevision? {
        guard case .trackedCommit(let revision) = record?.target.payload else { return nil }
        return revision
    }

    private var showsTrackedRevisionRow: Bool {
        trackedRevision != nil || record?.target.kind == .commit
    }

    private var trackedRevisionRow: some View {
        RevisionFollowControl(
            presentation: RevisionFollowPresentation(
                fixedSHA: fixedReviewSHA,
                revision: trackedRevision,
                refreshError: trackedRevision == nil ? nil : loadError
            ),
            worktreeID: worktree?.id ?? tabState.worktreeId,
            tabID: tabState.id,
            accessibilityPrefix: "review-session-revision",
            appState: appState,
            followedTarget: trackedRevision?.target,
            isRefreshing: isLoading && trackedRevision != nil,
            onAcceptPendingCheckout: acceptPendingCheckout,
            onRetry: { loadGeneration += 1 }
        )
    }

    private var fixedReviewSHA: String {
        if case .commit(let sha) = record?.target.payload { return sha }
        return trackedRevision?.resolvedSHA ?? "commit"
    }

    @MainActor
    private func acceptPendingCheckout() {
        guard let worktree, let appState else { return }
        appState.acceptTrackedRevisionCheckout(worktreeID: worktree.id, tabID: tabState.id)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            stateView(title: "Loading review session...", detail: nil, color: theme.color("fg-dim"), showsRetry: false)
        } else if let loaded, loaded.session.files.isEmpty {
            emptyReviewState()
        } else if let loaded {
            reviewSurface(loaded)
        } else if let loadError {
            stateView(title: "Could not load review session", detail: loadError, color: theme.color("del"), showsRetry: loadsOnAppear)
        } else {
            stateView(title: "No review session loaded", detail: nil, color: theme.color("fg-dim"), showsRetry: false)
        }
    }

    private func emptyReviewState() -> some View {
        VStack(spacing: 0) {
            if trackedRevision == nil, let loadError, !loadError.isEmpty {
                trackedRefreshErrorBanner(loadError)
            }
            stateView(title: "No files to review", detail: "This review session has no file diffs.", color: theme.color("fg-dim"), showsRetry: false)
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
        VStack(spacing: 0) {
            if let providerPublishError, !providerPublishError.isEmpty {
                providerErrorBanner(providerPublishError)
            }
            if trackedRevision == nil, let loadError, !loadError.isEmpty {
                trackedRefreshErrorBanner(loadError)
            }
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
                inlineFeedbackByFileID: inlineFeedbackByFileID(for: loaded),
                focusedFeedbackID: focusedFeedbackID,
                inlineFeedbackScrollCommand: inlineFeedbackScrollCommand,
                inlineFeedbackActions: inlineFeedbackActions(for: loaded),
                onSelectInlineFeedback: selectInlineFeedback,
                reviewFeedbackTarget: loaded.feedbackTarget,
                draftCommentsByFileID: ReviewDraftCommentGrouping.commentsByFileID(draftCommentController?.comments ?? []),
                focusedDraftCommentID: focusedDraftCommentID,
                draftCommentScrollCommand: draftCommentScrollCommand,
                draftCommentActions: draftCommentActions(for: loaded),
                onSelectDraftComment: selectDraftComment,
                onSaveDraftComment: saveDraftComment
            )
            .environment(\.reviewDraftSummaryRailStatus, ReviewDraftSummaryRailStatus(record: record))
        }
    }

    private func trackedRefreshErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.color("del"))
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg"))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Retry") {
                loadGeneration += 1
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityIdentifier("review-session-revision-error-retry")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.color("del").opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.color("line"))
                .frame(height: 1)
        }
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "review-session-revision-error",
                label: message
            )
        )
    }

    private func providerErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.color("del"))
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg"))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                providerPublishError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.color("fg-muted"))
            .help("Dismiss")
            .accessibilityIdentifier("review-session-provider-error-dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.color("del").opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.color("line"))
                .frame(height: 1)
        }
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "review-session-provider-error",
                label: message
            )
        )
    }

    private var layoutModeBinding: Binding<DiffLayoutMode> {
        guard let appState else { return $localLayoutMode }
        return DiffPreferenceBindings(
            appState: appState,
            wrapLines: $localWrapLines,
            showWhitespace: $localShowWhitespace
        ).layoutMode
    }

    private var wrapLinesBinding: Binding<Bool> {
        guard let appState else { return $localWrapLines }
        return DiffPreferenceBindings(
            appState: appState,
            wrapLines: $localWrapLines,
            showWhitespace: $localShowWhitespace
        ).wrapLines
    }

    private var showWhitespaceBinding: Binding<Bool> {
        $localShowWhitespace
    }

    private func makeLSPContext(_ file: DiffReviewFileSectionModel) -> DiffPaneLSPContext? {
        guard let appState, let worktree else { return nil }
        let relativePath = file.summary.path
        let fileURL = worktree.path.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let language = appState.lsp.language(forPath: relativePath)
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
        isLoading = loaded == nil
        loadError = nil
        return token
    }

    private func loadReviewSession(token: ReviewSessionTabLoadToken) async -> Bool {
        selectionPersister.flush()
        do {
            guard let storedRecord = try sessionStore.load(id: tabState.sessionID) else {
                throw ReviewSessionTabError.missingSession(tabState.sessionID)
            }

            let resolvedRecord: (record: ReviewSessionRecord, paused: Bool)
            let refreshError: String?
            do {
                resolvedRecord = try await resolveTrackedRecordForLoad(storedRecord)
                refreshError = nil
            } catch {
                guard case .trackedCommit = storedRecord.target.payload else { throw error }
                resolvedRecord = (storedRecord, false)
                refreshError = error.localizedDescription
            }
            guard loadCoordinator.canPublish(token) else { return false }
            var refreshedRecord = mergeLatestMutableFields(into: resolvedRecord.record, fallback: storedRecord)
            if let loaded,
               Self.canReuseLoadedTrackedDiff(
                   loadedTrackedResolvedSHA: loadedTrackedResolvedSHA,
                   refreshedRecord: refreshedRecord
               ) {
                if refreshedRecord.target != storedRecord.target {
                    try sessionStore.save(refreshedRecord)
                }
                record = refreshedRecord
                self.loaded = loaded.replacingFeedbackTarget(for: refreshedRecord.target)
                loadedTrackedResolvedSHA = Self.trackedResolvedSHA(in: refreshedRecord)
                loadError = refreshError
                loadDraftCommentController(for: refreshedRecord)
                isLoading = false
                loadCoordinator.finish(token)
                return true
            }
            if resolvedRecord.paused, refreshedRecord.target != storedRecord.target {
                try sessionStore.save(refreshedRecord)
            }

            let loadedContext = try await loader.load(target: refreshedRecord.target)
            guard loadCoordinator.canPublish(token) else { return false }
            refreshedRecord = mergeLatestMutableFields(into: refreshedRecord, fallback: storedRecord)
            if !resolvedRecord.paused, refreshedRecord.target != storedRecord.target {
                try sessionStore.save(refreshedRecord)
            }

            publishInitialLoad(
                ReviewSessionTabLoadPublication.initial(
                    record: refreshedRecord,
                    loaded: loadedContext
                )
            )
            loadError = refreshError
            loadDraftCommentController(for: refreshedRecord)
            isLoading = false
            loadCoordinator.finish(token)
            return true
        } catch is CancellationError {
            guard loadCoordinator.canPublish(token) else { return false }
            isLoading = false
            loadCoordinator.finish(token)
            return false
        } catch {
            guard loadCoordinator.canPublish(token) else { return false }
            loadError = error.localizedDescription
            isLoading = false
            loadCoordinator.finish(token)
            return true
        }
    }

    private func mergeLatestMutableFields(
        into refreshedRecord: ReviewSessionRecord,
        fallback: ReviewSessionRecord
    ) -> ReviewSessionRecord {
        let latestRecord = (try? sessionStore.load(id: refreshedRecord.id)) ?? fallback
        var merged = refreshedRecord
        merged.selectedFileID = latestRecord.selectedFileID
        merged.focusedCommentID = latestRecord.focusedCommentID
        merged.handoffs = latestRecord.handoffs
        merged.lastSendError = latestRecord.lastSendError
        if Self.trackedResolvedSHA(in: latestRecord) == Self.trackedResolvedSHA(in: refreshedRecord) {
            merged.status = latestRecord.status
            merged.verdict = latestRecord.verdict
            merged.updatedAt = latestRecord.updatedAt
        }
        return merged
    }

    static func canReuseLoadedTrackedDiff(
        loadedTrackedResolvedSHA: String?,
        refreshedRecord: ReviewSessionRecord
    ) -> Bool {
        guard case .trackedCommit = refreshedRecord.target.payload else { return false }
        return loadedTrackedResolvedSHA == trackedResolvedSHA(in: refreshedRecord)
    }

    private static func trackedResolvedSHA(in record: ReviewSessionRecord?) -> String? {
        guard case .trackedCommit(let revision) = record?.target.payload else { return nil }
        return revision.resolvedSHA
    }

    private func resolveTrackedRecordForLoad(
        _ storedRecord: ReviewSessionRecord
    ) async throws -> (record: ReviewSessionRecord, paused: Bool) {
        guard let worktree, case .trackedCommit(let revision) = storedRecord.target.payload else {
            return (storedRecord, false)
        }
        let candidate: TrackedRevisionCandidate
        do {
            candidate = try await TrackedRevisionResolver.live.resolve(
                at: worktree.path,
                target: revision.target
            )
        } catch {
            guard case .stall(let stalled) = TrackedRevisionPolicy.evaluate(current: revision, error: error) else {
                throw error
            }
            let target = storedRecord.target.updatingTrackedRevision(stalled, title: storedRecord.target.title)
            return (
                storedRecord.retargetingCommit(to: target, resolvedSHAChanged: false, now: now()),
                true
            )
        }
        switch TrackedRevisionPolicy.evaluate(current: revision, candidate: candidate) {
        case .unchanged(let updated):
            let target = storedRecord.target.updatingTrackedRevision(updated, title: storedRecord.target.title)
            return (
                storedRecord.retargetingCommit(
                    to: target,
                    resolvedSHAChanged: false,
                    now: now()
                ),
                false
            )
        case .follow(let updated):
            let target = storedRecord.target.updatingTrackedRevision(updated, title: "Review \(updated.target.displayLabel)")
            return (
                storedRecord.retargetingCommit(
                    to: target,
                    resolvedSHAChanged: true,
                    now: now()
                ),
                false
            )
        case .pause(let updated), .stall(let updated):
            let target = storedRecord.target.updatingTrackedRevision(updated, title: storedRecord.target.title)
            return (
                storedRecord.retargetingCommit(
                    to: target,
                    resolvedSHAChanged: false,
                    now: now()
                ),
                true
            )
        }
    }

    private func publishInitialLoad(_ publication: ReviewSessionTabLoadPublication) {
        record = publication.record
        loaded = publication.loaded
        loadedTrackedResolvedSHA = Self.trackedResolvedSHA(in: publication.record)
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

    private func rekeyDraftControllerForCurrentSession() {
        selectionPersister.flush()
        guard persistsState,
              let refreshed = try? sessionStore.load(id: tabState.sessionID)
        else { return }
        record = refreshed
        loadDraftCommentController(for: refreshed)
    }

    private func draftCommentActions(for loaded: ReviewSessionLoadedContext) -> ReviewDraftCommentActions {
        let handoffOriginRecordID = record?.id
        var actions = ReviewDraftWorkspaceActions.make(
            controller: draftCommentController,
            sender: feedbackSender,
            sessionID: tabState.sessionID,
            recordHandoff: { handoff in
                recordSessionHandoff(handoff, originRecordID: handoffOriginRecordID)
            },
            recordSendFailure: { error in
                recordSessionSendFailure(error, originRecordID: handoffOriginRecordID)
            },
            worktreeID: persistsState ? tabState.worktreeId : nil,
            now: now,
            sessionStore: { sessionStore }
        )
        let baseAvailability = actions.availability
        actions.availability = { comment in
            var availability = baseAvailability(comment)
            availability.canPublishProvider = canPublishProvider(comment, in: loaded)
            return availability
        }
        actions.canPublishReview = {
            canPublishProviderReview(in: loaded)
        }
        actions.publishProvider = { comment in
            openProviderPublishConfirmation(commentID: comment.id, loaded: loaded)
        }
        actions.publishReview = {
            openProviderPublishConfirmation(commentID: nil, loaded: loaded)
        }
        return actions
    }

    private func makeProviderMutationController(for loaded: ReviewSessionLoadedContext) -> ProviderReviewMutationController? {
        Self.makeProviderMutationController(
            loaded: loaded,
            draftCommentController: draftCommentController,
            providerRegistry: providerRegistry,
            now: now
        )
    }

    private func canPublishProvider(_ comment: ReviewDraftComment, in loaded: ReviewSessionLoadedContext) -> Bool {
        guard loaded.providerContext != nil else { return false }
        return !ProviderReviewPublishPlanner.publishableDrafts([comment]).isEmpty
    }

    private func canPublishProviderReview(in loaded: ReviewSessionLoadedContext) -> Bool {
        guard let providerContext = loaded.providerContext,
              let provider = providerRegistry.provider(for: providerContext.remote.kind)
        else { return false }
        let capabilities = provider.capabilities
        return capabilities.canComment
            || capabilities.canSubmitReview
            || capabilities.canSubmitReview
    }

    private func openProviderPublishConfirmation(commentID: String?, loaded: ReviewSessionLoadedContext) {
        guard let providerContext = loaded.providerContext,
              let provider = providerRegistry.provider(for: providerContext.remote.kind)
        else { return }
        let comments = providerPublishableComments(commentID: commentID)
        let unpublishableMessages = providerUnpublishableMessages(commentID: commentID)
        guard commentID == nil || !comments.isEmpty || !unpublishableMessages.isEmpty else { return }
        guard !comments.isEmpty
            || !unpublishableMessages.isEmpty
            || provider.capabilities.canSubmitReview
            || provider.capabilities.canSubmitReview
        else { return }
        let allowedDecisions = Self.allowedProviderDecisions(
            commentCount: comments.count,
            capabilities: provider.capabilities
        )
        guard !allowedDecisions.isEmpty else { return }
        selectedProviderDecision = Self.defaultProviderDecision(
            allowedDecisions: allowedDecisions
        )
        providerReviewSummaryBody = ""
        providerPublishError = nil
        providerPublishConfirmation = ProviderReviewPublishConfirmationState(
            commentID: commentID,
            providerName: providerContext.remote.kind.displayName,
            reviewIdentity: providerContext.reviewRequest.displayIdentity,
            commentCount: comments.count,
            unpublishableMessages: unpublishableMessages,
            allowedDecisions: allowedDecisions
        )
    }

    private static func allowedProviderDecisions(
        commentCount: Int,
        capabilities: CodeHostProviderCapabilities
    ) -> [ProviderReviewDecision] {
        var decisions: [ProviderReviewDecision] = []
        if commentCount > 0, capabilities.canComment {
            decisions.append(.comment)
        }
        if capabilities.canSubmitReview {
            decisions.append(.approve)
        }
        if capabilities.canSubmitReview {
            decisions.append(.requestChanges)
        }
        return decisions
    }

    private static func defaultProviderDecision(
        allowedDecisions: [ProviderReviewDecision]
    ) -> ProviderReviewDecision {
        if allowedDecisions.contains(.comment) {
            return .comment
        }
        return allowedDecisions.first ?? .comment
    }

    private func providerPublishableComments(commentID: String?) -> [ReviewDraftComment] {
        let comments = draftCommentController?.comments ?? []
        let filtered = commentID.map { id in comments.filter { $0.id == id } } ?? comments
        return ProviderReviewPublishPlanner.publishableDrafts(filtered)
    }

    private func providerUnpublishableMessages(commentID: String?) -> [String] {
        let comments = draftCommentController?.comments ?? []
        let filtered = commentID.map { id in comments.filter { $0.id == id } } ?? comments
        return ProviderReviewPublishPlanner.unpublishableMessages(filtered)
    }

    @ViewBuilder
    private var providerPublishConfirmationOverlay: some View {
        if let providerPublishConfirmation {
            ZStack {
                theme.color("bg-0").opacity(0.45)
                    .ignoresSafeArea()
                ProviderReviewPublishConfirmationView(
                    providerName: providerPublishConfirmation.providerName,
                    reviewIdentity: providerPublishConfirmation.reviewIdentity,
                    commentCount: providerPublishConfirmation.commentCount,
                    unpublishableMessages: providerPublishConfirmation.unpublishableMessages,
                    allowedDecisions: providerPublishConfirmation.allowedDecisions,
                    selectedDecision: $selectedProviderDecision,
                    summaryBody: $providerReviewSummaryBody,
                    isPublishing: isProviderPublishing,
                    errorMessage: providerPublishError,
                    onCancel: {
                        self.providerPublishConfirmation = nil
                        providerPublishError = nil
                    },
                    onConfirm: {
                        Task { @MainActor in
                            await confirmProviderPublish()
                        }
                    }
                )
            }
        }
    }

    private func confirmProviderPublish() async {
        guard !isProviderPublishing else { return }
        guard let confirmation = providerPublishConfirmation,
              let loaded,
              let providerContext = loaded.providerContext,
              let controller = makeProviderMutationController(for: loaded)
        else { return }

        isProviderPublishing = true
        providerPublishError = nil
        defer { isProviderPublishing = false }

        do {
            guard confirmation.allowedDecisions.contains(selectedProviderDecision) else {
                providerPublishError = "\(selectedProviderDecision.displayName) is not supported by this provider."
                return
            }
            let summaryBody = providerReviewSummaryBody.trimmingCharacters(in: .whitespacesAndNewlines)
            if selectedProviderDecision.requiresSummaryBody, summaryBody.isEmpty {
                providerPublishError = "\(selectedProviderDecision.displayName) requires a review summary."
                return
            }
            let selectedDraftIDs = confirmation.commentID.map { Set([$0]) }
            let result = try await controller.publishReview(
                remote: providerContext.remote,
                reviewRequest: providerContext.reviewRequest,
                decision: selectedProviderDecision,
                summaryBody: summaryBody,
                cwd: record?.target.repositoryPath ?? URL(fileURLWithPath: loaded.feedbackTarget.repositoryPath ?? "/"),
                localDraftIDs: selectedDraftIDs
            )
            replaceProviderReviewRequest(result.refreshedRequest)
            providerPublishConfirmation = nil
            if !result.warnings.isEmpty {
                providerPublishError = result.warnings.joined(separator: "\n")
            }
        } catch {
            providerPublishError = error.localizedDescription
        }
    }

    private func inlineFeedbackByFileID(for loaded: ReviewSessionLoadedContext) -> [DiffReviewFileID: [DiffReviewInlineFeedback]] {
        guard let providerContext = loaded.providerContext else { return [:] }
        return Self.inlineFeedbackByFileID(
            threads: providerContext.reviewRequest.threads,
            files: loaded.session.summary.files,
            providerName: providerContext.remote.kind.displayName
        )
    }

    static func inlineFeedbackByFileID(
        threads: [ReviewThread],
        files: [DiffReviewFileSummary],
        providerName: String
    ) -> [DiffReviewFileID: [DiffReviewInlineFeedback]] {
        var grouped: [DiffReviewFileID: [DiffReviewInlineFeedback]] = [:]
        let matcher = ReviewSessionInlineFeedbackFileMatcher(files: files)
        for thread in threads {
            guard let path = thread.path,
                  let file = matcher.file(forPath: path)
            else { continue }
            let status: ReviewEvidenceStatus
            if thread.isResolved {
                status = .resolved
            } else if thread.isActionable {
                status = .actionable
            } else {
                status = .unknown
            }

            let feedback = DiffReviewInlineFeedback(
                id: thread.id,
                providerName: providerName,
                author: thread.author,
                bodyPreview: String(thread.body.prefix(240)),
                status: status,
                providerURL: thread.url,
                anchor: DiffReviewInlineFeedbackAnchor(
                    path: path,
                    line: thread.line ?? thread.originalLine,
                    side: {
                        if let side = thread.diffSide {
                            return side.uppercased() == "LEFT" ? .old : .new
                        }
                        return thread.line != nil ? .new : thread.originalLine != nil ? .old : .unknown
                    }()
                ),
                evidenceItemID: thread.id
            )
            grouped[file.id, default: []].append(feedback)
        }

        return grouped.mapValues { feedback in
            feedback.sorted { lhs, rhs in
                switch (lhs.anchor.line, rhs.anchor.line) {
                case (nil, nil):
                    return lhs.id < rhs.id
                case (nil, _?):
                    return true
                case (_?, nil):
                    return false
                case (let lhsLine?, let rhsLine?):
                    if lhsLine != rhsLine {
                        return lhsLine < rhsLine
                    }
                    return lhs.id < rhs.id
                }
            }
        }
    }

    static func fileID(
        forFeedbackID feedbackID: String,
        in grouped: [DiffReviewFileID: [DiffReviewInlineFeedback]]
    ) -> DiffReviewFileID? {
        grouped.first { _, items in
            items.contains { $0.id == feedbackID }
        }?.key
    }

    private func inlineFeedbackActions(for loaded: ReviewSessionLoadedContext) -> DiffReviewInlineFeedbackActions {
        var actions = DiffReviewInlineFeedbackActions()
        actions.availability = { item, _ in
            guard let providerContext = loaded.providerContext,
                  let provider = providerRegistry.provider(for: providerContext.remote.kind)
            else { return .none }

            let capabilities = provider.capabilities
            return DiffReviewInlineFeedbackActionAvailability(
                canOpenProvider: item.providerURL != nil,
                canCopyContext: true,
                canSendToAgent: false,
                canReplyProvider: item.status == .actionable && capabilities.canReply,
                canResolveProvider: item.status == .actionable && capabilities.canResolve,
                canUnresolveProvider: item.status == .resolved && capabilities.canResolve
            )
        }
        actions.replyProvider = { item, file, body in
            Task { await mutateProviderThread(item, file: file, loaded: loaded, kind: .reply, body: body) }
        }
        actions.openProvider = { item, _ in
            guard let url = item.providerURL else { return }
            NSWorkspace.shared.open(url)
        }
        actions.copyContext = { item, file in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(
                DiffReviewInlineFeedbackContextFormatter.format(item: item, file: file),
                forType: .string
            )
        }
        actions.resolveProvider = { item, file in
            Task { await mutateProviderThread(item, file: file, loaded: loaded, kind: .resolve, body: nil) }
        }
        actions.unresolveProvider = { item, file in
            Task { await mutateProviderThread(item, file: file, loaded: loaded, kind: .unresolve, body: nil) }
        }
        return actions
    }

    private func mutateProviderThread(
        _ item: DiffReviewInlineFeedback,
        file: DiffReviewFileSummary,
        loaded: ReviewSessionLoadedContext,
        kind: ProviderThreadMutationKind,
        body: String?
    ) async {
        guard let providerContext = loaded.providerContext,
              let controller = makeProviderMutationController(for: loaded)
        else { return }

        do {
            let result = try await controller.mutateThread(
                ProviderThreadMutation(
                    remote: providerContext.remote,
                    reviewRequest: providerContext.reviewRequest,
                    thread: reviewThreadSummary(item, file: file),
                    kind: kind,
                    bodyMarkdown: body,
                    cwd: record?.target.repositoryPath ?? URL(fileURLWithPath: loaded.feedbackTarget.repositoryPath ?? "/")
                )
            )
            replaceProviderReviewRequest(result.refreshedRequest)
            providerPublishError = result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n")
        } catch {
            providerPublishError = error.localizedDescription
        }
    }

    private func reviewThreadSummary(
        _ item: DiffReviewInlineFeedback,
        file: DiffReviewFileSummary
    ) -> ReviewThreadSummary {
        ReviewThreadSummary(
            id: item.id,
            author: item.author,
            body: item.bodyPreview,
            url: item.providerURL,
            isResolved: item.status == .resolved,
            isActionable: item.status == .actionable,
            location: ReviewThreadLocation(
                path: item.anchor.path,
                originalPath: file.originalPath,
                line: item.anchor.line,
                side: ReviewThreadSide(item.anchor.side),
                providerPosition: nil
            ),
            providerThreadID: item.id,
            providerCommentID: nil
        )
    }

    private func replaceProviderReviewRequest(_ reviewRequest: ReviewRequest) {
        guard let current = loaded,
              let providerContext = current.providerContext
        else { return }
        loaded = ReviewSessionLoadedContext(
            session: current.session,
            feedbackTarget: current.feedbackTarget,
            providerContext: ReviewSessionProviderContext(
                remote: providerContext.remote,
                reviewRequest: reviewRequest
            )
        )
    }

    static func makeProviderMutationController(
        loaded: ReviewSessionLoadedContext,
        draftCommentController: ReviewDraftCommentController?,
        providerRegistry: CodeHostProviderRegistry,
        now: @escaping () -> Date
    ) -> ProviderReviewMutationController? {
        guard let providerContext = loaded.providerContext,
              let draftCommentController,
              let provider = providerRegistry.provider(for: providerContext.remote.kind)
        else { return nil }

        return ProviderReviewMutationController(
            provider: provider,
            draftController: draftCommentController,
            now: now
        )
    }

    private func recordSessionHandoff(_ handoff: ReviewFeedbackHandoff, originRecordID: ReviewSessionID?) {
        record = ReviewSessionHandoffPersistence.record(
            handoff,
            currentRecord: record,
            originRecordID: originRecordID,
            sessionStore: sessionStore,
            persistsState: persistsState,
            now: now
        )
    }

    private func recordSessionSendFailure(_ error: Error, originRecordID: ReviewSessionID?) {
        guard let visibleRecord = record else { return }
        record = ReviewSessionHandoffPersistence.recordSendFailure(
            error,
            currentRecord: visibleRecord,
            originRecordID: originRecordID,
            sessionStore: sessionStore,
            persistsState: persistsState,
            now: now
        )
    }

    private func selectDraftComment(_ comment: ReviewDraftComment) {
        setFocusedDraftCommentID(comment.id, persist: true)
        setSelectedFileID(comment.fileID, persist: true)
        draftCommentScrollCommand = draftCommentScrollController.command(
            commentID: comment.id,
            fileID: comment.fileID
        )
    }

    private func selectInlineFeedback(_ item: DiffReviewInlineFeedback) {
        guard let loaded else { return }
        let grouped = inlineFeedbackByFileID(for: loaded)
        guard let fileID = Self.fileID(forFeedbackID: item.id, in: grouped) else { return }
        focusedFeedbackID = item.id
        setSelectedFileID(fileID, persist: true)
        inlineFeedbackScrollCommand = inlineFeedbackScrollController.command(
            feedbackID: item.id,
            fileID: fileID
        )
    }

    private func saveDraftComment(
        fileID: DiffReviewFileID,
        originalPath: String?,
        anchor: DiffReviewLineAnchor,
        body: String
    ) {
        do {
            try draftCommentController?.add(anchor: anchor, fileID: fileID, originalPath: originalPath, bodyMarkdown: body)
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
        record = current.selectingFile(fileID, now: now())
        guard persistsState else { return }
        // Scroll-spy selection changes arrive on every file boundary crossed
        // during a fling; a synchronous write here (snapshot decode + two
        // JSON encodes + two atomic replaces) stalls the scroll.
        //
        // The write must not save the in-memory `record` wholesale: another
        // path (e.g. AppState.persistReviewRetargeting) can replace this
        // session's stored record — even under a new id — while our write is
        // still pending, and `record` won't reflect that until this view's
        // own load cycle runs. Saving it as-is would either clobber the
        // fresher target/handoffs or, if the id changed, resurrect the
        // record `replace` just removed. Reload the latest stored record at
        // flush time and merge only the selection onto it instead.
        //
        // The selection itself must come from this call's `fileID`
        // parameter, not from reading `record` at flush time: a handoff or
        // send failure completing during the debounce window reassigns
        // `record` from a fresh disk load (`ReviewSessionHandoffPersistence`
        // prefers disk over the in-memory value), which would revert
        // `record.selectedFileID` to whatever was on disk before this write
        // flushes — silently losing the user's latest selection.
        let sessionID = current.id
        selectionPersister.schedule {
            guard let latest = try? sessionStore.load(id: sessionID) else { return }
            let merged = Self.mergingSelectedFile(into: latest, fileID: fileID, now: now())
            do {
                try sessionStore.save(merged)
            } catch {
                loadError = error.localizedDescription
            }
            updateTabState { state in
                state.selectedFileID = merged.selectedFileID
            }
        }
    }

    static func mergingSelectedFile(
        into latest: ReviewSessionRecord,
        fileID: DiffReviewFileID?,
        now: Date
    ) -> ReviewSessionRecord {
        guard latest.selectedFileID != fileID else { return latest }
        return latest.selectingFile(fileID, now: now)
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

enum ReviewSessionHandoffPersistence {
    @MainActor
    static func record(
        _ handoff: ReviewFeedbackHandoff,
        currentRecord: ReviewSessionRecord?,
        originRecordID: ReviewSessionID? = nil,
        sessionStore: ReviewSessionStore,
        persistsState: Bool,
        now: () -> Date
    ) -> ReviewSessionRecord? {
        guard persistsState else {
            return currentRecord?.recording(handoff: handoff)
        }

        do {
            let current = try operationRecord(
                sessionID: handoff.sessionID,
                currentRecord: currentRecord,
                originRecordID: originRecordID,
                sessionStore: sessionStore
            )
            guard let current else { return nil }
            let updated = current.recording(handoff: handoff)
            try sessionStore.save(updated)
            return updated
        } catch {
            guard var visibleRecord = currentRecord else { return nil }
            visibleRecord.lastSendError = "Sent to agent, but failed to save handoff record: \(error.localizedDescription)"
            visibleRecord.updatedAt = now()
            return visibleRecord
        }
    }

    @MainActor
    static func recordSendFailure(
        _ error: Error,
        currentRecord: ReviewSessionRecord,
        originRecordID: ReviewSessionID? = nil,
        sessionStore: ReviewSessionStore,
        persistsState: Bool,
        now: () -> Date
    ) -> ReviewSessionRecord {
        let sessionID = originRecordID ?? currentRecord.id
        let current = (try? operationRecord(
            sessionID: sessionID,
            currentRecord: currentRecord,
            originRecordID: originRecordID,
            sessionStore: sessionStore
        )) ?? currentRecord
        var updated = current
        updated.lastSendError = "Failed to send to agent: \(error.localizedDescription)"
        updated.updatedAt = now()
        guard persistsState else { return updated }
        do {
            try sessionStore.save(updated)
        } catch {
            // Visible send failure state is already set; failure to persist that state is non-blocking.
        }
        return updated
    }

    private static func operationRecord(
        sessionID: ReviewSessionID,
        currentRecord: ReviewSessionRecord?,
        originRecordID: ReviewSessionID?,
        sessionStore: ReviewSessionStore
    ) throws -> ReviewSessionRecord? {
        let direct = try sessionStore.load(id: sessionID)
        let replacement = try sessionStore.loadReplacement(for: sessionID)
        if let currentRecord {
            if currentRecord.id == originRecordID || currentRecord.id == sessionID {
                return direct ?? currentRecord
            }
            if currentRecord.id == replacement?.id {
                return replacement
            }
        }
        return replacement ?? direct ?? currentRecord
    }
}

struct ReviewSessionInlineFeedbackFileMatcher {
    private let filesByPath: [String: DiffReviewFileSummary]
    private let filesByOriginalPath: [String: DiffReviewFileSummary]

    init(files: [DiffReviewFileSummary]) {
        self.filesByPath = Self.uniqueFiles(files) { $0.path }
        self.filesByOriginalPath = Self.uniqueFiles(
            files.compactMap { file in file.originalPath == nil ? nil : file },
            keyedBy: { $0.originalPath }
        )
    }

    func file(forPath path: String) -> DiffReviewFileSummary? {
        filesByPath[path] ?? filesByOriginalPath[path]
    }

    func file(for location: ReviewThreadLocation) -> DiffReviewFileSummary? {
        switch location.side {
        case .new:
            return filesByPath[location.path]
                ?? location.originalPath.flatMap { filesByOriginalPath[$0] }
                ?? filesByOriginalPath[location.path]
        case .old:
            if let originalPath = location.originalPath, originalPath != location.path {
                return filesByOriginalPath[originalPath]
                    ?? filesByPath[location.path]
                    ?? filesByOriginalPath[location.path]
            }
            return filesByPath[location.path]
                ?? filesByOriginalPath[location.path]
        case .unknown:
            return filesByPath[location.path]
                ?? location.originalPath.flatMap { filesByOriginalPath[$0] }
                ?? filesByOriginalPath[location.path]
        }
    }

    private static func uniqueFiles(
        _ files: [DiffReviewFileSummary],
        keyedBy key: (DiffReviewFileSummary) -> String?
    ) -> [String: DiffReviewFileSummary] {
        var counts: [String: Int] = [:]
        var matches: [String: DiffReviewFileSummary] = [:]
        for file in files {
            guard let value = key(file), !value.isEmpty else { continue }
            counts[value, default: 0] += 1
            matches[value] = file
        }
        return matches.filter { counts[$0.key] == 1 }
    }
}

private extension DiffReviewInlineFeedbackSide {
    init(_ side: ReviewThreadSide) {
        switch side {
        case .old:
            self = .old
        case .new:
            self = .new
        case .unknown:
            self = .unknown
        }
    }
}

private extension ReviewThreadSide {
    init(_ side: DiffReviewInlineFeedbackSide) {
        switch side {
        case .old:
            self = .old
        case .new:
            self = .new
        case .unknown:
            self = .unknown
        }
    }
}

private extension ProviderReviewDecision {
    var displayName: String {
        switch self {
        case .comment:
            "Comment"
        case .approve:
            "Approve"
        case .requestChanges:
            "Request changes"
        }
    }
}
