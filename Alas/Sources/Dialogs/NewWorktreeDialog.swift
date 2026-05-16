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
    @State private var openTerminal: Bool = true
    @State private var launchAgent: Bool = false
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
                    AlasField(text: $branch, monospaced: true, focusOnAppear: true, onSubmit: submitCreate)
                }
                HStack(spacing: 10) {
                    AlasToggle(on: $runStartup)
                    Text("Run startup script after create").font(.system(size: 12))
                        .foregroundColor(theme.color("fg"))
                }
                HStack(spacing: 10) {
                    AlasToggle(on: $openTerminal)
                    Text("Open in new terminal pane").font(.system(size: 12))
                        .foregroundColor(theme.color("fg"))
                }
                if let validationMessage = branchValidationMessage {
                    Text(validationMessage).font(.system(size: 11)).foregroundColor(.red)
                }
                if let agent = effectiveAutoLaunchAgent {
                    HStack(spacing: 10) {
                        AlasToggle(on: $launchAgent)
                        Text("Launch \(agent.displayName) on create").font(.system(size: 12))
                            .foregroundColor(theme.color("fg"))
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
                branchValidation: branchValidationMessage
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
            launchAgent = effectiveAutoLaunchAgent != nil
            loadBranchesForSelectedProject()
        }
        .onChange(of: projectId) { _, _ in
            launchAgent = effectiveAutoLaunchAgent != nil
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

    private func create() {
        guard let project = state.projects.first(where: { $0.id == projectId }) else { return }
        let dest = URL(fileURLWithPath: renderedPath)
        let id = state.createWorktree(
            projectId: project.id,
            base: base,
            branch: branch,
            destination: dest,
            runStartup: runStartup,
            openTerminal: openTerminal,
            launchAgent: launchAgent
        )
        guard !id.isEmpty else {
            createErrorMessage = "A worktree already exists at this path."
            return
        }
        createErrorMessage = nil
        presented = false
    }

    private func submitCreate() {
        guard Self.canCreate(projectsEmpty: state.projects.isEmpty, branchEmpty: branch.isEmpty, branchValidation: branchValidationMessage) else { return }
        create()
    }

    nonisolated static func canCreate(projectsEmpty: Bool, branchEmpty: Bool, branchValidation: String? = nil) -> Bool {
        !projectsEmpty && !branchEmpty && branchValidation == nil
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
}
