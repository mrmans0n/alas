import AppKit
import SwiftUI

struct DraftReviewRequestTabView: View {
    let worktreePath: URL
    let worktreeId: String
    let tabState: DraftReviewRequestTabState
    @Bindable var appState: AppState

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var createAsDraft: Bool = false
    @State private var selectedPath: String?
    @State private var context: ReviewRequestDraftContext?
    @State private var busy = false
    @State private var error: String?
    @State private var warning: String?
    @State private var loadingContext = false
    @State private var loadedContextKey: String?
    @State private var selectedDisplayPreview: DraftReviewRequestDiffDisplayPreview?
    @State private var selectedDisplayPreviewLoadingKey: DraftReviewRequestDiffDisplayPreview.Key?
    @State private var selectedDisplayPreviewTask: Task<Void, Never>?
    @State private var generation: Task<Void, Never>? = nil

    @Environment(\.theme) private var theme
    @FocusState private var focused: Field?

    private let git = GitService()
    private static let minPaneWidth: CGFloat = 140

    private enum Field: Hashable { case title, body }

    private var snapshot: ReviewLoopSnapshot? {
        appState.rightPaneStore.activeState(worktreeId: worktreeId)?.reviewLoop.snapshot
    }

    private var matchingSnapshot: ReviewLoopSnapshot? {
        guard let snapshot, tabState.matchesTarget(snapshot) else { return nil }
        return snapshot
    }

    private var targetMismatchMessage: String? {
        guard let snapshot else { return nil }
        guard !tabState.matchesTarget(snapshot) else { return nil }
        return "This draft targets \(tabState.branchName) at \(tabState.headSHA.prefix(7)). Switch back to that branch state before creating it."
    }

    private var validationMessage: String? {
        if let targetMismatchMessage { return targetMismatchMessage }
        return ReviewRequestDraft.validationMessage(
            for: ReviewRequestDraft.ValidationInput(
                title: title,
                body: bodyText,
                snapshot: snapshot
            )
        )
    }

    private var canCreate: Bool {
        validationMessage == nil && !busy && tabState.createdURL == nil
    }

    private var contextKey: String {
        let head = matchingSnapshot?.local.headSHA ?? tabState.headSHA
        let base = matchingSnapshot?.local.baseBranch ?? tabState.baseBranch
        return "\(head):\(base)"
    }

    private var diffPreferences: DiffPreferenceBindings {
        DiffPreferenceBindings(appState: appState)
    }

    var body: some View {
        VStack(spacing: 0) {
            reviewRequestEditor
            contextBrowser
        }
        .onAppear { hydrateFromTabState() }
        .onChange(of: title) { _, new in persist(title: new) }
        .onChange(of: bodyText) { _, new in persist(body: new) }
        .onChange(of: createAsDraft) { _, new in persist(createAsDraft: new) }
        .onChange(of: selectedPath) { _, new in
            persist(selectedPath: new)
            refreshSelectedDisplayPreview()
        }
        .task(id: contextKey) { await loadContext() }
        .onDisappear {
            generation?.cancel()
            selectedDisplayPreviewTask?.cancel()
        }
    }

    private var reviewRequestEditor: some View {
        VStack(spacing: 0) {
            CommitMessageEditorView(
                subject: $title,
                bodyText: $bodyText,
                aiToolId: appState.bind(\.changes.aiToolId),
                title: editorTitle,
                busy: busy,
                error: error,
                availableAgents: appState.agentRegistry.enabled(),
                onGenerate: handleGenerate,
                primaryAction: CommitPrimaryAction(
                    label: "Create \(tabState.provider.reviewRequestLabel)",
                    isEnabled: canCreate,
                    showSavedState: false,
                    handler: createReviewRequest
                ),
                iconName: "branch",
                editorDisabled: tabState.createdURL != nil,
                onDismissError: { self.error = nil },
                accessory: AnyView(
                    Toggle(isOn: $createAsDraft) {
                        Text("Draft")
                            .font(.system(size: 11))
                            .foregroundColor(theme.color("fg-dim"))
                    }
                    .toggleStyle(.checkbox)
                    .disabled(busy || tabState.createdURL != nil)
                )
            )
            if hasEditorMessages {
                editorMessages
            }
        }
    }

    private var hasEditorMessages: Bool {
        warning != nil || (validationMessage != nil && tabState.createdURL == nil) || tabState.createdURL != nil
    }

