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
    // Defaults are seeded from the persisted Worktrees settings in .onAppear
    // (these literals are placeholders only — the real defaults come from
    // state.config.worktrees.{baseBranch,branchPrefix}).
    @State private var base: String = ""
    @State private var branch: String = ""
    @State private var stackName: String = ""
    @State private var runStartup: Bool = true
    @State private var ggMode: GGWorktreeMode = .off
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

    @Environment(\.theme) var theme

    init(
        state: AppState,
        presented: Binding<Bool>,
        presetProjectId: String? = nil
    ) {
        self.state = state
        self._presented = presented
        self.presetProjectId = presetProjectId
        self._projectId = State(initialValue: Self.initialProjectId(
            presetProjectId: presetProjectId,
            projects: state.projects
        ))
    }

    var body: some View {
        DialogContainer(
            title: "New worktree",
            subtitle: subtitleText,
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
                            projects: state.projects
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
                        inputFilter: .branchName
                    )
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
                    } else if createsGGStack, case .enabled(let username) = ggStackAvailability, !stackName.isEmpty {
                        Text(Self.ggBranchPreview(
                            branch: GGConfigReader.composeStackBranch(username: username, stackName: stackName),
                            base: stackPinnedBase
                        ))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.color("fg-dim"))
                    }
                }
                if let validationMessage = branchValidationMessage, activeName != state.config.worktrees.branchPrefix {
                    Text(validationMessage).font(.system(size: 11)).foregroundColor(.red)
                }
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
            if branch.isEmpty {
                branch = state.config.worktrees.branchPrefix
            }
            applyLaunchDefaults(for: projectId)
            loadBranchesForSelectedProject()
        }
        .onChange(of: projectId) { _, _ in
            applyGGModeDefault(for: projectId)
            applyLaunchDefaults(for: projectId)
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
                    stackName = newValue
                } else {
                    branch = newValue
                }
            }
        )
    }

    private var branchValidationMessage: String? {
        let result = GitNameValidator.validateBranchName(activeName)
        switch result {
        case .valid:
            return nil
        case .invalid(let message):
            return message
        }
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

    private var ggConfigurationMissing: Bool {
        guard createsGGStack else { return false }
        if case .disabled = ggStackAvailability { return true }
        return false
    }

    /// The branch actually created. In stack mode the real branch follows
    /// gg's `<username>/<name>` convention; otherwise the plain branch field
    /// is used verbatim (including its seeded global branch prefix).
    private var effectiveBranch: String {
        if createsGGStack, case .enabled(let username) = ggStackAvailability {
            return GGConfigReader.composeStackBranch(username: username, stackName: stackName)
        }
        return branch
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
        let resolved = AgentAutoLaunch.resolve(
            registry: state.agentRegistry,
            globalAgentId: state.config.agents.worktreeAutoLaunch.agentId,
            globalUseBypass: state.config.agents.worktreeAutoLaunch.useBypassPermissions,
            projectMode: project.startupScripts.worktreeAgentMode,
            projectAgentId: project.startupScripts.worktreeAgentId,
            projectUseBypass: project.startupScripts.worktreeAgentUseBypassPermissions
        )
        return resolved.flatMap { state.agent(id: $0.agentId) }
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
        let defaults = Self.resolvedLaunchDefaults(
            projectOpenAfterCreate: project?.worktreeOpenAfterCreate,
            projectLauncherMode: project?.worktreeDefaultLauncherMode,
            globalLauncherMode: state.config.agents.defaultLauncherMode,
            acpSegmentEnabled: acpSegmentEnabled
        )
        launchMode = defaults.launchMode
        persistableLaunchMode = defaults.persistableLaunchMode
        openAfterCreate = defaults.openAfterCreate
        let initialAgent = effectiveAutoLaunchAgent?.id ?? "none"
        launchAgentId = Self.resolvedLaunchAgent(
            initialAgentId: initialAgent,
            mode: launchMode,
            enabledAgents: state.agentRegistry.enabled()
        )
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
        let dest = URL(fileURLWithPath: renderedPath)
        let surface: WorktreeLaunchSurface
        if !openAfterCreate {
            surface = .none
        } else {
            switch launchMode {
            case .terminal:
                surface = .terminal(agentId: launchAgentId == "none" ? nil : launchAgentId)
            case .acp:
                guard launchAgentId != "none" else {
                    // Defensive: confirm button should already be disabled.
                    createErrorMessage = "Pick an ACP-capable agent for the chat session."
                    return
                }
                surface = .acp(agentId: launchAgentId)
            }
        }
        Task { @MainActor in
            let id = await state.createWorktree(
                projectId: project.id,
                base: base,
                branch: effectiveBranch,
                destination: dest,
                runStartup: runStartup,
                launchSurface: surface,
                ggWorktreeMode: ggMode
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

    nonisolated static func ggBranchPreview(branch: String, base: String?) -> String {
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

    // MARK: - Launch surface UI

    private var pickerAgents: [AgentDefinition] {
        let enabled = state.agentRegistry.enabled()
        switch launchMode {
        case .terminal: return enabled
        case .acp:      return Self.acpCapableAgents(from: enabled)
        }
    }

    private var acpSegmentEnabled: Bool {
        Self.acpSegmentEnabled(enabledAgents: state.agentRegistry.enabled())
    }

    private var launchAgentPicker: some View {
        Picker("", selection: $launchAgentId) {
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
                enabledAgents: state.agentRegistry.enabled()
            )
        case .acp:
            guard acpSegmentEnabled else { return }
            openAfterCreate = true
            launchMode = .acp
            persistableLaunchMode = .acp
            launchAgentId = Self.resolvedLaunchAgent(
                initialAgentId: launchAgentId,
                mode: .acp,
                enabledAgents: state.agentRegistry.enabled()
            )
        }
    }

    // MARK: - Launch surface helpers

    nonisolated static func acpCapableAgents(from agents: [AgentDefinition]) -> [AgentDefinition] {
        let acpIds = Set(ACPLaunchCatalog.specs.map(\.agentID))
        return agents.filter { acpIds.contains($0.id) }
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
