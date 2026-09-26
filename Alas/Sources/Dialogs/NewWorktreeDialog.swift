import SwiftUI

enum NewWorktreeLaunchSurfaceSegment: Hashable {
    case none
    case terminal
    case acp
}

struct NewWorktreeGGModeSegment: Equatable {
    let mode: GGWorktreeMode
    let label: String
    let icon: GGStackIconVariant
}

struct NewWorktreeDialog: View {
    nonisolated static let ggModeFieldLabel = "Stacked Diffs Mode"

    @Bindable var state: AppState
    @Binding var presented: Bool
    var presetProjectId: String?

    @State private var projectId: String
    // `base` is seeded from the persisted Worktrees settings in .onAppear
    // (this literal is a placeholder only — the real default comes from
    // state.config.worktrees.baseBranch). `branch`/`stackName` hold a bare
    // name: the branch prefix is composed in `effectiveBranch`, never typed.
    @State private var base: String = ""
    @State private var branch: String = ""
    @State private var stackName: String = ""
    @State private var runStartup: Bool = true
    @State private var ggMode: GGWorktreeMode
    @State private var openAfterCreate: Bool = true
    @State private var launchMode: AppConfig.LauncherMode = .terminal
    /// The launcher mode to persist — preserves the user's intent even when
    /// ACP is temporarily unavailable and `launchMode` has been coerced.
    @State private var persistableLaunchMode: AppConfig.LauncherMode = .terminal
    @State private var launchAgentId: String = "none"
    @State private var branches: [String] = []
    @State private var isLoadingBranches = false
    @State private var branchLoadError: String?
    @State private var createErrorMessage: String?
    @State private var issueState = NewWorktreeIssueState()
    @State private var issueSheetPresentation: AttachIssuePresentation?
    @State private var issueDrivenProjectChangeID: String?
    @State private var nameSuggestionTask: Task<Void, Never>?

    @Environment(\.theme) var theme

    init(
        state: AppState,
        presented: Binding<Bool>,
        presetProjectId: String? = nil
    ) {
        self.state = state
        self._presented = presented
        self.presetProjectId = presetProjectId
        let initialSelection = Self.initialSelection(
            presetProjectId: presetProjectId,
            projects: state.projects,
            repoHasGGConfig: { project in
                GGStackGate.repoHasGGConfig(repoPath: project.path)
            }
        )
        self._projectId = State(initialValue: initialSelection.projectId)
        self._ggMode = State(initialValue: initialSelection.ggMode)
    }

