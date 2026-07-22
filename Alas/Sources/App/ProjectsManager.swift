import Foundation
import Observation

struct ProjectUpdate: Equatable {
    var name: String
    var icon: ProjectIcon
    var startupScripts: ProjectStartupScripts = .defaults
    /// `nil` means this update does not change the project's MCP configuration.
    var mcpServers: [ProjectMCPServer]?

    init(
        name: String,
        icon: ProjectIcon,
        startupScripts: ProjectStartupScripts = .defaults,
        mcpServers: [ProjectMCPServer]? = nil
    ) {
        self.name = name
        self.icon = icon
        self.startupScripts = startupScripts
        self.mcpServers = mcpServers
    }

    init(
        name: String,
        color: String,
        startupScripts: ProjectStartupScripts = .defaults,
        mcpServers: [ProjectMCPServer]? = nil
    ) {
        self.init(
            name: name,
            icon: ProjectIcon.default(color: color),
            startupScripts: startupScripts,
            mcpServers: mcpServers
        )
    }
}

enum WorktreeOperationState: Equatable {
    case creating
    case deleting
    case createFailed(message: String, base: String)
    case deleteFailed(message: String)
}

@Observable
@MainActor
final class ProjectsManager {
    private(set) var projects: [ProjectConfig]
    private(set) var worktreesByProject: [String: [Worktree]] = [:]
    private(set) var worktreeOperationStates: [String: WorktreeOperationState] = [:]

    private let git = GitService()
    private let worktreeSvc = WorktreeService()

    /// Source of the global default sort mode. `AppState` rebinds this after
    /// its stored properties are initialized so it can capture `self` weakly;
    /// tests inject a fixed value via the convenience `defaultOrdering:` init.
    private var defaultOrderingSource: () -> AppConfig.WorktreeSortMode = { .manual }

    init(
        persistedProjects: [ProjectConfig],
        defaultOrdering: @escaping () -> AppConfig.WorktreeSortMode = { .manual }
    ) {
        self.projects = persistedProjects
        self.defaultOrderingSource = defaultOrdering
        for project in persistedProjects {
            if let host = project.host {
                RemoteHostRegistry.shared.register(root: project.path, host: host)
            }
        }
    }

    /// Replace the live source of the global default sort mode. The closure is
    /// evaluated lazily on every sort, so a single wire-up at app launch suffices
    /// to keep ordering current as the user toggles the setting — but a *re-sort
    /// of already-sorted lists* is therefore not implicit. Callers must invoke
    /// `reapplyOrderingForAllProjects()` after a config change to propagate the
    /// new mode to lists that were already sorted.
    func setDefaultOrdering(_ source: @escaping () -> AppConfig.WorktreeSortMode) {
        self.defaultOrderingSource = source
    }

