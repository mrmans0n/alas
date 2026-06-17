import SwiftUI

struct DraftCommitTabView: View {
    let worktreePath: URL
    let worktreeId: String
    let tabState: DraftCommitTabState
    @Bindable var appState: AppState

    @State private var subject: String = ""
    @State private var bodyText: String = ""
    @State private var amend: Bool = false
    @State private var busy = false
    @State private var error: String?
    @State private var amendPrefilled: Bool = false
    @State private var amendPrefilledSubject: String = ""
    @State private var amendPrefilledBody: String = ""
    @State private var amendWarning: Bool = false
    @State private var canAmend: Bool = true
    @State private var generation: Task<Void, Never>? = nil

    @State private var stagedSession: DiffReviewLoadedSession?
    @State private var selectedFileID: DiffReviewFileID?
    @State private var loadingSession = false
    @State private var railCollapsed = false

    @Environment(\.theme) private var theme
    private let git = GitService()

    private var diffPreferences: DiffPreferenceBindings {
        DiffPreferenceBindings(appState: appState)
    }

    private var trimmedSubject: String {
        subject.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasStaged: Bool {
        guard let rps = appState.rightPaneStore.activeState(worktreeId: worktreeId) else { return false }
        return rps.changes.contains { $0.stage == .staged }
    }
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

    /// Drives `refreshCanAmend()` re-firing when HEAD changes (e.g. an
    /// external commit on an unborn branch should enable Amend without
    /// needing a tab reopen). The value itself doesn't matter, only that
    /// it shifts when HEAD does.
    private var amendProbeKey: String {
        appState.rightPaneStore.activeState(worktreeId: worktreeId)?.currentHeadSHA ?? ""
    }

    // Computed property that overlays mutation actions onto the loaded session.
    // Reads `busy` fresh on each render so closures always see current value.
    private var sessionWithActions: DiffReviewLoadedSession? {
        guard let session = stagedSession else { return nil }
        let filesWithActions = session.files.map { model in
            var m = model
            m.stagedMutationActions = DiffReviewStagedMutationActions(
                unstageFile: {
                    unstageFileByPaths(path: model.summary.path, originalPath: model.summary.originalPath)
                },
                unstageHunk: { hunk in
                    unstageHunk(path: model.summary.path, hunk: hunk)
                },
                isHunkUnstageEnabled: { hunk in
                    !busy && model.summary.status == .modified && !hunk.lines.isEmpty
                }
            )
            return m
        }
        return DiffReviewLoadedSession(files: filesWithActions, summary: session.summary)
    }

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
            stagedDiffBody
        }
        .onAppear { hydrateFromTabState() }
        // Re-probe HEAD existence whenever the right-pane state observes a
        // HEAD-changing event (external commit, rebase, reset, etc.). On
        // mount the key is "" → "<sha>" so the task fires once.
        .task(id: amendProbeKey) { await refreshCanAmend() }
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
        .onChange(of: selectedFileID) { _, new in persist(selectedPath: new?.path) }
        .task(id: stagedKey) { await loadStagedSession() }
    }

    @ViewBuilder
    private var stagedDiffBody: some View {
        if loadingSession && stagedSession == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let session = sessionWithActions, !session.files.isEmpty {
            DiffReviewSurface(
                session: session,
                selectedFileID: $selectedFileID,
                railCollapsed: $railCollapsed,
                reviewSummaryCollapsed: .constant(false),
                layoutMode: diffPreferences.layoutMode,
                wrapLines: diffPreferences.wrapLines,
                showWhitespace: diffPreferences.showWhitespace,
                codeFontFamily: appState.config.code.fontFamily,
                codeFontSize: CGFloat(appState.config.code.fontSize),
                showsSourceBadges: false,
                showsRailDisplayControls: true,
                allowsDraftCommentCreation: false
            )
        } else {
            Text("No staged changes yet.\nStage files from the sidebar to start a commit.")
                .multilineTextAlignment(.center)
                .foregroundColor(theme.color("fg-dim"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func hydrateFromTabState() {
        subject = tabState.subject
        bodyText = tabState.bodyText
        amend = tabState.amend
        selectedFileID = tabState.selectedPath.map { DiffReviewFileID(namespace: "staged", path: $0) }
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

    @MainActor
    private func loadStagedSession() async {
        let token = stagedKey
        loadingSession = true
        error = nil
        defer {
            if stagedKey == token { loadingSession = false }
        }
        do {
            let session = try await StagedDiffLoader().load(worktreePath: worktreePath)
            guard !Task.isCancelled, stagedKey == token else { return }
            stagedSession = session
            synchronizeSelection(with: session)
        } catch is CancellationError {
            // ignore
        } catch {
            guard stagedKey == token else { return }
            stagedSession = nil
            self.error = (error as NSError).localizedDescription
        }
    }

    private func synchronizeSelection(with session: DiffReviewLoadedSession) {
        let fileIDs = session.files.map { $0.summary.id }
        if let sel = selectedFileID, fileIDs.contains(sel) {
            // keep current selection
        } else if let first = fileIDs.first {
            selectedFileID = first
            persist(selectedPath: first.path)
        } else {
            selectedFileID = nil
            persist(selectedPath: nil)
        }
    }

    private func unstageFileByPaths(path: String, originalPath: String?) {
        guard !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                var paths = [path]
                if let original = originalPath, !original.isEmpty {
                    paths.append(original)
                }
                try await git.unstage(worktreePath: worktreePath, files: paths)
                await loadStagedSession()
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
                await loadStagedSession()
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
