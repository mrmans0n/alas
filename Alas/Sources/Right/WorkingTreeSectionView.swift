import SwiftUI

struct WorkingTreeSectionView: View {
    let changes: [ChangedFile]
    @Binding var expanded: Bool
    let onSelect: (ChangedFile) -> Void
    let fileContextTarget: (ChangedFile) -> FileContextMenuTarget
    var onStageAll: (([ChangedFile]) -> Void)? = nil
    var onUnstageAll: (([ChangedFile]) -> Void)? = nil
    var onIgnore: ((_ path: String, _ isDirectory: Bool, _ destination: IgnoreDestination) -> Void)? = nil
    var onDiscardAll: (() -> Void)? = nil
    var onDiscardFolder: ((String) -> Void)? = nil
    var onOpenFile:        ((ChangedFile) -> Void)? = nil
    var onCopyRelative:    ((ChangedFile) -> Void)? = nil
    var onCopyFull:        ((ChangedFile) -> Void)? = nil
    var onCopyDiff:        ((ChangedFile) -> Void)? = nil
    var onViewAtHEAD:      ((ChangedFile) -> Void)? = nil
    var onCompareWithHEAD: ((ChangedFile) -> Void)? = nil
    var onFileHistory:     ((ChangedFile) -> Void)? = nil
    var onDiscardFile:     ((ChangedFile) -> Void)? = nil
    var onStashChanges:     (() -> Void)? = nil
    var stashChangesDisabled: Bool = false
    var isOpenFileEnabled: ((ChangedFile) -> Bool)? = nil
    var dragPayload: ((ChangedFile) -> DragOutPayload?)? = nil

    @Environment(\.theme) private var theme

    @State private var collapsedChangePaths: Set<String> = []

    private var staged:   [ChangedFile] { changes.filter { $0.stage == .staged   } }
    private var unstaged: [ChangedFile] { changes.filter { $0.stage == .unstaged } }
    private var changeGroups: [WorkingTreeChangeGroup] {
        WorkingTreeChangeGroup.group(files: changes)
    }

    nonisolated static func directoryRowLeadingPadding(depth: Int) -> CGFloat {
        12 + CGFloat(depth * 14)
    }

    private var totalAdd: Int { changeGroups.reduce(0) { $0 + $1.add } }
    private var totalDel: Int { changeGroups.reduce(0) { $0 + $1.del } }

