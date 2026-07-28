import Foundation
import Testing
@testable import Alas

struct NewWorktreeDialogTests {
    @Test func presentationKeepsRequestedProjectId() {
        let presentation = NewWorktreePresentation(projectId: "alas")

        #expect(presentation.projectId == "alas")
    }

    @Test func presentationSupportsGlobalCreation() {
        let presentation = NewWorktreePresentation(projectId: nil)

        #expect(presentation.projectId == nil)
    }

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

    @Test func initialSelectionEnablesStackedDiffsBeforeFirstRender() {
        let selection = NewWorktreeDialog.initialSelection(
            presetProjectId: nil,
            projects: [Self.project(id: "repo-a", ggMode: .auto)],
            repoHasGGConfig: { $0.id == "repo-a" }
        )

        #expect(selection.projectId == "repo-a")
        #expect(selection.ggMode == .on)
    }

    @Test func initialSelectionDisablesStackedDiffsBeforeFirstRender() {
        let selection = NewWorktreeDialog.initialSelection(
            presetProjectId: nil,
            projects: [Self.project(id: "repo-a", ggMode: .off)],
            repoHasGGConfig: { _ in true }
        )

        #expect(selection.projectId == "repo-a")
        #expect(selection.ggMode == .off)
    }

    @Test func initialSelectionUsesValidPresetProjectPolicy() {
        let selection = NewWorktreeDialog.initialSelection(
            presetProjectId: "repo-b",
            projects: [
                Self.project(id: "repo-a", ggMode: .off),
                Self.project(id: "repo-b", ggMode: .on),
            ],
            repoHasGGConfig: { _ in false }
        )

        #expect(selection.projectId == "repo-b")
        #expect(selection.ggMode == .on)
    }

    @Test func initialSelectionFallsBackToFirstProjectForStalePreset() {
        let selection = NewWorktreeDialog.initialSelection(
            presetProjectId: "missing",
            projects: [
                Self.project(id: "repo-a", ggMode: .off),
                Self.project(id: "repo-b", ggMode: .on),
            ],
            repoHasGGConfig: { _ in true }
        )

        #expect(selection.projectId == "repo-a")
        #expect(selection.ggMode == .off)
    }

    @Test func initialSelectionIsOffWithoutProjects() {
        let selection = NewWorktreeDialog.initialSelection(
            presetProjectId: nil,
            projects: [],
            repoHasGGConfig: { _ in true }
        )

        #expect(selection.projectId.isEmpty)
        #expect(selection.ggMode == .off)
    }

