import Foundation
import Observation
import SwiftUI

struct NewMissionPresentation: Identifiable, Equatable {
    let id = UUID()
}

@Observable
@MainActor
final class NewMissionDialogModel {
    struct BranchInventory {
        let names: [String]
        let remoteNames: Set<String>
        let localBranchNames: Set<String>
    }

    enum Phase: Equatable {
        case entry
        case resolving
        case confirmation
        case creating
    }

    enum CreationError: LocalizedError, Equatable {
        case duplicate(existing: MissionID)

        var errorDescription: String? {
            "An active Mission already exists for this source."
        }
    }

    var reference = "" {
        didSet {
            guard reference != oldValue else { return }
            if phase == .resolving {
                invalidateResolution()
            } else if phase == .entry {
                pendingManualFallback = nil
                errorMessage = nil
            }
        }
    }

    var phase: Phase = .entry
    var resolved: ResolvedMissionSource?
    var pendingManualFallback: ResolvedMissionSource?
    var sourceTitle = "" {
        didSet { refreshManualSourceDraft(updateBranch: true) }
    }
    var sourceBody = "" {
        didSet { refreshManualSourceDraft(updateBranch: false) }
    }
    var projectId = ""
    private(set) var base = ""
    private(set) var branch = ""
    var agentId = ""
    var prompt = ""
    var errorMessage: String?
    var existingMissionID: MissionID?
    private(set) var candidateProjectIds: [String] = []
    private(set) var branches: [String] = []
    private(set) var isLoadingBranches = false
    private(set) var branchErrorMessage: String?
    private var remoteNames: Set<String> = []
    private var localBranchNames: Set<String> = []

    struct Environment {
        let resolveSource: (String) async throws -> ResolvedMissionSource
        let branches: (String) async throws -> BranchInventory
        let configuredBase: (String) -> String
        let configuredBranchPrefix: (String) -> String
        let reservedBranches: (String) -> [String]
        let enabledACPAgents: () -> [AgentDefinition]
        let destination: (String, String) -> URL
        let destinationAvailable: (String, URL) -> Bool
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
    private var baseIsUserOwned = false
    @ObservationIgnored
    private var branchIsUserOwned = false
    @ObservationIgnored
    private var promptIsUserOwned = false
    @ObservationIgnored
    private var duplicateBranch: String?

    init(environment: Environment) {
        self.environment = environment
    }

    var agentOptions: [AgentDefinition] {
        NewWorktreeDialog.acpCapableAgents(from: environment.enabledACPAgents())
    }

    var validationMessage: String? {
        guard let resolved else { return "Resolve a work item before creating a Mission." }
        if resolved.source.contentOrigin == .manual {
            guard !sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Enter a work-item title."
            }
        }
        guard candidateProjectIds.contains(projectId) else {
            return "Choose a primary repository."
        }
        guard !isLoadingBranches else {
            return "Wait for repository branches to finish loading."
        }
        guard branchErrorMessage == nil else {
            return "Reload repository branches before creating a Mission."
        }
        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Choose a base branch."
        }
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else { return "Enter a branch name." }
        if case .invalid(let message) = GitNameValidator.validateBranchName(trimmedBranch) {
            return message
        }
        guard !environment.reservedBranches(projectId).contains(trimmedBranch) else {
            return "Another active Mission already reserves this branch."
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
            errorMessage = "Enter a work-item link."
            return
        }

        resolutionGeneration &+= 1
        let generation = resolutionGeneration
        phase = .resolving
        errorMessage = nil
        branchErrorMessage = nil
        existingMissionID = nil
        duplicateBranch = nil
        resolved = nil
        pendingManualFallback = nil
        candidateProjectIds = []
        projectId = ""

