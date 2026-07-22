import SwiftUI

struct DiffLoadToken: Equatable {
    let key: String
    let id: UUID

    static func next(key: String) -> DiffLoadToken {
        DiffLoadToken(key: key, id: UUID())
    }

    func isActive(activeKey: String?, activeID: UUID) -> Bool {
        activeKey == key && activeID == id
    }
}

struct DiffTabView: View {
    let worktreePath: URL
    let relativePath: String
    let staged: Bool
    let originalPath: String?
    let compareWithHEAD: Bool
    let worktreeId: String
    let appState: AppState
    var codeFontFamily: String = ""
    var codeFontSize: CGFloat = 13
    let onOpenFile: (() -> Void)?
    let onRequestDiscardFile: (() -> Void)?
    @Environment(\.theme) var theme

    @State private var diff: ParsedDiff = ParsedDiff(hunks: [])
    @State private var displayModel: DiffDisplayModel?
    @State private var totalAdd = 0
    @State private var totalDel = 0
    @State private var loaded = false
    @State private var error: String?
    @State private var activeLoadKey: String?
    @State private var activeLoadID = UUID()
    @State private var confirmingDiscardHunk: ParsedDiff.Hunk? = nil
    @State private var isFileTracked: Bool = true
    @State private var isFileDeleted: Bool = false
    @State private var imagePair: ImageDiffPair?
    @State private var imagePairLoaded: Bool = false
    @State private var draftCommentController: ReviewDraftCommentController?
    @State private var loadedDraftSessionID: ReviewDraftSessionID?
    @State private var pendingDraftAnchor: DiffReviewLineAnchor?
    @State private var pendingDraftBody = ""
    @State private var draftComposerFocusRequestGeneration = 0
    @State private var reviewExpandedCollapsedRowIDs: Set<String> = []
    @State private var showWhitespace = false
    @StateObject private var renderContextCache = DiffTabRenderContextCache()
    @FocusState private var draftComposerFocused: Bool

    #if DEBUG
    var onRenderContextCacheMissForTesting: (() -> Void)? = nil
    #endif

    private let git = GitService()

    var body: some View {
        if ImageFileType.isSupported(relativePath: relativePath) {
            imageBody
        } else {
            textBody
        }
    }

