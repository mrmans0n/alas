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
            .map(\.path)
            .sorted()
            .joined(separator: "|")
        return "\(rps.changes.count):\(staged)"
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
                onGenerate: {},     // wired in Task 7
                primaryAction: CommitPrimaryAction(
                    label: amend ? "Amend" : "Commit",
                    savedLabel: nil,
                    isEnabled: canCommit,
                    showSavedState: false,
                    handler: runCommit
                )
            )
            splitBody
        }
        .onAppear { hydrateFromTabState() }
        .onChange(of: subject) { _, new in persist(subject: new) }
        .onChange(of: bodyText) { _, new in persist(body: new) }
        .onChange(of: amend) { _, new in persist(amend: new) }
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
                try await git.unstage(worktreePath: worktreePath, files: [file.path])
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
                let baseRef = appState.rightPaneStore.commitEditorComparisonRef(worktreeId: worktreeId) ?? "HEAD~1"
                _ = appState.tabs.replaceDraftWithCommitEditor(
                    worktreeId: worktreeId,
                    draftTabId: tabState.id,
                    baseRef: baseRef,
                    newSha: newSha,
                    title: title
                )
                await appState.rightPaneStore.refresh(worktreeId: worktreeId)
            } catch {
                self.error = (error as NSError).localizedDescription
            }
        }
    }
}