    var body: some View {
        Section {
            if expanded {
                if changes.isEmpty {
                    Text("no changes")
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-faint"))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    flatFileTree(groups: changeGroups)
                }
            }
        } header: {
            SectionHeader(
                role: .workingTree,
                title: "Working tree",
                count: changeGroups.count,
                expanded: expanded,
                onToggle: { expanded.toggle() },
                stats: (add: totalAdd, del: totalDel)
            ) { }
            .contextMenu {
                if !unstaged.isEmpty {
                    Button("Stage All Changes") {
                        onStageAll?(unstaged)
                    }
                }
                if !staged.isEmpty {
                    Button("Unstage All Changes") {
                        onUnstageAll?(staged)
                    }
                }
                if !changes.isEmpty {
                    Button("Stash Changes…") {
                        onStashChanges?()
                    }
                    .disabled(stashChangesDisabled || changes.isEmpty || onStashChanges == nil)
                    Divider()
                }
                Button("Discard all working tree changes…", role: .destructive) {
                    onDiscardAll?()
                }
                .disabled(changes.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func flatFileTree(groups: [WorkingTreeChangeGroup]) -> some View {
        let groupsByPath = Dictionary(uniqueKeysWithValues: groups.map { ($0.path, $0) })
        let files = groups.map(\.primaryEntry)
        ForEach(ChangesTreeBuilder.build(files: files)) { node in
            renderNode(node, groups: groups, groupsByPath: groupsByPath, depth: 0)
        }
    }

    /// A ChangedFile is "untracked" when status parser produced ("A",
    /// .unstaged). Staged adds parse to ("A", .staged) so the stage check
    /// is required.
    private func isUntracked(_ file: ChangedFile) -> Bool {
        file.status == "A" && file.stage == .unstaged
    }

    private func hasHeadVersion(_ group: WorkingTreeChangeGroup) -> Bool {
        if group.entries.contains(where: { $0.status == "D" || $0.status == "R" }) {
            return true
        }
        return !group.entries.contains { $0.status == "A" }
    }

    /// True when every ChangedFile reachable through `node` is untracked.
    /// Folders that contain any tracked entry get no Ignore menu.
    private func isUntrackedSubtree(
        _ node: FileTreeNode,
        groupsByPath: [String: WorkingTreeChangeGroup]
    ) -> Bool {
        if node.kind == .file {
            return groupsByPath[node.path]?.entries.allSatisfy(isUntracked) ?? false
        }
        guard let kids = node.children, !kids.isEmpty else { return false }
        return kids.allSatisfy { isUntrackedSubtree($0, groupsByPath: groupsByPath) }
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
        groups: [WorkingTreeChangeGroup],
        groupsByPath: [String: WorkingTreeChangeGroup],
        depth: Int
    ) -> AnyView {
        if node.kind == .dir {
            let collapseKey = "working-tree:\(node.path)"
            let open = !collapsedChangePaths.contains(collapseKey)
            let folderGroups = groups.groups(under: node.path)
            let stagedEntries = folderGroups.flatMap(\.stagedEntries)
            let unstagedEntries = folderGroups.flatMap(\.unstagedEntries)
            let folderState = folderStageState(staged: stagedEntries, unstaged: unstagedEntries)
            let folderUntracked = isUntrackedSubtree(node, groupsByPath: groupsByPath)
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
                            StageChip(state: stageChipState(for: folderState)) {
                                switch folderState {
                                case .staged:           onUnstageAll?(stagedEntries)
                                case .mixed, .unstaged: onStageAll?(unstagedEntries)
                                }
                            }
                            FolderIconView(
                                name: node.name,
                                path: node.path,
                                open: open,
                                fallbackColor: open ? theme.color("accent") : theme.color("fg-dim")
                            )
                            Text(node.name)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(theme.color("fg"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.leading, Self.directoryRowLeadingPadding(depth: depth))
                        .padding(.trailing, 12)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !unstagedEntries.isEmpty {
                            Button("Stage Changes") {
                                onStageAll?(unstagedEntries)
                            }
                        }
                        if !stagedEntries.isEmpty {
                            Button("Unstage Changes") {
                                onUnstageAll?(stagedEntries)
                            }
                        }
                        if !stagedEntries.isEmpty || !unstagedEntries.isEmpty {
                            Divider()
                        }
                        Button("Discard Changes…", role: .destructive) {
                            onDiscardFolder?(node.path)
                        }
                        if folderUntracked {
                            ignoreMenu(path: node.path, isDirectory: true)
                        }
                    }
                    if open, let kids = node.children {
                        ForEach(kids) {
                            renderNode(
                                $0,
                                groups: groups,
                                groupsByPath: groupsByPath,
                                depth: depth + 1
                            )
                        }
                    }
                }
            )
        } else if let group = groupsByPath[node.path] {
            let file = group.primaryEntry
            let fileUntracked = isUntracked(file)
            let ignore: AnyView? = fileUntracked
                ? AnyView(ignoreMenu(path: file.path, isDirectory: false))
                : nil
            let canStage = !group.unstagedEntries.isEmpty
            let canUnstage = !group.stagedEntries.isEmpty
            let headPathEntry = group.entries.first { $0.renameFrom != nil } ?? file
            return AnyView(
                ChangedRow(
                    file: file,
                    fileContextTarget: fileContextTarget(file),
                    depth: depth,
                    onSelect: { onSelect(file) },
                    onStage: primaryStageAction(for: group),
                    stageState: stageChipState(for: group.stageState),
                    displayAdd: group.add,
                    displayDel: group.del,
                    onStageEntries: canStage ? { onStageAll?(group.unstagedEntries) } : nil,
                    onUnstageEntries: canUnstage ? { onUnstageAll?(group.stagedEntries) } : nil,
                    onOpenFile: onOpenFile.map { fn in { fn(file) } },
                    onCopyRelative: onCopyRelative.map { fn in { fn(file) } },
                    onCopyFull: onCopyFull.map { fn in { fn(file) } },
                    onCopyDiff: onCopyDiff.map { fn in { fn(file) } },
                    onViewAtHEAD: onViewAtHEAD.map { fn in { fn(headPathEntry) } },
                    onCompareWithHEAD: onCompareWithHEAD.map { fn in { fn(headPathEntry) } },
                    onFileHistory: onFileHistory.map { fn in { fn(headPathEntry) } },
                    onDiscard: onDiscardFile.map { fn in { fn(file) } },
                    openFileEnabled: isOpenFileEnabled?(file) ?? true,
                    viewAtHEADEnabled: hasHeadVersion(group),
                    ignoreMenu: ignore,
                    dragPayload: dragPayload.map { fn in { fn(file) } }
                )
            )
        } else {
            return AnyView(EmptyView())
        }
    }

    private func primaryStageAction(for group: WorkingTreeChangeGroup) -> (() -> Void)? {
        switch group.stageState {
        case .staged:
            guard !group.stagedEntries.isEmpty else { return nil }
            return { onUnstageAll?(group.stagedEntries) }
        case .mixed, .unstaged:
            guard !group.unstagedEntries.isEmpty else { return nil }
            return { onStageAll?(group.unstagedEntries) }
        }
    }

    private func folderStageState(
        staged: [ChangedFile],
        unstaged: [ChangedFile]
    ) -> WorkingTreeStageState {
        switch (staged.isEmpty, unstaged.isEmpty) {
        case (false, false): return .mixed
        case (false, true):  return .staged
        default:             return .unstaged
        }
    }

    private func stageChipState(for state: WorkingTreeStageState) -> StageChip.DisplayState {
        switch state {
        case .staged: return .staged
        case .mixed: return .mixed
        case .unstaged: return .unstaged
        }
    }
}
