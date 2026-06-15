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

    private func makeContextSnapshotRepo(withInitialCommit: Bool = true) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-context-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await gitOK(["init", "-q", "-b", "main"], cwd: dir)
        try await gitOK(["config", "user.email", "t@example.com"], cwd: dir)
        try await gitOK(["config", "user.name", "Test User"], cwd: dir)
        if withInitialCommit {
            try await gitOK(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        }
        return dir
    }

    @discardableResult
    private func gitOK(_ args: [String], cwd: URL) async throws -> ProcessResult {
        let result = try await Process.git(args, cwd: cwd)
        guard result.exitCode == 0 else {
            throw NSError(
                domain: "GitServiceTests.gitOK",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
        return result
    }

    private func writeText(_ text: String, _ path: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeData(_ data: Data, _ path: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
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

    @Test func contextSnapshotSeparatesStagedAndUnstagedRefs() async throws {
        let repo = try await makeContextSnapshotRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try writeText("base\n", "file.txt", in: repo)
        try await gitOK(["add", "file.txt"], cwd: repo)
        try await gitOK(["commit", "-q", "-m", "base"], cwd: repo)

        try writeText("staged\n", "file.txt", in: repo)
        try await gitOK(["add", "file.txt"], cwd: repo)
        try writeText("worktree\n", "file.txt", in: repo)

        let service = GitService()

        let staged = try await service.contextSnapshot(worktreePath: repo, file: "file.txt", staged: true)
        #expect(staged == DiffReviewFileContextSnapshot(
            old: .available(["base"]),
            new: .available(["staged"])
        ))

        let unstaged = try await service.contextSnapshot(worktreePath: repo, file: "file.txt", staged: false)
        #expect(unstaged == DiffReviewFileContextSnapshot(
            old: .available(["staged"]),
            new: .available(["worktree"])
        ))
    }

    @Test func contextSnapshotUsesEmptyOldSideForUnbornHeadStagedAdd() async throws {
        let repo = try await makeContextSnapshotRepo(withInitialCommit: false)
        defer { try? FileManager.default.removeItem(at: repo) }

        try writeText("new\n", "new.txt", in: repo)
        try await gitOK(["add", "new.txt"], cwd: repo)

        let snapshot = try await GitService().contextSnapshot(worktreePath: repo, file: "new.txt", staged: true)

        #expect(snapshot == DiffReviewFileContextSnapshot(
            old: .available([]),
            new: .available(["new"])
        ))
    }

    @Test func contextSnapshotHandlesAddsAndDeletes() async throws {
        let repo = try await makeContextSnapshotRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try writeText("delete me\n", "deleted.txt", in: repo)
        try await gitOK(["add", "deleted.txt"], cwd: repo)
        try await gitOK(["commit", "-q", "-m", "seed deleted file"], cwd: repo)

        try writeText("added\n", "added.txt", in: repo)
        try await gitOK(["add", "added.txt"], cwd: repo)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("deleted.txt"))

        let service = GitService()
        let added = try await service.contextSnapshot(worktreePath: repo, file: "added.txt", staged: true)
        #expect(added == DiffReviewFileContextSnapshot(
            old: .unavailable,
            new: .available(["added"])
        ))

        let deleted = try await service.contextSnapshot(worktreePath: repo, file: "deleted.txt", staged: false)
        #expect(deleted == DiffReviewFileContextSnapshot(
            old: .available(["delete me"]),
            new: .unavailable
        ))
    }

    @Test func contextSnapshotUsesOriginalPathForStagedRename() async throws {
        let repo = try await makeContextSnapshotRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try writeText("old\n", "old.swift", in: repo)
        try await gitOK(["add", "old.swift"], cwd: repo)
        try await gitOK(["commit", "-q", "-m", "seed rename"], cwd: repo)
        try await gitOK(["mv", "old.swift", "new.swift"], cwd: repo)
        try writeText("new\n", "new.swift", in: repo)
        try await gitOK(["add", "new.swift"], cwd: repo)

        let snapshot = try await GitService().contextSnapshot(
            worktreePath: repo,
            file: "new.swift",
            staged: true,
            originalPath: "old.swift"
        )

        #expect(snapshot == DiffReviewFileContextSnapshot(
            old: .available(["old"]),
            new: .available(["new"])
        ))
    }

    @Test func contextSnapshotReturnsUnavailableForBinaryAndInvalidUTF8() async throws {
        let repo = try await makeContextSnapshotRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try writeText("valid\n", "invalid.txt", in: repo)
        try await gitOK(["add", "invalid.txt"], cwd: repo)
        try await gitOK(["commit", "-q", "-m", "seed invalid"], cwd: repo)
        try writeData(Data([0xC3, 0x28]), "invalid.txt", in: repo)

        try writeData(Data([0x00, 0x01, 0x02]), "binary.dat", in: repo)
        try await gitOK(["add", "binary.dat"], cwd: repo)

        let service = GitService()
        let invalid = try await service.contextSnapshot(worktreePath: repo, file: "invalid.txt", staged: false)
        #expect(invalid == DiffReviewFileContextSnapshot(
            old: .available(["valid"]),
            new: .unavailable
        ))

        let binary = try await service.contextSnapshot(worktreePath: repo, file: "binary.dat", staged: true)
        #expect(binary == DiffReviewFileContextSnapshot(
            old: .unavailable,
            new: .unavailable
        ))
    }

    @Test func contextSnapshotDropsOnlyFinalTrailingEmptyLine() async throws {
        let repo = try await makeContextSnapshotRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try writeText("one\n\nthree\n", "lines.txt", in: repo)
        try await gitOK(["add", "lines.txt"], cwd: repo)

        let snapshot = try await GitService().contextSnapshot(worktreePath: repo, file: "lines.txt", staged: true)

        #expect(snapshot.new == .available(["one", "", "three"]))
    }

    @Test func contextSnapshotReadsUnstagedSymlinkAsLinkTarget() async throws {
        let repo = try await makeContextSnapshotRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try writeText("old target contents\n", "old-target.txt", in: repo)
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent("link.txt").path,
            withDestinationPath: "old-target.txt"
        )
        try await gitOK(["add", "old-target.txt", "link.txt"], cwd: repo)
        try await gitOK(["commit", "-q", "-m", "seed symlink"], cwd: repo)

        try FileManager.default.removeItem(at: repo.appendingPathComponent("link.txt"))
        try writeText("new target contents should not be read\n", "new-target.txt", in: repo)
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent("link.txt").path,
            withDestinationPath: "new-target.txt"
        )

        let snapshot = try await GitService().contextSnapshot(worktreePath: repo, file: "link.txt", staged: false)

        #expect(snapshot == DiffReviewFileContextSnapshot(
            old: .available(["old-target.txt"]),
            new: .available(["new-target.txt"])
        ))
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
