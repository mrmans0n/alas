import SwiftUI

struct WorkingTreeFlatRow: Identifiable, Equatable {
    let node: FileTreeNode
    let depth: Int

    var id: String { node.id }

    static func make(
        groups: [WorkingTreeChangeGroup],
        collapsedPaths: Set<String>
    ) -> [WorkingTreeFlatRow] {
        let roots = ChangesTreeBuilder.build(files: groups.map(\.primaryEntry))
        return roots.flatMap { flatten($0, depth: 0, collapsedPaths: collapsedPaths) }
    }

    private static func flatten(
        _ node: FileTreeNode,
        depth: Int,
        collapsedPaths: Set<String>
    ) -> [WorkingTreeFlatRow] {
        let row = WorkingTreeFlatRow(node: node, depth: depth)
        guard node.kind == .dir,
              !collapsedPaths.contains("working-tree:\(node.path)")
        else { return [row] }
        return [row] + (node.children ?? []).flatMap {
            flatten($0, depth: depth + 1, collapsedPaths: collapsedPaths)
        }
    }
}

struct WorkingTreeSectionView: View {
    let changes: [ChangedFile]
    @Binding var expanded: Bool
    @Binding var collapsedChangePaths: Set<String>
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
            headerRow
        }
    }

    var headerRow: some View {
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

    @ViewBuilder
    private func flatFileTree(groups: [WorkingTreeChangeGroup]) -> some View {
        let groupsByPath = Dictionary(uniqueKeysWithValues: groups.map { ($0.path, $0) })
        ForEach(WorkingTreeFlatRow.make(groups: groups, collapsedPaths: collapsedChangePaths)) { row in
            WorkingTreeFlatRowView(
                row: row,
                groups: groups,
                groupsByPath: groupsByPath,
                collapsedPaths: $collapsedChangePaths,
                actions: rowActions
            )
        }
    }

    var rowActions: WorkingTreeRowActions {
        WorkingTreeRowActions(
            onSelect: onSelect,
            fileContextTarget: fileContextTarget,
            onStageAll: onStageAll,
            onUnstageAll: onUnstageAll,
            onIgnore: onIgnore,
            onDiscardFolder: onDiscardFolder,
            onOpenFile: onOpenFile,
            onCopyRelative: onCopyRelative,
            onCopyFull: onCopyFull,
            onCopyDiff: onCopyDiff,
            onViewAtHEAD: onViewAtHEAD,
            onCompareWithHEAD: onCompareWithHEAD,
            onFileHistory: onFileHistory,
            onDiscardFile: onDiscardFile,
            isOpenFileEnabled: isOpenFileEnabled,
            dragPayload: dragPayload
        )
    }
}

struct WorkingTreeRowActions {
    let onSelect: (ChangedFile) -> Void
    let fileContextTarget: (ChangedFile) -> FileContextMenuTarget
    let onStageAll: (([ChangedFile]) -> Void)?
    let onUnstageAll: (([ChangedFile]) -> Void)?
    let onIgnore: ((_ path: String, _ isDirectory: Bool, _ destination: IgnoreDestination) -> Void)?
    let onDiscardFolder: ((String) -> Void)?
    let onOpenFile: ((ChangedFile) -> Void)?
    let onCopyRelative: ((ChangedFile) -> Void)?
    let onCopyFull: ((ChangedFile) -> Void)?
    let onCopyDiff: ((ChangedFile) -> Void)?
    let onViewAtHEAD: ((ChangedFile) -> Void)?
    let onCompareWithHEAD: ((ChangedFile) -> Void)?
    let onFileHistory: ((ChangedFile) -> Void)?
    let onDiscardFile: ((ChangedFile) -> Void)?
    let isOpenFileEnabled: ((ChangedFile) -> Bool)?
    let dragPayload: ((ChangedFile) -> DragOutPayload?)?
}

struct WorkingTreeFlatRowView: View {
    let row: WorkingTreeFlatRow
    let groups: [WorkingTreeChangeGroup]
    let groupsByPath: [String: WorkingTreeChangeGroup]
    @Binding var collapsedPaths: Set<String>
    let actions: WorkingTreeRowActions

    @Environment(\.theme) private var theme

    @ViewBuilder
    var body: some View {
        if row.node.kind == .dir {
            folderRow
        } else if let group = groupsByPath[row.node.path] {
            fileRow(group)
        }
    }

