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

    @Environment(\.theme) private var theme
    private let git = GitService()

    private static let minPaneWidth: CGFloat = 140

    private var trimmedSubject: String {
        subject.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasStaged: Bool { !stagedFiles.isEmpty }
    private var canCommit: Bool { hasStaged && !trimmedSubject.isEmpty && !busy }

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
                    handler: {}     // wired in Task 5
                )
            )
            splitBody
        }
        .onAppear { hydrateFromTabState() }
        .onChange(of: subject) { _, new in persist(subject: new) }
        .onChange(of: bodyText) { _, new in persist(body: new) }
        .onChange(of: amend) { _, new in persist(amend: new) }
        .onChange(of: selectedPath) { _, new in persist(selectedPath: new) }
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
                    onDropFile: { _ in },       // wired in Task 6
                    dropFileEnabled: { _ in false }
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
                        loading: false,
                        error: nil,
                        codeFontFamily: appState.config.code.fontFamily,
                        codeFontSize: CGFloat(appState.config.code.fontSize),
                        onOpenFile: nil,
                        onDropHunk: { _ in },        // wired in Task 6
                        dropHunkEnabled: { _, _ in false }
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
}
