import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct GitServiceUpstreamTests {
    @Test func cancelledRemoteProbeRemovesFetchedTemporaryRefBeforeReturning() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let checkpoint = try await checkedGit(["rev-parse", "HEAD"], cwd: repo)
        let marker = repo.appendingPathComponent("fetched")
        let release = repo.appendingPathComponent("release-fetch")
        let hook = repo.appendingPathComponent(".git/hooks/reference-transaction")
        try """
        #!/bin/sh
        while read old new ref; do
            case "$ref" in
            refs/alas/publish-check/*)
                if [ "$new" = '0000000000000000000000000000000000000000' ]; then
                    sleep 0.1
                elif [ "$1" = committed ]; then
                    touch '\(marker.path)'
                    while [ ! -f '\(release.path)' ]; do sleep 0.01; done
                fi
                ;;
            esac
        done
        """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let probe = Task {
            try await GitService().remoteBranchContainsCommit(worktreePath: repo, remote: remote.path, branch: "main", commitSHA: checkpoint)
        }
        defer {
            probe.cancel()
            try? "".write(to: release, atomically: true, encoding: .utf8)
        }
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let didFetch = FileManager.default.fileExists(atPath: marker.path)
        let fetchedRefs = try await checkedGit(["for-each-ref", "--format=%(refname)", "refs/alas/publish-check/"], cwd: repo)
        probe.cancel()
        try "".write(to: release, atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) { try await probe.value }
        #expect(didFetch)
        #expect(!fetchedRefs.isEmpty)
        #expect(try await checkedGit(["for-each-ref", "--format=%(refname)", "refs/alas/publish-check/"], cwd: repo).isEmpty)
    }

    @Test(arguments: [true, false])
    func remoteProbeReportsCleanupFailureButPreservesOriginalFailure(validCheckpoint: Bool) async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let checkpoint = try await checkedGit(["rev-parse", "HEAD"], cwd: repo)
        let hook = repo.appendingPathComponent(".git/hooks/reference-transaction")
        try """
        #!/bin/sh
        while read old new ref; do
            case "$ref" in
            refs/alas/publish-check/*)
                if [ "$1" = prepared ] && [ "$new" = '0000000000000000000000000000000000000000' ]; then
                    echo 'cleanup refused' >&2
                    exit 1
                fi
                ;;
            esac
        done
        """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        do {
            _ = try await GitService().remoteBranchContainsCommit(
                worktreePath: repo, remote: remote.path, branch: "main",
                commitSHA: validCheckpoint ? checkpoint : "not-a-commit"
            )
            Issue.record("Expected the probe or cleanup error to propagate")
        } catch {
            #expect((error as NSError).domain == "GitService.\(validCheckpoint ? "Delete publication probe ref" : "Check remote commit")")
        }
    }

    @Test func remoteProbeUsesResolvedPushURLForSplitFetchAndPushRemote() async throws {
        let (repo, fetchRemote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: fetchRemote)
        }
        let pushRemote = repo.appendingPathComponent("publish.git")
        _ = try await checkedGit(["init", "--bare", "-q", pushRemote.path], cwd: repo)
        _ = try await checkedGit(["remote", "set-url", "--push", "origin", pushRemote.path], cwd: repo)
        _ = try await checkedGit(["commit", "-q", "--allow-empty", "-m", "publication"], cwd: repo)
        _ = try await checkedGit(["push", "-q", "origin", "main"], cwd: repo)
        let checkpoint = try await checkedGit(["rev-parse", "HEAD"], cwd: repo)
        let publicationURL = try await checkedGit(["remote", "get-url", "--push", "origin"], cwd: repo)
        let git = GitService()
        #expect(try await git.remoteBranchContainsCommit(worktreePath: repo, remote: publicationURL, branch: "main", commitSHA: checkpoint))
        #expect(try await git.remoteBranchContainsCommit(worktreePath: repo, remote: "origin", branch: "main", commitSHA: checkpoint) == false)
    }

    @Test func strictPublicationDistinguishesStatesAndProbeFailures() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let git = GitService()
        #expect(try await git.headPublicationState(worktreePath: repo) == .published)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "local"], cwd: repo)
        #expect(try await git.headPublicationState(worktreePath: repo) == .unpublished)
        _ = try await Process.git(["update-ref", "-d", "refs/remotes/origin/main"], cwd: repo)
        await #expect(throws: (any Error).self) { try await git.headPublicationState(worktreePath: repo) }
        _ = try await Process.git(["branch", "--unset-upstream"], cwd: repo)
        #expect(try await git.headPublicationState(worktreePath: repo) == .noUpstream)
        await #expect(throws: (any Error).self) { try await git.headPublicationState(worktreePath: remote.deletingLastPathComponent()) }
    }

    @Test func strictPublicationDistinguishesBehindDivergedAndDetachedHead() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let git = GitService()
        let initial = try await checkedGit(["rev-parse", "HEAD"], cwd: repo)
        _ = try await checkedGit(["commit", "-q", "--allow-empty", "-m", "remote update"], cwd: repo)
        _ = try await checkedGit(["push", "-q", "origin", "main"], cwd: repo)
        _ = try await checkedGit(["update-ref", "refs/heads/main", initial], cwd: repo)
        #expect(try await git.headPublicationState(worktreePath: repo) == .published)
        _ = try await checkedGit(["commit", "-q", "--allow-empty", "-m", "local divergence"], cwd: repo)
        #expect(try await git.headPublicationState(worktreePath: repo) == .unpublished)
        #expect(try await git.isHeadAtOrBehindUpstream(worktreePath: repo) == false)
        _ = try await checkedGit(["checkout", "--detach", "HEAD"], cwd: repo)
        #expect(try await git.headPublicationState(worktreePath: repo) == .noUpstream)
    }

    @Test func remoteContainmentUsesExactBranchWithoutUpstreamAndCleansTemporaryRef() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let git = GitService()
        let checkpoint = try await checkedGit(["rev-parse", "HEAD"], cwd: repo)
        let secondRemote = repo.appendingPathComponent("secondary.git")
        _ = try await checkedGit(["init", "--bare", "-q", secondRemote.path], cwd: repo)
        _ = try await checkedGit(["remote", "add", "publish", secondRemote.path], cwd: repo)
        _ = try await checkedGit(["push", "-q", "publish", "HEAD:main"], cwd: repo)
        _ = try await checkedGit(["branch", "--unset-upstream"], cwd: repo)
        _ = try await checkedGit(["update-ref", "refs/alas/publish-check/keep", checkpoint], cwd: repo)
        #expect(try await git.remoteBranchContainsCommit(worktreePath: repo, remote: "origin", branch: "missing", commitSHA: checkpoint) == false)
        #expect(try await git.remoteBranchContainsCommit(worktreePath: repo, remote: "origin", branch: "main", commitSHA: checkpoint))
        _ = try await checkedGit(["commit", "-q", "--allow-empty", "-m", "advance"], cwd: repo)
        _ = try await checkedGit(["push", "-q", "origin", "HEAD:main"], cwd: repo)
        #expect(try await git.remoteBranchContainsCommit(worktreePath: repo, remote: "origin", branch: "main", commitSHA: checkpoint))
        _ = try await checkedGit(["checkout", "--orphan", "unrelated"], cwd: repo)
        _ = try await checkedGit(["commit", "-q", "--allow-empty", "-m", "unrelated"], cwd: repo)
        _ = try await checkedGit(["push", "-q", "--force", "origin", "HEAD:main"], cwd: repo)
        _ = try await checkedGit(["update-ref", "refs/remotes/origin/main", checkpoint], cwd: repo)
        #expect(try await git.remoteBranchContainsCommit(worktreePath: repo, remote: "origin", branch: "main", commitSHA: checkpoint) == false)
        #expect(try await git.remoteBranchContainsCommit(worktreePath: repo, remote: "publish", branch: "main", commitSHA: checkpoint))
        #expect(try await checkedGit(["rev-parse", "refs/remotes/origin/main"], cwd: repo) == checkpoint)
        await #expect(throws: (any Error).self) {
            try await git.remoteBranchContainsCommit(worktreePath: repo, remote: "origin", branch: "main", commitSHA: "not-a-commit")
        }
        #expect(try await checkedGit(["for-each-ref", "--format=%(refname)", "refs/alas/publish-check/"], cwd: repo) == "refs/alas/publish-check/keep")
        _ = try await checkedGit(["remote", "set-url", "origin", remote.appendingPathComponent("missing").path], cwd: repo)
        await #expect(throws: (any Error).self) {
            try await git.remoteBranchContainsCommit(worktreePath: repo, remote: "origin", branch: "main", commitSHA: checkpoint)
        }
    }

    @Test func remoteContainmentThrowsWhenFetchFailsAfterAdvertisement() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let checkpoint = try await checkedGit(["rev-parse", "HEAD"], cwd: repo)
        let script = repo.appendingPathComponent("upload-pack")
        let marker = repo.appendingPathComponent("advertised")
        try """
        #!/bin/sh
        if [ -f '\(marker.path)' ]; then
            echo 'fetch refused' >&2
            exit 42
        fi
        touch '\(marker.path)'
        exec /usr/bin/git-upload-pack "$@"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        _ = try await checkedGit(["config", "remote.origin.uploadpack", script.path], cwd: repo)
        await #expect(throws: (any Error).self) {
            try await GitService().remoteBranchContainsCommit(worktreePath: repo, remote: "origin", branch: "main", commitSHA: checkpoint)
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try await checkedGit(["for-each-ref", "--format=%(refname)", "refs/alas/publish-check/"], cwd: repo).isEmpty)
    }

    private func checkedGit(_ args: [String], cwd: URL) async throws -> String {
        let result = try await Process.git(args, cwd: cwd)
        guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeRepoWithRemote() async throws -> (URL, URL) {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-up-\(UUID().uuidString)")
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-rmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: repo)
        _ = try await Process.git(["config", "user.name", "t"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)
        _ = try await Process.git(["init", "--bare", "-q", remote.path], cwd: nil)
        _ = try await Process.git(["remote", "add", "origin", remote.path], cwd: repo)
        _ = try await Process.git(["push", "-q", "-u", "origin", "main"], cwd: repo)
        return (repo, remote)
    }

    @Test func trueWhenHeadEqualsUpstream() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let svc = GitService()
        #expect(try await svc.isHeadAtOrBehindUpstream(worktreePath: repo) == true)
    }

    @Test func falseWhenHeadAhead() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "extra"], cwd: repo)
        let svc = GitService()
        #expect(try await svc.isHeadAtOrBehindUpstream(worktreePath: repo) == false)
    }

    @Test func falseWhenNoUpstream() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-noup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: dir)
        _ = try await Process.git(["config", "user.name", "t"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "x"], cwd: dir)

        let svc = GitService()
        #expect(try await svc.isHeadAtOrBehindUpstream(worktreePath: dir) == false)
    }
}
