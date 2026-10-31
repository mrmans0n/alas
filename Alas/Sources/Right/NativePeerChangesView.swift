import SwiftUI

/// Working-tree changes and expandable commits for a peer session, read-only
/// unless the host serves git actions. File rows open their working-tree or
/// commit diff in the center.
struct NativePeerChangesView: View {
    /// What the working tree's rows and header do on a host that serves git.
    struct Git {
        let onStage: ([ChangedFile]) -> Void
        let onUnstage: ([ChangedFile]) -> Void
        let onDiscard: (PendingDiscard) -> Void
        let onCommit: () -> Void
        /// Nil hides the Stashes section and "Stash Changes…".
        let stashes: [GitStash]?
        /// Each open stash's files, by ref.
        let stashFiles: [String: NativePeerWorkspace.Load<[GitStashFile]>]
        let onStashChanges: () -> Void
        let onToggleStash: (GitStash) -> Void
        let onApplyStash: (GitStash) -> Void
        let onPopStash: (GitStash) -> Void
        let onDropStash: (GitStash) -> Void
        /// False hides the operation card, the conflicts section and the commit actions.
        let servesOperations: Bool
        /// Whether a conflicted file opens for editing rather than as its diff.
        let editsFiles: Bool
        let onContinue: (MergeOperation) -> Void
        let onSkip: (MergeOperation) -> Void
        let onAbort: (MergeOperation) -> Void
        let onUseOurs: (ChangedFile) -> Void
        let onUseTheirs: (ChangedFile) -> Void
        let onKeepDeleted: (ChangedFile) -> Void
        let onMarkResolved: (ChangedFile) -> Void
        /// Each nil leaves its item out of a commit row's menu.
        let onCherryPick: ((RemoteCommit) -> Void)?
        let onRevert: ((RemoteCommit) -> Void)?
        let onEditCommit: ((RemoteCommit) -> Void)?
    }

    let changes: NativePeerWorkspace.Load<NativePeerWorkspace.Changes>
    /// The peer worktree's root, only used to build the "Copy Full Path" text.
    let worktreePath: URL
    let commitFiles: [String: NativePeerWorkspace.Load<NativePeerWorkspace.CommitFiles>]
    let onLoadCommitFiles: (String) -> Void
    let onOpen: (NativePeerWorkspace.Document) -> Void
    /// Nil leaves File History out of, or disabled in, a file row's menu.
    var onFileHistory: ((ChangedFile) -> Void)? = nil
    var git: Git? = nil

    @Environment(\.theme) private var theme
    /// Stashes starts collapsed, as `RightPaneState.stashesExpanded` does locally.
    @State private var collapsedSections: Set<String> = ["Stashes"]
    @State private var collapsedWorkingTreePaths: Set<String> = []
    @State private var expandedCommits: Set<String> = []
    @State private var collapsedCommitPaths: [String: Set<String>] = [:]

