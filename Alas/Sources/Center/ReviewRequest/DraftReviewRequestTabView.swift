import AppKit
import SwiftUI

struct DraftReviewRequestTabView: View {
    let worktreePath: URL
    let worktreeId: String
    let tabState: DraftReviewRequestTabState
    @Bindable var appState: AppState
    var onStartupRecoveryReady: () -> Void = {}

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var createAsDraft: Bool = false
    @State private var selectedPath: String?
    @State private var context: ReviewRequestDraftContext?
    @State private var busy = false
    @State private var error: String?
    @State private var warning: String?
    @State private var loadingContext = false
    @State private var loadedContextKey: String?
    @State private var draftReviewSession: DiffReviewLoadedSession?
    @State private var selectedFileID: DiffReviewFileID?
    @State private var railCollapsed = false
    @State private var reviewSummaryCollapsed = false
    @State private var draftCommentController: ReviewDraftCommentController?
    @State private var loadedDraftSessionID: ReviewDraftSessionID?
    @State private var focusedDraftCommentID: String?
    @State private var draftCommentScrollCommand: DiffReviewDraftCommentScrollCommand?
    @State private var draftCommentScrollController = DiffReviewDraftCommentScrollController()
    @State private var generation: Task<Void, Never>? = nil
    @State private var reviewSessionLaunchError: String?
    @State private var wrapLines = false
    @State private var showWhitespace = false

    @Environment(\.theme) private var theme
    @FocusState private var focused: Field?

    private let git = GitService()

    private enum Field: Hashable { case title, body }

    private var snapshot: ReviewLoopSnapshot? {
        appState.rightPaneStore.activeState(worktreeId: worktreeId)?.reviewLoop.snapshot
    }

    private var matchingSnapshot: ReviewLoopSnapshot? {
        guard let snapshot, tabState.matchesTarget(snapshot) else { return nil }
        return snapshot
    }

    private var targetMismatchMessage: String? {
        guard let snapshot else { return nil }
        guard !tabState.matchesTarget(snapshot) else { return nil }
        return "This draft targets \(tabState.branchName) at \(tabState.headSHA.prefix(7)). Switch back to that branch state before creating it."
    }

    private var validationMessage: String? {
        if let targetMismatchMessage { return targetMismatchMessage }
        return ReviewRequestDraft.validationMessage(
            for: ReviewRequestDraft.ValidationInput(
                title: title,
                body: bodyText,
                snapshot: snapshot
            )
        )
    }

    private var canCreate: Bool {
        validationMessage == nil && !busy && tabState.createdURL == nil
    }

    private var contextKey: String {
        let head = matchingSnapshot?.local.headSHA ?? tabState.headSHA
        let base = matchingSnapshot?.local.baseBranch ?? tabState.baseBranch
        return "\(head):\(base)"
    }

    private var diffPreferences: DiffPreferenceBindings {
        DiffPreferenceBindings(
            appState: appState,
            wrapLines: $wrapLines,
            showWhitespace: $showWhitespace
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            reviewRequestEditor
            contextBrowser
        }
        .onAppear { hydrateFromTabState() }
        .onChange(of: title) { _, new in persist(title: new) }
        .onChange(of: bodyText) { _, new in persist(body: new) }
        .onChange(of: createAsDraft) { _, new in persist(createAsDraft: new) }
        .onChange(of: selectedPath) { _, new in
            persist(selectedPath: new)
        }
        .onChange(of: selectedFileID) { _, new in
            let path = DraftReviewRequestDiffSessionBuilder.selectedPath(for: new)
            guard selectedPath != path else { return }
            selectedPath = path
        }
        .task(id: contextKey) {
            let requestedContextKey = contextKey
            await loadContext()
            guard Self.shouldReportStartupRecoveryReady(
                requestedContextKey: requestedContextKey,
                currentContextKey: contextKey,
                isCancelled: Task.isCancelled
            ) else { return }
            onStartupRecoveryReady()
        }
        .task(id: reviewDraftSessionID.rawValue) {
            loadDraftCommentController()
        }
        .onDisappear {
            generation?.cancel()
        }
    }