    private var folderRow: some View {
        let node = row.node
        let collapseKey = "working-tree:\(node.path)"
        let open = !collapsedPaths.contains(collapseKey)
        let folderGroups = groups.groups(under: node.path)
        let stagedEntries = folderGroups.flatMap(\.stagedEntries)
        let unstagedEntries = folderGroups.flatMap(\.unstagedEntries)
        let folderState = Self.folderStageState(staged: stagedEntries, unstaged: unstagedEntries)
        let folderUntracked = isUntrackedSubtree(node)
        return Button {
            if open { collapsedPaths.insert(collapseKey) }
            else { collapsedPaths.remove(collapseKey) }
        } label: {
            HStack(spacing: 6) {
                StageChip(state: Self.stageChipState(for: folderState)) {
                    switch folderState {
                    case .staged: actions.onUnstageAll?(stagedEntries)
                    case .mixed, .unstaged: actions.onStageAll?(unstagedEntries)
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
            .padding(.leading, WorkingTreeSectionView.directoryRowLeadingPadding(depth: row.depth))
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !unstagedEntries.isEmpty {
                Button("Stage Changes") { actions.onStageAll?(unstagedEntries) }
            }
            if !stagedEntries.isEmpty {
                Button("Unstage Changes") { actions.onUnstageAll?(stagedEntries) }
            }
            if !stagedEntries.isEmpty || !unstagedEntries.isEmpty { Divider() }
            Button("Discard Changes…", role: .destructive) {
                actions.onDiscardFolder?(node.path)
            }
            if folderUntracked { ignoreMenu(path: node.path, isDirectory: true) }
        }
    }

    private func fileRow(_ group: WorkingTreeChangeGroup) -> some View {
        let file = group.primaryEntry
        let canStage = !group.unstagedEntries.isEmpty
        let canUnstage = !group.stagedEntries.isEmpty
        let headPathEntry = group.entries.first { $0.renameFrom != nil } ?? file
        let ignore = Self.isUntracked(file)
            ? AnyView(ignoreMenu(path: file.path, isDirectory: false))
            : nil
        return ChangedRow(
            file: file,
            fileContextTarget: actions.fileContextTarget(file),
            depth: row.depth,
            onSelect: { actions.onSelect(file) },
            onStage: primaryStageAction(for: group),
            stageState: Self.stageChipState(for: group.stageState),
            displayAdd: group.add,
            displayDel: group.del,
            onStageEntries: canStage ? { actions.onStageAll?(group.unstagedEntries) } : nil,
            onUnstageEntries: canUnstage ? { actions.onUnstageAll?(group.stagedEntries) } : nil,
            onOpenFile: actions.onOpenFile.map { fn in { fn(file) } },
            onCopyRelative: actions.onCopyRelative.map { fn in { fn(file) } },
            onCopyFull: actions.onCopyFull.map { fn in { fn(file) } },
            onCopyDiff: actions.onCopyDiff.map { fn in { fn(file) } },
            onViewAtHEAD: actions.onViewAtHEAD.map { fn in { fn(headPathEntry) } },
            onCompareWithHEAD: actions.onCompareWithHEAD.map { fn in { fn(headPathEntry) } },
            onFileHistory: actions.onFileHistory.map { fn in { fn(headPathEntry) } },
            onDiscard: actions.onDiscardFile.map { fn in { fn(file) } },
            openFileEnabled: actions.isOpenFileEnabled?(file) ?? true,
            viewAtHEADEnabled: Self.hasHeadVersion(group),
            ignoreMenu: ignore,
            dragPayload: actions.dragPayload.map { fn in { fn(file) } }
        )
    }

    private func primaryStageAction(for group: WorkingTreeChangeGroup) -> (() -> Void)? {
        switch group.stageState {
        case .staged:
            return group.stagedEntries.isEmpty ? nil : { actions.onUnstageAll?(group.stagedEntries) }
        case .mixed, .unstaged:
            return group.unstagedEntries.isEmpty ? nil : { actions.onStageAll?(group.unstagedEntries) }
        }
    }

    @ViewBuilder
    private func ignoreMenu(path: String, isDirectory: Bool) -> some View {
        Menu("Ignore") {
            Button("Add to .gitignore (repo root)") { actions.onIgnore?(path, isDirectory, .repoRoot) }
            Button("Add to nearest .gitignore") { actions.onIgnore?(path, isDirectory, .nearest) }
            Button("Add to .git/info/exclude") { actions.onIgnore?(path, isDirectory, .infoExclude) }
        }
    }

    private func isUntrackedSubtree(_ node: FileTreeNode) -> Bool {
        if node.kind == .file {
            return groupsByPath[node.path]?.entries.allSatisfy { Self.isUntracked($0) } ?? false
        }
        guard let children = node.children, !children.isEmpty else { return false }
        return children.allSatisfy { isUntrackedSubtree($0) }
    }

    private static func isUntracked(_ file: ChangedFile) -> Bool {
        file.status == "A" && file.stage == .unstaged
    }

    private static func hasHeadVersion(_ group: WorkingTreeChangeGroup) -> Bool {
        group.entries.contains(where: { $0.status == "D" || $0.status == "R" })
            || !group.entries.contains { $0.status == "A" }
    }

    private static func folderStageState(
        staged: [ChangedFile],
        unstaged: [ChangedFile]
    ) -> WorkingTreeStageState {
        switch (staged.isEmpty, unstaged.isEmpty) {
        case (false, false): return .mixed
        case (false, true): return .staged
        default: return .unstaged
        }
    }

    private static func stageChipState(for state: WorkingTreeStageState) -> StageChip.DisplayState {
        switch state {
        case .staged: return .staged
        case .mixed: return .mixed
        case .unstaged: return .unstaged
        }
    }
}
