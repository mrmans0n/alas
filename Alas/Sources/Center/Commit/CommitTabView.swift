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

    @State private var reviewSession: DiffReviewLoadedSession?
    @State private var loadingReviewSession = false
    @State private var reviewSessionError: String?
    @State private var selectedReviewFileID: DiffReviewFileID?
    @State private var railCollapsed = false
    @State private var activeReviewKey: String?
    @State private var activeReviewID = UUID()

    @State private var headerExpanded: Bool = false

    @Environment(\.theme) private var theme
    private let git = GitService()
    private let reviewLoader = CommitReviewLoader()

    private var diffPreferences: DiffPreferenceBindings {
        DiffPreferenceBindings(appState: appState)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let details {
                CommitHeaderView(details: details, expanded: $headerExpanded)
                commitReviewContent(details: details)
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
    }

    @ViewBuilder
    private func commitReviewContent(details: CommitDetails) -> some View {
        let contentState = CommitReviewContentState.resolve(
            detailsFileCount: details.files.count,
            loadingReviewSession: loadingReviewSession,
            reviewSessionFileCount: reviewSession?.files.count,
            reviewSessionError: reviewSessionError
        )

        switch contentState {
        case .loading:
            Spinner()
                .frame(width: 20, height: 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error:
            VStack(spacing: 8) {
                Text("Could not load commit diffs")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.color("del"))
                Text(reviewSessionError ?? "")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                AlasButton(title: "Retry", style: .subtle) {
                    Task { await loadReviewSession(details: details) }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if let reviewSession {
                CommitReviewBody(
                    session: reviewSession,
                    selectedFileID: $selectedReviewFileID,
                    railCollapsed: $railCollapsed,
                    layoutMode: diffPreferences.layoutMode,
                    wrapLines: diffPreferences.wrapLines,
                    showWhitespace: diffPreferences.showWhitespace,
                    codeFontFamily: appState.config.code.fontFamily,
                    codeFontSize: CGFloat(appState.config.code.fontSize),
                    worktreeId: worktreeId,
                    worktreePath: worktreePath,
                    appState: appState
                )
            } else {
                Spinner()
                    .frame(width: 20, height: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .empty:
            Text("No files changed in this commit")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.color("fg-dim"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadDetails() async {
        let requestedKey = sha
        activeDetailsKey = requestedKey
        loadingDetails = true
        detailsError = nil
        details = nil
        reviewSession = nil
        reviewSessionError = nil
        selectedReviewFileID = nil
        activeReviewKey = nil
        activeReviewID = UUID()
        loadingReviewSession = false
        defer {
            if activeDetailsKey == requestedKey { loadingDetails = false }
        }
        do {
            let d = try await git.commitDetails(at: worktreePath, sha: sha)
            guard !Task.isCancelled, activeDetailsKey == requestedKey else { return }
            self.details = d
            await loadReviewSession(details: d)
        } catch {
            guard !Task.isCancelled, activeDetailsKey == requestedKey else { return }
            self.detailsError = (error as NSError).localizedDescription
        }
    }

    private func loadReviewSession(details: CommitDetails) async {
        guard CommitReviewLoadIdentity.isCurrent(details: details, currentDetails: self.details, sha: sha) else {
            return
        }
        let requestedToken = CommitReviewLoadToken.next(key: reviewKey(details: details))
        activeReviewKey = requestedToken.key
        activeReviewID = requestedToken.id
        loadingReviewSession = true
        reviewSessionError = nil
        reviewSession = nil
        defer {
            if requestedToken.isActive(activeKey: activeReviewKey, activeID: activeReviewID) {
                loadingReviewSession = false
                activeReviewKey = nil
            }
        }
        do {
            let loaded = try await reviewLoader.load(
                worktreePath: worktreePath,
                sha: sha,
                files: details.files,
                openFileForPath: openFileAction(for:)
            )
            guard
                !Task.isCancelled,
                requestedToken.isActive(activeKey: activeReviewKey, activeID: activeReviewID),
                CommitReviewLoadIdentity.isCurrent(details: details, currentDetails: self.details, sha: sha)
            else { return }
            reviewSession = loaded
            selectedReviewFileID = selectedReviewFileID.flatMap { selected in
                loaded.summary.files.contains { $0.id == selected } ? selected : loaded.summary.files.first?.id
            } ?? loaded.summary.files.first?.id
        } catch is CancellationError {
        } catch {
            guard
                !Task.isCancelled,
                requestedToken.isActive(activeKey: activeReviewKey, activeID: activeReviewID),
                CommitReviewLoadIdentity.isCurrent(details: details, currentDetails: self.details, sha: sha)
            else { return }
            reviewSessionError = (error as NSError).localizedDescription
        }
    }

    private func openFileAction(for path: String) -> (() -> Void)? {
        guard DiffOpenFileAvailability.isAvailable(worktreePath: worktreePath, relativePath: path) else {
            return nil
        }
        return {
            Task { @MainActor in
                appState.openFile(relativePath: path, worktreeId: worktreeId)
            }
        }
    }

    private func reviewKey(details: CommitDetails) -> String {
        let fileKey = details.files
            .map { file in
                [
                    file.path,
                    file.originalPath ?? "",
                    file.status,
                    "\(file.add)",
                    "\(file.del)",
                ].joined(separator: "\u{1f}")
            }
            .joined(separator: "\u{1e}")
        return "\(sha)\u{0}\(details.info.sha)\u{0}\(details.files.count)\u{0}\(fileKey)"
    }
}

struct CommitReviewLoadToken: Equatable {
    let key: String
    let id: UUID

    static func next(key: String) -> CommitReviewLoadToken {
        CommitReviewLoadToken(key: key, id: UUID())
    }

    func isActive(activeKey: String?, activeID: UUID) -> Bool {
        activeKey == key && activeID == id
    }
}

enum CommitReviewLoadIdentity {
    static func isCurrent(details: CommitDetails, currentDetails: CommitDetails?, sha: String) -> Bool {
        details.info.sha == sha && currentDetails?.info.sha == details.info.sha
    }
}

enum CommitReviewContentState: Equatable {
    case loading
    case error
    case loaded
    case empty

    static func resolve(
        detailsFileCount: Int,
        loadingReviewSession: Bool,
        reviewSessionFileCount: Int?,
        reviewSessionError: String?
    ) -> CommitReviewContentState {
        if loadingReviewSession {
            return .loading
        }
        if reviewSessionError != nil {
            return .error
        }
        if let reviewSessionFileCount {
            return reviewSessionFileCount > 0 ? .loaded : .empty
        }
        return detailsFileCount > 0 ? .loading : .empty
    }
}

struct CommitReviewBody: View {
    let session: DiffReviewLoadedSession
    @Binding var selectedFileID: DiffReviewFileID?
    @Binding var railCollapsed: Bool
    @Binding var layoutMode: DiffLayoutMode
    @Binding var wrapLines: Bool
    @Binding var showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat
    var worktreeId: String? = nil
    var worktreePath: URL? = nil
    var appState: AppState? = nil

    init(
        session: DiffReviewLoadedSession,
        selectedFileID: Binding<DiffReviewFileID?>,
        railCollapsed: Binding<Bool>,
        layoutMode: Binding<DiffLayoutMode>,
        wrapLines: Binding<Bool>,
        showWhitespace: Binding<Bool>,
        codeFontFamily: String,
        codeFontSize: CGFloat,
        worktreeId: String? = nil,
        worktreePath: URL? = nil,
        appState: AppState? = nil
    ) {
        self.session = session
        self._selectedFileID = selectedFileID
        self._railCollapsed = railCollapsed
        self._layoutMode = layoutMode
        self._wrapLines = wrapLines
        self._showWhitespace = showWhitespace
        self.codeFontFamily = codeFontFamily
        self.codeFontSize = codeFontSize
        self.worktreeId = worktreeId
        self.worktreePath = worktreePath
        self.appState = appState
    }

    var body: some View {
        DiffReviewSurface(
            session: session,
            selectedFileID: $selectedFileID,
            railCollapsed: $railCollapsed,
            layoutMode: $layoutMode,
            wrapLines: $wrapLines,
            showWhitespace: $showWhitespace,
            codeFontFamily: codeFontFamily,
            codeFontSize: codeFontSize,
            showsSourceBadges: false,
            showsRailDisplayControls: true,
            lspContextForFile: { file in
                makeLSPContext(relativePath: file.summary.path)
            }
        )
        .accessibilityIdentifier("commit-review-body")
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "commit-review-body",
                label: "Commit review"
            )
        )
    }

    private func makeLSPContext(relativePath: String) -> DiffPaneLSPContext? {
        guard let worktreeId, let worktreePath, let appState else { return nil }
        let fileURL = worktreePath.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let language = appState.lsp.language(forFileExtension: (relativePath as NSString).pathExtension)
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
                    worktreeId: worktreeId,
                    worktreePath: worktreePath,
                    appState: appState,
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
        worktreeId: String,
        worktreePath: URL,
        appState: AppState,
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
}
