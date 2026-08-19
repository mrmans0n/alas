import Foundation
import Testing
@testable import Alas

@MainActor
struct ChangesTabViewTests {
    @Test func appKitCommitRowsTrackPrimaryRemote() {
        let primaryRemote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "owner",
            repository: "repo",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/owner/repo")!
        )
        let withoutRemote = ChangesTabView.commitRowsStateToken(
            ggStack: nil,
            inFlightAction: nil,
            pausedOperation: nil,
            mergeOperation: nil,
            selectionIsStale: false,
            commitsNeedPush: false,
            commitRemote: nil,
            primaryCommitRemote: nil
        )
        let withRemote = ChangesTabView.commitRowsStateToken(
            ggStack: nil,
            inFlightAction: nil,
            pausedOperation: nil,
            mergeOperation: nil,
            selectionIsStale: false,
            commitsNeedPush: false,
            commitRemote: nil,
            primaryCommitRemote: primaryRemote
        )

        #expect(withoutRemote != withRemote)
    }

    @Test func appKitRowsUseLatestActionsWithoutRebuilding() {
        let relay = ChangesAppKitActionRelay()
        var selections: [String] = []
        relay.update(
            onSelectFile: { selections.append("first:\($0.path)") },
            onSelectCommit: { _ in },
            onEditCommit: { _, _ in },
            onReviewCommit: { _ in }
        )
        relay.update(
            onSelectFile: { selections.append("second:\($0.path)") },
            onSelectCommit: { _ in },
            onEditCommit: { _, _ in },
            onReviewCommit: { _ in }
        )

        relay.onSelectFile(ChangedFile(
            path: "App.swift", status: "M", stage: .unstaged,
            add: 1, del: 0, renameFrom: nil
        ))

        #expect(selections == ["second:App.swift"])
    }

    @Test func genericOperationCardHiddenDuringPausedGGOperation() {
        let operation = MergeOperation.merge(sourceBranch: "main")

        #expect(ChangesTabView.shouldShowGenericOperationCard(
            mergeOperation: operation,
            pausedGGOperation: nil
        ))
        #expect(!ChangesTabView.shouldShowGenericOperationCard(
            mergeOperation: operation,
            pausedGGOperation: GGPausedOperation(pausedBy: .sync)
        ))
        #expect(!ChangesTabView.shouldShowGenericOperationCard(
            mergeOperation: nil,
            pausedGGOperation: nil
        ))
    }

    @Test func changesPreparationCardVisibilityDoesNotDependOnGGDrawer() {
        #expect(ChangesTabView.shouldShowChangesPreparationCard(
            preparationIsVisible: true
        ))
        #expect(!ChangesTabView.shouldShowChangesPreparationCard(
            preparationIsVisible: false
        ))
    }

    @Test func regularGitOperationDisablesGGPreparationMutations() {
        let reason = ChangesTabView.ggPreparationMutationDisabledReason(
            contextIsActive: true,
            stackLoadState: .loaded,
            pausedOperation: nil,
            inFlightAction: nil,
            mergeOperation: .merge(sourceBranch: "main")
        )

        #expect(reason == "Finish the current Git operation first.")
    }

    @Test func newStackCommitRequiresActualStackHeadCheckout() {
        let stack = stack(currentPosition: 1)

        #expect(ChangesTabView.ggNewStackCommitDisabledReason(
            contextIsActive: true,
            stackLoadState: .loaded,
            stack: stack,
            currentHeadSHA: "1111111111111111111111111111111111111111"
        ) == "Checkout the stack head to create a new stack commit.")
        #expect(ChangesTabView.ggNewStackCommitDisabledReason(
            contextIsActive: true,
            stackLoadState: .loaded,
            stack: stack,
            currentHeadSHA: "2222222222222222222222222222222222222222"
        ) == nil)
    }

    @Test func activeEmptyContextAllowsFirstStackCommitButNotRewrites() {
        #expect(ChangesTabView.ggNewStackCommitDisabledReason(
            contextIsActive: true,
            stackLoadState: .empty,
            stack: nil,
            currentHeadSHA: "1111111111111111111111111111111111111111"
        ) == nil)

        let model = ChangesPreparationModel.makeGG(
            staged: .init(files: 1, insertions: 1, deletions: 0),
            hasDraft: false,
            capabilities: GGCapabilities(
                structuredSplit: true,
                keepCurrentUnstack: true,
                stagedOnlyAmend: true
            ),
            hasLoadedCommit: false
        )
        #expect(model.ggAction(.newStackCommit)?.isEnabled == true)
        #expect(model.ggAction(.amendCurrent)?.disabledReason == "Create the first stack commit.")
        #expect(model.ggAction(.absorbIntoStack)?.disabledReason == "Create the first stack commit.")
    }

    @Test func unavailableStackStateDisablesPreparationWithAccurateReason() {
        #expect(ChangesTabView.ggPreparationMutationDisabledReason(
            contextIsActive: true,
            stackLoadState: .loading,
            pausedOperation: nil,
            inFlightAction: nil,
            mergeOperation: nil
        ) == "Wait for the GG stack to load.")
        #expect(ChangesTabView.ggNewStackCommitDisabledReason(
            contextIsActive: true,
            stackLoadState: .failed("gg unavailable"),
            stack: nil,
            currentHeadSHA: "1111111111111111111111111111111111111111"
        ) == "Retry loading the GG stack.")
    }

    @Test func loadedStackWithoutVerifiableHeadDisablesNewCommit() {
        #expect(ChangesTabView.ggNewStackCommitDisabledReason(
            contextIsActive: true,
            stackLoadState: .loaded,
            stack: stack(currentPosition: 2),
            currentHeadSHA: ""
        ) == "Checkout the stack head to create a new stack commit.")
    }

    @Test func ggDrawerActiveForContextOrRecovery() {
        #expect(!ChangesTabView.shouldShowGGDrawer(
            contextIsActive: false, pausedGGOperation: nil, hasUndoCandidate: false
        ))
        #expect(ChangesTabView.shouldShowGGDrawer(
            contextIsActive: true,
            pausedGGOperation: nil,
            hasUndoCandidate: false
        ))
        #expect(ChangesTabView.shouldShowGGDrawer(
            contextIsActive: false,
            pausedGGOperation: GGPausedOperation(pausedBy: .sync),
            hasUndoCandidate: false
        ))
        #expect(ChangesTabView.shouldShowGGDrawer(
            contextIsActive: false, pausedGGOperation: nil, hasUndoCandidate: true
        ))
    }

    @Test func prepareSelectsSyncForUnsyncedStack() {
        let readiness = GGStackReadinessModel.make(
            stack: stack(syncedCommits: 0, prState: .open),
            action: GGStackActionState()
        )

        #expect(ChangesTabView.reconciliationAction(from: readiness)?.kind == .sync)
    }

    @Test func prepareSelectsSyncForPublishableStack() {
        let readiness = GGStackReadinessModel.make(
            stack: stack(syncedCommits: 1, prState: nil),
            action: GGStackActionState()
        )

        #expect(ChangesTabView.reconciliationAction(from: readiness)?.kind == .sync)
    }

    @Test func prepareSelectsSyncWithRebaseDetailForAutoRebase() {
        let readiness = GGStackReadinessModel.make(
            stack: stack(syncedCommits: 1, behindBase: 2, prState: .open),
            action: GGStackActionState(),
            effectiveConfig: .init(syncAutoRebase: true, syncBehindThreshold: 1)
        )

        let action = ChangesTabView.reconciliationAction(from: readiness)
        #expect(action?.kind == .sync)
        #expect(action?.detail == "Includes rebase onto main")
    }

    @Test func prepareSelectsRebaseForManualRebase() {
        let readiness = GGStackReadinessModel.make(
            stack: stack(syncedCommits: 1, behindBase: 2, prState: .open),
            action: GGStackActionState(),
            effectiveConfig: .init(syncAutoRebase: false, syncBehindThreshold: 1)
        )

        #expect(ChangesTabView.reconciliationAction(from: readiness)?.kind == .rebase)
    }

    @Test func prepareOmitsNonReconciliationReadiness() {
        let readiness = GGStackReadinessModel.make(
            stack: stack(
                syncedCommits: 1,
                prState: .open,
                approved: true,
                ciStatus: .success
            ),
            action: GGStackActionState()
        )

        #expect(ChangesTabView.reconciliationAction(from: readiness) == nil)
    }

    private func stack(
        currentPosition: Int?,
        entries: [GGStackEntry] = [
            GGStackEntry(
                position: 1,
                sha: "1111111",
                title: "First",
                isCurrent: true
            ),
            GGStackEntry(
                position: 2,
                sha: "2222222",
                title: "Second"
            ),
        ]
    ) -> GGStack {
        GGStack(
            name: "feat",
            base: "main",
            totalCommits: entries.count,
            syncedCommits: 0,
            currentPosition: currentPosition,
            behindBase: nil,
            entries: entries
        )
    }

    private func stack(
        syncedCommits: Int,
        behindBase: Int? = nil,
        prState: GGPRState?,
        approved: Bool = false,
        ciStatus: GGCIStatus? = nil
    ) -> GGStack {
        let entry = GGStackEntry(
            position: 1,
            sha: "1111111",
            title: "First",
            prNumber: prState == nil ? nil : 101,
            prState: prState,
            approved: approved,
            ciStatus: ciStatus,
            isCurrent: true
        )
        return GGStack(
            name: "feat",
            base: "main",
            totalCommits: 1,
            syncedCommits: syncedCommits,
            currentPosition: 1,
            behindBase: behindBase,
            entries: [entry]
        )
    }
}
