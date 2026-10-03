import SwiftUI

/// Read-only working-tree changes and expandable commits for a peer session.
/// File rows open their working-tree or commit diff in the center.
struct NativePeerChangesView: View {
    let changes: NativePeerWorkspace.Load<NativePeerWorkspace.Changes>
    /// The peer worktree's root, only used to build the "Copy Full Path" text.
    let worktreePath: URL
    let commitFiles: [String: NativePeerWorkspace.Load<NativePeerWorkspace.CommitFiles>]
    let onLoadCommitFiles: (String) -> Void
    let onOpen: (NativePeerWorkspace.Document) -> Void

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
                            }
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
        showsHeader: Bool = true
    ) -> some View {
        if !files.isEmpty {
            let expanded = !collapsedSections.contains(title)
            let groups = WorkingTreeChangeGroup.group(files: files)
            let groupsByPath = Dictionary(uniqueKeysWithValues: groups.map { ($0.path, $0) })
            if showsHeader {
                SectionHeader(
                    role: .workingTree,
                    title: title,
                    count: groups.count,
                    expanded: expanded,
                    onToggle: { toggle(title) },
                    stats: (
                        add: groups.reduce(0) { $0 + $1.add },
                        del: groups.reduce(0) { $0 + $1.del }
                    )
                ) { EmptyView() }
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
                            readOnly: true,
                            showsStageState: showsStageState,
                            onOpenFile: { onOpen(.file(path: $0.path)) },
                            onCopyRelative: { Clipboard.copy($0.path) },
                            onCopyFull: {
                                Clipboard.copyPath(worktreePath.appendingPathComponent($0.path).path)
                            },
                            onSelectStage: onSelectStage
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
        case .idle, .loading:
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
