import Foundation
import Observation
import SwiftUI

struct NewMissionPresentation: Identifiable, Equatable {
    let id = UUID()
}

@Observable
@MainActor
final class NewMissionDialogModel {
    enum Phase: Equatable {
        case entry
        case resolving
        case confirmation
        case creating
    }

    enum CreationError: LocalizedError, Equatable {
        case duplicate(existing: MissionID)

        var errorDescription: String? {
            "An active Mission already exists for this issue."
        }
    }

    var reference = "" {
        didSet {
            guard reference != oldValue, phase == .resolving else { return }
            invalidateResolution()
        }
    }

    var phase: Phase = .entry
    var resolved: ResolvedMissionIssue?
    var projectId = ""
    var base = ""
    var branch = ""
    var agentId = ""
    var prompt = ""
    var errorMessage: String?
    var existingMissionID: MissionID?
    private(set) var candidateProjectIds: [String] = []
    private(set) var branches: [String] = []
    private(set) var isLoadingBranches = false
    private(set) var branchErrorMessage: String?

    struct Environment {
        let resolveIssue: (String) async throws -> ResolvedMissionIssue
        let branches: (String) async throws -> [String]
        let configuredBase: (String) -> String
        let configuredBranchPrefix: (String) -> String
        let enabledACPAgents: () -> [AgentDefinition]
        let destination: (String, String) -> URL
        let createMission: (MissionDraft, Bool) async throws -> MissionID
        let openMission: (MissionID) -> Void
    }

    @ObservationIgnored
    private let environment: Environment
    @ObservationIgnored
    private var resolutionGeneration = 0
    @ObservationIgnored
    private var projectGeneration = 0
    @ObservationIgnored
    private var seededBase = ""
    @ObservationIgnored
    private var seededBranch = ""

    init(environment: Environment) {
        self.environment = environment
    }

    var agentOptions: [AgentDefinition] {
        NewWorktreeDialog.acpCapableAgents(from: environment.enabledACPAgents())
    }

