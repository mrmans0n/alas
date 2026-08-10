import Foundation
import Testing
@testable import Alas

struct GGStackGateTests {
    private func makeRepo(withGGConfig: Bool) throws -> String {
        let dir = NSTemporaryDirectory() + "gg-gate-" + UUID().uuidString
        let ggDir = dir + "/.git/gg"
        try FileManager.default.createDirectory(
            atPath: withGGConfig ? ggDir : dir + "/.git",
            withIntermediateDirectories: true
        )
        if withGGConfig {
            FileManager.default.createFile(atPath: ggDir + "/config.json", contents: Data("{}".utf8))
        }
        return dir
    }

    /// Builds a primary checkout with a real `.git` directory (optionally
    /// carrying gg config) plus a linked worktree whose `.git` is a *file*
    /// pointing at a private per-worktree dir under
    /// `<main>/.git/worktrees/<name>`, itself carrying a `commondir` file
    /// that points back to `<main>/.git` — mirroring real `git worktree add`
    /// output. Returns (mainRepoPath, linkedWorktreePath).
    private func makeRepoWithLinkedWorktree(withGGConfig: Bool) throws -> (main: String, linked: String) {
        let main = try makeRepo(withGGConfig: withGGConfig)
        let linked = NSTemporaryDirectory() + "gg-gate-linked-" + UUID().uuidString
        let privateGitDir = main + "/.git/worktrees/feature"
        try FileManager.default.createDirectory(atPath: privateGitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: linked, withIntermediateDirectories: true)
        try "../..".write(toFile: privateGitDir + "/commondir", atomically: true, encoding: .utf8)
        try "gitdir: \(privateGitDir)".write(toFile: linked + "/.git", atomically: true, encoding: .utf8)
        return (main, linked)
    }

    private func commit(body: String) -> CommitInfo {
        CommitInfo(
            sha: String(repeating: "a", count: 40), shortSha: "aaaaaaa",
            author: "Test", authorInitials: "T", date: Date(),
            subject: "subject", body: body, conventionalTag: nil,
            filesChanged: 1, insertions: 1, deletions: 0
        )
    }

    @Test func detectsGGConfigFile() throws {
        #expect(GGStackGate.repoHasGGConfig(repoPath: try makeRepo(withGGConfig: true)))
        #expect(!GGStackGate.repoHasGGConfig(repoPath: try makeRepo(withGGConfig: false)))
    }

