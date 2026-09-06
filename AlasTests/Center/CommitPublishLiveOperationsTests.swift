import Foundation
import Testing
@testable import Alas

@MainActor
struct CommitPublishLiveOperationsTests {
    @Test func captureSeparatesReviewRepositoryFromPushDestination() async throws {
        let snapshot = ReviewLoopSnapshot(
            local: ReviewLoopLocalState(branchName: "feature", headSHA: "old", baseBranch: "upstream/main",
                hasWorkingTreeChanges: true, hasStagedChanges: true, aheadCommitCount: 1,
                hasUpstream: false, headRemoteName: "fork", headRemoteOwner: "contributor",
                upstreamAheadCommitCount: 0, needsPush: true),
            remote: .init(kind: .github, host: "github.com", owner: "team", repository: "repo",
                remoteName: "upstream", webURL: URL(string: "https://github.com/team/repo")!),
            reviewRequest: nil, providerAvailable: true, providerAuthenticated: true,
            providerCapabilities: .githubCLI, errorMessage: nil
        )
        let target = try await CommitPublishReviewTarget.capture(
            snapshot: snapshot, createAsDraft: true, runGit: { args in
                #expect(args == ["remote", "get-url", "--push", "fork"])
                return ProcessResult(exitCode: 0, stdout: "ssh://git@github.com/contributor/repo.git\n", stderr: "")
            }
        )
        #expect(target.remote.remoteName == "upstream")
        #expect(target.pushRemoteName == "fork")
        #expect(target.pushURL == "ssh://git@github.com/contributor/repo.git")
        #expect(target.baseBranch == "upstream/main")
        #expect(target.createAsDraft)
        #expect(target.headOwner == "contributor")
        #expect(target.upstreamBranch == nil)
        #expect(try JSONDecoder().decode(CommitPublishReviewTarget.self, from: JSONEncoder().encode(target)) == target)
    }

    @Test func livePushUsesCapturedTargetWithoutUpstreamAndReportsOutput() async throws {
        var target = makeTarget()
        target.pushURL = "ssh://git@github.com/contributor/repo.git"
        target.pushRemoteName = "fork"
        var containmentCalls = 0
        let operations = CommitPublishOperations.live(
            worktreePath: URL(fileURLWithPath: "/tmp"),
            reviewLoop: ReviewLoopState(worktreePath: URL(fileURLWithPath: "/tmp"), baseBranch: "changed"),
            comparisonBase: "captured-base", syncGG: {}, refreshAfterCompletion: {},
            runGit: { args in
                if args == ["remote", "get-url", "--push", "fork"] {
                    return .init(exitCode: 0, stdout: "ssh://git@github.com/contributor/repo.git\n", stderr: "")
                }
                #expect(args == ["push", "-u", "fork", "feature"])
                return ProcessResult(exitCode: 1, stdout: "remote rejected branch\n", stderr: "")
            },
            containsCommit: { remote, branch, sha in
                containmentCalls += 1
                #expect(remote == "ssh://git@github.com/contributor/repo.git")
                #expect(branch == "feature")
                #expect(sha == "created-sha")
                return false
            }
        )
        #expect(try await !operations.remoteBranchContainsCommit(target, "created-sha"))
        #expect(containmentCalls == 1)
        do {
            try await operations.push(target, "created-sha")
            Issue.record("Expected push failure")
        } catch {
            #expect(error.localizedDescription.contains("remote rejected branch"))
        }
    }

