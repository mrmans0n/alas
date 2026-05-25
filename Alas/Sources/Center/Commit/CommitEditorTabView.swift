import SwiftUI

struct CommitEditorTabView: View {
    let worktreePath: URL
    let worktreeId: String
    let tabState: CommitEditorTabState
    @Bindable var appState: AppState

    @State private var details: CommitDetails?
    @State private var loadingDetails = true
    @State private var activeDetailsKey: String?

    @State private var selectedPath: String?
    @State private var diff: ParsedDiff = ParsedDiff(hunks: [])
    @State private var loadingDiff = false
    @State private var activeDiffKey: String?

    @State private var subject = ""
    @State private var bodyText = ""
    @State private var savedSubject = ""
    @State private var savedBodyText = ""
    @State private var busy = false
    @State private var error: String?

    @Environment(\.theme) private var theme
    private let git = GitService()

    private static let minPaneWidth: CGFloat = 140

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
                    dirty: dirty,
                    error: error,
                    availableAgents: appState.agentRegistry.enabled(),
                    onGenerate: generateMessage,
                    onSave: saveMessage
                )
                splitBody(details: details)
            } else if loadingDetails {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .task(id: tabState.currentSha) { await loadDetails() }
        .task(id: diffTaskKey) { await loadDiffIfNeeded() }
    }

    @ViewBuilder
    private func splitBody(details: CommitDetails) -> some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let ratio = max(0.15, min(0.7, appState.config.commitDetailSplitRatio))
            let leftWidth = max(Self.minPaneWidth, total * ratio)
            HStack(spacing: 0) {
                CommitFilesListView(files: details.files, selectedPath: $selectedPath)
                    .frame(width: leftWidth)
                DragHandle(axis: .horizontal, onDrag: { delta in
                    guard total > 0 else { return }
                    let newWidth = max(Self.minPaneWidth, min(total - Self.minPaneWidth, leftWidth + delta))
                    appState.config.commitDetailSplitRatio = newWidth / total
                    appState.saveConfig()
                })
                Group {
                    if let path = selectedPath,
                       let file = details.files.first(where: { $0.path == path }) {
                        let openAvailable = DiffOpenFileAvailability.isAvailable(
                            worktreePath: worktreePath, relativePath: path
                        )
                        CommitDiffView(
                            worktreePath: worktreePath,
                            sha: tabState.currentSha,
                            file: file,
                            path: path,
                            diff: diff,
                            loading: loadingDiff,
                            error: error,
                            codeFontFamily: appState.config.code.fontFamily,
                            codeFontSize: CGFloat(appState.config.code.fontSize),
                            onOpenFile: openAvailable
                                ? { appState.openFile(relativePath: path, worktreeId: worktreeId) }
                                : nil
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
        loadingDiff = false
        defer {
            if activeDetailsKey == requestedKey { loadingDetails = false }
        }
        do {
            let loadedDetails = try await git.commitDetails(at: worktreePath, sha: tabState.currentSha)
            guard !Task.isCancelled, activeDetailsKey == requestedKey else { return }
            details = loadedDetails
            selectedPath = loadedDetails.files.first?.path
            let loadedSubject = editorSubject(from: loadedDetails)
            subject = loadedSubject
            bodyText = loadedDetails.body
            savedSubject = loadedSubject
            savedBodyText = loadedDetails.body
        } catch {
            guard !Task.isCancelled, activeDetailsKey == requestedKey else { return }
            self.error = (error as NSError).localizedDescription
        }
    }

    private func loadDiffIfNeeded() async {
        guard let path = selectedPath,
              let file = details?.files.first(where: { $0.path == path }) else { return }
        let requestedKey = "\(tabState.currentSha):\(path)"
        activeDiffKey = requestedKey
        loadingDiff = true
        error = nil
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
            diff = loaded
        } catch {
            guard !Task.isCancelled, activeDiffKey == requestedKey else { return }
            self.error = (error as NSError).localizedDescription
        }
    }

    private func editorSubject(from details: CommitDetails) -> String {
        if let tag = details.info.conventionalTag {
            return "\(tag): \(details.info.subject)"
        }
        return details.info.subject
    }

    private func saveMessage() {
    }

    private func generateMessage() {
    }
}
