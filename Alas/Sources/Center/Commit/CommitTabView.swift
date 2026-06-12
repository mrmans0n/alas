// Alas/Sources/Center/Commit/CommitTabView.swift
import SwiftUI

struct CommitTabView: View {
    let worktreePath: URL
    let sha: String
    let worktreeId: String
    @Bindable var appState: AppState

    @State private var details: CommitDetails?
    @State private var loadingDetails = true
    @State private var detailsError: String?
    @State private var activeDetailsKey: String?

    @State private var selectedPath: String?
    @State private var diff: ParsedDiff = ParsedDiff(hunks: [])
    @State private var displayModel: DiffDisplayModel?
    @State private var displayModelKey: String?
    @State private var loadingDiff = false
    @State private var diffError: String?
    @State private var activeDiffKey: String?

    @State private var headerExpanded: Bool = false

    @Environment(\.theme) private var theme
    private let git = GitService()

    private static let minPaneWidth: CGFloat = 140
    private var diffPreferences: DiffPreferenceBindings {
        DiffPreferenceBindings(appState: appState)
    }

    private var diffTaskKey: String {
        "\(sha):\(selectedPath ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let details {
                CommitHeaderView(details: details, expanded: $headerExpanded)
                splitBody(details: details)
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
        .task(id: sha) { await loadDetails() }
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
                        let selectedDiffKey = "\(sha):\(path)"
                        let selectedDisplayModel = displayModelKey == selectedDiffKey ? displayModel : nil
                        let openAvailable = DiffOpenFileAvailability.isAvailable(
                            worktreePath: worktreePath, relativePath: path
                        )
                        CommitDiffView(
                            worktreePath: worktreePath,
                            sha: sha,
                            file: file,
                            path: path,
                            diff: diff,
                            displayModel: selectedDisplayModel,
                            loading: loadingDiff,
                            error: diffError,
                            codeFontFamily: appState.config.code.fontFamily,
                            codeFontSize: CGFloat(appState.config.code.fontSize),
                            layoutMode: diffPreferences.layoutMode,
                            wrapLines: diffPreferences.wrapLines,
                            showWhitespace: diffPreferences.showWhitespace,
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
        let requestedKey = sha
        activeDetailsKey = requestedKey
        loadingDetails = true
        detailsError = nil
        details = nil
        activeDiffKey = nil
        selectedPath = nil
        diff = ParsedDiff(hunks: [])
        displayModel = nil
        displayModelKey = nil
        loadingDiff = false
        diffError = nil
        defer {
            if activeDetailsKey == requestedKey { loadingDetails = false }
        }
        do {
            let d = try await git.commitDetails(at: worktreePath, sha: sha)
            guard !Task.isCancelled, activeDetailsKey == requestedKey else { return }
            self.details = d
            self.selectedPath = d.files.first?.path
        } catch {
            guard !Task.isCancelled, activeDetailsKey == requestedKey else { return }
            self.detailsError = (error as NSError).localizedDescription
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
        let requestedKey = "\(sha):\(path)"
        activeDiffKey = requestedKey
        loadingDiff = true
        diffError = nil
        displayModel = nil
        displayModelKey = nil
        defer {
            if activeDiffKey == requestedKey { loadingDiff = false }
        }
        do {
            // For renames AND copies, forward the original path so git can
            // emit a proper rename/copy header. GitService.diff post-slices
            // the multi-file output down to just this file's section, so a
            // C row whose source was also modified won't pull in the
            // source's hunks.
            let loaded = try await git.diff(
                worktreePath: worktreePath,
                sha: sha,
                file: path,
                originalPath: file.originalPath
            )
            guard !Task.isCancelled, activeDiffKey == requestedKey else { return }
            let loadedModel = await Task.detached(priority: .userInitiated) {
                DiffDisplayModelBuilder.build(diff: loaded, filePath: path)
            }.value
            guard !Task.isCancelled, activeDiffKey == requestedKey else { return }
            self.diff = loaded
            self.displayModel = loadedModel
            self.displayModelKey = requestedKey
        } catch {
            guard !Task.isCancelled, activeDiffKey == requestedKey else { return }
            self.diffError = (error as NSError).localizedDescription
        }
    }
}
