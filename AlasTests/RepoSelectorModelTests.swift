import Testing
import Foundation
@testable import Alas

@MainActor
struct RepoSelectorModelTests {
    // MARK: - Fixtures

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
        recents: RepoSelectorRecents = RepoSelectorRecents(),
        currentWorktreeId: String? = nil
    ) -> RepoSelectorEnvironment {
        var recentsBox = recents
        return RepoSelectorEnvironment(
            projects: { projects },
            visibleWorktrees: { worktrees[$0] ?? [] },
            readRecents: { recentsBox },
            writeRecents: { recentsBox = $0 },
            focusWorktree: { _ in },
            openNewProject: { },
            openNewWorktree: { _ in },
            currentWorktreeId: { currentWorktreeId }
        )
    }

    // MARK: - Empty-projects state

    @Test func emptyProjectsShowsNoProjectsHint() {
        let model = RepoSelectorModel()
        let e = env(projects: [])
        #expect(model.rows(environment: e) == [.emptyHint(.noProjects)])
    }

    // MARK: - Empty-query state

    @Test func emptyQueryNoRecentsSingleProjectListsHeaderWorktreesActionThenAddProject() {
        let model = RepoSelectorModel()
        let w1 = worktree("w1", projectId: "p1")
        let e = env(
            projects: [project("p1")],
            worktrees: ["p1": [w1]]
        )
        #expect(model.rows(environment: e) == [
            .projectHeader(projectId: "p1"),
            .worktree(w1, indices: [], isCurrent: false),
            .action(.newWorktreeForRepo(projectId: "p1")),
            .actionsHeader,
            .action(.newProject)
        ])
    }

    @Test func emptyQueryWithRecentsPutsRecentHeaderAndRecentRowsFirst() {
        let model = RepoSelectorModel()
        let pAlas = project("p-alas", name: "alas")
        let pAcme = project("p-acme", name: "acme")
        let alasMain = worktree("alas-main", projectId: "p-alas", branch: "main")
        let alasFeat = worktree("alas-feat", projectId: "p-alas", branch: "feat")
        let acmeMain = worktree("acme-main", projectId: "p-acme", branch: "main")
        var r = RepoSelectorRecents()
        r.bumpWorktree("alas-main", in: "p-alas")  // older
        r.bumpWorktree("acme-main", in: "p-acme")  // newer → first
        r.bumpProject("p-alas")
        r.bumpProject("p-acme")  // newest project
        let e = env(
            projects: [pAlas, pAcme],
            worktrees: [
                "p-alas": [alasMain, alasFeat],
                "p-acme": [acmeMain]
            ],
            recents: r
        )

        let rows = model.rows(environment: e)
        // RECENT header + the two recent worktrees (newest first)
        #expect(rows.prefix(3) == [
            .recentHeader,
            .worktree(acmeMain, indices: [], isCurrent: false),
            .worktree(alasMain, indices: [], isCurrent: false)
        ])
        // Then projects in recency order: acme first, then alas
        let acmeIdx = rows.firstIndex(of: .projectHeader(projectId: "p-acme"))
        let alasIdx = rows.firstIndex(of: .projectHeader(projectId: "p-alas"))
        #expect(acmeIdx != nil && alasIdx != nil && acmeIdx! < alasIdx!)
        // Trailing actions header + add-project action.
        #expect(rows.suffix(2) == [.actionsHeader, .action(.newProject)])
    }

    @Test func emptyQueryWithNoRecentsOmitsRecentHeader() {
        let model = RepoSelectorModel()
        let e = env(
            projects: [project("p1")],
            worktrees: ["p1": [worktree("w1", projectId: "p1")]]
        )
        let rows = model.rows(environment: e)
        #expect(!rows.contains(.recentHeader))
    }

    @Test func emptyQueryRecentsLimitsToFive() {
        let model = RepoSelectorModel()
        let wts: [Worktree] = (1...7).map { worktree("w\($0)", projectId: "p1", branch: "b\($0)") }
        var r = RepoSelectorRecents()
        r.bumpProject("p1")
        // bump in reverse so w1 ends up most recent
        for w in wts.reversed() { r.bumpWorktree(w.id, in: "p1") }
        // The store caps at 5 per project (see RepoSelectorRecents.worktreeCapPerProject)
        // and the model caps at 5 across the whole RECENT section. Either bound is
        // enough to keep this test honest; with one project both bounds apply.
        let e = env(
            projects: [project("p1")],
            worktrees: ["p1": wts],
            recents: r
        )
        let rows = model.rows(environment: e)
        let recentWorktrees: [Worktree] = rows
            .prefix(while: { $0 != .projectHeader(projectId: "p1") })
            .compactMap { if case .worktree(let w, _, _) = $0 { return w } else { return nil } }
        #expect(recentWorktrees.count == 5)
    }

    @Test func emptyQueryProjectSectionOrdersByRecencyThenAlpha() {
        let model = RepoSelectorModel()
        let p1 = project("p1")
        let wa = worktree("wa", projectId: "p1", branch: "a")
        let wb = worktree("wb", projectId: "p1", branch: "b")
        let wc = worktree("wc", projectId: "p1", branch: "c")
        var r = RepoSelectorRecents()
        r.bumpWorktree("wb", in: "p1")  // wb is the only recency hit
        let e = env(
            projects: [p1],
            worktrees: ["p1": [wa, wb, wc]],
            recents: r
        )
        let rows = model.rows(environment: e)
        // Inside p1's section: wb (recent) first, then wa, wc (alphabetical).
        let inSection: [Worktree] = rows
            .drop(while: { $0 != .projectHeader(projectId: "p1") })
            .dropFirst()
            .prefix(while: { row in
                if case .action(.newWorktreeForRepo) = row { return false }
                return true
            })
            .compactMap { if case .worktree(let w, _, _) = $0 { return w } else { return nil } }
        #expect(inSection == [wb, wa, wc])
    }

    @Test func emptyQueryProjectWithZeroWorktreesStillShowsHeaderAndNewWorktreeAction() {
        let model = RepoSelectorModel()
        let e = env(
            projects: [project("p1")],
            worktrees: ["p1": []]
        )
        let rows = model.rows(environment: e)
        #expect(rows.contains(.projectHeader(projectId: "p1")))
        #expect(rows.contains(.action(.newWorktreeForRepo(projectId: "p1"))))
    }

    @Test func isCurrentSetForCurrentWorktreeInBothRecentAndProjectSections() {
        let model = RepoSelectorModel()
        let p1 = project("p1")
        let w1 = worktree("w1", projectId: "p1")
        var r = RepoSelectorRecents()
        r.bumpProject("p1")
        r.bumpWorktree("w1", in: "p1")
        let e = env(
            projects: [p1],
            worktrees: ["p1": [w1]],
            recents: r,
            currentWorktreeId: "w1"
        )
        let rows = model.rows(environment: e)
        let currentMarks = rows.compactMap { row -> Bool? in
            if case .worktree(_, _, let isCurrent) = row { return isCurrent } else { return nil }
        }
        // Two .worktree rows (one in Recent, one in the project section); both flagged.
        #expect(currentMarks == [true, true])
    }

    // MARK: - Filter mode

    @Test func filterModeProducesFlatFuzzyRankedWorktrees() {
        let model = RepoSelectorModel()
        let p1 = project("p1")
        let p2 = project("p2")
        let main = worktree("w1", projectId: "p1", branch: "main")
        let checkout = worktree("w2", projectId: "p2", branch: "feat/checkout")
        let check = worktree("w3", projectId: "p2", branch: "fix/check-flake")
        let e = env(
            projects: [p1, p2],
            worktrees: ["p1": [main], "p2": [checkout, check]]
        )
        model.query = "check"
        let rows = model.rows(environment: e)
        // Headers and action rows are absent in filter mode.
        #expect(!rows.contains(where: {
            if case .recentHeader = $0 { return true }
            if case .projectHeader = $0 { return true }
            if case .actionsHeader = $0 { return true }
            if case .action = $0 { return true }
            return false
        }))
        let branches: [String] = rows.compactMap {
            if case .worktree(let w, _, _) = $0 { return w.branch } else { return nil }
        }
        #expect(branches.contains("feat/checkout"))
        #expect(branches.contains("fix/check-flake"))
        #expect(!branches.contains("main"))
    }

    @Test func filterModeAttachesFuzzyMatchIndices() {
        let model = RepoSelectorModel()
        let p1 = project("p1")
        let main = worktree("w1", projectId: "p1", branch: "main")
        let e = env(projects: [p1], worktrees: ["p1": [main]])
        model.query = "ma"
        let rows = model.rows(environment: e)
        guard case .worktree(_, let indices, _) = rows.first else {
            Issue.record("expected first row to be a worktree")
            return
        }
        #expect(indices == [0, 1])
    }

    @Test func filterModePropagatesCurrentFlag() {
        let model = RepoSelectorModel()
        let p1 = project("p1")
        let main = worktree("w1", projectId: "p1", branch: "main")
        let e = env(
            projects: [p1],
            worktrees: ["p1": [main]],
            currentWorktreeId: "w1"
        )
        model.query = "ma"
        let rows = model.rows(environment: e)
        guard case .worktree(_, _, let isCurrent) = rows.first else {
            Issue.record("expected first row to be a worktree")
            return
        }
        #expect(isCurrent == true)
    }

    // MARK: - Selection movement

    @Test func moveSelectionDownSkipsAllHeaderKinds() {
        let model = RepoSelectorModel()
        let w1 = worktree("w1", projectId: "p1")
        let rows: [RepoSelectorRow] = [
            .recentHeader,
            .worktree(w1, indices: [], isCurrent: false),
            .projectHeader(projectId: "p1"),
            .worktree(w1, indices: [], isCurrent: false),
            .actionsHeader,
            .action(.newProject)
        ]
        model.setSelectedIndex(1, in: rows)
        model.moveSelectionDown(in: rows)
        #expect(model.selectedIndex == 3)  // skipped projectHeader at 2
        model.moveSelectionDown(in: rows)
        #expect(model.selectedIndex == 5)  // skipped actionsHeader at 4
    }

    @Test func moveSelectionUpSkipsAllHeaderKinds() {
        let model = RepoSelectorModel()
        let w1 = worktree("w1", projectId: "p1")
        let rows: [RepoSelectorRow] = [
            .recentHeader,
            .worktree(w1, indices: [], isCurrent: false),
            .projectHeader(projectId: "p1"),
            .worktree(w1, indices: [], isCurrent: false),
            .actionsHeader,
            .action(.newProject)
        ]
        model.setSelectedIndex(5, in: rows)
        model.moveSelectionUp(in: rows)
        #expect(model.selectedIndex == 3)
        model.moveSelectionUp(in: rows)
        #expect(model.selectedIndex == 1)
    }

    @Test func setSelectedIndexSnapsAwayFromAnyHeader() {
        let model = RepoSelectorModel()
        let w1 = worktree("w1", projectId: "p1")
        let rows: [RepoSelectorRow] = [
            .recentHeader,
            .worktree(w1, indices: [], isCurrent: false)
        ]
        model.setSelectedIndex(0, in: rows)
        #expect(model.selectedIndex == 1)
    }

    @Test func changingQueryResetsSelectionToZero() {
        let model = RepoSelectorModel()
        let w1 = worktree("w1", projectId: "p1")
        let rows: [RepoSelectorRow] = [
            .worktree(w1, indices: [], isCurrent: false),
            .worktree(w1, indices: [], isCurrent: false)
        ]
        model.setSelectedIndex(1, in: rows)
        #expect(model.selectedIndex == 1)
        model.query = "a"
        #expect(model.selectedIndex == 0)
    }

    // MARK: - Activation

    @Test func activateWorktreeFocusesClosesAndBumpsRecents() {
        let model = RepoSelectorModel()
        model.isOpen = true
        var focused: String? = nil
        var writtenRecents: RepoSelectorRecents? = nil
        let w1 = worktree("w1", projectId: "p1")
        var e = env(projects: [project("p1")], worktrees: ["p1": [w1]])
        e.focusWorktree = { focused = $0 }
        e.writeRecents = { writtenRecents = $0 }

        let rows = model.rows(environment: e)
        // First selectable row is the worktree (under the projectHeader).
        guard let widx = rows.firstIndex(where: {
            if case .worktree = $0 { return true } else { return false }
        }) else {
            Issue.record("expected a worktree row")
            return
        }
        model.setSelectedIndex(widx, in: rows)
        let result = model.activate(rows: rows, environment: e)

        #expect(result == .focused(worktreeId: "w1"))
        #expect(focused == "w1")
        #expect(model.isOpen == false)
        #expect(writtenRecents?.projectIds == ["p1"])
        #expect(writtenRecents?.worktreeIdsByProject["p1"] == ["w1"])
    }

    @Test func activateNewWorktreeForRepoDelegatesAndCloses() {
        let model = RepoSelectorModel()
        model.isOpen = true
        var openedFor: String? = nil
        var e = env(projects: [project("p1")], worktrees: ["p1": [worktree("w1", projectId: "p1")]])
        e.openNewWorktree = { openedFor = $0 }

        let rows = model.rows(environment: e)
        guard let aidx = rows.firstIndex(where: {
            if case .action(.newWorktreeForRepo) = $0 { return true } else { return false }
        }) else {
            Issue.record("expected a newWorktreeForRepo action")
            return
        }
        model.setSelectedIndex(aidx, in: rows)
        let result = model.activate(rows: rows, environment: e)

        #expect(result == .openedNewWorktree(projectId: "p1"))
        #expect(openedFor == "p1")
        #expect(model.isOpen == false)
    }

    @Test func activateNewProjectDelegatesAndCloses() {
        let model = RepoSelectorModel()
        model.isOpen = true
        var opened = false
        var e = env(projects: [project("p1")], worktrees: ["p1": [worktree("w1", projectId: "p1")]])
        e.openNewProject = { opened = true }

        let rows = model.rows(environment: e)
        guard let idx = rows.firstIndex(of: .action(.newProject)) else {
            Issue.record("expected a newProject action")
            return
        }
        model.setSelectedIndex(idx, in: rows)
        let result = model.activate(rows: rows, environment: e)

        #expect(result == .openedNewProject)
        #expect(opened)
        #expect(model.isOpen == false)
    }

    @Test func activateNoProjectsHintDelegatesToNewProject() {
        let model = RepoSelectorModel()
        model.isOpen = true
        var opened = false
        var e = env(projects: [])
        e.openNewProject = { opened = true }

        let rows = model.rows(environment: e)
        model.setSelectedIndex(0, in: rows)
        let result = model.activate(rows: rows, environment: e)

        #expect(result == .openedNewProject)
        #expect(opened)
        #expect(model.isOpen == false)
    }
}
