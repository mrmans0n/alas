import SwiftUI

struct ReviewChangesLoadToken: Equatable {
    let key: String
    let id: UUID

    static func next(key: String) -> ReviewChangesLoadToken {
        ReviewChangesLoadToken(key: key, id: UUID())
    }

    func isActive(activeKey: String?, activeID: UUID) -> Bool {
        activeKey == key && activeID == id
    }
}

struct ReviewChangesLoadKey {
    @MainActor
    static func build(tabID: TabID, worktreePath: URL, rightPaneState: RightPaneState?) -> String {
        [
            tabID,
            worktreePath.path,
            rightPaneState.map(fingerprint) ?? "no-right-pane-state",
        ].joined(separator: "\u{0}")
    }

    @MainActor
    static func fingerprint(rightPaneState: RightPaneState) -> String {
        fingerprint(
            changes: rightPaneState.changes,
            indexFingerprint: rightPaneState.indexFingerprint,
            changesGeneration: rightPaneState.changesGeneration
        )
    }

    static func fingerprint(
        changes: [ChangedFile],
        indexFingerprint: String,
        changesGeneration: Int = 0
    ) -> String {
        let changeTokens = changes
            .sorted { lhs, rhs in
                if lhs.stage != rhs.stage { return lhs.stage.rawValue < rhs.stage.rawValue }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            .map { change in
                [
                    change.stage.rawValue,
                    change.path,
                    change.status,
                    "\(change.add)",
                    "\(change.del)",
                    change.renameFrom ?? "",
                    change.conflict?.rawValue ?? "",
                ].joined(separator: "\u{1f}")
            }
            .joined(separator: "\u{1e}")
        return "\(changesGeneration)\u{0}\(indexFingerprint)\u{0}\(changes.count)\u{0}\(changeTokens)"
    }
}

enum ReviewChangesLoadingPresentation {
    static func showsBlockingLoader(isLoading: Bool, hasSession: Bool) -> Bool {
        isLoading && !hasSession
    }

    static func showsRefreshError(loadError: String?, hasSession: Bool) -> Bool {
        hasSession && loadError != nil
    }
}

struct ReviewChangesTabView: View {
    static let reviewSessionLauncherLabel = "Open review session"

    let worktree: Worktree
    let tabState: ReviewChangesTabState
    let appState: AppState
    var loader: ReviewChangesLoader = ReviewChangesLoader()

    @Environment(\.theme) private var theme
    @State private var session: ReviewChangesLoadedSession?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedFileID: ReviewChangesFileID?
    @State private var railCollapsed = false
    @State private var reviewSummaryCollapsed = false
    @State private var draftCommentController: ReviewDraftCommentController?
    @State private var loadedDraftSessionID: ReviewDraftSessionID?
    @State private var focusedDraftCommentID: String?
    @State private var draftCommentScrollCommand: DiffReviewDraftCommentScrollCommand?
    @State private var draftCommentScrollController = DiffReviewDraftCommentScrollController()
    @State private var activeLoadKey: String?
    @State private var activeLoadID = UUID()
    @State private var reviewSessionLaunchError: String?
    @State private var wrapLines = false
    @State private var showWhitespace = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(theme.color("line"))
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
        .task(id: loadKey) {
            await loadSession()
        }
        .task(id: reviewDraftSessionID.rawValue) {
            loadDraftCommentController()
        }
        .onReceive(NotificationCenter.default.publisher(for: .alasReviewDraftCommentsDidChangeExternally)) { _ in
            try? draftCommentController?.load()
        }
    }

    static func reviewDraftSessionID(worktree: Worktree) -> ReviewDraftSessionID {
        ReviewDraftSessionID.localChanges(
            worktreeID: worktree.id,
            worktreePath: worktree.path,
            scope: .all
        )
    }

    static func reviewSessionTarget(
        worktreeID: String,
        repositoryPath: URL,
        scope: ReviewDraftLocalChangesScope
    ) -> ReviewSessionTarget {
        ReviewSessionTarget.localChanges(
            worktreeID: worktreeID,
            repositoryPath: repositoryPath,
            scope: scope
        )
    }

    private var reviewDraftSessionID: ReviewDraftSessionID {
        Self.reviewDraftSessionID(worktree: worktree)
    }

    private var loadKey: String {
        ReviewChangesLoadKey.build(
            tabID: tabState.id,
            worktreePath: worktree.path,
            rightPaneState: appState.rightPaneStore.activeState(worktreeId: worktree.id)
        )
    }

