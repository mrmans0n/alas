import AppKit
import Foundation
import SwiftUI
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

    @Test func completedGGProbeCarriesImmediateBranchInputIntoEmptyStackDraft() {
        let stackName = NewWorktreeDialog.stackNameAfterGGAvailabilityProbe(
            branch: "feature",
            currentStackName: ""
        )

        #expect(stackName == "feature")
    }

    @Test func completedGGProbePreservesExistingStackDraft() {
        let stackName = NewWorktreeDialog.stackNameAfterGGAvailabilityProbe(
            branch: "regular-draft",
            currentStackName: "stack-draft"
        )

        #expect(stackName == "stack-draft")
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

    @Test func issueAttachmentUsesOnlyAnExactCurrentProjectMatch() {
        #expect(NewWorktreeDialog.projectIDAfterIssueAttach(
            preferredProjectID: "repo-b",
            currentProjectID: "repo-a",
            availableProjectIDs: ["repo-a", "repo-b"]
        ) == "repo-b")
        #expect(NewWorktreeDialog.projectIDAfterIssueAttach(
            preferredProjectID: "stale",
            currentProjectID: "repo-a",
            availableProjectIDs: ["repo-a", "repo-b"]
        ) == "repo-a")
        #expect(NewWorktreeDialog.projectIDAfterIssueAttach(
            preferredProjectID: nil,
            currentProjectID: "repo-a",
            availableProjectIDs: ["repo-a", "repo-b"]
        ) == "repo-a")
    }

    @Test func issueAttachmentSeedsOnlyTheActiveBranchOrStackInput() {
        #expect(NewWorktreeDialog.namesAfterIssueAttach(
            branchSeed: "42-fix-sync",
            createsGGStack: false,
            branch: "manual-branch",
            stackName: "manual-stack"
        ) == (branch: "42-fix-sync", stackName: "manual-stack"))
        #expect(NewWorktreeDialog.namesAfterIssueAttach(
            branchSeed: "42-fix-sync",
            createsGGStack: true,
            branch: "manual-branch",
            stackName: "manual-stack"
        ) == (branch: "manual-branch", stackName: "42-fix-sync"))
    }

    @Test func issueAttachmentSelectsTheFirstEnabledACPCapableAgent() {
        let agents = [
            Self.agent(id: "amp", displayName: "Amp"),
            Self.agent(id: "codex", displayName: "Codex"),
            Self.agent(id: "claude", displayName: "Claude"),
        ]

        #expect(NewWorktreeDialog.issueLaunchAgent(from: agents) == "codex")
        #expect(NewWorktreeDialog.issueLaunchAgent(from: agents, preferredAgentID: "claude") == "claude")
        #expect(NewWorktreeDialog.initialLaunchMode(
            preferredMode: .acp, projectAgentMode: .overrideGlobal,
            resolvedAgentID: "claude", enabledAgents: agents
        ) == .acp)
        #expect(NewWorktreeDialog.initialLaunchMode(
            preferredMode: .acp, projectAgentMode: .overrideGlobal,
            resolvedAgentID: "amp", enabledAgents: agents
        ) == .terminal)
    }

    @Test func issuePromptIsAvailableOnlyForChatLaunchWhileAttachmentRemains() {
        let draft = AttachedIssueDraft(
            source: IssueSnapshot(
                identity: .init(providerID: .manual, stableID: "issue-42"),
                canonicalURL: URL(string: "https://example.com/issues/42")!,
                providerLabel: "example.com",
                displayReference: "#42",
                repositoryLocator: nil,
                title: "Fix sync",
                body: "Issue context",
                state: .unknown,
                labels: [],
                assignees: [],
                providerUpdatedAt: nil,
                capturedAt: .distantPast,
                refreshError: nil,
                contentOrigin: .manual,
                isEditable: true,
                isRefreshable: false
            ),
            projectID: nil,
            branchSeed: "feature/42-fix-sync",
            prompt: "Fix the issue."
        )

        #expect(NewWorktreeDialog.issuePromptForLaunch(
            draft: draft,
            openAfterCreate: true,
            launchMode: .acp
        ) == "Fix the issue.")
        #expect(NewWorktreeDialog.issuePromptForLaunch(
            draft: draft,
            openAfterCreate: true,
            launchMode: .terminal
        ) == nil)
        #expect(NewWorktreeDialog.issuePromptForLaunch(
            draft: draft,
            openAfterCreate: false,
            launchMode: .acp
        ) == nil)
        #expect(draft.attachment.displayTitle == "#42 · Fix sync")
    }

    @Test func editingAttachedIssueDoesNotReapplyParentFieldEffects() {
        #expect(NewWorktreeDialog.appliesParentFieldsAfterIssueAttach(existingDraft: nil))
        #expect(!NewWorktreeDialog.appliesParentFieldsAfterIssueAttach(existingDraft: Self.issueDraft()))
    }

    @Test func issueDrivenProjectChangeDoesNotReapplyLaunchDefaults() {
        #expect(!NewWorktreeDialog.appliesLaunchDefaultsAfterProjectChange(
            projectID: "repo-b",
            issueDrivenProjectID: "repo-b"
        ))
        #expect(NewWorktreeDialog.appliesLaunchDefaultsAfterProjectChange(
            projectID: "repo-c",
            issueDrivenProjectID: "repo-b"
        ))
        #expect(NewWorktreeDialog.appliesLaunchDefaultsAfterProjectChange(
            projectID: "repo-b",
            issueDrivenProjectID: nil
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

    private static func issueDraft() -> AttachedIssueDraft {
        AttachedIssueDraft(
            source: IssueSnapshot(
                identity: .init(providerID: .manual, stableID: "issue-42"),
                canonicalURL: URL(string: "https://example.com/issues/42")!,
                providerLabel: "example.com",
                displayReference: "#42",
                repositoryLocator: nil,
                title: "Fix sync",
                body: "Issue context",
                state: .unknown,
                labels: [],
                assignees: [],
                providerUpdatedAt: nil,
                capturedAt: .distantPast,
                refreshError: nil,
                contentOrigin: .manual,
                isEditable: true,
                isRefreshable: false
            ),
            projectID: nil,
            branchSeed: "feature/42-fix-sync",
            prompt: "Fix the issue."
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

    @Test func launchEligibleAgentsForLocalProjectUsesInstalledAgents() {
        let configured = [
            Self.agent(id: "claude", displayName: "Claude"),
            Self.agent(id: "codex", displayName: "Codex"),
        ]
        let locallyInstalled = [
            Self.agent(id: "claude", displayName: "Claude"),
        ]

        let agents = NewWorktreeDialog.launchEligibleAgents(
            isRemoteProject: false,
            configuredEnabledAgents: configured,
            locallyEnabledAgents: locallyInstalled
        )

        #expect(agents.map(\.id) == ["claude"])
    }

    @Test func launchEligibleAgentsForRemoteProjectUsesConfiguredAgents() {
        let configured = [
            Self.agent(id: "claude", displayName: "Claude"),
            Self.agent(id: "codex", displayName: "Codex"),
        ]
        let locallyInstalled = [
            Self.agent(id: "claude", displayName: "Claude"),
        ]

        let agents = NewWorktreeDialog.launchEligibleAgents(
            isRemoteProject: true,
            configuredEnabledAgents: configured,
            locallyEnabledAgents: locallyInstalled
        )

        #expect(agents.map(\.id) == ["claude", "codex"])
    }

    @Test func remoteAutoLaunchDefaultUsesConfiguredAgentCatalog() {
        let configured = [
            Self.agent(id: "remote-only", displayName: "Remote Only"),
            Self.agent(id: "local", displayName: "Local"),
        ]
        let agentId = NewWorktreeDialog.resolvedAutoLaunchAgentID(
            globalAgentId: "remote-only",
            projectMode: .useGlobal,
            projectAgentId: nil,
            repoAgentId: nil,
            enabledAgents: configured
        )

        #expect(agentId == "remote-only")
    }

    @Test func localAutoLaunchDefaultRejectsUninstalledConfiguredAgent() {
        let locallyInstalled = [
            Self.agent(id: "local", displayName: "Local"),
        ]
        let agentId = NewWorktreeDialog.resolvedAutoLaunchAgentID(
            globalAgentId: "remote-only",
            projectMode: .useGlobal,
            projectAgentId: nil,
            repoAgentId: nil,
            enabledAgents: locallyInstalled
        )

        #expect(agentId == nil)
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

    @Test func repositoryNoneDoesNotFallBackToAnAutomaticChatAgent() {
        #expect(NewWorktreeDialog.initialLaunchMode(
            preferredMode: .acp, projectAgentMode: .disabled,
            resolvedAgentID: nil, enabledAgents: []
        ) == .terminal)
        #expect(NewWorktreeDialog.initialLaunchMode(
            preferredMode: .acp, projectAgentMode: .overrideGlobal,
            resolvedAgentID: "unavailable", enabledAgents: []
        ) == .terminal)
        #expect(NewWorktreeDialog.initialLaunchMode(
            preferredMode: .acp, projectAgentMode: .useGlobal,
            resolvedAgentID: nil, enabledAgents: []
        ) == .acp)
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

    @Test func branchPreviewIncludesPinnedBase() {
        #expect(NewWorktreeDialog.branchPreview(branch: "nacho/feature", base: "main") ==
            "Branch: nacho/feature, based on main")
    }

    @Test func branchPreviewOmitsMissingBase() {
        #expect(NewWorktreeDialog.branchPreview(branch: "feature/login-fix", base: nil) ==
            "Branch: feature/login-fix")
    }

    @Test func composedBranchPrependsTheConfiguredPrefix() {
        #expect(NewWorktreeDialog.composedBranch(prefix: "feature/", name: "login-fix") ==
            "feature/login-fix")
        #expect(NewWorktreeDialog.composedBranch(prefix: "", name: "login-fix") == "login-fix")
    }

    /// The prefix is composed, never typed, so an empty field must not
    /// render as a bare prefix — Create stays disabled on emptiness alone.
    @Test func composedBranchIsEmptyWhileTheNameIsEmpty() {
        #expect(NewWorktreeDialog.composedBranch(prefix: "feature/", name: "").isEmpty)
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

@Suite(.serialized)
@MainActor
struct NewWorktreeDialogPresentationTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    @Test func worktreeDialogOwnsRuntimeHookApprovalPresentation() async throws {
        let state = AppState(store: MemoryStore(), restoreActiveTabsOnStartup: false)
        let dialog = NewWorktreeDialog(state: state, presented: .constant(true), presetProjectId: "project")
        let theme = try ThemeStore().current
        let controller = NSHostingController(rootView: dialog.environment(\.theme, theme))
        controller.view.frame = NSRect(x: 0, y: 0, width: 560, height: 480)
        controller.view.layoutSubtreeIfNeeded()

        let bytes = Data("echo session open".utf8)
        let hook = RepoHook(
            event: .sessionOpen,
            source: .local,
            bytes: bytes,
            text: String(decoding: bytes, as: UTF8.self),
            hash: RepoHookTrust.hash(event: .sessionOpen, bytes: bytes)
        )
        let task = Task {
            await state.repoHookApprovalQueue.requestDecision(
                hook: hook,
                projectID: "project",
                context: .sessionOpen
            )
        }

        await Task.yield()
        let nestedRequest = state.repoHookApprovalQueue.activeDialogRequest
        let rootRequest = state.repoHookApprovalQueue.activeRuntimeRequest
        state.repoHookApprovalQueue.decide(.approve)

        #expect(nestedRequest?.context == .sessionOpen)
        #expect(rootRequest == nil)
        #expect(await task.value == .approve)
    }

    @Test func inactiveParentBindingHandsRuntimeApprovalToActiveChild() async {
        let queue = RepoHookApprovalQueue()
        let childPresenterID = UUID()
        queue.registerDialogPresenter(id: childPresenterID)
        defer {
            queue.decide(.approve)
            queue.unregisterDialogPresenter(id: childPresenterID)
        }

        let bytes = Data("echo session open".utf8)
        let hook = RepoHook(
            event: .sessionOpen,
            source: .local,
            bytes: bytes,
            text: String(decoding: bytes, as: UTF8.self),
            hash: RepoHookTrust.hash(event: .sessionOpen, bytes: bytes)
        )
        let task = Task {
            await queue.requestDecision(
                hook: hook,
                projectID: "project",
                context: .sessionOpen
            )
        }
        await Task.yield()

        let activeRequestID = queue.activeRequest?.id
        let queueBinding = Binding<RepoHookApprovalRequest?>(
            get: { queue.activeDialogRequest },
            set: { queue.activeDialogRequest = $0 }
        )
        let parentBinding = RepoHookApprovalPresentationHandler(
            approvalQueue: queue,
            isActive: false
        ).presentationBinding(for: queueBinding)
        let childBinding = RepoHookApprovalPresentationHandler(approvalQueue: queue)
            .presentationBinding(for: queueBinding)

        #expect(activeRequestID != nil)
        #expect(parentBinding.wrappedValue == nil)
        #expect(childBinding.wrappedValue?.id == activeRequestID)

        parentBinding.wrappedValue = nil
        #expect(queue.activeRequest?.id == activeRequestID)

        queue.decide(.approve)
        #expect(await task.value == .approve)
    }

    @Test func inactivePresenterLeavesRuntimeApprovalForRoot() async {
        let queue = RepoHookApprovalQueue()
        let controller = NSHostingController(
            rootView: Text("Project").modifier(
                RepoHookApprovalPresentationHandler(
                    approvalQueue: queue,
                    isActive: false,
                    registersPresenter: false
                )
            )
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        controller.view.layoutSubtreeIfNeeded()
        await Task.yield()

        let bytes = Data("echo session open".utf8)
        let hook = RepoHook(
            event: .sessionOpen,
            source: .local,
            bytes: bytes,
            text: String(decoding: bytes, as: UTF8.self),
            hash: RepoHookTrust.hash(event: .sessionOpen, bytes: bytes)
        )
        let task = Task {
            await queue.requestDecision(
                hook: hook,
                projectID: "project",
                context: .sessionOpen
            )
        }
        await Task.yield()

        #expect(queue.activeRuntimeRequest?.context == .sessionOpen)
        #expect(queue.activeDialogRequest == nil)

        queue.decide(.approve)
        #expect(await task.value == .approve)
    }
}