    @Test func changedPushURLPreservesCheckpointAndDoesNotPush() async throws {
        var target = makeTarget()
        target.pushURL = "ssh://git@github.com/contributor/repo.git"
        target.pushRemoteName = "fork"
        var checkpoint: CommitPublishCheckpoint? = .init(commitSHA: "committed", baseRef: "base",
            commitTitle: "Title", subject: "Subject", body: "Body", destination: .review(target), nextPhase: .push)
        let original = checkpoint
        var pushed = false
        let operations = CommitPublishOperations.live(worktreePath: URL(fileURLWithPath: "/tmp"),
            reviewLoop: ReviewLoopState(worktreePath: URL(fileURLWithPath: "/tmp"), baseBranch: "main"),
            comparisonBase: nil, syncGG: {}, refreshAfterCompletion: {}, runGit: { args in
                switch args.first {
                case "rev-parse": return .init(exitCode: 0, stdout: "committed", stderr: "")
                case "remote": return .init(exitCode: 0, stdout: "ssh://git@github.com/other/repo.git", stderr: "")
                default:
                    pushed = true
                    throw NSError(domain: "Unexpected push", code: 1)
                }
            }, containsCommit: { _, _, _ in false })
        let workflow = CommitPublishWorkflow(operations: operations) { checkpoint = $0 }
        await workflow.resume(try #require(checkpoint))
        #expect(!pushed)
        #expect(checkpoint == original)
        #expect(workflow.lastError?.localizedDescription == "The push destination changed. Restore the captured remote URL before retrying.")
    }

    @Test func livePushUsesCapturedUpstreamBranch() async throws {
        var target = makeTarget(upstreamBranch: "remote-feature")
        target.pushURL = "ssh://git@github.com/contributor/repo.git"
        target.pushRemoteName = "fork"
        var calls: [[String]] = []
        let operations = CommitPublishOperations.live(worktreePath: URL(fileURLWithPath: "/tmp"),
            reviewLoop: ReviewLoopState(worktreePath: URL(fileURLWithPath: "/tmp"), baseBranch: "main"),
            comparisonBase: nil, syncGG: {}, refreshAfterCompletion: {}, runGit: { args in
                calls.append(args)
                return .init(exitCode: 0, stdout: target.pushURL!, stderr: "")
            }, containsCommit: { remote, branch, sha in
                #expect(remote == target.pushURL)
                #expect(branch == "remote-feature")
                #expect(sha == "committed")
                return false
            })
        #expect(try await !operations.remoteBranchContainsCommit(target, "committed"))
        try await operations.push(target, "committed")
        #expect(calls == [["remote", "get-url", "--push", "fork"], ["push", "-u", "fork", "HEAD:remote-feature"]])
    }

    @Test func workflowNormalizesMessageBeforeCommitCheckpointAndProviderCreation() async throws {
        let provider = CapturedPublishProvider()
        let path = URL(fileURLWithPath: "/tmp/captured-worktree")
        let review = ReviewLoopState(worktreePath: path, baseBranch: "main",
            providerRegistry: .init(providers: [.github: provider]))
        let operations = CommitPublishOperations.live(worktreePath: path, reviewLoop: review,
            comparisonBase: "main", syncGG: {}, refreshAfterCompletion: {},
            runGit: { _ in .init(exitCode: 0, stdout: "committed", stderr: "") },
            commit: { subject, body, _ in
                #expect(subject == "Subject")
                #expect(body == "Body")
                return "committed"
            }, containsCommit: { _, _, _ in true })
        var checkpoints: [CommitPublishCheckpoint] = []
        let workflow = CommitPublishWorkflow(operations: operations) {
            if let checkpoint = $0 { checkpoints.append(checkpoint) }
        }
        var target = makeTarget()
        target.pushURL = "ssh://git@github.com/contributor/repo.git"
        await workflow.start(subject: " \nSubject\t ", body: "\n Body \n", amend: false, destination: .review(target))
        #expect(workflow.lastError == nil)
        #expect(await provider.creationCount == 1)
        #expect(checkpoints.count == 2)
        #expect(checkpoints.allSatisfy { $0.subject == "Subject" && $0.body == "Body" })
    }

    @Test func liveCommitProbesAmendBeforeCommittingAndKeepsComparisonBase() async throws {
        var calls: [String] = []
        let operations = CommitPublishOperations.live(
            worktreePath: URL(fileURLWithPath: "/tmp"),
            reviewLoop: ReviewLoopState(worktreePath: URL(fileURLWithPath: "/tmp"), baseBranch: "main"),
            comparisonBase: "captured-base", syncGG: {}, refreshAfterCompletion: {},
            commit: { subject, body, amend in
                calls.append("commit")
                #expect(subject == "Subject")
                #expect(body == "Body")
                #expect(amend)
                return "abcdef123"
            },
            publicationState: { calls.append("probe"); return .unpublished }
        )
        let created = try await operations.createCommit("Subject", "Body", true)
        #expect(calls == ["probe", "commit"])
        #expect(created.comparisonBase == "captured-base")
        #expect(created.editorTitle == "abcdef1 Subject")
    }

    @Test func publishedAmendNeverCommits() async throws {
        var committed = false
        let operations = CommitPublishOperations.live(
            worktreePath: URL(fileURLWithPath: "/tmp"),
            reviewLoop: ReviewLoopState(worktreePath: URL(fileURLWithPath: "/tmp"), baseBranch: "main"),
            comparisonBase: nil, syncGG: {}, refreshAfterCompletion: {},
            commit: { _, _, _ in committed = true; return "new" }, publicationState: { .published }
        )
        await #expect(throws: (any Error).self) {
            try await operations.createCommit("Subject", "", true)
        }
        #expect(!committed)
    }

