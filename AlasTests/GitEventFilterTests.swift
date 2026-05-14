import Testing
import Foundation
@testable import Alas

struct GitEventFilterTests {
    private let gitDir = URL(fileURLWithPath: "/repo/.git")

    @Test func ignoresLockFilesAnywhereUnderGitDir() {
        let cases = [
            "/repo/.git/index.lock",
            "/repo/.git/HEAD.lock",
            "/repo/.git/worktrees/feat/HEAD.lock",
            "/repo/.git/refs/heads/main.lock",
        ]
        for path in cases {
            let cat = GitEventFilter.classify(eventPath: path, gitDir: gitDir)
            #expect(cat == .ignored, "expected .ignored for \(path), got \(cat)")
        }
    }

    @Test func classifiesMainWorktreeHEAD() {
        let cat = GitEventFilter.classify(eventPath: "/repo/.git/HEAD", gitDir: gitDir)
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
            gitDir: repoGit
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
            let cat = GitEventFilter.classify(eventPath: path, gitDir: gitDir)
            #expect(cat == .topologyChange, "expected .topologyChange for \(path), got \(cat)")
        }
    }

    @Test func ignoresUnrelatedPathsUnderGitDir() {
        let cases = [
            "/repo/.git/objects/pack/pack-abc.pack",
            "/repo/.git/refs/heads/main",
            "/repo/.git/config",
            "/repo/.git/worktrees/feat/locked",
        ]
        for path in cases {
            let cat = GitEventFilter.classify(eventPath: path, gitDir: gitDir)
            #expect(cat == .other, "expected .other for \(path), got \(cat)")
        }
    }

    @Test func ignoresPathsOutsideGitDir() {
        let cat = GitEventFilter.classify(
            eventPath: "/repo/src/main.swift",
            gitDir: gitDir
        )
        #expect(cat == .other)
    }
}
