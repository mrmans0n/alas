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
            focusWorktree: { _, _ in },
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

    @Test func emptyQueryRecentsLimitsToFiveAcrossMultipleProjects() {
        // Two projects, each with several recents. Pumping the flat global
        // recents list past 5 must still produce exactly 5 RECENT rows —
        // this exercises the model's `recentLimit` independently of the
        // per-project store cap.
        let model = RepoSelectorModel()
        let p1 = project("p1")
        let p2 = project("p2")
        let p1Wts: [Worktree] = (1...4).map {
            worktree("p1-w\($0)", projectId: "p1", branch: "p1/b\($0)")
        }
        let p2Wts: [Worktree] = (1...4).map {
            worktree("p2-w\($0)", projectId: "p2", branch: "p2/b\($0)")
        }
        var r = RepoSelectorRecents()
        r.bumpProject("p1")
        r.bumpProject("p2")
        // Interleaved bumps across projects so the flat list is genuinely
        // cross-project. Final order (newest first):
        //   p2-w4, p1-w4, p2-w3, p1-w3, p2-w2, p1-w2, p2-w1, p1-w1
        for i in 1...4 {
            r.bumpWorktree("p1-w\(i)", in: "p1")
            r.bumpWorktree("p2-w\(i)", in: "p2")
        }
        let e = env(
            projects: [p1, p2],
            worktrees: ["p1": p1Wts, "p2": p2Wts],
            recents: r
        )
        let rows = model.rows(environment: e)
        // Take the RECENT section: everything between `.recentHeader` and
        // the first `.projectHeader`.
        guard rows.first == .recentHeader else {
            Issue.record("expected RECENT header at row 0, got \(rows.first as Any)")
            return
        }
        let recentWorktrees: [Worktree] = rows
            .dropFirst()
            .prefix(while: { row in
                if case .projectHeader = row { return false }
                return true
            })
            .compactMap { if case .worktree(let w, _, _) = $0 { return w } else { return nil } }
        // Exactly the global cap — neither bucketed by project nor over-long.
        #expect(recentWorktrees.count == 5)
        // Order is strict global recency, not project-bucketed.
        #expect(recentWorktrees.map(\.id) == ["p2-w4", "p1-w4", "p2-w3", "p1-w3", "p2-w2"])
    }

    @Test func emptyQueryRecentSectionIsGloballyOrderedNotProjectBucketed() {
        // Spec example: A/w1 → A/w2 → B/w3 → A/w4 ⇒ [w4, w3, w2, w1].
        let model = RepoSelectorModel()
        let pA = project("A")
        let pB = project("B")
        let aW1 = worktree("w1", projectId: "A", branch: "A/w1")
        let aW2 = worktree("w2", projectId: "A", branch: "A/w2")
        let aW4 = worktree("w4", projectId: "A", branch: "A/w4")
        let bW3 = worktree("w3", projectId: "B", branch: "B/w3")
        var r = RepoSelectorRecents()
        r.bumpWorktree("w1", in: "A")
        r.bumpWorktree("w2", in: "A")
        r.bumpWorktree("w3", in: "B")
        r.bumpWorktree("w4", in: "A")
        let e = env(
            projects: [pA, pB],
            worktrees: ["A": [aW1, aW2, aW4], "B": [bW3]],
            recents: r
        )
        let rows = model.rows(environment: e)
        let recentIds: [String] = rows
            .dropFirst()  // skip .recentHeader
            .prefix(while: { row in
                if case .projectHeader = row { return false }
                return true
            })
            .compactMap { if case .worktree(let w, _, _) = $0 { return w.id } else { return nil } }
        #expect(recentIds == ["w4", "w3", "w2", "w1"])
    }

    @Test func emptyQueryBackfillsRecentFromLegacyPerProjectListsWhenFlatRefsEmpty() {
        // Upgrade case: a config written before `recentWorktreeRefs` existed
        // only carries `projectIds` + `worktreeIdsByProject`. The RECENT
        // section should still populate (round-robin interleaved across
        // projects in projectIds order) instead of being empty until the
        // next focus.
        let model = RepoSelectorModel()
        let pA = project("A")
        let pB = project("B")
        let aWts: [Worktree] = (1...3).map { worktree("a\($0)", projectId: "A", branch: "A/\($0)") }
        let bWts: [Worktree] = (1...2).map { worktree("b\($0)", projectId: "B", branch: "B/\($0)") }
        var r = RepoSelectorRecents()
        // Legacy shape — `recentWorktreeRefs` left empty on purpose.
        r.projectIds = ["B", "A"]  // B is the most recently touched project
        r.worktreeIdsByProject = ["A": ["a1", "a2", "a3"], "B": ["b1", "b2"]]
        let e = env(
            projects: [pA, pB],
            worktrees: ["A": aWts, "B": bWts],
            recents: r
        )
        let rows = model.rows(environment: e)
        let recentIds: [String] = rows
            .dropFirst()  // skip .recentHeader
            .prefix(while: { row in
                if case .projectHeader = row { return false }
                return true
            })
            .compactMap { if case .worktree(let w, _, _) = $0 { return w.id } else { return nil } }
        // Round-robin from projectIds order ["B", "A"]:
        //   slot 0: b1, a1
        //   slot 1: b2, a2
        //   slot 2: a3   (B exhausted)
        // Cap is 5, so all of these fit.
        #expect(recentIds == ["b1", "a1", "b2", "a2", "a3"])
    }

    @Test func emptyQueryDoesNotBackfillWhenFlatRefsArePopulated() {
        // Once `recentWorktreeRefs` exists, it's authoritative — the
        // backfill must not contribute.
        let model = RepoSelectorModel()
        let pA = project("A")
        let pB = project("B")
        let aWts = [worktree("a1", projectId: "A", branch: "A/1")]
        let bWts = [worktree("b1", projectId: "B", branch: "B/1")]
        var r = RepoSelectorRecents()
        r.projectIds = ["A", "B"]
        r.worktreeIdsByProject = ["A": ["a1"], "B": ["b1"]]
        // Only B's worktree in the flat list — A's a1 must not be backfilled.
        r.recentWorktreeRefs = [.init(projectId: "B", worktreeId: "b1")]
        let e = env(
            projects: [pA, pB],
            worktrees: ["A": aWts, "B": bWts],
            recents: r
        )
        let rows = model.rows(environment: e)
        let recentIds: [String] = rows
            .dropFirst()
            .prefix(while: { row in
                if case .projectHeader = row { return false }
                return true
            })
            .compactMap { if case .worktree(let w, _, _) = $0 { return w.id } else { return nil } }
        #expect(recentIds == ["b1"])
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

    @Test func emptyQueryPutsCurrentWorktreesProjectFirst() {
        // Switching usually means jumping to another worktree in the same
        // repo, so the project owning the current worktree sorts first —
        // ahead of more-recent and alphabetically-earlier projects.
        let model = RepoSelectorModel()
        let acme = project("p-acme", name: "acme")
        let beta = project("p-beta", name: "beta")
        let alas = project("p-alas", name: "alas")
        let acmeW = worktree("acme-w", projectId: "p-acme", branch: "main")
        let betaW = worktree("beta-w", projectId: "p-beta", branch: "main")
        let alasW = worktree("alas-w", projectId: "p-alas", branch: "main")
        var r = RepoSelectorRecents()
        r.bumpProject("p-acme")  // acme is the most-recently-touched project
        let e = env(
            projects: [acme, beta, alas],
            worktrees: [
                "p-acme": [acmeW],
                "p-beta": [betaW],
                "p-alas": [alasW]
            ],
            recents: r,
            currentWorktreeId: "beta-w"  // current lives in beta
        )
        let rows = model.rows(environment: e)
        let headerOrder = rows.compactMap { row -> String? in
            if case .projectHeader(let pid) = row { return pid } else { return nil }
        }
        // beta first (owns current), then recency (acme), then alpha (alas).
        #expect(headerOrder == ["p-beta", "p-acme", "p-alas"])
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

    @Test func filterModeMatchesProjectNameAndBranchTogether() {
        let model = RepoSelectorModel()
        let alas = project("p-alas", name: "alas")
        let acme = project("p-acme", name: "acme")
        let alasWorktree = worktree("alas-blabla", projectId: "p-alas", branch: "blabla")
        let acmeWorktree = worktree("acme-blabla", projectId: "p-acme", branch: "blabla")
        let e = env(
            projects: [alas, acme],
            worktrees: [
                "p-alas": [alasWorktree],
                "p-acme": [acmeWorktree]
            ]
        )
        model.query = "alas blabla"

        let rows = model.rows(environment: e)
        let worktrees: [Worktree] = rows.compactMap {
            if case .worktree(let w, _, _) = $0 { return w } else { return nil }
        }
        #expect(worktrees == [alasWorktree])
    }

    @Test func filterModeMatchesProjectNameOnly() {
        let model = RepoSelectorModel()
        let alas = project("p-alas", name: "alas")
        let acme = project("p-acme", name: "acme")
        let main = worktree("alas-main", projectId: "p-alas", branch: "main")
        let feature = worktree("alas-feature", projectId: "p-alas", branch: "feature")
        let other = worktree("acme-main", projectId: "p-acme", branch: "main")
        let e = env(
            projects: [alas, acme],
            worktrees: [
                "p-alas": [main, feature],
                "p-acme": [other]
            ]
        )
        model.query = "alas"

        let rows = model.rows(environment: e)
        let worktreeIds: [String] = rows.compactMap {
            if case .worktree(let w, _, _) = $0 { return w.id } else { return nil }
        }
        #expect(Set(worktreeIds) == ["alas-main", "alas-feature"])
    }

    @Test func filterModeMapsScopedMatchIndicesToBranch() {
        let model = RepoSelectorModel()
        let alas = project("p-alas", name: "alas")
        let worktree = worktree("alas-blabla", projectId: "p-alas", branch: "blabla")
        let e = env(projects: [alas], worktrees: ["p-alas": [worktree]])
        model.query = "alas bla"

        let rows = model.rows(environment: e)
        guard case .worktree(_, let indices, _) = rows.first else {
            Issue.record("expected first row to be a worktree")
            return
        }
        #expect(indices == [0, 1, 2])
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
        var focused: (worktreeId: String, projectId: String)? = nil
        var writtenRecents: RepoSelectorRecents? = nil
        let w1 = worktree("w1", projectId: "p1")
        var e = env(projects: [project("p1")], worktrees: ["p1": [w1]])
        e.focusWorktree = { focused = (worktreeId: $0, projectId: $1) }
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
        #expect(focused?.worktreeId == "w1")
        #expect(focused?.projectId == "p1")
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
