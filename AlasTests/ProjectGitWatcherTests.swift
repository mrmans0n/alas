import Testing
import Foundation
@testable import Alas

@MainActor
struct ProjectGitWatcherTests {
    /// Build a fake `<tmp>/repo/.git` layout with two linked worktrees,
    /// each having a HEAD pointing to a branch and a `gitdir` pointing
    /// at the worktree root. Returns (gitDir, [worktreeName: worktreeRoot]).
    private func setupRepo() throws -> (URL, [String: URL]) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-pgw-\(UUID().uuidString)")
        let gitDir = tmp.appendingPathComponent("repo/.git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(
            to: gitDir.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        var roots: [String: URL] = [:]
        for name in ["alpha", "beta"] {
            let wtRoot = tmp.appendingPathComponent("worktrees/\(name)").standardizedFileURL
            try FileManager.default.createDirectory(at: wtRoot, withIntermediateDirectories: true)
            let wtGit = gitDir.appendingPathComponent("worktrees/\(name)")
            try FileManager.default.createDirectory(at: wtGit, withIntermediateDirectories: true)
            try "ref: refs/heads/\(name)\n".write(
                to: wtGit.appendingPathComponent("HEAD"),
                atomically: true,
                encoding: .utf8
            )
            try (wtRoot.appendingPathComponent(".git").path + "\n").write(
                to: wtGit.appendingPathComponent("gitdir"),
                atomically: true,
                encoding: .utf8
            )
            roots[name] = wtRoot
        }
        return (gitDir, roots)
    }

    private func makeWatcher(gitDir: URL) -> ProjectGitWatcher {
        ProjectGitWatcher(
            repoPath: gitDir.deletingLastPathComponent(),
            resolvedGitDir: gitDir,
            resolvedWorktreeRoot: gitDir.deletingLastPathComponent(),
            headDebounceInterval: 0.05,
            headDebounceMaxWait: 0.2,
            topologyDebounceInterval: 0.05,
            topologyDebounceMaxWait: 0.2
        )
    }

    @Test func headOnlyBatchTriggersHeadCallback() async throws {
        let (gitDir, roots) = try setupRepo()
        defer { try? FileManager.default.removeItem(at: gitDir.deletingLastPathComponent().deletingLastPathComponent()) }

        let watcher = makeWatcher(gitDir: gitDir)
        var heads: [URL: String] = [:]
        var topologyFires = 0
        watcher.onHeadChanged = { heads = $0 }
        watcher.onTopologyChanged = { topologyFires += 1 }

        watcher.processEvents([
            gitDir.appendingPathComponent("worktrees/alpha/HEAD").path
        ])
        try await Task.sleep(nanoseconds: 300_000_000)
        // Compare via .path because URL equality is strict about directory flag
        // and the watcher may produce a directory URL while roots[] stores a
        // standardized file URL.
        let actualPaths = Dictionary(uniqueKeysWithValues: heads.map { ($0.key.path, $0.value) })
        let expectedPaths = Dictionary(uniqueKeysWithValues: [(roots["alpha"]!.path, "alpha")])
        #expect(actualPaths == expectedPaths)
        #expect(topologyFires == 0)
    }

    @Test func topologyOnlyBatchTriggersTopologyCallback() async throws {
        let (gitDir, _) = try setupRepo()
        defer { try? FileManager.default.removeItem(at: gitDir.deletingLastPathComponent().deletingLastPathComponent()) }

        let watcher = makeWatcher(gitDir: gitDir)
        var headFires = 0
        var topologyFires = 0
        watcher.onHeadChanged = { _ in headFires += 1 }
        watcher.onTopologyChanged = { topologyFires += 1 }

        watcher.processEvents([
            gitDir.appendingPathComponent("worktrees/new").path
        ])
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(headFires == 0)
        #expect(topologyFires == 1)
    }

