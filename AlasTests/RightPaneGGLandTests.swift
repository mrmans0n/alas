import Foundation
import Testing
@testable import Alas

@MainActor
struct RightPaneGGLandTests {
    private func entry(id: String, prState: GGPRState, approved: Bool, ci: GGCIStatus?) -> GGStackEntry {
        GGStackEntry(position: 1, sha: "s", title: "t", ggId: id, prNumber: 5,
                     prState: prState, approved: approved, ciStatus: ci)
    }

    private func entry(
        id: String,
        position: Int,
        prState: GGPRState,
        approved: Bool,
        ci: GGCIStatus?
    ) -> GGStackEntry {
        GGStackEntry(position: position, sha: "s\(position)", title: "t\(position)", ggId: id, prNumber: 5 + position,
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
        let landableWithoutCI = stack([entry(id: "a", prState: .open, approved: true, ci: nil)])
        #expect(state.ggLandTargetStillLandable(.ready, in: landableWithoutCI))
        let failingCI = stack([entry(id: "a", prState: .open, approved: true, ci: .failed)])
        #expect(!state.ggLandTargetStillLandable(.ready, in: failingCI))
        let notLandable = stack([entry(id: "a", prState: .open, approved: false, ci: .success)])
        #expect(!state.ggLandTargetStillLandable(.ready, in: notLandable))
    }

    @Test func readyRequiresContiguousBottomPrefix() {
        let wt = Worktree(id: "i", projectId: "p", name: "f", branch: "f",
                          path: URL(fileURLWithPath: "/tmp/x"), status: .clean, lastActivity: Date())
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        func positionedEntry(
            id: String,
            position: Int,
            prState: GGPRState,
            approved: Bool,
            ci: GGCIStatus?
        ) -> GGStackEntry {
            GGStackEntry(position: position, sha: "s\(position)", title: "t\(position)", ggId: id, prNumber: 5 + position,
                         prState: prState, approved: approved, ciStatus: ci)
        }

        let blockedBottom = stack([
            positionedEntry(id: "a", position: 1, prState: .open, approved: false, ci: .success),
            positionedEntry(id: "b", position: 2, prState: .open, approved: true, ci: .success),
        ])
        #expect(!state.ggLandTargetStillLandable(.ready, in: blockedBottom))

        let readyAfterMergedBottom = stack([
            positionedEntry(id: "a", position: 1, prState: .merged, approved: false, ci: .failed),
            positionedEntry(id: "b", position: 2, prState: .open, approved: true, ci: .success),
        ])
        #expect(state.ggLandTargetStillLandable(.ready, in: readyAfterMergedBottom))
        #expect(RightPaneState.ggLandReadyPrefix(in: readyAfterMergedBottom).map(\.id) == ["b"])
    }

    @Test func readyConfirmationCountsContiguousBottomPrefixOnly() {
        let message = RightPaneState.ggLandConfirmationMessage(
            for: .ready,
            stack: stack([
                GGStackEntry(position: 1, sha: "s1", title: "t1", ggId: "a", prNumber: 6,
                             prState: .open, approved: true, ciStatus: .success),
                GGStackEntry(position: 2, sha: "s2", title: "t2", ggId: "b", prNumber: 7,
                             prState: .open, approved: false, ciStatus: .success),
                GGStackEntry(position: 3, sha: "s3", title: "t3", ggId: "c", prNumber: 8,
                             prState: .open, approved: true, ciStatus: .success),
            ])
        )

        #expect(message == "Merge 1 approved, passing PR from the bottom of the stack.")
    }

    @Test func readyConfirmationCountsApprovedOpenEntriesWithNoCI() {
        let message = RightPaneState.ggLandConfirmationMessage(
            for: .ready,
            stack: stack([
                entry(id: "a", position: 1, prState: .open, approved: true, ci: .success),
                entry(id: "b", position: 2, prState: .open, approved: true, ci: nil),
                entry(id: "c", position: 3, prState: .open, approved: true, ci: .pending),
            ])
        )

        #expect(message == "Merge 2 approved, passing PRs from the bottom of the stack.")
    }

    @Test func readyLandUsesLastVerifiedPrefixEntryAsUntilTarget() {
        let s = stack([
            entry(id: "a", position: 1, prState: .open, approved: true, ci: .success),
            entry(id: "b", position: 2, prState: .open, approved: true, ci: nil),
            entry(id: "c", position: 3, prState: .open, approved: false, ci: .success),
        ])

        #expect(RightPaneState.ggLandUntilTarget(for: .ready, in: s) == "b")
    }

    @Test func untilLandUsesRequestedEntryAsUntilTarget() {
        let s = stack([
            entry(id: "a", position: 1, prState: .open, approved: true, ci: .success),
            entry(id: "b", position: 2, prState: .open, approved: true, ci: .success),
        ])

        #expect(RightPaneState.ggLandUntilTarget(for: .until(entryId: "b", title: "t2"), in: s) == "b")
    }

    @Test func landStackFingerprintTracksConfirmedStackIdentity() {
        let original = stack([
            GGStackEntry(position: 1, sha: "s1", title: "t1", ggId: "a", prNumber: 6,
                         prState: .open, approved: true, ciStatus: .success),
            GGStackEntry(position: 2, sha: "s2", title: "t2", ggId: "b", prNumber: 7,
                         prState: .open, approved: true, ciStatus: .success),
        ])
        let rebased = stack([
            GGStackEntry(position: 1, sha: "s1-rebased", title: "t1", ggId: "a", prNumber: 6,
                         prState: .open, approved: true, ciStatus: .success),
            GGStackEntry(position: 2, sha: "s2", title: "t2", ggId: "b", prNumber: 7,
                         prState: .open, approved: true, ciStatus: .success),
        ])
        let fingerprint = RightPaneState.ggLandStackFingerprint(original)

        #expect(RightPaneState.ggLandStackMatchesPendingConfirmation(original, fingerprint: fingerprint))
        #expect(!RightPaneState.ggLandStackMatchesPendingConfirmation(rebased, fingerprint: fingerprint))
        #expect(!RightPaneState.ggLandStackMatchesPendingConfirmation(original, fingerprint: nil))
    }

    @Test func untilLandableWhenTargetEntryPresent() {
        let wt = Worktree(id: "i", projectId: "p", name: "f", branch: "f",
                          path: URL(fileURLWithPath: "/tmp/x"), status: .clean, lastActivity: Date())
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        let s = stack([entry(id: "a", prState: .open, approved: true, ci: .success)])
        #expect(state.ggLandTargetStillLandable(.until(entryId: "a", title: "t"), in: s))
        #expect(!state.ggLandTargetStillLandable(.until(entryId: "missing", title: "t"), in: s))
    }

    @Test func untilRequiresReadyTargetEntry() {
        let wt = Worktree(id: "i", projectId: "p", name: "f", branch: "f",
                          path: URL(fileURLWithPath: "/tmp/x"), status: .clean, lastActivity: Date())
        let state = RightPaneState(worktree: wt, baseBranch: "main")

        #expect(!state.ggLandTargetStillLandable(
            .until(entryId: "a", title: "t"),
            in: stack([entry(id: "a", prState: .open, approved: false, ci: .success)])
        ))
        #expect(!state.ggLandTargetStillLandable(
            .until(entryId: "a", title: "t"),
            in: stack([entry(id: "a", prState: .draft, approved: true, ci: .success)])
        ))
        #expect(!state.ggLandTargetStillLandable(
            .until(entryId: "a", title: "t"),
            in: stack([entry(id: "a", prState: .open, approved: true, ci: .failed)])
        ))
        #expect(state.ggLandTargetStillLandable(
            .until(entryId: "a", title: "t"),
            in: stack([entry(id: "a", prState: .open, approved: true, ci: nil)])
        ))
    }

    @Test func untilRequiresReadyLowerEntries() {
        let wt = Worktree(id: "i", projectId: "p", name: "f", branch: "f",
                          path: URL(fileURLWithPath: "/tmp/x"), status: .clean, lastActivity: Date())
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        func positionedEntry(
            id: String,
            position: Int,
            prState: GGPRState,
            approved: Bool,
            ci: GGCIStatus?
        ) -> GGStackEntry {
            GGStackEntry(position: position, sha: "s\(position)", title: "t\(position)", ggId: id, prNumber: 5 + position,
                         prState: prState, approved: approved, ciStatus: ci)
        }

        #expect(state.ggLandTargetStillLandable(
            .until(entryId: "b", title: "t2"),
            in: stack([
                positionedEntry(id: "a", position: 1, prState: .open, approved: true, ci: .success),
                positionedEntry(id: "b", position: 2, prState: .open, approved: true, ci: .success),
            ])
        ))
        #expect(state.ggLandTargetStillLandable(
            .until(entryId: "b", title: "t2"),
            in: stack([
                positionedEntry(id: "a", position: 1, prState: .merged, approved: false, ci: .failed),
                positionedEntry(id: "b", position: 2, prState: .open, approved: true, ci: .success),
            ])
        ))
        #expect(!state.ggLandTargetStillLandable(
            .until(entryId: "b", title: "t2"),
            in: stack([
                positionedEntry(id: "a", position: 1, prState: .open, approved: false, ci: .success),
                positionedEntry(id: "b", position: 2, prState: .open, approved: true, ci: .success),
            ])
        ))
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
