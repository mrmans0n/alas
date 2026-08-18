import SwiftUI

struct CommitEditorTabView: View {
    let worktreePath: URL
    let worktreeId: String
    let tabState: CommitEditorTabState
    @Bindable var appState: AppState
    var onStartupRecoveryReady: () -> Void = {}

    @State private var details: CommitDetails?
    @State private var loadingDetails = true
    @State private var activeDetailsKey: String?

    @State private var selectedPath: String?
    @State private var diff: ParsedDiff = ParsedDiff(hunks: [])
    @State private var displayModel: DiffDisplayModel?
    @State private var displayModelKey: String?
    @State private var loadingDiff = false
    @State private var activeDiffKey: String?

    @State private var subject = ""
    @State private var bodyText = ""
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
        "\(tabState.currentSha):\(selectedPath ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let details {
                CommitMessageEditorView(
                    subject: $subject,
                    bodyText: $bodyText,
                    aiToolId: appState.bind(\.changes.aiToolId),
                    title: tabState.title,
                    busy: busy,
                    error: error,
                    availableAgents: appState.agentRegistry.enabled(),
                    onGenerate: generateMessage,
                    primaryAction: CommitPrimaryAction(
                        label: "Save message",
                        savedLabel: "Saved",
                        isEnabled: dirty && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        showSavedState: !dirty,
                        handler: saveMessage
                    )
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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .task(id: tabState.currentSha) {
            await loadDetails()
            onStartupRecoveryReady()
        }
        .task(id: diffTaskKey) {
            await loadDiffIfNeeded()
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
                CommitFilesListView(
                    files: details.files,
                    selectedPath: $selectedPath,
                    onDropFile: { pendingDropFile = PendingCommitFileDrop(sha: tabState.currentSha, file: $0) },
                    dropFileEnabled: canDropFile,
                    dragPayload: { file in
                        .commitFile(
                            worktreePath: worktreePath,
                            sha: tabState.currentSha,
                            file: file
                        )
                    }
                )
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
                        let openAvailable = DiffOpenFileAvailability.isAvailable(
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
        displayModel = nil
        displayModelKey = nil
        loadingDiff = false
        defer {
            if activeDetailsKey == requestedKey { loadingDetails = false }
        }
        do {
            async let detailsLoad = git.commitDetails(at: worktreePath, sha: tabState.currentSha)
            async let subjectLoad = git.rawCommitSubject(at: worktreePath, sha: tabState.currentSha)
            let (loadedDetails, loadedSubject) = try await (detailsLoad, subjectLoad)
            guard !Task.isCancelled, activeDetailsKey == requestedKey else { return }
            details = loadedDetails
            selectedPath = loadedDetails.files.first?.path
            if !dirty {
                subject = loadedSubject
                bodyText = loadedDetails.body
                savedSubject = loadedSubject
                savedBodyText = loadedDetails.body
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
            let loaded = try await git.diff(
                worktreePath: worktreePath,
                sha: tabState.currentSha,
                file: path,
                originalPath: file.originalPath
            )
            guard !Task.isCancelled, activeDiffKey == requestedKey else { return }
            let loadedModel = await Task.detached(priority: .userInitiated) {
                DiffDisplayModelBuilder.build(diff: loaded, filePath: path)
            }.value
            guard !Task.isCancelled, activeDiffKey == requestedKey else { return }
            diff = loaded
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
        !busy && !dirty && file.status == "M" && !hunk.lines.isEmpty
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
        let tabId = tabState.id
        let baseRef = appState.rightPaneStore.commitEditorComparisonRef(worktreeId: worktreeId) ?? tabState.baseRef

        busy = true
        error = nil

        Task<Void, Never> { @MainActor in
            defer { busy = false }
            do {
                let result = try await git.editCommit(
                    worktreePath: worktreePath,
                    baseRef: baseRef,
                    targetSha: targetSha,
                    action: action
                )
                async let detailsLoad = git.commitDetails(at: worktreePath, sha: result.currentSha)
                async let subjectLoad = git.rawCommitSubject(at: worktreePath, sha: result.currentSha)
                let (refreshedDetails, refreshedSubject) = try await (detailsLoad, subjectLoad)

                details = refreshedDetails
                selectedPath = refreshedDetails.files.first?.path
                diff = ParsedDiff(hunks: [])
                activeDiffKey = nil
                subject = refreshedSubject
                bodyText = refreshedDetails.body
                savedSubject = refreshedSubject
                savedBodyText = refreshedDetails.body

                appState.tabs.updateCommitEditorShas(worktreeId: worktreeId, shaMap: result.shaMap)
                appState.tabs.updateCommitEditor(
                    worktreeId: worktreeId,
                    tabId: tabId,
                    currentSha: result.currentSha,
                    title: tabTitle(from: refreshedDetails)
                )
                await appState.rightPaneStore.refresh(worktreeId: worktreeId)
            } catch {
                self.error = (error as NSError).localizedDescription
            }
        }
    }

    private func generateMessage() {
        guard !busy else { return }
        guard let agent = appState.agent(id: appState.config.changes.aiToolId) else {
            error = "Select an AI tool to generate a commit message."
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
                    workingDirectory: worktreePath.path
                )
                guard !Task.isCancelled else { return }
                subject = message.subject
                bodyText = message.body
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
