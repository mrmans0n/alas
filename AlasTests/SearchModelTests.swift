import Testing
import Foundation
@testable import Alas

@MainActor
struct SearchModelTests {
    @Test func contentSearchHitRevealTargetUsesZeroBasedEditorCoordinates() {
        let hit = ContentSearchHit(
            worktreeId: "wt",
            projectId: "project",
            relativePath: "Sources/App.swift",
            line: 12,
            column: 4,
            revealColumn: nil,
            snippet: "    let value = true",
            matchCharRange: nil
        )

        #expect(hit.revealLine == 11)
        #expect(hit.revealCharacter == 3)
    }

    @Test func contentSearchHitRevealTargetUsesUtf16RevealColumnWhenAvailable() {
        let hit = ContentSearchHit(
            worktreeId: "wt",
            projectId: "project",
            relativePath: "Sources/App.swift",
            line: 1,
            column: 2,
            revealColumn: 3,
            snippet: "😀needle",
            matchCharRange: nil
        )

        #expect(hit.column == 2)
        #expect(hit.revealCharacter == 2)
    }

    @Test func contentSearchHitRevealTargetClampsInvalidCoordinatesToFileStart() {
        let hit = ContentSearchHit(
            worktreeId: "wt",
            projectId: "project",
            relativePath: "Sources/App.swift",
            line: 0,
            column: 0,
            revealColumn: nil,
            snippet: "",
            matchCharRange: nil
        )

        #expect(hit.revealLine == 0)
        #expect(hit.revealCharacter == 0)
    }

    @Test func searchWorktreeCacheKeyIncludesPinnedSSHHost() {
        let path = URL(fileURLWithPath: "/repos/shared")
        let first = SearchWorktree(
            id: "a",
            projectId: "project-a",
            displayName: "A",
            absolutePath: path,
            executionLocation: .ssh("build-a")
        )
        let second = SearchWorktree(
            id: "b",
            projectId: "project-b",
            displayName: "B",
            absolutePath: path,
            executionLocation: .ssh("build-b")
        )

        #expect(first.remoteHost == "build-a")
        #expect(second.remoteHost == "build-b")
        #expect(first.cacheKey != second.cacheKey)
    }

    /// Returns a finished AsyncThrowingStream with no elements.
    private func emptyContentStream() -> AsyncThrowingStream<ContentSearchHit, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    private func makeEnv(
        worktrees: [SearchWorktree] = [],
        files: [String: [FileIndex.Entry]] = [:],
        statuses: [String: [String: GitStatusBadge]] = [:],
        entries: (@Sendable (SearchWorktree) async throws -> [FileIndex.Entry])? = nil,
        fileSearch: (@Sendable (String, SearchWorktree) async throws -> [FileSearchBackendResult]?)? = nil,
        rankFiles: (@Sendable (String, [FileSearchRankingSource]) async throws -> [FileSearchResult])? = nil,
        contentSearch: (@Sendable (String, SearchContentOptions, [SearchWorktree]) -> AsyncThrowingStream<ContentSearchHit, Error>)? = nil,
        workspaceCheckoutWorktrees: (@Sendable () -> [SearchWorktree])? = nil
    ) -> SearchEnvironment {
        let ranker = FileSearchRanker()
        return SearchEnvironment(
            currentWorktreeId: { worktrees.first?.id },
            allWorktrees: { worktrees },
            entries: entries ?? { wt in files[wt.id] ?? [] },
            statuses: { wt in statuses[wt.id] ?? [:] },
            workspaceCheckoutWorktrees: workspaceCheckoutWorktrees ?? { [] },
            fileSearch: fileSearch ?? { _, _ in nil },
            rankFiles: rankFiles ?? { query, sources in
                try await ranker.rank(query: query, sources: sources)
            },
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
            workspaceCheckoutWorktrees: { [] },
            fileSearch: { _, _ in nil },
            rankFiles: { [ranker = FileSearchRanker()] query, sources in
                try await ranker.rank(query: query, sources: sources)
            },
            contentSearch: { _, _, _ in AsyncThrowingStream { $0.finish() } }
        )
        let model2 = SearchModel(environment: env)
        model2.open()
        #expect(model2.scope == .allRepos)
    }

    @Test func openPrefersWorkspaceCheckoutScopeWhenCheckoutMembersAreAvailable() async {
        let member = wt("member", projectId: "p1")
        let env = makeEnv(
            worktrees: [wt("focused", projectId: "p2")],
            workspaceCheckoutWorktrees: { [member] }
        )
        let model = SearchModel(environment: env)

        model.open()

        #expect(model.scope == .workspaceCheckout)
    }

