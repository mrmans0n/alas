import AppKit
import Foundation
import Observation
import os

extension RightPaneState {
    func invalidateFileTreeChildLoadsForRefresh() {
        fileTreeGeneration += 1
        loadedFileTreeChildPaths = [""]
        loadingFileTreeChildPaths = []
        fileTreeChildLoadTokens = [:]
        failedFileTreeChildPaths = []
        fileTree = Self.resetLoadingFileTreeChildren(in: fileTree)
    }

    func toggleStage(_ file: ChangedFile) {
        if file.stage == .staged {
            unstageAll([file])
        } else {
            stageAll([file])
        }
    }

    nonisolated static func mergingChildren(
        in nodes: [FileTreeNode],
        for path: String,
        with children: [FileTreeNode],
        state: DirectoryChildrenState
    ) -> (nodes: [FileTreeNode], didMerge: Bool) {
        var didMerge = false
        let updatedNodes = nodes.map { node in
            if node.path == path {
                didMerge = true
                var updated = node
                var merged: [String: FileTreeNode] = [:]
                for child in node.children ?? [] {
                    merged[child.id] = child
                }
                for child in children {
                    if let existing = merged[child.id] {
                        var refreshed = existing
                        refreshed.badge = child.badge ?? existing.badge
                        refreshed.visibility = mergedVisibility(existing: existing.visibility, incoming: child.visibility)
                        refreshed.isSubmodule = child.isSubmodule || existing.isSubmodule
                        refreshed.childrenState = mergedChildrenState(existing: existing.childrenState, incoming: child.childrenState)
                        if refreshed.children == nil {
                            refreshed.children = child.children
                        }
                        merged[child.id] = refreshed
                    } else {
                        merged[child.id] = child
                    }
                }
                updated.children = merged.values.sorted { lhs, rhs in
                    if lhs.kind != rhs.kind { return lhs.kind == .dir }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                updated.childrenState = state
                return updated
            }
            guard let existing = node.children else { return node }
            var updated = node
            let result = mergingChildren(in: existing, for: path, with: children, state: state)
            didMerge = didMerge || result.didMerge
            updated.children = result.nodes
            return updated
        }
        return (updatedNodes, didMerge)
    }

    nonisolated private static func mergedVisibility(
        existing: FileVisibility,
        incoming: FileVisibility
    ) -> FileVisibility {
        if incoming == .tracked, existing != .tracked {
            return existing
        }
        return incoming
    }

    nonisolated private static func mergedChildrenState(
        existing: DirectoryChildrenState,
        incoming: DirectoryChildrenState
    ) -> DirectoryChildrenState {
        if incoming == .notLoaded, existing != .notLoaded {
            return existing
        }
        return incoming
    }

    nonisolated static func resetLoadingFileTreeChildren(in nodes: [FileTreeNode]) -> [FileTreeNode] {
        nodes.map { node in
            var updated = node
            if let children = node.children {
                updated.children = resetLoadingFileTreeChildren(in: children)
            }
            if node.kind == .dir, node.childrenState == .loading {
                updated.children = nil
                updated.childrenState = .notLoaded
            }
            return updated
        }
    }

    /// Carries previously loaded lazy-directory subtrees from `previous` into a
    /// freshly rebuilt `fresh` tree.
    ///
    /// `GitService.fileTree` rebuilds lazily-loaded directories (ignored or
    /// excluded roots, and anything expanded on demand) as `.notLoaded` with no
    /// children. Assigning that tree verbatim on refresh collapses any directory
    /// the user had already expanded — it briefly renders the uncompacted tree,
    /// re-loads it level by level, and re-collapses (the "blink"). Grafting the
    /// prior subtree keeps the expanded, compacted state stable across refreshes;
    /// contents are still reconciled in the background by `loadFileTreeChildren`.
    nonisolated static func preservingLazyChildren(
        fresh: [FileTreeNode],
        previous: [FileTreeNode]
    ) -> [FileTreeNode] {
        var previousDirectoriesByPath: [String: FileTreeNode] = [:]
        for node in previous where node.kind == .dir {
            previousDirectoriesByPath[node.path] = node
        }
        return fresh.map { node in
            var updated = node
            let prior = previousDirectoriesByPath[node.path]
            if node.kind == .dir,
               node.childrenState == .notLoaded,
               node.children == nil,
               let prior,
               prior.kind == .dir,
               prior.childrenState == .loaded,
               let priorChildren = prior.children {
                updated.childrenState = .loaded
                updated.children = priorChildren
                return updated
            }
            if let children = node.children {
                updated.children = preservingLazyChildren(
                    fresh: children,
                    previous: prior?.children ?? []
                )
            }
            return updated
        }
    }

    /// Directories whose old children are retained because a refreshed tree
    /// leaves them lazy. Their retained descendants need one fresh listing.
    nonisolated static func preservedLazyChildPaths(
        fresh: [FileTreeNode],
        previous: [FileTreeNode]
    ) -> [String] {
        var previousDirectoriesByPath: [String: FileTreeNode] = [:]
        for node in previous where node.kind == .dir {
            previousDirectoriesByPath[node.path] = node
        }
        var paths: [String] = []
        for node in fresh where node.kind == .dir {
            let prior = previousDirectoriesByPath[node.path]
            if let prior,
               node.childrenState == .notLoaded,
               node.children == nil,
               prior.childrenState == .loaded,
               prior.children != nil {
                paths += loadedDirectoryPaths(in: prior)
                continue
            }
            paths += preservedLazyChildPaths(
                fresh: node.children ?? [],
                previous: prior?.children ?? []
            )
        }
        return paths
    }

    nonisolated private static func loadedDirectoryPaths(in node: FileTreeNode) -> [String] {
        guard node.kind == .dir,
              node.childrenState == .loaded,
              let children = node.children else {
            return []
        }
        return [node.path] + children.flatMap(loadedDirectoryPaths(in:))
    }

    /// Reconciles the child list of the directory at `path` against a fresh
    /// listing from `GitService.fileTreeChildren`. Used when re-loading an
    /// already-loaded directory on refresh.
    ///
    /// `mergingChildren` seeds from the existing children and only overlays
    /// incoming entries, so deletions/renames linger. This instead treats the
    /// listing as authoritative for which children still exist. Surviving
    /// entries keep their badge, visibility, submodule flag, and any
    /// already-loaded subtree, since the listing has `badges: [:]` and a
    /// `.tracked` default that would otherwise erase that metadata.
    nonisolated static func replacingChildren(
        in nodes: [FileTreeNode],
        for path: String,
        with children: [FileTreeNode],
        state: DirectoryChildrenState,
        currentDeletedPaths: Set<String> = []
    ) -> (nodes: [FileTreeNode], didMerge: Bool) {
        var didMerge = false
        let updatedNodes = nodes.map { node -> FileTreeNode in
            if node.path == path {
                didMerge = true
                var updated = node
                var existingByID: [String: FileTreeNode] = [:]
                for child in node.children ?? [] { existingByID[child.id] = child }
                let reconciled = children.map { incoming -> FileTreeNode in
                    guard let existing = existingByID[incoming.id] else { return incoming }
                    var refreshed = incoming
                    refreshed.badge = incoming.badge
                    refreshed.visibility = mergedVisibility(existing: existing.visibility, incoming: incoming.visibility)
                    refreshed.isSubmodule = incoming.isSubmodule || existing.isSubmodule
                    refreshed.childrenState = mergedChildrenState(existing: existing.childrenState, incoming: incoming.childrenState)
                    if refreshed.children == nil {
                        refreshed.children = existing.children
                    }
                    return refreshed
                }
                let incomingIDs = Set(children.map(\.id))
                let currentDeletions = (node.children ?? []).filter { existing in
                    !incomingIDs.contains(existing.id)
                        && existing.visibility == .tracked
                        && currentDeletedPaths.contains(existing.path)
                }
                let nextChildren = reconciled + currentDeletions
                updated.children = nextChildren.sorted { lhs, rhs in
                    if lhs.kind != rhs.kind { return lhs.kind == .dir }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                updated.childrenState = state
                return updated
            }
            guard let existing = node.children else { return node }
            var updated = node
            let result = replacingChildren(
                in: existing,
                for: path,
                with: children,
                state: state,
                currentDeletedPaths: currentDeletedPaths
            )
            didMerge = didMerge || result.didMerge
            updated.children = result.nodes
            return updated
        }
        return (updatedNodes, didMerge)
    }

    nonisolated static func fileTreeNode(at path: String, in nodes: [FileTreeNode]) -> FileTreeNode? {
        for node in nodes {
            if node.path == path { return node }
            if let children = node.children,
               let found = fileTreeNode(at: path, in: children) {
                return found
            }
        }
        return nil
    }

    nonisolated static func shouldAutoLoadFileTreeChildren(
        path: String,
        childrenState: DirectoryChildrenState,
        loadedPaths: Set<String>,
        loadingPaths: Set<String>,
        failedPaths: Set<String>
    ) -> Bool {
        guard !loadedPaths.contains(path),
              !loadingPaths.contains(path),
              !failedPaths.contains(path) else { return false }
        return childrenState == .notLoaded || childrenState == .loaded
    }

    func shouldAutoLoadFileTreeChildren(path: String, childrenState: DirectoryChildrenState) -> Bool {
        Self.shouldAutoLoadFileTreeChildren(
            path: path,
            childrenState: childrenState,
            loadedPaths: loadedFileTreeChildPaths,
            loadingPaths: loadingFileTreeChildPaths,
            failedPaths: failedFileTreeChildPaths
        )
    }

    func loadFileTreeChildren(path: String) {
        let reconcilesRetainedChildren = bookmarkReconciliationPaths.contains(path)
        guard (!loadedFileTreeChildPaths.contains(path) || reconcilesRetainedChildren),
              !loadingFileTreeChildPaths.contains(path) else { return }
        loadingFileTreeChildPaths.insert(path)
        nextFileTreeChildLoadToken &+= 1
        let loadToken = nextFileTreeChildLoadToken
        fileTreeChildLoadTokens[path] = loadToken
        // A directory whose children were carried over from a previous load
        // (e.g. across a refresh) is being reconciled, not loaded for the first
        // time. Flipping it to `.loading` would drop it out of a compacted chain
        // and make the row visibly collapse and re-expand, so keep it `.loaded`
        // and refresh its contents in the background instead.
        let alreadyLoaded = Self.fileTreeNode(at: path, in: fileTree)
            .map { $0.childrenState == .loaded && $0.children != nil } ?? false
        let replacesChildren = Self.shouldReplaceChildrenOnFileTreeLoad(
            path: path,
            in: fileTree,
            bookmarkReconciliationPaths: bookmarkReconciliationPaths
        )
        if !alreadyLoaded && !replacesChildren {
            let loadingMerge = Self.mergingChildren(in: fileTree, for: path, with: [], state: .loading)
            guard loadingMerge.didMerge else {
                loadingFileTreeChildPaths.remove(path)
                fileTreeChildLoadTokens[path] = nil
                return
            }
            fileTree = loadingMerge.nodes
        }
        let generation = fileTreeGeneration
        let refreshRevision = fileTreeRefreshRevision
        Task { @MainActor in
            defer {
                if self.fileTreeGeneration == generation,
                   self.fileTreeChildLoadTokens[path] == loadToken {
                    self.fileTreeChildLoadTokens[path] = nil
                    self.loadingFileTreeChildPaths.remove(path)
                }
            }
            do {
                let children = isFolder
                    ? try await git.plainDirectoryChildren(worktreePath: worktree.path, path: path)
                    : try await git.fileTreeChildren(
                        worktreePath: worktree.path,
                        path: path,
                        badges: Self.fileTreeBadges(from: self.changes)
                    )
                guard self.fileTreeGeneration == generation else { return }
                guard Self.shouldPublishFileTreeChildLoad(
                    startedAtRefreshRevision: refreshRevision,
                    currentRefreshRevision: self.fileTreeRefreshRevision
                ) else { return }
                // On the first load, merge so concurrent per-level loads (e.g. the
                // reveal flow expanding several ancestors at once) accumulate.
                // When reconciling an already-loaded directory, rebuild its child
                // list from the fresh filesystem listing so deleted/renamed
                // entries drop out — `mergingChildren` only overlays and would
                // leave stale children behind.
                let result = replacesChildren
                    ? Self.replacingChildren(
                        in: self.fileTree,
                        for: path,
                        with: children,
                        state: .loaded,
                        currentDeletedPaths: Self.fileTreeDeletedPaths(from: self.changes)
                    )
                    : Self.mergingChildren(in: self.fileTree, for: path, with: children, state: .loaded)
                guard result.didMerge else { return }
                self.loadedFileTreeChildPaths.insert(path)
                self.failedFileTreeChildPaths.remove(path)
                if replacesChildren {
                    self.bookmarkReconciliationPaths.remove(path)
                }
                self.fileTree = result.nodes
            } catch {
                guard self.fileTreeGeneration == generation else { return }
                guard Self.shouldPublishFileTreeChildLoad(
                    startedAtRefreshRevision: refreshRevision,
                    currentRefreshRevision: self.fileTreeRefreshRevision
                ) else { return }
                let result = Self.mergingChildren(in: self.fileTree, for: path, with: [], state: .failed)
                guard result.didMerge else { return }
                self.failedFileTreeChildPaths.insert(path)
                self.fileTree = result.nodes
                logger.error("file tree child load failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated static func shouldReplaceChildrenOnFileTreeLoad(
        path: String,
        in nodes: [FileTreeNode],
        bookmarkReconciliationPaths: Set<String>
    ) -> Bool {
        if bookmarkReconciliationPaths.contains(path) { return true }
        return fileTreeNode(at: path, in: nodes)
            .map { $0.childrenState == .loaded && $0.children != nil } ?? false
    }

    nonisolated static func fileTreeBadges(from changes: [ChangedFile]) -> [String: String] {
        var badges: [String: String] = [:]
        for change in changes {
            badges[change.path] = change.status
        }
        return badges
    }

    nonisolated static func fileTreeDeletedPaths(from changes: [ChangedFile]) -> Set<String> {
        Set(changes.filter { $0.status == "D" }.map(\.path))
    }

    nonisolated static func bookkeepingAfterPublishingRefreshedTree(
        loaded: Set<String>,
        loading _: Set<String>
    ) -> (loaded: Set<String>, loading: Set<String>) {
        (
            loaded.contains("") ? [""] : [],
            []
        )
    }

    nonisolated static func loadTokensAfterPublishingRefreshedTree(
        tokens: [String: Int],
        loading: Set<String>
    ) -> [String: Int] {
        tokens.filter { path, _ in loading.contains(path) }
    }

    nonisolated static func shouldPublishFileTreeChildLoad(
        startedAtRefreshRevision: Int,
        currentRefreshRevision: Int
    ) -> Bool {
        startedAtRefreshRevision == currentRefreshRevision
    }

    /// Bookmark roots start expanded. Seeding once (rather than on every
    /// render) keeps a collapsed root collapsed, and dropping removed
    /// bookmarks means re-adding one expands it again.
    func syncBookmarkRoots(_ bookmarks: [String]) {
        let paths = bookmarks.map(FileBookmarks.path(for:))
        for path in paths where !seededBookmarkRoots.contains(path) {
            seededBookmarkRoots.insert(path)
            bookmarkOpenPaths.insert(path)
        }
        seededBookmarkRoots.formIntersection(paths)
    }

    /// Walks each bookmark toward its node and starts the next directory load
    /// it needs. The file tree loads lazily and the drawer renders no ancestor
    /// rows of its own, so nothing else would pull those levels in. One level
    /// advances per call; callers re-invoke as the tree changes.
    func ensureBookmarkPathsLoaded(_ bookmarks: [String]) {
        for bookmark in bookmarks {
            if let pending = FileBookmarks.pendingLoadPath(forBookmark: bookmark, in: fileTree) {
                loadFileTreeChildren(path: pending)
            } else if let reconciliationPath = bookmarkReconciliationPath(for: FileBookmarks.path(for: bookmark)) {
                loadFileTreeChildren(path: reconciliationPath)
            }
        }
    }

    private func bookmarkReconciliationPath(for bookmarkPath: String) -> String? {
        bookmarkReconciliationPaths
            .filter { candidate in bookmarkPath == candidate || bookmarkPath.hasPrefix("\(candidate)/") }
            .min { $0.split(separator: "/").count < $1.split(separator: "/").count }
    }

    func reveal(path: String, opensPane: Bool = false) {
        activeTab = .files
        pendingRevealForPaneMount = pendingRevealForPaneMount || opensPane
        let pathComponents = path.split(separator: "/").map(String.init)
        for i in 0..<(pathComponents.count - 1) {
            let ancestor = pathComponents[0...i].joined(separator: "/")
            openPaths.insert(ancestor)
            if !loadedFileTreeChildPaths.contains(ancestor) {
                loadFileTreeChildren(path: ancestor)
            }
        }
        revealPath = path
        revealTick += 1
    }

    func consumePendingRevealForPaneMount() -> Bool {
        defer { pendingRevealForPaneMount = false }
        return pendingRevealForPaneMount
    }

    func completeInitialTabSelection() {
        didInitDefaultTab = true
    }

    func clearReveal() {
        revealPath = nil
    }

    func stageAll(_ files: [ChangedFile]) {
        enqueueStageMutation(files: files, target: .staged, gitPaths: files.map(\.path))
    }

    func unstageAll(_ files: [ChangedFile]) {
        enqueueStageMutation(
            files: files,
            target: .unstaged,
            gitPaths: files.flatMap(\.gitPaths)
        )
    }

    private func enqueueStageMutation(
        files: [ChangedFile],
        target: ChangeStage,
        gitPaths: [String]
    ) {
        guard !files.isEmpty, !checkpointMutationsDisabled else { return }
        sidebarError = nil
        pendingStageMutations.append(PendingStageMutation(
            paths: Set(files.map(\.path)),
            gitPaths: gitPaths,
            target: target
        ))
        guard stageMutationWorker == nil else { return }
        pendingStageMutationsSucceeded = true
        stageMutationWorker = Task { @MainActor [weak self] in
            await self?.runStageMutationQueue()
        }
    }

    private func runStageMutationQueue() async {
        while let mutation = pendingStageMutations.first(where: { !$0.hasAppliedGitMutation }) {
            do {
                guard await checkpointMutationAllowedAfterJournalRevalidation() else {
                    pendingStageMutationsSucceeded = false
                    pendingStageMutations.removeAll { $0.id == mutation.id }
                    continue
                }
                if mutation.target == .staged {
                    try await git.stageAll(worktreePath: worktree.path, files: mutation.gitPaths)
                } else {
                    try await git.unstageAll(worktreePath: worktree.path, files: mutation.gitPaths)
                }
                if let index = pendingStageMutations.firstIndex(where: { $0.id == mutation.id }) {
                    pendingStageMutations[index].hasAppliedGitMutation = true
                    pendingStageMutations[index].minimumRefreshGeneration = refreshGeneration + 1
                }
                await refresh()
            } catch {
                pendingStageMutationsSucceeded = false
                pendingStageMutations.removeAll { $0.id == mutation.id }
                sidebarError = (error as NSError).localizedDescription
                await refresh()
            }
        }
        stageMutationWorker = nil
    }

    func finishPendingStageMutations() async -> Bool {
        if let worker = stageMutationWorker {
            await worker.value
        }
        defer { pendingStageMutationsSucceeded = true }
        return pendingStageMutationsSucceeded
    }
}
