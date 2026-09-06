import Foundation
import Testing
@testable import Alas

@MainActor
struct CommitPublishLiveOperationsTests {
    @Test func captureRejectsIncompatibleUpstreamRemoteBeforeReadingGit() async {
        let snapshot = ReviewLoopSnapshot(
            local: ReviewLoopLocalState(branchName: "feature", headSHA: "old", baseBranch: "main",
                hasWorkingTreeChanges: true, hasStagedChanges: true, aheadCommitCount: 1,
                hasUpstream: true, upstreamRemoteName: "fork", upstreamBranchName: "feature",
                upstreamAheadCommitCount: 0, needsPush: true),
            remote: .init(kind: .github, host: "github.com", owner: "team", repository: "repo",
                remoteName: "origin", webURL: URL(string: "https://github.com/team/repo")!),
            reviewRequest: nil, providerAvailable: true, providerAuthenticated: true,
            providerCapabilities: .githubCLI, errorMessage: nil
        )
        var commands: [[String]] = []

        await #expect(throws: CommitPublishWorkflowError.incompatiblePushRemote) {
            try await CommitPublishReviewTarget.capture(
                snapshot: snapshot, createAsDraft: false, runGit: { args in
                    commands.append(args)
                    return .init(exitCode: 0, stdout: "", stderr: "")
                }
            )
        }