    @Test func oldTargetDecodesWithoutCapturedPushFields() throws {
        let data = try JSONEncoder().encode(makeTarget())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["pushURL"] == nil)
        let target = try JSONDecoder().decode(CommitPublishReviewTarget.self, from: data)
        #expect(target.pushURL == nil)
        #expect(target.pushRemoteName == nil)
    }

    @Test func liveLookupAndCreationUseCapturedTargetThenRefreshAfterCheckpointClears() async throws {
        let provider = CapturedPublishProvider()
        let path = URL(fileURLWithPath: "/tmp/captured-worktree")
        let review = ReviewLoopState(worktreePath: path, baseBranch: "changed-base",
            providerRegistry: .init(providers: [.github: provider]))
        let target = makeTarget()
        var checkpoint: CommitPublishCheckpoint? = .init(commitSHA: "committed", baseRef: "old-base",
            commitTitle: "Title", subject: "Subject", body: "Body", destination: .review(target), nextPhase: .createReviewRequest)
        var refreshed = false
        let operations = CommitPublishOperations.live(worktreePath: path, reviewLoop: review,
            comparisonBase: "changed-base", syncGG: {}, refreshAfterCompletion: {
                #expect(checkpoint == nil)
                #expect(await provider.creationCount == 1)
                refreshed = true
            }, runGit: { args in
                #expect(args == ["rev-parse", "--verify", "HEAD"])
                return .init(exitCode: 0, stdout: "committed", stderr: "")
            })
        let workflow = CommitPublishWorkflow(operations: operations) { checkpoint = $0 }
        await workflow.resume(try #require(checkpoint))
        #expect(workflow.lastError == nil)
        #expect(refreshed)
        #expect(await provider.lookupCount == 1)
    }

    @Test func liveCommitWithoutComparisonUsesFirstParentOrEmptyTree() async throws {
        for parentExists in [true, false] {
            let operations = CommitPublishOperations.live(worktreePath: URL(fileURLWithPath: "/tmp"),
                reviewLoop: ReviewLoopState(worktreePath: URL(fileURLWithPath: "/tmp"), baseBranch: "main"),
                comparisonBase: nil, syncGG: {}, refreshAfterCompletion: {},
                runGit: { args in
                    #expect(args == ["rev-parse", "--verify", "new-sha^"])
                    return .init(exitCode: parentExists ? 0 : 1, stdout: "parent-sha\n", stderr: "")
                }, commit: { _, _, _ in "new-sha" })
            let created = try await operations.createCommit("Subject", "", false)
            #expect(created.comparisonBase == (parentExists ? "parent-sha" : "4b825dc642cb6eb9a060e54bf8d69288fbee4904"))
        }
    }

    private func makeTarget(upstreamBranch: String? = nil) -> CommitPublishReviewTarget {
        .init(provider: .github, host: "github.com", owner: "team", repository: "repo",
              repositorySlug: "team/repo", remoteName: "upstream",
              webURL: URL(string: "https://github.com/team/repo")!, branch: "feature",
              upstreamBranch: upstreamBranch, headOwner: "contributor", baseBranch: "main",
              reviewRequestExisted: false, createAsDraft: true)
    }
}

private actor CapturedPublishProvider: CodeHostProvider {
    nonisolated let kind = CodeHostKind.github
    var lookupCount = 0
    var creationCount = 0
    func isAvailable(cwd: URL) async -> Bool { true }
    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }
    func currentReviewRequest(remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, cwd: URL) async throws -> ReviewRequest? {
        lookupCount += 1
        checkTarget(remote, branch, headOwner, baseBranch, cwd)
        return nil
    }
    func createReviewRequest(remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String,
        title: String, body: String, isDraft: Bool, cwd: URL) async throws -> URL {
        creationCount += 1
        checkTarget(remote, branch, headOwner, baseBranch, cwd)
        #expect(title == "Subject")
        #expect(body == "Body")
        #expect(isDraft)
        return remote.webURL
    }
    private func checkTarget(_ remote: CodeHostRemote, _ branch: String, _ owner: String?, _ base: String, _ cwd: URL) {
        #expect(remote.repositorySlug == "team/repo")
        #expect(remote.remoteName == "upstream")
        #expect(branch == "feature")
        #expect(owner == "contributor")
        #expect(base == "main")
        #expect(cwd.path == "/tmp/captured-worktree")
    }
    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] { [] }
    func rerunFailedChecks(remote: CodeHostRemote, branch: String, headSHA: String, request: ReviewRequest?, cwd: URL) async throws {}
}