    @Test func initialProjectIdUsesValidPreset() {
        let projects = [Self.project(id: "repo-a"), Self.project(id: "repo-b")]

        #expect(NewWorktreeDialog.initialProjectId(
            presetProjectId: "repo-b",
            projects: projects
        ) == "repo-b")
    }

    @Test func initialProjectIdFallsBackToFirstProjectForStalePreset() {
        let projects = [Self.project(id: "repo-a"), Self.project(id: "repo-b")]

        #expect(NewWorktreeDialog.initialProjectId(
            presetProjectId: "missing",
            projects: projects
        ) == "repo-a")
    }

    @Test func initialProjectIdUsesFirstProjectWithoutPreset() {
        let projects = [Self.project(id: "repo-a"), Self.project(id: "repo-b")]

        #expect(NewWorktreeDialog.initialProjectId(
            presetProjectId: nil,
            projects: projects
        ) == "repo-a")
    }

    @Test func initialProjectIdIsEmptyWithoutProjects() {
        #expect(NewWorktreeDialog.initialProjectId(
            presetProjectId: nil,
            projects: []
        ) == "")
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

    @Test func initialBaseUsesStackPinnedBaseWhenAvailable() {
        #expect(NewWorktreeDialog.initialBase(
            configuredDefault: "main",
            stackPinnedBase: "develop"
        ) == "develop")
    }

    @Test func initialBaseUsesConfiguredDefaultWithoutStackPin() {
        #expect(NewWorktreeDialog.initialBase(
            configuredDefault: "main",
            stackPinnedBase: nil
        ) == "main")
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

    private static func project(
        id: String,
        ggMode: GGProjectMode = .auto
    ) -> ProjectConfig {
        ProjectConfig(
            id: id,
            name: "nacho/\(id)",
            path: "/tmp/\(id)",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0),
            ggMode: ggMode
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

    @Test func launchSurfaceSegmentsExposeEnabledOptionsToKeyboardFocus() {
        #expect(NewWorktreeDialog.launchSurfaceSegmentFocusable(.none, acpSegmentEnabled: false))
        #expect(NewWorktreeDialog.launchSurfaceSegmentFocusable(.terminal, acpSegmentEnabled: false))
        #expect(!NewWorktreeDialog.launchSurfaceSegmentFocusable(.acp, acpSegmentEnabled: false))
        #expect(NewWorktreeDialog.launchSurfaceSegmentFocusable(.acp, acpSegmentEnabled: true))
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
        #expect(result.persistableLaunchMode == .acp)
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
        #expect(result.persistableLaunchMode == .acp)
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
        // persistableLaunchMode preserves the intended .acp preference
        #expect(result.persistableLaunchMode == .acp)
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
        #expect(result.persistableLaunchMode == .terminal)
    }

    @Test func explicitGGDescriptionsExplainCreation() {
        #expect(NewWorktreeDialog.ggModeDescription(mode: .on, createsGGStack: true) ==
            "GG enabled for this worktree.")
        #expect(NewWorktreeDialog.ggModeDescription(mode: .off, createsGGStack: false) ==
            "GG disabled for this worktree. Creates a regular Git branch.")
    }

    @Test func ggModeFieldUsesStackedDiffsName() {
        #expect(NewWorktreeDialog.ggModeFieldLabel == "Stacked Diffs Mode")
    }

    @Test func ggBranchPreviewIncludesPinnedBase() {
        #expect(NewWorktreeDialog.ggBranchPreview(branch: "nacho/feature", base: "main") ==
            "Branch: nacho/feature, based on main")
    }

    @Test func ggBranchPreviewOmitsMissingBase() {
        #expect(NewWorktreeDialog.ggBranchPreview(branch: "nacho/feature", base: nil) ==
            "Branch: nacho/feature")
    }

    @Test(arguments: [
        (GGProjectMode.off, false, GGWorktreeMode.off),
        (GGProjectMode.off, true, GGWorktreeMode.off),
        (GGProjectMode.on, false, GGWorktreeMode.on),
        (GGProjectMode.on, true, GGWorktreeMode.on),
        (GGProjectMode.auto, false, GGWorktreeMode.off),
        (GGProjectMode.auto, true, GGWorktreeMode.on),
    ])
    func initialGGModeResolvesRepositoryPolicy(
        projectMode: GGProjectMode,
        repoHasGGConfig: Bool,
        expected: GGWorktreeMode
    ) {
        #expect(NewWorktreeDialog.initialGGMode(
            projectMode: projectMode,
            repoHasGGConfig: repoHasGGConfig
        ) == expected)
    }

    @Test func repositoryChangeReplacesExplicitChoiceWithNewRepositoryDefault() {
        #expect(NewWorktreeDialog.ggModeAfterRepositoryChange(
            projectMode: .off,
            repoHasGGConfig: true
        ) == .off)
        #expect(NewWorktreeDialog.ggModeAfterRepositoryChange(
            projectMode: .auto,
            repoHasGGConfig: true
        ) == .on)
    }

    @Test func ggModeSegmentsMatchDialogOrderAndIcons() {
        #expect(NewWorktreeDialog.ggModeSegments == [
            NewWorktreeGGModeSegment(mode: .on, label: "On", icon: .stack),
            NewWorktreeGGModeSegment(mode: .off, label: "Off", icon: .disabled),
        ])
    }

    @Test func canCreateBlocksMissingUsernameOnlyForEffectiveGG() {
        #expect(!NewWorktreeDialog.canCreate(
            projectsEmpty: false,
            branchEmpty: false,
            ggConfigurationMissing: true
        ))
        #expect(NewWorktreeDialog.canCreate(
            projectsEmpty: false,
            branchEmpty: false,
            ggConfigurationMissing: false
        ))
    }

    @Test func ggModeUsesIndependentStackNameInsteadOfBranchPrefix() {
        #expect(NewWorktreeDialog.activeName(
            createsGGStack: false,
            branch: "nacho/auth-flow",
            stackName: "auth-flow"
        ) == "nacho/auth-flow")
        #expect(NewWorktreeDialog.activeName(
            createsGGStack: true,
            branch: "nacho/auth-flow",
            stackName: "auth-flow"
        ) == "auth-flow")
    }

    @Test func ggModePreservesNestedStackNameVerbatim() {
        #expect(NewWorktreeDialog.activeName(
            createsGGStack: true,
            branch: "nacho/other-branch",
            stackName: "nacho/auth-flow"
        ) == "nacho/auth-flow")
    }
}