    func addProject(
        path: URL,
        displayName: String,
        icon: ProjectIcon,
        host: String? = nil,
        id: String = UUID().uuidString
    ) async throws -> ProjectConfig {
        let worktreeRootsByProject = worktreesByProject.mapValues { $0.map(\.path.path) }
        try Self.ensureNoPathCollision(
            newRoot: path.path,
            newHost: host,
            existing: projects,
            existingWorktreeRootsByProject: worktreeRootsByProject
        )
        if let host {
            try await RemoteRepoValidator.validate(host: host, path: path.path)
        } else {
            let isRepo = try await git.isGitRepository(path)
            guard isRepo else {
                throw NSError(domain: "ProjectsManager", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Not a git repository: \(path.path)"])
            }
        }
        let project = ProjectConfig(
            id: id,
            name: displayName,
            path: path.path,
            color: icon.color,
            addedAt: Date(),
            icon: icon,
            host: host
        )
        if let host {
            RemoteHostRegistry.shared.register(root: path.path, host: host)
        }
        projects.append(project)
        return project
    }

    func addProject(
        path: URL,
        displayName: String,
        color: String,
        id: String = UUID().uuidString
    ) async throws -> ProjectConfig {
        try await addProject(
            path: path,
            displayName: displayName,
            icon: ProjectIcon.default(color: color),
            id: id
        )
    }

    func removeProject(id: String, unregisterRemoteRoots: Bool = true) {
        if unregisterRemoteRoots,
           let project = projects.first(where: { $0.id == id }), project.host != nil {
            RemoteHostRegistry.shared.unregister(root: project.path)
            for worktree in worktreesByProject[id, default: []] {
                RemoteHostRegistry.shared.unregister(root: worktree.path.path)
            }
        }
        let ids = Set(worktreesByProject[id, default: []].map(\.id))
        projects.removeAll { $0.id == id }
        worktreesByProject.removeValue(forKey: id)
        worktreeOperationStates = worktreeOperationStates.filter { !ids.contains($0.key) }
    }

    func updateProject(id: String, update: ProjectUpdate) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].name = update.name
        projects[idx].icon = update.icon
        projects[idx].color = update.icon.color
        projects[idx].startupScripts = update.startupScripts
        if let mcpServers = update.mcpServers {
            projects[idx].mcpServers = mcpServers
        }
    }

    /// Sets the per-project stacked-diffs mode. Callers persist via
    /// `AppState.saveProjects()`.
    func setGGMode(projectId: String, mode: GGProjectMode) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].ggMode = mode
    }

    func ggWorktreeMode(projectId: String, worktreeId: String) -> GGWorktreeMode {
        projects.first(where: { $0.id == projectId })?.ggWorktreeModes[worktreeId] ?? .inherit
    }

    func setGGWorktreeMode(projectId: String, worktreeId: String, mode: GGWorktreeMode) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        if mode == .inherit {
            projects[idx].ggWorktreeModes.removeValue(forKey: worktreeId)
        } else {
            projects[idx].ggWorktreeModes[worktreeId] = mode
        }
    }

    func removeGGWorktreeMode(projectId: String, worktreeId: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].ggWorktreeModes.removeValue(forKey: worktreeId)
    }

    func reorderProject(fromIndex: Int, toIndex: Int) {
        guard projects.indices.contains(fromIndex),
              projects.indices.contains(toIndex),
              fromIndex != toIndex
        else { return }

        let moving = projects.remove(at: fromIndex)
        let clampedDestination = min(toIndex, projects.count)
        projects.insert(moving, at: clampedDestination)
    }

    func reorderProject(movingId: String, destinationId: String) {
        guard let fromIndex = projects.firstIndex(where: { $0.id == movingId }),
              let toIndex = projects.firstIndex(where: { $0.id == destinationId }),
              fromIndex != toIndex
        else { return }
        reorderProject(fromIndex: fromIndex, toIndex: toIndex)
    }

    func moveProjectToEnd(id: String) {
        guard let fromIndex = projects.firstIndex(where: { $0.id == id }),
              fromIndex != projects.count - 1
        else { return }
        let moving = projects.remove(at: fromIndex)
        projects.append(moving)
    }

    func worktrees(projectId: String) -> [Worktree] {
        worktreesByProject[projectId] ?? []
    }

    func operationState(for worktreeId: String) -> WorktreeOperationState? {
        worktreeOperationStates[worktreeId]
    }

    func setOperationState(id: String, state: WorktreeOperationState?) {
        if let state {
            worktreeOperationStates[id] = state
        } else {
            worktreeOperationStates.removeValue(forKey: id)
        }
    }

    func insertOptimisticWorktree(_ worktree: Worktree) {
        let projectId = worktree.projectId
        worktreesByProject[projectId, default: []].removeAll { $0.id == worktree.id }
        worktreesByProject[projectId, default: []].append(worktree)
        applyWorktreeOrdering(projectId: projectId)
    }

    func removeOptimisticWorktree(id: String, projectId: String) {
        worktreesByProject[projectId]?.removeAll { $0.id == id }
        worktreeOperationStates.removeValue(forKey: id)
        applyWorktreeOrdering(projectId: projectId)
    }

    func visibleWorktrees(projectId: String) -> [Worktree] {
        let hidden = hiddenSet(projectId: projectId)
        return worktrees(projectId: projectId).filter { !hidden.contains(canonical($0.path)) }
    }

    func archivedWorktrees(projectId: String) -> [Worktree] {
        let hidden = hiddenSet(projectId: projectId)
        return worktrees(projectId: projectId).filter { hidden.contains(canonical($0.path)) }
    }

    func visibleMainWorktree(projectId: String) -> Worktree? {
        guard let project = projects.first(where: { $0.id == projectId }) else { return nil }
        return visibleWorktrees(projectId: projectId).first { isMainWorktree($0, project: project) }
    }

    func resetWorktreeOrder(projectId: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let wasManual = projects[idx].worktreeOrderIsManual || !projects[idx].worktreeOrder.isEmpty
        guard wasManual else { return }
        projects[idx].worktreeOrder = []
        projects[idx].worktreeOrderIsManual = false
        applyWorktreeOrdering(projectId: projectId)
    }

    /// Re-sort every project's worktree list using the current effective sort
    /// mode. Invoke after mutating `config.worktrees.defaultOrdering` (or
    /// `setDefaultOrdering`) — otherwise the change only affects subsequent
    /// sort triggers (worktree add/remove, refresh), not the lists already
    /// rendered. Returns `true` if any project's persisted `worktreeOrder`
    /// actually changed (e.g. orphan ids dropped during normalization), so
    /// callers can decide whether to persist.
    @discardableResult
    func reapplyOrderingForAllProjects() -> Bool {
        var changed = false
        for project in projects {
            if applyWorktreeOrdering(projectId: project.id) {
                changed = true
            }
        }
        return changed
    }

    func reorderWorktree(projectId: String, fromIndex: Int, toIndex: Int) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectId }),
              var rows = worktreesByProject[projectId],
              rows.indices.contains(fromIndex)
        else { return }

        applyWorktreeOrdering(projectId: projectId)
        rows = worktreesByProject[projectId, default: []]
        guard rows.indices.contains(fromIndex),
              !isMainWorktree(rows[fromIndex], project: projects[projectIndex])
        else { return }

        let moving = rows.remove(at: fromIndex)
        let clampedDestination = min(max(toIndex, 1), rows.count)
        rows.insert(moving, at: clampedDestination)

        worktreesByProject[projectId] = rows
        projects[projectIndex].worktreeOrderIsManual = true
        projects[projectIndex].worktreeOrder = normalizedWorktreeOrder(
            rows.map(\.id),
            rows: rows,
            project: projects[projectIndex]
        )
        applyWorktreeOrdering(projectId: projectId)
    }

    func reorderWorktree(projectId: String, movingId: String, destinationId: String) {
        applyWorktreeOrdering(projectId: projectId)
        let rows = worktreesByProject[projectId, default: []]
        guard let fromIndex = rows.firstIndex(where: { $0.id == movingId }),
              let toIndex = rows.firstIndex(where: { $0.id == destinationId })
        else { return }

        reorderWorktree(projectId: projectId, fromIndex: fromIndex, toIndex: toIndex)
    }

    func isWorktreeHidden(projectId: String, path: URL) -> Bool {
        hiddenSet(projectId: projectId).contains(canonical(path))
    }

    func setWorktreeLaunchDefaults(projectId: String, openAfterCreate: Bool, launcherMode: AppConfig.LauncherMode) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].worktreeOpenAfterCreate = openAfterCreate
        projects[idx].worktreeDefaultLauncherMode = launcherMode
    }

    func setWorktreeHidden(projectId: String, path: URL, hidden: Bool) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let key = canonical(path)
        var paths = projects[idx].hiddenWorktreePaths
        if hidden {
            if !paths.contains(key) { paths.append(key) }
        } else {
            paths.removeAll { $0 == key }
        }
        projects[idx].hiddenWorktreePaths = paths
    }

    /// Refresh the live worktree list and reconcile per-worktree persisted
    /// configuration. Returns `true` when the caller should persist changes.
    @discardableResult
    func refreshWorktrees(projectId: String) async throws -> Bool {
        guard let project = projects.first(where: { $0.id == projectId }) else { return false }
        let configuredURL = URL(fileURLWithPath: project.path)
        let url: URL
        // gg clean can remove the linked worktree stored as the project path.
        // Query from another cached checkout so the deleted row can be reconciled.
        if project.host == nil,
           !FileManager.default.fileExists(atPath: configuredURL.path),
           let survivingWorktree = worktreesByProject[projectId, default: []].first(where: {
               FileManager.default.fileExists(atPath: $0.path.path)
           }) {
            url = survivingWorktree.path
        } else {
            url = configuredURL
        }
        let trees = try await worktreeSvc.list(repoPath: url, projectId: projectId)
        let anchorChanged = url.standardizedFileURL != configuredURL.standardizedFileURL

        // Reconcile optimistic rows: preserve creating rows until the owner
        // task completes, while still replacing them with real rows when
        // they appear in git.
        let previous = worktreesByProject[projectId, default: []]
        let previousById = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let liveIds = Set(trees.map(\.id))
        var reconciled = trees
        var clearOperationIds: [String] = []
        for (id, opState) in Array(worktreeOperationStates) {
            guard previousById[id] != nil || liveIds.contains(id) else { continue }
            switch opState {
            case .creating:
                if !liveIds.contains(id) {
                    // Still pending; keep the optimistic row visible.
                    if let optimistic = previousById[id] {
                        reconciled.append(optimistic)
                    }
                }
            case .deleting:
                // If the row is gone from git, the deletion succeeded.
                if !liveIds.contains(id) {
                    clearOperationIds.append(id)
                }
            case .createFailed:
                if liveIds.contains(id) {
                    // Worktree exists in git — transient failure is resolved; clear state.
                    clearOperationIds.append(id)
                } else if let existing = previousById[id] {
                    // Preserve failed rows so they remain visible for retry/removal.
                    reconciled.append(existing)
                }
            case .deleteFailed:
                // If git still sees the worktree, keep it visible with the failed
                // state so the user can retry or remove. If the worktree is gone
                // (user fixed it externally), clear the ghost state.
                if !liveIds.contains(id) {
                    clearOperationIds.append(id)
                }
            }
        }
        for id in clearOperationIds {
            worktreeOperationStates.removeValue(forKey: id)
        }
        reconcileRemoteHostRegistrations(project: project, previous: previous, reconciled: reconciled)
        worktreesByProject[projectId] = reconciled
        let orderChanged = applyWorktreeOrdering(projectId: projectId)

        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return false }
        if anchorChanged {
            projects[idx].path = url.path
        }
        let live = Set(trees.map { canonical($0.path) })
        let before = projects[idx].hiddenWorktreePaths.count
        projects[idx].hiddenWorktreePaths.removeAll { !live.contains($0) }
        let reconciledIds = Set(reconciled.map(\.id))
        let previousGGWorktreeModes = projects[idx].ggWorktreeModes
        projects[idx].ggWorktreeModes = previousGGWorktreeModes.filter {
            reconciledIds.contains($0.key)
        }
        return anchorChanged
            || orderChanged
            || projects[idx].hiddenWorktreePaths.count != before
            || projects[idx].ggWorktreeModes != previousGGWorktreeModes
    }

    func reconcileRemoteHostRegistrations(project: ProjectConfig, previous: [Worktree], reconciled: [Worktree]) {
        guard let host = project.host else { return }
        let liveRoots = Set(reconciled.map { $0.path.path })
        for worktree in previous where !liveRoots.contains(worktree.path.path) {
            RemoteHostRegistry.shared.unregister(root: worktree.path.path)
        }
        for worktree in reconciled {
            RemoteHostRegistry.shared.register(root: worktree.path.path, host: host)
        }
    }

    /// Remote and local roots must not overlap: a prefix collision would make
    /// host routing ambiguous. Existing local-to-local nesting remains valid.
    nonisolated static func ensureNoPathCollision(
        newRoot: String,
        newHost: String?,
        existing: [ProjectConfig],
        existingWorktreeRootsByProject: [String: [String]] = [:]
    ) throws {
        func overlaps(_ lhs: String, _ rhs: String) -> Bool {
            lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
        }

        for project in existing {
            let roots = [project.path] + existingWorktreeRootsByProject[project.id, default: []]
            for root in roots {
                let bothLocal = newHost == nil && project.host == nil
                let sameHost = newHost != nil && newHost == project.host
                if bothLocal || sameHost { continue }
                if !overlaps(newRoot, root) { continue }
                throw NSError(
                    domain: "ProjectsManager",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Path \(newRoot) collides with existing project \(project.name) (\(root)). Remote and local project roots must not overlap."]
                )
            }
        }
    }

    /// Refresh every project. Returns `true` when at least one project's
    /// persisted configuration changed, so the caller can save it.
    @discardableResult
    func refreshAll() async -> Bool {
        var changed = false
        for project in projects {
            if let didGC = try? await refreshWorktrees(projectId: project.id) {
                changed = changed || didGC
            }
        }
        return changed
    }

    /// Fast-path branch label update. Patches `branch` (and `name`, since
    /// name == branch in the current model) for any worktree whose
    /// canonicalized path matches a key in `branchByWorktreePath`. Worktrees
    /// not present in the map are left alone.
    ///
    /// Skips rows whose operation state is `.creating` or `.createFailed`:
    /// those rows show the user's intended branch name, not whatever git
    /// has on disk yet. `.deleting` and `.deleteFailed` rows are still
    /// updated — they correspond to real git worktrees with a pending UI
    /// operation, so git's branch is still the truth.
    @discardableResult
    func applyHeadUpdates(projectId: String, branchByWorktreePath: [URL: String]) -> Set<String> {
        guard var rows = worktreesByProject[projectId], !rows.isEmpty else { return [] }
        let lookup: [String: String] = Dictionary(uniqueKeysWithValues:
            branchByWorktreePath.map { (canonical($0.key), $0.value) }
        )
        var changed = false
        var changedPaths: Set<String> = []
        for i in rows.indices {
            let key = canonical(rows[i].path)
            guard let newBranch = lookup[key] else { continue }
            if let op = worktreeOperationStates[rows[i].id] {
                switch op {
                case .creating, .createFailed: continue
                case .deleting, .deleteFailed: break
                }
            }
            if rows[i].branch != newBranch || rows[i].name != newBranch {
                rows[i].branch = newBranch
                rows[i].name = newBranch
                changed = true
                changedPaths.insert(rows[i].path.path)
            }
        }
        if changed {
            worktreesByProject[projectId] = rows
            applyWorktreeOrdering(projectId: projectId)
        }
        return changedPaths
    }

    private func hiddenSet(projectId: String) -> Set<String> {
        guard let project = projects.first(where: { $0.id == projectId }) else { return [] }
        return Set(project.hiddenWorktreePaths)
    }

    private func canonical(_ url: URL) -> String {
        Worktree.makeId(path: url)
    }

    @discardableResult
    private func applyWorktreeOrdering(projectId: String) -> Bool {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectId }),
              let rows = worktreesByProject[projectId]
        else { return false }

        let project = projects[projectIndex]
        let ordered = sortedWorktrees(rows, project: project)
        worktreesByProject[projectId] = ordered

        let normalized = normalizedWorktreeOrder(project.worktreeOrder, rows: ordered, project: project)
        if projects[projectIndex].worktreeOrder != normalized {
            projects[projectIndex].worktreeOrder = normalized
            return true
        }
        return false
    }

    private func sortedWorktrees(_ rows: [Worktree], project: ProjectConfig) -> [Worktree] {
        let effectiveMode: AppConfig.WorktreeSortMode =
            project.worktreeOrderIsManual ? .manual : defaultOrderingSource()

        // Partition main first; main is always pinned at position 0.
        var main: [Worktree] = []
        var others: [Worktree] = []
        for row in rows {
            if isMainWorktree(row, project: project) { main.append(row) } else { others.append(row) }
        }

        let sortedOthers: [Worktree]
        switch effectiveMode {
        case .manual:
            let order = normalizedWorktreeOrder(project.worktreeOrder, rows: rows, project: project)
            let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
            sortedOthers = others.sorted { lhs, rhs in
                let lhsRank = rank[lhs.id]
                let rhsRank = rank[rhs.id]
                if let lhsRank, let rhsRank, lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhsRank != nil { return true }
                if rhsRank != nil { return false }
                return lhs.id < rhs.id
            }
        case .creationDesc:
            sortedOthers = others.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id < rhs.id
            }
        case .creationAsc:
            sortedOthers = others.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id < rhs.id
            }
        case .lastUpdateDesc:
            sortedOthers = others.sorted { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
                return lhs.id < rhs.id
            }
        case .lastUpdateAsc:
            sortedOthers = others.sorted { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity < rhs.lastActivity }
                return lhs.id < rhs.id
            }
        case .branchAsc:
            sortedOthers = others.sorted { lhs, rhs in
                let lb = lhs.branch.localizedLowercase
                let rb = rhs.branch.localizedLowercase
                if lb != rb { return lb < rb }
                return lhs.id < rhs.id
            }
        }

        return main + sortedOthers
    }

    private func normalizedWorktreeOrder(
        _ order: [String],
        rows: [Worktree],
        project: ProjectConfig
    ) -> [String] {
        // Empty input means "follow default" — keep it empty so callers can
        // distinguish manual-mode (non-empty) from auto-mode (empty).
        if order.isEmpty { return [] }

        let nonMainIds = Set(rows.filter { !isMainWorktree($0, project: project) }.map(\.id))
        var seen: Set<String> = []
        var normalized: [String] = []

        for id in order where nonMainIds.contains(id) && !seen.contains(id) {
            normalized.append(id)
            seen.insert(id)
        }

        for row in rows where nonMainIds.contains(row.id) && !seen.contains(row.id) {
            normalized.append(row.id)
            seen.insert(row.id)
        }

        return normalized
    }

    /// Whether `worktree` is the project's primary on-disk checkout (the main
    /// worktree) rather than a feature worktree. Reuses the same path
    /// comparison the sort logic uses to pin main at position 0.
    func isMain(_ worktree: Worktree, in project: ProjectConfig) -> Bool {
        isMainWorktree(worktree, project: project)
    }

    private func isMainWorktree(_ worktree: Worktree, project: ProjectConfig) -> Bool {
        worktree.isMainWorktree
            ?? (canonical(worktree.path) == canonical(URL(fileURLWithPath: project.path)))
    }
}
