import Testing
import Foundation
@testable import Alas

@MainActor
struct SearchModelTests {
    private func makeEnv(
        worktrees: [SearchWorktree] = [],
        files: [String: [FileIndex.Entry]] = [:],
        statuses: [String: [String: GitStatusBadge]] = [:]
    ) -> SearchEnvironment {
        SearchEnvironment(
            currentWorktreeId: { worktrees.first?.id },
            allWorktrees: { worktrees },
            entries: { wt in files[wt.id] ?? [] },
            statuses: { wt in statuses[wt.id] ?? [:] }
        )
    }

    private func wt(_ id: String, projectId: String = "p1") -> SearchWorktree {
        SearchWorktree(
            id: id,
            projectId: projectId,
            displayName: "wt-\(id)",
            absolutePath: URL(fileURLWithPath: "/tmp/\(id)")
        )
    }

    @Test func openSeedsScopeFromCurrentWorktree() async {
        var env = makeEnv(worktrees: [wt("a")])
        let model = SearchModel(environment: env)
        model.open()
        #expect(model.scope == .thisWorktree)
        #expect(model.kind == .files)
        #expect(model.query == "")

        env = SearchEnvironment(
            currentWorktreeId: { nil },
            allWorktrees: { [] },
            entries: { _ in [] },
            statuses: { _ in [:] }
        )
        let model2 = SearchModel(environment: env)
        model2.open()
        #expect(model2.scope == .allRepos)
    }

    @Test func emptyQueryInFilesModeShowsAllInThisWorktree() async {
        let env = makeEnv(
            worktrees: [wt("a")],
            files: ["a": [
                .init(relativePath: "src/main.rs", ext: "rs"),
                .init(relativePath: "README.md",  ext: "md"),
            ]]
        )
        let model = SearchModel(environment: env)
        model.open()
        await model.waitForIdle()
        #expect(model.results.fileResults.map(\.relativePath).sorted() == ["README.md", "src/main.rs"])
    }

    @Test func fuzzyQueryFiltersAndSortsByScore() async {
        let env = makeEnv(
            worktrees: [wt("a")],
            files: ["a": [
                .init(relativePath: "tab_bar.rs",  ext: "rs"),
                .init(relativePath: "tab_drag.rs", ext: "rs"),
                .init(relativePath: "main.rs",     ext: "rs"),
            ]]
        )
        let model = SearchModel(environment: env)
        model.open()
        model.query = "tab"
        await model.waitForIdle()
        let paths = model.results.fileResults.map(\.relativePath)
        #expect(paths.contains("tab_bar.rs"))
        #expect(paths.contains("tab_drag.rs"))
        #expect(!paths.contains("main.rs"))
    }

    @Test func selectionClampsOnResultShrink() async {
        let env = makeEnv(
            worktrees: [wt("a")],
            files: ["a": (0..<10).map {
                FileIndex.Entry(relativePath: "f\($0).rs", ext: "rs")
            }]
        )
        let model = SearchModel(environment: env)
        model.open()
        await model.waitForIdle()
        model.selectedIndex = 7
        model.query = "f1"  // matches f1, f10..f19 — but only f1 exists; ~1 result.
        await model.waitForIdle()
        #expect(model.selectedIndex < model.totalResultRows)
    }

    @Test func contentPrefixFlipsKindToContent() async {
        let env = makeEnv(worktrees: [wt("a")])
        let model = SearchModel(environment: env)
        model.open()
        model.query = "> foo"
        #expect(model.kind == .content)
        #expect(model.trimmedQuery == "foo")
    }

    @Test func toggleKindSwapsModeWithoutTouchingQuery() async {
        let env = makeEnv(worktrees: [wt("a")])
        let model = SearchModel(environment: env)
        model.open()
        model.query = "abc"
        model.toggleKind()
        #expect(model.kind == .content)
        #expect(model.query == "abc")
        model.toggleKind()
        #expect(model.kind == .files)
    }

    @Test func allReposScopeUnionsAcrossWorktrees() async {
        let env = makeEnv(
            worktrees: [wt("a"), wt("b", projectId: "p2")],
            files: [
                "a": [.init(relativePath: "x.rs", ext: "rs")],
                "b": [.init(relativePath: "y.rs", ext: "rs")],
            ]
        )
        let model = SearchModel(environment: env)
        model.open()
        model.scope = .allRepos
        await model.waitForIdle()
        let paths = Set(model.results.fileResults.map(\.relativePath))
        #expect(paths == ["x.rs", "y.rs"])
    }

    @Test func resetClearsStateOnOpen() async {
        let env = makeEnv(
            worktrees: [wt("a")],
            files: ["a": [.init(relativePath: "x.rs", ext: "rs")]]
        )
        let model = SearchModel(environment: env)
        model.open()
        model.query = "x"
        model.kind = .content
        model.selectedIndex = 0
        model.open()
        #expect(model.query == "")
        #expect(model.kind == .files)
        #expect(model.selectedIndex == 0)
    }

    @Test func waitForIdleReturnsImmediatelyWhenNothingScheduled() async {
        let env = makeEnv(worktrees: [wt("a")])
        let model = SearchModel(environment: env)
        // No open() / no query change → no task scheduled.
        // Should return ~immediately, not deadlock.
        let started = Date()
        await model.waitForIdle()
        #expect(Date().timeIntervalSince(started) < 0.1)
    }

    @Test func waitForIdleAfterCompletedSearchDoesNotDeadlock() async {
        let env = makeEnv(
            worktrees: [wt("a")],
            files: ["a": [.init(relativePath: "x.rs", ext: "rs")]]
        )
        let model = SearchModel(environment: env)
        model.open()
        await model.waitForIdle()      // first wait — completes
        let started = Date()
        await model.waitForIdle()      // second wait — must not park
        #expect(Date().timeIntervalSince(started) < 0.1)
    }
}
