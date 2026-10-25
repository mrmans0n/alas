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
    }

    let changes: NativePeerWorkspace.Load<NativePeerWorkspace.Changes>
    /// The peer worktree's root, only used to build the "Copy Full Path" text.
    let worktreePath: URL
    let commitFiles: [String: NativePeerWorkspace.Load<NativePeerWorkspace.CommitFiles>]
    let onLoadCommitFiles: (String) -> Void
    let onOpen: (NativePeerWorkspace.Document) -> Void
    var git: Git? = nil

    @Environment(\.theme) private var theme
    @State private var collapsedSections: Set<String> = []
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
            if changes.staged.isEmpty && changes.unstaged.isEmpty && changes.commits.isEmpty {
                NativePeerRailMessage(text: "No changes.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        treeSection(
                            "Working tree",
                            files: changes.staged + changes.unstaged,
                            collapsedPaths: $collapsedWorkingTreePaths,
                            document: { .diff(path: $0.path, stage: $0.stage) },
                            onSelectStage: { file, stage in
                                onOpen(.diff(path: file.path, stage: stage))
                            },
                            git: git,
                            truncated: changes.truncated
                        )
                        commitSection(changes.commits, truncated: changes.commitsTruncated)
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
