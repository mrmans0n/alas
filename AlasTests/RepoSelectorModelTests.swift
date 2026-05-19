import Testing
import Foundation
@testable import Alas

@MainActor
struct RepoSelectorModelTests {
    // MARK: - Helpers

    private func project(_ id: String, name: String? = nil) -> ProjectConfig {
        ProjectConfig(
            id: id,
            name: name ?? id,
            path: "/tmp/\(id)",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func worktree(_ id: String, projectId: String, branch: String? = nil) -> Worktree {
        Worktree(
            id: id,
            projectId: projectId,
            name: branch ?? id,
            branch: branch ?? id,
            path: URL(fileURLWithPath: "/tmp/\(projectId)/\(id)"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0),
            addedLines: 0,
            deletedLines: 0
        )
    }

    private func env(
        projects: [ProjectConfig] = [],
        worktrees: [String: [Worktree]] = [:],
        recents: RepoSelectorRecents = RepoSelectorRecents()
    ) -> RepoSelectorEnvironment {
        var recentsBox = recents
        return RepoSelectorEnvironment(
            projects: { projects },
            visibleWorktrees: { worktrees[$0] ?? [] },
            readRecents: { recentsBox },
            writeRecents: { recentsBox = $0 },
            focusWorktree: { _ in },
            openNewProject: { },
            openNewWorktree: { _ in }
        )
    }

    // MARK: - Empty query

    @Test func emptyQueryNoRecentsListsProjectsInOrder() {
        let model = RepoSelectorModel()
        let e = env(projects: [project("a"), project("b"), project("c")])
        let rows = model.rows(environment: e)
        #expect(rows == [
            .repo(project("a"), indices: []),
            .repo(project("b"), indices: []),
            .repo(project("c"), indices: []),
        ])
    }