    @ViewBuilder
    private var imageBody: some View {
        Group {
            if !imagePairLoaded {
                Spinner()
                    .frame(width: 20, height: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let pair = imagePair {
                ImageDiffView(
                    pair: pair,
                    relativePath: relativePath,
                    onOpenFile: onOpenFile
                )
            } else {
                Text("Could not load image diff for \(relativePath)")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("del"))
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.color("bg-1"))
        .task(id: imageLoadKey) { await loadImagePair() }
    }

    private var imageLoadKey: String {
        "img:\(worktreePath.path)\u{0}\(relativePath)\u{0}\(staged)\u{0}\(originalPath ?? "")\u{0}\(compareWithHEAD)"
    }

    private func loadImagePair() async {
        imagePairLoaded = false
        imagePair = nil
        do {
            let pair: ImageDiffPair
            if compareWithHEAD {
                pair = try await git.imageDiffPairAgainstHEAD(
                    worktreePath: worktreePath,
                    relativePath: relativePath,
                    originalPath: originalPath
                )
            } else {
                pair = try await git.imageDiffPair(
                    worktreePath: worktreePath,
                    relativePath: relativePath,
                    staged: staged
                )
            }
            guard !Task.isCancelled else { return }
            imagePair = pair
        } catch {
            // Leave imagePair nil to show the error placeholder.
        }
        imagePairLoaded = true
    }

    @ViewBuilder
    private var textBody: some View {
        VStack(spacing: 0) {
            header
            if let error {
                Text(error)
                    .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 2))
                    .foregroundColor(theme.color("del"))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.color("bg-2"))
            }
            if !loaded {
                Spinner()
                    .frame(width: 16, height: 16)
                    .padding()
            } else if diff.hunks.isEmpty {
                Text("No changes for \(relativePath)").foregroundColor(theme.color("fg-dim")).padding()
            } else if let displayModel {
                reviewDiffBody(model: displayModel)
            } else {
                Spinner()
                    .frame(width: 16, height: 16)
                    .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.color("bg-1"))
        .onChange(of: loadKey, initial: true) { _, _ in loadDraftCommentController() }
        .task(id: loadKey) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .alasReviewDraftCommentsDidChangeExternally)) { _ in
            try? draftCommentController?.load()
        }
        .alert(
            "Discard this hunk in \u{201C}\((relativePath as NSString).lastPathComponent)\u{201D}?",
            isPresented: Binding(
                get: { confirmingDiscardHunk != nil },
                set: { if !$0 { confirmingDiscardHunk = nil } }
            ),
            actions: {
                Button("Discard", role: .destructive) {
                    if let h = confirmingDiscardHunk {
                        confirmingDiscardHunk = nil
                        performDiscardHunk(h)
                    }
                }
                Button("Cancel", role: .cancel) { confirmingDiscardHunk = nil }
            },
            message: {
                Text("This permanently removes the selected hunk from your working copy. This cannot be undone.")
            }
        )
    }

    private var loadKey: String {
        "\(worktreePath.path)\u{0}\(relativePath)\u{0}\(staged)\u{0}\(originalPath ?? "")\u{0}\(compareWithHEAD)"
    }

    private var diffPreferences: DiffPreferenceBindings {
        DiffPreferenceBindings(appState: appState, showWhitespace: $showWhitespace)
    }

    private var lspContext: DiffPaneLSPContext? {
        let fileURL = worktreePath.appendingPathComponent(relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            return nil
        }
        guard let language = appState.lsp.language(forFileExtension: (relativePath as NSString).pathExtension) else {
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

    private var header: some View {
        HStack(spacing: 12) {
            Text((relativePath as NSString).lastPathComponent)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize))
                .foregroundColor(theme.color("fg"))
            if compareWithHEAD {
                Text("HEAD")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(theme.color("accent").opacity(0.16))
                    .foregroundColor(theme.color("accent"))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else if staged {
                Text("STAGED")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(theme.color("info").opacity(0.18))
                    .foregroundColor(theme.color("info"))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text("·").foregroundColor(theme.color("fg-faint"))
            Text((relativePath as NSString).deletingLastPathComponent)
                .font(.system(size: codeFontSize - 1.5))
                .foregroundColor(theme.color("fg-dim"))
            Spacer()
            if shouldShowChangeSummary(additions: totalAdd, deletions: totalDel) {
                HStack(spacing: 10) {
                    Text("+\(totalAdd)").foregroundColor(theme.color("add"))
                    Text("−\(totalDel)").foregroundColor(theme.color("del"))
                }
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 1.5))
            }
            HStack(spacing: 4) {
                if let onOpenFile {
                    AlasButton(title: "Open File", style: .subtle, action: onOpenFile)
                }
                if let onRequestDiscardFile, !compareWithHEAD {
                    AlasButton(title: "Discard Changes...", style: .subtle, action: onRequestDiscardFile)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private func load() async {
        let requestedLoadKey = loadKey
        let requestedLoadToken = DiffLoadToken.next(key: requestedLoadKey)
        activeLoadKey = requestedLoadToken.key
        activeLoadID = requestedLoadToken.id
        loaded = false
        diff = ParsedDiff(hunks: [])
        displayModel = nil
        totalAdd = 0
        totalDel = 0
        error = nil
        clearPendingDraft()

        do {
            let loadedDiff: ParsedDiff
            if compareWithHEAD {
                loadedDiff = try await git.diffAgainstHEAD(
                    worktreePath: worktreePath,
                    file: relativePath,
                    originalPath: originalPath
                )
            } else {
                loadedDiff = try await git.diff(
                    worktreePath: worktreePath,
                    file: relativePath,
                    staged: staged,
                    originalPath: originalPath
                )
            }
            guard isActiveLoad(requestedLoadToken) else { return }

            let loadedDisplayModel = await Task.detached(priority: .userInitiated) {
                DiffDisplayModelBuilder.build(diff: loadedDiff, filePath: relativePath)
            }.value
            guard isActiveLoad(requestedLoadToken) else { return }

            // Single off-main pass instead of two `.flatMap.filter.count`
            // allocations on MainActor — for big diffs each pass copies the
            // full line array, which would stall the UI right after parse.
            let (loadedTotalAdd, loadedTotalDel) = await Task.detached(priority: .userInitiated) {
                var add = 0
                var del = 0
                for hunk in loadedDiff.hunks {
                    for line in hunk.lines {
                        switch line.kind {
                        case .add: add += 1
                        case .delete: del += 1
                        case .context: break
                        }
                    }
                }
                return (add, del)
            }.value
            guard isActiveLoad(requestedLoadToken) else { return }

            let tracked = (try? await Process.git(
                ["ls-files", "--error-unmatch", "--", relativePath],
                cwd: worktreePath
            ))?.exitCode == 0
            guard isActiveLoad(requestedLoadToken) else { return }

            // A tracked file that's gone from disk is an unstaged deletion.
            // The diff for it has `+++ /dev/null`, so reverse-applying a
            // per-hunk patch (which uses `+++ b/<path>`) would fail — hide
            // Discard hunk in that case and rely on file-level Discard.
            let deleted = tracked && !FileManager.default.fileExists(
                atPath: worktreePath.appendingPathComponent(relativePath).path
            )

            guard isActiveLoad(requestedLoadToken) else { return }
            diff = loadedDiff
            displayModel = loadedDisplayModel
            totalAdd = loadedTotalAdd
            totalDel = loadedTotalDel
            isFileTracked = tracked
            isFileDeleted = deleted
            loaded = true
        } catch {
            guard isActiveLoad(requestedLoadToken) else { return }
            self.error = error.localizedDescription
            loaded = true
        }
    }

    private func isActiveLoad(_ token: DiffLoadToken) -> Bool {
        !Task.isCancelled && token.isActive(activeKey: activeLoadKey, activeID: activeLoadID)
    }

    private func stageHunk(_ hunk: ParsedDiff.Hunk) {
        Task {
            let tracked = isFileTracked
            // For untracked files we need the real file mode so `git apply
            // --cached` doesn't drop the +x bit or rewrite a symlink as a
            // regular file. Tracked patches ignore this argument.
            let untrackedMode = Self.fileMode(at: worktreePath.appendingPathComponent(relativePath))
            let patch = HunkPatchBuilder.patch(
                file: relativePath,
                hunk: hunk,
                tracked: tracked,
                untrackedMode: untrackedMode
            )
            var didFail = false
            do {
                let result = try await Process.git(["apply", "--cached", "-"], cwd: worktreePath, stdin: patch)
                if result.exitCode != 0 {
                    self.error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    didFail = true
                }
            } catch {
                self.error = (error as NSError).localizedDescription
                didFail = true
            }
            // Only reload on success — load() resets `error` at its start, so
            // calling it after a failure would erase the error we just set
            // and make the action look like a silent no-op.
            if !didFail { await load() }
        }
    }

    private func stagedHunkActions(hunk: ParsedDiff.Hunk) -> (stage: (() -> Void)?, discard: (() -> Void)?) {
        if compareWithHEAD { return (nil, nil) }
        // Staged view: no per-hunk actions for now (out of scope).
        if staged { return (nil, nil) }
        // Unstaged tracked, file exists: stage + discard.
        // Unstaged untracked: stage only (Discard hidden — whole file IS the hunk).
        // Unstaged tracked, file deleted: stage only (Discard hidden — the
        // generated patch would have `+++ b/<path>` but reverse-apply needs
        // /dev/null; file-level Discard restores the whole file).
        let stage: () -> Void = { stageHunk(hunk) }
        let discard: (() -> Void)? = (isFileTracked && !isFileDeleted)
            ? { confirmingDiscardHunk = hunk }
            : nil
        return (stage, discard)
    }

    private func performDiscardHunk(_ hunk: ParsedDiff.Hunk) {
        Task {
            let patch = HunkPatchBuilder.patch(file: relativePath, hunk: hunk, tracked: true)
            var didFail = false
            do {
                try await git.applyPatchReverse(worktreePath: worktreePath, patch: patch)
            } catch {
                self.error = (error as NSError).localizedDescription
                didFail = true
            }
            // See stageHunk: load() clears `error`, so only reload on success.
            if !didFail { await load() }
        }
    }

    /// Map a worktree file to the git mode string used in a `new file mode`
    /// patch header. Symlinks → "120000", executable regular files → "100755",
    /// everything else → "100644". Falls back to "100644" when the file isn't
    /// readable (caller probably already errored out elsewhere).
    static func fileMode(at url: URL) -> String {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let type = attrs[.type] as? FileAttributeType, type == .typeSymbolicLink {
                return "120000"
            }
            if let perms = attrs[.posixPermissions] as? NSNumber, perms.uintValue & 0o111 != 0 {
                return "100755"
            }
        } catch {
            // Fall through to default.
        }
        return HunkPatchBuilder.defaultUntrackedMode
    }

    // MARK: - Local review

    private var fileID: DiffReviewFileID {
        let namespace = compareWithHEAD ? "head" : (staged ? "staged" : "unstaged")
        return DiffReviewFileID(namespace: namespace, path: relativePath)
    }

    private var draftSessionID: ReviewDraftSessionID {
        ReviewDraftSessionID.localChanges(
            worktreeID: worktreeId,
            worktreePath: worktreePath,
            scope: .all
        )
    }

    private var reviewFeedbackTarget: ReviewFeedbackTarget {
        ReviewFeedbackTarget(
            title: (relativePath as NSString).lastPathComponent,
            repositoryPath: worktreePath.path,
            providerDescription: nil,
            sourceDescription: compareWithHEAD
                ? "Changes since HEAD"
                : staged ? "Staged changes" : "Unstaged changes"
        )
    }

    private var fileSummary: DiffReviewFileSummary {
        DiffReviewFileSummary(
            path: relativePath,
            namespace: compareWithHEAD ? "head" : (staged ? "staged" : "unstaged"),
            groupID: nil,
            groupTitle: nil,
            status: .modified,
            additions: totalAdd,
            deletions: totalDel,
            isRenderable: true
        )
    }

    private func makeDraftCommentActions() -> ReviewDraftCommentActions {
        ReviewDraftWorkspaceActions.make(
            controller: draftCommentController,
            sender: ReviewFeedbackAgentSender.production(appState: appState, worktreeID: worktreeId),
            worktreeID: worktreeId
        )
    }

    private func loadDraftCommentController() {
        let sessionID = draftSessionID
        if loadedDraftSessionID != sessionID {
            draftCommentController = ReviewDraftCommentController(sessionID: sessionID)
            loadedDraftSessionID = sessionID
        }
        try? draftCommentController?.load()
    }

    private func savePendingDraft() {
        guard let anchor = pendingDraftAnchor,
              let model = displayModel else { return }
        let canonicalAnchor = ReviewDraftCommentRowSegmentation.canonicalPendingAnchor(anchor, in: model.groups)
        let body = pendingDraftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let validKeys = Set(model.groups.flatMap(ReviewDraftCommentPlacement.allRowKeys))
        guard validKeys.contains(ReviewDraftCommentPlacement.RowKey(
            side: canonicalAnchor.side,
            line: canonicalAnchor.endLine ?? canonicalAnchor.line
        )) else {
            clearPendingDraft()
            return
        }
        try? draftCommentController?.add(anchor: canonicalAnchor, fileID: fileID, bodyMarkdown: body)
        clearPendingDraft()
    }

    private func clearPendingDraft() {
        pendingDraftAnchor = nil
        pendingDraftBody = ""
        draftComposerFocused = false
    }

    private func beginPendingDraft(at anchor: DiffReviewLineAnchor) {
        pendingDraftAnchor = anchor
        pendingDraftBody = ""
        draftComposerFocusRequestGeneration &+= 1
    }

    @ViewBuilder
    private func reviewDiffBody(model: DiffDisplayModel) -> some View {
        let currentFileID = fileID
        let comments = (draftCommentController?.comments ?? []).filter { $0.fileID == currentFileID }
        let key = DiffTabRenderContextKey(
            model: model,
            comments: comments,
            pendingDraftAnchor: pendingDraftAnchor
        )
        #if DEBUG
        let missCountBefore = renderContextCache.missCountForTests
        #endif
        let context = renderContextCache.context(key: key) {
            DiffTabRenderContextBuilder.build(
                key: key,
                model: model,
                comments: comments,
                pendingDraftAnchor: pendingDraftAnchor
            )
        }
        #if DEBUG
        let _ = {
            if renderContextCache.missCountForTests > missCountBefore {
                onRenderContextCacheMissForTesting?()
            }
        }()
        #endif
        VStack(spacing: 0) {
            reviewDiffToolbar
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let fileLevel = context.fileLevelDraftComments
                        if !fileLevel.isEmpty {
                            reviewDraftCommentStack(fileLevel)
                                .padding(.bottom, 10)
                        }
                        ForEach(context.groupData) { groupData in
                            reviewDiffGroup(groupData)
                        }
                    }
                    .padding(10)
                    .frame(minWidth: proxy.size.width, alignment: .topLeading)
                }
                .defaultScrollAnchor(.topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.color("bg-1"))
    }

    private var reviewDiffToolbar: some View {
        HStack(spacing: 8) {
            reviewLayoutSwitcher
            Spacer()
            reviewToolbarToggle(
                systemName: diffPreferences.wrapLines.wrappedValue ? "text.justify.left" : "text.alignleft",
                tooltip: "Wrap lines",
                isActive: diffPreferences.wrapLines.wrappedValue
            ) {
                diffPreferences.wrapLines.wrappedValue = !diffPreferences.wrapLines.wrappedValue
            }
            reviewToolbarToggle(
                systemName: "paragraphsign",
                tooltip: "Show whitespace",
                isActive: diffPreferences.showWhitespace.wrappedValue
            ) {
                diffPreferences.showWhitespace.wrappedValue = !diffPreferences.showWhitespace.wrappedValue
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(theme.color("bg-1"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }

    private var reviewLayoutSwitcher: some View {
        let currentMode = diffPreferences.layoutMode.wrappedValue
        return HStack(spacing: 0) {
            reviewLayoutModeButton(.split, systemName: "rectangle.split.2x1", currentMode: currentMode)
            reviewLayoutModeButton(.stacked, systemName: "rectangle.split.1x2", currentMode: currentMode)
        }
        .padding(3)
        .background(theme.color("bg-3"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.color("line"), lineWidth: 0.75))
    }

    private func reviewLayoutModeButton(
        _ mode: DiffLayoutMode,
        systemName: String,
        currentMode: DiffLayoutMode
    ) -> some View {
        let active = currentMode == mode
        return Button {
            diffPreferences.layoutMode.wrappedValue = mode
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemName).font(.system(size: 11, weight: .semibold))
                Text(mode.title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(active ? theme.color("fg") : theme.color("fg-muted"))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(active ? theme.color("bg-1") : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(mode.title)
    }

    private func reviewToolbarToggle(
        systemName: String,
        tooltip: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isActive ? theme.color("accent") : theme.color("fg-muted"))
                .frame(width: 24, height: 22)
                .background(isActive ? theme.color("accent-soft") : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    @ViewBuilder
    private func reviewDiffGroup(
        _ groupData: DiffTabRenderContext.Group
    ) -> some View {
        let group = groupData.group
        if groupData.containsLocalAccessories {
            VStack(alignment: .leading, spacing: 0) {
                reviewHunkHeader(group)
                ForEach(groupData.segments) { segment in
                    if !segment.rows.isEmpty {
                        DiffPaneTextDocumentView(
                            group: DiffDisplayGroup(
                                id: segment.id,
                                header: group.header,
                                sourceHunk: group.sourceHunk,
                                rows: segment.rows,
                                rowsSignature: segment.rowsSignature
                            ),
                            expandedCollapsedRowIDs: reviewExpandedCollapsedRowIDs,
                            layoutMode: diffPreferences.layoutMode.wrappedValue,
                            wrapLines: diffPreferences.wrapLines.wrappedValue,
                            showWhitespace: diffPreferences.showWhitespace.wrappedValue,
                            fileExtension: LanguageRegistry.highlighterExtension(forPath: relativePath),
                            codeFontFamily: codeFontFamily,
                            codeFontSize: codeFontSize,
                            theme: theme,
                            lspContext: lspContext,
                            onReviewLineSelected: beginPendingDraft
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if !segment.draftComments.isEmpty {
                        reviewDraftCommentStack(segment.draftComments, rows: segment.rows)
                    }
                    if segment.showsComposer, let pendingDraftAnchor {
                        reviewDraftComposer(anchor: pendingDraftAnchor, rows: segment.rows)
                    }
                }
            }
            .background(theme.color("bg-1"))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.color("line"), lineWidth: 0.75))
            .padding(.bottom, 10)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                reviewHunkHeader(group)
                DiffPaneTextDocumentView(
                    group: group,
                    expandedCollapsedRowIDs: reviewExpandedCollapsedRowIDs,
                    layoutMode: diffPreferences.layoutMode.wrappedValue,
                    wrapLines: diffPreferences.wrapLines.wrappedValue,
                    showWhitespace: diffPreferences.showWhitespace.wrappedValue,
                    fileExtension: LanguageRegistry.highlighterExtension(forPath: relativePath),
                    codeFontFamily: codeFontFamily,
                    codeFontSize: codeFontSize,
                    theme: theme,
                    lspContext: lspContext,
                    onReviewLineSelected: beginPendingDraft
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            .background(theme.color("bg-1"))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.color("line"), lineWidth: 0.75))
            .padding(.bottom, 10)
        }
    }

    private func reviewHunkHeader(_ group: DiffDisplayGroup) -> some View {
        let actions = stagedHunkActions(hunk: group.sourceHunk)
        return HStack(spacing: 8) {
            Text(group.header)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 1))
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
            Spacer(minLength: 12)
            if !DiffCollapsedContextController.collapsedRowIDs(in: group).isEmpty {
                let expanded = DiffCollapsedContextController.isExpanded(
                    group, expandedIDs: reviewExpandedCollapsedRowIDs
                )
                reviewHunkActionButton(
                    systemName: expanded ? "minus.square" : "plus.square",
                    tooltip: expanded ? "Collapse context" : "Expand context"
                ) {
                    reviewExpandedCollapsedRowIDs = DiffCollapsedContextController.toggled(
                        group, expandedIDs: reviewExpandedCollapsedRowIDs
                    )
                }
            }
            if let stage = actions.stage {
                reviewHunkActionButton(systemName: "plus.square", tooltip: "Stage hunk", action: stage)
            }
            if let discard = actions.discard {
                reviewHunkActionButton(systemName: "trash", tooltip: "Discard hunk", action: discard)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }

    private func reviewHunkActionButton(
        systemName: String,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    @ViewBuilder
    private func reviewDraftCommentStack(_ comments: [ReviewDraftComment]) -> some View {
        if !comments.isEmpty {
            let actions = makeDraftCommentActions()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(comments) { comment in
                    ReviewDraftCommentCard(
                        comment: comment,
                        file: fileSummary,
                        isFocused: false,
                        actions: actions,
                        reviewFeedbackTarget: reviewFeedbackTarget,
                        onSelect: { _ in }
                    )
                    .id(DiffReviewDraftCommentTargetID.targetID(commentID: comment.id, fileID: fileID))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(theme.color("bg-1"))
            .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
        }
    }

    @ViewBuilder
    private func reviewDraftCommentStack(_ comments: [ReviewDraftComment], rows: [DiffDisplayRow]) -> some View {
        if !comments.isEmpty {
            let actions = makeDraftCommentActions()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(comments) { comment in
                    DiffFeedbackLaneView(
                        lane: DiffFeedbackLaneResolver.lane(for: comment),
                        layoutMode: diffPreferences.layoutMode.wrappedValue,
                        rows: rows
                    ) {
                        ReviewDraftCommentCard(
                            comment: comment,
                            file: fileSummary,
                            isFocused: false,
                            actions: actions,
                            reviewFeedbackTarget: reviewFeedbackTarget,
                            onSelect: { _ in }
                        )
                        .id(DiffReviewDraftCommentTargetID.targetID(commentID: comment.id, fileID: fileID))
                        .padding(.horizontal, 14)
                    }
                }
            }
            .padding(.vertical, 10)
            .background(theme.color("bg-1"))
            .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
        }
    }

    private func reviewDraftComposer(anchor: DiffReviewLineAnchor, rows: [DiffDisplayRow]) -> some View {
        DiffFeedbackLaneView(
            lane: DiffFeedbackLaneResolver.lane(for: anchor),
            layoutMode: diffPreferences.layoutMode.wrappedValue,
            rows: rows
        ) {
            reviewDraftComposerContent
        }
    }

    private var reviewDraftComposerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ReviewDraftComposerTextEditor(
                text: $pendingDraftBody,
                theme: theme,
                isFocused: $draftComposerFocused,
                focusRequestGeneration: draftComposerFocusRequestGeneration,
                onSave: savePendingDraft,
                onCancel: clearPendingDraft
            )
            .frame(minHeight: 64, maxHeight: 90)
            .background(theme.color("bg-2"))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.color("line"), lineWidth: 0.5))
            .accessibilityIdentifier("diff-review-draft-composer")
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Cancel") { clearPendingDraft() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.color("fg-muted"))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(theme.color("bg-3"))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .accessibilityIdentifier("diff-review-draft-composer-cancel")
                Button("Save") { savePendingDraft() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.color("bg-1"))
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(theme.color("accent"))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .accessibilityIdentifier("diff-review-draft-composer-save")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(theme.color("bg-1"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }
}

struct HunkView: View {
    let hunk: ParsedDiff.Hunk
    let fileExtension: String
    var codeFontFamily: String = ""
    var codeFontSize: CGFloat = 13
    var onStage:   (() -> Void)? = nil
    var onDiscard: (() -> Void)? = nil
    var onDropFromCommit: (() -> Void)? = nil
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(hunk.header)
                    .font(CenterTypography.codeFont(family: codeFontFamily, size: headerFontSize))
                    .foregroundColor(theme.color("fg-dim"))
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if onStage != nil {
                    AlasButton(title: "Stage hunk", style: .subtle, action: { onStage?() })
                }
                if onDiscard != nil {
                    AlasButton(title: "Discard hunk...", style: .subtle, action: { onDiscard?() })
                }
                if onDropFromCommit != nil {
                    AlasButton(title: "Drop hunk...", style: .subtle, action: { onDropFromCommit?() })
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color("bg-2"))
            .overlay(Divider().opacity(0.5), alignment: .top)
            .overlay(Divider().opacity(0.5), alignment: .bottom)
            DiffSelectableTextView(
                hunk: hunk,
                fileExtension: fileExtension,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                theme: theme
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The hunk header (@@…@@) is rendered slightly smaller than diff content.
    private var headerFontSize: CGFloat { (codeFontSize * 0.85).rounded() }
}
