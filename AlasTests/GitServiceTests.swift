import Testing
import Foundation
@testable import Alas

// Serialize: each test creates an ephemeral repo and shells out to git.
// Concurrent git invocations on macos-26 CI have produced flaky hangs.
@Suite(.serialized)
struct GitServiceTests {
    private func makeRepo(remote: String? = nil) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-svc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        if let remote {
            _ = try await Process.git(["remote", "add", "origin", remote], cwd: dir)
        }
        return dir
    }

    @Test func validateAcceptsRealRepo() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let svc = GitService()
        let valid = try await svc.isGitRepository(repo)
        #expect(valid == true)
    }

    @Test func validateRejectsNonRepo() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-nonrepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let svc = GitService()
        let valid = try await svc.isGitRepository(dir)
        #expect(valid == false)
    }

    @Test func suggestNameFromHttpsRemote() async throws {
        let repo = try await makeRepo(remote: "https://github.com/nlopez/alas.git")
        defer { try? FileManager.default.removeItem(at: repo) }
        let svc = GitService()
        let name = try await svc.suggestProjectName(repo)
        #expect(name == "nlopez/alas")
    }

    @Test func suggestNameFromSshRemote() async throws {
        let repo = try await makeRepo(remote: "git@github.com:nlopez/git-gud.git")
        defer { try? FileManager.default.removeItem(at: repo) }
        let svc = GitService()
        let name = try await svc.suggestProjectName(repo)
        #expect(name == "nlopez/git-gud")
    }

    @Test func suggestNameFallsBackToFolder() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let svc = GitService()
        let name = try await svc.suggestProjectName(repo)
        #expect(name == repo.lastPathComponent)
    }

    @Test func parseBranchListCleansAndDeduplicatesBranches() {
        let branches = GitService.parseBranchList("""
        main
        release/1.2

        main
        origin/main
        * feature/current
        """)

        #expect(branches == ["main", "release/1.2", "origin/main", "feature/current"])
    }

    @Test func branchesIncludesLocalAndRemoteRefs() async throws {
        let repo = try await makeRepo()
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-remote-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }

        _ = try await Process.git(["checkout", "-q", "-b", "develop"], cwd: repo)
        _ = try await Process.git(["init", "--bare", "-q", remote.path], cwd: nil)
        _ = try await Process.git(["remote", "add", "origin", remote.path], cwd: repo)
        _ = try await Process.git(["push", "-q", "origin", "main:main"], cwd: repo)
        _ = try await Process.git(["push", "-q", "origin", "develop:release/remote-only"], cwd: repo)
        _ = try await Process.git(["fetch", "-q", "origin"], cwd: repo)

        let branches = try await GitService().branches(at: repo)

        #expect(branches.contains("main"))
        #expect(branches.contains("develop"))
        #expect(branches.contains("origin/main"))
        #expect(branches.contains("origin/release/remote-only"))
        #expect(branches.firstIndex(of: "develop")! < branches.firstIndex(of: "origin/main")!)
    }
}
