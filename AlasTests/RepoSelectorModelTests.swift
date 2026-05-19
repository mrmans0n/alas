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
}
