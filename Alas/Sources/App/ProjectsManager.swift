import Foundation
import Observation

struct ProjectUpdate: Equatable {
    var name: String
    var color: String
    var startupScripts: ProjectStartupScripts = .defaults
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
    }

    /// Replace the live source of the global default sort mode. Callers must
    /// also invoke `reapplyOrderingForAllProjects()` after a config change to
    /// propagate the new mode to already-sorted lists — `setDefaultOrdering`
    /// alone does not trigger a re-sort.
    func setDefaultOrdering(_ source: @escaping () -> AppConfig.WorktreeSortMode) {
        self.defaultOrderingSource = source
    }

    func addProject(path: URL, displayName: String, color: String) async throws -> ProjectConfig {
        let isRepo = try await git.isGitRepository(path)
        guard isRepo else {
            throw NSError(domain: "ProjectsManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Not a git repository: \(path.path)"])
        }
        let project = ProjectConfig(
            id: UUID().uuidString,
            name: displayName,
            path: path.path,
            color: color,
            addedAt: Date()
        )
        projects.append(project)
        return project
    }

    func removeProject(id: String) {
        let ids = Set(worktreesByProject[id, default: []].map(\.id))
        projects.removeAll { $0.id == id }
        worktreesByProject.removeValue(forKey: id)
        worktreeOperationStates = worktreeOperationStates.filter { !ids.contains($0.key) }
    }

    func updateProject(id: String, update: ProjectUpdate) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].name = update.name
        projects[idx].color = update.color
        projects[idx].startupScripts = update.startupScripts
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
        guard !projects[idx].worktreeOrder.isEmpty else { return }
        projects[idx].worktreeOrder = []
        applyWorktreeOrdering(projectId: projectId)
    }

    func reapplyOrderingForAllProjects() {
        for project in projects {
            applyWorktreeOrdering(projectId: project.id)
        }
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

    /// Refresh the live worktree list for a project and GC orphan hidden
    /// paths. Returns `true` when the GC dropped at least one entry, so the
    /// caller can persist the change to disk; `false` otherwise.
    @discardableResult
    func refreshWorktrees(projectId: String) async throws -> Bool {
        guard let project = projects.first(where: { $0.id == projectId }) else { return false }
        let url = URL(fileURLWithPath: project.path)
        let trees = try await worktreeSvc.list(repoPath: url, projectId: projectId)

        // Reconcile optimistic rows: preserve creating rows that still aren't in git,
        // replace them with real rows when they appear, and clear operation state.
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
                } else {
                    // Creation succeeded; clear the pending state.
                    clearOperationIds.append(id)
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
        worktreesByProject[projectId] = reconciled
        let orderChanged = applyWorktreeOrdering(projectId: projectId)

        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return false }
        let live = Set(trees.map { canonical($0.path) })
        let before = projects[idx].hiddenWorktreePaths.count
        projects[idx].hiddenWorktreePaths.removeAll { !live.contains($0) }
        return orderChanged || projects[idx].hiddenWorktreePaths.count != before
    }

    /// Refresh every project. Returns `true` when at least one project's
    /// hidden-path GC dropped an entry, so the caller can persist the change.
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
    func applyHeadUpdates(projectId: String, branchByWorktreePath: [URL: String]) {
        guard var rows = worktreesByProject[projectId], !rows.isEmpty else { return }
        let lookup: [String: String] = Dictionary(uniqueKeysWithValues:
            branchByWorktreePath.map { (canonical($0.key), $0.value) }
        )
        var changed = false
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
            }
        }
        if changed {
            worktreesByProject[projectId] = rows
            applyWorktreeOrdering(projectId: projectId)
        }
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
            project.worktreeOrder.isEmpty ? defaultOrderingSource() : .manual

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
        case .lastUpdateDesc:
            sortedOthers = others.sorted { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
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

    private func isMainWorktree(_ worktree: Worktree, project: ProjectConfig) -> Bool {
        canonical(worktree.path) == canonical(URL(fileURLWithPath: project.path))
    }
}