    private var editorTitle: String {
        let repo = tabState.repositorySlug.isEmpty ? "Unknown repository" : tabState.repositorySlug
        return "\(tabState.provider.displayName) \(tabState.provider.reviewRequestLabel) · \(repo) · \(tabState.branchName) -> \(tabState.baseBranch)"
    }

    @ViewBuilder
    private var editorMessages: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let warning {
                Text(warning)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.color("warn"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let validationMessage, tabState.createdURL == nil {
                Text(validationMessage)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.color("fg-dim"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let createdURL = tabState.createdURL {
                HStack(spacing: 6) {
                    Icon(name: "link", size: 11, color: theme.color("accent"))
                    Text(createdURL.absoluteString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.color("fg-dim"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    AlasButton(title: "Open \(tabState.provider.reviewRequestLabel)", icon: "arrow.up.right.square") {
                        NSWorkspace.shared.open(createdURL)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [theme.color("composer-bg-top"), theme.color("composer-bg-bot")],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Icon(name: "branch", size: 12, color: theme.color("accent"))
            Text("\(tabState.provider.displayName) \(tabState.provider.reviewRequestLabel)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Text(tabState.repositorySlug.isEmpty ? "Unknown repository" : tabState.repositorySlug)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
            Text("\(tabState.branchName) -> \(tabState.baseBranch)")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-faint"))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Toggle(isOn: $createAsDraft) {
                Text("Draft")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
            }
            .toggleStyle(.checkbox)
            .disabled(busy || tabState.createdURL != nil)
            AiSplitButton(
                availableAgents: appState.agentRegistry.enabled(),
                selectedToolId: appState.bind(\.changes.aiToolId),
                busy: busy,
                onGenerate: handleGenerate
            )
            createButton
            if let createdURL = tabState.createdURL {
                AlasButton(title: "Open \(tabState.provider.reviewRequestLabel)", icon: "arrow.up.right.square") {
                    NSWorkspace.shared.open(createdURL)
                }
            }
        }
    }

    private var createButton: some View {
        Button(action: createReviewRequest) {
            HStack(spacing: 8) {
                if busy {
                    Spinner(lineWidth: 1.5, duration: 0.7)
                        .frame(width: 12, height: 12)
                }
                Text("Create \(tabState.provider.reviewRequestLabel)")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
            .foregroundColor(.white)
            .background(canCreate ? theme.color("accent") : theme.color("accent").opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!canCreate)
    }

    private var titleField: some View {
        TextField("Title", text: $title)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(theme.color("fg"))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(theme.color("field-bg"))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        focused == .title ? theme.color("accent") : theme.color("line"),
                        lineWidth: focused == .title ? 1 : 0.5
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        focused == .title ? theme.color("accent-glow-soft") : .clear,
                        lineWidth: 2
                    )
                    .padding(-2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .focused($focused, equals: .title)
            .disabled(busy || tabState.createdURL != nil)
    }

    private var bodyEditor: some View {
        TextEditor(text: $bodyText)
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: 90, maxHeight: 180)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(theme.color("field-bg"))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        focused == .body ? theme.color("accent") : theme.color("line"),
                        lineWidth: focused == .body ? 1 : 0.5
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        focused == .body ? theme.color("accent-glow-soft") : .clear,
                        lineWidth: 2
                    )
                    .padding(-2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .focused($focused, equals: .body)
            .disabled(busy || tabState.createdURL != nil)
    }

    private var contextBrowser: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let ratio = max(0.15, min(0.7, appState.config.commitDetailSplitRatio))
            let leftWidth = max(Self.minPaneWidth, total * ratio)
            HStack(spacing: 0) {
                leftContextPane
                    .frame(width: leftWidth)
                DragHandle(axis: .horizontal, onDrag: { delta in
                    guard total > 0 else { return }
                    let newWidth = max(Self.minPaneWidth, min(total - Self.minPaneWidth, leftWidth + delta))
                    appState.config.commitDetailSplitRatio = newWidth / total
                    appState.saveConfig()
                })
                rightContextPane
            }
        }
    }

    private var leftContextPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            contextSectionTitle("Commits")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array((context?.commits ?? []).enumerated()), id: \.element.id) { index, commit in
                        CommitRow(
                            commit: commit,
                            isLast: index == (context?.commits.count ?? 0) - 1,
                            onSelect: {},
                            onCopySHA: { Clipboard.copy(commit.sha) }
                        )
                    }
                }
            }
            .frame(minHeight: 74)
            Divider()
            contextSectionTitle("Files")
            fileList
        }
        .background(theme.color("bg-1"))
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(context?.changedFiles ?? []) { file in
                    Button {
                        selectedPath = file.path
                    } label: {
                        HStack(spacing: 8) {
                            Text(file.status)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(statusColor(file.status))
                                .frame(width: 18, alignment: .leading)
                            Text(file.path)
                                .font(.system(size: 11))
                                .foregroundColor(theme.color("fg"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("+\(file.add) -\(file.del)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(theme.color("fg-faint"))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(selectedPath == file.path ? theme.color("accent").opacity(0.2) : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var rightContextPane: some View {
        Group {
            if loadingContext {
                Spinner()
                    .frame(width: 20, height: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let context {
                VStack(alignment: .leading, spacing: 8) {
                    let preview = selectedDiffPreview(in: context)
                    if let selectedPath,
                       let file = context.changedFiles.first(where: { $0.path == selectedPath }),
                       let rawDiff = context.fileDiffsByPath[selectedPath] {
                        if let displayPreview = selectedDisplayPreview,
                           displayPreview.key == DraftReviewRequestDiffDisplayPreview.Key(
                               path: selectedPath,
                               file: file,
                               rawDiff: rawDiff
                           ) {
                            DraftReviewRequestDiffPreviewView(
                                preview: displayPreview,
                                codeFontFamily: appState.config.code.fontFamily,
                                codeFontSize: CGFloat(appState.config.code.fontSize),
                                layoutMode: diffPreferences.layoutMode,
                                wrapLines: diffPreferences.wrapLines,
                                showWhitespace: diffPreferences.showWhitespace
                            )
                        } else {
                            Spinner()
                                .frame(width: 16, height: 16)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        Text("Branch diff")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.color("fg"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                        ScrollView([.horizontal, .vertical]) {
                            Text(preview.diff.isEmpty ? "No committed diff." : preview.diff)
                                .font(CenterTypography.codeFont(
                                    family: appState.config.code.fontFamily,
                                    size: CGFloat(appState.config.code.fontSize)
                                ))
                                .foregroundColor(theme.color("fg"))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(12)
                        }
                        .background(theme.color("field-bg"))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(theme.color("line"), lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(12)
            } else {
                VStack(spacing: 8) {
                    Text("No committed branch context.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.color("fg-dim"))
                    AlasButton(title: "Reload", icon: "arrow.clockwise") {
                        Task { await loadContext() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.color("bg-0"))
    }

    private func contextSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(theme.color("fg-faint"))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color("bg-2"))
    }

    private func hydrateFromTabState() {
        title = tabState.title
        bodyText = tabState.body
        createAsDraft = tabState.createAsDraft
        selectedPath = tabState.selectedPath
    }

    private func persist(
        title: String? = nil,
        body: String? = nil,
        createAsDraft: Bool? = nil,
        selectedPath: String?? = nil,
        createdURL: URL?? = nil
    ) {
        appState.tabs.updateDraftReviewRequest(worktreeId: worktreeId, tabId: tabState.id) { state in
            if let title { state.title = title }
            if let body { state.body = body }
            if let createAsDraft { state.createAsDraft = createAsDraft }
            if let selectedPath { state.selectedPath = selectedPath }
            if let createdURL { state.createdURL = createdURL }
        }
    }

    private func loadContext() async {
        let key = contextKey
        loadingContext = true
        context = nil
        loadedContextKey = nil
        clearSelectedDisplayPreview()
        warning = nil
        error = nil
        defer {
            if key == contextKey {
                loadingContext = false
            }
        }
        guard matchingSnapshot != nil else {
            warning = targetMismatchMessage
            return
        }
        do {
            let loaded = try await git.reviewRequestDraftContext(
                worktreePath: worktreePath,
                baseRef: tabState.baseBranch
            )
            guard !Task.isCancelled, key == contextKey else { return }
            context = loaded
            loadedContextKey = key
            warning = loaded.hasUncommittedChanges
                ? "Uncommitted changes are present but excluded from this \(tabState.provider.reviewRequestLabel)."
                : nil
            if let selectedPath, loaded.changedFiles.contains(where: { $0.path == selectedPath }) {
                refreshSelectedDisplayPreview()
                return
            }
            selectedPath = loaded.changedFiles.first?.path
            refreshSelectedDisplayPreview()
        } catch {
            guard !Task.isCancelled, key == contextKey else { return }
            self.error = (error as NSError).localizedDescription
        }
    }

    private func handleGenerate() {
        if busy {
            generation?.cancel()
            return
        }
        guard let agent = appState.agent(id: appState.config.changes.aiToolId) else {
            error = "Select an AI tool to generate a \(tabState.provider.reviewRequestLabel) description."
            return
        }
        guard matchingSnapshot != nil else {
            error = targetMismatchMessage
            return
        }
        guard !loadingContext, loadedContextKey == contextKey, let context else {
            error = "Branch context is still loading."
            return
        }

        busy = true
        error = nil
        let provider = tabState.provider.displayName
        let repository = tabState.repositorySlug
        let prompt = appState.config.changes.reviewRequestPrompt
        let payload = ReviewRequestContextBuilder.build(
            provider: provider,
            repository: repository,
            branch: tabState.branchName,
            base: tabState.baseBranch,
            hasUncommittedChanges: context.hasUncommittedChanges,
            commitSubjects: context.commitSubjects,
            diff: context.diff
        )

        generation = Task { @MainActor in
            defer {
                busy = false
                generation = nil
            }
            do {
                let raw = try await AgentRunner.runPromptRaw(
                    agent: agent,
                    input: payload,
                    prompt: prompt,
                    workingDirectory: worktreePath.path
                )
                guard !Task.isCancelled else { return }
                let message = try ReviewRequestDraft.parseGeneratedMessage(raw)
                title = message.title
                bodyText = message.body
            } catch is CancellationError {
                // user-cancelled
            } catch {
                self.error = (error as NSError).localizedDescription
            }
        }
    }

    private func createReviewRequest() {
        guard !busy, let snapshot = matchingSnapshot, validationMessage == nil else { return }
        busy = true
        error = nil
        let titleSnapshot = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodySnapshot = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftSnapshot = createAsDraft
        Task { @MainActor in
            defer { busy = false }
            do {
                let url = try await appState.rightPaneStore
                    .activeState(worktreeId: worktreeId)?
                    .reviewLoop
                    .createReviewRequest(
                        snapshot: snapshot,
                        branch: tabState.branchName,
                        headOwner: tabState.headOwner,
                        baseBranch: tabState.baseBranch,
                        title: titleSnapshot,
                        body: bodySnapshot,
                        isDraft: draftSnapshot
                    )
                guard let url else {
                    error = "Review state is still loading."
                    return
                }
                persist(createdURL: url)
                await appState.rightPaneStore.refresh(worktreeId: worktreeId)
            } catch {
                self.error = (error as NSError).localizedDescription
            }
        }
    }

    private func selectedDiffPreview(in context: ReviewRequestDraftContext) -> (path: String?, diff: String) {
        guard let selectedPath,
              let diff = context.fileDiffsByPath[selectedPath]
        else {
            return (nil, context.diff)
        }
        return (selectedPath, diff)
    }

    private func refreshSelectedDisplayPreview() {
        guard let key = selectedDisplayPreviewKey() else {
            clearSelectedDisplayPreview()
            return
        }

        guard selectedDisplayPreview?.key != key else { return }
        guard selectedDisplayPreviewLoadingKey != key else { return }

        selectedDisplayPreviewTask?.cancel()
        selectedDisplayPreview = nil
        selectedDisplayPreviewLoadingKey = key
        selectedDisplayPreviewTask = Task { @MainActor in
            let prepared = await DraftReviewRequestDiffDisplayPreview.prepare(key: key)
            guard !Task.isCancelled else { return }
            guard selectedDisplayPreviewKey() == key else {
                if selectedDisplayPreviewLoadingKey == key {
                    selectedDisplayPreviewLoadingKey = nil
                    selectedDisplayPreviewTask = nil
                }
                return
            }

            selectedDisplayPreview = prepared
            selectedDisplayPreviewLoadingKey = nil
            selectedDisplayPreviewTask = nil
        }
    }

    private func selectedDisplayPreviewKey() -> DraftReviewRequestDiffDisplayPreview.Key? {
        guard let context,
              let selectedPath,
              let file = context.changedFiles.first(where: { $0.path == selectedPath }),
              let rawDiff = context.fileDiffsByPath[selectedPath]
        else {
            return nil
        }

        return DraftReviewRequestDiffDisplayPreview.Key(path: selectedPath, file: file, rawDiff: rawDiff)
    }

    private func clearSelectedDisplayPreview() {
        selectedDisplayPreviewTask?.cancel()
        selectedDisplayPreviewTask = nil
        selectedDisplayPreviewLoadingKey = nil
        selectedDisplayPreview = nil
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "A": return theme.color("add")
        case "D": return theme.color("del")
        case "R", "C": return theme.color("accent")
        default: return theme.color("fg-dim")
        }
    }
}

struct DraftReviewRequestDiffPreview {
    let path: String
    let file: CommitChangedFile
    let rawDiff: String

    var parsedDiff: ParsedDiff {
        DiffParser.parse(rawDiff)
    }

    var fileExtension: String {
        LanguageRegistry.highlighterExtension(forPath: path)
    }

    var title: String {
        (path as NSString).lastPathComponent
    }

    var directory: String {
        (path as NSString).deletingLastPathComponent
    }
}

struct DraftReviewRequestDiffDisplayPreview {
    struct Key: Equatable {
        let path: String
        let originalPath: String?
        let status: String
        let add: Int
        let del: Int
        let rawDiff: String

        init(path: String, file: CommitChangedFile, rawDiff: String) {
            self.path = path
            self.originalPath = file.originalPath
            self.status = file.status
            self.add = file.add
            self.del = file.del
            self.rawDiff = rawDiff
        }

        var file: CommitChangedFile {
            CommitChangedFile(
                path: path,
                originalPath: originalPath,
                status: status,
                add: add,
                del: del
            )
        }
    }

    let path: String
    let file: CommitChangedFile
    let rawDiff: String
    let parsedDiff: ParsedDiff
    let displayModel: DiffDisplayModel

    static func prepare(key: Key) async -> DraftReviewRequestDiffDisplayPreview {
        await Task.detached(priority: .userInitiated) {
            let parsed = DiffParser.parse(key.rawDiff)
            let model = DiffDisplayModelBuilder.build(diff: parsed, filePath: key.path)
            return DraftReviewRequestDiffDisplayPreview(key: key, parsedDiff: parsed, displayModel: model)
        }.value
    }

    var key: Key {
        Key(path: path, file: file, rawDiff: rawDiff)
    }

    private init(key: Key, parsedDiff: ParsedDiff, displayModel: DiffDisplayModel) {
        self.path = key.path
        self.file = key.file
        self.rawDiff = key.rawDiff
        self.parsedDiff = parsedDiff
        self.displayModel = displayModel
    }

    var fileExtension: String {
        LanguageRegistry.highlighterExtension(forPath: path)
    }

    var title: String {
        (path as NSString).lastPathComponent
    }

    var directory: String {
        (path as NSString).deletingLastPathComponent
    }
}

struct DraftReviewRequestDiffPreviewView: View {
    let preview: DraftReviewRequestDiffDisplayPreview
    let codeFontFamily: String
    let codeFontSize: CGFloat
    @Binding var layoutMode: DiffLayoutMode
    @Binding var wrapLines: Bool
    @Binding var showWhitespace: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.color("bg-1"))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(preview.title)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize))
                .foregroundColor(theme.color("fg"))
                .lineLimit(1)
            if !preview.directory.isEmpty {
                Text("·").foregroundColor(theme.color("fg-faint"))
                Text(preview.directory)
                    .font(.system(size: codeFontSize - 2))
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(preview.file.status)  +\(preview.file.add) -\(preview.file.del)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.color("fg-dim"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.4), alignment: .bottom)
    }

    @ViewBuilder
    private var content: some View {
        if preview.parsedDiff.hunks.isEmpty {
            Text("No changes for \(preview.path)")
                .foregroundColor(theme.color("fg-dim"))
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            DiffPaneView(
                model: preview.displayModel,
                fileExtension: preview.fileExtension,
                layoutMode: $layoutMode,
                wrapLines: $wrapLines,
                showWhitespace: $showWhitespace,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                showsToolbar: false,
                verticalScrollMode: .internalScroll,
                lspContext: nil,
                hunkActions: { _ in DiffPaneHunkActions() }
            )
        }
    }
}
