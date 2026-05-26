import SwiftUI

struct DraftCommitTabView: View {
    let worktreePath: URL
    let worktreeId: String
    let tabState: DraftCommitTabState
    @Bindable var appState: AppState

    @State private var subject: String = ""
    @State private var bodyText: String = ""
    @State private var amend: Bool = false
    @State private var selectedPath: String?
    @State private var stagedFiles: [CommitChangedFile] = []
    @State private var diff: ParsedDiff = ParsedDiff(hunks: [])
    @State private var busy = false
    @State private var error: String?
    @State private var loadingFiles = false
    @State private var loadingDiff = false
    @State private var amendPrefilled: Bool = false
    @State private var amendPrefilledSubject: String = ""
    @State private var amendPrefilledBody: String = ""
    @State private var amendWarning: Bool = false
    @State private var canAmend: Bool = true
    @State private var generation: Task<Void, Never>? = nil

    @Environment(\.theme) private var theme
    private let git = GitService()

    private static let minPaneWidth: CGFloat = 140

    private var trimmedSubject: String {
        subject.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasStaged: Bool { !stagedFiles.isEmpty }
    private var canCommit: Bool { hasStaged && !trimmedSubject.isEmpty && !busy }

    /// A key that changes whenever the staged set changes in the sidebar.
    /// SwiftUI tracks reads of `@Observable` properties, so this recomputes
    /// automatically when `rps.changes` mutates.
    private var stagedKey: String {
        guard let rps = appState.rightPaneStore.activeState(worktreeId: worktreeId) else {
            return "no-rps"
        }
        let staged = rps.changes
            .filter { $0.stage == .staged }
            .sorted(by: { $0.path < $1.path })
            .map { "\($0.path):\($0.add):\($0.del)" }
            .joined(separator: "|")
        return "\(rps.changes.count):\(staged):\(rps.indexFingerprint)"
    }

    private var diffKey: String { "\(stagedKey):\(selectedPath ?? "")" }

    var body: some View {
        VStack(spacing: 0) {
            CommitMessageEditorView(
                subject: $subject,
                bodyText: $bodyText,
                aiToolId: appState.bind(\.changes.aiToolId),
                title: amend ? "Amend HEAD" : "Draft commit",
                busy: busy,
                error: error,
                availableAgents: appState.agentRegistry.enabled(),
                onGenerate: handleGenerate,
                primaryAction: CommitPrimaryAction(
                    label: amend ? "Amend" : "Commit",
                    savedLabel: nil,
                    isEnabled: canCommit,
                    showSavedState: false,
                    keyboardShortcut: appState.shortcut(for: .commitInComposer),
                    handler: runCommit
                ),
                accessory: AnyView(
                    Toggle(isOn: $amend) {
                        Text("Amend").font(.system(size: 11)).foregroundColor(theme.color("fg-dim"))
                    }
                    .toggleStyle(.checkbox)
                    .disabled(busy || !canAmend)
                    .help(canAmend ? "" : "No previous commit to amend")
                )
            )
            if amend && amendWarning {
                Text("Amending a pushed commit will rewrite history.")
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.color("warn"))
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            splitBody
        }
        .onAppear { hydrateFromTabState() }
        .task { await refreshCanAmend() }
        .onChange(of: subject) { _, new in persist(subject: new) }
        .onChange(of: bodyText) { _, new in persist(body: new) }
        .onChange(of: amend) { _, new in
            persist(amend: new)
            if new {
                Task { await applyAmendPrefill() }
            } else {
                clearAmendPrefillIfUnchanged()
            }
        }
        .onChange(of: selectedPath) { _, new in persist(selectedPath: new) }
        .task(id: stagedKey) { await loadStaged() }
        .task(id: diffKey) { await loadDiff() }
    }

    @ViewBuilder
    private var splitBody: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let ratio = max(0.15, min(0.7, appState.config.commitDetailSplitRatio))
            let leftWidth = max(Self.minPaneWidth, total * ratio)
            HStack(spacing: 0) {
                CommitFilesListView(
                    files: stagedFiles,
                    selectedPath: $selectedPath,
                    onDropFile: { file in unstageFile(file) },
                    dropFileEnabled: { _ in !busy }
                )
                .frame(width: leftWidth)
                DragHandle(axis: .horizontal, onDrag: { delta in
                    guard total > 0 else { return }
                    let newWidth = max(Self.minPaneWidth, min(total - Self.minPaneWidth, leftWidth + delta))
                    appState.config.commitDetailSplitRatio = newWidth / total
                    appState.saveConfig()
                })
                if hasStaged, let path = selectedPath,
                   let file = stagedFiles.first(where: { $0.path == path }) {
                    CommitDiffView(
                        worktreePath: worktreePath,
                        sha: "INDEX",
                        file: file,
                        path: path,
                        diff: diff,
                        loading: loadingDiff,
                        error: nil,
                        codeFontFamily: appState.config.code.fontFamily,
                        codeFontSize: CGFloat(appState.config.code.fontSize),
                        onOpenFile: nil,
                        onDropHunk: { hunk in unstageHunk(path: path, hunk: hunk) },
                        dropHunkEnabled: { file, hunk in !busy && file.status == "M" && !hunk.lines.isEmpty }
                    )
                } else {
                    Text(hasStaged ? "Select a file" : "No staged changes yet.\nStage files from the sidebar to start a commit.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(theme.color("fg-dim"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func hydrateFromTabState() {
        subject = tabState.subject
        bodyText = tabState.bodyText
        amend = tabState.amend
        selectedPath = tabState.selectedPath
    }

    private func persist(subject: String? = nil, body: String? = nil, amend: Bool? = nil, selectedPath: String?? = nil) {
        appState.tabs.updateDraftCommit(worktreeId: worktreeId, tabId: tabState.id) { s in
            if let subject { s.subject = subject }
            if let body { s.bodyText = body }
            if let amend { s.amend = amend }
            if let selectedPath { s.selectedPath = selectedPath }
        }
    }

    private func applyAmendPrefill() async {
        let head = (try? await git.headMessage(worktreePath: worktreePath)) ?? nil
        guard amend else { return }
        if let head,
           let prefill = DraftAmendPrefill.apply(
               priorSubject: head.subject,
               priorBody: head.body,
               currentSubject: subject,
               currentBody: bodyText
           ) {
            subject = prefill.subject
            bodyText = prefill.body
            amendPrefilledSubject = prefill.subject
            amendPrefilledBody = prefill.body
            amendPrefilled = true
        }
        let pushed = (try? await git.isHeadAtOrBehindUpstream(worktreePath: worktreePath)) ?? false
        guard amend else { return }
        amendWarning = pushed
    }

    private func clearAmendPrefillIfUnchanged() {
        amendWarning = false
        guard DraftAmendPrefill.shouldClear(
            wasPrefilled: amendPrefilled,
            prefilledSubject: amendPrefilledSubject,
            prefilledBody: amendPrefilledBody,
            currentSubject: subject,
            currentBody: bodyText
        ) else { return }
        subject = ""
        bodyText = ""
        amendPrefilled = false
        amendPrefilledSubject = ""
        amendPrefilledBody = ""
    }

    private func refreshCanAmend() async {
        let head = (try? await git.hasHead(worktreePath: worktreePath)) ?? true
        canAmend = head
    }

    private func handleGenerate() {
        if busy {
            generation?.cancel()
            // Do not clear generation or busy here — runGenerate's defer handles both.
            return
        }
        runGenerate()
    }

    private func runGenerate() {
        guard let agent = appState.agent(id: appState.config.changes.aiToolId) else {
            error = "Select an AI tool to generate a commit message."
            return
        }
        let amendSnapshot = amend
        let wt = worktreePath
        let prompt = appState.config.changes.prompt
        let baseBranch = appState.rightPaneStore.commitEditorComparisonRef(worktreeId: worktreeId) ?? "HEAD"

        busy = true
        error = nil

        generation = Task { @MainActor in
            defer {
                busy = false
                generation = nil
            }
            do {
                let priorMessage: GitService.HeadMessage?
                if amendSnapshot {
                    priorMessage = (try? await git.headMessage(worktreePath: wt)) ?? nil
                } else {
                    priorMessage = nil
                }
                let diffResult = try await Process.git(["diff", "--cached", "--no-color"], cwd: wt)
                let recentResult = try await Process.git(["log", "-3", "--pretty=format:%s"], cwd: wt)
                let branchResult = try await Process.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: wt)
                try Task.checkCancellation()
                let recentSubjects = recentResult.stdout
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init)
                let branchRaw = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let branch: String? = branchRaw == "HEAD" ? nil : branchRaw

                let payload = CommitContextBuilder.build(
                    branch: branch,
                    base: baseBranch,
                    recentSubjects: recentSubjects,
                    priorMessage: priorMessage,
                    diff: diffResult.stdout
                )
                let message = try await AgentRunner.runPrompt(
                    agent: agent,
                    input: payload,
                    prompt: prompt,
                    workingDirectory: wt.path
                )
                guard !Task.isCancelled else { return }
                subject = message.subject
                bodyText = message.body
            } catch is CancellationError {
                // user-cancelled
            } catch {
                self.error = (error as NSError).localizedDescription
            }
        }
    }

    private func loadStaged() async {
        loadingFiles = true
        defer { loadingFiles = false }
        do {
            let files = try await git.stagedChangedFiles(at: worktreePath)
            guard !Task.isCancelled else { return }
            stagedFiles = files
            if let sel = selectedPath, !files.contains(where: { $0.path == sel }) {
                selectedPath = files.first?.path
            } else if selectedPath == nil {
                selectedPath = files.first?.path
            }
        } catch {
            self.error = (error as NSError).localizedDescription
        }
    }

    private func loadDiff() async {
        guard let path = selectedPath,
              stagedFiles.first(where: { $0.path == path }) != nil else {
            diff = ParsedDiff(hunks: [])
            return
        }
        loadingDiff = true
        defer { loadingDiff = false }
        do {
            let loaded = try await git.diff(worktreePath: worktreePath, file: path, staged: true)
            guard !Task.isCancelled else { return }
            diff = loaded
        } catch {
            self.error = (error as NSError).localizedDescription
        }
    }

    private func unstageFile(_ file: CommitChangedFile) {
        guard !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                // For staged renames git needs both the old and the new
                // path; passing only `file.path` leaves the old-path
                // deletion staged. `originalPath` is non-nil for R/C entries.
                var paths = [file.path]
                if let original = file.originalPath, !original.isEmpty {
                    paths.append(original)
                }
                try await git.unstage(worktreePath: worktreePath, files: paths)
                await loadStaged()
                await loadDiff()
                await appState.rightPaneStore.refresh(worktreeId: worktreeId)
            } catch {
                self.error = (error as NSError).localizedDescription
            }
        }
    }

    private func unstageHunk(path: String, hunk: ParsedDiff.Hunk) {
        guard !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await git.unstageHunk(worktreePath: worktreePath, path: path, hunk: hunk)
                await loadStaged()
                await loadDiff()
                await appState.rightPaneStore.refresh(worktreeId: worktreeId)
            } catch {
                self.error = (error as NSError).localizedDescription
            }
        }
    }

    private func runCommit() {
        guard !busy else { return }
        let subjectSnapshot = trimmedSubject
        let bodySnapshot = bodyText
        let amendSnapshot = amend

        busy = true
        error = nil

        Task { @MainActor in
            defer { busy = false }
            do {
                let newSha = try await git.commit(
                    worktreePath: worktreePath,
                    subject: subjectSnapshot,
                    body: bodySnapshot,
                    amend: amendSnapshot
                )
                let shortSha = String(newSha.prefix(7))
                let title = "\(shortSha) \(subjectSnapshot)"
                let baseRef: String
                if let ref = appState.rightPaneStore.commitEditorComparisonRef(worktreeId: worktreeId) {
                    baseRef = ref
                } else {
                    // No active comparison — try the new commit's first parent. If the
                    // new commit has no parent (root commit), fall back to the canonical
                    // empty-tree SHA so the commit editor can still render a diff.
                    let parentResult = try? await Process.git(["rev-parse", "--verify", "\(newSha)^"], cwd: worktreePath)
                    if let pr = parentResult, pr.exitCode == 0 {
                        baseRef = pr.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        baseRef = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
                    }
                }
                _ = appState.tabs.replaceDraftWithCommitEditor(
                    worktreeId: worktreeId,
                    draftTabId: tabState.id,
                    baseRef: baseRef,
                    newSha: newSha,
                    title: title
                )
                await appState.rightPaneStore.refresh(worktreeId: worktreeId)
                await refreshCanAmend()
            } catch {
                self.error = (error as NSError).localizedDescription
            }
        }
    }
}
