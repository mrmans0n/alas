import Testing
@testable import Alas

struct GGStackCreateModeTests {
    @Test func creationPolicyUsesRawModeAndLinkedRepositoryDefault() {
        #expect(createsStack(projectMode: .auto, worktreeMode: .inherit, hasConfig: true))
        #expect(!createsStack(projectMode: .auto, worktreeMode: .inherit, hasConfig: false))
        #expect(!createsStack(projectMode: .off, worktreeMode: .inherit, hasConfig: true))
        #expect(createsStack(projectMode: .on, worktreeMode: .inherit, hasConfig: false))
        #expect(createsStack(projectMode: .off, worktreeMode: .on, hasConfig: false))
        #expect(!createsStack(projectMode: .on, worktreeMode: .off, hasConfig: true))
    }

    @Test func creationPolicyHonorsHardStops() {
        #expect(!createsStack(masterEnabled: false))
        #expect(!createsStack(ggInstalled: false))
        #expect(!createsStack(isRemoteProject: true))
    }

    @Test func hiddenWhenGateFails() {
        #expect(GGStackCreateMode.availability(gatePassed: false, username: "nacho") == .hidden)
    }

    @Test func disabledWithHintWhenUsernameMissing() {
        let availability = GGStackCreateMode.availability(gatePassed: true, username: nil)
        guard case .disabled(let hint) = availability else {
            Issue.record("expected disabled")
            return
        }
        #expect(hint.contains("branch_username"))
    }

    @Test func enabledCarriesUsername() {
        #expect(GGStackCreateMode.availability(gatePassed: true, username: "nacho") == .enabled(username: "nacho"))
    }

    private func createsStack(
        masterEnabled: Bool = true,
        ggInstalled: Bool = true,
        isRemoteProject: Bool = false,
        projectMode: GGProjectMode = .auto,
        worktreeMode: GGWorktreeMode = .inherit,
        hasConfig: Bool = true
    ) -> Bool {
        GGStackCreateMode.createsStack(
            masterEnabled: masterEnabled,
            ggInstalled: ggInstalled,
            isRemoteProject: isRemoteProject,
            projectMode: projectMode,
            worktreeMode: worktreeMode,
            repoHasGGConfig: hasConfig
        )
    }
}
