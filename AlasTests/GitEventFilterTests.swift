import Testing
import Foundation
@testable import Alas

struct GitEventFilterTests {
    private let gitDir = URL(fileURLWithPath: "/repo/.git")
    private let worktreeRoot = URL(fileURLWithPath: "/repo")

    @Test func ignoresLockFilesAnywhereUnderGitDir() {
        let cases = [
            "/repo/.git/index.lock",
            "/repo/.git/HEAD.lock",
            "/repo/.git/worktrees/feat/HEAD.lock",
            "/repo/.git/refs/heads/main.lock",
        ]
        for path in cases {
            let cat = GitEventFilter.classify(eventPath: path, gitDir: gitDir, worktreeRoot: worktreeRoot)
            #expect(cat == .ignored, "expected .ignored for \(path), got \(cat)")
        }
    }

    @Test func classifiesMainWorktreeHEAD() {
        let cat = GitEventFilter.classify(eventPath: "/repo/.git/HEAD", gitDir: gitDir, worktreeRoot: worktreeRoot)
        #expect(cat == .headChange(URL(fileURLWithPath: "/repo")))
    }

    @Test func classifiesLinkedWorktreeHEADUsingGitdirFile() throws {
        // Set up a fake linked-worktree layout on disk so the classifier can
        // resolve the worktree root via .git/worktrees/<name>/gitdir.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-test-\(UUID().uuidString)")
        let repoGit = tmp.appendingPathComponent("repo/.git")
        let wtDir = repoGit.appendingPathComponent("worktrees/feat")
        try FileManager.default.createDirectory(at: wtDir, withIntermediateDirectories: true)
        let worktreeRoot = tmp.appendingPathComponent("worktrees/feat")
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let gitdirContent = worktreeRoot.appendingPathComponent(".git").path + "\n"
        try gitdirContent.write(
            to: wtDir.appendingPathComponent("gitdir"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cat = GitEventFilter.classify(
            eventPath: wtDir.appendingPathComponent("HEAD").path,
            gitDir: repoGit,
            worktreeRoot: tmp.appendingPathComponent("repo")
        )
        #expect(cat == .headChange(worktreeRoot.standardizedFileURL))
    }

    @Test func classifiesWorktreesDirectoryAsTopology() {
        let cases = [
            "/repo/.git/worktrees",
            "/repo/.git/worktrees/feat",
            "/repo/.git/worktrees/feat/",
        ]
        for path in cases {
            let cat = GitEventFilter.classify(eventPath: path, gitDir: gitDir, worktreeRoot: worktreeRoot)
            #expect(cat == .topologyChange, "expected .topologyChange for \(path), got \(cat)")
        }
    }

    @Test func ignoresUnrelatedPathsUnderGitDir() {
        let cases = [
            "/repo/.git/objects/pack/pack-abc.pack",
            "/repo/.git/worktrees/feat/locked",
        ]
        for path in cases {
            let cat = GitEventFilter.classify(eventPath: path, gitDir: gitDir, worktreeRoot: worktreeRoot)
            #expect(cat == .other, "expected .other for \(path), got \(cat)")
        }
    }

    @Test func branchRefUpdateIsRevisionAndTopology() {
        #expect(GitEventFilter.classify(
            eventPath: "/repo/.git/refs/heads/main",
            gitDir: gitDir,
            worktreeRoot: worktreeRoot
        ) == .revisionAndTopologyChange)
        #expect(GitEventFilter.classify(
            eventPath: "/repo/.git/refs/heads/feature/foo",
            gitDir: gitDir,
            worktreeRoot: worktreeRoot
        ) == .revisionAndTopologyChange)
    }

    @Test func packedRefsUpdateIsRevisionAndTopologyChange() {
        #expect(GitEventFilter.classify(
            eventPath: "/repo/.git/packed-refs",
            gitDir: gitDir,
            worktreeRoot: worktreeRoot
        ) == .revisionAndTopologyChange)
    }

    @Test func configUpdateIsRevisionChange() {
        #expect(GitEventFilter.classify(
            eventPath: "/repo/.git/config",
            gitDir: gitDir,
            worktreeRoot: worktreeRoot
        ) == .revisionChange)
        #expect(GitEventFilter.classify(
            eventPath: "/repo/.git/config.worktree",
            gitDir: gitDir,
            worktreeRoot: worktreeRoot
        ) == .revisionChange)
    }

    @Test func shallowBoundaryUpdateIsRevisionChange() {
        #expect(GitEventFilter.classify(
            eventPath: "/repo/.git/shallow",
            gitDir: gitDir,
            worktreeRoot: worktreeRoot
        ) == .revisionChange)
    }

    @Test func graftAncestryUpdateIsRevisionChange() {
        #expect(GitEventFilter.classify(
            eventPath: "/repo/.git/info/grafts",
            gitDir: gitDir,
            worktreeRoot: worktreeRoot
        ) == .revisionChange)
    }

    @Test func alternateObjectDatabaseUpdateIsRevisionChange() {
        #expect(GitEventFilter.classify(
            eventPath: "/repo/.git/objects/info/alternates",
            gitDir: gitDir,
            worktreeRoot: worktreeRoot
        ) == .revisionChange)
    }

    @Test func reflogUpdatesAreRevisionChanges() {
        let cases = [
            "/repo/.git/logs/HEAD",
            "/repo/.git/logs/refs/heads/main",
            "/repo/.git/logs/refs/tags/v1",
        ]
        for path in cases {
            #expect(GitEventFilter.classify(
                eventPath: path,
                gitDir: gitDir,
                worktreeRoot: worktreeRoot
            ) == .revisionChange)
        }
    }

    @Test func pseudoRefsAcceptedByRevisionResolverAreRevisionChanges() {
        let cases = [
            "FETCH_HEAD",
            "REBASE_HEAD",
            "MERGE_HEAD",
            "CHERRY_PICK_HEAD",
            "REVERT_HEAD",
            "ORIG_HEAD",
            "AUTO_MERGE",
        ]
        for ref in cases {
            #expect(GitEventFilter.classify(
                eventPath: "/repo/.git/\(ref)",
                gitDir: gitDir,
                worktreeRoot: worktreeRoot
            ) == .revisionChange)
        }
    }

    @Test func topLevelSymbolicRevisionIsRevisionChange() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-symbolic-ref-\(UUID().uuidString)")
        let gitDir = tmp.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let symbolicRef = gitDir.appendingPathComponent("FOO")
        try "ref: refs/heads/main\n".write(to: symbolicRef, atomically: true, encoding: .utf8)
        let directRef = gitDir.appendingPathComponent("DIRECT")
        try "0123456789abcdef0123456789abcdef01234567\n".write(to: directRef, atomically: true, encoding: .utf8)
        let nonRef = gitDir.appendingPathComponent("BAR")
        try "not a ref\n".write(to: nonRef, atomically: true, encoding: .utf8)
        let deletedSymbolicRef = gitDir.appendingPathComponent("DELETED_FOO")

        #expect(GitEventFilter.classify(
            eventPath: symbolicRef.path,
            gitDir: gitDir,
            worktreeRoot: tmp
        ) == .revisionChange)
        #expect(GitEventFilter.classify(
            eventPath: directRef.path,
            gitDir: gitDir,
            worktreeRoot: tmp
        ) == .revisionChange)
        #expect(GitEventFilter.classify(
            eventPath: nonRef.path,
            gitDir: gitDir,
            worktreeRoot: tmp
        ) == .other)
        #expect(GitEventFilter.classify(
            eventPath: deletedSymbolicRef.path,
            gitDir: gitDir,
            worktreeRoot: tmp
        ) == .revisionChange)
        #expect(GitEventFilter.classify(
            eventPath: gitDir.appendingPathComponent("index").path,
            gitDir: gitDir,
            worktreeRoot: tmp
        ) == .other)
    }

    @Test func linkedWorktreePseudoRefsAreRevisionChanges() {
        #expect(GitEventFilter.classify(
            eventPath: "/repo/.git/worktrees/feat/REBASE_HEAD",
            gitDir: gitDir,
            worktreeRoot: worktreeRoot
        ) == .revisionChange)
        #expect(GitEventFilter.classify(
            eventPath: "/repo/.git/worktrees/feat/FETCH_HEAD",
            gitDir: gitDir,
            worktreeRoot: worktreeRoot
        ) == .revisionChange)
    }

    @Test func linkedWorktreeConfigAndReflogsAreRevisionChanges() {
        let cases = [
            "/repo/.git/worktrees/feat/config.worktree",
            "/repo/.git/worktrees/feat/logs/HEAD",
            "/repo/.git/worktrees/feat/logs/refs/heads/topic",
        ]
        for path in cases {
            #expect(GitEventFilter.classify(
                eventPath: path,
                gitDir: gitDir,
                worktreeRoot: worktreeRoot
            ) == .revisionChange)
        }
    }

    @Test func linkedWorktreePrivateRefsAreRevisionChanges() {
        let cases = [
            "/repo/.git/worktrees/feat/refs/worktree/follow",
            "/repo/.git/worktrees/feat/refs/bisect/good-abc",
            "/repo/.git/worktrees/feat/refs/rewritten/main",
        ]
        for path in cases {
            #expect(GitEventFilter.classify(
                eventPath: path,
                gitDir: gitDir,
                worktreeRoot: worktreeRoot
            ) == .revisionChange)
        }
    }

    @Test func refsTagsAreRevisionChangesOnly() {
        #expect(GitEventFilter.classify(
            eventPath: "/repo/.git/refs/tags/v1",
            gitDir: gitDir,
            worktreeRoot: worktreeRoot
        ) == .revisionChange)
    }

    @Test func ignoresPathsOutsideGitDir() {
        let cat = GitEventFilter.classify(
            eventPath: "/repo/src/main.swift",
            gitDir: gitDir,
            worktreeRoot: worktreeRoot
        )
        #expect(cat == .other)
    }

    @Test func mainHEADResolvesToWorktreeRootEvenWhenGitDirIsOutside() {
        // Submodule case: gitDir is /super/.git/modules/sub, worktree is /sub
        let gitDir = URL(fileURLWithPath: "/super/.git/modules/sub")
        let worktreeRoot = URL(fileURLWithPath: "/sub")
        let cat = GitEventFilter.classify(
            eventPath: "/super/.git/modules/sub/HEAD",
            gitDir: gitDir,
            worktreeRoot: worktreeRoot
        )
        #expect(cat == .headChange(worktreeRoot.standardizedFileURL))
    }
}