    var validationMessage: String? {
        guard resolved != nil else { return "Resolve an issue before creating a Mission." }
        guard candidateProjectIds.contains(projectId) else {
            return "Choose a repository matched to this issue."
        }
        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Choose a base branch."
        }
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else { return "Enter a branch name." }
        if case .invalid(let message) = GitNameValidator.validateBranchName(trimmedBranch) {
            return message
        }
        guard !agentOptions.isEmpty else {
            return "Enable an ACP-capable agent in Settings before creating a Mission."
        }
        guard agentOptions.contains(where: { $0.id == agentId }) else {
            return "Choose an enabled ACP-capable agent."
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter an initial prompt."
        }
        return nil
    }

    var canCreate: Bool {
        phase == .confirmation && validationMessage == nil
    }

    func resolve() async {
        guard phase == .entry else { return }
        let input = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            errorMessage = "Enter an issue number or URL."
            return
        }

        resolutionGeneration &+= 1
        let generation = resolutionGeneration
        phase = .resolving
        errorMessage = nil
        branchErrorMessage = nil
        existingMissionID = nil
        resolved = nil
        candidateProjectIds = []
        projectId = ""

        let resolution: ResolvedMissionIssue
        do {
            resolution = try await environment.resolveIssue(input)
        } catch {
            guard acceptsResolution(generation: generation, input: input) else { return }
            phase = .entry
            errorMessage = error.localizedDescription
            return
        }
        guard acceptsResolution(generation: generation, input: input) else { return }
        guard resolution.candidateProjectIds.contains(resolution.selectedProjectId) else {
            phase = .entry
            errorMessage = "The resolved issue did not match an available repository."
            return
        }

        isLoadingBranches = true
        let discoveredBranches: [String]
        let branchLoadError: String?
        do {
            discoveredBranches = try await environment.branches(resolution.selectedProjectId)
            branchLoadError = nil
        } catch {
            discoveredBranches = []
            branchLoadError = error.localizedDescription
        }
        guard acceptsResolution(generation: generation, input: input) else { return }

        resolved = resolution
        candidateProjectIds = resolution.candidateProjectIds
        projectId = resolution.selectedProjectId
        branches = discoveredBranches
        branchErrorMessage = branchLoadError
        isLoadingBranches = false

        let configuredBase = environment.configuredBase(projectId)
        base = NewWorktreeDialog.preferredBaseBranch(
            availableBranches: discoveredBranches,
            configuredDefault: configuredBase
        )
        seededBase = base
        branch = generatedBranch(projectID: projectId, issue: resolution.snapshot)
        seededBranch = branch
        prompt = MissionPromptBuilder.build(snapshot: resolution.snapshot)
        agentId = agentOptions.first?.id ?? ""
        phase = .confirmation
    }

    func cancelResolution() {
        invalidateResolution()
    }

    func selectProject(_ candidateID: String) async {
        guard phase == .confirmation, let issue = resolved?.snapshot else { return }
        guard candidateProjectIds.contains(candidateID) else {
            errorMessage = "Choose a repository matched to this issue."
            return
        }
        guard candidateID != projectId else {
            errorMessage = nil
            return
        }

        let updatesBase = base == seededBase
        let updatesBranch = branch == seededBranch
        projectGeneration &+= 1
        let generation = projectGeneration
        projectId = candidateID
        errorMessage = nil
        existingMissionID = nil

        let nextSeededBase = environment.configuredBase(candidateID)
        seededBase = nextSeededBase
        if updatesBase { base = nextSeededBase }

        let nextSeededBranch = generatedBranch(projectID: candidateID, issue: issue)
        seededBranch = nextSeededBranch
        if updatesBranch { branch = nextSeededBranch }

        branches = []
        branchErrorMessage = nil
        isLoadingBranches = true
        do {
            let discovered = try await environment.branches(candidateID)
            guard projectGeneration == generation, projectId == candidateID else { return }
            branches = discovered
            if updatesBase, base == seededBase {
                let preferred = NewWorktreeDialog.preferredBaseBranch(
                    availableBranches: discovered,
                    configuredDefault: nextSeededBase
                )
                base = preferred
                seededBase = preferred
            }
        } catch {
            guard projectGeneration == generation, projectId == candidateID else { return }
            branchErrorMessage = error.localizedDescription
        }
        guard projectGeneration == generation, projectId == candidateID else { return }
        isLoadingBranches = false
    }

    func create(allowDuplicate: Bool) async -> MissionID? {
        guard let issue = resolved?.snapshot else {
            errorMessage = "Resolve an issue before creating a Mission."
            return nil
        }
        guard let validationMessage else {
            phase = .creating
            errorMessage = nil
            existingMissionID = nil
            let draft = MissionDraft(
                issue: issue,
                projectId: projectId,
                baseRef: base,
                branch: branch,
                destinationPath: environment.destination(projectId, branch).path,
                agentId: agentId,
                initialPromptId: UUID(),
                initialPrompt: prompt
            )
            do {
                return try await environment.createMission(draft, allowDuplicate)
            } catch let CreationError.duplicate(existing) {
                existingMissionID = existing
                phase = .confirmation
                return nil
            } catch {
                errorMessage = error.localizedDescription
                phase = .confirmation
                return nil
            }
        }
        errorMessage = validationMessage
        return nil
    }

    func openExistingMission() -> MissionID? {
        guard let existingMissionID else { return nil }
        environment.openMission(existingMissionID)
        self.existingMissionID = nil
        return existingMissionID
    }

    func cancelDuplicateChoice() {
        existingMissionID = nil
    }

    private func acceptsResolution(generation: Int, input: String) -> Bool {
        resolutionGeneration == generation
            && phase == .resolving
            && reference.trimmingCharacters(in: .whitespacesAndNewlines) == input
    }

    private func invalidateResolution() {
        resolutionGeneration &+= 1
        projectGeneration &+= 1
        phase = .entry
        resolved = nil
        candidateProjectIds = []
        projectId = ""
        base = ""
        branch = ""
        agentId = ""
        prompt = ""
        branches = []
        isLoadingBranches = false
        errorMessage = nil
        branchErrorMessage = nil
        existingMissionID = nil
        seededBase = ""
        seededBranch = ""
    }

    private func generatedBranch(projectID: String, issue: MissionIssueSnapshot) -> String {
        MissionBranchName.make(
            issueNumber: issue.identity.number,
            title: issue.title,
            prefix: environment.configuredBranchPrefix(projectID)
        )
    }
}

struct NewMissionDialog: View {
    static let confirmationWidth: CGFloat = 680

    @Binding var presented: Bool
    let projects: [ProjectConfig]
    @State private var model: NewMissionDialogModel
    @Environment(\.theme) private var theme