    @Test func workspaceCheckoutScopeSearchesOnlyExplicitCheckoutMembersAndReportsPartialFailures() async {
        let member = wt("member", projectId: "p1")
        let outside = wt("outside", projectId: "p2")
        let env = makeEnv(
            worktrees: [member, outside],
            entries: { wt in
                if wt.id == "member" { throw CocoaError(.fileReadUnknown) }
                return [.init(relativePath: "outside.swift", ext: "swift")]
            },
            rankFiles: { _, sources in
                sources.flatMap { source in
                    source.entries.map {
                        FileSearchResult(
                            worktreeId: source.worktreeId,
                            projectId: source.projectId,
                            relativePath: $0.relativePath,
                            ext: $0.ext,
                            statusBadge: nil,
                            matchIndices: [],
                            score: 1
                        )
                    }
                }
            },
            workspaceCheckoutWorktrees: { [member] }
        )
        let model = SearchModel(environment: env)
        model.open()
        model.scope = SearchScope.workspaceCheckout
        model.query = "swift"
        await model.waitForIdle()

        #expect(model.results.fileResults.isEmpty)
        #expect(model.results.partialFailureMessage == "Couldn't read files for wt-member")
    }

    @Test func workspaceCheckoutFileResultsCarryMemberIdentity() async {
        let memberID = UUID()
        var member = wt("member", projectId: "p1")
        member.workspaceCheckoutMemberID = memberID
        let env = makeEnv(
            files: ["member": [.init(relativePath: "Sources/App.swift", ext: "swift")]],
            workspaceCheckoutWorktrees: { [member] }
        )
        let model = SearchModel(environment: env)
        model.open()
        model.scope = .workspaceCheckout
        model.query = "App"
        await model.waitForIdle()

        #expect(model.results.fileResults.first?.workspaceCheckoutMemberID == memberID)
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

    @Test func fileSearchUsesBackendResultsWhenAvailable() async {
        let env = makeEnv(
            worktrees: [wt("a")],
            files: ["a": [
                .init(relativePath: "fallback_only.rs", ext: "rs"),
            ]],
            statuses: ["a": [
                "src/backend_result.swift": .modified,
            ]],
            fileSearch: { query, _ in
                guard query == "backend" else { return nil }
                return [
                    FileSearchBackendResult(
                        relativePath: "src/backend_result.swift",
                        score: 42,
                        matchIndices: [4, 5, 6]
                    ),
                ]
            }
        )
        let model = SearchModel(environment: env)
        model.open()
        model.query = "backend"
        await model.waitForIdle()

        #expect(model.results.fileResults.map(\.relativePath) == ["src/backend_result.swift"])
        #expect(model.results.fileResults.first?.statusBadge == .modified)
        #expect(model.results.fileResults.first?.score == 44)
        #expect(model.results.fileResults.first?.matchIndices == [4, 5, 6])
    }

    @Test func fileSearchPreservesBackendResultsWhenEntryEnumerationFails() async {
        let env = makeEnv(
            worktrees: [wt("a")],
            entries: { _ in throw CocoaError(.fileReadUnknown) },
            fileSearch: { _, _ in
                [FileSearchBackendResult(
                    relativePath: "src/backend_result.swift",
                    score: 42,
                    matchIndices: [4, 5, 6]
                )]
            }
        )
        let model = SearchModel(environment: env)
        model.open()
        model.query = "backend"
        await model.waitForIdle()

        #expect(model.results.fileResults.map(\.relativePath) == ["src/backend_result.swift"])
        #expect(model.results.partialFailureMessage == "Couldn't read files for wt-a")
    }

    @Test func fileSearchMergesDeletedFallbackRowsWithBackendResults() async {
        let env = makeEnv(
            worktrees: [wt("a")],
            files: ["a": [
                .init(relativePath: "old_file.swift", ext: "swift"),
                .init(relativePath: "other_file.swift", ext: "swift"),
            ]],
            statuses: ["a": [
                "old_file.swift": .deleted,
                "other_file.swift": .modified,
            ]],
            fileSearch: { query, _ in
                guard query == "old" else { return nil }
                return []
            }
        )
        let model = SearchModel(environment: env)
        model.open()
        model.query = "old"
        await model.waitForIdle()

        #expect(model.results.fileResults.map(\.relativePath) == ["old_file.swift"])
        #expect(model.results.fileResults.first?.statusBadge == .deleted)
    }

    @Test func fileSearchMergesTrackedFallbackRowsOmittedByBackend() async {
        let env = makeEnv(
            worktrees: [wt("a")],
            files: ["a": [
                .init(relativePath: "ignored/tracked_file.swift", ext: "swift"),
                .init(relativePath: "src/other_file.swift", ext: "swift"),
            ]],
            fileSearch: { query, _ in
                guard query == "tracked" else { return nil }
                return []
            }
        )
        let model = SearchModel(environment: env)
        model.open()
        model.query = "tracked"
        await model.waitForIdle()

        #expect(model.results.fileResults.map(\.relativePath) == ["ignored/tracked_file.swift"])
        #expect(model.results.fileResults.first?.statusBadge == nil)
    }

    @Test func fileSearchFallsBackWhenBackendIsNotReady() async {
        let env = makeEnv(
            worktrees: [wt("a")],
            files: ["a": [
                .init(relativePath: "src/fallback_result.swift", ext: "swift"),
            ]],
            fileSearch: { _, _ in nil }
        )
        let model = SearchModel(environment: env)
        model.open()
        model.query = "fallback"
        await model.waitForIdle()

        #expect(model.results.fileResults.map(\.relativePath) == ["src/fallback_result.swift"])
    }

    @Test func fileSearchKeepsSingleCharacterQueryOnSwiftScorer() async {
        let env = makeEnv(
            worktrees: [wt("a")],
            files: ["a": [
                .init(relativePath: "src/apple.swift", ext: "swift"),
                .init(relativePath: "src/zoom.swift", ext: "swift"),
            ]],
            fileSearch: { _, _ in [
                FileSearchBackendResult(
                    relativePath: "src/backend_result.swift",
                    score: 100,
                    matchIndices: []
                ),
            ] }
        )
        let model = SearchModel(environment: env)
        model.open()
        model.query = "a"
        await model.waitForIdle()

        #expect(model.results.fileResults.map(\.relativePath) == ["src/apple.swift"])
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
                revealColumn: nil,
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
                line: 1, column: 1, revealColumn: nil,
                snippet: "x", matchCharRange: nil
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
                line: i + 1, column: 1, revealColumn: nil,
                snippet: "x", matchCharRange: nil
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
            revealColumn: nil, snippet: "match", matchCharRange: nil
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

    @Test func staleFileRankingCannotPublishOrClearSuccessorLoading() async throws {
        let gate = RankGate()
        let ranker = FileSearchRanker()
        let env = makeEnv(
            worktrees: [wt("a")],
            files: ["a": [
                .init(relativePath: "old.swift", ext: "swift"),
                .init(relativePath: "new.swift", ext: "swift"),
            ]],
            rankFiles: { query, sources in
                guard query == "old" || query == "new" else {
                    return try await ranker.rank(query: query, sources: sources)
                }
                return try await gate.rank(query: query)
            }
        )
        let model = SearchModel(environment: env)
        model.open()
        await model.waitForIdle()

        model.query = "old"
        await gate.waitUntilStarted(query: "old")
        model.query = "new"
        await gate.waitUntilStarted(query: "new")

        await gate.release(query: "old", results: [fileResult(path: "old.swift")])
        await drainMainActor()
        #expect(model.isLoading)
        #expect(model.results.fileResults.map(\.relativePath) != ["old.swift"])

        await gate.release(query: "new", results: [fileResult(path: "new.swift")])
        await model.waitForIdle()
        #expect(model.results.fileResults.map(\.relativePath) == ["new.swift"])
        #expect(!model.isLoading)
    }

    @Test func staleContentPartialAndErrorCannotOverwriteCompletedSuccessor() async {
        let streams = ContentStreamGate()
        let env = makeEnv(
            worktrees: [wt("a")],
            contentSearch: { query, _, _ in streams.stream(for: query) }
        )
        let model = SearchModel(environment: env)
        model.open()
        await model.waitForIdle()
        model.kind = .content
        model.query = "old"
        await streams.waitUntilStarted(query: "old")

        await streams.yield(
            query: "old",
            hits: (0..<25).map { contentHit(path: "old.swift", line: $0 + 1) }
        )
        await waitUntil { model.results.contentGroups.first?.relativePath == "old.swift" }

        model.query = "new"
        await streams.waitUntilStarted(query: "new")
        await streams.yield(query: "new", hits: [contentHit(path: "new.swift", line: 1)])
        await streams.finish(query: "new")
        await model.waitForIdle()
        #expect(model.results.contentGroups.map(\.relativePath) == ["new.swift"])
        #expect(model.results.partialFailureMessage == nil)

        await streams.finish(
            query: "old",
            throwing: ContentSearcher.SearchError.rgFailed(exitCode: 2)
        )
        await drainMainActor()
        #expect(model.results.contentGroups.map(\.relativePath) == ["new.swift"])
        #expect(model.results.partialFailureMessage == nil)
    }

    @Test func closeInvalidatesActiveSearchAndReleasesIdleWaiters() async {
        let gate = RankGate()
        let ranker = FileSearchRanker()
        let env = makeEnv(
            worktrees: [wt("a")],
            files: ["a": [.init(relativePath: "active.swift", ext: "swift")]],
            rankFiles: { query, sources in
                guard query == "active" else {
                    return try await ranker.rank(query: query, sources: sources)
                }
                return try await gate.rank(query: query)
            }
        )
        let model = SearchModel(environment: env)
        model.open()
        await model.waitForIdle()
        model.query = "active"
        await gate.waitUntilStarted(query: "active")
        #expect(model.isLoading)

        let idleWaiter = Task { @MainActor in await model.waitForIdle() }
        model.close()
        await idleWaiter.value

        #expect(!model.isOpen)
        #expect(!model.isLoading)
        #expect(model.query.isEmpty)
        #expect(model.results == SearchResults())

        await gate.release(query: "active", results: [fileResult(path: "active.swift")])
        await drainMainActor()
        #expect(model.results == SearchResults())
        #expect(!model.isLoading)
    }

    private func fileResult(path: String) -> FileSearchResult {
        FileSearchResult(
            worktreeId: "a",
            projectId: "p1",
            relativePath: path,
            ext: "swift",
            statusBadge: nil,
            matchIndices: [],
            score: 1
        )
    }

    private func contentHit(path: String, line: Int) -> ContentSearchHit {
        ContentSearchHit(
            worktreeId: "a",
            projectId: "p1",
            relativePath: path,
            line: line,
            column: 1,
            revealColumn: nil,
            snippet: "match",
            matchCharRange: nil
        )
    }

    private func drainMainActor() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        while !predicate() { await Task.yield() }
    }
}

/// Test helper used by `invalidRegexIsCaughtBeforeBackendRuns` to flag
/// whether the contentSearch closure was invoked.
private actor InvocationFlag {
    private var invoked = false
    func set() { invoked = true }
    var value: Bool { invoked }
}

private actor RankGate {
    private var startedQueries: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var rankWaiters: [String: CheckedContinuation<[FileSearchResult], Error>] = [:]

    func rank(query: String) async throws -> [FileSearchResult] {
        startedQueries.insert(query)
        let waiters = startWaiters.removeValue(forKey: query) ?? []
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            rankWaiters[query] = continuation
        }
    }