    static func reviewDraftSessionID(
        worktreeID: String,
        repositoryPath: URL,
        base: String,
        head: String
    ) -> ReviewDraftSessionID {
        ReviewDraftSessionID.draftReviewRequest(
            worktreeID: worktreeID,
            repositoryPath: repositoryPath,
            base: base,
            head: head
        )
    }

    static func reviewSessionTarget(
        worktreeID: String,
        repositoryPath: URL,
        tabState: DraftReviewRequestTabState
    ) -> ReviewSessionTarget {
        ReviewSessionTarget.draftReviewRequest(
            worktreeID: worktreeID,
            repositoryPath: repositoryPath,
            provider: tabState.provider,
            repositorySlug: tabState.repositorySlug,
            base: tabState.baseBranch,
            head: tabState.branchName,
            headSHA: tabState.headSHA
        )
    }

    static func canLaunchReviewSession(targetMismatchMessage: String?) -> Bool {
        targetMismatchMessage == nil
    }

    static func shouldReportStartupRecoveryReady(
        requestedContextKey: String,
        currentContextKey: String,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && requestedContextKey == currentContextKey
    }

    private var reviewDraftSessionID: ReviewDraftSessionID {
        Self.reviewDraftSessionID(
            worktreeID: worktreeId,
            repositoryPath: worktreePath,
            base: tabState.baseBranch,
            head: tabState.branchName
        )
    }

    private var reviewRequestEditor: some View {
        VStack(spacing: 0) {
            ReviewRequestMessageEditor(
                title: $title,
                bodyText: $bodyText,
                aiToolId: appState.bind(\.changes.aiToolId),
                editorTitle: editorTitle,
                busy: busy,
                error: error,
                availableAgents: appState.agentRegistry.enabled(),
                onGenerate: handleGenerate,
                primaryAction: CommitPrimaryAction(
                    label: "Create \(tabState.provider.reviewRequestLabel)",
                    isEnabled: canCreate,
                    showSavedState: false,
                    handler: createReviewRequest
                ),
                editorDisabled: tabState.createdURL != nil,
                onDismissError: { self.error = nil },
                accessory: AnyView(
                    Toggle(isOn: $createAsDraft) {
                        Text("Draft")
                            .font(.system(size: 11))
                            .foregroundColor(theme.color("fg-dim"))
                    }
                    .toggleStyle(.checkbox)
                    .disabled(busy || tabState.createdURL != nil)
                )
            )
            if hasEditorMessages {
                editorMessages
            }
        }
    }

    private var hasEditorMessages: Bool {
        warning != nil || (validationMessage != nil && tabState.createdURL == nil) || tabState.createdURL != nil
    }

    private var editorTitle: String {
        let repo = tabState.repositorySlug.isEmpty ? "Unknown repository" : tabState.repositorySlug
        return "\(tabState.provider.displayName) \(tabState.provider.reviewRequestLabel) · \(repo) · \(tabState.branchName) -> \(tabState.baseBranch)"
    }

