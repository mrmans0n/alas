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

    // MARK: - Step 2 rows (stub for Task 7 — keep compiling)

    private func worktreeRows(
        projectId: String,
        environment env: RepoSelectorEnvironment
    ) -> [RepoSelectorRow] {
        return []
    }
}
