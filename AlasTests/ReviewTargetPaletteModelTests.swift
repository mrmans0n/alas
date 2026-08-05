import Foundation
import Testing
@testable import Alas

@MainActor
struct ReviewTargetPaletteModelTests {
    private func worktree(_ branch: String, id: String? = nil) -> Worktree {
        Worktree(
            id: id ?? "/tmp/\(branch)",
            projectId: "p1",
            name: branch,
            branch: branch,
            path: URL(fileURLWithPath: "/tmp/\(branch)"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
    }

    private func commit(_ sha: String, _ subject: String) -> CommitInfo {
        CommitInfo(sha: sha, shortSha: String(sha.prefix(7)), author: "A", authorInitials: "A",
                   date: Date(timeIntervalSince1970: 0), subject: subject, conventionalTag: nil,
                   filesChanged: 0, insertions: 0, deletions: 0)
    }

    private func environment(
        worktrees: [Worktree] = [],
        currentId: String? = nil,
        commits: [CommitInfo] = [],
        comparisonRef: String? = "origin/main",
        branches: [String] = [],
        onOpen: @escaping (ReviewSessionTarget, Worktree) -> Void = { _, _ in }
    ) -> ReviewTargetPaletteEnvironment {
        ReviewTargetPaletteEnvironment(
            worktrees: { worktrees },
            currentWorktreeId: { currentId },
            loadCommitsAhead: { _ in (commits, comparisonRef) },
            loadBranches: { _ in branches },
            resolveRevision: { _, ref in "resolved-\(ref)" },
            currentBranch: { _ in "feature" },
            headSHA: { _ in "head-sha" },
            openTarget: onOpen
        )
    }

    @Test func exactRevisionQueryLaunchesTrackedCommit() async throws {
        let model = ReviewTargetPaletteModel()
        let w = worktree("feature")
        var opened: ReviewSessionTarget?
        let env = environment(worktrees: [w], branches: [], onOpen: { target, _ in opened = target })
        model.open(prefill: w)
        await model.loadTargets(environment: env)

        model.query = "HEAD~3"
        await model.validateRevisionQuery(environment: env)

        #expect(model.targetRows().contains(.followedRevision(
            expression: "HEAD~3",
            resolvedSHA: "resolved-HEAD~3",
            branch: "feature"
        )))
        await model.activateSelection(environment: env)
        #expect(opened?.kind == .trackedCommit)
        #expect(opened?.revisionDescription == "HEAD~3 -> resolved-HEAD~3")
    }

    @Test func worktreeEntriesPutCurrentFirstThenAlpha() {
        let model = ReviewTargetPaletteModel()
        model.open()
        let env = environment(
            worktrees: [worktree("zeta"), worktree("alpha"), worktree("current")],
            currentId: "/tmp/current"
        )
        let entries = model.worktreeEntries(environment: env)
        #expect(entries.map(\.worktree.branch) == ["current", "alpha", "zeta"])
        #expect(entries[0].isCurrent)
    }

    @Test func worktreeEntriesFuzzyFilterByBranch() {
        let model = ReviewTargetPaletteModel()
        model.open()
        let env = environment(worktrees: [worktree("feature-login"), worktree("bugfix-crash")])
        model.query = "fl"
        let entries = model.worktreeEntries(environment: env)
        #expect(entries.map(\.worktree.branch) == ["feature-login"])
    }

    @Test func loadWorktreeMetricsPopulatesAheadCounts() async {
        let model = ReviewTargetPaletteModel()
        model.open()
        let w = worktree("feature")
        let env = environment(worktrees: [w], commits: [commit("a1", "one"), commit("b2", "two")])
        await model.loadWorktreeMetrics(environment: env)
        #expect(model.aheadCounts[w.id] == 2)
        #expect(model.comparisonRefs[w.id] == "origin/main")
    }

    @Test func enterOnWorktreeWithCommitsLaunchesFullRangePinnedToSHAs() async {
        let model = ReviewTargetPaletteModel()
        model.open()
        let w = worktree("feature")
        var opened: (ReviewSessionTarget, Worktree)?
        let env = environment(
            worktrees: [w],
            commits: [commit("a1", "one")],
            onOpen: { opened = ($0, $1) }
        )
        await model.loadWorktreeMetrics(environment: env)
        await model.activateSelection(environment: env)
        let (target, host) = try! #require(opened)
        #expect(host.id == w.id)
        #expect(target.kind == .branch)
        #expect(target.payload == .branch(base: "resolved-origin/main", head: "head-sha"))
    }

    @Test func enterOnWorktreeWithoutMetricsDrillsIn() async {
        let model = ReviewTargetPaletteModel()
        model.open()
        let w = worktree("feature")
        var opened = false
        let env = environment(worktrees: [w], onOpen: { _, _ in opened = true })
        // No loadWorktreeMetrics call: aheadCount unknown.
        await model.activateSelection(environment: env)
        #expect(!opened)
        #expect(model.level == .targets(w))
    }

    @Test func enterOnWorktreeWithZeroAheadDrillsIn() async {
        let model = ReviewTargetPaletteModel()
        model.open()
        let w = worktree("feature")
        var opened = false
        let env = environment(worktrees: [w], commits: [], onOpen: { _, _ in opened = true })
        await model.loadWorktreeMetrics(environment: env)
        await model.activateSelection(environment: env)
        #expect(!opened)
        #expect(model.level == .targets(w))
    }

    @Test func targetRowsListCommitsThenBranchesWithHeaders() async {
        let model = ReviewTargetPaletteModel()
        model.open(prefill: worktree("feature"))
        let env = environment(commits: [commit("a1", "one")], branches: ["main", "dev"])
        await model.loadTargets(environment: env)
        let rows = model.targetRows()
        #expect(rows == [
            .header("Commits"),
            .commit(commit("a1", "one")),
            .header("Branches"),
            .branch("main"),
            .branch("dev"),
        ])
        #expect(!rows[0].isSelectable)
        #expect(rows[1].isSelectable)
    }

    @Test func filteringAtTargetLevelSnapsSelectionPastTheHeaderSoEnterFiresImmediately() async {
        let model = ReviewTargetPaletteModel()
        let w = worktree("feature")
        model.open(prefill: w)
        var opened: ReviewSessionTarget?
        let env = environment(
            commits: [commit("a1a1a1a1", "fix login"), commit("b2b2b2b2", "add export")],
            onOpen: { t, _ in opened = t }
        )
        await model.loadTargets(environment: env)
        model.query = "export"
        #expect(model.targetRows() == [.header("Commits"), .commit(commit("b2b2b2b2", "add export"))])
        #expect(model.selectedIndex == 1)
        await model.activateSelection(environment: env)
        #expect(opened?.kind == .commit)
        #expect(opened?.payload == .commit(sha: "b2b2b2b2"))
    }

    @Test func enterOnCommitLaunchesSingleCommitReview() async {
        let model = ReviewTargetPaletteModel()
        let w = worktree("feature")
        model.open(prefill: w)
        var opened: ReviewSessionTarget?
        let env = environment(commits: [commit("a1a1a1a1", "one")], branches: [], onOpen: { t, _ in opened = t })
        await model.loadTargets(environment: env)
        model.setSelectedIndex(1, selectable: model.targetRows().map(\.isSelectable))
        await model.activateSelection(environment: env)
        #expect(opened?.kind == .commit)
        #expect(opened?.payload == .commit(sha: "a1a1a1a1"))
    }

    @Test func anchorPlusSecondCommitLaunchesOrderedRange() async {
        let model = ReviewTargetPaletteModel()
        let w = worktree("feature")
        model.open(prefill: w)
        // Newest first, git log order.
        let newest = commit("ccc3", "third")
        let middle = commit("bbb2", "second")
        let oldest = commit("aaa1", "first")
        var opened: ReviewSessionTarget?
        let env = environment(commits: [newest, middle, oldest], onOpen: { t, _ in opened = t })
        await model.loadTargets(environment: env)
        model.toggleAnchor(oldest)
        // Select the newest commit row (index 1: header at 0).
        model.setSelectedIndex(1, selectable: model.targetRows().map(\.isSelectable))
        await model.activateSelection(environment: env)
        #expect(opened?.kind == .commitRange)
        #expect(opened?.payload == .commitRange(base: "aaa1^", head: "ccc3"))
    }

    @Test func shiftDownAnchorsCurrentCommitAndLaunchesOrderedRange() async {
        let model = ReviewTargetPaletteModel()
        let w = worktree("feature")
        model.open(prefill: w)
        // Newest first, git log order.
        let newest = commit("ccc3", "third")
        let middle = commit("bbb2", "second")
        let oldest = commit("aaa1", "first")
        var opened: ReviewSessionTarget?
        let env = environment(commits: [newest, middle, oldest], onOpen: { t, _ in opened = t })
        await model.loadTargets(environment: env)

        #expect(model.selectedIndex == 1)
        #expect(model.extendCommitRangeSelection(step: 1))
        #expect(model.rangeAnchor == newest)
        #expect(model.selectedIndex == 2)

        await model.activateSelection(environment: env)
        #expect(opened?.kind == .commitRange)
        #expect(opened?.payload == .commitRange(base: "bbb2^", head: "ccc3"))
    }

    @Test func repeatedShiftDownKeepsOriginalAnchorAndExtendsRange() async {
        let model = ReviewTargetPaletteModel()
        let w = worktree("feature")
        model.open(prefill: w)
        // Newest first, git log order.
        let newest = commit("ccc3", "third")
        let middle = commit("bbb2", "second")
        let oldest = commit("aaa1", "first")
        var opened: ReviewSessionTarget?
        let env = environment(commits: [newest, middle, oldest], onOpen: { t, _ in opened = t })
        await model.loadTargets(environment: env)

        #expect(model.extendCommitRangeSelection(step: 1))
        #expect(model.extendCommitRangeSelection(step: 1))
        #expect(model.rangeAnchor == newest)
        #expect(model.selectedIndex == 3)

        await model.activateSelection(environment: env)
        #expect(opened?.kind == .commitRange)
        #expect(opened?.payload == .commitRange(base: "aaa1^", head: "ccc3"))
    }

    @Test func shiftDownFromLastCommitDoesNotMoveIntoBranchRows() async {
        let model = ReviewTargetPaletteModel()
        let w = worktree("feature")
        model.open(prefill: w)
        let only = commit("aaa1", "first")
        let env = environment(commits: [only], branches: ["main"])
        await model.loadTargets(environment: env)

        #expect(model.selectedIndex == 1)
        #expect(model.extendCommitRangeSelection(step: 1))
        #expect(model.selectedIndex == 1)
        #expect(model.rangeAnchor == nil)
    }

    @Test func enterOnBranchLaunchesPinnedBranchReview() async {
        let model = ReviewTargetPaletteModel()
        model.open(prefill: worktree("feature"))
        var opened: ReviewSessionTarget?
        let env = environment(commits: [], branches: ["main"], onOpen: { t, _ in opened = t })
        await model.loadTargets(environment: env)
        let selectable = model.targetRows().map(\.isSelectable)
        // Rows: header Commits, message(no commits), header Branches, branch(main)
        model.setSelectedIndex(3, selectable: selectable)
        await model.activateSelection(environment: env)
        #expect(opened?.kind == .branch)
        #expect(opened?.payload == .branch(base: "resolved-main", head: "head-sha"))
    }

    @Test func backReturnsToWorktreesAndResetsQueryAndAnchor() {
        let model = ReviewTargetPaletteModel()
        model.open()
        let w = worktree("feature")
        let env = environment(worktrees: [w])
        model.drillIntoSelectedWorktree(environment: env)
        model.query = "abc"
        model.toggleAnchor(commit("a1", "one"))
        #expect(model.back())
        #expect(model.level == .worktrees)
        #expect(model.query.isEmpty)
        #expect(model.rangeAnchor == nil)
    }

    @Test func backFromPrefilledLevelClosesInstead() {
        let model = ReviewTargetPaletteModel()
        model.open(prefill: worktree("feature"))
        #expect(!model.back())
    }

    @Test func loadTargetsSurfacesErrors() async {
        let model = ReviewTargetPaletteModel()
        model.open(prefill: worktree("feature"))
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        var env = environment()
        env.loadCommitsAhead = { _ in throw Boom() }
        await model.loadTargets(environment: env)
        #expect(model.targetRows() == [.message("Could not load commits: boom")])
    }
}
