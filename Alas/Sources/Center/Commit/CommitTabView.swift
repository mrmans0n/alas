// Alas/Sources/Center/Commit/CommitTabView.swift
import SwiftUI

struct CommitTabView: View {
    let worktreePath: URL
    let tabState: CommitTabState
    let worktreeId: String
    @Bindable var appState: AppState

    @State private var details: CommitDetails?
    @State private var loadingDetails = true
    @State private var detailsError: String?
    @State private var activeDetailsKey: String?
    @State private var activeDetailsID = UUID()

    @State private var reviewSession: DiffReviewLoadedSession?
    @State private var loadingReviewSession = false
    @State private var reviewSessionError: String?
    @State private var selectedReviewFileID: DiffReviewFileID?
    @State private var railCollapsed = false
    @State private var activeReviewKey: String?
    @State private var activeReviewID = UUID()

    @State private var headerExpanded: Bool = false
    @State private var reviewSessionLaunchError: String?
    @State private var wrapLines = false
    @State private var showWhitespace = false
    @State private var isRefreshingTrackedRevision = false

    @Environment(\.theme) private var theme
    private let git = GitService()
    private let reviewLoader = CommitReviewLoader()
    private let revisionResolver = TrackedRevisionResolver.live

    private var sha: String { tabState.sha }

    private var loadTaskID: String {
        if let tracked = tabState.revision.tracked {
            return "\(tabState.id):\(tracked.expression):\(appState.revisionChangeGeneration(worktreeID: worktreeId))"
        }
        return "\(tabState.id):\(sha)"
    }

    private var diffPreferences: DiffPreferenceBindings {
        DiffPreferenceBindings(
            appState: appState,
            wrapLines: $wrapLines,
            showWhitespace: $showWhitespace
        )
    }

