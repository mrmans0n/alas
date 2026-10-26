import SwiftUI

struct CommitEditorTabView: View {
    let worktreePath: URL
    let worktreeId: String
    let tabState: CommitEditorTabState
    let executionTarget: AgentExecutionTarget
    @Bindable var appState: AppState
    var onStartupRecoveryReady: () -> Void = {}
    /// Nil edits this Mac's worktree, as `CommitEditorGit.local`.
    var source: CommitEditorGit? = nil
    /// Shows a close button, for an editor opened over the peer center pane.
    var onClose: (() -> Void)? = nil

    @State private var details: CommitDetails?
    @State private var loadingDetails = true
    @State private var activeDetailsKey: String?

    @State private var selectedPath: String?
    @State private var diff: ParsedDiff = ParsedDiff(hunks: [])
    @State private var displayModel: DiffDisplayModel?
    @State private var displayModelKey: String?
    /// The diff was cut off by the host: its hunks are not all there to drop.
    @State private var diffTruncated = false
    @State private var loadingDiff = false
    @State private var activeDiffKey: String?

    @State private var subject = ""
    @State private var bodyText = ""
    @State private var protectedTrailers: [ProtectedCommitTrailer] = []
    @State private var savedSubject = ""
    @State private var savedBodyText = ""
    @State private var busy = false
    @State private var error: String?
    @State private var pendingDropFile: PendingCommitFileDrop?
    @State private var pendingDropHunk: PendingCommitHunkDrop?
    @State private var wrapLines = false
    @State private var showWhitespace = false

    // Files/diff divider drag: transient during the drag, committed to
    // config (and disk) once on drag end.
    @State private var transientFilesWidth: CGFloat?
    @State private var filesDragStartWidth: CGFloat?

    @Environment(\.theme) private var theme
    private let git = GitService()

    private var editorGit: CommitEditorGit {
        source ?? .local(
            worktreePath: worktreePath, worktreeId: worktreeId, tabId: tabState.id, baseRef: tabState.baseRef, appState: appState
        )
    }

    private var generatesMessages: Bool { source?.generatesMessages ?? true }

    private var agentAvailability: AgentAvailabilityState {
        appState.agentAvailability(worktreePath: worktreePath, executionTarget: executionTarget)
    }

    private var agentAvailabilityTaskKey: String {
        "\(executionTarget):\(appState.agentAvailabilityGeneration(worktreePath: worktreePath, executionTarget: executionTarget))"
    }

    private static let minPaneWidth: CGFloat = 140

    private var diffPreferences: DiffPreferenceBindings {
        DiffPreferenceBindings(
            appState: appState,
            wrapLines: $wrapLines,
            showWhitespace: $showWhitespace
        )
    }

    private var dirty: Bool {
        subject != savedSubject || bodyText != savedBodyText
    }

    private var diffTaskKey: String {
        Self.diffTaskKey(
            currentSha: tabState.currentSha,
            selectedPath: selectedPath,
            loadingDetails: loadingDetails
        )
    }

    static func diffTaskKey(currentSha: String, selectedPath: String?, loadingDetails: Bool) -> String {
        "\(currentSha):\(selectedPath ?? ""):\(loadingDetails)"
    }

    static func shouldReportStartupRecoveryReady(
        requestedDiffTaskKey: String,
        currentDiffTaskKey: String,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && requestedDiffTaskKey == currentDiffTaskKey
    }

