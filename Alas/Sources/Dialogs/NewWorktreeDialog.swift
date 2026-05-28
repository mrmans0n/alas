import SwiftUI

struct NewWorktreeDialog: View {
    @Bindable var state: AppState
    @Binding var presented: Bool
    var presetProjectId: String? = nil

    @State private var projectId: String = ""
    // Defaults are seeded from the persisted Worktrees settings in .onAppear
    // (these literals are placeholders only — the real defaults come from
    // state.config.worktrees.{baseBranch,branchPrefix}).
    @State private var base: String = ""
    @State private var branch: String = ""
    @State private var runStartup: Bool = true
    @State private var openAfterCreate: Bool = true
    @State private var launchMode: AppConfig.LauncherMode = .terminal
    @State private var launchAgentId: String = "none"
    @State private var branches: [String] = []
    @State private var isLoadingBranches = false
    @State private var branchLoadError: String?
    @State private var createErrorMessage: String?

    @Environment(\.theme) var theme

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
                }
                DialogField(label: "Branch name") {
                    AlasField(
                        text: $branch,
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
                if let validationMessage = branchValidationMessage, branch != state.config.worktrees.branchPrefix {
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
                branchEmpty: branch.isEmpty,
                branchValidation: branchValidationMessage,
                requiresAcpAgent: openAfterCreate && launchMode == .acp,
                hasAcpAgent: launchAgentId != "none"
            )
        )
        .onAppear {
            if projectId.isEmpty {
                if let preset = presetProjectId, state.projects.contains(where: { $0.id == preset }) {
                    projectId = preset
                } else {
                    projectId = state.projects.first?.id ?? ""
                }
            }
            if base.isEmpty {
                base = state.config.worktrees.baseBranch
            }
            if branch.isEmpty {
                branch = state.config.worktrees.branchPrefix
            }
            applyLaunchDefaults(for: projectId)
            loadBranchesForSelectedProject()
        }
        .onChange(of: projectId) { _, _ in
            applyLaunchDefaults(for: projectId)
            loadBranchesForSelectedProject()
        }
        .onChange(of: branch) { _, _ in
            createErrorMessage = nil
        }
    }

    private var presetProject: ProjectConfig? {
        Self.resolvedPresetProject(presetProjectId: presetProjectId, projects: state.projects)
    }

    private var showsRepositorySelector: Bool {
        !state.projects.isEmpty && presetProject == nil
    }

    private var branchValidationMessage: String? {
        let result = GitNameValidator.validateBranchName(branch)
        switch result {
        case .valid:
            return nil
        case .invalid(let message):
            return message
        }
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
        let template = state.config.worktrees.pathTemplate
            .replacingOccurrences(of: "{worktreeRoot}", with: state.config.worktrees.rootPath)
            .replacingOccurrences(of: "{repo}", with: project.name.split(separator: "/").last.map(String.init) ?? "repo")
            .replacingOccurrences(of: "{branch}", with: branch.replacingOccurrences(of: "/", with: "-"))
            .replacingOccurrences(of: "{user}", with: NSUserName())
            .replacingOccurrences(of: "{ts}", with: ISO8601DateFormatter().string(from: Date()))
        return (template as NSString).expandingTildeInPath
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
                if base == baseBeforeLoad {
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
        openAfterCreate = defaults.openAfterCreate
        let initialAgent = effectiveAutoLaunchAgent?.id ?? "none"
        launchAgentId = Self.resolvedLaunchAgent(
            initialAgentId: initialAgent,
            mode: launchMode,
            enabledAgents: state.agentRegistry.enabled()
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
        let id = state.createWorktree(
            projectId: project.id,
            base: base,
            branch: branch,
            destination: dest,
            runStartup: runStartup,
            launchSurface: surface
        )
        guard !id.isEmpty else {
            createErrorMessage = "A worktree already exists at this path."
            return
        }
        state.setWorktreeLaunchDefaults(
            projectId: project.id,
            openAfterCreate: openAfterCreate,
            launcherMode: launchMode
        )
        createErrorMessage = nil
        presented = false
    }

    private func submitCreate() {
        guard Self.canCreate(
            projectsEmpty: state.projects.isEmpty,
            branchEmpty: branch.isEmpty,
            branchValidation: branchValidationMessage,
            requiresAcpAgent: openAfterCreate && launchMode == .acp,
            hasAcpAgent: launchAgentId != "none"
        ) else { return }
        create()
    }

    nonisolated static func canCreate(
        projectsEmpty: Bool,
        branchEmpty: Bool,
        branchValidation: String? = nil,
        requiresAcpAgent: Bool = false,
        hasAcpAgent: Bool = true
    ) -> Bool {
        guard !projectsEmpty, !branchEmpty, branchValidation == nil else { return false }
        if requiresAcpAgent, !hasAcpAgent { return false }
        return true
    }

    nonisolated static func resolvedPresetProject(
        presetProjectId: String?,
        projects: [ProjectConfig]
    ) -> ProjectConfig? {
        guard let presetProjectId else { return nil }
        return projects.first { $0.id == presetProjectId }
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
            HStack(spacing: 2) {
                segment(
                    isSelected: !openAfterCreate,
                    icon: "circle.slash",
                    label: "No tab",
                    isEnabled: true
                ) {
                    openAfterCreate = false
                }
                segment(
                    isSelected: openAfterCreate && launchMode == .terminal,
                    icon: "terminal",
                    label: "Terminal",
                    isEnabled: true
                ) {
                    openAfterCreate = true
                    launchMode = .terminal
                    launchAgentId = Self.resolvedLaunchAgent(
                        initialAgentId: launchAgentId,
                        mode: .terminal,
                        enabledAgents: state.agentRegistry.enabled()
                    )
                }
                segment(
                    isSelected: openAfterCreate && launchMode == .acp,
                    icon: "sparkle",
                    label: "Chat",
                    isEnabled: acpSegmentEnabled,
                    disabledHelp: "Enable an ACP-capable agent in Settings → Agents."
                ) {
                    openAfterCreate = true
                    launchMode = .acp
                    launchAgentId = Self.resolvedLaunchAgent(
                        initialAgentId: launchAgentId,
                        mode: .acp,
                        enabledAgents: state.agentRegistry.enabled()
                    )
                }
            }
            .padding(2)
            .background(theme.color("seg-container-bg"))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Spacer(minLength: 0)
        }
    }

    private func segment(
        isSelected: Bool,
        icon: String,
        label: String,
        isEnabled: Bool,
        disabledHelp: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Icon(name: icon, size: 11,
                     color: isSelected ? theme.color("fg") : theme.color("fg-muted"))
                Text(label)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? theme.color("fg") : theme.color("fg-muted"))
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 4).fill(theme.color("bg-3"))
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.04), lineWidth: 1)
                            .blendMode(.plusLighter)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .modifier(SegmentHelpModifier(text: isEnabled ? nil : disabledHelp))
    }

    private struct SegmentHelpModifier: ViewModifier {
        let text: String?
        func body(content: Content) -> some View {
            if let text { content.help(text) } else { content }
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
    /// falling back to global defaults. Returns the effective values.
    nonisolated static func resolvedLaunchDefaults(
        projectOpenAfterCreate: Bool?,
        projectLauncherMode: AppConfig.LauncherMode?,
        globalLauncherMode: AppConfig.LauncherMode,
        acpSegmentEnabled: Bool
    ) -> (openAfterCreate: Bool, launchMode: AppConfig.LauncherMode) {
        var mode = projectLauncherMode ?? globalLauncherMode
        if mode == .acp, !acpSegmentEnabled {
            mode = .terminal
        }
        let open = projectOpenAfterCreate ?? true
        return (open, mode)
    }
}