    static func reviewSessionTarget(
        worktreeID: String,
        repositoryPath: URL,
        sha: String,
        title: String
    ) -> ReviewSessionTarget {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionTitle = trimmedTitle.isEmpty ? "Review \(String(sha.prefix(10)))" : "Review \(trimmedTitle)"
        return ReviewSessionTarget.commit(
            worktreeID: worktreeID,
            repositoryPath: repositoryPath,
            sha: sha,
            title: sessionTitle
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let details {
                CommitHeaderView(
                    details: details,
                    expanded: $headerExpanded,
                    trackedRevision: tabState.revision.tracked,
                    worktreeID: worktreeId,
                    tabID: tabState.id,
                    appState: appState,
                    isRefreshingRevision: isRefreshingTrackedRevision,
                    revisionError: detailsError,
                    onAcceptPendingCheckout: acceptPendingCheckout,
                    onRetryRevision: retryRevisionRefresh
                )
                commitReviewContent(details: details)
            } else if loadingDetails {
                Spinner()
                    .frame(width: 20, height: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detailsError {
                VStack(spacing: 8) {
                    Text("Could not load commit \(String(sha.prefix(7)))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.color("del"))
                    Text(detailsError)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-dim"))
                    AlasButton(title: "Retry", style: .subtle) {
                        Task { await loadDetails() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .task(id: loadTaskID) { await loadDetails() }
    }

    @ViewBuilder
    private func commitReviewContent(details: CommitDetails) -> some View {
        let contentState = CommitReviewContentState.resolve(
            detailsFileCount: details.files.count,
            loadingReviewSession: loadingReviewSession,
            reviewSessionFileCount: reviewSession?.files.count,
            reviewSessionError: reviewSessionError
        )

        switch contentState {
        case .loading:
            Spinner()
                .frame(width: 20, height: 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error:
            VStack(spacing: 8) {
                Text("Could not load commit diffs")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.color("del"))
                Text(reviewSessionError ?? "")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                AlasButton(title: "Retry", style: .subtle) {
                    Task { await loadDetails() }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if let reviewSession {
                VStack(spacing: 0) {
                    commitReviewHeader(details: details)
                    Divider().overlay(theme.color("line"))
                    CommitReviewBody(
                        session: reviewSession,
                        selectedFileID: $selectedReviewFileID,
                        railCollapsed: $railCollapsed,
                        layoutMode: diffPreferences.layoutMode,
                        wrapLines: diffPreferences.wrapLines,
                        showWhitespace: diffPreferences.showWhitespace,
                        codeFontFamily: appState.config.code.fontFamily,
                        codeFontSize: CGFloat(appState.config.code.fontSize),
                        worktreeId: worktreeId,
                        worktreePath: worktreePath,
                        allowsReviewing: false,
                        appState: appState
                    )
                }
            } else {
                Spinner()
                    .frame(width: 20, height: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .empty:
            Text("No files changed in this commit")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.color("fg-dim"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func commitReviewHeader(details: CommitDetails) -> some View {
        HStack(spacing: 8) {
            Text("Commit review")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Text(details.info.shortSha)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.color("fg-dim"))
            Spacer()
            if let reviewSessionLaunchError {
                Text(reviewSessionLaunchError)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("del"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            AlasButton(title: "Review This Commit", icon: "doc.text.magnifyingglass") {
                openReviewSession(
                    target: Self.reviewSessionTarget(
                        worktreeID: worktreeId,
                        repositoryPath: worktreePath,
                        sha: details.info.sha,
                        title: details.info.subject
                    )
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.color("bg-2"))
    }

    private func loadDetails() async {
        let requestedToken = CommitReviewLoadToken.next(key: loadTaskID)
        activeDetailsKey = requestedToken.key
        activeDetailsID = requestedToken.id
        let preservesCurrentSnapshot = CommitReviewLoadIdentity.preservesPublishedSession(
            details: details,
            sha: tabState.sha,
            hasReviewSession: reviewSession != nil
        )
        let isTrackedRefresh = (tabState.revision.tracked != nil || preservesCurrentSnapshot) && details != nil
        loadingDetails = details == nil
        isRefreshingTrackedRevision = isTrackedRefresh
        detailsError = nil
        if details == nil {
            reviewSession = nil
        }
        reviewSessionError = nil
        if details == nil {
            selectedReviewFileID = nil
        }
        activeReviewKey = nil
        activeReviewID = UUID()
        loadingReviewSession = false
        headerExpanded = true
        defer {
            if requestedToken.isActive(activeKey: activeDetailsKey, activeID: activeDetailsID) {
                loadingDetails = false
                isRefreshingTrackedRevision = false
            }
        }
        do {
            let resolved: (
                sha: String,
                trackedRevision: TrackedRevision?,
                reusesCurrentSnapshot: Bool
            )
            let refreshError: String?
            do {
                resolved = try await resolvedRevisionForLoad()
                refreshError = nil
            } catch {
                guard case .following(let tracked) = tabState.revision else { throw error }
                resolved = (tracked.resolvedSHA, nil, false)
                refreshError = error.localizedDescription
            }
            guard !Task.isCancelled, requestedToken.isActive(activeKey: activeDetailsKey, activeID: activeDetailsID) else { return }
            if resolved.reusesCurrentSnapshot {
                if let tracked = resolved.trackedRevision {
                    appState.tabs.updateCommit(worktreeId: worktreeId, tabId: tabState.id) {
                        $0.revision = .following(tracked)
                    }
                }
                return
            }
            let d = try await git.commitDetails(at: worktreePath, sha: resolved.sha)
            guard !Task.isCancelled, requestedToken.isActive(activeKey: activeDetailsKey, activeID: activeDetailsID) else { return }
            let loaded = try await loadReviewSession(
                details: d,
                sha: resolved.sha,
                preservesPublishedSession: isTrackedRefresh
            )
            guard !Task.isCancelled, requestedToken.isActive(activeKey: activeDetailsKey, activeID: activeDetailsID) else { return }
            self.details = d
            detailsError = refreshError
            publishReviewSession(loaded, preservingSelectionByPathFrom: selectedReviewFileID)
            if let tracked = resolved.trackedRevision {
                appState.tabs.updateCommit(worktreeId: worktreeId, tabId: tabState.id) {
                    $0.revision = .following(tracked)
                    $0.title = d.info.subject
                }
            }
        } catch {
            guard !Task.isCancelled, requestedToken.isActive(activeKey: activeDetailsKey, activeID: activeDetailsID) else { return }
            self.detailsError = (error as NSError).localizedDescription
        }
    }

    private func resolvedRevisionForLoad() async throws -> (
        sha: String,
        trackedRevision: TrackedRevision?,
        reusesCurrentSnapshot: Bool
    ) {
        guard case .following(let tracked) = tabState.revision else {
            return (tabState.sha, nil, false)
        }
        let candidate = try await revisionResolver.resolve(at: worktreePath, expression: tracked.expression)
        switch TrackedRevisionPolicy.evaluate(current: tracked, candidate: candidate) {
        case .unchanged(let revision):
            let canReuseSnapshot = details?.info.sha == revision.resolvedSHA && reviewSession != nil
            return (revision.resolvedSHA, revision, canReuseSnapshot)
        case .follow(let revision):
            return (revision.resolvedSHA, revision, false)
        case .pause(let revision):
            appState.tabs.updateCommit(worktreeId: worktreeId, tabId: tabState.id) {
                $0.revision = .following(revision)
            }
            return (tracked.resolvedSHA, nil, false)
        }
    }

    private func loadReviewSession(
        details: CommitDetails,
        sha: String,
        preservesPublishedSession: Bool = false
    ) async throws -> DiffReviewLoadedSession {
        let requestedToken = CommitReviewLoadToken.next(key: reviewKey(details: details, sha: sha))
        activeReviewKey = requestedToken.key
        activeReviewID = requestedToken.id
        if !preservesPublishedSession {
            loadingReviewSession = true
            reviewSession = nil
        }
        reviewSessionError = nil
        defer {
            if requestedToken.isActive(activeKey: activeReviewKey, activeID: activeReviewID) {
                if !preservesPublishedSession {
                    loadingReviewSession = false
                }
                activeReviewKey = nil
            }
        }
        do {
            let loaded = try await reviewLoader.load(
                worktreePath: worktreePath,
                sha: sha,
                files: details.files,
                openFileForPath: openFileAction(for:)
            )
            guard
                !Task.isCancelled,
                requestedToken.isActive(activeKey: activeReviewKey, activeID: activeReviewID)
            else { throw CancellationError() }
            return loaded
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard
                !Task.isCancelled,
                requestedToken.isActive(activeKey: activeReviewKey, activeID: activeReviewID)
            else { throw CancellationError() }
            if !preservesPublishedSession {
                reviewSessionError = (error as NSError).localizedDescription
            }
            throw error
        }
    }

    private func publishReviewSession(
        _ loaded: DiffReviewLoadedSession,
        preservingSelectionByPathFrom previousSelection: DiffReviewFileID?
    ) {
        reviewSession = loaded
        selectedReviewFileID = previousSelection.flatMap { selected in
            loaded.summary.files.first { $0.path == selected.path }?.id
        } ?? loaded.summary.files.first?.id
    }

    private func openFileAction(for path: String) -> (() -> Void)? {
        guard DiffOpenFileAvailability.isAvailable(worktreePath: worktreePath, relativePath: path) else {
            return nil
        }
        return {
            Task { @MainActor in
                appState.openFile(relativePath: path, worktreeId: worktreeId)
            }
        }
    }

    private func reviewKey(details: CommitDetails, sha: String) -> String {
        let fileKey = details.files
            .map { file in
                [
                    file.path,
                    file.originalPath ?? "",
                    file.status,
                    "\(file.add)",
                    "\(file.del)",
                ].joined(separator: "\u{1f}")
            }
            .joined(separator: "\u{1e}")
        return "\(sha)\u{0}\(details.info.sha)\u{0}\(details.files.count)\u{0}\(fileKey)"
    }

    @MainActor
    private func openReviewSession(target: ReviewSessionTarget) {
        let store = ReviewSessionStore()
        ReviewSessionLauncher.openOrFocus(
            target: target,
            findActive: { try store.findActive(targetID: $0) },
            save: { try store.save($0) },
            open: {
                reviewSessionLaunchError = nil
                appState.tabs.openOrFocusReviewSession(worktreeId: worktreeId, record: $0)
            },
            onFailure: { reviewSessionLaunchError = $0.localizedDescription }
        )
    }

    @MainActor
    private func acceptPendingCheckout() {
        appState.acceptTrackedRevisionCheckout(worktreeID: worktreeId, tabID: tabState.id)
    }

    private func retryRevisionRefresh() {
        Task { await loadDetails() }
    }
}

struct CommitReviewLoadToken: Equatable {
    let key: String
    let id: UUID

    static func next(key: String) -> CommitReviewLoadToken {
        CommitReviewLoadToken(key: key, id: UUID())
    }

    func isActive(activeKey: String?, activeID: UUID) -> Bool {
        activeKey == key && activeID == id
    }
}

enum CommitReviewLoadIdentity {
    static func isCurrent(details: CommitDetails, currentDetails: CommitDetails?, sha: String) -> Bool {
        details.info.sha == sha && currentDetails?.info.sha == details.info.sha
    }

    static func preservesPublishedSession(details: CommitDetails?, sha: String, hasReviewSession: Bool) -> Bool {
        details?.info.sha == sha && hasReviewSession
    }
}

enum CommitReviewContentState: Equatable {
    case loading
    case error
    case loaded
    case empty

    static func resolve(
        detailsFileCount: Int,
        loadingReviewSession: Bool,
        reviewSessionFileCount: Int?,
        reviewSessionError: String?
    ) -> CommitReviewContentState {
        if loadingReviewSession {
            return .loading
        }
        if reviewSessionError != nil {
            return .error
        }
        if let reviewSessionFileCount {
            return reviewSessionFileCount > 0 ? .loaded : .empty
        }
        return detailsFileCount > 0 ? .loading : .empty
    }
}

struct CommitReviewBody: View {
    let session: DiffReviewLoadedSession
    @Binding var selectedFileID: DiffReviewFileID?
    @Binding var railCollapsed: Bool
    @Binding var layoutMode: DiffLayoutMode
    @Binding var wrapLines: Bool
    @Binding var showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat
    var worktreeId: String? = nil
    var worktreePath: URL? = nil
    var reviewDraftSessionID: ReviewDraftSessionID? = nil
    var reviewedCommitSHA: String? = nil
    var allowsReviewing = true
    var appState: AppState? = nil

    @State private var reviewSummaryCollapsed = false
    @State private var draftCommentController: ReviewDraftCommentController?
    @State private var loadedDraftSessionID: ReviewDraftSessionID?
    @State private var focusedDraftCommentID: String?
    @State private var draftCommentScrollCommand: DiffReviewDraftCommentScrollCommand?
    @State private var draftCommentScrollController = DiffReviewDraftCommentScrollController()

    init(
        session: DiffReviewLoadedSession,
        selectedFileID: Binding<DiffReviewFileID?>,
        railCollapsed: Binding<Bool>,
        layoutMode: Binding<DiffLayoutMode>,
        wrapLines: Binding<Bool>,
        showWhitespace: Binding<Bool>,
        codeFontFamily: String,
        codeFontSize: CGFloat,
        worktreeId: String? = nil,
        worktreePath: URL? = nil,
        reviewDraftSessionID: ReviewDraftSessionID? = nil,
        reviewedCommitSHA: String? = nil,
        allowsReviewing: Bool = true,
        appState: AppState? = nil
    ) {
        self.session = session
        self._selectedFileID = selectedFileID
        self._railCollapsed = railCollapsed
        self._layoutMode = layoutMode
        self._wrapLines = wrapLines
        self._showWhitespace = showWhitespace
        self.codeFontFamily = codeFontFamily
        self.codeFontSize = codeFontSize
        self.worktreeId = worktreeId
        self.worktreePath = worktreePath
        self.reviewDraftSessionID = reviewDraftSessionID
        self.reviewedCommitSHA = reviewedCommitSHA
        self.allowsReviewing = allowsReviewing
        self.appState = appState
    }

    static func reviewDraftSessionID(
        worktreeID: String,
        repositoryPath: URL,
        sha: String
    ) -> ReviewDraftSessionID {
        ReviewDraftSessionID.commit(
            worktreeID: worktreeID,
            repositoryPath: repositoryPath,
            sha: sha
        )
    }

    static func reviewFeedbackTarget(repositoryPath: URL, sha: String?) -> ReviewFeedbackTarget {
        let trimmedSHA = sha?.trimmingCharacters(in: .whitespacesAndNewlines)
        let commitDescription = trimmedSHA.flatMap { $0.isEmpty ? nil : $0 }
        let shortSHA = commitDescription.map { String($0.prefix(10)) }
        return ReviewFeedbackTarget(
            title: shortSHA.map { "Commit Review \($0)" } ?? "Commit Review",
            repositoryPath: repositoryPath.path,
            providerDescription: nil,
            sourceDescription: commitDescription.map { "Commit \($0)" } ?? "Commit"
        )
    }

    var body: some View {
        DiffReviewSurface(
            session: session,
            selectedFileID: $selectedFileID,
            railCollapsed: $railCollapsed,
            reviewSummaryCollapsed: $reviewSummaryCollapsed,
            layoutMode: $layoutMode,
            wrapLines: $wrapLines,
            showWhitespace: $showWhitespace,
            codeFontFamily: codeFontFamily,
            codeFontSize: codeFontSize,
            showsSourceBadges: false,
            showsRailDisplayControls: true,
            showsDraftSummaryRail: effectiveReviewDraftSessionID != nil,
            allowsDraftCommentCreation: effectiveReviewDraftSessionID != nil,
            lspContextForFile: { file in
                makeLSPContext(relativePath: file.summary.path)
            },
            reviewFeedbackTarget: reviewFeedbackTarget,
            draftCommentsByFileID: effectiveDraftCommentsByFileID,
            focusedDraftCommentID: focusedDraftCommentID,
            draftCommentScrollCommand: draftCommentScrollCommand,
            draftCommentActions: effectiveDraftCommentActions,
            onSelectDraftComment: selectDraftComment,
            onSaveDraftComment: { fileID, originalPath, anchor, body in
                saveDraftComment(fileID: fileID, originalPath: originalPath, anchor: anchor, body: body)
            }
        )
        .accessibilityIdentifier("commit-review-body")
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "commit-review-body",
                label: "Commit review"
            )
        )
        .onAppear {
            loadDraftCommentController()
        }
        .onChange(of: effectiveReviewDraftSessionID?.rawValue) { _, _ in
            loadDraftCommentController()
        }
    }

    private var effectiveReviewDraftSessionID: ReviewDraftSessionID? {
        allowsReviewing ? reviewDraftSessionID : nil
    }

    private var reviewFeedbackTarget: ReviewFeedbackTarget? {
        guard allowsReviewing else { return nil }
        guard let worktreePath else { return nil }
        return Self.reviewFeedbackTarget(repositoryPath: worktreePath, sha: reviewedCommitSHA)
    }

    private var effectiveDraftCommentsByFileID: [DiffReviewFileID: [ReviewDraftComment]] {
        guard allowsReviewing else { return [:] }
        return ReviewDraftCommentGrouping.commentsByFileID(draftCommentController?.comments ?? [])
    }

    private var effectiveDraftCommentActions: ReviewDraftCommentActions {
        guard allowsReviewing else { return ReviewDraftCommentActions() }
        return draftCommentActions()
    }

    private func makeLSPContext(relativePath: String) -> DiffPaneLSPContext? {
        guard let worktreeId, let worktreePath, let appState else { return nil }
        let fileURL = worktreePath.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let language = appState.lsp.language(forFileExtension: (relativePath as NSString).pathExtension)
        else {
            return nil
        }
        return DiffPaneLSPContext(
            worktreeId: worktreeId,
            worktreeRoot: worktreePath,
            relativePath: relativePath,
            language: language,
            lsp: appState.lsp,
            openTarget: { url, line, character in
                openLSPTarget(
                    url: url,
                    worktreeId: worktreeId,
                    worktreePath: worktreePath,
                    appState: appState,
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
        worktreeId: String,
        worktreePath: URL,
        appState: AppState,
        originatingRelativePath: String,
        language: String,
        line: Int,
        character: Int
    ) {
        let prefix = worktreePath.path + "/"
        if url.path.hasPrefix(prefix) {
            let relativeTarget = String(url.path.dropFirst(prefix.count))
            appState.tabs.openEditor(
                worktreeId: worktreeId,
                relativePath: relativeTarget,
                revealLine: line,
                revealCharacter: character
            )
        } else {
            appState.tabs.openExternalEditor(
                worktreeId: worktreeId,
                absoluteURL: url,
                revealLine: line,
                revealCharacter: character,
                originatingRelativePath: originatingRelativePath,
                originatingWorktreeRoot: worktreePath,
                language: language
            )
        }
    }

    private var reviewFeedbackAgentSender: ReviewFeedbackAgentSender? {
        guard let appState, let worktreeId else { return nil }
        return ReviewFeedbackAgentSender.production(appState: appState, worktreeID: worktreeId)
    }

    private func loadDraftCommentController() {
        guard let sessionID = effectiveReviewDraftSessionID else {
            draftCommentController = nil
            loadedDraftSessionID = nil
            focusedDraftCommentID = nil
            draftCommentScrollCommand = nil
            return
        }
        if loadedDraftSessionID != sessionID {
            draftCommentController = ReviewDraftCommentController(sessionID: sessionID)
            loadedDraftSessionID = sessionID
            focusedDraftCommentID = nil
            draftCommentScrollCommand = nil
        }
        do {
            try draftCommentController?.load()
        } catch {
            // The controller keeps the non-blocking error state for the review rail.
        }
    }

    private func draftCommentActions() -> ReviewDraftCommentActions {
        guard let reviewFeedbackAgentSender else {
            return ReviewDraftCommentActions()
        }
        return ReviewDraftWorkspaceActions.make(
            controller: draftCommentController,
            sender: reviewFeedbackAgentSender,
            worktreeID: worktreeId
        )
    }

    private func selectDraftComment(_ comment: ReviewDraftComment) {
        focusedDraftCommentID = comment.id
        selectedFileID = comment.fileID
        draftCommentScrollCommand = draftCommentScrollController.command(
            commentID: comment.id,
            fileID: comment.fileID
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
            // The controller keeps the non-blocking error state for the review rail.
        }
    }
}