    init(
        presented: Binding<Bool>,
        projects: [ProjectConfig],
        environment: NewMissionDialogModel.Environment
    ) {
        _presented = presented
        self.projects = projects
        _model = State(initialValue: NewMissionDialogModel(environment: environment))
    }

    var body: some View {
        switch model.phase {
        case .entry, .resolving:
            entrySheet
        case .confirmation, .creating:
            confirmationSheet
        }
    }

    private var entrySheet: some View {
        DialogContainer(
            title: "New Mission",
            subtitle: "Start from a GitHub or GitLab issue.",
            content: {
                DialogField(label: "Issue") {
                    AlasField(
                        text: $model.reference,
                        placeholder: "Issue URL or #123",
                        focusOnAppear: true,
                        onSubmit: continueFromEntry
                    )
                    .disabled(model.phase == .resolving)
                }
                if model.phase == .resolving {
                    HStack(spacing: 8) {
                        Spinner(lineWidth: 1.5, duration: 0.7)
                            .frame(width: 14, height: 14)
                        Text("Resolving issue…")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg-dim"))
                    }
                    .accessibilityElement(children: .combine)
                }
                if let errorMessage = model.errorMessage {
                    inlineError(errorMessage)
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: model.phase == .resolving ? "Resolving…" : "Continue",
            confirmStyle: .primary,
            onCancel: cancel,
            onConfirm: continueFromEntry,
            confirmEnabled: model.phase == .entry
                && !model.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .interactiveDismissDisabled(model.phase == .resolving)
    }

    private var confirmationSheet: some View {
        DialogContainer(
            title: "Confirm Mission",
            subtitle: "Review the worktree and ACP session draft before creating it.",
            width: Self.confirmationWidth,
            content: {
                if let issue = model.resolved?.snapshot {
                    NewMissionIssueCard(issue: issue)
                }
                DialogField(label: "Repository") {
                    ProjectPicker(selection: projectSelection, projects: matchingProjects)
                        .disabled(matchingProjects.count < 2 || model.phase == .creating)
                }
                DialogField(label: "Base branch") {
                    BranchPicker(
                        selection: $model.base,
                        branches: model.branches,
                        isLoading: model.isLoadingBranches,
                        errorMessage: model.branchErrorMessage
                    )
                    .disabled(model.phase == .creating)
                }
                DialogField(label: "Branch name") {
                    AlasField(
                        text: $model.branch,
                        monospaced: true,
                        inputFilter: .branchName
                    )
                    .disabled(model.phase == .creating)
                }
                DialogField(label: "ACP agent") {
                    agentPicker
                }
                DialogField(label: "Initial prompt") {
                    TextEditor(text: $model.prompt)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.color("fg"))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 130, maxHeight: 190)
                        .padding(8)
                        .background(theme.color("bg-0"))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(theme.color("line"), lineWidth: 0.5)
                        )
                        .disabled(model.phase == .creating)
                }
                if model.phase == .creating {
                    HStack(spacing: 8) {
                        Spinner(lineWidth: 1.5, duration: 0.7)
                            .frame(width: 14, height: 14)
                        Text("Saving Mission…")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg-dim"))
                    }
                    .accessibilityElement(children: .combine)
                } else if let validationMessage = model.validationMessage {
                    inlineError(validationMessage)
                } else if let errorMessage = model.errorMessage {
                    inlineError(errorMessage)
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: model.phase == .creating ? "Creating…" : "Create Mission",
            confirmStyle: .primary,
            onCancel: cancel,
            onConfirm: createMission,
            confirmEnabled: model.canCreate
        )
        .interactiveDismissDisabled(model.phase == .creating)
        .confirmationDialog(
            "A Mission already exists for this issue.",
            isPresented: duplicateChoicePresented,
            titleVisibility: .visible
        ) {
            Button("Open Existing") { openExistingMission() }
            Button("Create Another") { createAnotherMission() }
            Button("Cancel", role: .cancel) { model.cancelDuplicateChoice() }
        } message: {
            Text("Open the active Mission or explicitly create another one.")
        }
    }

    private var matchingProjects: [ProjectConfig] {
        let candidateIDs = Set(model.candidateProjectIds)
        return projects.filter { candidateIDs.contains($0.id) }
    }

    private var projectSelection: Binding<String> {
        Binding(
            get: { model.projectId },
            set: { projectID in
                Task { await model.selectProject(projectID) }
            }
        )
    }

    private var duplicateChoicePresented: Binding<Bool> {
        Binding(
            get: { model.existingMissionID != nil },
            set: { isPresented in
                if !isPresented { model.cancelDuplicateChoice() }
            }
        )
    }

    private var agentPicker: some View {
        Picker("ACP agent", selection: $model.agentId) {
            ForEach(model.agentOptions) { agent in
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
        .disabled(model.phase == .creating || model.agentOptions.isEmpty)
    }

    private func inlineError(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func continueFromEntry() {
        guard model.phase == .entry else { return }
        Task { await model.resolve() }
    }

    private func createMission() {
        guard model.canCreate else { return }
        Task {
            if await model.create(allowDuplicate: false) != nil {
                presented = false
            }
        }
    }

    private func createAnotherMission() {
        Task {
            if await model.create(allowDuplicate: true) != nil {
                presented = false
            }
        }
    }

    private func openExistingMission() {
        if model.openExistingMission() != nil {
            presented = false
        }
    }

    private func cancel() {
        guard model.phase != .creating else { return }
        model.cancelResolution()
        presented = false
    }
}

private struct NewMissionIssueCard: View {
    let issue: MissionIssueSnapshot
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(issue.identity.provider.displayName)
                Text(issue.identity.repositorySlug)
                Text("#\(issue.identity.number)")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.color("fg-dim"))
            Text(issue.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.color("fg"))
                .textSelection(.enabled)
            if !issue.labels.isEmpty {
                Text(issue.labels.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.color("fg-muted"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(theme.color("bg-2"))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }
}

extension NewMissionDialogModel.Environment {
    @MainActor
    static func live(state: AppState) -> Self {
        Self(
            resolveIssue: { [weak state] reference in
                guard let state else {
                    throw CodeHostProviderError.malformedOutput("Alas is no longer available.")
                }
                let resolver = MissionIssueResolver(environment: .init(
                    projects: { state.projects },
                    selectedProjectId: {
                        state.selectedWorktreeId.flatMap { state.worktree(withId: $0)?.projectId }
                    },
                    remotes: { project in
                        try await GitService().remotes(
                            worktreePath: URL(fileURLWithPath: project.path)
                        )
                    },
                    providers: .live()
                ))
                return try await resolver.resolve(reference)
            },
            branches: { [weak state] projectID in
                guard let project = state?.projects.first(where: { $0.id == projectID }) else {
                    throw CodeHostProviderError.malformedOutput("The selected repository is no longer available.")
                }
                return try await GitService().branches(at: URL(fileURLWithPath: project.path))
            },
            configuredBase: { [weak state] _ in state?.config.worktrees.baseBranch ?? "main" },
            configuredBranchPrefix: { [weak state] _ in state?.config.worktrees.branchPrefix ?? "feature/" },
            enabledACPAgents: { [weak state] in state?.agentRegistry.enabled() ?? [] },
            destination: { [weak state] projectID, branch in
                guard let state,
                      let project = state.projects.first(where: { $0.id == projectID })
                else { return URL(fileURLWithPath: "") }
                return WorktreePathTemplateRenderer.render(
                    template: state.config.worktrees.pathTemplate,
                    worktreeRoot: state.config.worktrees.rootPath,
                    repoName: project.name,
                    branch: branch
                )
            },
            createMission: { [weak state] draft, allowDuplicate in
                guard let state else {
                    throw CodeHostProviderError.malformedOutput("Alas is no longer available.")
                }
                do {
                    return try await state.missions.create(draft, allowDuplicate: allowDuplicate)
                } catch MissionStore.Error.duplicateActiveIssueIdentity {
                    if let existing = state.missions.aggregates.first(where: {
                        $0.mission.state != .completed && $0.issue.identity == draft.issue.identity
                    }) {
                        throw NewMissionDialogModel.CreationError.duplicate(
                            existing: existing.mission.id
                        )
                    }
                    throw MissionStore.Error.duplicateActiveIssueIdentity
                }
            },
            openMission: { [weak state] missionID in
                guard let worktreeID = state?.missions.aggregate(id: missionID)?.primaryLeg?.worktreeId else {
                    return
                }
                state?.selectWorktree(id: worktreeID)
            }
        )
    }
}
