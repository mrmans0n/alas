import AppKit
import SwiftUI

struct ReviewTabView: View {
    let worktree: Worktree
    let tabState: ReviewPRTabState
    let appState: AppState
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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(theme.color("line"))
            CIStatusStrip(checks: reviewRequest?.checks ?? [])
            OutdatedThreadsDrawer(threads: outdatedAndFileLevelThreads)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
        .task(id: loadKey) {
            await loadSession()
        }
    }

    // MARK: - Derived state from snapshot

    private var activeSnapshot: ReviewLoopSnapshot? {
        appState.rightPaneStore.activeState(worktreeId: tabState.worktreeId)?.reviewLoop.snapshot
    }

    private var matchedSnapshot: ReviewLoopSnapshot? {
        guard let snap = activeSnapshot, tabState.matches(snap) else { return nil }
        return snap
    }

    private var reviewRequest: ReviewRequest? {
        matchedSnapshot?.reviewRequest
    }

    private var outdatedAndFileLevelThreads: [ReviewThread] {
        (reviewRequest?.threads ?? []).filter { $0.isFileLevel || $0.isOutdated }
    }

    private var activeThreads: [ReviewThread] {
        reviewRequest?.threads ?? []
    }

    // MARK: - Load key (mirrors ReviewChangesTabView)

    private var loadKey: String {
        ReviewChangesLoadKey.build(
            tabID: tabState.id,
            worktreePath: worktree.path,
            rightPaneState: appState.rightPaneStore.activeState(worktreeId: worktree.id)
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            stateView(title: "Loading changes...", detail: nil, color: theme.color("fg-dim"))
        } else if let loadError {
            stateView(title: "Could not load review changes", detail: loadError, color: theme.color("del"))
        } else if let session, session.files.isEmpty {
            stateView(title: "No changes to review", detail: "This worktree has no staged or unstaged file diffs.", color: theme.color("fg-dim"))
        } else if let session {
            reviewSurface(session)
        } else {
            stateView(title: "No changes loaded", detail: nil, color: theme.color("fg-dim"))
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
            threads: activeThreads
        )
    }

    private func makeLSPContext(relativePath: String) -> DiffPaneLSPContext? {
        let fileURL = worktree.path.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let language = appState.lsp.language(forFileExtension: (relativePath as NSString).pathExtension)
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
        session = nil
        defer {
            if requestedLoadToken.isActive(activeKey: activeLoadKey, activeID: activeLoadID) {
                isLoading = false
                activeLoadKey = nil
            }
        }

        do {
            let loaded = try await loader.load(worktreePath: worktree.path)
            guard
                requestedLoadToken.isActive(activeKey: activeLoadKey, activeID: activeLoadID),
                !Task.isCancelled
            else { return }
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

    private var diffPreferences: DiffPreferenceBindings {
        DiffPreferenceBindings(appState: appState)
    }
}
