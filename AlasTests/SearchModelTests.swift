import Testing
import Foundation
@testable import Alas

@MainActor
struct SearchModelTests {
    /// Returns a finished AsyncThrowingStream with no elements.
    private func emptyContentStream() -> AsyncThrowingStream<ContentSearchHit, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    private func makeEnv(
        worktrees: [SearchWorktree] = [],
        files: [String: [FileIndex.Entry]] = [:],
        statuses: [String: [String: GitStatusBadge]] = [:],
        contentSearch: (@Sendable (String, SearchContentOptions, [SearchWorktree]) -> AsyncThrowingStream<ContentSearchHit, Error>)? = nil
    ) -> SearchEnvironment {
        SearchEnvironment(
            currentWorktreeId: { worktrees.first?.id },
            allWorktrees: { worktrees },
            entries: { wt in files[wt.id] ?? [] },
            statuses: { wt in statuses[wt.id] ?? [:] },
            contentSearch: contentSearch ?? { _, _, _ in AsyncThrowingStream { $0.finish() } }
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
            statuses: { _ in [:] },
            contentSearch: { _, _, _ in AsyncThrowingStream { $0.finish() } }
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

extension SearchModelTests {
    @Test func contentOptionsPersistAcrossKindToggles() async {
        let env = makeEnv(worktrees: [wt("a")])
        let model = SearchModel(environment: env)
        model.open()
        model.contentOptions.caseSensitive = true
        model.contentOptions.regex = true
        model.toggleKind() // -> content
        model.toggleKind() // -> files
        #expect(model.contentOptions.caseSensitive == true)
        #expect(model.contentOptions.regex == true)
        #expect(model.contentOptions.wholeWord == false)
    }

    @Test func contentPrefixWorksEvenWithStubbedBackend() async {
        let env = makeEnv(worktrees: [wt("a")])
        let model = SearchModel(environment: env)
        model.open()
        model.query = "> needle"
        await model.waitForIdle()
        #expect(model.kind == .content)
        #expect(model.results.contentGroups.isEmpty)
    }

    @Test func contentResultsAreGroupedByFile() async {
        // Two files across the same worktree — accumulation logic under test,
        // not the rg backend.
        let worktree = wt("a")
        func makeHit(path: String, line: Int) -> ContentSearchHit {
            ContentSearchHit(
                worktreeId: "a",
                projectId: "p1",
                relativePath: path,
                line: line,
                column: 1,
                snippet: "some snippet",
                matchCharRange: nil
            )
        }
        let hits: [ContentSearchHit] = [
            makeHit(path: "src/foo.rs", line: 10),
            makeHit(path: "src/bar.rs", line: 5),
            makeHit(path: "src/foo.rs", line: 20),
            makeHit(path: "src/bar.rs", line: 15),
        ]

        let env = makeEnv(
            worktrees: [worktree],
            contentSearch: { _, _, _ in
                AsyncThrowingStream { cont in
                    Task {
                        for h in hits { cont.yield(h) }
                        cont.finish()
                    }
                }
            }
        )
        let model = SearchModel(environment: env)
        model.open()
        model.kind = .content
        model.query = "snippet"
        await model.waitForIdle()

        let groups = model.results.contentGroups
        // Two distinct files → two groups, in encounter order.
        #expect(groups.count == 2)
        #expect(groups[0].relativePath == "src/foo.rs")
        #expect(groups[1].relativePath == "src/bar.rs")
        // Hits within each group in arrival order.
        #expect(groups[0].hits.map(\.line) == [10, 20])
        #expect(groups[1].hits.map(\.line) == [5, 15])
    }

    @Test func contentSearchCapsAtFiftyFiles() async {
        let worktree = wt("a")
        // Yield 60 distinct files (one hit each); cap is 50.
        let hits: [ContentSearchHit] = (0..<60).map { i in
            ContentSearchHit(
                worktreeId: "a", projectId: "p1",
                relativePath: "f\(i).rs",
                line: 1, column: 1, snippet: "x", matchCharRange: nil
            )
        }
        let env = makeEnv(
            worktrees: [worktree],
            contentSearch: { _, _, _ in
                AsyncThrowingStream { cont in
                    Task {
                        for h in hits { cont.yield(h) }
                        cont.finish()
                    }
                }
            }
        )
        let model = SearchModel(environment: env)
        model.open()
        model.kind = .content
        model.query = "x"
        await model.waitForIdle()
        #expect(model.results.contentGroups.count == 50)
        // First 50 distinct files survived; the rest were dropped.
        let surviving = Set(model.results.contentGroups.map(\.relativePath))
        #expect(surviving.contains("f0.rs"))
        #expect(surviving.contains("f49.rs"))
        #expect(!surviving.contains("f50.rs"))
        #expect(!surviving.contains("f59.rs"))
    }

    @Test func contentSearchCapsAtTwoHundredHits() async {
        let worktree = wt("a")
        // Yield 220 hits across two files (way above the 200-hit cap).
        let hits = (0..<220).map { i in
            ContentSearchHit(
                worktreeId: "a", projectId: "p1",
                relativePath: i.isMultiple(of: 2) ? "a.rs" : "b.rs",
                line: i + 1, column: 1, snippet: "x", matchCharRange: nil
            )
        }
        let env = makeEnv(
            worktrees: [worktree],
            contentSearch: { _, _, _ in
                AsyncThrowingStream { cont in
                    for hit in hits { cont.yield(hit) }
                    cont.finish()
                }
            }
        )
        let model = SearchModel(environment: env)
        model.open()
        model.kind = .content
        model.query = "x"
        await model.waitForIdle()
        let totalHits = model.results.contentGroups.reduce(0) { $0 + $1.hits.count }
        #expect(totalHits == 200)
    }

    @Test func invalidRegexIsCaughtBeforeBackendRuns() async {
        // Validation is now up-front via NSRegularExpression — the backend
        // closure should never be invoked for an unparseable pattern.
        let backendInvoked = InvocationFlag()
        let env = makeEnv(
            worktrees: [wt("a")],
            contentSearch: { _, _, _ in
                Task { await backendInvoked.set() }
                return AsyncThrowingStream { $0.finish() }
            }
        )
        let model = SearchModel(environment: env)
        model.open()
        model.kind = .content
        model.contentOptions.regex = true
        model.query = "["  // unparseable
        await model.waitForIdle()
        #expect(model.results.contentGroups.isEmpty)
        #expect(model.results.partialFailureMessage == "Invalid regex pattern.")
        #expect(await backendInvoked.value == false)
    }

    @Test func backendRegexInvalidSurfacesInvalidPatternBanner() async {
        // For patterns NSRegularExpression accepts but rg rejects (look-around,
        // backrefs), rg's stderr-detected regex error throws regexInvalid —
        // model should label it as a regex error, not as a generic failure.
        let env = makeEnv(
            worktrees: [wt("a")],
            contentSearch: { _, _, _ in
                AsyncThrowingStream { cont in
                    cont.finish(throwing: ContentSearcher.SearchError.regexInvalid)
                }
            }
        )
        let model = SearchModel(environment: env)
        model.open()
        model.kind = .content
        model.contentOptions.regex = true
        // Look-around — NSRegular accepts, rg's default rejects.
        model.query = "(?=needle)"
        await model.waitForIdle()
        #expect(model.results.contentGroups.isEmpty)
        #expect(model.results.partialFailureMessage == "Invalid regex pattern.")
    }

    @Test func validRegexProceedsToBackendAndReportsSoftFailureGenerically() async {
        // A valid regex that nevertheless trips rg's exit 2 (e.g. unreadable
        // file) must not be mislabeled as an invalid pattern — that was the
        // PR 37 round-7 finding.
        let env = makeEnv(
            worktrees: [wt("a")],
            contentSearch: { _, _, _ in
                AsyncThrowingStream { cont in
                    cont.finish(throwing: ContentSearcher.SearchError.rgFailed(exitCode: 2))
                }
            }
        )
        let model = SearchModel(environment: env)
        model.open()
        model.kind = .content
        model.contentOptions.regex = true
        model.query = "^needle$"  // valid regex
        await model.waitForIdle()
        #expect(model.results.contentGroups.isEmpty)
        #expect(model.results.partialFailureMessage == "Content search failed.")
    }

    @Test func rgFailedInLiteralModeWithNoHitsSaysGenericFailure() async {
        let env = makeEnv(
            worktrees: [wt("a")],
            contentSearch: { _, _, _ in
                AsyncThrowingStream { cont in
                    cont.finish(throwing: ContentSearcher.SearchError.rgFailed(exitCode: 2))
                }
            }
        )
        let model = SearchModel(environment: env)
        model.open()
        model.kind = .content
        // regex toggle off — exit 2 here is a soft I/O error, not a regex syntax error.
        model.query = "needle"
        await model.waitForIdle()
        #expect(model.results.contentGroups.isEmpty)
        #expect(model.results.partialFailureMessage == "Content search failed.")
    }

    @Test func rgFailedAfterPartialResultsPreservesGroupsWithSoftBanner() async {
        let hit = ContentSearchHit(
            worktreeId: "a", projectId: "p1",
            relativePath: "x.rs", line: 1, column: 1,
            snippet: "match", matchCharRange: nil
        )
        let env = makeEnv(
            worktrees: [wt("a")],
            contentSearch: { _, _, _ in
                AsyncThrowingStream { cont in
                    Task {
                        cont.yield(hit)
                        cont.finish(throwing: ContentSearcher.SearchError.rgFailed(exitCode: 2))
                    }
                }
            }
        )
        let model = SearchModel(environment: env)
        model.open()
        model.kind = .content
        model.query = "match"
        await model.waitForIdle()
        // The earlier hit must survive — Codex's regression scenario was
        // that a soft I/O error wiped accumulated groups from earlier files.
        #expect(model.results.contentGroups.count == 1)
        #expect(model.results.partialFailureMessage == "Some files couldn't be searched.")
    }
}

/// Test helper used by `invalidRegexIsCaughtBeforeBackendRuns` to flag
/// whether the contentSearch closure was invoked.
private actor InvocationFlag {
    private var invoked = false
    func set() { invoked = true }
    var value: Bool { invoked }
}
