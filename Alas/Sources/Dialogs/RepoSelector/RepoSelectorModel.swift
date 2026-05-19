import Foundation
import Observation

/// State + logic for the repo-selector dialog. View-agnostic; takes a
/// `RepoSelectorEnvironment` for all external reads/writes so the model is
/// unit-testable.
@Observable
@MainActor
final class RepoSelectorModel {
    enum Step: Equatable {
        case repos
        case worktrees(projectId: String)
    }

    var isOpen: Bool = false
    private(set) var step: Step = .repos
    var query: String = ""
    private(set) var selectedIndex: Int = 0

    // Snapshot of step-1 state preserved across a push so popToRepos can
    // restore both the query and (where possible) the selection.
    private var savedReposQuery: String = ""
    private var savedReposSelectedIndex: Int = 0

    func open() {
        step = .repos
        query = ""
        selectedIndex = 0
        savedReposQuery = ""
        savedReposSelectedIndex = 0
        isOpen = true
    }

    func close() {
        isOpen = false
    }

    /// Compute the rows for the current step. Pure — does not mutate `self`.
    /// Callers re-invoke whenever inputs (query, step, projects, recents)
    /// change.
    func rows(environment env: RepoSelectorEnvironment) -> [RepoSelectorRow] {
        switch step {
        case .repos:
            return repoRows(environment: env)
        case .worktrees(let projectId):
            return worktreeRows(projectId: projectId, environment: env)
        }
    }

    // MARK: - Step 1 rows

    private func repoRows(environment env: RepoSelectorEnvironment) -> [RepoSelectorRow] {
        let projects = env.projects()
        guard !projects.isEmpty else { return [.emptyHint(.noProjects)] }

        if query.isEmpty {
            return emptyQueryRepoRows(projects: projects, environment: env)
        } else {
            return filteredRepoRows(projects: projects)
        }
    }

    private func emptyQueryRepoRows(
        projects: [ProjectConfig],
        environment env: RepoSelectorEnvironment
    ) -> [RepoSelectorRow] {
        let validIds = Set(projects.map(\.id))
        let recentIds = env.readRecents().liveProjectIds(validProjectIds: validIds)
        let projectsById = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })

        let recentRows: [RepoSelectorRow] = recentIds.compactMap { id in
            projectsById[id].map { .repo($0, indices: []) }
        }
        let recentSet = Set(recentIds)
        let rest = projects
            .filter { !recentSet.contains($0.id) }
            .map { RepoSelectorRow.repo($0, indices: []) }

        if recentRows.isEmpty { return rest }
        if rest.isEmpty { return recentRows }
        return recentRows + [.divider(label: "All repositories")] + rest
    }

    private func filteredRepoRows(projects: [ProjectConfig]) -> [RepoSelectorRow] {
        struct Scored {
            let project: ProjectConfig
            let result: FuzzyMatch.Result
        }
        let scored: [Scored] = projects.compactMap { p in
            guard let r = FuzzyMatch.score(query: query, target: p.name) else { return nil }
            return Scored(project: p, result: r)
        }
        return scored
            .sorted { a, b in
                if a.result.score != b.result.score { return a.result.score > b.result.score }
                return a.project.name.localizedCaseInsensitiveCompare(b.project.name) == .orderedAscending
            }
            .map { .repo($0.project, indices: $0.result.indices) }
    }

    // MARK: - Step transitions

    func pushRepo(projectId: String) {
        savedReposQuery = query
        savedReposSelectedIndex = selectedIndex
        step = .worktrees(projectId: projectId)
        query = ""
        selectedIndex = 0
    }

    func popToRepos() {
        step = .repos
        query = savedReposQuery
        selectedIndex = savedReposSelectedIndex
    }

    // MARK: - Step 2 rows

    private func worktreeRows(
        projectId: String,
        environment env: RepoSelectorEnvironment
    ) -> [RepoSelectorRow] {
        let worktrees = env.visibleWorktrees(projectId)

        let listed: [RepoSelectorRow]
        if query.isEmpty {
            listed = emptyQueryWorktreeRows(
                projectId: projectId,
                worktrees: worktrees,
                environment: env
            )
        } else {
            listed = filteredWorktreeRows(worktrees: worktrees)
        }

        var rows = listed
        rows.append(.divider(label: ""))
        rows.append(.action(.newWorktreeForRepo(projectId: projectId)))
        return rows
    }

    private func emptyQueryWorktreeRows(
        projectId: String,
        worktrees: [Worktree],
        environment env: RepoSelectorEnvironment
    ) -> [RepoSelectorRow] {
        let validIds = Set(worktrees.map(\.id))
        let recentIds = env.readRecents().liveWorktreeIds(in: projectId, validWorktreeIds: validIds)
        let byId = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.id, $0) })
        let recentRows: [RepoSelectorRow] = recentIds.compactMap {
            byId[$0].map { .worktree($0, indices: []) }
        }
        let recentSet = Set(recentIds)
        let rest = worktrees
            .filter { !recentSet.contains($0.id) }
            .map { RepoSelectorRow.worktree($0, indices: []) }
        return recentRows + rest
    }

    private func filteredWorktreeRows(worktrees: [Worktree]) -> [RepoSelectorRow] {
        struct Scored {
            let worktree: Worktree
            let result: FuzzyMatch.Result
        }
        let scored: [Scored] = worktrees.compactMap { w in
            guard let r = FuzzyMatch.score(query: query, target: w.branch) else { return nil }
            return Scored(worktree: w, result: r)
        }
        return scored
            .sorted { a, b in
                if a.result.score != b.result.score { return a.result.score > b.result.score }
                return a.worktree.branch.localizedCaseInsensitiveCompare(b.worktree.branch) == .orderedAscending
            }
            .map { .worktree($0.worktree, indices: $0.result.indices) }
    }

    // MARK: - Selection

    func moveSelectionDown(in rows: [RepoSelectorRow]) {
        let next = nextSelectable(from: selectedIndex, step: 1, in: rows)
        if let next { selectedIndex = next }
    }

    func moveSelectionUp(in rows: [RepoSelectorRow]) {
        let prev = nextSelectable(from: selectedIndex, step: -1, in: rows)
        if let prev { selectedIndex = prev }
    }

    /// Set selection directly, snapping forward (then backward) to the
    /// nearest selectable row if the target is a divider. Used on hover.
    func setSelectedIndex(_ index: Int, in rows: [RepoSelectorRow]) {
        guard !rows.isEmpty else { selectedIndex = 0; return }
        let clamped = max(0, min(rows.count - 1, index))
        if rows[clamped].isSelectable {
            selectedIndex = clamped
            return
        }
        // Try forward first, then backward.
        if let fwd = scan(from: clamped, step: 1, in: rows) {
            selectedIndex = fwd
        } else if let back = scan(from: clamped, step: -1, in: rows) {
            selectedIndex = back
        } else {
            selectedIndex = clamped
        }
    }

    /// Resets selection to the first selectable row. Called after recomputes.
    func resetSelectionToFirstSelectable(in rows: [RepoSelectorRow]) {
        if let idx = scan(from: -1, step: 1, in: rows) {
            selectedIndex = idx
        } else {
            selectedIndex = 0
        }
    }

    private func nextSelectable(
        from index: Int,
        step: Int,
        in rows: [RepoSelectorRow]
    ) -> Int? {
        scan(from: index, step: step, in: rows)
    }

    private func scan(from index: Int, step: Int, in rows: [RepoSelectorRow]) -> Int? {
        var i = index + step
        while i >= 0 && i < rows.count {
            if rows[i].isSelectable { return i }
            i += step
        }
        return nil
    }
}