        let resolution: ResolvedMissionSource
        do {
            resolution = try await environment.resolveSource(input)
        } catch let failure as MissionSourceResolutionFailure {
            guard acceptsResolution(generation: generation, input: input) else { return }
            pendingManualFallback = failure.fallback
            phase = .entry
            errorMessage = failure.localizedDescription
            return
        } catch {
            guard acceptsResolution(generation: generation, input: input) else { return }
            phase = .entry
            errorMessage = error.localizedDescription
            return
        }
        guard acceptsResolution(generation: generation, input: input) else { return }
        await adoptResolution(resolution, generation: generation, input: input)
    }

    func continueManually() async {
        guard phase == .entry, let fallback = pendingManualFallback else { return }
        resolutionGeneration &+= 1
        let generation = resolutionGeneration
        phase = .resolving
        errorMessage = nil
        pendingManualFallback = nil
        await adoptResolution(fallback, generation: generation, input: nil)
    }

    private func adoptResolution(
        _ resolution: ResolvedMissionSource,
        generation: Int,
        input: String?
    ) async {
        let selectedProjectID = preferredProjectID(for: resolution)
        guard let selectedProjectID,
              resolution.candidateProjectIDs.contains(selectedProjectID)
        else {
            phase = .entry
            errorMessage = "Choose a primary repository."
            return
        }

        isLoadingBranches = true
        let branchInventory: BranchInventory
        let branchLoadError: String?
        do {
            branchInventory = try await environment.branches(selectedProjectID)
            branchLoadError = nil
        } catch {
            branchInventory = BranchInventory(names: [], remoteNames: [], localBranchNames: [])
            branchLoadError = error.localizedDescription
        }
        if let input {
            guard acceptsResolution(generation: generation, input: input) else { return }
        } else {
            guard resolutionGeneration == generation, phase == .resolving else { return }
        }

        resolved = resolution
        pendingManualFallback = nil
        candidateProjectIds = resolution.candidateProjectIDs
        projectId = selectedProjectID
        branches = branchInventory.names
        remoteNames = branchInventory.remoteNames
        localBranchNames = branchInventory.localBranchNames
        branchErrorMessage = branchLoadError
        isLoadingBranches = false

        let configuredBase = environment.configuredBase(projectId)
        base = NewWorktreeDialog.preferredBaseBranch(
            availableBranches: branchInventory.names,
            configuredDefault: configuredBase
        )
        baseIsUserOwned = false
        branch = availableBranch(
            seededBy: generatedBranch(projectID: projectId, source: resolution.source),
            occupied: branchInventory.names + environment.reservedBranches(projectId),
            projectID: projectId
        )
        branchIsUserOwned = false
        sourceTitle = resolution.source.contentOrigin == .manual ? "" : resolution.source.title
        sourceBody = resolution.source.contentOrigin == .manual ? "" : resolution.source.body
        prompt = MissionPromptBuilder.build(source: resolution.source)
        promptIsUserOwned = false
        agentId = agentOptions.first?.id ?? ""
        phase = .confirmation
    }

    func cancelResolution() {
        invalidateResolution()
    }

    func selectProject(_ candidateID: String) async {
        guard phase == .confirmation, let source = resolved?.source else { return }
        guard candidateProjectIds.contains(candidateID) else {
            errorMessage = "Choose a primary repository."
            return
        }
        guard candidateID != projectId else {
            errorMessage = nil
            return
        }

        let updatesBase = !baseIsUserOwned
        let updatesBranch = !branchIsUserOwned
        projectGeneration &+= 1
        let generation = projectGeneration
        projectId = candidateID
        errorMessage = nil
        existingMissionID = nil
        duplicateBranch = nil

        let nextSeededBase = environment.configuredBase(candidateID)
        if updatesBase { base = nextSeededBase }

        let nextSeededBranch = generatedBranch(projectID: candidateID, source: source)
        if updatesBranch { branch = nextSeededBranch }

        branches = []
        remoteNames = []
        localBranchNames = []
        branchErrorMessage = nil
        isLoadingBranches = true
        do {
            let inventory = try await environment.branches(candidateID)
            guard projectGeneration == generation, projectId == candidateID else { return }
            branches = inventory.names
            remoteNames = inventory.remoteNames
            localBranchNames = inventory.localBranchNames
            if updatesBase, !baseIsUserOwned {
                let preferred = NewWorktreeDialog.preferredBaseBranch(
                    availableBranches: inventory.names,
                    configuredDefault: nextSeededBase
                )
                base = preferred
            }
            if updatesBranch, !branchIsUserOwned {
                branch = availableBranch(
                    seededBy: nextSeededBranch,
                    occupied: inventory.names + environment.reservedBranches(candidateID),
                    projectID: candidateID
                )
            }
        } catch {
            guard projectGeneration == generation, projectId == candidateID else { return }
            branchErrorMessage = error.localizedDescription
        }
        guard projectGeneration == generation, projectId == candidateID else { return }
        isLoadingBranches = false
    }

    func create(allowDuplicate: Bool) async -> MissionID? {
        guard let source = resolvedSourceForCreation() else {
            errorMessage = "Resolve a work item before creating a Mission."
            return nil
        }
        let normalizedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseRemoteName = MissionBaseReference.remoteName(
            in: normalizedBase,
            knownRemoteNames: remoteNames,
            localBranchNames: localBranchNames
        )
        let normalizedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if allowDuplicate,
           duplicateBranch?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedBranch {
            errorMessage = "Choose a different branch for the additional Mission."
            phase = .confirmation
            return nil
        }
        guard let validationMessage else {
            phase = .creating
            errorMessage = nil
            existingMissionID = nil
            let draft = MissionDraft(
                source: source,
                projectId: projectId,
                baseRef: normalizedBase,
                baseRemoteName: baseRemoteName ?? "",
                branch: normalizedBranch,
                destinationPath: availableDestination(projectID: projectId, branch: normalizedBranch).path,
                agentId: agentId,
                initialPromptId: UUID(),
                initialPrompt: prompt
            )
            do {
                return try await environment.createMission(draft, allowDuplicate)
            } catch let CreationError.duplicate(existing) {
                existingMissionID = existing
                duplicateBranch = branch
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
        duplicateBranch = nil
    }

    func prepareDuplicateCreation() -> Bool {
        guard existingMissionID != nil, let original = duplicateBranch else { return false }
        branch = availableBranch(
            seededBy: original,
            occupied: branches + environment.reservedBranches(projectId) + [original],
            projectID: projectId
        )
        branchIsUserOwned = false
        existingMissionID = nil
        errorMessage = nil
        return true
    }

    fileprivate func updateBaseFromUser(_ value: String) {
        base = value
        baseIsUserOwned = true
    }

    fileprivate func updateBranchFromUser(_ value: String) {
        branch = value
        branchIsUserOwned = true
    }

    private func acceptsResolution(generation: Int, input: String) -> Bool {
        resolutionGeneration == generation
            && phase == .resolving
            && reference.trimmingCharacters(in: .whitespacesAndNewlines) == input
    }

    private func availableDestination(projectID: String, branch: String) -> URL {
        let requested = environment.destination(projectID, branch).standardizedFileURL
        guard !environment.destinationAvailable(projectID, requested) else { return requested }

        let parent = requested.deletingLastPathComponent()
        let name = requested.lastPathComponent
        var suffix = 2
        while true {
            let candidate = parent
                .appendingPathComponent("\(name)-\(suffix)")
                .standardizedFileURL
            if environment.destinationAvailable(projectID, candidate) {
                return candidate
            }
            suffix += 1
        }
    }

    private func invalidateResolution() {
        resolutionGeneration &+= 1
        projectGeneration &+= 1
        phase = .entry
        resolved = nil
        pendingManualFallback = nil
        sourceTitle = ""
        sourceBody = ""
        candidateProjectIds = []
        projectId = ""
        base = ""
        branch = ""
        agentId = ""
        prompt = ""
        branches = []
        remoteNames = []
        localBranchNames = []
        isLoadingBranches = false
        errorMessage = nil
        branchErrorMessage = nil
        existingMissionID = nil
        baseIsUserOwned = false
        branchIsUserOwned = false
        promptIsUserOwned = false
        duplicateBranch = nil
    }

    private func generatedBranch(projectID: String, source: MissionSourceSnapshot) -> String {
        MissionBranchName.make(
            displayReference: source.displayReference,
            title: source.title,
            prefix: environment.configuredBranchPrefix(projectID)
        )
    }

    fileprivate func updatePromptFromUser(_ value: String) {
        prompt = value
        promptIsUserOwned = true
    }

    private func preferredProjectID(for resolution: ResolvedMissionSource) -> String? {
        if let selected = resolution.selectedProjectID,
           resolution.candidateProjectIDs.contains(selected) {
            return selected
        }
        return resolution.candidateProjectIDs.first
    }

    private func resolvedSourceForCreation() -> MissionSourceSnapshot? {
        guard let source = resolved?.source else { return nil }
        guard source.contentOrigin == .manual else { return source }
        let title = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return manualSource(from: source, title: title, body: sourceBody.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func refreshManualSourceDraft(updateBranch: Bool) {
        guard phase == .confirmation,
              var resolution = resolved,
              resolution.source.contentOrigin == .manual
        else { return }
        let title = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextSource = manualSource(from: resolution.source, title: title, body: sourceBody)
        resolution.source = nextSource
        resolved = resolution
        if updateBranch, !branchIsUserOwned, !title.isEmpty {
            branch = availableBranch(
                seededBy: generatedBranch(projectID: projectId, source: nextSource),
                occupied: branches + environment.reservedBranches(projectId),
                projectID: projectId
            )
        }
        if !promptIsUserOwned, !title.isEmpty {
            prompt = MissionPromptBuilder.build(source: nextSource)
        }
    }

    private func manualSource(
        from source: MissionSourceSnapshot,
        title: String,
        body: String
    ) -> MissionSourceSnapshot {
        MissionSourceSnapshot(
            identity: source.identity,
            canonicalURL: source.canonicalURL,
            providerLabel: source.providerLabel,
            displayReference: source.displayReference,
            repositoryLocator: source.repositoryLocator,
            title: title,
            body: body,
            state: source.state,
            labels: source.labels,
            assignees: source.assignees,
            providerUpdatedAt: source.providerUpdatedAt,
            capturedAt: source.capturedAt,
            refreshError: source.refreshError,
            contentOrigin: source.contentOrigin,
            isEditable: source.isEditable,
            isRefreshable: source.isRefreshable
        )
    }

    private func availableBranch(
        seededBy seed: String,
        occupied: [String],
        projectID _: String
    ) -> String {
        let rawOccupied = Set(occupied)
        var occupied = rawOccupied
        for branch in rawOccupied {
            guard let remoteName = remoteNames
                .filter({ branch.hasPrefix("\($0)/") })
                .max(by: { $0.count < $1.count })
            else { continue }
            occupied.insert(String(branch.dropFirst(remoteName.count + 1)))
        }
        guard occupied.contains(seed) else { return seed }
        var suffix = 2
        var candidate = "\(seed)-\(suffix)"
        while occupied.contains(candidate) {
            suffix += 1
            candidate = "\(seed)-\(suffix)"
        }
        return candidate
    }
}

@MainActor
struct NewMissionDialogActions {
    private let model: NewMissionDialogModel
    private let dismiss: () -> Void

    init(model: NewMissionDialogModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
    }

    var base: Binding<String> {
        Binding(
            get: { model.base },
            set: { model.updateBaseFromUser($0) }
        )
    }

    var branch: Binding<String> {
        Binding(
            get: { model.branch },
            set: { model.updateBranchFromUser($0) }
        )
    }

    var prompt: Binding<String> {
        Binding(
            get: { model.prompt },
            set: { model.updatePromptFromUser($0) }
        )
    }

    @discardableResult
    func create(allowDuplicate: Bool) async -> MissionID? {
        guard let missionID = await model.create(allowDuplicate: allowDuplicate) else {
            return nil
        }
        dismiss()
        return missionID
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
            subtitle: "Start from any work-item link.",
            content: {
                DialogField(label: "Work item link") {
                    AlasField(
                        text: $model.reference,
                        placeholder: "Work-item URL or #123",
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
                if model.pendingManualFallback != nil {
                    Button("Continue Manually") {
                        Task { await model.continueManually() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.phase != .entry)
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
                if let source = model.resolved?.source {
                    NewMissionSourceCard(source: source)
                    if source.contentOrigin == .manual {
                        DialogField(label: "Work-item title") {
                            AlasField(text: $model.sourceTitle)
                                .disabled(model.phase == .creating)
                        }
                        DialogField(label: "Work-item context") {
                            TextEditor(text: $model.sourceBody)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.color("fg"))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 80, maxHeight: 140)
                                .padding(8)
                                .background(theme.color("bg-0"))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(theme.color("line"), lineWidth: 0.5)
                                )
                                .disabled(model.phase == .creating)
                        }
                    }
                }
                DialogField(label: "Repository") {
                    ProjectPicker(selection: projectSelection, projects: matchingProjects)
                        .disabled(matchingProjects.count < 2 || model.phase == .creating)
                }
                DialogField(label: "Base branch") {
                    BranchPicker(
                        selection: actions.base,
                        branches: model.branches,
                        isLoading: model.isLoadingBranches,
                        errorMessage: model.branchErrorMessage
                    )
                    .disabled(model.phase == .creating)
                }
                DialogField(label: "Branch name") {
                    AlasField(
                        text: actions.branch,
                        monospaced: true,
                        inputFilter: .branchName
                    )
                    .disabled(model.phase == .creating)
                }
                DialogField(label: "ACP agent") {
                    agentPicker
                }
                DialogField(label: "Initial prompt") {
                    TextEditor(text: actions.prompt)
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
            "A Mission already exists for this work item.",
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

    private var actions: NewMissionDialogActions {
        NewMissionDialogActions(model: model) {
            presented = false
        }
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
        Task { await actions.create(allowDuplicate: false) }
    }

    private func createAnotherMission() {
        guard model.prepareDuplicateCreation() else { return }
        Task { await actions.create(allowDuplicate: true) }
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

private struct NewMissionSourceCard: View {
    let source: MissionSourceSnapshot
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(source.providerLabel)
                if let repositorySlug = source.repositoryLocator?.repositorySlug {
                    Text(repositorySlug)
                }
                if let displayReference = source.displayReference {
                    Text(displayReference)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.color("fg-dim"))
            Text(source.title.isEmpty ? "Manual work item" : source.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.color("fg"))
                .textSelection(.enabled)
            if !source.labels.isEmpty {
                Text(source.labels.joined(separator: " · "))
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
            resolveSource: { [weak state] reference in
                guard let state else {
                    throw CodeHostProviderError.malformedOutput("Alas is no longer available.")
                }
                let resolver = MissionSourceResolver(environment: .init(
                    projects: { state.projects },
                    selectedProjectID: {
                        state.selectedWorktreeId.flatMap { state.worktree(withId: $0)?.projectId }
                    },
                    remotes: { project in
                        try await GitService().remotes(
                            worktreePath: URL(fileURLWithPath: project.path)
                        )
                    },
                    providers: MissionSourceProviderRegistry([
                        CodeHostMissionSourceProvider(kind: .github, providers: .live()),
                        CodeHostMissionSourceProvider(kind: .gitlab, providers: .live()),
                        ManualMissionSourceProvider()
                    ])
                ))
                return try await resolver.resolve(reference)
            },
            branches: { [weak state] projectID in
                guard let project = state?.projects.first(where: { $0.id == projectID }) else {
                    throw CodeHostProviderError.malformedOutput("The selected repository is no longer available.")
                }
                let path = URL(fileURLWithPath: project.path)
                let git = GitService()
                let branches = try await git.branches(at: path)
                let localBranches = try await git.localBranches(at: path)
                let remotes = try await git.remotes(worktreePath: path)
                return NewMissionDialogModel.BranchInventory(
                    names: branches,
                    remoteNames: Set(remotes.map(\.name)),
                    localBranchNames: Set(localBranches)
                )
            },
            configuredBase: { [weak state] _ in state?.config.worktrees.baseBranch ?? "main" },
            configuredBranchPrefix: { [weak state] _ in state?.config.worktrees.branchPrefix ?? "feature/" },
            reservedBranches: { [weak state] projectID in
                Self.activeMissionBranches(
                    in: state?.missions.aggregates ?? [],
                    projectID: projectID
                )
            },
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
            destinationAvailable: { [weak state] projectID, destination in
                guard let state,
                      let project = state.projects.first(where: { $0.id == projectID })
                else { return false }
                let candidate = destination.standardizedFileURL.path
                return Self.destinationAvailable(
                    project: project,
                    destination: destination,
                    activeMissionDestinationPaths: Self.activeMissionDestinationPaths(
                        in: state.missions.aggregates,
                        projectID: projectID
                    ),
                    worktreePaths: state.projectsManager.worktrees(projectId: projectID).map(\.path),
                    localDestinationExists: FileManager.default.fileExists(atPath: candidate)
                )
            },
            createMission: { [weak state] draft, allowDuplicate in
                guard let state else {
                    throw CodeHostProviderError.malformedOutput("Alas is no longer available.")
                }
                do {
                    let preparedDraft = try await state.preparedMissionDraft(draft)
                    return try await state.missions.create(preparedDraft, allowDuplicate: allowDuplicate)
                } catch MissionStore.Error.duplicateActiveSourceIdentity {
                    if let existing = state.missions.aggregates.first(where: {
                        $0.mission.state != .completed && $0.source.identity == draft.source.identity
                    }) {
                        throw NewMissionDialogModel.CreationError.duplicate(
                            existing: existing.mission.id
                        )
                    }
                    throw MissionStore.Error.duplicateActiveSourceIdentity
                }
            },
            openMission: { [weak state] missionID in
                _ = state?.openMission(id: missionID)
            }
        )
    }

    static func activeMissionBranches(
        in aggregates: [MissionAggregate],
        projectID: String
    ) -> [String] {
        aggregates.flatMap { aggregate -> [String] in
            guard aggregate.mission.state != .completed else { return [] }
            return aggregate.legs
                .filter { $0.projectId == projectID }
                .map(\.branch)
        }
    }

    static func activeMissionDestinationPaths(
        in aggregates: [MissionAggregate],
        projectID: String
    ) -> Set<String> {
        Set(aggregates.flatMap { aggregate -> [String] in
            guard aggregate.mission.state != .completed else { return [] }
            return aggregate.legs
                .filter { $0.projectId == projectID }
                .map { URL(fileURLWithPath: $0.destinationPath).standardizedFileURL.path }
        })
    }

    static func destinationAvailable(
        project: ProjectConfig,
        destination: URL,
        activeMissionDestinationPaths: Set<String>,
        worktreePaths: [URL],
        localDestinationExists: Bool
    ) -> Bool {
        let candidate = destination.standardizedFileURL.path
        let localCollision = project.host == nil && localDestinationExists
        return !localCollision
            && !activeMissionDestinationPaths.contains(candidate)
            && !worktreePaths.contains { $0.standardizedFileURL.path == candidate }
    }
}
