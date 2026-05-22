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

    @Test func suggestNameUsesDirectoryName() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let svc = GitService()
        let name = try await svc.suggestProjectName(repo)
        #expect(name == repo.lastPathComponent)
    }

    @Test func suggestNameIgnoresOriginRemote() async throws {
        let repo = try await makeRepo(remote: "https://github.com/nlopez/a-longer-remote-name.git")
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

    @Test func fileTreeIncludesIgnoredAndExcludedRootEntries() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try "ignored-root/\n".write(
            to: repo.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("ignored-root"), withIntermediateDirectories: true)
        try "cache\n".write(to: repo.appendingPathComponent("ignored-root/cache.txt"), atomically: true, encoding: .utf8)

        let exclude = repo.appendingPathComponent(".git/info/exclude")
        try "excluded-root/\n".write(to: exclude, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("excluded-root"), withIntermediateDirectories: true)
        try "local\n".write(to: repo.appendingPathComponent("excluded-root/local.txt"), atomically: true, encoding: .utf8)

        try "tracked\n".write(to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", ".gitignore", "tracked.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)

        let tree = try await GitService().fileTree(worktreePath: repo, statusEntries: [])

        let ignored = try #require(tree.first { $0.path == "ignored-root" })
        #expect(ignored.visibility == .ignored)
        #expect(ignored.childrenState == .notLoaded)
        #expect(ignored.children == nil)

        let excluded = try #require(tree.first { $0.path == "excluded-root" })
        #expect(excluded.visibility == .excluded)
        #expect(excluded.childrenState == .notLoaded)

        let tracked = try #require(tree.first { $0.path == "tracked.txt" })
        #expect(tracked.visibility == .tracked)
    }

    @Test func fileTreeClassifiesGlobalExcludesAsExcludedRootEntries() async throws {
        let repo = try await makeRepo()
        let globalExcludes = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-global-excludes-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: globalExcludes)
        }

        try "global-cache/\n".write(to: globalExcludes, atomically: true, encoding: .utf8)
        _ = try await Process.git(["config", "core.excludesfile", globalExcludes.path], cwd: repo)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("global-cache"), withIntermediateDirectories: true)
        try "cache\n".write(to: repo.appendingPathComponent("global-cache/cache.txt"), atomically: true, encoding: .utf8)

        let tree = try await GitService().fileTree(worktreePath: repo, statusEntries: [])

        let excluded = try #require(tree.first { $0.path == "global-cache" })
        #expect(excluded.visibility == .excluded)
        #expect(excluded.childrenState == .notLoaded)
        #expect(excluded.children == nil)
    }

    @Test func fileTreeClassifiesLinkedWorktreeInfoExcludeAsExcluded() async throws {
        let repo = try await makeRepo()
        let linked = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-linked-worktree-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: linked)
            try? FileManager.default.removeItem(at: repo)
        }

        _ = try await Process.git(["worktree", "add", "-q", "-b", "linked-test", linked.path], cwd: repo)
        let excludeResult = try await Process.git(["rev-parse", "--git-path", "info/exclude"], cwd: linked)
        let excludePath = excludeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let exclude = excludePath.hasPrefix("/")
            ? URL(fileURLWithPath: excludePath)
            : linked.appendingPathComponent(excludePath)

        try "linked-excluded/\n".write(to: exclude, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: linked.appendingPathComponent("linked-excluded"), withIntermediateDirectories: true)
        try "local\n".write(to: linked.appendingPathComponent("linked-excluded/local.txt"), atomically: true, encoding: .utf8)

        let tree = try await GitService().fileTree(worktreePath: linked, statusEntries: [])

        let excluded = try #require(tree.first { $0.path == "linked-excluded" })
        #expect(excluded.visibility == .excluded)
        #expect(excluded.childrenState == .notLoaded)
        #expect(excluded.children == nil)
    }

    @Test func fileTreeDoesNotMarkNegatedIgnoredRootDirectoryAsIgnored() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try "ignored-root/\n!ignored-root/\n".write(
            to: repo.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("ignored-root"), withIntermediateDirectories: true)
        try "tracked\n".write(to: repo.appendingPathComponent("ignored-root/keep.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", ".gitignore"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)

        let tree = try await GitService().fileTree(worktreePath: repo, statusEntries: [])

        let root = try #require(tree.first { $0.path == "ignored-root" })
        #expect(root.visibility == .tracked)
        #expect(root.children?.contains { $0.path == "ignored-root/keep.txt" } == true)
    }

    @Test func fileTreeKeepsTrackedChildrenLoadedInIgnoredRootDirectory() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try "generated/\n".write(
            to: repo.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("generated"), withIntermediateDirectories: true)
        try "tracked\n".write(to: repo.appendingPathComponent("generated/keep.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", ".gitignore"], cwd: repo)
        _ = try await Process.git(["add", "-f", "generated/keep.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)

        let tree = try await GitService().fileTree(worktreePath: repo, statusEntries: [])

        let generatedNodes = tree.filter { $0.path == "generated" }
        #expect(generatedNodes.count == 1)
        #expect(!tree.contains { $0.id == "file:generated" })
        let generated = try #require(generatedNodes.first)
        #expect(generated.kind == .dir)
        #expect(generated.visibility == .ignored)
        #expect(generated.childrenState == .loaded)
        #expect(generated.children?.contains { $0.path == "generated/keep.txt" } == true)
    }

    @Test func fileTreeKeepsTrackedChildrenLoadedInInfoExcludedRootDirectory() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let exclude = repo.appendingPathComponent(".git/info/exclude")
        try "local-generated/\n".write(to: exclude, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("local-generated"), withIntermediateDirectories: true)
        try "tracked\n".write(to: repo.appendingPathComponent("local-generated/keep.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "-f", "local-generated/keep.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)

        let tree = try await GitService().fileTree(worktreePath: repo, statusEntries: [])

        let generatedNodes = tree.filter { $0.path == "local-generated" }
        #expect(generatedNodes.count == 1)
        #expect(!tree.contains { $0.id == "file:local-generated" })
        let generated = try #require(generatedNodes.first)
        #expect(generated.kind == .dir)
        #expect(generated.visibility == .excluded)
        #expect(generated.childrenState == .loaded)
        #expect(generated.children?.contains { $0.path == "local-generated/keep.txt" } == true)
    }

    @Test func loadFileTreeChildrenLoadsOnlyImmediateIgnoredChildren() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try "ignored-root/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let nested = repo.appendingPathComponent("ignored-root/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "one\n".write(to: repo.appendingPathComponent("ignored-root/one.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: nested.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", ".gitignore"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)

        let children = try await GitService().fileTreeChildren(worktreePath: repo, path: "ignored-root")

        #expect(children.map(\.path).sorted() == ["ignored-root/nested", "ignored-root/one.txt"])
        #expect(children.first { $0.path == "ignored-root/one.txt" }?.visibility == .ignored)
        let nestedNode = children.first { $0.path == "ignored-root/nested" }!
        #expect(nestedNode.kind == .dir)
        #expect(nestedNode.childrenState == .notLoaded)
        #expect(nestedNode.children == nil)
    }

    @Test func fileTreeChildrenLoadsNestedIgnoredDirectoryChildren() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try "ignored-root/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let nested = repo.appendingPathComponent("ignored-root/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "two\n".write(to: nested.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", ".gitignore"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)

        let children = try await GitService().fileTreeChildren(worktreePath: repo, path: "ignored-root/nested")

        #expect(children.map(\.path) == ["ignored-root/nested/two.txt"])
        #expect(children.first?.visibility == .ignored)
    }

    @Test func fileTreeChildrenKeepsForceTrackedChildTrackedInsideIgnoredDirectory() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try "generated/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("generated"), withIntermediateDirectories: true)
        try "tracked\n".write(to: repo.appendingPathComponent("generated/keep.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", ".gitignore"], cwd: repo)
        _ = try await Process.git(["add", "-f", "generated/keep.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)

        let children = try await GitService().fileTreeChildren(worktreePath: repo, path: "generated")

        let keep = try #require(children.first { $0.path == "generated/keep.txt" })
        #expect(keep.visibility == .tracked)
    }

    @Test func fileTreeChildrenKeepsIgnoredDirectoryAffordanceWhenItHasTrackedDescendants() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try "generated/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("generated/nested"), withIntermediateDirectories: true)
        try "tracked\n".write(to: repo.appendingPathComponent("generated/nested/keep.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", ".gitignore"], cwd: repo)
        _ = try await Process.git(["add", "-f", "generated/nested/keep.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)

        let generatedChildren = try await GitService().fileTreeChildren(worktreePath: repo, path: "generated")
        let nested = try #require(generatedChildren.first { $0.path == "generated/nested" })
        #expect(nested.visibility == .ignored)
        #expect(nested.childrenState == .notLoaded)

        let nestedChildren = try await GitService().fileTreeChildren(worktreePath: repo, path: "generated/nested")
        let keep = try #require(nestedChildren.first { $0.path == "generated/nested/keep.txt" })
        #expect(keep.visibility == .tracked)
    }

    @Test func fileTreeChildrenRevealsIgnoredChildInsideTrackedDirectory() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try "Sources/cache.log\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "tracked\n".write(to: repo.appendingPathComponent("Sources/App.swift"), atomically: true, encoding: .utf8)
        try "ignored\n".write(to: repo.appendingPathComponent("Sources/cache.log"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", ".gitignore", "Sources/App.swift"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repo)

        let children = try await GitService().fileTreeChildren(worktreePath: repo, path: "Sources")

        #expect(children.contains { $0.path == "Sources/App.swift" && $0.visibility == .tracked })
        #expect(children.contains { $0.path == "Sources/cache.log" && $0.visibility == .ignored })
    }

    @Test func submodulePathsDetectsRegisteredSubmodules() async throws {
        let repo = try await makeRepo()
        let submoduleRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alassubmodule-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: submoduleRepo)
        }
        try FileManager.default.createDirectory(at: submoduleRepo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: submoduleRepo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: submoduleRepo)
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleRepo.path, "Deps/Submodule"],
            cwd: repo
        )
        _ = try await Process.git(["commit", "-q", "-am", "add submodule"], cwd: repo)
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"],
            cwd: repo
        )

        let svc = GitService()
        let paths = try await svc.submodulePaths(worktreePath: repo)
        #expect(paths == ["Deps/Submodule"])
    }

    @Test func submodulePathsHandlesSpacedSubmodulePath() async throws {
        let repo = try await makeRepo()
        let submoduleRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-spaced-sub-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: submoduleRepo)
        }
        try FileManager.default.createDirectory(at: submoduleRepo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: submoduleRepo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: submoduleRepo)
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleRepo.path, "Deps/Space Name"],
            cwd: repo
        )
        _ = try await Process.git(["commit", "-q", "-am", "add submodule"], cwd: repo)
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"],
            cwd: repo
        )

        let svc = GitService()
        let paths = try await svc.submodulePaths(worktreePath: repo)
        #expect(paths == ["Deps/Space Name"])
    }

    @Test func submodulePathsHandlesDeletedSubmodule() async throws {
        let repo = try await makeRepo()
        let submoduleRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-deletedsub-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: submoduleRepo)
        }
        try FileManager.default.createDirectory(at: submoduleRepo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: submoduleRepo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: submoduleRepo)
        _ = try await Process.git(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleRepo.path, "Deps/Submodule"],
            cwd: repo
        )
        _ = try await Process.git(["commit", "-q", "-am", "add submodule"], cwd: repo)

        // Remove the submodule directory from disk without running submodule deinit
        try FileManager.default.removeItem(at: repo.appendingPathComponent("Deps/Submodule"))

        let svc = GitService()
        let paths = try await svc.submodulePaths(worktreePath: repo)
        #expect(paths == ["Deps/Submodule"])
    }

    private func makeRepoWithRemote() async throws -> (URL, URL) {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-revparse-\(UUID().uuidString)")
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-revparse-rmt-\(UUID().uuidString)")
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

    @Test func revParseHEADReturnsSHA() async throws {
        let (repo, remote) = try await makeRepoWithRemote()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
        }
        let svc = GitService()
        let sha = try await svc.revParseHEAD(worktreePath: repo)
        #expect(sha.count == 40)
    }
}