    var body: some View {
        switch changes {
        case .idle, .loading:
            RightPaneLoadingSkeletonView(activeTab: .changes)
        case .failed(let message):
            NativePeerRailMessage(text: message)
        case .loaded(let changes):
            let unchanged = changes.staged.isEmpty && changes.unstaged.isEmpty && changes.commits.isEmpty
            let servesOperations = git?.servesOperations == true
            let operation = servesOperations ? changes.operation : nil
            let conflicts = servesOperations ? Self.conflicts(in: changes) : []
            // Stashes still show, so changes stashed away can be popped back.
            if unchanged && (git?.stashes ?? []).isEmpty && operation == nil {
                NativePeerRailMessage(text: "No changes.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if unchanged {
                            NativePeerRailMessage(text: "No changes.")
                        }
                        if let git, let operation {
                            OperationCard(
                                operation: operation,
                                hasUnresolvedConflicts: !conflicts.isEmpty,
                                onContinue: { git.onContinue(operation) },
                                onSkip: { git.onSkip(operation) },
                                onAbort: { git.onAbort(operation) }
                            )
                        }
                        // A stash pop's conflicts come with no operation in progress.
                        if let git, !conflicts.isEmpty {
                            ConflictsSection(
                                conflicts: conflicts,
                                bulkInFlight: false,
                                hasAgent: false,
                                showsBulkResolve: false,
                                onSelect: { onOpen(git.editsFiles ? .file(path: $0.path) : .diff(path: $0.path, stage: .unstaged)) },
                                onUseOurs: git.onUseOurs,
                                onUseTheirs: git.onUseTheirs,
                                onKeepDeleted: git.onKeepDeleted,
                                onMarkResolved: git.onMarkResolved,
                                onResolveAllWithAgent: {},
                                onCancelBulkResolve: {}
                            )
                        }
                        treeSection(
                            "Working tree",
                            // As locally, conflicted files show in Conflicts only.
                            files: (changes.staged + changes.unstaged).filter { conflicts.isEmpty || $0.conflict == nil },
                            collapsedPaths: $collapsedWorkingTreePaths,
                            document: { .diff(path: $0.path, stage: $0.stage) },
                            onSelectStage: { file, stage in
                                onOpen(.diff(path: file.path, stage: stage))
                            },
                            git: git,
                            truncated: changes.truncated
                        )
                        commitSection(changes.commits, truncated: changes.commitsTruncated)
                        if let git {
                            stashSection(git)
                        }
                        if changes.truncated {
                            NativePeerRailMessage(text: "The peer shortened these lists.")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func treeSection(
        _ title: String,
        files: [ChangedFile],
        collapsedPaths: Binding<Set<String>>,
        document: @escaping (ChangedFile) -> NativePeerWorkspace.Document,
        onSelectStage: ((ChangedFile, ChangeStage) -> Void)? = nil,
        showsStageState: Bool = true,
        showsHeader: Bool = true,
        git: Git? = nil,
        truncated: Bool = false
    ) -> some View {
        if !files.isEmpty {
            let expanded = !collapsedSections.contains(title)
            let groups = WorkingTreeChangeGroup.group(files: files)
            let groupsByPath = Dictionary(uniqueKeysWithValues: groups.map { ($0.path, $0) })
            if showsHeader {
                let header = SectionHeader(
                    role: .workingTree,
                    title: title,
                    count: groups.count,
                    expanded: expanded,
                    onToggle: { toggle(title) },
                    stats: (
                        add: groups.reduce(0) { $0 + $1.add },
                        del: groups.reduce(0) { $0 + $1.del }
                    )
                ) {
                    if let git, files.contains(where: { $0.stage == .staged }) {
                        Button("Commit…", action: git.onCommit)
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.color("accent"))
                    }
                }
                if let git {
                    header.contextMenu {
                        let staged = files.filter { $0.stage == .staged }
                        let unstaged = files.filter { $0.stage == .unstaged }
                        // A shortened list would act on part of the changes only.
                        if truncated {
                            Button(
                                "The host lists only the first \(RemoteWorktreeFileAccess.maxChangedFiles) changes; "
                                    + "stage them individually or on the host."
                            ) {}
                            .disabled(true)
                            Divider()
                        }
                        if !unstaged.isEmpty {
                            Button("Stage All Changes") { git.onStage(unstaged) }.disabled(truncated)
                        }
                        if !staged.isEmpty {
                            Button("Unstage All Changes") { git.onUnstage(staged) }.disabled(truncated)
                        }
                        if git.stashes != nil {
                            Button("Stash Changes…", action: git.onStashChanges)
                        }
                        Divider()
                        Button("Discard all working tree changes…", role: .destructive) {
                            git.onDiscard(PendingDiscard(target: .all(fileCount: files.count), paths: files.map(\.path)))
                        }
                        .disabled(truncated)
                    }
                } else {
                    header
                }
            }
            if expanded || !showsHeader {
                ForEach(WorkingTreeFlatRow.make(
                    groups: groups,
                    collapsedPaths: collapsedPaths.wrappedValue
                )) { row in
                    WorkingTreeFlatRowView(
                        row: row,
                        groups: groups,
                        groupsByPath: groupsByPath,
                        collapsedPaths: collapsedPaths,
                        actions: WorkingTreeRowActions(
                            onSelect: { onOpen(document($0)) },
                            fileContextTarget: { _ in
                                FileContextMenuTarget(kind: .file, localURL: nil)
                            },
                            readOnly: git == nil,
                            showsStageState: showsStageState,
                            onStageAll: git?.onStage,
                            onUnstageAll: git?.onUnstage,
                            onDiscardFolder: git.map { git in { (folder: String) in
                                // As `RightPaneState.requestDiscardFolder`, unexpanded: the host expands renames.
                                let prefix = folder.hasSuffix("/") ? folder : folder + "/"
                                let under = files.filter { $0.path.hasPrefix(prefix) }
                                guard !under.isEmpty else { return }
                                git.onDiscard(PendingDiscard(
                                    target: .folder(path: folder, fileCount: under.count), paths: under.map(\.path)
                                ))
                            } },
                            onOpenFile: { onOpen(.file(path: $0.path)) },
                            onCopyRelative: { Clipboard.copy($0.path) },
                            onCopyFull: {
                                Clipboard.copyPath(worktreePath.appendingPathComponent($0.path).path)
                            },
                            onSelectStage: onSelectStage,
                            onFileHistory: onFileHistory,
                            onDiscardFile: git.map { git in { (file: ChangedFile) in
                                git.onDiscard(PendingDiscard(target: .file(path: file.path), paths: [file.path]))
                            } }
                        )
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func commitSection(_ commits: [RemoteCommit], truncated: Bool) -> some View {
        if !commits.isEmpty {
            let title = "Commits"
            let expanded = !collapsedSections.contains(title)
            SectionHeader(
                role: .commits,
                title: title,
                count: commits.count,
                expanded: expanded,
                onToggle: { toggle(title) }
            ) { EmptyView() }
            if expanded {
                ForEach(commits, id: \.revision) { commit in
                    let sha = commit.revision
                    let isExpanded = expandedCommits.contains(sha)
                    Button {
                        if expandedCommits.remove(sha) == nil {
                            expandedCommits.insert(sha)
                            onLoadCommitFiles(sha)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(theme.color("fg-faint"))
                                .frame(width: 8)
                            Text(commit.shortSha).foregroundColor(theme.color("fg-faint"))
                            Text(commit.subject)
                                .font(.system(size: 11.5))
                                .foregroundColor(theme.color("fg"))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            if commit.add > 0 { Text("+\(commit.add)").foregroundColor(theme.color("add")) }
                            if commit.del > 0 { Text("−\(commit.del)").foregroundColor(theme.color("del")) }
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(commit.subject)\n\(commit.author)")
                    .accessibilityLabel("\(commit.shortSha) \(commit.subject)")
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    .contextMenu { commitMenu(commit) }
                    if isExpanded {
                        commitFilesSection(sha: sha)
                    }
                }
                if truncated {
                    NativePeerRailMessage(text: "Showing the latest \(commits.count) commits.")
                }
            }
        }
    }

    /// As `CommitRow`'s menu; empty, so no menu shows, without a full SHA.
    @ViewBuilder
    private func commitMenu(_ commit: RemoteCommit) -> some View {
        if commit.sha != nil, let git {
            if let onEditCommit = git.onEditCommit {
                Button("Edit Commit…") { onEditCommit(commit) }
            }
            if let onCherryPick = git.onCherryPick {
                if git.onEditCommit != nil { Divider() }
                Button("Cherry-pick…") { onCherryPick(commit) }
            }
            if let onRevert = git.onRevert {
                Divider()
                Button("Revert Commit…", role: .destructive) { onRevert(commit) }
            }
        }
    }

    /// The conflicted files, staged or not, one per path.
    private static func conflicts(in changes: NativePeerWorkspace.Changes) -> [ChangedFile] {
        var seen = Set<String>()
        return (changes.staged + changes.unstaged).filter { $0.conflict != nil && seen.insert($0.path).inserted }
    }

    /// As the local Stashes section: an open stash lists its files, each opening its diff.
    @ViewBuilder
    private func stashSection(_ git: Git) -> some View {
        if let stashes = git.stashes, !stashes.isEmpty {
            let title = "Stashes"
            let expanded = !collapsedSections.contains(title)
            SectionHeader(
                role: .stashes,
                title: title,
                count: stashes.count,
                expanded: expanded,
                onToggle: { toggle(title) }
            ) { EmptyView() }
            if expanded {
                ForEach(stashes) { stash in
                    let files = git.stashFiles[stash.ref]
                    StashSummaryRow(
                        stash: stash,
                        open: files != nil,
                        loading: files == .some(.loading),
                        onToggle: { git.onToggleStash(stash) },
                        onApply: { git.onApplyStash(stash) },
                        onPop: { git.onPopStash(stash) },
                        onDrop: { git.onDropStash(stash) }
                    )
                    switch files {
                    case nil:
                        EmptyView()
                    case .idle?, .loading?:
                        StashEmptyRow(loading: true)
                    case .failed(let message)?:
                        NativePeerRailMessage(text: message)
                    case .loaded(let loaded)?:
                        if loaded.isEmpty {
                            StashEmptyRow(loading: false)
                        } else {
                            ForEach(loaded) { file in
                                StashFileRow(
                                    file: file,
                                    onSelect: { onOpen(.stashDiff(path: file.path, stash: HostStashRef(stash))) },
                                    dragPayload: { nil }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func commitFilesSection(sha: String) -> some View {
        switch commitFiles[sha] ?? .idle {
        case .idle:
            NativePeerRailMessage(text: "Loading commit files…")
                .onAppear { onLoadCommitFiles(sha) }
        case .loading:
            NativePeerRailMessage(text: "Loading commit files…")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 0) {
                NativePeerRailMessage(text: message)
                Button("Retry") { onLoadCommitFiles(sha) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("accent"))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        case .loaded(let result):
            if result.files.isEmpty {
                NativePeerRailMessage(text: "No files changed in this commit.")
            } else {
                treeSection(
                    sha,
                    files: result.files,
                    collapsedPaths: Binding(
                        get: { collapsedCommitPaths[sha] ?? [] },
                        set: { collapsedCommitPaths[sha] = $0 }
                    ),
                    document: { .commitDiff(path: $0.path, sha: sha) },
                    showsStageState: false,
                    showsHeader: false
                )
            }
            if result.truncated {
                NativePeerRailMessage(text: "The peer shortened this commit's file list.")
            }
        }
    }

    private func toggle(_ title: String) {
        if collapsedSections.remove(title) == nil { collapsedSections.insert(title) }
    }
}

/// A one-line status or failure note inside the peer rail.
struct NativePeerRailMessage: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-dim"))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Commits a host worktree's staged changes. A suggested message fills only
/// the fields still blank.
struct NativePeerCommitSheet: View {
    let subtitle: String
    /// Without staged changes only an amend, of the message alone, can run.
    let hasStaged: Bool
    /// Nil when this Mac cannot suggest a message.
    let suggest: (@MainActor () async -> CommitMessageSuggestion?)?
    /// The error message to show, nil once committed.
    let commit: @MainActor (_ subject: String, _ body: String, _ amend: Bool) async -> String?
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var amend = false
    @State private var isSuggesting = false
    @State private var isCommitting = false
    @State private var errorMessage: String?

    var body: some View {
        DialogContainer(
            title: "Commit",
            subtitle: subtitle,
            headerAccessory: { EmptyView() },
            content: {
                DialogField(label: "Subject") {
                    AlasField(text: $subject, focusOnAppear: true, onSubmit: commitChanges)
                        .aiBeam(isActive: isSuggesting)
                }
                DialogField(label: "Body") {
                    TextEditor(text: $messageBody)
                        .font(.system(size: 12))
                        .foregroundColor(theme.color("fg"))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 80, maxHeight: 160)
                        .padding(8)
                        .background(theme.color("bg-0"))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5))
                        .aiBeam(isActive: isSuggesting)
                }
                Toggle("Amend the last commit", isOn: $amend)
                    .font(.system(size: 12))
                    .toggleStyle(.checkbox)
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 11)).foregroundColor(.red)
                } else if !hasStaged && !amend {
                    Text("Stage changes before committing.").font(.system(size: 11)).foregroundColor(theme.color("fg-dim"))
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: amend ? "Amend" : "Commit",
            confirmStyle: .primary,
            onCancel: onDismiss,
            onConfirm: commitChanges,
            confirmEnabled: canCommit
        )
        .task {
            guard let suggest else { return }
            isSuggesting = true
            let suggestion = await suggest()
            isSuggesting = false
            guard let suggestion, !Task.isCancelled else { return }
            if subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { subject = suggestion.subject }
            if messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { messageBody = suggestion.body ?? "" }
        }
    }

    private var canCommit: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCommitting && (hasStaged || amend)
    }

    private func commitChanges() {
        guard canCommit else { return }
        isCommitting = true
        errorMessage = nil
        Task { @MainActor in
            errorMessage = await commit(subject, messageBody, amend)
            isCommitting = false
            if errorMessage == nil { onDismiss() }
        }
    }
}
