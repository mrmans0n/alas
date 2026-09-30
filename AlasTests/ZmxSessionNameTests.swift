import Testing
@testable import Alas

@Suite
struct ZmxSessionNameTests {
    @Test
    func deriveIncludesStableWorktreeAndLeafScope() {
        let worktreeId = "/Users/nacho/.alas/.worktrees/alas/nacho-new-worktree-acp"
        let leafId = "61F2A8E0-2D9F-4B1F-9E5A-9C0B6C3F0F0F"
        #expect(ZmxSessionName.derive(worktreeId: worktreeId, leafId: leafId) == "alas-f07e6273132977f2-c9820693548f0fac")
    }

    @Test
    func sameLeafInDifferentWorktreesGetsDifferentName() {
        let leafId = "shared-leaf-id"
        let main = ZmxSessionName.derive(worktreeId: "/Volumes/Workspace/alas", leafId: leafId)
        let worktree = ZmxSessionName.derive(
            worktreeId: "/Users/nacho/.alas/.worktrees/alas/nacho-new-worktree-acp",
            leafId: leafId
        )
        #expect(main != worktree)
        #expect(main.hasPrefix("alas-"))
        #expect(worktree.hasPrefix("alas-"))
    }

    /// Remote sessions live on their own host, so the name hashes the real
    /// path and survives the move to virtual worktree ids.
    @Test
    func remoteWorktreeHashesItsRealPath() {
        #expect(
            ZmxSessionName.derive(worktreeId: "/.alas-remote/mini/srv/wt/a", leafId: "L")
                == ZmxSessionName.derive(worktreeId: "/srv/wt/a", leafId: "L")
        )
    }

    /// The orphan sweep must map a virtual known id to the hash of a
    /// session named from its real path, or leftover sessions leak.
    @Test
    func orphanSweepMatchesSessionNamedFromRealPath() {
        let name = ZmxSessionName.derive(worktreeId: "/srv/wt/a", leafId: "stale-leaf")
        let orphans = TerminalService.orphanSessionNames(
            allSessionNames: [name],
            knownWorktreeIdHashes: ZmxSessionName.worktreeHashes(["/.alas-remote/mini/srv/wt/a"]),
            knownLeafIdHashes: []
        )
        #expect(orphans == [name])
    }

    @Test
    func legacyNameKeepsPreScopedFormatForUpgradeFallback() {
        #expect(ZmxSessionName.legacy(leafId: "leaf-123") == "alas-leaf-123")
    }

    @Test
    func deriveDoesNotMutateInput() {
        let worktreeId = "/tmp/worktree"
        let leafId = "abc-123"
        _ = ZmxSessionName.derive(worktreeId: worktreeId, leafId: leafId)
        #expect(worktreeId == "/tmp/worktree")
        #expect(leafId == "abc-123")
    }
}