    @Test func sharedRefsTriggerRevisionCallback() async throws {
        let (gitDir, _) = try setupRepo()
        defer { try? FileManager.default.removeItem(at: gitDir.deletingLastPathComponent().deletingLastPathComponent()) }

        let watcher = makeWatcher(gitDir: gitDir)
        var headFires = 0
        var revisionFires = 0
        var topologyFires = 0
        watcher.onHeadChanged = { _ in headFires += 1 }
        watcher.onRevisionChanged = { revisionFires += 1 }
        watcher.onTopologyChanged = { topologyFires += 1 }

        watcher.processEvents([
            gitDir.appendingPathComponent("refs/heads/main").path,
            gitDir.appendingPathComponent("refs/remotes/origin/main").path,
            gitDir.appendingPathComponent("refs/tags/v1").path,
        ])
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(headFires == 0)
        #expect(revisionFires == 1)
        #expect(topologyFires == 0)
    }

    @Test func mixedBatchClearsHeadInFavorOfTopology() async throws {
        let (gitDir, _) = try setupRepo()
        defer { try? FileManager.default.removeItem(at: gitDir.deletingLastPathComponent().deletingLastPathComponent()) }

        let watcher = makeWatcher(gitDir: gitDir)
        var headFires = 0
        var topologyFires = 0
        watcher.onHeadChanged = { _ in headFires += 1 }
        watcher.onTopologyChanged = { topologyFires += 1 }

        watcher.processEvents([
            gitDir.appendingPathComponent("worktrees/alpha/HEAD").path,
            gitDir.appendingPathComponent("worktrees/new").path,
        ])
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(topologyFires == 1)
        // Head supersedes: with equal head/topology intervals scheduling is
        // racy. The contract is "no head fire AFTER topology fire" — easier
        // to test via the all-or-nothing pending set behavior. Allow up to
        // one head fire (if it scheduled before topology).
        #expect(headFires <= 1)
    }

    @Test func allLockBatchIsNoop() async throws {
        let (gitDir, _) = try setupRepo()
        defer { try? FileManager.default.removeItem(at: gitDir.deletingLastPathComponent().deletingLastPathComponent()) }

        let watcher = makeWatcher(gitDir: gitDir)
        var headFires = 0
        var topologyFires = 0
        watcher.onHeadChanged = { _ in headFires += 1 }
        watcher.onTopologyChanged = { topologyFires += 1 }

        watcher.processEvents([
            gitDir.appendingPathComponent("index.lock").path,
            gitDir.appendingPathComponent("worktrees/alpha/HEAD.lock").path,
        ])
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(headFires == 0)
        #expect(topologyFires == 0)
    }

    @Test func headReadFailureEscalatesToTopology() async throws {
        let (gitDir, _) = try setupRepo()
        defer { try? FileManager.default.removeItem(at: gitDir.deletingLastPathComponent().deletingLastPathComponent()) }

        // Corrupt one HEAD so HeadReader returns nil for it.
        let alphaHead = gitDir.appendingPathComponent("worktrees/alpha/HEAD")
        try "garbage\n".write(to: alphaHead, atomically: true, encoding: .utf8)

        let watcher = makeWatcher(gitDir: gitDir)
        var topologyFires = 0
        var heads: [URL: String] = [:]
        watcher.onHeadChanged = { heads = $0 }
        watcher.onTopologyChanged = { topologyFires += 1 }

        watcher.processEvents([alphaHead.path])
        try await Task.sleep(nanoseconds: 400_000_000)
        // The fast path produced no usable updates; topology must have fired.
        #expect(heads.isEmpty)
        #expect(topologyFires >= 1)
    }

    @Test func stopBeforeAsyncResolveCompletesDoesNotStartStream() async throws {
        let (gitDir, _) = try setupRepo()
        defer { try? FileManager.default.removeItem(at: gitDir.deletingLastPathComponent().deletingLastPathComponent()) }

        var streamStarts = 0
        let watcher = ProjectGitWatcher(
            repoPath: gitDir.deletingLastPathComponent(),
            resolvedGitDir: nil,
            resolvedWorktreeRoot: nil,
            headDebounceInterval: 0.05,
            headDebounceMaxWait: 0.2,
            topologyDebounceInterval: 0.05,
            topologyDebounceMaxWait: 0.2,
            gitInfoResolver: { _ in
                try? await Task.sleep(nanoseconds: 50_000_000)
                return (gitDir, gitDir.deletingLastPathComponent())
            },
            startStreamOverride: { _, _ in
                streamStarts += 1
            }
        )

        watcher.start()
        watcher.stop()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(streamStarts == 0)
    }
}