    @ViewBuilder
    private var content: some View {
        if ReviewChangesLoadingPresentation.showsBlockingLoader(isLoading: isLoading, hasSession: session != nil) {
            stateView(title: "Loading changes...", detail: nil, color: theme.color("fg-dim"))
        } else if let session, session.files.isEmpty {
            loadedSessionContent {
                stateView(title: "No changes to review", detail: "This worktree has no staged or unstaged file diffs.", color: theme.color("fg-dim"))
            }
        } else if let session {
            loadedSessionContent {
                reviewSurface(session)
            }
        } else if let loadError {
            stateView(title: "Could not load review changes", detail: loadError, color: theme.color("del"))
        } else {
            stateView(title: "No changes loaded", detail: nil, color: theme.color("fg-dim"))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Review Changes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            if let summary = session?.summary, summary.fileCount > 0 {
                Text("\(summary.fileCount) files")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.color("fg-dim"))
                Text("+\(summary.totalAdditions)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.color("add"))
                Text("-\(summary.totalDeletions)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.color("del"))
            }
            Spacer()
            if let reviewSessionLaunchError {
                Text(reviewSessionLaunchError)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("del"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            toolbarButton(
                systemName: "scope",
                tooltip: "Choose review scope",
                isActive: appState.isReviewPaletteOpen
            ) {
                appState.openReviewPaletteOverlay(prefill: worktree)
            }
            toolbarButton(
                systemName: "doc.text.magnifyingglass",
                tooltip: Self.reviewSessionLauncherLabel,
                isActive: false
            ) {
                openReviewSession(
                    target: Self.reviewSessionTarget(
                        worktreeID: worktree.id,
                        repositoryPath: worktree.path,
                        scope: .all
                    )
                )
            }
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

    private func loadedSessionContent<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            if ReviewChangesLoadingPresentation.showsRefreshError(loadError: loadError, hasSession: true),
               let loadError
            {
                refreshErrorBanner(message: loadError)
            }
            content()
        }
    }

    private func refreshErrorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.color("del"))
            Text("Could not refresh changes")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(theme.color("del").opacity(0.12))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
        .accessibilityIdentifier("review-changes-refresh-error")
        .accessibilityLabel("Could not refresh changes. \(message)")
    }

    private func reviewSurface(_ session: ReviewChangesLoadedSession) -> some View {
        DiffReviewSurface(
            session: session,
            selectedFileID: $selectedFileID,
            railCollapsed: $railCollapsed,
            reviewSummaryCollapsed: $reviewSummaryCollapsed,
            layoutMode: diffPreferences.layoutMode,
            wrapLines: diffPreferences.wrapLines,
            showWhitespace: diffPreferences.showWhitespace,
            codeFontFamily: appState.config.code.fontFamily,
            codeFontSize: CGFloat(appState.config.code.fontSize),
            showsSourceBadges: true,
            showsDraftSummaryRail: true,
            lspContextForFile: { file in
                makeLSPContext(relativePath: file.summary.path)
            },
            reviewFeedbackTarget: reviewFeedbackTarget,
            draftCommentsByFileID: ReviewDraftCommentGrouping.commentsByFileID(draftCommentController?.comments ?? []),
            focusedDraftCommentID: focusedDraftCommentID,
            draftCommentScrollCommand: draftCommentScrollCommand,
            draftCommentActions: draftCommentActions(),
            onSelectDraftComment: selectDraftComment,
            onSaveDraftComment: saveDraftComment
        )
    }

    private var reviewFeedbackTarget: ReviewFeedbackTarget {
        ReviewFeedbackTarget(
            title: "Review Changes",
            repositoryPath: worktree.path.path,
            providerDescription: nil,
            sourceDescription: "Review Changes"
        )
    }

    private func makeLSPContext(relativePath: String) -> DiffPaneLSPContext? {
        let fileURL = worktree.path.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let language = appState.lsp.language(forPath: relativePath)
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

    @MainActor
    private func loadSession() async {
        let requestedLoadToken = ReviewChangesLoadToken.next(key: loadKey)
        activeLoadKey = requestedLoadToken.key
        activeLoadID = requestedLoadToken.id
        isLoading = true
        loadError = nil
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
            loadDraftCommentController()
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
        DiffPreferenceBindings(
            appState: appState,
            wrapLines: $wrapLines,
            showWhitespace: $showWhitespace
        )
    }

    private var reviewFeedbackAgentSender: ReviewFeedbackAgentSender {
        ReviewFeedbackAgentSender.production(appState: appState, worktreeID: worktree.id)
    }

    @MainActor
    private func openReviewSession(target: ReviewSessionTarget) {
        let store = ReviewSessionStore()
        ReviewSessionLauncher.openOrFocus(
            target: target,
            findActive: { try store.findActive(targetID: $0) },
            save: { try store.save($0) },
            open: {
                reviewSessionLaunchError = nil
                appState.tabs.openOrFocusReviewSession(worktreeId: worktree.id, record: $0)
            },
            onFailure: { reviewSessionLaunchError = $0.localizedDescription }
        )
    }

    private func loadDraftCommentController() {
        let sessionID = reviewDraftSessionID
        if loadedDraftSessionID != sessionID {
            draftCommentController = ReviewDraftCommentController(sessionID: sessionID)
            loadedDraftSessionID = sessionID
            focusedDraftCommentID = nil
            draftCommentScrollCommand = nil
        }
        do {
            try draftCommentController?.load()
        } catch {
            // The controller keeps the non-blocking error state for the review rail.
        }
    }

    private func draftCommentActions() -> ReviewDraftCommentActions {
        ReviewDraftWorkspaceActions.make(
            controller: draftCommentController,
            sender: reviewFeedbackAgentSender,
            worktreeID: worktree.id
        )
    }

    private func selectDraftComment(_ comment: ReviewDraftComment) {
        focusedDraftCommentID = comment.id
        selectedFileID = comment.fileID
        draftCommentScrollCommand = draftCommentScrollController.command(
            commentID: comment.id,
            fileID: comment.fileID
        )
    }

    private func saveDraftComment(
        fileID: DiffReviewFileID,
        originalPath: String?,
        anchor: DiffReviewLineAnchor,
        body: String
    ) {
        do {
            try draftCommentController?.add(anchor: anchor, fileID: fileID, originalPath: originalPath, bodyMarkdown: body)
        } catch {
            // The controller keeps the non-blocking error state for the review rail.
        }
    }
}
