import Foundation
import Testing
@testable import Alas

@MainActor
struct RightPaneGGLandTests {
    private func entry(id: String, prState: GGPRState, approved: Bool, ci: GGCIStatus) -> GGStackEntry {
        GGStackEntry(position: 1, sha: "s", title: "t", ggId: id, prNumber: 5,
                     prState: prState, approved: approved, ciStatus: ci)
    }

    private func stack(_ entries: [GGStackEntry]) -> GGStack {
        GGStack(name: "feat", base: "main", totalCommits: entries.count, syncedCommits: entries.count,
                currentPosition: nil, behindBase: nil, entries: entries)
    }

    @Test func readyLandableWhenAnyEntryOpenApprovedGreen() {
        let wt = Worktree(id: "i", projectId: "p", name: "f", branch: "f",
                          path: URL(fileURLWithPath: "/tmp/x"), status: .clean, lastActivity: Date())
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        let landable = stack([entry(id: "a", prState: .open, approved: true, ci: .success)])
        #expect(state.ggLandTargetStillLandable(.ready, in: landable))
        let notLandable = stack([entry(id: "a", prState: .open, approved: false, ci: .success)])
        #expect(!state.ggLandTargetStillLandable(.ready, in: notLandable))
    }

    @Test func untilLandableWhenTargetEntryPresent() {
        let wt = Worktree(id: "i", projectId: "p", name: "f", branch: "f",
                          path: URL(fileURLWithPath: "/tmp/x"), status: .clean, lastActivity: Date())
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        let s = stack([entry(id: "a", prState: .open, approved: true, ci: .success)])
        #expect(state.ggLandTargetStillLandable(.until(entryId: "a", title: "t"), in: s))
        #expect(!state.ggLandTargetStillLandable(.until(entryId: "missing", title: "t"), in: s))
    }

    @Test func requestAndCancelSetAndClearPending() {
        let wt = Worktree(id: "i", projectId: "p", name: "f", branch: "f",
                          path: URL(fileURLWithPath: "/tmp/x"), status: .clean, lastActivity: Date())
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.requestGGLand(.ready)
        #expect(state.pendingGGLand == .ready)
        state.cancelGGLand()
        #expect(state.pendingGGLand == nil)
    }

    @Test func requestAndCancelCleanAllSetAndClearPending() {
        let wt = Worktree(id: "i", projectId: "p", name: "f", branch: "f",
                          path: URL(fileURLWithPath: "/tmp/x"), status: .clean, lastActivity: Date())
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.requestGGCleanAll()
        #expect(state.pendingGGCleanAll)
        state.cancelGGCleanAll()
        #expect(!state.pendingGGCleanAll)
    }
}
