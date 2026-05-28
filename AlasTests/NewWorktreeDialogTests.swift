import Foundation
import Testing
@testable import Alas

struct NewWorktreeDialogTests {
    @Test func repositorySelectorShowsForGlobalCreation() {
        #expect(NewWorktreeDialog.showsRepositorySelector(
            presetProjectId: nil,
            projects: [Self.project(id: "repo-a")]
        ))
    }

    @Test func repositorySelectorIsHiddenForValidPreset() {
        #expect(!NewWorktreeDialog.showsRepositorySelector(
            presetProjectId: "repo-a",
            projects: [Self.project(id: "repo-a"), Self.project(id: "repo-b")]
        ))
    }

    @Test func repositorySelectorShowsForStalePreset() {
        #expect(NewWorktreeDialog.showsRepositorySelector(
            presetProjectId: "missing",
            projects: [Self.project(id: "repo-a")]
        ))
    }

    @Test func repositorySelectorStaysHiddenWhenThereAreNoProjects() {
        #expect(!NewWorktreeDialog.showsRepositorySelector(
            presetProjectId: nil,
            projects: []
        ))
    }

    @Test func resolvedPresetProjectReturnsMatchingProject() {
        let projects = [Self.project(id: "repo-a"), Self.project(id: "repo-b")]

        #expect(NewWorktreeDialog.resolvedPresetProject(
            presetProjectId: "repo-b",
            projects: projects
        )?.id == "repo-b")
    }

    @Test func preferredBaseBranchChoosesMainWhenNoConfiguredDefault() {
        let selected = NewWorktreeDialog.preferredBaseBranch(
            availableBranches: ["trunk", "master", "main"],
            configuredDefault: ""
        )

        #expect(selected == "main")
    }

    @Test func preferredBaseBranchUsesConfiguredDefaultOverMain() {
        let selected = NewWorktreeDialog.preferredBaseBranch(
            availableBranches: ["trunk", "master", "main", "develop"],
            configuredDefault: "develop"
        )

        #expect(selected == "develop")
    }

    @Test func preferredBaseBranchChoosesMasterBeforeTrunk() {
        let selected = NewWorktreeDialog.preferredBaseBranch(
            availableBranches: ["trunk", "master"],
            configuredDefault: ""
        )

        #expect(selected == "master")
    }

    @Test func preferredBaseBranchUsesConfiguredDefaultWhenAvailable() {
        let selected = NewWorktreeDialog.preferredBaseBranch(
            availableBranches: ["release/1.0", "develop"],
            configuredDefault: "develop"
        )

        #expect(selected == "develop")
    }

    @Test func preferredBaseBranchUsesFirstAvailableBeforeUnavailableDefault() {
        let selected = NewWorktreeDialog.preferredBaseBranch(
            availableBranches: ["release/1.0", "develop"],
            configuredDefault: "integration"
        )

        #expect(selected == "release/1.0")
    }

    @Test func preferredBaseBranchPreservesDefaultWhenNoBranchesAvailable() {
        let selected = NewWorktreeDialog.preferredBaseBranch(
            availableBranches: [],
            configuredDefault: "integration"
        )

        #expect(selected == "integration")
    }

    @Test func canCreateRequiresProjects() {
        #expect(!NewWorktreeDialog.canCreate(projectsEmpty: true, branchEmpty: false))
    }

    @Test func canCreateRequiresBranch() {
        #expect(!NewWorktreeDialog.canCreate(projectsEmpty: false, branchEmpty: true))
    }

    @Test func canCreateBlockedByInvalidBranch() {
        #expect(!NewWorktreeDialog.canCreate(projectsEmpty: false, branchEmpty: false, branchValidation: "Name cannot contain spaces."))
    }

    @Test func canCreateSucceedsWithProjectsAndBranch() {
        #expect(NewWorktreeDialog.canCreate(projectsEmpty: false, branchEmpty: false))
    }

    @Test func canCreateBlockedByAcpModeWithoutAgent() {
        #expect(!NewWorktreeDialog.canCreate(
            projectsEmpty: false,
            branchEmpty: false,
            requiresAcpAgent: true,
            hasAcpAgent: false
        ))
    }

    @Test func canCreateAllowsAcpModeWithAgent() {
        #expect(NewWorktreeDialog.canCreate(
            projectsEmpty: false,
            branchEmpty: false,
            requiresAcpAgent: true,
            hasAcpAgent: true
        ))
    }

    private static func project(id: String) -> ProjectConfig {
        ProjectConfig(
            id: id,
            name: "nacho/\(id)",
            path: "/tmp/\(id)",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Launch surface helpers

    private static func agent(id: String, displayName: String, isEnabled: Bool = true) -> AgentDefinition {
        AgentDefinition(
            id: id,
            displayName: displayName,
            binary: id,
            binaryOverride: nil,
            promptModeArgs: [],
            bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: true,
            isEnabled: isEnabled,
            builtinLogoAssetName: nil
        )
    }

    @Test func acpCapableAgentsFiltersToCatalogIds() {
        let agents = [
            Self.agent(id: "claude",  displayName: "Claude"),   // ACP-capable
            Self.agent(id: "amp",     displayName: "Amp"),      // terminal-only
            Self.agent(id: "codex",   displayName: "Codex"),    // ACP-capable
        ]
        let filtered = NewWorktreeDialog.acpCapableAgents(from: agents)
        #expect(filtered.map(\.id) == ["claude", "codex"])
    }

    @Test func acpCapableAgentsReturnsEmptyWhenNoneMatch() {
        let agents = [Self.agent(id: "amp", displayName: "Amp")]
        #expect(NewWorktreeDialog.acpCapableAgents(from: agents).isEmpty)
    }

    @Test func acpSegmentEnabledWhenAtLeastOneACPCapableAgent() {
        let agents = [Self.agent(id: "claude", displayName: "Claude")]
        #expect(NewWorktreeDialog.acpSegmentEnabled(enabledAgents: agents))
    }

    @Test func acpSegmentDisabledWhenNoACPCapableAgents() {
        let agents = [Self.agent(id: "amp", displayName: "Amp")]
        #expect(!NewWorktreeDialog.acpSegmentEnabled(enabledAgents: agents))
    }

    @Test func resolvedLaunchAgentKeepsInitialWhenValidForTerminalMode() {
        let agents = [
            Self.agent(id: "claude", displayName: "Claude"),
            Self.agent(id: "amp",    displayName: "Amp"),
        ]
        let resolved = NewWorktreeDialog.resolvedLaunchAgent(
            initialAgentId: "amp",
            mode: .terminal,
            enabledAgents: agents
        )
        #expect(resolved == "amp")
    }

    @Test func resolvedLaunchAgentAllowsNoneInTerminalMode() {
        let agents = [Self.agent(id: "claude", displayName: "Claude")]
        let resolved = NewWorktreeDialog.resolvedLaunchAgent(
            initialAgentId: "none",
            mode: .terminal,
            enabledAgents: agents
        )
        #expect(resolved == "none")
    }

    @Test func resolvedLaunchAgentReplacesNonACPInACPMode() {
        let agents = [
            Self.agent(id: "amp",    displayName: "Amp"),     // not ACP-capable
            Self.agent(id: "claude", displayName: "Claude"),  // ACP-capable
            Self.agent(id: "codex",  displayName: "Codex"),   // ACP-capable
        ]
        let resolved = NewWorktreeDialog.resolvedLaunchAgent(
            initialAgentId: "amp",
            mode: .acp,
            enabledAgents: agents
        )
        #expect(resolved == "claude")
    }

    @Test func resolvedLaunchAgentReplacesNoneInACPMode() {
        let agents = [Self.agent(id: "claude", displayName: "Claude")]
        let resolved = NewWorktreeDialog.resolvedLaunchAgent(
            initialAgentId: "none",
            mode: .acp,
            enabledAgents: agents
        )
        #expect(resolved == "claude")
    }

    @Test func resolvedLaunchAgentKeepsValidACPInACPMode() {
        let agents = [
            Self.agent(id: "claude", displayName: "Claude"),
            Self.agent(id: "codex",  displayName: "Codex"),
        ]
        let resolved = NewWorktreeDialog.resolvedLaunchAgent(
            initialAgentId: "codex",
            mode: .acp,
            enabledAgents: agents
        )
        #expect(resolved == "codex")
    }

    @Test func resolvedLaunchAgentReturnsNoneWhenACPModeButNoCapableAgents() {
        // Defensive: caller should disable the ACP segment first, but if
        // they don't, we still return "none" rather than crashing.
        let agents = [Self.agent(id: "amp", displayName: "Amp")]
        let resolved = NewWorktreeDialog.resolvedLaunchAgent(
            initialAgentId: "amp",
            mode: .acp,
            enabledAgents: agents
        )
        #expect(resolved == "none")
    }

    // MARK: - Per-project launch defaults

    @Test func resolvedLaunchDefaultsUsesProjectPreference() {
        let result = NewWorktreeDialog.resolvedLaunchDefaults(
            projectOpenAfterCreate: false,
            projectLauncherMode: .acp,
            globalLauncherMode: .terminal,
            acpSegmentEnabled: true
        )
        #expect(result.openAfterCreate == false)
        #expect(result.launchMode == .acp)
    }

    @Test func resolvedLaunchDefaultsFallsBackToGlobalWhenProjectIsNil() {
        let result = NewWorktreeDialog.resolvedLaunchDefaults(
            projectOpenAfterCreate: nil,
            projectLauncherMode: nil,
            globalLauncherMode: .acp,
            acpSegmentEnabled: true
        )
        #expect(result.openAfterCreate == true)
        #expect(result.launchMode == .acp)
    }

    @Test func resolvedLaunchDefaultsFallsBackToTerminalWhenACPDisabled() {
        let result = NewWorktreeDialog.resolvedLaunchDefaults(
            projectOpenAfterCreate: nil,
            projectLauncherMode: .acp,
            globalLauncherMode: .terminal,
            acpSegmentEnabled: false
        )
        #expect(result.openAfterCreate == true)
        #expect(result.launchMode == .terminal)
    }

    @Test func resolvedLaunchDefaultsProjectOpenAfterCreateOverridesGlobal() {
        let result = NewWorktreeDialog.resolvedLaunchDefaults(
            projectOpenAfterCreate: false,
            projectLauncherMode: nil,
            globalLauncherMode: .terminal,
            acpSegmentEnabled: true
        )
        #expect(result.openAfterCreate == false)
        #expect(result.launchMode == .terminal)
    }
}
