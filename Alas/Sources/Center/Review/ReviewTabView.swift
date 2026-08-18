import AppKit
import SwiftUI

enum ReviewTabLoadingPresentation {
    static func showsBlockingLoader(isLoading: Bool, hasSession: Bool) -> Bool {
        isLoading && !hasSession
    }

    static func showsLoadError(loadError: String?, isLoading: Bool, hasSession: Bool) -> Bool {
        loadError != nil && !showsBlockingLoader(isLoading: isLoading, hasSession: hasSession)
    }
}

enum ReviewTabPendingReviewPresentation {
    static func showsRail(stagedCount: Int, loadedFileCount: Int?) -> Bool {
        loadedFileCount != nil && stagedCount > 0
    }

    static func showsToolbarFinishButton(canSubmitReview: Bool, hasPendingReviewScope: Bool) -> Bool {
        canSubmitReview && hasPendingReviewScope
    }
}

enum ReviewTabStartupRecoveryReadiness {
    static func reviewRefreshSettled(
        hasSnapshot: Bool,
        isRefreshing: Bool,
        hasError: Bool
    ) -> Bool {
        !isRefreshing && (hasSnapshot || hasError)
    }

    static func shouldComplete(hasReviewRequest: Bool, reviewRefreshSettled: Bool) -> Bool {
        hasReviewRequest || reviewRefreshSettled
    }
}

struct ReviewTabView: View {
    let worktree: Worktree
    let tabState: ReviewPRTabState
    let appState: AppState
    var onStartupRecoveryReady: () -> Void = {}
    // Loads the working-tree diff (same as ReviewChangesTabView). To show PR base..head diff
    // instead, inject a PR-diff loader here when that loader exists.
    var loader: ReviewChangesLoader = ReviewChangesLoader()