    var body: some View {
        DialogContainer(
            title: "New worktree",
            subtitle: subtitleText,
            headerAccessory: {
                if issueState.draft == nil {
                    DialogHeaderIconButton(icon: "paperclip", tooltip: "Attach issue…") {
                        issueSheetPresentation = AttachIssuePresentation(draft: nil)
                    }
                }
            },
            content: {
                if state.projects.isEmpty {
                    DialogField(label: "Repository") {
                        Text("No projects yet — add one first.").font(.system(size: 12))
                            .foregroundColor(theme.color("fg-dim"))
                    }
                } else if showsRepositorySelector {
                    DialogField(label: "Repository") {
                        ProjectPicker(
                            selection: $projectId,
                            projects: state.projects,
                            icon: { state.effectiveIcon(for: $0) }
                        )
                    }
                }
                DialogField(label: "Base branch") {
                    BranchPicker(
                        selection: $base,
                        branches: branches,
                        isLoading: isLoadingBranches,
                        errorMessage: branchLoadError
                    )
                    .disabled(stackPinnedBase != nil)
                }
                if stackPinnedBase != nil {
                    Text("Pinned to gg's stack base").font(.system(size: 11))
                        .foregroundColor(theme.color("fg-dim"))
                }
                DialogField(label: createsGGStack ? "Stack name" : "Branch name") {
                    AlasField(
                        text: activeNameBinding,
                        monospaced: true,
                        focusOnAppear: true,
                        onSubmit: submitCreate,
                        disablesAutomaticTextSubstitutions: true
                    )
                }
                if let preview = branchPreviewText {
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.color("fg-dim"))
                }
                HStack(spacing: 10) {
                    AlasToggle(on: $runStartup)
                    Text("Run startup script after create").font(.system(size: 12))
                        .foregroundColor(theme.color("fg"))
                }
                if ggStackAvailability != .hidden {
                    DialogField(label: Self.ggModeFieldLabel) {
                        ggModeSegmented
                    }
                    Text(Self.ggModeDescription(mode: ggMode, createsGGStack: createsGGStack))
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-dim"))
                    if createsGGStack, case .disabled(let hint) = ggStackAvailability {
                        Text(hint).font(.system(size: 11)).foregroundColor(theme.color("fg-dim"))
                    }
                }
                if let validationMessage = branchValidationMessage {
                    Text(validationMessage).font(.system(size: 11)).foregroundColor(.red)
                }
                issueAttachmentSection
                DialogField(label: "Open after create") {
                    HStack(spacing: 8) {
                        launchSurfaceSegmented
                        if openAfterCreate, !pickerAgents.isEmpty {
                            launchAgentPicker
                        }
                    }
                }
                if let createErrorMessage {
                    Text(createErrorMessage).font(.system(size: 11)).foregroundColor(.red)
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: "Create worktree",
            confirmStyle: .primary,
            onCancel: { presented = false },
            onConfirm: create,
            confirmEnabled: Self.canCreate(
                projectsEmpty: state.projects.isEmpty,
                branchEmpty: activeName.isEmpty,
                branchValidation: branchValidationMessage,
                ggConfigurationMissing: ggConfigurationMissing,
                requiresAcpAgent: openAfterCreate && launchMode == .acp,
                hasAcpAgent: launchAgentId != "none"
            )
        )
        .onAppear {
            if projectId.isEmpty {
                projectId = Self.initialProjectId(
                    presetProjectId: presetProjectId,
                    projects: state.projects
                )
            }
            applyGGModeDefault(for: projectId)
            if base.isEmpty {
                base = Self.initialBase(
                    configuredDefault: state.config.worktrees.baseBranch,
                    stackPinnedBase: stackPinnedBase
                )
            }
            applyLaunchDefaults(for: projectId)
            loadBranchesForSelectedProject()
        }
        .onDisappear { cancelNameSuggestion() }
        .onChange(of: projectId) { _, newProjectId in
            let shouldApplyLaunchDefaults = Self.appliesLaunchDefaultsAfterProjectChange(
                projectID: newProjectId,
                issueDrivenProjectID: issueDrivenProjectChangeID
            )
            issueDrivenProjectChangeID = nil
            applyGGModeDefault(for: projectId)
            if shouldApplyLaunchDefaults {
                applyLaunchDefaults(for: projectId)
            }
            // Seed the base for the new project synchronously so the picker
            // never shows the previous project's value; the async branch load
            // refines it (guarded: it skips pinned bases and user edits).
            base = stackPinnedBase ?? state.config.worktrees.baseBranch
            loadBranchesForSelectedProject()
        }
        .onChange(of: branch) { _, _ in
            createErrorMessage = nil
        }
        .onChange(of: stackName) { _, _ in
            createErrorMessage = nil
        }
        .onChange(of: ggMode) { _, _ in
            if createsGGStack {
                if let pinned = stackPinnedBase { base = pinned }
            }
        }
        .onChange(of: GGAvailability.shared.isInstalled) { wasInstalled, isInstalled in
            guard !wasInstalled, isInstalled, stackedDiffsRequested else { return }
            // The startup probe can resolve after this field has accepted input.
            // Carry that input forward without coupling later manual mode toggles.
            stackName = Self.stackNameAfterGGAvailabilityProbe(
                branch: branch,
                currentStackName: stackName
            )
        }
        .sheet(item: $issueSheetPresentation) { presentation in
            AttachIssueDialog(
                environment: attachIssueEnvironment(),
                initialDraft: presentation.draft,
                onCancel: { issueSheetPresentation = nil },
                onAttach: attachIssue
            )
            .modifier(RepoHookApprovalPresentationHandler(approvalQueue: state.repoHookApprovalQueue))
        }
        .modifier(RepoHookApprovalPresentationHandler(
            approvalQueue: state.repoHookApprovalQueue,
            isActive: issueSheetPresentation == nil
        ))
    }

    private var presetProject: ProjectConfig? {
        Self.resolvedPresetProject(presetProjectId: presetProjectId, projects: state.projects)
    }

    private var showsRepositorySelector: Bool {
        !state.projects.isEmpty && presetProject == nil
    }

    private var activeName: String {
        Self.activeName(createsGGStack: createsGGStack, branch: branch, stackName: stackName)
    }

    private var activeNameBinding: Binding<String> {
        Binding(
            get: { activeName },
            set: { newValue in
                if createsGGStack {
                    if newValue != stackName { issueState.recordUserNameEdit() }
                    stackName = newValue
                } else {
                    if newValue != branch { issueState.recordUserNameEdit() }
                    branch = newValue
                }
            }
        )
    }

    /// Nil while the field is empty: an untouched dialog should not shout a
    /// red "cannot be empty" — the disabled Create button already says so.
    /// Validates the composed branch, not the typed name, since the prefix
    /// (gg's `<username>/` or the configured worktree prefix) is part of the
    /// ref git will be asked to create.
    private var branchValidationMessage: String? {
        guard !activeName.isEmpty else { return nil }
        switch GitNameValidator.validateBranchName(effectiveBranch) {
        case .valid:
            return nil
        case .invalid(let message):
            return message
        }
    }

    /// The composed branch shown under the name field, so the prefix that is
    /// no longer typed stays visible. Hidden while the name is empty or the
    /// composition cannot be resolved (gg enabled without a branch username).
    private var branchPreviewText: String? {
        guard !activeName.isEmpty else { return nil }
        if createsGGStack {
            guard case .enabled = ggStackAvailability else { return nil }
            return Self.branchPreview(branch: effectiveBranch, base: stackPinnedBase)
        }
        return Self.branchPreview(branch: effectiveBranch, base: nil)
    }

    private var ggStackAvailability: GGStackCreateMode.Availability {
        guard let project = state.projects.first(where: { $0.id == projectId }) else { return .hidden }
        let gatePassed = state.config.changes.stackedDiffsEnabled
            && GGAvailability.shared.isInstalled
            && project.host == nil
        guard gatePassed else { return .hidden }
        return GGStackCreateMode.availability(
            gatePassed: true,
            username: GGConfigReader.branchUsername(repoPath: project.path)
        )
    }

    private var createsGGStack: Bool {
        guard let project = state.projects.first(where: { $0.id == projectId }) else { return false }
        return GGStackCreateMode.createsStack(
            masterEnabled: state.config.changes.stackedDiffsEnabled,
            ggInstalled: GGAvailability.shared.isInstalled,
            isRemoteProject: project.host != nil,
            projectMode: project.ggMode,
            worktreeMode: ggMode,
            repoHasGGConfig: GGStackGate.repoHasGGConfig(repoPath: project.path)
        )
    }

    private var stackedDiffsRequested: Bool {
        guard let project = state.projects.first(where: { $0.id == projectId }) else { return false }
        return GGStackCreateMode.createsStack(
            masterEnabled: state.config.changes.stackedDiffsEnabled,
            ggInstalled: true,
            isRemoteProject: project.host != nil,
            projectMode: project.ggMode,
            worktreeMode: ggMode,
            repoHasGGConfig: GGStackGate.repoHasGGConfig(repoPath: project.path)
        )
    }

    private var ggConfigurationMissing: Bool {
        guard createsGGStack else { return false }
        if case .disabled = ggStackAvailability { return true }
        return false
    }

    /// The branch actually created. Neither prefix is ever typed into the
    /// name field: in stack mode the branch follows gg's `<username>/<name>`
    /// convention, otherwise the configured worktree branch prefix is
    /// composed with the typed name.
    private var effectiveBranch: String {
        if createsGGStack, case .enabled(let username) = ggStackAvailability {
            return GGConfigReader.composeStackBranch(username: username, stackName: stackName)
        }
        return Self.composedBranch(prefix: state.config.worktrees.branchPrefix, name: branch)
    }

    /// When creating a gg stack, the worktree base is pinned to gg's
    /// `defaults.base` so the branch is cut from the commit gg will treat as
    /// the stack base — otherwise a non-default pick would leave gg
    /// syncing/PR-ing against the repo default. Nil when create-as-stack is
    /// off/unavailable or gg config records no base (then the picker stays free).
    private var stackPinnedBase: String? {
        guard createsGGStack, case .enabled = ggStackAvailability,
              let project = state.projects.first(where: { $0.id == projectId })
        else { return nil }
        return GGConfigReader.defaultBase(repoPath: project.path)
    }

    private var subtitleText: String {
        guard let project = state.projects.first(where: { $0.id == projectId }) else {
            return "Create a worktree."
        }
        return "Create a worktree in \(project.name) branched from \(base)."
    }

    private var effectiveAutoLaunchAgent: AgentDefinition? {
        guard let project = state.projects.first(where: { $0.id == projectId }) else { return nil }
        let agentId = Self.resolvedAutoLaunchAgentID(
            globalAgentId: state.config.agents.worktreeAutoLaunch.agentId,
            projectMode: project.startupScripts.worktreeAgentMode,
            projectAgentId: project.startupScripts.worktreeAgentId,
            repoAgentId: repoDefaultAgentId,
            enabledAgents: launchEligibleAgents
        )
        return agentId.flatMap { id in launchEligibleAgents.first { $0.id == id } }
    }

    /// The repo's `.alas/config.json` default agent when it names an
    /// installed, enabled agent. The worktree being created does not exist
    /// yet, so this resolves from the primary checkout. Local projects only.
    private var repoDefaultAgentId: String? {
        guard let project = state.projects.first(where: { $0.id == projectId }),
              project.host == nil,
              let candidate = state.repoConfig(
                  worktreeRoot: URL(fileURLWithPath: project.path, isDirectory: true)
              )?.defaultAgent else {
            return nil
        }
        return launchEligibleAgents.contains(where: { $0.id == candidate }) ? candidate : nil
    }

    private var currentLaunchPreference: NewWorktreeLaunchPreference {
        .init(
            openAfterCreate: openAfterCreate,
            launchMode: launchMode,
            persistableLaunchMode: persistableLaunchMode,
            launchAgentID: launchAgentId
        )
    }

    private var renderedPath: String {
        guard let project = state.projects.first(where: { $0.id == projectId }) else { return "" }
        return WorktreePathTemplateRenderer.render(
            template: state.config.worktrees.pathTemplate,
            worktreeRoot: state.config.worktrees.rootPath,
            repoName: project.name,
            branch: effectiveBranch
        ).path
    }

    private func loadBranchesForSelectedProject() {
        createErrorMessage = nil
        guard let project = state.projects.first(where: { $0.id == projectId }) else {
            branches = []
            branchLoadError = nil
            isLoadingBranches = false
            return
        }

        let selectedProjectId = project.id
        let baseBeforeLoad = base
        isLoadingBranches = true
        branchLoadError = nil
        Task {
            do {
                let discovered = try await GitService().branches(at: URL(fileURLWithPath: project.path))
                guard projectId == selectedProjectId else { return }
                branches = discovered
                let preferred = Self.preferredBaseBranch(
                    availableBranches: discovered,
                    configuredDefault: state.config.worktrees.baseBranch
                )
                if base == baseBeforeLoad, stackPinnedBase == nil {
                    base = preferred
                }
            } catch {
                guard projectId == selectedProjectId else { return }
                branches = []
                branchLoadError = error.localizedDescription
                if base.isEmpty {
                    base = state.config.worktrees.baseBranch
                }
            }
            guard projectId == selectedProjectId else { return }
            isLoadingBranches = false
        }
    }

    private func applyLaunchDefaults(for selectedProjectId: String) {
        let project = state.projects.first { $0.id == selectedProjectId }
        let preference = project?.effectiveWorktreeLaunchPreference
        let defaults = Self.resolvedLaunchDefaults(
            projectOpenAfterCreate: preference?.openAfterCreate,
            projectLauncherMode: preference?.launcherMode,
            globalLauncherMode: state.config.agents.defaultLauncherMode,
            acpSegmentEnabled: acpSegmentEnabled
        )
        launchMode = Self.initialLaunchMode(
            preferredMode: defaults.launchMode,
            projectAgentMode: project?.startupScripts.worktreeAgentMode ?? .useGlobal,
            resolvedAgentID: effectiveAutoLaunchAgent?.id,
            enabledAgents: launchEligibleAgents
        )
        persistableLaunchMode = defaults.persistableLaunchMode
        openAfterCreate = defaults.openAfterCreate
        let initialAgent = effectiveAutoLaunchAgent?.id ?? "none"
        launchAgentId = Self.resolvedLaunchAgent(
            initialAgentId: initialAgent,
            mode: launchMode,
            enabledAgents: launchEligibleAgents
        )
    }

    private func attachIssueEnvironment() -> AttachIssueDialogModel.Environment {
        let loader = state.makeIssueSuggestionLoader()
        return .init(
            resolve: { reference in
                try await state.makeIssueResolver(selectedProjectID: projectId).resolve(reference)
            },
            loadSuggestions: { projectID, limit in
                try await loader.suggestions(projectID: projectID, limit: limit)
            },
            selectedProjectID: projectId,
            projects: { state.projects }
        )
    }

    private func attachIssue(_ draft: AttachedIssueDraft) {
        let shouldApplyParentFields = Self.appliesParentFieldsAfterIssueAttach(existingDraft: issueState.draft)
        cancelNameSuggestion()
        let effects = issueState.attach(draft, currentLaunch: currentLaunchPreference)
        guard shouldApplyParentFields else {
            issueSheetPresentation = nil
            createErrorMessage = nil
            return
        }
        let resolvedProjectID = Self.projectIDAfterIssueAttach(
            preferredProjectID: effects.preferredProjectID,
            currentProjectID: projectId,
            availableProjectIDs: state.projects.map(\.id)
        )
        if projectId != resolvedProjectID {
            issueDrivenProjectChangeID = resolvedProjectID
            projectId = resolvedProjectID
            applyGGModeDefault(for: resolvedProjectID)
            base = stackPinnedBase ?? state.config.worktrees.baseBranch
            loadBranchesForSelectedProject()
        }
        let names = Self.namesAfterIssueAttach(
            branchSeed: effects.branchSeed,
            createsGGStack: createsGGStack,
            branch: branch,
            stackName: stackName
        )
        branch = names.branch
        stackName = names.stackName
        startNameSuggestion()
        if effects.shouldSelectChat, acpSegmentEnabled {
            openAfterCreate = true
            launchMode = .acp
            persistableLaunchMode = .acp
            launchAgentId = Self.issueLaunchAgent(
                from: launchEligibleAgents,
                preferredAgentID: effectiveAutoLaunchAgent?.id
            )
        }
        issueSheetPresentation = nil
        createErrorMessage = nil
    }

    /// The deterministic seed is already in the field; this only upgrades its
    /// title component if the local model answers before the user edits it.
    private func startNameSuggestion() {
        guard state.issueWorktreeNameSuggestionsAvailable,
              let request = issueState.beginNameSuggestion() else { return }
        let suggester = state.makeIssueWorktreeNameSuggester()
        nameSuggestionTask = Task { @MainActor in
            let semanticName = await suggester.suggestName(for: request.source)
            guard !Task.isCancelled else { return }
            nameSuggestionTask = nil
            guard let names = issueState.completeNameSuggestion(
                request.id,
                semanticName: semanticName,
                branch: branch,
                stackName: stackName
            ) else { return }
            branch = names.branch
            stackName = names.stackName
        }
    }

    private func cancelNameSuggestion() {
        nameSuggestionTask?.cancel()
        nameSuggestionTask = nil
    }

    private func removeIssue() {
        cancelNameSuggestion()
        if let preference = issueState.remove() {
            openAfterCreate = preference.openAfterCreate
            launchMode = preference.launchMode
            persistableLaunchMode = preference.persistableLaunchMode
            launchAgentId = preference.launchAgentID
        }
    }

    private func applyGGModeDefault(for selectedProjectId: String) {
        guard let project = state.projects.first(where: { $0.id == selectedProjectId }) else {
            ggMode = .off
            return
        }
        ggMode = Self.initialGGMode(
            projectMode: project.ggMode,
            repoHasGGConfig: GGStackGate.repoHasGGConfig(repoPath: project.path)
        )
    }

    private func create() {
        guard let project = state.projects.first(where: { $0.id == projectId }) else { return }
        cancelNameSuggestion()
        let dest = URL(fileURLWithPath: renderedPath)
        let issueDraft = issueState.draft
        guard launchMode != .acp || !openAfterCreate || launchAgentId != "none" else {
            // Defensive: confirm button should already be disabled.
            createErrorMessage = "Pick an ACP-capable agent for the chat session."
            return
        }
        let surface = Self.launchSurfaceForCreate(
            openAfterCreate: openAfterCreate,
            launchMode: launchMode,
            launchAgentId: launchAgentId,
            issueDraft: issueDraft,
            makePreparedPrompt: { prompt in
                PreparedWorktreeACPPrompt(
                    sessionID: UUID().uuidString,
                    promptID: UUID(),
                    text: prompt
                )
            }
        )
        Task { @MainActor in
            let id = await state.createWorktree(
                projectId: project.id,
                base: base,
                branch: effectiveBranch,
                destination: dest,
                runStartup: runStartup,
                launchSurface: surface,
                ggWorktreeMode: ggMode,
                issueAttachment: issueDraft?.attachment
            )
            guard !id.isEmpty else {
                createErrorMessage = "A worktree already exists at this path."
                return
            }
            state.setWorktreeLaunchDefaults(
                projectId: project.id,
                openAfterCreate: openAfterCreate,
                launcherMode: persistableLaunchMode
            )
            createErrorMessage = nil
            presented = false
        }
    }

    private func submitCreate() {
        guard Self.canCreate(
            projectsEmpty: state.projects.isEmpty,
            branchEmpty: activeName.isEmpty,
            branchValidation: branchValidationMessage,
            ggConfigurationMissing: ggConfigurationMissing,
            requiresAcpAgent: openAfterCreate && launchMode == .acp,
            hasAcpAgent: launchAgentId != "none"
        ) else { return }
        create()
    }

    nonisolated static func canCreate(
        projectsEmpty: Bool,
        branchEmpty: Bool,
        branchValidation: String? = nil,
        ggConfigurationMissing: Bool = false,
        requiresAcpAgent: Bool = false,
        hasAcpAgent: Bool = true
    ) -> Bool {
        guard !projectsEmpty, !branchEmpty, branchValidation == nil, !ggConfigurationMissing else { return false }
        if requiresAcpAgent, !hasAcpAgent { return false }
        return true
    }

    nonisolated static func ggModeDescription(
        mode: GGWorktreeMode,
        createsGGStack: Bool
    ) -> String {
        switch mode {
        case .inherit:
            createsGGStack
                ? "Uses repository default: On."
                : "Uses repository default: Off. Creates a regular Git branch."
        case .on:
            "GG enabled for this worktree."
        case .off:
            "GG disabled for this worktree. Creates a regular Git branch."
        }
    }

    nonisolated static func initialGGMode(
        projectMode: GGProjectMode,
        repoHasGGConfig: Bool
    ) -> GGWorktreeMode {
        GGWorktreeContextResolver.isPolicyEnabled(
            projectMode: projectMode,
            worktreeOverride: .inherit,
            isMainWorktree: false,
            repoHasGGConfig: repoHasGGConfig
        ) ? .on : .off
    }

    nonisolated static func ggModeAfterRepositoryChange(
        projectMode: GGProjectMode,
        repoHasGGConfig: Bool
    ) -> GGWorktreeMode {
        initialGGMode(
            projectMode: projectMode,
            repoHasGGConfig: repoHasGGConfig
        )
    }

    nonisolated static func initialBase(
        configuredDefault: String,
        stackPinnedBase: String?
    ) -> String {
        stackPinnedBase ?? configuredDefault
    }

    nonisolated static func composedBranch(prefix: String, name: String) -> String {
        name.isEmpty ? "" : prefix + name
    }

    nonisolated static func branchPreview(branch: String, base: String?) -> String {
        guard let base else { return "Branch: \(branch)" }
        return "Branch: \(branch), based on \(base)"
    }

    nonisolated static func activeName(
        createsGGStack: Bool,
        branch: String,
        stackName: String
    ) -> String {
        createsGGStack ? stackName : branch
    }

    /// Carries a name typed before gg's availability probe resolved into the
    /// stack field. Both fields hold a bare name, so this is a plain carry.
    nonisolated static func stackNameAfterGGAvailabilityProbe(
        branch: String,
        currentStackName: String
    ) -> String {
        currentStackName.isEmpty ? branch : currentStackName
    }

    nonisolated static func resolvedPresetProject(
        presetProjectId: String?,
        projects: [ProjectConfig]
    ) -> ProjectConfig? {
        guard let presetProjectId else { return nil }
        return projects.first { $0.id == presetProjectId }
    }

    nonisolated static func initialProjectId(
        presetProjectId: String?,
        projects: [ProjectConfig]
    ) -> String {
        resolvedPresetProject(presetProjectId: presetProjectId, projects: projects)?.id
            ?? projects.first?.id
            ?? ""
    }

    nonisolated static func initialSelection(
        presetProjectId: String?,
        projects: [ProjectConfig],
        repoHasGGConfig: (ProjectConfig) -> Bool
    ) -> (projectId: String, ggMode: GGWorktreeMode) {
        guard let project = resolvedPresetProject(
            presetProjectId: presetProjectId,
            projects: projects
        ) ?? projects.first else {
            return ("", .off)
        }

        return (
            project.id,
            initialGGMode(
                projectMode: project.ggMode,
                repoHasGGConfig: repoHasGGConfig(project)
            )
        )
    }

    nonisolated static func showsRepositorySelector(
        presetProjectId: String?,
        projects: [ProjectConfig]
    ) -> Bool {
        !projects.isEmpty && resolvedPresetProject(presetProjectId: presetProjectId, projects: projects) == nil
    }

    nonisolated static func preferredBaseBranch(
        availableBranches: [String],
        configuredDefault: String
    ) -> String {
        if !configuredDefault.isEmpty && availableBranches.contains(configuredDefault) {
            return configuredDefault
        }
        for preferred in ["main", "master", "trunk"] where availableBranches.contains(preferred) {
            return preferred
        }
        return availableBranches.first ?? configuredDefault
    }

    nonisolated static func projectIDAfterIssueAttach(
        preferredProjectID: String?,
        currentProjectID: String,
        availableProjectIDs: [String]
    ) -> String {
        guard let preferredProjectID,
              availableProjectIDs.contains(preferredProjectID)
        else { return currentProjectID }
        return preferredProjectID
    }

    /// `branchSeed` is a bare name (no configured prefix, no gg username), so
    /// it drops straight into whichever field is active.
    nonisolated static func namesAfterIssueAttach(
        branchSeed: String,
        createsGGStack: Bool,
        branch: String,
        stackName: String
    ) -> (branch: String, stackName: String) {
        if createsGGStack {
            return (branch, branchSeed)
        }
        return (branchSeed, stackName)
    }

    nonisolated static func issueLaunchAgent(from agents: [AgentDefinition], preferredAgentID: String? = nil) -> String {
        resolvedLaunchAgent(initialAgentId: preferredAgentID ?? "none", mode: .acp, enabledAgents: agents)
    }

    nonisolated static func issuePromptForLaunch(
        draft: AttachedIssueDraft?,
        openAfterCreate: Bool,
        launchMode: AppConfig.LauncherMode
    ) -> String? {
        guard openAfterCreate, launchMode == .acp else { return nil }
        return draft?.prompt
    }

    nonisolated static func launchSurfaceForCreate(
        openAfterCreate: Bool,
        launchMode: AppConfig.LauncherMode,
        launchAgentId: String,
        issueDraft: AttachedIssueDraft?,
        makePreparedPrompt: (String) -> PreparedWorktreeACPPrompt
    ) -> WorktreeLaunchSurface {
        guard openAfterCreate else { return .none }
        switch launchMode {
        case .terminal:
            return .terminal(agentId: launchAgentId == "none" ? nil : launchAgentId)
        case .acp:
            let preparedPrompt = issueDraft.map { makePreparedPrompt($0.prompt) }
            return .acp(agentId: launchAgentId, preparedPrompt: preparedPrompt)
        }
    }

    nonisolated static func appliesParentFieldsAfterIssueAttach(existingDraft: AttachedIssueDraft?) -> Bool {
        existingDraft == nil
    }

    nonisolated static func appliesLaunchDefaultsAfterProjectChange(
        projectID: String,
        issueDrivenProjectID: String?
    ) -> Bool {
        issueDrivenProjectID != projectID
    }

    nonisolated static let ggModeSegments: [NewWorktreeGGModeSegment] = [
        .init(mode: .on, label: "On", icon: .stack),
        .init(mode: .off, label: "Off", icon: .disabled),
    ]

    private var ggModeSegmented: some View {
        HStack(spacing: 0) {
            AlasSegmentedControl(
                selection: ggMode,
                options: Self.ggModeSegments.map {
                    AlasSegmentedOption(
                        id: $0.mode,
                        label: $0.label,
                        segmentedIcon: .gg($0.icon)
                    )
                },
                onSelect: { ggMode = $0 }
            )
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var issueAttachmentSection: some View {
        if let draft = issueState.draft {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Issue")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(theme.color("fg-muted"))
                    Text(draft.attachment.displayTitle)
                        .font(.system(size: 12))
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                AlasButton(title: "Edit", style: .subtle) {
                    issueSheetPresentation = AttachIssuePresentation(draft: draft)
                }
                AlasButton(title: "Remove", style: .subtle, action: removeIssue)
                AlasButton(title: "Open", style: .subtle) {
                    NSWorkspace.shared.open(draft.attachment.canonicalURL)
                }
            }
            .padding(8)
            .background(theme.color("bg-0"))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Launch surface UI

    private var pickerAgents: [AgentDefinition] {
        let enabled = launchEligibleAgents
        switch launchMode {
        case .terminal: return enabled
        case .acp:      return Self.acpCapableAgents(from: enabled)
        }
    }

    private var acpSegmentEnabled: Bool {
        Self.acpSegmentEnabled(enabledAgents: launchEligibleAgents)
    }

    private var launchEligibleAgents: [AgentDefinition] {
        Self.launchEligibleAgents(
            isRemoteProject: state.projects.first(where: { $0.id == projectId })?.host != nil,
            configuredEnabledAgents: configuredEnabledAgents,
            locallyEnabledAgents: state.agentRegistry.enabled()
        )
    }

    private var configuredEnabledAgents: [AgentDefinition] {
        AgentConfiguredCatalog.enabled(
            builtinState: state.config.agents.builtinState,
            customs: state.config.agents.custom
        )
    }

    private var launchAgentPicker: some View {
        Picker("", selection: launchAgentSelection) {
            if launchMode == .terminal {
                Text("None").tag("none")
            }
            ForEach(pickerAgents) { agent in
                Label {
                    Text(agent.displayName)
                } icon: {
                    Image(nsImage: AgentLogoView.menuImage(for: agent, size: 14))
                }
                .tag(agent.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    private var launchAgentSelection: Binding<String> {
        Binding(
            get: { launchAgentId },
            set: { newValue in
                launchAgentId = newValue
                issueState.recordLaunchPreferenceChangeAfterAttach()
            }
        )
    }

    private var launchSurfaceSegmented: some View {
        HStack(spacing: 0) {
            AlasSegmentedControl(
                selection: selectedLaunchSurfaceSegment,
                options: [
                    AlasSegmentedOption(id: .none, label: "No tab", icon: "circle.slash"),
                    AlasSegmentedOption(id: .terminal, label: "Terminal", icon: "terminal"),
                    AlasSegmentedOption(
                        id: .acp,
                        label: "Chat",
                        icon: "sparkle",
                        isEnabled: acpSegmentEnabled,
                        disabledHelp: "Enable an ACP-capable agent in Settings → Agents."
                    ),
                ],
                onSelect: selectLaunchSurface
            )
            Spacer(minLength: 0)
        }
    }

    private var selectedLaunchSurfaceSegment: NewWorktreeLaunchSurfaceSegment {
        if !openAfterCreate { return .none }
        return launchMode == .terminal ? .terminal : .acp
    }

    private func selectLaunchSurface(_ segment: NewWorktreeLaunchSurfaceSegment) {
        switch segment {
        case .none:
            openAfterCreate = false
        case .terminal:
            openAfterCreate = true
            launchMode = .terminal
            persistableLaunchMode = .terminal
            launchAgentId = Self.resolvedLaunchAgent(
                initialAgentId: launchAgentId,
                mode: .terminal,
                enabledAgents: launchEligibleAgents
            )
        case .acp:
            guard acpSegmentEnabled else { return }
            openAfterCreate = true
            launchMode = .acp
            persistableLaunchMode = .acp
            launchAgentId = Self.resolvedLaunchAgent(
                initialAgentId: launchAgentId,
                mode: .acp,
                enabledAgents: launchEligibleAgents
            )
        }
        issueState.recordLaunchPreferenceChangeAfterAttach()
    }

    // MARK: - Launch surface helpers

    nonisolated static func acpCapableAgents(from agents: [AgentDefinition]) -> [AgentDefinition] {
        let acpIds = Set(ACPLaunchCatalog.specs.map(\.agentID))
        return agents.filter { acpIds.contains($0.id) }
    }

    nonisolated static func launchEligibleAgents(
        isRemoteProject: Bool,
        configuredEnabledAgents: [AgentDefinition],
        locallyEnabledAgents: [AgentDefinition]
    ) -> [AgentDefinition] {
        isRemoteProject ? configuredEnabledAgents : locallyEnabledAgents
    }

    nonisolated static func resolvedAutoLaunchAgentID(
        globalAgentId: String?,
        projectMode: ProjectStartupScriptMode,
        projectAgentId: String?,
        repoAgentId: String?,
        enabledAgents: [AgentDefinition]
    ) -> String? {
        func enabled(_ id: String?) -> String? {
            guard let id, enabledAgents.contains(where: { $0.id == id }) else { return nil }
            return id
        }

        switch projectMode {
        case .disabled:
            return nil
        case .useGlobal:
            return enabled(repoAgentId) ?? enabled(globalAgentId)
        case .overrideGlobal, .appendToGlobal:
            return enabled(projectAgentId)
        }
    }

    nonisolated static func acpSegmentEnabled(enabledAgents: [AgentDefinition]) -> Bool {
        !acpCapableAgents(from: enabledAgents).isEmpty
    }

    nonisolated static func launchSurfaceSegmentFocusable(
        _ segment: NewWorktreeLaunchSurfaceSegment,
        acpSegmentEnabled: Bool
    ) -> Bool {
        switch segment {
        case .none, .terminal:
            return true
        case .acp:
            return acpSegmentEnabled
        }
    }

    /// Repository overrides must not silently launch a different chat agent.
    /// Explicitly choosing Chat later still uses the normal chat picker fallback.
    nonisolated static func initialLaunchMode(
        preferredMode: AppConfig.LauncherMode,
        projectAgentMode: ProjectStartupScriptMode,
        resolvedAgentID: String?,
        enabledAgents: [AgentDefinition]
    ) -> AppConfig.LauncherMode {
        guard preferredMode == .acp, projectAgentMode != .useGlobal else { return preferredMode }
        guard projectAgentMode != .disabled,
              let resolvedAgentID,
              acpCapableAgents(from: enabledAgents).contains(where: { $0.id == resolvedAgentID }) else {
            return .terminal
        }
        return .acp
    }

    /// Decide which agent id the picker should hold given the desired
    /// `mode`. In terminal mode any enabled agent (or "none") is valid.
    /// In ACP mode "none" is not allowed and the agent must be
    /// ACP-capable; if the incoming id isn't, fall back to the first
    /// ACP-capable enabled agent, or "none" if none exist.
    nonisolated static func resolvedLaunchAgent(
        initialAgentId: String,
        mode: AppConfig.LauncherMode,
        enabledAgents: [AgentDefinition]
    ) -> String {
        switch mode {
        case .terminal:
            return initialAgentId
        case .acp:
            let capable = acpCapableAgents(from: enabledAgents)
            if initialAgentId != "none", capable.contains(where: { $0.id == initialAgentId }) {
                return initialAgentId
            }
            return capable.first?.id ?? "none"
        }
    }

    /// Resolve launch mode and openAfterCreate from per-project config,
    /// falling back to global defaults. Returns the effective UI values plus the
    /// persistable mode (which preserves the user's intent when ACP is temporarily unavailable).
    nonisolated static func resolvedLaunchDefaults(
        projectOpenAfterCreate: Bool?,
        projectLauncherMode: AppConfig.LauncherMode?,
        globalLauncherMode: AppConfig.LauncherMode,
        acpSegmentEnabled: Bool
    ) -> (openAfterCreate: Bool, launchMode: AppConfig.LauncherMode, persistableLaunchMode: AppConfig.LauncherMode) {
        let intended = projectLauncherMode ?? globalLauncherMode
        var mode = intended
        if mode == .acp, !acpSegmentEnabled {
            mode = .terminal
        }
        let open = projectOpenAfterCreate ?? true
        return (open, mode, intended)
    }
}