    @Test func emptyQueryWithRecentsPutsRecentsFirstWithDivider() {
        let model = RepoSelectorModel()
        var r = RepoSelectorRecents()
        r.bumpProject("b")
        r.bumpProject("c")  // most recent: c, then b
        let e = env(
            projects: [project("a"), project("b"), project("c")],
            recents: r
        )
        let rows = model.rows(environment: e)
        #expect(rows == [
            .repo(project("c"), indices: []),
            .repo(project("b"), indices: []),
            .divider(label: "All repositories"),
            .repo(project("a"), indices: []),
        ])
    }

    @Test func emptyQueryDropsDanglingRecents() {
        let model = RepoSelectorModel()
        var r = RepoSelectorRecents()
        r.bumpProject("missing")
        r.bumpProject("a")
        let e = env(projects: [project("a")], recents: r)
        let rows = model.rows(environment: e)
        #expect(rows == [.repo(project("a"), indices: [])])
    }

    @Test func emptyQueryEmptyProjectsShowsNoProjectsHint() {
        let model = RepoSelectorModel()
        let e = env(projects: [])
        let rows = model.rows(environment: e)
        #expect(rows == [.emptyHint(.noProjects)])
    }

    // MARK: - Non-empty query

    @Test func nonEmptyQueryFiltersAndRanks() {
        let model = RepoSelectorModel()
        model.query = "ala"
        let e = env(projects: [
            project("p1", name: "alas"),
            project("p2", name: "other"),
            project("p3", name: "alacrity"),
        ])
        let rows = model.rows(environment: e)
        // Both "alas" and "alacrity" match; ordering relies on FuzzyMatch
        // (shorter target ranks higher because the span penalty is smaller).
        // We only assert containment + that "other" was dropped.
        let names: [String] = rows.compactMap {
            if case .repo(let p, _) = $0 { return p.name } else { return nil }
        }
        #expect(names.contains("alas"))
        #expect(names.contains("alacrity"))
        #expect(!names.contains("other"))
        #expect(!rows.contains { if case .divider = $0 { return true } else { return false } })
    }

    @Test func nonEmptyQueryIncludesFuzzyIndices() {
        let model = RepoSelectorModel()
        model.query = "al"
        let e = env(projects: [project("p1", name: "alas")])
        let rows = model.rows(environment: e)
        guard case .repo(_, let indices) = rows.first else {
            Issue.record("expected first row to be a repo")
            return
        }
        #expect(indices == [0, 1])
    }

    // MARK: - Selection movement

    @Test func moveSelectionDownSkipsDivider() {
        let model = RepoSelectorModel()
        let rows: [RepoSelectorRow] = [
            .repo(project("a"), indices: []),
            .divider(label: "All repositories"),
            .repo(project("b"), indices: []),
        ]
        model.moveSelectionDown(in: rows)  // 0 -> 2 (skip divider at 1)
        #expect(model.selectedIndex == 2)
    }

    @Test func moveSelectionUpSkipsDivider() {
        let model = RepoSelectorModel()
        let rows: [RepoSelectorRow] = [
            .repo(project("a"), indices: []),
            .divider(label: "All repositories"),
            .repo(project("b"), indices: []),
        ]
        model.setSelectedIndex(2, in: rows)
        model.moveSelectionUp(in: rows)
        #expect(model.selectedIndex == 0)
    }

    @Test func moveSelectionDownClampsAtBottom() {
        let model = RepoSelectorModel()
        let rows: [RepoSelectorRow] = [
            .repo(project("a"), indices: []),
            .repo(project("b"), indices: []),
        ]
        model.setSelectedIndex(1, in: rows)
        model.moveSelectionDown(in: rows)
        #expect(model.selectedIndex == 1)
    }

    @Test func moveSelectionUpClampsAtTop() {
        let model = RepoSelectorModel()
        let rows: [RepoSelectorRow] = [
            .repo(project("a"), indices: []),
            .repo(project("b"), indices: []),
        ]
        model.moveSelectionUp(in: rows)
        #expect(model.selectedIndex == 0)
    }

    @Test func setSelectedIndexSnapsAwayFromDivider() {
        let model = RepoSelectorModel()
        let rows: [RepoSelectorRow] = [
            .repo(project("a"), indices: []),
            .divider(label: "All repositories"),
            .repo(project("b"), indices: []),
        ]
        model.setSelectedIndex(1, in: rows)  // divider; snap to next selectable
        #expect(model.selectedIndex == 2)
    }

    // MARK: - Push / pop

    @Test func pushRepoSwitchesStepAndResetsQuery() {
        let model = RepoSelectorModel()
        model.query = "ala"
        model.pushRepo(projectId: "p1")
        #expect(model.step == .worktrees(projectId: "p1"))
        #expect(model.query == "")
        #expect(model.selectedIndex == 0)
    }

    @Test func popToReposRestoresQueryAndStep() {
        let model = RepoSelectorModel()
        model.query = "ala"
        let e = env(projects: [project("p1", name: "alas"), project("p2", name: "other")])
        _ = model.rows(environment: e)
        model.setSelectedIndex(0, in: model.rows(environment: e))
        model.pushRepo(projectId: "p1")
        model.popToRepos()
        #expect(model.step == .repos)
        #expect(model.query == "ala")
        #expect(model.selectedIndex == 0)
    }

    // MARK: - Step 2 rows

    @Test func step2EmptyQueryListsRecentsThenRestThenAction() {
        let model = RepoSelectorModel()
        var r = RepoSelectorRecents()
        r.bumpWorktree("w3", in: "p1")
        r.bumpWorktree("w1", in: "p1")  // most recent
        let wts = [
            worktree("w1", projectId: "p1"),
            worktree("w2", projectId: "p1"),
            worktree("w3", projectId: "p1"),
        ]
        let e = env(
            projects: [project("p1")],
            worktrees: ["p1": wts],
            recents: r
        )
        model.pushRepo(projectId: "p1")
        let rows = model.rows(environment: e)
        #expect(rows == [
            .worktree(wts[0], indices: []),                                    // w1 (most recent)
            .worktree(wts[2], indices: []),                                    // w3 (next recent)
            .worktree(wts[1], indices: []),                                    // w2 (rest, sidebar order)
            .divider(label: ""),
            .action(.newWorktreeForRepo(projectId: "p1")),
        ])
    }

    @Test func step2NonEmptyQueryFiltersAndKeepsActionRow() {
        let model = RepoSelectorModel()
        let wts = [
            worktree("w1", projectId: "p1", branch: "main"),
            worktree("w2", projectId: "p1", branch: "feature/login"),
            worktree("w3", projectId: "p1", branch: "feature/repo-selector"),
        ]
        let e = env(projects: [project("p1")], worktrees: ["p1": wts])
        model.pushRepo(projectId: "p1")
        model.query = "feat"
        let rows = model.rows(environment: e)
        let branches: [String] = rows.compactMap {
            if case .worktree(let w, _) = $0 { return w.branch } else { return nil }
        }
        #expect(branches.contains("feature/login"))
        #expect(branches.contains("feature/repo-selector"))
        #expect(!branches.contains("main"))
        // The action row remains at the bottom regardless of query.
        #expect(rows.last == .action(.newWorktreeForRepo(projectId: "p1")))
    }
}
