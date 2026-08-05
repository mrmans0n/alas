import Foundation
import Testing
@testable import Alas

@Suite("Review session loader")
struct ReviewSessionLoaderTests {
    @MainActor
    @Test func productionLoaderLoadsLocalChangesFromWorktree() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-review-session-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)

        let worktree = Worktree(
            id: Worktree.makeId(path: repo),
            projectId: "project-1",
            name: "main",
            branch: "main",
            path: repo,
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 1)
        )
        let target = ReviewSessionTarget.localChanges(
            worktreeID: worktree.id,
            repositoryPath: repo,
            scope: .all
        )
        let loader = ReviewSessionLoader.production(
            appState: AppState(store: MemoryStore()),
            worktree: worktree
        )

        let loaded = try await loader.load(target: target)
        let draftCommitTarget = ReviewSessionTarget.draftCommit(
            worktreeID: worktree.id,
            repositoryPath: repo
        )
        let draftCommitLoaded = try await loader.load(target: draftCommitTarget)

        #expect(loaded.session.files.isEmpty)
        #expect(loaded.feedbackTarget.title == "Review all changes")
        #expect(draftCommitLoaded.session.files.isEmpty)
        #expect(draftCommitLoaded.feedbackTarget.title == "Review draft commit")
    }

    @Test func localChangesLoaderBuildsGroupedSessionAndFeedbackTarget() async throws {
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let loader = ReviewSessionLoader(
            localChanges: { target in
                #expect(target.kind == .localChanges)
                let summary = DiffReviewFileSummary(
                    path: "Sources/A.swift",
                    namespace: "unstaged",
                    groupID: "unstaged",
                    groupTitle: "Unstaged",
                    status: .modified,
                    additions: 1,
                    deletions: 0,
                    isRenderable: true
                )
                return DiffReviewLoadedSession(
                    files: [
                        DiffReviewFileSectionModel(
                            summary: summary,
                            parsedDiff: nil,
                            displayModel: nil,
                            placeholderMessage: nil,
                            openFile: nil,
                            contextProvider: nil
                        ),
                    ],
                    summary: DiffReviewSessionModel(files: [summary], groupsEnabled: true)
                )
            }
        )

        let loaded = try await loader.load(target: target)

        #expect(loaded.session.summary.fileCount == 1)
        #expect(loaded.feedbackTarget.title == "Review all changes")
        #expect(loaded.feedbackTarget.repositoryPath == "/repo")
        #expect(loaded.feedbackTarget.sourceDescription == "Local changes: all")
    }

    @Test func commitLoaderBuildsPinnedSourceDescription() async throws {
        let target = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "deadbeef",
            title: "Review deadbeef"
        )
        let loader = ReviewSessionLoader(
            commit: { target in
                #expect(target.revisionDescription == "deadbeef")
                return DiffReviewLoadedSession(files: [], summary: DiffReviewSessionModel(files: [], groupsEnabled: false))
            }
        )

        let loaded = try await loader.load(target: target)

        #expect(loaded.feedbackTarget.sourceDescription == "Commit deadbeef")
    }

    @Test func trackedCommitLoaderUsesResolvedSHAAndFeedbackDescription() async throws {
        let revision = try #require(TrackedRevision(
            expression: "HEAD~3", baselineBranch: "feature", resolvedSHA: "bbb"
        ))
        let target = ReviewSessionTarget.trackedCommit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            revision: revision,
            title: "Review HEAD~3"
        )
        var loadedPayload: ReviewSessionTarget.Payload?
        let loader = ReviewSessionLoader(
            commit: { target in
                loadedPayload = target.payload
                guard case .trackedCommit(let loadedRevision) = target.payload else {
                    throw ReviewSessionLoaderError.unsupportedTarget
                }
                #expect(loadedRevision.resolvedSHA == "bbb")
                return DiffReviewLoadedSession(files: [], summary: DiffReviewSessionModel(files: [], groupsEnabled: false))
            }
        )

        let loaded = try await loader.load(target: target)

        #expect(loadedPayload == .trackedCommit(revision))
        #expect(loaded.feedbackTarget.sourceDescription == "Commit HEAD~3 -> bbb")
        #expect(loaded.feedbackTarget.revisionDescription == "HEAD~3 -> bbb")
    }

    @MainActor
    @Test func productionLoaderPassesResolvedSHAForTrackedCommit() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-review-session-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["config", "user.email", "test@example.com"], cwd: repo)
        _ = try await Process.git(["config", "user.name", "Test User"], cwd: repo)
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "first"], cwd: repo)
        let sha = try await GitService().resolveRevision(at: repo, ref: "HEAD")
        let worktree = Worktree(
            id: Worktree.makeId(path: repo),
            projectId: "project-1",
            name: "main",
            branch: "main",
            path: repo,
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 1)
        )
        let revision = try #require(TrackedRevision(
            expression: "HEAD", baselineBranch: "main", resolvedSHA: sha
        ))
        let target = ReviewSessionTarget.trackedCommit(
            worktreeID: worktree.id,
            repositoryPath: repo,
            revision: revision,
            title: "Review HEAD"
        )
        let loader = ReviewSessionLoader.production(
            appState: AppState(store: MemoryStore()),
            worktree: worktree
        )

        let loaded = try await loader.load(target: target)

        #expect(loaded.feedbackTarget.revisionDescription == "HEAD -> \(sha)")
    }

    @MainActor
    @Test func productionLoaderLoadsProviderReviewRequestWithProviderContext() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-review-session-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)

        let worktree = Worktree(
            id: Worktree.makeId(path: repo),
            projectId: "project-1",
            name: "main",
            branch: "main",
            path: repo,
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 1)
        )
        let target = ReviewSessionTarget.reviewRequest(
            worktreeID: worktree.id,
            repositoryPath: repo,
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            number: 428,
            url: URL(string: "https://github.com/mrmans0n/alas/pull/428")!,
            title: "Review loop",
            headSHA: "abc123"
        )
        let summary = DiffReviewFileSummary(
            path: "Sources/App.swift",
            namespace: "github-pr",
            groupID: nil,
            groupTitle: nil,
            status: .modified,
            additions: 1,
            deletions: 0,
            isRenderable: true
        )
        let provider = FakeReviewRequestProvider(
            diff: """
            diff --git a/Sources/App.swift b/Sources/App.swift
            index 1111111..2222222 100644
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -1 +1 @@
            -let old = true
            +let new = true
            """
        )
        let loader = ReviewSessionLoader.production(
            appState: AppState(store: MemoryStore()),
            worktree: worktree,
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        let loaded = try await loader.load(target: target)

        #expect(loaded.providerContext?.remote.repositorySlug == "mrmans0n/alas")
        #expect(loaded.providerContext?.reviewRequest.number == 428)
        #expect(loaded.providerContext?.reviewRequest.title == "Provider refreshed title")
        #expect(loaded.providerContext?.reviewRequest.threads.map(\.id) == ["thread-1"])
        #expect(loaded.session.summary.files.map(\.path) == [summary.path])
        #expect(loaded.session.summary.files.map(\.namespace) == [summary.namespace])
    }

    @Test func routesCommitRangeTargetToInjectedLoader() async throws {
        let path = URL(fileURLWithPath: "/tmp/repo")
        let expected = DiffReviewLoadedSession(files: [], summary: DiffReviewSessionModel(files: [], groupsEnabled: false))
        let loader = ReviewSessionLoader(commitRange: { _ in expected })
        let target = ReviewSessionTarget.commitRange(worktreeID: "wt", repositoryPath: path, base: "aaa", head: "bbb")

        let context = try await loader.load(target: target)

        #expect(context.session.files.isEmpty)
    }

    @Test func defaultBranchLoaderThrowsUnsupportedTarget() async throws {
        let path = URL(fileURLWithPath: "/tmp/repo")
        let loader = ReviewSessionLoader()
        let target = ReviewSessionTarget.branch(worktreeID: "wt", repositoryPath: path, base: "main", head: "HEAD")
        await #expect(throws: ReviewSessionLoaderError.unsupportedTarget) {
            _ = try await loader.load(target: target)
        }
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_ value: T, to url: URL) throws {}

        func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
            nil
        }
    }

    private struct FakeReviewRequestProvider: CodeHostProvider {
        let kind: CodeHostKind = .github
        let diff: String

        func isAvailable(cwd: URL) async -> Bool { true }
        func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }
        func currentReviewRequest(
            remote: CodeHostRemote,
            branch: String,
            headOwner: String?,
            baseBranch: String,
            cwd: URL
        ) async throws -> ReviewRequest? {
            nil
        }
        func reviewRequest(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> ReviewRequest {
            ReviewRequest(
                remote: remote,
                number: number,
                title: "Provider refreshed title",
                url: URL(string: "https://github.com/mrmans0n/alas/pull/\(number)")!,
                state: .open,
                isDraft: false,
                headRefName: "feature/provider-review",
                baseRefName: "main",
                reviewDecision: .unknown,
                mergeState: .clean,
                checks: [],
                threads: [
                    ReviewThread(
                        id: "thread-1",
                        path: "Sources/App.swift",
                        line: 1,
                        startLine: nil,
                        originalLine: nil,
                        diffHunk: nil,
                        isResolved: false,
                        isOutdated: false,
                        isFileLevel: false,
                        comments: [
                            ReviewComment(
                                id: "comment-provider-1",
                                author: "reviewer",
                                body: "Please adjust this.",
                                url: URL(string: "https://github.com/mrmans0n/alas/pull/\(number)#discussion_r1"),
                                createdAt: nil,
                                viewerCanUpdate: true,
                                viewerCanDelete: true,
                                isPending: false
                            ),
                        ],
                        viewerCanResolve: true,
                        viewerCanReply: true,
                        url: URL(string: "https://github.com/mrmans0n/alas/pull/\(number)#discussion_r1")
                    ),
                ]
            )
        }
        func createReviewRequest(
            remote: CodeHostRemote,
            branch: String,
            headOwner: String?,
            baseBranch: String,
            title: String,
            body: String,
            isDraft: Bool,
            cwd: URL
        ) async throws -> URL {
            remote.webURL
        }
        func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] { [] }
        func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String { diff }
        func failedCheckEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] { [] }
        func checkEvidenceDetail(
            remote: CodeHostRemote,
            request: ReviewRequest,
            item: ReviewEvidenceItem,
            cwd: URL
        ) async throws -> ReviewEvidenceDetail {
            throw CodeHostProviderError.malformedOutput("FakeReviewRequestProvider does not provide check evidence details.")
        }
        func feedbackEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] { [] }
        func feedbackEvidenceDetail(
            remote: CodeHostRemote,
            request: ReviewRequest,
            item: ReviewEvidenceItem,
            cwd: URL
        ) async throws -> ReviewEvidenceDetail {
            throw CodeHostProviderError.malformedOutput("FakeReviewRequestProvider does not provide feedback evidence details.")
        }
        func rerunFailedChecks(
            remote: CodeHostRemote,
            branch: String,
            headSHA: String,
            request: ReviewRequest?,
            cwd: URL
        ) async throws {}
    }
}
