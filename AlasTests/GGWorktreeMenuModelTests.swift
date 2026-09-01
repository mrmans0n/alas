import Testing
@testable import Alas

struct GGWorktreeMenuModelTests {
    @Test func inheritedMainWorktreeWithPolicyOffHasNoMisleadingExplanation() {
        let model = menuModel(
            selectedMode: .inherit,
            context: .inactive(reason: .policyOff)
        )

        #expect(model.selectedMode == .inherit)
        #expect(!model.isEffectiveActive)
        #expect(model.inactiveExplanation == nil)
        #expect(!model.showsStatusIndicator)
        #expect(model.isVisible)
    }

    @Test func explicitOnValidBranchIsActive() {
        let model = menuModel(
            selectedMode: .on,
            context: .active(stackName: "my-stack"),
            hasStackSummary: true
        )

        #expect(model.selectedMode == .on)
        #expect(model.isEffectiveActive)
        #expect(model.inactiveExplanation == nil)
        #expect(!model.showsStatusIndicator)
    }

    @Test func branchMismatchExplainsRequiredPrefix() {
        let model = menuModel(
            selectedMode: .on,
            context: .inactive(reason: .branchPrefixMismatch(expectedPrefix: "nacho/"))
        )

        #expect(model.inactiveExplanation == "Branch must start with nacho/")
    }

    @Test func missingUsernameHasUsefulExplanation() {
        let model = menuModel(
            selectedMode: .on,
            context: .inactive(reason: .branchUsernameMissing)
        )

        #expect(model.inactiveExplanation == "Set branch_username in gg config.")
    }

    @Test func missingCLIHasUsefulExplanation() {
        let model = menuModel(
            selectedMode: .on,
            context: .inactive(reason: .cliMissing)
        )

        #expect(model.inactiveExplanation == "gg is not installed.")
    }

    @Test func globalDisableHidesMenuAndHasUsefulExplanation() {
        let model = menuModel(
            selectedMode: .on,
            context: .inactive(reason: .masterDisabled)
        )

        #expect(!model.isVisible)
        #expect(model.inactiveExplanation == "Stacked diffs are disabled in Settings.")
    }

    @Test func remoteContextHidesMenuAndExplanation() {
        let model = menuModel(
            selectedMode: .on,
            context: .inactive(reason: .remoteProject)
        )

        #expect(!model.isVisible)
        #expect(model.inactiveExplanation == nil)
        #expect(!model.showsStatusIndicator)
    }

    @Test func remoteWorktreeFlagHidesMenuWhenEarlierHardStopWins() {
        let model = menuModel(
            selectedMode: .on,
            context: .inactive(reason: .masterDisabled),
            isRemoteWorktree: true
        )

        #expect(!model.isVisible)
        #expect(model.inactiveExplanation == nil)
        #expect(!model.showsStatusIndicator)
    }

    @Test func activeEmptyStackShowsStatusIndicator() {
        let model = menuModel(
            selectedMode: .inherit,
            context: .active(stackName: "empty-stack"),
            hasStackSummary: false
        )

        #expect(model.isEffectiveActive)
        #expect(model.showsStatusIndicator)
    }

    @Test func ggModeMenuItemsMarkTheSelectedMode() {
        let items = WorktreeRowView.ggModeMenuItems(selectedMode: .on)

        #expect(items.map(\.mode) == [.inherit, .on, .off])
        #expect(items.map(\.title) == ["Inherit repository default", "✓ On", "Off"])
    }

    private func menuModel(
        selectedMode: GGWorktreeMode,
        context: GGWorktreeContext,
        hasStackSummary: Bool = false,
        isRemoteWorktree: Bool = false
    ) -> GGWorktreeMenuModel {
        GGWorktreeMenuModel(
            selectedMode: selectedMode,
            context: context,
            hasStackSummary: hasStackSummary,
            isRemoteWorktree: isRemoteWorktree
        )
    }
}
