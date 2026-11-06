import Foundation
import Testing
@testable import AlasPlatform
@testable import AlasAgents

/// Real git: a clone whose `origin` is another copy of the template.
struct PeerWorktreeBaseTests {
    private struct Repo {
        let root: URL
        let clone: URL
        let origin: URL
        let head: String

        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-peer-base-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            clone = root.appendingPathComponent("clone")
            origin = root.appendingPathComponent("origin")
            try await GitTemplate.repository(at: origin)
            try await GitTemplate.repository(at: clone)
            _ = try await Process.git(["remote", "add", "origin", origin.path], cwd: clone)
            _ = try await Process.git(["fetch", "-q", "origin", "main"], cwd: clone)
            head = try await Self.sha("HEAD", in: clone)
        }

        static func sha(_ ref: String, in repo: URL) async throws -> String {
            try await Process.git(["rev-parse", ref], cwd: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// A commit on top of `HEAD` in `repo`, with no working tree needed.
        func commitOnHead(in repo: URL) async throws -> String {
            let identity = ["-c", "user.name=test", "-c", "user.email=test@example.com"]
            return try await Process.git(identity + ["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "next"], cwd: repo)
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func resolve(branch: String = "fix/parser", base: String = "main", expectedSHA: String?) async -> Result<String, PeerWorktreeBase.Failure> {
            await PeerWorktreeBase.resolve(branch: branch, base: base, expectedSHA: expectedSHA, repo: clone, machine: "Mini")
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func failureMessage(_ result: Result<String, PeerWorktreeBase.Failure>) throws -> String {
        guard case .failure(let failure) = result else {
            Issue.record("Expected a failure, got \(result)")
            throw CancellationError()
        }
        return failure.message
    }

    @Test func aDifferentRemoteCommitFails() async throws {
        let repo = try await Repo()
        defer { repo.tearDown() }
        let wrong = String(repeating: "0", count: 40)

        let message = try failureMessage(await repo.resolve(expectedSHA: wrong))

        #expect(message == "main on Mini is at \(repo.head), expected \(wrong). Push and try again.")
    }

    /// The tracking ref was behind, so this passes only by fetching. The answer
    /// is the commit, since another fetch can move the ref before it is used.
    @Test func aPushedCommitIsFetchedAndTheCommitReturned() async throws {
        let repo = try await Repo()
        defer { repo.tearDown() }
        let pushed = try await repo.commitOnHead(in: repo.origin)
        _ = try await Process.git(["update-ref", "refs/heads/main", pushed], cwd: repo.origin)

        let result = await repo.resolve(expectedSHA: pushed)

        #expect(result == .success(pushed))
        #expect(try await Repo.sha("origin/main", in: repo.clone) == pushed)
    }

    /// The state the source reads from the parent's checkout, with real git.
    @Test func branchStateSeesAnUnpushedCommit() async throws {
        let repo = try await Repo()
        defer { repo.tearDown() }
        _ = try await Process.git(["branch", "--set-upstream-to=origin/main", "main"], cwd: repo.clone)

        let pushed = await ACPPeerBasePreflight.branchState(worktreePath: repo.clone)

        #expect(pushed == ACPPeerBranchState(
            isClean: true, head: repo.head, branch: "main", upstream: "origin/main", upstreamHead: repo.head, upstreamOnOrigin: true
        ))
        let identity = ["-c", "user.name=test", "-c", "user.email=test@example.com"]
        _ = try await Process.git(identity + ["commit", "-q", "--allow-empty", "-m", "local"], cwd: repo.clone)

        let ahead = try #require(await ACPPeerBasePreflight.branchState(worktreePath: repo.clone))

        #expect(ahead.head != repo.head && ahead.upstreamHead == repo.head)
    }

    enum FetchFailure: CaseIterable { case branchMissing, remoteUnreachable }

    /// Git's own reason, since it can as well be auth or the network.
    @Test(arguments: FetchFailure.allCases)
    func aFailedFetchFailsWithGitsReason(failure: FetchFailure) async throws {
        let repo = try await Repo()
        defer { repo.tearDown() }
        if failure == .remoteUnreachable {
            _ = try await Process.git(["remote", "set-url", "origin", repo.root.appendingPathComponent("gone").path], cwd: repo.clone)
        }
        let base = failure == .branchMissing ? "gone" : "main"

        let message = try failureMessage(await repo.resolve(base: base, expectedSHA: repo.head))

        #expect(message.hasPrefix("\(base) on Mini could not be fetched from origin, expected \(repo.head): "))
        #expect(message.contains(failure == .branchMissing ? "couldn't find remote ref" : "does not appear to be a git repository"))
        #expect(!message.contains("Push and try again"))
    }

    @Test func noRemoteFails() async throws {
        let repo = try await Repo()
        defer { repo.tearDown() }
        _ = try await Process.git(["remote", "remove", "origin"], cwd: repo.clone)

        let message = try failureMessage(await repo.resolve(expectedSHA: repo.head))

        #expect(message.hasPrefix("main on Mini has no origin remote"))
    }

    /// A worktree checks out an existing branch, ignoring the base.
    @Test func aLocalBranchElsewhereFails() async throws {
        let repo = try await Repo()
        defer { repo.tearDown() }
        let other = try await repo.commitOnHead(in: repo.clone)
        _ = try await Process.git(["branch", "fix/parser", other], cwd: repo.clone)

        let message = try failureMessage(await repo.resolve(expectedSHA: repo.head))

        #expect(message.hasPrefix("fix/parser already exists on Mini at \(other)"))
    }

    /// An explicit base too: the child would run on the branch's old code, not
    /// the base asked for, with nothing said.
    @Test func withoutAnExpectedCommitALocalBranchElsewhereFails() async throws {
        let repo = try await Repo()
        defer { repo.tearDown() }
        let other = try await repo.commitOnHead(in: repo.clone)
        _ = try await Process.git(["branch", "fix/parser", other], cwd: repo.clone)
        _ = try await Process.git(["branch", "local-only"], cwd: repo.clone)

        let message = try failureMessage(await repo.resolve(expectedSHA: nil))
        #expect(message == "fix/parser already exists on Mini at \(other), but origin/main is at \(repo.head). Delete it or pick another name.")
        // A base the remote does not have, then a repository with no remote.
        #expect(try failureMessage(await repo.resolve(base: "local-only", expectedSHA: nil)).hasPrefix("fix/parser already exists"))
        _ = try await Process.git(["remote", "remove", "origin"], cwd: repo.clone)
        #expect(try failureMessage(await repo.resolve(base: "local-only", expectedSHA: nil)).hasPrefix("fix/parser already exists"))
        // Nothing would run on the wrong code, so nothing to refuse.
        _ = try await Process.git(["branch", "-f", "fix/parser", repo.head], cwd: repo.clone)
        #expect(await repo.resolve(base: "local-only", expectedSHA: nil) == .success("local-only"))
    }

    /// Without an expected commit a failed fetch fails nothing: the remote's
    /// ref if it has one, stale or not, else the base as given.
    @Test func withoutAnExpectedCommitTheFetchIsBestEffort() async throws {
        let repo = try await Repo()
        defer { repo.tearDown() }
        _ = try await Process.git(["branch", "local-only"], cwd: repo.clone)

        #expect(await repo.resolve(expectedSHA: nil) == .success("origin/main"))
        #expect(await repo.resolve(base: "origin/main", expectedSHA: nil) == .success("origin/main"))
        #expect(await repo.resolve(base: "local-only", expectedSHA: nil) == .success("local-only"))

        _ = try await Process.git(["remote", "set-url", "origin", repo.root.appendingPathComponent("gone").path], cwd: repo.clone)
        #expect(await repo.resolve(expectedSHA: nil) == .success("origin/main"))
    }

    @Test func credentialsInGitsErrorAreRemoved() {
        let error = "fatal: unable to access 'https://user:token@example.com/repo.git/': 403"
        #expect(PeerWorktreeBase.redactingCredentials(error) == "fatal: unable to access 'https://example.com/repo.git/': 403")
    }
}