    @ViewBuilder
    private var editorMessages: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let warning {
                Text(warning)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.color("warn"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let validationMessage, tabState.createdURL == nil {
                Text(validationMessage)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.color("fg-dim"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let createdURL = tabState.createdURL {
                HStack(spacing: 6) {
                    Icon(name: "link", size: 11, color: theme.color("accent"))
                    Text(createdURL.absoluteString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.color("fg-dim"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    AlasButton(title: "Open \(tabState.provider.reviewRequestLabel)", icon: "arrow.up.right.square") {
                        NSWorkspace.shared.open(createdURL)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [theme.color("composer-bg-top"), theme.color("composer-bg-bot")],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private var contextBrowser: some View {
        VStack(spacing: 0) {
            draftContextHeader
            draftCommitStrip
            Divider().overlay(theme.color("line"))
            draftContextContent
        }
        .background(theme.color("bg-1"))
    }

    private var draftContextHeader: some View {
        HStack(spacing: 10) {
            Text("Branch diff")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Text("\(tabState.baseBranch) -> HEAD")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.color("fg-dim"))
            if let context {
                Text("\(context.commits.count) commits")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
                Text("\(context.changedFiles.count) files")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
                if let summary = draftReviewSession?.summary {
                    Text("+\(summary.totalAdditions)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.color("add"))
                    Text("-\(summary.totalDeletions)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.color("del"))
                }
            }
            Spacer()
            if let reviewSessionLaunchError {
                Text(reviewSessionLaunchError)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("del"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            AlasButton(title: "Review Branch Diff", icon: "doc.text.magnifyingglass") {
                if let targetMismatchMessage {
                    reviewSessionLaunchError = targetMismatchMessage
                    return
                }
                openReviewSession(
                    target: Self.reviewSessionTarget(
                        worktreeID: worktreeId,
                        repositoryPath: worktreePath,
                        tabState: tabState
                    )
                )
            }
            .disabled(!Self.canLaunchReviewSession(targetMismatchMessage: targetMismatchMessage))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.color("bg-2"))
    }

    @ViewBuilder
    private var draftCommitStrip: some View {
        if let context, !context.commits.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(context.commits) { commit in
                        Button {
                            Clipboard.copy(commit.sha)
                        } label: {
                            HStack(spacing: 6) {
                                Text(commit.shortSha)
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundColor(theme.color("accent"))
                                Text(commit.subject)
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.color("fg-dim"))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(theme.color("bg-1"))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(theme.color("line"), lineWidth: 0.5)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help("Copy commit SHA")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .background(theme.color("bg-0"))
        }
    }

    @ViewBuilder
    private var draftContextContent: some View {
        if loadingContext {
            Spinner()
                .frame(width: 20, height: 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let context, context.changedFiles.isEmpty {
            stateMessage(
                "No committed branch diff.",
                detail: "There are no committed changes between \(tabState.baseBranch) and HEAD."
            )
        } else if let draftReviewSession {
            DiffReviewSurface(
                session: draftReviewSession,
                selectedFileID: $selectedFileID,
                railCollapsed: $railCollapsed,
                reviewSummaryCollapsed: $reviewSummaryCollapsed,
                layoutMode: diffPreferences.layoutMode,
                wrapLines: diffPreferences.wrapLines,
                showWhitespace: diffPreferences.showWhitespace,
                codeFontFamily: appState.config.code.fontFamily,
                codeFontSize: CGFloat(appState.config.code.fontSize),
                showsSourceBadges: false,
                showsRailDisplayControls: true,
                showsDraftSummaryRail: true,
                lspContextForFile: { file in
                    makeLSPContext(relativePath: file.summary.path)
                },
                reviewFeedbackTarget: reviewFeedbackTarget,
                draftCommentsByFileID: ReviewDraftCommentGrouping.commentsByFileID(draftCommentController?.comments ?? []),
                focusedDraftCommentID: focusedDraftCommentID,
                draftCommentScrollCommand: draftCommentScrollCommand,
                draftCommentActions: draftCommentActions(),
                onSelectDraftComment: selectDraftComment,
                onSaveDraftComment: { fileID, path, originalPath, anchor, body in
                    saveDraftComment(fileID: fileID, path: path, originalPath: originalPath, anchor: anchor, body: body)
                }
            )
        } else {
            VStack(spacing: 8) {
                Text("No committed branch context.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.color("fg-dim"))
                AlasButton(title: "Reload", icon: "arrow.clockwise") {
                    Task { await loadContext() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func stateMessage(_ title: String, detail: String?) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.color("fg-dim"))
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-faint"))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hydrateFromTabState() {
        title = tabState.title
        bodyText = tabState.body
        createAsDraft = tabState.createAsDraft
        selectedPath = tabState.selectedPath
    }

    private func persist(
        title: String? = nil,
        body: String? = nil,
        createAsDraft: Bool? = nil,
        selectedPath: String?? = nil,
        createdURL: URL?? = nil
    ) {
        appState.tabs.updateDraftReviewRequest(worktreeId: worktreeId, tabId: tabState.id) { state in
            if let title { state.title = title }
            if let body { state.body = body }
            if let createAsDraft { state.createAsDraft = createAsDraft }
            if let selectedPath { state.selectedPath = selectedPath }
            if let createdURL { state.createdURL = createdURL }
        }
    }

    private func loadContext() async {
        let key = contextKey
        loadingContext = true
        context = nil
        draftReviewSession = nil
        loadedContextKey = nil
        warning = nil
        error = nil
        defer {
            if key == contextKey {
                loadingContext = false
            }
        }
        guard matchingSnapshot != nil else {
            warning = targetMismatchMessage
            return
        }
        do {
            let loaded = try await git.reviewRequestDraftContext(
                worktreePath: worktreePath,
                baseRef: tabState.baseBranch
            )
            let resolvedHeadRef = tabState.headSHA.isEmpty ? "HEAD" : tabState.headSHA
            let imageRevisions = try await git.resolvedRangeTrees(
                worktreePath: worktreePath,
                base: tabState.baseBranch,
                head: resolvedHeadRef,
                threeDot: true
            )
            guard !Task.isCancelled, key == contextKey else { return }
            let session = try await DraftReviewRequestDiffSessionBuilder.build(
                context: loaded,
                worktreePath: worktreePath,
                openFileForPath: { path in
                    Self.draftDiffOpenFileAction(
                        worktreePath: worktreePath,
                        relativePath: path
                    ) { path in
                        appState.openFile(relativePath: path, worktreeId: worktreeId)
                    }
                },
                contextProviderForPath: { path, originalPath in
                    DiffReviewContextProvider {
                        try await GitService().refContextSnapshot(
                            worktreePath: worktreePath,
                            baseRef: tabState.baseBranch,
                            headRef: resolvedHeadRef,
                            file: path,
                            originalPath: originalPath
                        )
                    }
                },
                imageProviderForFile: { file in
                    git.rangeImageProvider(
                        worktreePath: worktreePath,
                        revisions: imageRevisions,
                        file: file
                    )
                }
            )
            guard !Task.isCancelled, key == contextKey else { return }
            context = loaded
            loadedContextKey = key
            draftReviewSession = session
            if loaded.commits.count == 1, title.isEmpty, bodyText.isEmpty,
               let subject = loaded.commitSubjects.first {
                title = subject
                bodyText = loaded.singleCommitBody ?? ""
            }
            selectedFileID = DraftReviewRequestDiffSessionBuilder.synchronizedSelection(
                selectedPath: selectedPath,
                session: session
            )
            selectedPath = DraftReviewRequestDiffSessionBuilder.selectedPath(for: selectedFileID)
            loadDraftCommentController()
            warning = loaded.hasUncommittedChanges
                ? "Uncommitted changes are present but excluded from this \(tabState.provider.reviewRequestLabel)."
                : nil
        } catch {
            guard !Task.isCancelled, key == contextKey else { return }
            self.error = (error as NSError).localizedDescription
        }
    }

    static func draftDiffOpenFileAction(
        worktreePath: URL,
        relativePath: String,
        openFile: @escaping (String) -> Void
    ) -> (() -> Void)? {
        guard DiffOpenFileAvailability.isAvailable(
            worktreePath: worktreePath,
            relativePath: relativePath
        ) else {
            return nil
        }
        return {
            openFile(relativePath)
        }
    }

    private func handleGenerate() {
        if busy {
            generation?.cancel()
            return
        }
        guard let agent = appState.agent(id: appState.config.changes.aiToolId) else {
            error = "Select an AI tool to generate a \(tabState.provider.reviewRequestLabel) description."
            return
        }
        guard matchingSnapshot != nil else {
            error = targetMismatchMessage
            return
        }
        guard !loadingContext, loadedContextKey == contextKey, let context else {
            error = "Branch context is still loading."
            return
        }

        busy = true
        error = nil
        let provider = tabState.provider.displayName
        let repository = tabState.repositorySlug
        let prompt = appState.config.changes.reviewRequestPrompt
        let payload = ReviewRequestContextBuilder.build(
            provider: provider,
            repository: repository,
            branch: tabState.branchName,
            base: tabState.baseBranch,
            hasUncommittedChanges: context.hasUncommittedChanges,
            commitSubjects: context.commitSubjects,
            diff: context.diff
        )

        generation = Task { @MainActor in
            defer {
                busy = false
                generation = nil
            }
            do {
                let raw = try await AgentRunner.runPromptRaw(
                    agent: agent,
                    input: payload,
                    prompt: prompt,
                    workingDirectory: worktreePath.path
                )
                guard !Task.isCancelled else { return }
                let message = try ReviewRequestDraft.parseGeneratedMessage(raw)
                title = message.title
                bodyText = message.body
            } catch is CancellationError {
                // user-cancelled
            } catch {
                self.error = (error as NSError).localizedDescription
            }
        }
    }

    private func createReviewRequest() {
        guard !busy, let snapshot = matchingSnapshot, validationMessage == nil else { return }
        busy = true
        error = nil
        let titleSnapshot = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodySnapshot = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftSnapshot = createAsDraft
        Task { @MainActor in
            defer { busy = false }
            do {
                let url = try await appState.rightPaneStore
                    .activeState(worktreeId: worktreeId)?
                    .reviewLoop
                    .createReviewRequest(
                        snapshot: snapshot,
                        branch: tabState.branchName,
                        headOwner: tabState.headOwner,
                        baseBranch: tabState.baseBranch,
                        title: titleSnapshot,
                        body: bodySnapshot,
                        isDraft: draftSnapshot
                    )
                guard let url else {
                    error = "Review state is still loading."
                    return
                }
                persist(createdURL: url)
                await appState.rightPaneStore.refresh(
                    worktreeId: worktreeId,
                    forceReviewLoopRemote: true
                )
            } catch {
                self.error = (error as NSError).localizedDescription
            }
        }
    }

    private func makeLSPContext(relativePath: String) -> DiffPaneLSPContext? {
        let fileURL = worktreePath.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let language = appState.lsp.language(forPath: relativePath)
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

    private var reviewFeedbackTarget: ReviewFeedbackTarget {
        ReviewFeedbackTarget(
            title: "Draft \(tabState.provider.reviewRequestLabel)",
            repositoryPath: worktreePath.path,
            providerDescription: [
                tabState.provider.displayName,
                tabState.repositorySlug,
            ].filter { !$0.isEmpty }.joined(separator: " "),
            sourceDescription: "\(tabState.baseBranch) -> \(tabState.branchName)"
        )
    }

    private var reviewFeedbackAgentSender: ReviewFeedbackAgentSender {
        ReviewFeedbackAgentSender.production(appState: appState, worktreeID: worktreeId)
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

    private func loadDraftCommentController() {
        let sessionID = reviewDraftSessionID
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
        ReviewDraftWorkspaceActions.make(
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
        path: String,
        originalPath: String?,
        anchor: ReviewDraftCommentAnchor,
        body: String
    ) {
        do {
            try draftCommentController?.add(anchor: anchor, path: path, fileID: fileID, originalPath: originalPath, bodyMarkdown: body)
        } catch {
            // The controller keeps the non-blocking error state for the review rail.
        }
    }
}

struct ReviewRequestMessageEditor: View {
    @Binding var title: String
    @Binding var bodyText: String
    @Binding var aiToolId: String
    let editorTitle: String
    let busy: Bool
    let error: String?
    let availableAgents: [AgentDefinition]
    let onGenerate: () -> Void
    let primaryAction: CommitPrimaryAction
    let editorDisabled: Bool
    let onDismissError: () -> Void
    let accessory: AnyView?

    var body: some View {
        CommitMessageEditorView(
            subject: $title,
            bodyText: $bodyText,
            aiToolId: $aiToolId,
            title: editorTitle,
            busy: busy,
            error: error,
            availableAgents: availableAgents,
            onGenerate: onGenerate,
            primaryAction: primaryAction,
            iconName: "branch",
            editorDisabled: editorDisabled,
            onDismissError: onDismissError,
            accessory: accessory
        )
    }
}
