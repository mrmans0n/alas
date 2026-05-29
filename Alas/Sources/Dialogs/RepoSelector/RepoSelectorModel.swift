import Foundation
import Observation

/// State + logic for the repo-selector dialog. View-agnostic; takes a
/// `RepoSelectorEnvironment` for all external reads/writes so the model is
/// unit-testable.
@Observable
@MainActor
final class RepoSelectorModel {
    private static let recentLimit = 5

    var isOpen: Bool = false
    var query: String = "" {
        didSet {
            // Reset selection so a shrinking filter never strands the cursor
            // on a stale row. Bump the scroll tick so the view snaps back.
            if query != oldValue {
                selectedIndex = 0
                scrollToSelectionTick &+= 1
            }
        }
    }
    private(set) var selectedIndex: Int = 0
    /// Bumped by keyboard navigation. The view scrolls the selected row into
    /// view on changes to this — not on `selectedIndex` itself — so
    /// hover-driven selection doesn't fight the user's scroll.
    private(set) var scrollToSelectionTick: Int = 0

    func open() {
        query = ""
        selectedIndex = 0
        isOpen = true
    }

    func close() {
        isOpen = false
    }

    // MARK: - Row generation

    /// Compute the rows for the current query state. Pure — does not mutate
    /// `self`. Callers re-invoke whenever inputs (query, projects, recents,
    /// worktrees, currentWorktreeId) change.
    func rows(environment env: RepoSelectorEnvironment) -> [RepoSelectorRow] {
        let projects = env.projects()
        guard !projects.isEmpty else { return [.emptyHint(.noProjects)] }
        if query.isEmpty {
            return emptyQueryRows(projects: projects, environment: env)
        } else {
            return filteredRows(projects: projects, environment: env)
        }
    }