        #expect(commands.isEmpty)
    }

    @Test func captureUsesCompatibleTrackedUpstreamRemote() async throws {
        let snapshot = ReviewLoopSnapshot(
            local: ReviewLoopLocalState(branchName: "feature", headSHA: "old", baseBranch: "main",
                hasWorkingTreeChanges: true, hasStagedChanges: true, aheadCommitCount: 1,
                hasUpstream: true, upstreamRemoteName: "fork", upstreamBranchName: "review/feature",
                headRemoteName: "fork", headRemoteOwner: "contributor",
                upstreamAheadCommitCount: 0, needsPush: true),
            remote: .init(kind: .github, host: "github.com", owner: "team", repository: "repo",
                remoteName: "origin", webURL: URL(string: "https://github.com/team/repo")!),
            reviewRequest: nil, providerAvailable: true, providerAuthenticated: true,
            providerCapabilities: .githubCLI, errorMessage: nil
        )
        let target = try await CommitPublishReviewTarget.capture(
            snapshot: snapshot, createAsDraft: false, runGit: { args in
                switch args {
                case ["symbolic-ref", "--short", "HEAD"]:
                    return .init(exitCode: 0, stdout: "feature\n", stderr: "")
                case ["rev-parse", "--verify", "HEAD"]:
                    return .init(exitCode: 0, stdout: "captured-head\n", stderr: "")
                case ["remote", "get-url", "--push", "--all", "fork"]:
                    return .init(exitCode: 0, stdout: "ssh://git@github.com/contributor/repo.git\n", stderr: "")
                default:
                    Issue.record("Unexpected Git command: \(args)")
                    return .init(exitCode: 1, stdout: "", stderr: "")
                }
            }
        )

        #expect(target.pushRemoteName == "fork")
        #expect(target.upstreamBranch == "review/feature")
    }

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
                switch args {
                case ["symbolic-ref", "--short", "HEAD"]:
                    return .init(exitCode: 0, stdout: "feature\n", stderr: "")
                case ["rev-parse", "--verify", "HEAD"]:
                    return .init(exitCode: 0, stdout: "captured-head\n", stderr: "")
                case ["remote", "get-url", "--push", "--all", "fork"]:
                    return .init(exitCode: 0, stdout: "ssh://git@github.com/contributor/repo.git\nssh://mirror.example/repo.git\n", stderr: "")
                default:
                    Issue.record("Unexpected Git command: \\(args)")
                    return .init(exitCode: 1, stdout: "", stderr: "")
                }
            }
        )
        #expect(target.remote.remoteName == "upstream")
        #expect(target.pushRemoteName == "fork")
        #expect(target.pushURL == "ssh://git@github.com/contributor/repo.git")
        #expect(target.pushURLs == ["ssh://git@github.com/contributor/repo.git", "ssh://mirror.example/repo.git"])
        #expect(target.baseBranch == "upstream/main")
        #expect(target.createAsDraft)
        #expect(target.headOwner == "contributor")
        #expect(target.upstreamBranch == nil)
        #expect(target.expectedHeadSHA == "captured-head")
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
                if args == ["remote", "get-url", "--push", "--all", "fork"] {
                    return .init(exitCode: 0, stdout: "ssh://git@github.com/contributor/repo.git\n", stderr: "")
                }
                #expect(args == ["push", "-u", "fork", "created-sha:refs/heads/feature"])
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

    @Test func liveTargetValidationRejectsChangedBranchAndHead() async throws {
        let path = URL(fileURLWithPath: "/tmp/captured-worktree")
        let review = ReviewLoopState(worktreePath: path, baseBranch: "main")
        let branchOperations = CommitPublishOperations.live(worktreePath: path, reviewLoop: review,
            comparisonBase: nil, syncGG: {}, refreshAfterCompletion: {}, runGit: { args in
                #expect(args == ["symbolic-ref", "--short", "HEAD"])
                return .init(exitCode: 0, stdout: "other-feature\n", stderr: "")
            })
        await #expect(throws: CommitPublishWorkflowError.branchMismatch(expected: "feature", actual: "other-feature")) {
            try await branchOperations.validateReviewTarget(makeTarget())
        }

        let headOperations = CommitPublishOperations.live(worktreePath: path, reviewLoop: review,
            comparisonBase: nil, syncGG: {}, refreshAfterCompletion: {}, runGit: { args in
                switch args {
                case ["symbolic-ref", "--short", "HEAD"]:
                    return .init(exitCode: 0, stdout: "feature\n", stderr: "")
                case ["rev-parse", "--verify", "HEAD"]:
                    return .init(exitCode: 0, stdout: "changed-head\n", stderr: "")
                default:
                    Issue.record("Unexpected Git command: \\(args)")
                    return .init(exitCode: 1, stdout: "", stderr: "")
                }
            })
        await #expect(throws: CommitPublishWorkflowError.headMismatch(expected: "captured-head", actual: "changed-head")) {
            try await headOperations.validateReviewTarget(makeTarget(expectedHeadSHA: "captured-head"))
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
        #expect(calls == [["remote", "get-url", "--push", "--all", "fork"], ["push", "-u", "fork", "committed:refs/heads/remote-feature"]])
    }

    @Test func addingPushURLAfterCaptureDoesNotPublishToEitherDestination() async throws {
        var target = makeTarget()
        target.pushURL = "ssh://git@github.com/contributor/repo.git"
        target.pushURLs = [target.pushURL!]
        target.pushRemoteName = "fork"
        var pushed = false
        let operations = CommitPublishOperations.live(worktreePath: URL(fileURLWithPath: "/tmp"),
            reviewLoop: ReviewLoopState(worktreePath: URL(fileURLWithPath: "/tmp"), baseBranch: "main"),
            comparisonBase: nil, syncGG: {}, refreshAfterCompletion: {}, runGit: { args in
                if args.first == "remote" {
                    #expect(args == ["remote", "get-url", "--push", "--all", "fork"])
                    let urls = args.contains("--all") ? target.pushURL! + "\nssh://unexpected.example/repo.git\n" : target.pushURL!
                    return .init(exitCode: 0, stdout: urls, stderr: "")
                }
                pushed = true
                return .init(exitCode: 0, stdout: "", stderr: "")
            })
        await #expect(throws: CommitPublishWorkflowError.pushDestinationChanged) {
            try await operations.push(target, "committed")
        }
        #expect(!pushed)
    }

    @Test func headChangeDuringContainmentStillPushesCheckpointCommit() async throws {
        var target = makeTarget(upstreamBranch: "remote-feature")
        target.pushURL = "ssh://git@github.com/contributor/repo.git"
        target.pushRemoteName = "fork"
        var head = "committed"
        var pushArguments: [String]?
        var operations = CommitPublishOperations.live(worktreePath: URL(fileURLWithPath: "/tmp"),
            reviewLoop: ReviewLoopState(worktreePath: URL(fileURLWithPath: "/tmp"), baseBranch: "main"),
            comparisonBase: nil, syncGG: {}, refreshAfterCompletion: {}, runGit: { args in
                if args.first == "rev-parse" { return .init(exitCode: 0, stdout: head, stderr: "") }
                if args.first == "remote" { return .init(exitCode: 0, stdout: target.pushURL!, stderr: "") }
                pushArguments = args
                return .init(exitCode: 0, stdout: "", stderr: "")
            }, containsCommit: { _, _, _ in head = "new-head"
            return false })
        operations.currentReviewRequestExists = { _ in true }
        let workflow = CommitPublishWorkflow(operations: operations) { _ in }
        await workflow.resume(.init(commitSHA: "committed", baseRef: "main", commitTitle: "Title",
            subject: "Subject", body: "", destination: .review(target), nextPhase: .push))
        #expect(workflow.lastError == nil)
        #expect(head == "new-head")
        #expect(pushArguments == ["push", "-u", "fork", "committed:refs/heads/remote-feature"])
    }

    @Test func containmentChecksEveryCapturedPushURL() async throws {
        var target = makeTarget()
        target.pushURL = "ssh://primary.example/repo.git"
        target.pushURLs = [target.pushURL!, "ssh://mirror.example/repo.git"]
        var checked: [String] = []
        let operations = CommitPublishOperations.live(worktreePath: URL(fileURLWithPath: "/tmp"),
            reviewLoop: ReviewLoopState(worktreePath: URL(fileURLWithPath: "/tmp"), baseBranch: "main"),
            comparisonBase: nil, syncGG: {}, refreshAfterCompletion: {}, containsCommit: { remote, _, _ in
                checked.append(remote)
                return remote == target.pushURL
            })
        #expect(try await !operations.remoteBranchContainsCommit(target, "committed"))
        #expect(checked == target.pushURLs)
    }

    @Test func explicitCommitPushStillSetsUpstreamForUntrackedBranch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = directory.appendingPathComponent("worktree")
        let remote = directory.appendingPathComponent("remote.git")
        for args in [["init", "--bare", remote.path], ["init", "-b", "feature", repo.path]] {
            try GitService.assertSuccess(try await Process.git(args, cwd: directory), op: "Initialize test repository")
        }
        try GitService.assertSuccess(try await Process.git(
            ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "Initial"], cwd: repo), op: "Create test commit")
        try GitService.assertSuccess(try await Process.git(["remote", "add", "fork", remote.path], cwd: repo), op: "Add test remote")
        let head = try await Process.git(["rev-parse", "HEAD"], cwd: repo)
        let sha = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var target = makeTarget()
        target.pushURL = remote.path
        target.pushRemoteName = "fork"
        let operations = CommitPublishOperations.live(worktreePath: repo,
            reviewLoop: ReviewLoopState(worktreePath: repo, baseBranch: "main"), comparisonBase: nil,
            syncGG: {}, refreshAfterCompletion: {})
        try await operations.push(target, sha)
        let upstream = try await Process.git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], cwd: repo)
        #expect(upstream.exitCode == 0)
        #expect(upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "fork/feature")
    }

    @Test func workflowNormalizesMessageBeforeCommitCheckpointAndProviderCreation() async throws {
        let provider = CapturedPublishProvider()
        let path = URL(fileURLWithPath: "/tmp/captured-worktree")
        let review = ReviewLoopState(worktreePath: path, baseBranch: "main",
            providerRegistry: .init(providers: [.github: provider]))
        let operations = CommitPublishOperations.live(worktreePath: path, reviewLoop: review,
            comparisonBase: "main", syncGG: {}, refreshAfterCompletion: {},
            runGit: { args in
                if args == ["symbolic-ref", "--short", "HEAD"] {
                    return .init(exitCode: 0, stdout: "feature", stderr: "")
                }
                return .init(exitCode: 0, stdout: "committed", stderr: "")
            },
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
            publicationState: { calls.append("probe")
            return .unpublished }
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
            commit: { _, _, _ in committed = true
            return "new" }, publicationState: { .published }
        )
        await #expect(throws: (any Error).self) {
            try await operations.createCommit("Subject", "", true)
        }
        #expect(!committed)
    }

    @Test func oldTargetDecodesWithoutCapturedPushFields() throws {
        let encoded = try JSONEncoder().encode(makeTarget())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["pushURL"] == nil)
        object.removeValue(forKey: "expectedHeadSHA")
        let data = try JSONSerialization.data(withJSONObject: object)
        let target = try JSONDecoder().decode(CommitPublishReviewTarget.self, from: data)
        #expect(target.expectedHeadSHA == nil)
        #expect(target.pushURL == nil)
        #expect(target.pushRemoteName == nil)
    }

    @Test func legacyGGCheckpointDecodesWithoutCapturedTarget() throws {
        let data = Data(#"""
        {
          "commitSHA": "committed",
          "baseRef": "main",
          "commitTitle": "Title",
          "subject": "Subject",
          "body": "",
          "destination": { "gg": {} },
          "nextPhase": "sync"
        }
        """#.utf8)

        let checkpoint = try JSONDecoder().decode(CommitPublishCheckpoint.self, from: data)

        #expect(checkpoint.destination == .gg(nil))
    }

    @Test func legacySinglePushURLDecodesAsOneCapturedDestination() throws {
        var original = makeTarget()
        original.pushURL = "ssh://legacy.example/repo.git"
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(CommitPublishReviewTarget.self, from: data)
        #expect(restored.pushURLs == nil)
        #expect(restored.capturedPushURLs == ["ssh://legacy.example/repo.git"])
    }

    @Test func liveLookupAndCreationUseCapturedTargetThenRefreshAfterCheckpointClears() async throws {
        let provider = CapturedPublishProvider(expectedBranch: "pushed-feature")
        let path = URL(fileURLWithPath: "/tmp/captured-worktree")
        let review = ReviewLoopState(worktreePath: path, baseBranch: "changed-base",
            providerRegistry: .init(providers: [.github: provider]))
        let target = makeTarget(upstreamBranch: "pushed-feature")
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

    private func makeTarget(
        upstreamBranch: String? = nil,
        expectedHeadSHA: String? = nil
    ) -> CommitPublishReviewTarget {
        .init(provider: .github, host: "github.com", owner: "team", repository: "repo",
              repositorySlug: "team/repo", remoteName: "upstream",
              webURL: URL(string: "https://github.com/team/repo")!, branch: "feature",
              expectedHeadSHA: expectedHeadSHA, upstreamBranch: upstreamBranch,
              headOwner: "contributor", baseBranch: "main",
              reviewRequestExisted: false, createAsDraft: true)
    }
}

private actor CapturedPublishProvider: CodeHostProvider {
    nonisolated let kind = CodeHostKind.github
    private let expectedBranch: String
    var lookupCount = 0
    var creationCount = 0

    init(expectedBranch: String = "feature") {
        self.expectedBranch = expectedBranch
    }
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
        #expect(branch == expectedBranch)
        #expect(owner == "contributor")
        #expect(base == "main")
        #expect(cwd.path == "/tmp/captured-worktree")
    }
    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] { [] }
    func rerunFailedChecks(remote: CodeHostRemote, branch: String, headSHA: String, request: ReviewRequest?, cwd: URL) async throws {}
}