    func waitUntilStarted(query: String) async {
        guard !startedQueries.contains(query) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[query, default: []].append(continuation)
        }
    }

    func release(query: String, results: [FileSearchResult]) {
        rankWaiters.removeValue(forKey: query)?.resume(returning: results)
    }
}

private actor ContentStreamGate {
    private var continuations: [String: AsyncThrowingStream<ContentSearchHit, Error>.Continuation] = [:]
    private var startedQueries: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    nonisolated func stream(for query: String) -> AsyncThrowingStream<ContentSearchHit, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.register(continuation, for: query) }
        }
    }

    func waitUntilStarted(query: String) async {
        guard !startedQueries.contains(query) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[query, default: []].append(continuation)
        }
    }

    func yield(query: String, hits: [ContentSearchHit]) {
        guard let continuation = continuations[query] else { return }
        for hit in hits { continuation.yield(hit) }
    }

    func finish(query: String, throwing error: Error? = nil) {
        guard let continuation = continuations.removeValue(forKey: query) else { return }
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private func register(
        _ continuation: AsyncThrowingStream<ContentSearchHit, Error>.Continuation,
        for query: String
    ) {
        continuations[query] = continuation
        startedQueries.insert(query)
        let waiters = startWaiters.removeValue(forKey: query) ?? []
        waiters.forEach { $0.resume() }
    }
}