    var body: some View {
        VStack(spacing: 0) {
            if let details {
                CommitMessageEditorView(
                    subject: $subject,
                    bodyText: $bodyText,
                    aiToolId: appState.bind(\.changes.aiToolId),
                    title: source == nil ? tabState.title : tabTitle(from: details),
                    busy: busy,
                    error: error,
                    agentAvailability: agentAvailability,
                    executionTarget: executionTarget,
                    onRetryAgentAvailability: {
                        Task {
                            await appState.loadAgentAvailability(
                                worktreePath: worktreePath,
                                executionTarget: executionTarget,
                                force: true
                            )
                        }
                    },
                    onGenerate: generateMessage,
                    primaryAction: CommitPrimaryAction(
                        label: "Save message",
                        savedLabel: "Saved",
                        isEnabled: dirty && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        showSavedState: !dirty,
                        handler: saveMessage
                    ),
                    protectedTrailers: protectedTrailers,
                    accessory: onClose.map { AnyView(ToolbarBtn(icon: "x", tooltip: "Back to session", action: $0)) },
                    generatesMessages: generatesMessages
                )
                splitBody(details: details)
            } else if loadingDetails {
                Spinner()
                    .frame(width: 20, height: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack(spacing: 8) {
                    Text("Could not load commit \(String(tabState.currentSha.prefix(7)))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.color("del"))
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-dim"))
                    AlasButton(title: "Retry", style: .subtle) {
                        Task { await loadDetails() }
                    }
                    if let onClose {
                        AlasButton(title: "Close", style: .subtle, action: onClose)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .task(id: tabState.currentSha) {
            await loadDetails()
        }
        .task(id: worktreeId) {
            guard source == nil else { return }
            _ = await appState.checkpointFileWritesDisabledAfterDiscovery(worktreeId: worktreeId)
        }
        .task(id: agentAvailabilityTaskKey) {
            guard generatesMessages else { return }
            await appState.loadAgentAvailability(worktreePath: worktreePath, executionTarget: executionTarget)
        }
        .task(id: diffTaskKey) {
            guard !loadingDetails else { return }
            let requestedDiffTaskKey = diffTaskKey
            await loadDiffIfNeeded()
            guard Self.shouldReportStartupRecoveryReady(
                requestedDiffTaskKey: requestedDiffTaskKey,
                currentDiffTaskKey: diffTaskKey,
                isCancelled: Task.isCancelled
            ) else { return }
            onStartupRecoveryReady()
        }
        .confirmationDialog("Drop file from commit?", isPresented: Binding(
            get: { pendingDropFile != nil },
            set: { if !$0 { pendingDropFile = nil } }
        )) {
            Button("Drop \(((pendingDropFile?.file.path ?? "file") as NSString).lastPathComponent)", role: .destructive) {
                if let pending = pendingDropFile { dropFile(pending) }
                pendingDropFile = nil
            }
            .disabled(busy)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This rewrites commit \(String(tabState.currentSha.prefix(7))) immediately.")
        }
        .confirmationDialog("Drop hunk from commit?", isPresented: Binding(
            get: { pendingDropHunk != nil },
            set: { if !$0 { pendingDropHunk = nil } }
        )) {
            Button("Drop hunk", role: .destructive) {
                if let pending = pendingDropHunk { dropHunk(pending) }
                pendingDropHunk = nil
            }
            .disabled(busy)
            Button("Cancel", role: .cancel) { pendingDropHunk = nil }
        } message: {
            Text("This rewrites commit \(String(tabState.currentSha.prefix(7))) immediately.")
        }
    }

    @ViewBuilder
    private func splitBody(details: CommitDetails) -> some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let ratio = max(0.15, min(0.7, appState.config.commitDetailSplitRatio))
            let leftWidth: CGFloat = transientFilesWidth ?? max(Self.minPaneWidth, total * ratio)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    CommitFilesListView(
                        files: details.files,
                        selectedPath: $selectedPath,
                        onDropFile: { pendingDropFile = PendingCommitFileDrop(sha: tabState.currentSha, file: $0) },
                        dropFileEnabled: canDropFile,
                        dragPayload: { file in
                            // A host's commit is not on this Mac's disk to drag out.
                            guard source == nil else { return nil }
                            return .commitFile(
                                worktreePath: worktreePath,
                                sha: tabState.currentSha,
                                file: file
                            )
                        }
                    )
                    // A host caps the files it sends; `filesChanged` counts them all.
                    if details.files.count < details.info.filesChanged {
                        Text("Showing \(details.files.count) of \(details.info.filesChanged) files.")
                            .font(.system(size: 11))
                            .foregroundColor(theme.color("fg-dim"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(theme.color("bg-1"))
                    }
                }
                    .frame(width: leftWidth)
                DragHandle(
                    axis: .horizontal,
                    onDragChanged: { translation in
                        guard total > Self.minPaneWidth * 2 else { return }
                        let start: CGFloat = filesDragStartWidth ?? leftWidth
                        filesDragStartWidth = start
                        transientFilesWidth = CGFloat(PaneDragMath.resolvedWidth(
                            startWidth: Double(start),
                            translation: Double(translation),
                            min: max(Double(Self.minPaneWidth), Double(total) * 0.15),
                            max: min(Double(total) - Double(Self.minPaneWidth), Double(total) * 0.7)
                        ))
                    },
                    onDragEnded: {
                        if let width = transientFilesWidth, total > 0 {
                            appState.config.commitDetailSplitRatio = Double(width / total)
                            appState.saveConfig()
                        }
                        transientFilesWidth = nil
                        filesDragStartWidth = nil
                    }
                )
                Group {
                    if let path = selectedPath,
                       let file = details.files.first(where: { $0.path == path }) {
                        let selectedDiffKey = "\(tabState.currentSha):\(path)"
                        let selectedDisplayModel = displayModelKey == selectedDiffKey ? displayModel : nil
                        let openAvailable = source == nil && DiffOpenFileAvailability.isAvailable(
                            worktreePath: worktreePath, relativePath: path
                        )
                        CommitDiffView(
                            worktreePath: worktreePath,
                            sha: tabState.currentSha,
                            file: file,
                            path: path,
                            diff: diff,
                            displayModel: selectedDisplayModel,
                            loading: loadingDiff,
                            error: error,
                            codeFontFamily: appState.config.code.fontFamily,
                            codeFontSize: CGFloat(appState.config.code.fontSize),
                            layoutMode: diffPreferences.layoutMode,
                            wrapLines: diffPreferences.wrapLines,
                            showWhitespace: diffPreferences.showWhitespace,
                            onOpenFile: openAvailable
                                ? { appState.openFile(relativePath: path, worktreeId: worktreeId) }
                                : nil,
                            onDropHunk: { pendingDropHunk = PendingCommitHunkDrop(sha: tabState.currentSha, path: path, hunk: $0) },
                            dropHunkEnabled: { file, hunk in canDropHunk(file: file, hunk: hunk) }
                        )
                    } else {
                        Text("Select a file")
                            .foregroundColor(theme.color("fg-dim"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    private func loadDetails() async {
        let requestedKey = tabState.currentSha
        activeDetailsKey = requestedKey
        loadingDetails = true
        error = nil
        details = nil
        activeDiffKey = nil
        selectedPath = nil
        diff = ParsedDiff(hunks: [])
        diffTruncated = false
        displayModel = nil
        displayModelKey = nil
        loadingDiff = false
        protectedTrailers = []
        defer {
            if activeDetailsKey == requestedKey { loadingDetails = false }
        }
        do {
            let (loadedDetails, loadedSubject) = try await editorGit.details(tabState.currentSha)
            guard !Task.isCancelled, activeDetailsKey == requestedKey else { return }
            details = loadedDetails
            selectedPath = loadedDetails.files.first?.path
            if !dirty {
                let message = CommitMessage.split(loadedDetails.body)
                subject = loadedSubject
                bodyText = message.body
                protectedTrailers = message.protectedTrailers
                savedSubject = loadedSubject
                savedBodyText = message.body
            }
        } catch {
            guard !Task.isCancelled, activeDetailsKey == requestedKey else { return }
            self.error = (error as NSError).localizedDescription
        }
    }

    private func loadDiffIfNeeded() async {
        guard let path = selectedPath,
              let file = details?.files.first(where: { $0.path == path }) else {
            diff = ParsedDiff(hunks: [])
            diffTruncated = false
            displayModel = nil
            displayModelKey = nil
            return
        }
        let requestedKey = "\(tabState.currentSha):\(path)"
        activeDiffKey = requestedKey
        loadingDiff = true
        error = nil
        displayModel = nil
        displayModelKey = nil
        defer {
            if activeDiffKey == requestedKey { loadingDiff = false }
        }
        do {
            let (loaded, truncated) = try await editorGit.diff(tabState.currentSha, file)
            guard !Task.isCancelled, activeDiffKey == requestedKey else { return }
            let loadedModel = await Task.detached(priority: .userInitiated) {
                DiffDisplayModelBuilder.build(diff: loaded, filePath: path)
            }.value
            guard !Task.isCancelled, activeDiffKey == requestedKey else { return }
            diff = loaded
            diffTruncated = truncated
            displayModel = loadedModel
            displayModelKey = requestedKey
        } catch {
            guard !Task.isCancelled, activeDiffKey == requestedKey else { return }
            self.error = (error as NSError).localizedDescription
        }
    }

    private func displaySubject(from details: CommitDetails) -> String {
        if let tag = details.info.conventionalTag {
            return "\(tag): \(details.info.subject)"
        }
        return details.info.subject
    }

    private func tabTitle(from details: CommitDetails) -> String {
        "\(details.info.shortSha) \(displaySubject(from: details))"
    }

    private func canDropFile(_ file: CommitChangedFile) -> Bool {
        !busy && !dirty && ["A", "M", "D"].contains(file.status)
    }

    private func canDropHunk(file: CommitChangedFile, hunk: ParsedDiff.Hunk) -> Bool {
        !busy && !dirty && !diffTruncated && file.status == "M" && !hunk.lines.isEmpty
    }

    private func subjectLine(from commit: CommitInfo) -> String {
        if let tag = commit.conventionalTag {
            return "\(tag): \(commit.subject)"
        }
        return commit.subject
    }

    private func gitStdout(_ args: [String]) async throws -> String {
        let result = try await Process.git(args, cwd: worktreePath)
        guard result.exitCode == 0 else {
            throw NSError(
                domain: "CommitEditorTabView.git",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr.isEmpty ? "git failed" : result.stderr]
            )
        }
        return result.stdout
    }

    private func saveMessage() {
        runEdit(action: .message(subject: subject, body: bodyText))
    }

    private func dropFile(_ pending: PendingCommitFileDrop) {
        guard !dirty else {
            error = "Save or discard message edits before dropping files."
            return
        }
        guard pending.sha == tabState.currentSha else {
            error = "Commit changed before file drop could run. Try again."
            return
        }
        runEdit(action: .dropFile(path: pending.file.path))
    }

    private func dropHunk(_ pending: PendingCommitHunkDrop) {
        guard !dirty else {
            error = "Save or discard message edits before dropping hunks."
            return
        }
        guard pending.sha == tabState.currentSha else {
            error = "Commit changed before hunk drop could run. Try again."
            return
        }
        runEdit(action: .dropHunk(path: pending.path, hunk: pending.hunk))
    }

    private func runEdit(action: CommitEditAction) {
        guard !busy else { return }
        let targetSha = tabState.currentSha

        busy = true
        error = nil

        Task<Void, Never> { @MainActor in
            defer {
                busy = false
            }
            do {
                let result = try await editorGit.edit(targetSha, action)
                let (refreshedDetails, refreshedSubject) = try await editorGit.details(result.currentSha)

                let message = CommitMessage.split(refreshedDetails.body)
                details = refreshedDetails
                selectedPath = refreshedDetails.files.first?.path
                diff = ParsedDiff(hunks: [])
                diffTruncated = false
                activeDiffKey = nil
                subject = refreshedSubject
                bodyText = message.body
                protectedTrailers = message.protectedTrailers
                savedSubject = refreshedSubject
                savedBodyText = message.body

                await editorGit.didEdit(result, tabTitle(from: refreshedDetails))
            } catch {
                self.error = (error as NSError).localizedDescription
            }
        }
    }

    private func generateMessage() {
        guard !busy else { return }
        guard let agent = RepositoryAgentSelectionPolicy.selection(
            selectedID: appState.config.changes.aiToolId,
            availability: agentAvailability,
            where: \.supportsTerminal
        ).agent else {
            error = "Select an AI tool available on this host."
            return
        }
        guard details != nil else {
            error = "Commit details are still loading."
            return
        }

        let currentSubject = subject
        let currentBody = bodyText
        let currentSha = tabState.currentSha
        let baseRef = tabState.baseRef
        let prompt = appState.config.changes.prompt
        // The editor compares against the tab's already-selected `baseRef`, so
        // it uses that ref as given (local-first) instead of re-resolving it
        // origin-first the way Auto does for the Commits list — otherwise a
        // manual override like `develop` would silently become `origin/develop`
        // and change the nearby-commit context. Branch-upstream mode still
        // compares against the branch's own upstream.
        let commitsResolution: GitService.BaseResolution =
            appState.config.changes.comparisonMode == .branchUpstream ? .upstreamThenBase : .baseLocalFirst

        busy = true
        error = nil

        Task { @MainActor in
            defer { busy = false }
            do {
                let diff = try await gitStdout(["show", "--no-color", "--format=", currentSha])
                let branchRaw = try await gitStdout(["rev-parse", "--abbrev-ref", "HEAD"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let branch: String? = branchRaw == "HEAD" ? nil : branchRaw
                let nearbyCommits = try await git.commitsAhead(
                    at: worktreePath,
                    baseBranch: baseRef,
                    resolution: commitsResolution
                ).commits
                let payload = CommitContextBuilder.buildForCommitEdit(
                    branch: branch,
                    base: baseRef,
                    nearbySubjects: nearbyCommits.map(subjectLine(from:)),
                    priorMessage: GitService.HeadMessage(subject: currentSubject, body: currentBody),
                    diff: diff
                )

                let message = try await AgentRunner.runPrompt(
                    agent: agent,
                    input: payload,
                    prompt: prompt,
                    target: executionTarget,
                    workingDirectory: worktreePath.path
                )
                guard !Task.isCancelled else { return }
                subject = message.subject
                bodyText = message.body
            } catch let runError as AgentRunError {
                if case .binaryNotFound = runError,
                   case .ssh = executionTarget {
                    appState.agentAvailabilityStore.invalidate(
                        target: executionTarget,
                        worktreePath: worktreePath.path
                    )
                    await appState.loadAgentAvailability(worktreePath: worktreePath, executionTarget: executionTarget)
                }
                self.error = runError.localizedDescription
            } catch {
                self.error = (error as NSError).localizedDescription
            }
        }
    }
}

private struct PendingCommitFileDrop: Equatable {
    let sha: String
    let file: CommitChangedFile
}

private struct PendingCommitHunkDrop: Equatable {
    let sha: String
    let path: String
    let hunk: ParsedDiff.Hunk
}

/// What the commit editor reads and changes: this Mac's git, or a paired host's.
struct CommitEditorGit {
    var details: @MainActor (_ sha: String) async throws -> (details: CommitDetails, rawSubject: String)
    var diff: @MainActor (_ sha: String, _ file: CommitChangedFile) async throws -> (diff: ParsedDiff, truncated: Bool)
    var edit: @MainActor (_ targetSha: String, _ action: CommitEditAction) async throws -> CommitEditResult
    /// After an edit lands: the local tab and right-pane bookkeeping, or the peer selection's new sha.
    var didEdit: @MainActor (_ result: CommitEditResult, _ title: String) async -> Void
    var generatesMessages: Bool

    /// A refusal shown as the editor's error.
    struct Refusal: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Today's behaviour: GitService, the checkpoint-lease guards, the center
    /// git mutation, and the right pane's comparison ref, else `baseRef`.
    @MainActor static func local(
        worktreePath: URL, worktreeId: String, tabId: TabID, baseRef: String, appState: AppState
    ) -> Self {
        let git = GitService()
        let leaseRefusal = Refusal(message: "Recover the interrupted checkpoint restore before editing commits.")
        return CommitEditorGit(
            details: { sha in
                async let detailsLoad = git.commitDetails(at: worktreePath, sha: sha)
                async let subjectLoad = git.rawCommitSubject(at: worktreePath, sha: sha)
                return try await (detailsLoad, subjectLoad)
            },
            diff: { sha, file in
                let diff = try await git.diff(worktreePath: worktreePath, sha: sha, file: file.path, originalPath: file.originalPath)
                return (diff, false)
            },
            edit: { targetSha, action in
                guard !appState.checkpointFileWritesDisabled(worktreeId: worktreeId) else { throw leaseRefusal }
                let comparisonRef = appState.rightPaneStore.commitEditorComparisonRef(worktreeId: worktreeId) ?? baseRef
                guard await !appState.checkpointFileWritesDisabledAfterDiscovery(worktreeId: worktreeId) else {
                    throw leaseRefusal
                }
                appState.beginCenterGitMutation(worktreeId: worktreeId)
                defer { appState.endCenterGitMutation(worktreeId: worktreeId) }
                return try await git.editCommit(worktreePath: worktreePath, baseRef: comparisonRef, targetSha: targetSha, action: action)
            },
            didEdit: { result, title in
                appState.tabs.updateCommitEditorShas(worktreeId: worktreeId, shaMap: result.shaMap)
                appState.tabs.updateCommitEditor(worktreeId: worktreeId, tabId: tabId, currentSha: result.currentSha, title: title)
                await appState.rightPaneStore.refresh(worktreeId: worktreeId)
            },
            generatesMessages: true
        )
    }

    /// A paired host's: it computes the comparison ref and refuses what its
    /// editor would. A hunk is sent by its index and header, never its content.
    @MainActor static func peer(
        _ selection: NativePeerCommitEditorSelection, hosts: NativePeerHosts, onEdited: @escaping @MainActor (CommitEditResult) -> Void
    ) -> Self {
        let diff: @MainActor (String, String) async throws -> (diff: ParsedDiff, truncated: Bool) = { sha, path in
            switch await hosts.read(.commitDiff(sha: sha, path: path), in: selection.worktree, serverId: selection.serverId) {
            case .commitDiffResult(_, _, _, let hunks, let truncated, let metadataNote)?:
                return (ParsedDiff(hunks: hunks.map(NativePeerWorkspace.hunk), metadataSummary: metadataNote), truncated)
            case .commitDiffFailed(_, _, _, let reason, let message)?:
                throw Refusal(message: NativePeerWorkspace.describe(reason, message: message))
            default:
                throw Refusal(message: NativePeerWorkspace.offlineMessage)
            }
        }
        return CommitEditorGit(
            details: { sha in
                let details = try await hosts.commitDetails(sha, in: selection.worktree, serverId: selection.serverId).get()
                return (details, details.info.rawSubject)
            },
            diff: { sha, file in try await diff(sha, file.path) },
            edit: { targetSha, action in
                let edit: HostCommitEdit
                switch action {
                case .message(let subject, let body):
                    edit = .message(subject: subject, body: body)
                case .dropFile(let path):
                    edit = .dropFile(path: path)
                case .dropHunk(let path, let hunk):
                    guard let index = try await diff(targetSha, path).diff.hunks.firstIndex(of: hunk) else {
                        throw Refusal(message: "This commit changed since it was shown. Refresh and try again.")
                    }
                    edit = .dropHunk(path: path, index: index, header: hunk.header)
                }
                return try await hosts.editCommit(
                    targetSha, edit, comparisonMode: selection.comparisonMode, in: selection.worktree, serverId: selection.serverId
                ).get()
            },
            didEdit: { result, _ in onEdited(result) },
            generatesMessages: false
        )
    }
}