    @Test func projectEnabledMatrix() throws {
        let ggRepo = try makeRepo(withGGConfig: true)
        let plainRepo = try makeRepo(withGGConfig: false)
        // Master off / gg missing kill everything.
        #expect(!GGStackGate.projectEnabled(
            masterEnabled: false, ggInstalled: true, mode: .on, repoPath: ggRepo, isRemoteProject: false
        ))
        #expect(!GGStackGate.projectEnabled(
            masterEnabled: true, ggInstalled: false, mode: .on, repoPath: ggRepo, isRemoteProject: false
        ))
        // off always hides; on always allows; auto follows the config file.
        #expect(!GGStackGate.projectEnabled(
            masterEnabled: true, ggInstalled: true, mode: .off, repoPath: ggRepo, isRemoteProject: false
        ))
        #expect(GGStackGate.projectEnabled(
            masterEnabled: true, ggInstalled: true, mode: .on, repoPath: plainRepo, isRemoteProject: false
        ))
        #expect(GGStackGate.projectEnabled(
            masterEnabled: true, ggInstalled: true, mode: .auto, repoPath: ggRepo, isRemoteProject: false
        ))
        #expect(!GGStackGate.projectEnabled(
            masterEnabled: true, ggInstalled: true, mode: .auto, repoPath: plainRepo, isRemoteProject: false
        ))
    }

    /// gg's runner is local-only, unlike git's own process wrapper, which
    /// rewrites invocations to SSH for registered remote hosts. A remote
    /// project must never enable gg, regardless of mode.
    @Test func remoteProjectIsAlwaysDisabledRegardlessOfMode() throws {
        let ggRepo = try makeRepo(withGGConfig: true)
        for mode: GGProjectMode in [.off, .auto, .on] {
            #expect(!GGStackGate.projectEnabled(
                masterEnabled: true, ggInstalled: true, mode: mode, repoPath: ggRepo, isRemoteProject: true
            ))
        }
    }

    @Test func detectsGGConfigThroughLinkedWorktreeCommonDir() throws {
        let (mainWithConfig, linkedWithConfig) = try makeRepoWithLinkedWorktree(withGGConfig: true)
        #expect(GGStackGate.repoHasGGConfig(repoPath: mainWithConfig))
        #expect(GGStackGate.repoHasGGConfig(repoPath: linkedWithConfig))

        let (_, linkedWithoutConfig) = try makeRepoWithLinkedWorktree(withGGConfig: false)
        #expect(!GGStackGate.repoHasGGConfig(repoPath: linkedWithoutConfig))
    }

    @Test func stackShapeRequiresGGIDTrailer() {
        let stacked = commit(body: "Some detail.\n\nGG-ID: abc123\nGG-Parent: def456")
        let plain = commit(body: "Just a normal body mentioning GG-ID: in prose? No — mid-line doesn't count.")
        #expect(GGStackGate.isStackShaped(commits: [plain, stacked]))
        #expect(!GGStackGate.isStackShaped(commits: [plain]))
        #expect(!GGStackGate.isStackShaped(commits: []))
    }

    @Test func extractsFirstValidGGIDTrailerValue() {
        let body = "Details.\n\n  GG-ID:   c-first   \nGG-ID: c-second"

        #expect(GGCommitMetadata.ggID(in: body) == "c-first")
    }

    @Test func rejectsInvalidGGIDTrailerCandidates() {
        #expect(GGCommitMetadata.ggID(in: "mentions GG-ID: inline") == nil)
        #expect(GGCommitMetadata.ggID(in: "GG-ID:   ") == nil)
        #expect(GGCommitMetadata.ggID(in: "gg-id: c-lowercase") == nil)
        #expect(GGCommitMetadata.ggID(in: "") == nil)
    }

    @Test func emptyGGIDTrailerDoesNotMakeCommitStackShaped() {
        #expect(!GGStackGate.isStackShaped(commits: [commit(body: "GG-ID:   ")]))
    }

    private func makeRepo(rebaseInProgress: Bool) throws -> String {
        let dir = NSTemporaryDirectory() + "gg-op-" + UUID().uuidString
        let gitDir = dir + "/.git"
        try FileManager.default.createDirectory(atPath: gitDir, withIntermediateDirectories: true)
        if rebaseInProgress {
            try FileManager.default.createDirectory(atPath: gitDir + "/rebase-merge", withIntermediateDirectories: true)
        }
        return dir
    }

    @Test func detectsRebaseInProgress() throws {
        #expect(GGStackGate.operationInProgress(repoPath: try makeRepo(rebaseInProgress: true)))
        #expect(!GGStackGate.operationInProgress(repoPath: try makeRepo(rebaseInProgress: false)))
    }

    @Test func detectsMergeInProgressViaHeadFile() throws {
        let dir = NSTemporaryDirectory() + "gg-op-merge-" + UUID().uuidString
        let gitDir = dir + "/.git"
        try FileManager.default.createDirectory(atPath: gitDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: gitDir + "/MERGE_HEAD", contents: Data("sha\n".utf8))
        #expect(GGStackGate.operationInProgress(repoPath: dir))
    }

    /// The paused-operation markers live in the *private* per-worktree git
    /// dir, not the dir shared across worktrees. Drop a `rebase-merge`
    /// marker only under the linked worktree's private dir
    /// (`main/.git/worktrees/feature/rebase-merge`) and confirm the linked
    /// worktree reports mid-rebase while the primary checkout — whose own
    /// `.git` never held the marker — does not. A regression that swapped
    /// in `commonGitDir` (which resolves the linked worktree through to
    /// `main/.git`) would make `operationInProgress(linked)` wrongly return
    /// `false` here.
    @Test func detectsRebaseInProgressOnlyInLinkedWorktreePrivateDir() throws {
        let (main, linked) = try makeRepoWithLinkedWorktree(withGGConfig: false)
        let privateGitDir = main + "/.git/worktrees/feature"
        try FileManager.default.createDirectory(
            atPath: privateGitDir + "/rebase-merge", withIntermediateDirectories: true
        )
        #expect(GGStackGate.operationInProgress(repoPath: linked))
        #expect(!GGStackGate.operationInProgress(repoPath: main))
    }
}