    @Environment(\.theme) private var theme
    @State private var session: ReviewChangesLoadedSession?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedFileID: ReviewChangesFileID?
    @State private var railCollapsed = false
    @State private var activeLoadKey: String?
    @State private var activeLoadID = UUID()
    @State private var localThreads: [ReviewThread] = []
    @State private var annotations: [CheckAnnotation] = []
    @State private var isWriting = false
    @State private var errorMessage: String? = nil
    @State private var pendingReview: PendingReview?
    @State private var pendingReviewRailCollapsed = false
    @State private var showVerdictSheet = false
    @State private var wrapLines = false
    @State private var showWhitespace = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar
                Divider().overlay(theme.color("line"))
                CIStatusStrip(checks: reviewRequest?.checks ?? [], onExpand: { check in
                    Task { await fetchAnnotations(for: check) }
                })
                OutdatedThreadsDrawer(
                    threads: outdatedAndFileLevelThreads,
                    maxExpandedListHeight: OutdatedThreadsDrawerPresentation.expandedListMaxHeight(
                        availableHeight: geometry.size.height
                    )
                )
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.color("bg-1"))
        .overlay(alignment: .bottom) {
            if let msg = errorMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.2), value: errorMessage)
            }
        }
        .sheet(isPresented: $showVerdictSheet) {
            VerdictSheet(
                pendingCount: pendingReview?.staged.count ?? 0,
                onSubmit: { verdict, body in
                    submitReviewAction(verdict: verdict, body: body)
                },
                onCancel: {
                    showVerdictSheet = false
                }
            )
        }
        .task(id: loadKey) {
            let completesStartupRecovery = ReviewTabStartupRecoveryReadiness.shouldComplete(
                hasReviewRequest: reviewRequest != nil,
                reviewRefreshSettled: reviewRefreshSettled
            )
            await reload(completingStartupRecovery: completesStartupRecovery)
        }
        .task(id: reviewRequest?.number) {
            // Re-scope PendingReview and reload when the PR number first arrives (snapshot
            // may populate after the loadKey task has already run with prNumber: nil).
            guard reviewRequest != nil else { return }
            await reload(completingStartupRecovery: true)
        }
        .onChange(of: reviewRequest) { _, newValue in
            guard !isWriting else { return }
            localThreads = newValue?.threads ?? []
            let currentCheckIDs = Set(newValue?.checks.map { $0.id } ?? [])
            annotations = annotations.filter { currentCheckIDs.contains($0.checkRunID) }
        }
    }

    @MainActor
    private func reload(completingStartupRecovery: Bool) async {
        pendingReview = PendingReview(worktreePath: worktree.path, prNumber: reviewRequest?.number)
        await loadSession()
        localThreads = reviewRequest?.threads ?? []
        if completingStartupRecovery {
            onStartupRecoveryReady()
        }
    }

    // MARK: - Derived state from snapshot

    private var activeSnapshot: ReviewLoopSnapshot? {
        appState.rightPaneStore.activeState(worktreeId: tabState.worktreeId)?.reviewLoop.snapshot
    }

    private var reviewRefreshSettled: Bool {
        guard let reviewLoop = appState.rightPaneStore
            .activeState(worktreeId: tabState.worktreeId)?
            .reviewLoop
        else { return false }
        return ReviewTabStartupRecoveryReadiness.reviewRefreshSettled(
            hasSnapshot: reviewLoop.snapshot != nil,
            isRefreshing: reviewLoop.isRefreshing,
            hasError: reviewLoop.lastError != nil
        )
    }

    private var matchedSnapshot: ReviewLoopSnapshot? {
        guard let snap = activeSnapshot, tabState.matches(snap) else { return nil }
        return snap
    }

    private var reviewRequest: ReviewRequest? {
        matchedSnapshot?.reviewRequest
    }

    private var provider: (any CodeHostProvider)? {
        guard let remote = reviewRequest?.remote else { return nil }
        return CodeHostProviderRegistry.live().provider(for: remote.kind)
    }

    private var capabilities: CodeHostProviderCapabilities {
        matchedSnapshot?.providerCapabilities ?? .readOnly
    }

    private var canMergeReviewRequest: Bool {
        guard let snapshot = matchedSnapshot else { return false }
        return ReviewReadinessModel.canMergeReviewRequest(snapshot: snapshot)
    }

    private var outdatedAndFileLevelThreads: [ReviewThread] {
        localThreads.filter { $0.isFileLevel || $0.isOutdated }
    }

    // MARK: - Load key (mirrors ReviewChangesTabView)

    private var loadKey: String {
        [
            ReviewChangesLoadKey.build(
                tabID: tabState.id,
                worktreePath: worktree.path,
                rightPaneState: appState.rightPaneStore.activeState(worktreeId: worktree.id)
            ),
            "reviewRefreshSettled:\(reviewRefreshSettled)"
        ].joined(separator: "\u{0}")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if ReviewTabLoadingPresentation.showsBlockingLoader(isLoading: isLoading, hasSession: session != nil) {
            stateView(title: "Loading changes...", detail: nil, color: theme.color("fg-dim"))
        } else if ReviewTabLoadingPresentation.showsLoadError(loadError: loadError, isLoading: isLoading, hasSession: session != nil),
                  let loadError {
            stateView(title: "Could not load review changes", detail: loadError, color: theme.color("del"))
        } else if let session, session.files.isEmpty {
            loadedReviewContent(fileCount: session.files.count) {
                stateView(title: "No changes to review", detail: "This worktree has no staged or unstaged file diffs.", color: theme.color("fg-dim"))
            }
        } else if let session {
            loadedReviewContent(fileCount: session.files.count) {
                reviewSurface(session)
            }
        } else {
            stateView(title: "No changes loaded", detail: nil, color: theme.color("fg-dim"))
        }
    }

    private func loadedReviewContent<Content: View>(fileCount: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            content()

            if let pendingReview,
               ReviewTabPendingReviewPresentation.showsRail(
                   stagedCount: pendingReview.staged.count,
                   loadedFileCount: fileCount
               ) {
                PendingReviewRail(
                    pendingReview: pendingReview,
                    collapsed: $pendingReviewRailCollapsed
                ) {
                    showVerdictSheet = true
                }
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Icon(name: "list.bullet.rectangle.portrait.fill", size: 14, color: theme.color("accent"))
            VStack(alignment: .leading, spacing: 2) {
                let titleText = tabState.title.isEmpty
                    ? "\(tabState.provider.reviewRequestLabel) Review"
                    : tabState.title
                Text(titleText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                if let summary = session?.summary, summary.fileCount > 0 {
                    HStack(spacing: 6) {
                        Text("\(summary.fileCount) files")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.color("fg-dim"))
                        Text("+\(summary.totalAdditions)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.color("add"))
                        Text("-\(summary.totalDeletions)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.color("del"))
                    }
                }
            }
            Spacer()
            if ReviewTabPendingReviewPresentation.showsToolbarFinishButton(
                canSubmitReview: capabilities.canSubmitReview,
                hasPendingReviewScope: pendingReview != nil
            ) {
                toolbarButton(
                    systemName: "arrow.up.doc",
                    tooltip: "Finish review",
                    isActive: (pendingReview?.staged.isEmpty == false)
                ) {
                    showVerdictSheet = true
                }
            }
            layoutSwitcher
            toolbarButton(
                systemName: diffPreferences.wrapLines.wrappedValue ? "text.justify.left" : "text.alignleft",
                tooltip: "Wrap lines",
                isActive: diffPreferences.wrapLines.wrappedValue
            ) {
                diffPreferences.wrapLines.wrappedValue.toggle()
            }
            toolbarButton(
                systemName: "paragraphsign",
                tooltip: "Show whitespace",
                isActive: diffPreferences.showWhitespace.wrappedValue
            ) {
                diffPreferences.showWhitespace.wrappedValue.toggle()
            }
            if let url = reviewRequest?.url, !url.isFileURL {
                toolbarButton(
                    systemName: "arrow.up.right.square",
                    tooltip: "Open \(tabState.provider.reviewRequestLabel) in browser",
                    isActive: false
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
            if canMergeReviewRequest {
                toolbarButton(
                    systemName: "arrow.triangle.merge",
                    tooltip: "Merge \(tabState.provider.reviewRequestLabel)",
                    isActive: false
                ) {
                    appState.rightPaneStore
                        .activeState(worktreeId: tabState.worktreeId)?
                        .handleReviewReadinessAction(.merge, appState: appState)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(theme.color("bg-2"))
    }

    private var layoutSwitcher: some View {
        HStack(spacing: 0) {
            layoutButton(.split, systemName: "rectangle.split.2x1")
            layoutButton(.stacked, systemName: "rectangle.split.1x2")
        }
        .padding(3)
        .background(theme.color("bg-3"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.color("line"), lineWidth: 0.75)
        )
    }

    private func layoutButton(_ mode: DiffLayoutMode, systemName: String) -> some View {
        let active = diffPreferences.layoutMode.wrappedValue == mode
        return Button {
            diffPreferences.layoutMode.wrappedValue = mode
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(active ? theme.color("fg") : theme.color("fg-muted"))
                .frame(width: 28, height: 24)
                .background(active ? theme.color("bg-1") : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(mode.title)
    }

    private func toolbarButton(
        systemName: String,
        tooltip: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isActive ? theme.color("accent") : theme.color("fg-muted"))
                .frame(width: 26, height: 24)
                .background(isActive ? theme.color("accent-soft") : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Review surface

    private func reviewSurface(_ session: ReviewChangesLoadedSession) -> some View {
        DiffReviewSurface(
            session: session,
            selectedFileID: $selectedFileID,
            railCollapsed: $railCollapsed,
            layoutMode: diffPreferences.layoutMode,
            wrapLines: diffPreferences.wrapLines,
            showWhitespace: diffPreferences.showWhitespace,
            codeFontFamily: appState.config.code.fontFamily,
            codeFontSize: CGFloat(appState.config.code.fontSize),
            showsSourceBadges: true,
            lspContextForFile: { file in
                makeLSPContext(relativePath: file.summary.path)
            },
            onSaveDraftComment: { _, _, anchor, body in
                guard let pr = pendingReview else { return }
                pr.stage(StagedComment(
                    id: UUID(),
                    threadID: nil,
                    filePath: anchor.path,
                    line: anchor.line,
                    endLine: anchor.endLine,
                    side: anchor.side,
                    body: body,
                    suggestion: nil
                ))
            },
            threads: localThreads,
            onReply: { inlineThread, body in
                guard let t = localThreads.first(where: { $0.id == inlineThread.id }) else { return }
                replyAction(thread: t, body: body)
            },
            onResolve: { inlineThread in
                guard let t = localThreads.first(where: { $0.id == inlineThread.id }) else { return }
                resolveAction(thread: t)
            },
            onUnresolve: { inlineThread in
                guard let t = localThreads.first(where: { $0.id == inlineThread.id }) else { return }
                unresolveAction(thread: t)
            },
            onEdit: { inlineThread, inlineComment, newBody in
                guard let t = localThreads.first(where: { $0.id == inlineThread.id }),
                      let c = t.comments.first(where: { $0.id == inlineComment.id }) else { return }
                editAction(thread: t, comment: c, newBody: newBody)
            },
            onDelete: { inlineThread, inlineComment in
                guard let t = localThreads.first(where: { $0.id == inlineThread.id }),
                      let c = t.comments.first(where: { $0.id == inlineComment.id }) else { return }
                deleteAction(thread: t, comment: c)
            },
            annotations: annotations,
            canReply: capabilities.canReply,
            canResolve: capabilities.canResolve,
            onStageReply: { inlineThread, body in
                guard let pr = pendingReview else { return }
                pr.stage(StagedComment(
                    id: UUID(),
                    threadID: inlineThread.id,
                    filePath: inlineThread.filePath,
                    line: inlineThread.newLine,
                    side: inlineThread.isOldSide ? .old : .new,
                    body: body,
                    suggestion: nil
                ))
            },
            canAddToReview: capabilities.canSubmitReview
        )
    }

    // MARK: - Annotation fetching

    @MainActor
    private func fetchAnnotations(for check: ReviewCheck) async {
        guard capabilities.canFetchAnnotations,
              let provider,
              let remote = matchedSnapshot?.remote else { return }
        do {
            let fetched = try await provider.checkAnnotations(
                remote: remote, check: check, cwd: worktree.path)
            annotations = annotations.filter { $0.checkRunID != check.id } + fetched
        } catch {
            // Annotations are best-effort; silently ignore errors
        }
    }

    // MARK: - Write actions

    private func showError(_ message: String) {
        errorMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if errorMessage == message {
                errorMessage = nil
            }
        }
    }

    private func replyAction(thread: ReviewThread, body: String) {
        guard let provider, let request = reviewRequest, let remote = reviewRequest?.remote else { return }
        let optimisticComment = ReviewComment(
            id: UUID().uuidString,
            author: nil,
            body: body,
            url: nil,
            createdAt: nil,
            viewerCanUpdate: true,
            viewerCanDelete: true,
            isPending: true
        )
        isWriting = true
        localThreads = ReviewThreadMutations.applyReply(to: localThreads, threadID: thread.id, comment: optimisticComment)
        Task { @MainActor in
            defer { isWriting = false }
            do {
                let newComment = try await provider.replyToThread(
                    remote: remote, request: request, thread: thread, body: body, cwd: worktree.path
                )
                localThreads = localThreads.map {
                    $0.id == thread.id ? $0.replacingComment(id: optimisticComment.id, with: newComment) : $0
                }
            } catch {
                localThreads = localThreads.map {
                    $0.id == thread.id ? $0.removingComment(id: optimisticComment.id) : $0
                }
                showError(error.localizedDescription)
            }
        }
    }

    private func resolveAction(thread: ReviewThread) {
        guard let provider, let request = reviewRequest, let remote = reviewRequest?.remote else { return }
        isWriting = true
        localThreads = ReviewThreadMutations.applyResolve(to: localThreads, threadID: thread.id)
        Task { @MainActor in
            defer { isWriting = false }
            do {
                let updatedThread = try await provider.resolveThread(remote: remote, request: request, thread: thread, cwd: worktree.path)
                localThreads = localThreads.map { $0.id == updatedThread.id ? updatedThread : $0 }
            } catch {
                localThreads = localThreads.map { $0.id == thread.id ? thread : $0 }
                showError(error.localizedDescription)
            }
        }
    }

    private func unresolveAction(thread: ReviewThread) {
        guard let provider, let request = reviewRequest, let remote = reviewRequest?.remote else { return }
        isWriting = true
        localThreads = ReviewThreadMutations.applyUnresolve(to: localThreads, threadID: thread.id)
        Task { @MainActor in
            defer { isWriting = false }
            do {
                let updatedThread = try await provider.unresolveThread(remote: remote, request: request, thread: thread, cwd: worktree.path)
                localThreads = localThreads.map { $0.id == updatedThread.id ? updatedThread : $0 }
            } catch {
                localThreads = localThreads.map { $0.id == thread.id ? thread : $0 }
                showError(error.localizedDescription)
            }
        }
    }

    private func editAction(thread: ReviewThread, comment: ReviewComment, newBody: String) {
        guard capabilities.canEditComment,
              let provider, let request = reviewRequest, let remote = reviewRequest?.remote else { return }
        let original = comment
        isWriting = true
        localThreads = ReviewThreadMutations.applyEdit(to: localThreads, threadID: thread.id, commentID: comment.id, newBody: newBody)
        Task { @MainActor in
            defer { isWriting = false }
            do {
                let updated = try await provider.editComment(remote: remote, request: request, comment: comment, newBody: newBody, cwd: worktree.path)
                localThreads = localThreads.map { $0.id == thread.id ? $0.replacingComment(id: comment.id, with: updated) : $0 }
            } catch {
                localThreads = localThreads.map { $0.id == thread.id ? $0.replacingComment(id: comment.id, with: original) : $0 }
                showError(error.localizedDescription)
            }
        }
    }

    private func deleteAction(thread: ReviewThread, comment: ReviewComment) {
        guard capabilities.canDeleteComment,
              let provider, let request = reviewRequest, let remote = reviewRequest?.remote else { return }
        isWriting = true
        localThreads = ReviewThreadMutations.applyDelete(to: localThreads, threadID: thread.id, commentID: comment.id)
        Task { @MainActor in
            defer { isWriting = false }
            do {
                try await provider.deleteComment(remote: remote, request: request, comment: comment, cwd: worktree.path)
            } catch {
                // Surgical rollback: re-insert the deleted comment into its thread
                localThreads = localThreads.map { $0.id == thread.id ? $0.addingReply(comment) : $0 }
                showError(error.localizedDescription)
            }
        }
    }

    private func makeLSPContext(relativePath: String) -> DiffPaneLSPContext? {
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

    private func stateView(title: String, detail: String?, color: Color) -> some View {
        VStack(spacing: 8) {
            if isLoading {
                Spinner()
                    .frame(width: 18, height: 18)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    @MainActor
    private func loadSession() async {
        let requestedLoadToken = ReviewChangesLoadToken.next(key: loadKey)
        activeLoadKey = requestedLoadToken.key
        activeLoadID = requestedLoadToken.id
        isLoading = true
        loadError = nil
        defer {
            if requestedLoadToken.isActive(activeKey: activeLoadKey, activeID: activeLoadID) {
                isLoading = false
                activeLoadKey = nil
            }
        }

        do {
            // Prefer the PR base..head diff; server thread line numbers are relative to it.
            // Fall back to the working-tree diff when no PR session is available.
            var loaded: ReviewChangesLoadedSession
            if let prSession = try await loadPRDiffSession() {
                guard
                    requestedLoadToken.isActive(activeKey: activeLoadKey, activeID: activeLoadID),
                    !Task.isCancelled
                else { return }
                loaded = prSession
            } else {
                loaded = try await loader.load(worktreePath: worktree.path)
                guard
                    requestedLoadToken.isActive(activeKey: activeLoadKey, activeID: activeLoadID),
                    !Task.isCancelled
                else { return }
            }

            session = loaded
            selectedFileID = selectedFileID.flatMap { selected in
                loaded.summary.files.contains { $0.id == selected } ? selected : loaded.summary.files.first?.id
            } ?? loaded.summary.files.first?.id
        } catch is CancellationError {
        } catch {
            guard
                requestedLoadToken.isActive(activeKey: activeLoadKey, activeID: activeLoadID),
                !Task.isCancelled
            else { return }
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func loadPRDiffSession() async throws -> ReviewChangesLoadedSession? {
        guard let provider,
              let remote = matchedSnapshot?.remote,
              let request = reviewRequest
        else { return nil }
        let diffLoader = ReviewRequestDiffLoader(provider: provider)
        return try await diffLoader.load(remote: remote, request: request, cwd: worktree.path)
    }

    private var diffPreferences: DiffPreferenceBindings {
        DiffPreferenceBindings(
            appState: appState,
            wrapLines: $wrapLines,
            showWhitespace: $showWhitespace
        )
    }

    // MARK: - Verdict submission

    @MainActor
    private func submitReviewAction(verdict: ReviewVerdict, body: String) {
        guard let pr = pendingReview,
              let provider,
              let request = reviewRequest,
              let remote = reviewRequest?.remote
        else { return }

        let stagedComments = pr.staged
        showVerdictSheet = false

        Task { @MainActor in
            var createdReviewID: String?
            do {
                // Post thread replies first — they don't require a pending review object.
                for comment in stagedComments where comment.threadID != nil {
                    if let existingThread = localThreads.first(where: { $0.id == comment.threadID }) {
                        _ = try await provider.replyToThread(
                            remote: remote,
                            request: request,
                            thread: existingThread,
                            body: comment.body,
                            cwd: worktree.path
                        )
                        pr.remove(id: comment.id)
                    }
                }

                let inlineComments = stagedComments.filter { $0.threadID == nil }
                let hasReviewContent = !inlineComments.isEmpty
                    || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || verdict != .comment
                if hasReviewContent {
                    let reviewID = try await provider.startReview(remote: remote, request: request, cwd: worktree.path)
                    createdReviewID = reviewID
                    for comment in inlineComments {
                        try await provider.addReviewComment(
                            remote: remote,
                            request: request,
                            reviewID: reviewID,
                            comment: comment,
                            cwd: worktree.path
                        )
                    }
                    try await provider.submitReview(
                        remote: remote,
                        request: request,
                        reviewID: reviewID,
                        verdict: verdict,
                        body: body,
                        cwd: worktree.path
                    )
                    createdReviewID = nil
                    // Remove inline comments after submitReview so providers that buffer
                    // (e.g. GitLab) don't lose drafts if the submit step fails.
                    for comment in inlineComments {
                        pr.remove(id: comment.id)
                    }
                }
            } catch {
                if let reviewID = createdReviewID {
                    try? await provider.cancelReview(
                        remote: remote, request: request, reviewID: reviewID, cwd: worktree.path)
                }
                showError(error.localizedDescription)
            }
        }
    }
}