    private func emptyQueryRows(
        projects: [ProjectConfig],
        environment env: RepoSelectorEnvironment
    ) -> [RepoSelectorRow] {
        let currentId = env.currentWorktreeId()
        let worktreesByProject = Dictionary(
            uniqueKeysWithValues: projects.map { ($0.id, env.visibleWorktrees($0.id)) }
        )
        let recents = env.readRecents()

        var rows: [RepoSelectorRow] = []

        // RECENT section: flatten all per-project recents, dedupe, take 5.
        let recentRows = recentSectionRows(
            projects: projects,
            worktreesByProject: worktreesByProject,
            recents: recents,
            currentId: currentId
        )
        if !recentRows.isEmpty {
            rows.append(.recentHeader)
            rows.append(contentsOf: recentRows)
        }

        // Project sections, ordered by recency of their most-recently-touched
        // worktree (alpha as the tie-breaker / no-recents fallback).
        let projectOrder = orderedProjects(
            projects: projects,
            worktreesByProject: worktreesByProject,
            recents: recents,
            currentId: currentId
        )
        for project in projectOrder {
            rows.append(.projectHeader(projectId: project.id))
            let worktrees = worktreesByProject[project.id] ?? []
            let validIds = Set(worktrees.map(\.id))
            let recentIds = recents.liveWorktreeIds(in: project.id, validWorktreeIds: validIds)
            let recentSet = Set(recentIds)
            let byId = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.id, $0) })
            for id in recentIds {
                guard let w = byId[id] else { continue }
                rows.append(.worktree(w, indices: [], isCurrent: w.id == currentId))
            }
            let rest = worktrees
                .filter { !recentSet.contains($0.id) }
                .sorted { a, b in
                    a.branch.localizedCaseInsensitiveCompare(b.branch) == .orderedAscending
                }
            for w in rest {
                rows.append(.worktree(w, indices: [], isCurrent: w.id == currentId))
            }
            rows.append(.action(.newWorktreeForRepo(projectId: project.id)))
        }

        rows.append(.actionsHeader)
        rows.append(.action(.newProject))
        return rows
    }

    private func recentSectionRows(
        projects: [ProjectConfig],
        worktreesByProject: [String: [Worktree]],
        recents: RepoSelectorRecents,
        currentId: String?
    ) -> [RepoSelectorRow] {
        // Consume the flat global recency list directly so the RECENT
        // section is strict cross-project recency rather than per-project
        // drain order.
        let visibleByProject: [String: Set<String>] = worktreesByProject.mapValues {
            Set($0.map(\.id))
        }
        let worktreeByPair: [String: [String: Worktree]] = worktreesByProject.mapValues {
            Dictionary(uniqueKeysWithValues: $0.map { ($0.id, $0) })
        }
        let refs = recents.liveRecentWorktreeRefs(
            projectsWithVisibleWorktrees: visibleByProject
        )
        let effectiveRefs = refs.isEmpty
            ? legacyRecentRefs(
                projects: projects,
                worktreesByProject: worktreesByProject,
                visibleByProject: visibleByProject,
                recents: recents
            )
            : refs

        var output: [RepoSelectorRow] = []
        for ref in effectiveRefs {
            guard let w = worktreeByPair[ref.projectId]?[ref.worktreeId] else { continue }
            output.append(.worktree(w, indices: [], isCurrent: w.id == currentId))
            if output.count >= Self.recentLimit { break }
        }
        return output
    }

    /// Synthesize cross-project recents from the legacy per-project lists
    /// for users upgrading from configs that pre-date `recentWorktreeRefs`.
    /// Interleaves projects round-robin (most-recently-touched project's
    /// most-recent worktree first), which is the best approximation
    /// possible without per-worktree timestamps. The next `focus()` call
    /// populates the flat list and this fallback stops being used.
    private func legacyRecentRefs(
        projects: [ProjectConfig],
        worktreesByProject: [String: [Worktree]],
        visibleByProject: [String: Set<String>],
        recents: RepoSelectorRecents
    ) -> [RepoSelectorRecents.RecentWorktreeRef] {
        let validProjectIds = Set(projects.map(\.id))
        let projectOrder = recents.liveProjectIds(validProjectIds: validProjectIds)
        guard !projectOrder.isEmpty else { return [] }

        let perProject: [(projectId: String, ids: [String])] = projectOrder.map { pid in
            let visible = visibleByProject[pid] ?? []
            let ids = recents.liveWorktreeIds(in: pid, validWorktreeIds: visible)
            return (pid, ids)
        }
        guard perProject.contains(where: { !$0.ids.isEmpty }) else { return [] }

        var refs: [RepoSelectorRecents.RecentWorktreeRef] = []
        var slot = 0
        let maxSlots = perProject.map(\.ids.count).max() ?? 0
        while slot < maxSlots && refs.count < Self.recentLimit {
            for entry in perProject where slot < entry.ids.count {
                refs.append(.init(projectId: entry.projectId, worktreeId: entry.ids[slot]))
                if refs.count >= Self.recentLimit { break }
            }
            slot += 1
        }
        return refs
    }

    /// Projects ordered with the current worktree's project first (switching
    /// usually means jumping within the same repo), then by the recency of
    /// their most-recently-touched worktree. Projects with no recents fall
    /// back to alpha order on name.
    private func orderedProjects(
        projects: [ProjectConfig],
        worktreesByProject: [String: [Worktree]],
        recents: RepoSelectorRecents,
        currentId: String?
    ) -> [ProjectConfig] {
        // The project owning the currently-selected worktree always sorts
        // first, regardless of recency or alpha.
        let currentProjectId = currentId.flatMap { id in
            worktreesByProject.first { $0.value.contains { $0.id == id } }?.key
        }
        // Build a "most-recent index" per project: lower = more recent.
        // Projects with no recents get .max so they sort to the back.
        let validProjectIds = Set(projects.map(\.id))
        let recentProjectIds = recents.liveProjectIds(validProjectIds: validProjectIds)
        let projectRecencyIndex: [String: Int] = Dictionary(
            uniqueKeysWithValues: recentProjectIds.enumerated().map { ($0.element, $0.offset) }
        )
        return projects.sorted { a, b in
            if let currentProjectId {
                let aCurrent = a.id == currentProjectId
                let bCurrent = b.id == currentProjectId
                // Only decide on current-project priority when exactly one of
                // them is the current project — returning `true` when both are
                // (i.e. comparing the element with itself) would break the
                // strict-weak-ordering contract of `sorted(by:)`.
                if aCurrent != bCurrent { return aCurrent }
            }
            let ai = projectRecencyIndex[a.id] ?? Int.max
            let bi = projectRecencyIndex[b.id] ?? Int.max
            if ai != bi { return ai < bi }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func filteredRows(
        projects: [ProjectConfig],
        environment env: RepoSelectorEnvironment
    ) -> [RepoSelectorRow] {
        struct Scored {
            let worktree: Worktree
            let result: FuzzyMatch.Result
        }
        let currentId = env.currentWorktreeId()
        var scored: [Scored] = []
        for project in projects {
            for w in env.visibleWorktrees(project.id) {
                if let r = FuzzyMatch.score(query: query, target: w.branch) {
                    scored.append(Scored(worktree: w, result: r))
                }
            }
        }
        return scored
            .sorted { a, b in
                if a.result.score != b.result.score { return a.result.score > b.result.score }
                return a.worktree.branch.localizedCaseInsensitiveCompare(b.worktree.branch)
                    == .orderedAscending
            }
            .map { .worktree($0.worktree, indices: $0.result.indices, isCurrent: $0.worktree.id == currentId) }
    }

    // MARK: - Activation

    enum Activation: Equatable {
        case focused(worktreeId: String)
        case openedNewWorktree(projectId: String)
        case openedNewProject
        case noop
    }

    @discardableResult
    func activate(rows: [RepoSelectorRow], environment env: RepoSelectorEnvironment) -> Activation {
        guard !rows.isEmpty else { return .noop }
        let safeIndex = max(0, min(rows.count - 1, selectedIndex))
        switch rows[safeIndex] {
        case .worktree(let worktree, _, _):
            return focus(worktree: worktree, environment: env)
        case .action(.newWorktreeForRepo(let projectId)):
            env.openNewWorktree(projectId)
            close()
            return .openedNewWorktree(projectId: projectId)
        case .action(.newProject):
            env.openNewProject()
            close()
            return .openedNewProject
        case .emptyHint(.noProjects):
            env.openNewProject()
            close()
            return .openedNewProject
        case .recentHeader, .projectHeader, .actionsHeader:
            return .noop
        }
    }

    private func focus(
        worktree: Worktree,
        environment env: RepoSelectorEnvironment
    ) -> Activation {
        env.focusWorktree(worktree.id)
        var r = env.readRecents()
        r.bumpProject(worktree.projectId)
        r.bumpWorktree(worktree.id, in: worktree.projectId)
        env.writeRecents(r)
        close()
        return .focused(worktreeId: worktree.id)
    }

    // MARK: - Selection

    func moveSelectionDown(in rows: [RepoSelectorRow]) {
        if let next = scan(from: selectedIndex, step: 1, in: rows) {
            selectedIndex = next
            scrollToSelectionTick &+= 1
        }
    }

    func moveSelectionUp(in rows: [RepoSelectorRow]) {
        if let prev = scan(from: selectedIndex, step: -1, in: rows) {
            selectedIndex = prev
            scrollToSelectionTick &+= 1
        }
    }

    /// Set selection directly, snapping forward (then backward) to the
    /// nearest selectable row if the target is a header. Used on hover.
    func setSelectedIndex(_ index: Int, in rows: [RepoSelectorRow]) {
        guard !rows.isEmpty else {
            selectedIndex = 0
            return
        }
        let clamped = max(0, min(rows.count - 1, index))
        if rows[clamped].isSelectable {
            selectedIndex = clamped
            return
        }
        if let fwd = scan(from: clamped, step: 1, in: rows) {
            selectedIndex = fwd
        } else if let back = scan(from: clamped, step: -1, in: rows) {
            selectedIndex = back
        } else {
            selectedIndex = clamped
        }
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
