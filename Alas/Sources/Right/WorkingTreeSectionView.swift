import SwiftUI

struct WorkingTreeSectionView: View {
    let changes: [ChangedFile]
    @Binding var expanded: Bool
    let onSelect: (ChangedFile) -> Void
    var onToggleStage: ((ChangedFile) -> Void)? = nil
    var onStageAll: (([ChangedFile]) -> Void)? = nil
    var onUnstageAll: (([ChangedFile]) -> Void)? = nil
    var onIgnore: ((_ path: String, _ isDirectory: Bool, _ destination: IgnoreDestination) -> Void)? = nil

    @Environment(\.theme) private var theme

    @State private var stagedExpanded: Bool = true
    @State private var unstagedExpanded: Bool = true
    @State private var collapsedChangePaths: Set<String> = []

    private var staged:   [ChangedFile] { changes.filter { $0.stage == .staged   } }
    private var unstaged: [ChangedFile] { changes.filter { $0.stage == .unstaged } }
    private var totalAdd: Int { changes.reduce(0) { $0 + $1.add } }
    private var totalDel: Int { changes.reduce(0) { $0 + $1.del } }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(
                title: "Working tree",
                count: changes.count,
                expanded: expanded,
                onToggle: { expanded.toggle() }
            ) {
                HStack(spacing: 8) {
                    if shouldShowChangeSummary(additions: totalAdd, deletions: totalDel) {
                        HStack(spacing: 6) {
                            Text("+\(totalAdd)").foregroundColor(theme.color("add"))
                            Text("−\(totalDel)").foregroundColor(theme.color("del"))
                        }
                        .font(.system(size: 11, design: .monospaced))
                    }
                    if staged.isEmpty, !unstaged.isEmpty {
                        AlasButton(title: "Stage all", style: .subtle, action: { onStageAll?(unstaged) })
                    }
                }
            }

            if expanded {
                if changes.isEmpty {
                    Text("no changes")
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-faint"))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if staged.isEmpty {
                    flatFileTree(files: unstaged, collapseNamespace: "unstaged")
                } else {
                    subsection(
                        title: "Staged",
                        files: staged,
                        expanded: $stagedExpanded,
                        collapseNamespace: "staged",
                        actionLabel: "Unstage all",
                        onAction: { onUnstageAll?(staged) }
                    )
                    if !unstaged.isEmpty {
                        subsection(
                            title: "Changes",
                            files: unstaged,
                            expanded: $unstagedExpanded,
                            collapseNamespace: "unstaged",
                            actionLabel: "Stage all",
                            onAction: { onStageAll?(unstaged) }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func flatFileTree(files: [ChangedFile], collapseNamespace: String) -> some View {
        let filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        ForEach(ChangesTreeBuilder.build(files: files)) { node in
            renderNode(node, filesByPath: filesByPath, depth: 0, collapseNamespace: collapseNamespace)
        }
    }

    @ViewBuilder
    private func subsection(
        title: String,
        files: [ChangedFile],
        expanded: Binding<Bool>,
        collapseNamespace: String,
        actionLabel: String?,
        onAction: (() -> Void)?
    ) -> some View {
        SubHeader(
            title: title,
            count: files.count,
            expanded: expanded.wrappedValue,
            onToggle: { expanded.wrappedValue.toggle() },
            trailing: actionLabel.map { label in
                AnyView(
                    AlasButton(title: label, style: .subtle, action: { onAction?() })
                )
            }
        )
        if expanded.wrappedValue {
            let filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
            ForEach(ChangesTreeBuilder.build(files: files)) { node in
                renderNode(node, filesByPath: filesByPath, depth: 0, collapseNamespace: collapseNamespace)
            }
        }
    }

    /// A ChangedFile is "untracked" when status parser produced ("A",
    /// .unstaged). Staged adds parse to ("A", .staged) so the stage check
    /// is required.
    private func isUntracked(_ file: ChangedFile) -> Bool {
        file.status == "A" && file.stage == .unstaged
    }

    /// True when every ChangedFile reachable through `node` is untracked.
    /// Folders that contain any tracked entry get no Ignore menu.
    private func isUntrackedSubtree(
        _ node: FileTreeNode,
        filesByPath: [String: ChangedFile]
    ) -> Bool {
        if node.kind == .file {
            return filesByPath[node.path].map(isUntracked) ?? false
        }
        guard let kids = node.children, !kids.isEmpty else { return false }
        return kids.allSatisfy { isUntrackedSubtree($0, filesByPath: filesByPath) }
    }

    @ViewBuilder
    private func ignoreMenu(path: String, isDirectory: Bool) -> some View {
        Menu("Ignore") {
            Button("Add to .gitignore (repo root)") {
                onIgnore?(path, isDirectory, .repoRoot)
            }
            Button("Add to nearest .gitignore") {
                onIgnore?(path, isDirectory, .nearest)
            }
            Button("Add to .git/info/exclude") {
                onIgnore?(path, isDirectory, .infoExclude)
            }
        }
    }

    private func renderNode(
        _ node: FileTreeNode,
        filesByPath: [String: ChangedFile],
        depth: Int,
        collapseNamespace: String
    ) -> AnyView {
        if node.kind == .dir {
            let collapseKey = "\(collapseNamespace):\(node.path)"
            let open = !collapsedChangePaths.contains(collapseKey)
            let folderUntracked = isUntrackedSubtree(node, filesByPath: filesByPath)
            return AnyView(
                Group {
                    Button {
                        if open {
                            collapsedChangePaths.insert(collapseKey)
                        } else {
                            collapsedChangePaths.remove(collapseKey)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Icon(name: open ? "chev-down" : "chev-right", size: 10, color: theme.color("fg-faint"))
                            Icon(name: "folder", size: 11, color: open ? theme.color("accent") : theme.color("fg-dim"))
                            Text(node.name)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(theme.color("fg"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.leading, CGFloat(12 + depth * 14))
                        .padding(.trailing, 12)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if folderUntracked {
                            ignoreMenu(path: node.path, isDirectory: true)
                        }
                    }
                    if open, let kids = node.children {
                        ForEach(kids) {
                            renderNode(
                                $0,
                                filesByPath: filesByPath,
                                depth: depth + 1,
                                collapseNamespace: collapseNamespace
                            )
                        }
                    }
                }
            )
        } else if let file = filesByPath[node.path] {
            let fileUntracked = isUntracked(file)
            return AnyView(
                ChangedRow(
                    file: file,
                    depth: depth,
                    onSelect: { onSelect(file) },
                    onStage: onToggleStage.map { fn in { fn(file) } }
                )
                .contextMenu {
                    if fileUntracked {
                        ignoreMenu(path: file.path, isDirectory: false)
                    }
                }
            )
        } else {
            return AnyView(EmptyView())
        }
    }
}
