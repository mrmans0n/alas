import SwiftUI

/// Read-only Changes tab for a peer worktree: its working tree, everything
/// that differs from the comparison ref, and its commits. Rows open a diff in
/// the center; nothing here writes to the peer.
struct NativePeerChangesView: View {
    let changes: NativePeerWorkspace.Load<NativePeerWorkspace.Changes>
    /// The peer worktree's root, only used to build the "Copy Full Path" text.
    let worktreePath: URL
    let onOpen: (NativePeerWorkspace.Document) -> Void

    @Environment(\.theme) private var theme
    @State private var collapsedSections: Set<String> = []

    var body: some View {
        switch changes {
        case .idle, .loading:
            RightPaneLoadingSkeletonView(activeTab: .changes)
        case .failed(let message):
            NativePeerRailMessage(text: message)
        case .loaded(let changes):
            if changes.branchFiles.isEmpty && changes.staged.isEmpty
                && changes.unstaged.isEmpty && changes.commits.isEmpty {
                NativePeerRailMessage(text: "No changes.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Two sections, not one merged list: a partially
                        // staged file appears in both `staged` and
                        // `unstaged`, and the read-only row has no stage
                        // chip to tell those two copies apart on sight.
                        fileSection("Staged", files: changes.staged) {
                            .diff(path: $0.path, stage: $0.stage)
                        }
                        fileSection("Unstaged", files: changes.unstaged) {
                            .diff(path: $0.path, stage: $0.stage)
                        }
                        fileSection(changes.comparisonRef.map { "Since \($0)" } ?? "Branch",
                                    files: changes.branchFiles) {
                            .diff(path: $0.path, stage: nil)
                        }
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
    private func fileSection(
        _ title: String,
        files: [ChangedFile],
        document: @escaping (ChangedFile) -> NativePeerWorkspace.Document
    ) -> some View {
        if !files.isEmpty {
            let expanded = !collapsedSections.contains(title)
            SectionHeader(
                role: .workingTree,
                title: title,
                count: files.count,
                expanded: expanded,
                onToggle: { toggle(title) },
                stats: (add: files.reduce(0) { $0 + $1.add }, del: files.reduce(0) { $0 + $1.del })
            ) { EmptyView() }
            if expanded {
                ForEach(files) { file in
                    ChangedRow(
                        file: file,
                        fileContextTarget: FileContextMenuTarget(kind: .file, localURL: nil),
                        onSelect: { onOpen(document(file)) },
                        onOpenFile: { onOpen(.file(path: file.path)) },
                        onCopyRelative: { Clipboard.copy(file.path) },
                        onCopyFull: { Clipboard.copy(worktreePath.appendingPathComponent(file.path).path) },
                        readOnly: true
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
                ForEach(commits, id: \.shortSha) { commit in
                    HStack(spacing: 6) {
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
                    .help("\(commit.subject)\n\(commit.author)")
                }
                if truncated {
                    NativePeerRailMessage(text: "Showing the latest \(commits.count) commits.")
                }
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
