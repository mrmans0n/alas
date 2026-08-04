import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class AddMissionLegDialogActions {
    typealias PrepareDestination = (MissionLegDraft) async throws -> MissionLegDraft
    typealias AddLeg = (MissionLegDraft, MissionID) async throws -> MissionLegID

    private let model: AddMissionLegModel
    private let aggregate: () -> MissionAggregate?
    private let projects: () -> [ProjectConfig]
    private let prepareDestination: PrepareDestination
    private let addLeg: AddLeg
    private let dismiss: () -> Void

    private(set) var isSubmitting = false
    var errorMessage: String?

    init(
        model: AddMissionLegModel,
        aggregate: @escaping () -> MissionAggregate?,
        projects: @escaping () -> [ProjectConfig],
        prepareDestination: @escaping PrepareDestination,
        addLeg: @escaping AddLeg,
        dismiss: @escaping () -> Void
    ) {
        self.model = model
        self.aggregate = aggregate
        self.projects = projects
        self.prepareDestination = prepareDestination
        self.addLeg = addLeg
        self.dismiss = dismiss
    }

    func submit(
        missionID: MissionID,
        selectedProjectID: String,
        instructions: String
    ) async -> MissionLegID? {
        guard !isSubmitting else { return nil }
        guard let aggregate = aggregate() else {
            errorMessage = "The Mission is no longer available."
            return nil
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let draft = try await model.prepare(
                aggregate: aggregate,
                projects: projects(),
                selectedProjectID: selectedProjectID,
                instructions: instructions
            )
            let prepared = try await prepareDestination(draft)
            let legID = try await addLeg(prepared, missionID)
            errorMessage = nil
            dismiss()
            return legID
        } catch {
            errorMessage = Self.sanitizedError(error)
            return nil
        }
    }

    static func sanitizedError(_ error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return [
            #"\bgithub_pat_[A-Za-z0-9_]+\b"#,
            #"\bgh[pousr]_[A-Za-z0-9_]+\b"#,
            #"\bglpat-[A-Za-z0-9_-]+\b"#,
            #"(?i)\b(?:authorization\s*:\s*bearer|bearer)\s+[A-Za-z0-9._~+/=-]+"#,
            #"(?i)\b(?:access[_-]?token|api[_-]?key|token|password|secret)\s*[:=]\s*[^\s,;]+"#,
            #"(?i)(https?://)[^/\s@]+@"#,
        ].reduce(message) { sanitized, pattern in
            sanitized.replacingOccurrences(
                of: pattern,
                with: pattern.contains("https?://") ? "$1[redacted]@" : "[redacted]",
                options: .regularExpression
            )
        }
    }
}

struct AddMissionLegDialog: View {
    static let width: CGFloat = 680

    @Binding var presented: Bool
    let state: AppState
    let missionID: MissionID
    @State private var model: AddMissionLegModel
    @State private var actions: AddMissionLegDialogActions
    @State private var selectedProjectID = ""
    @State private var instructions = ""
    @State private var didLoad = false
    @Environment(\.theme) private var theme

    init(
        presented: Binding<Bool>,
        state: AppState,
        missionID: MissionID
    ) {
        _presented = presented
        self.state = state
        self.missionID = missionID
        let model = AddMissionLegModel(environment: .live(state: state))
        _model = State(initialValue: model)
        _actions = State(initialValue: AddMissionLegDialogActions(
            model: model,
            aggregate: { [weak state] in state?.missions.aggregate(id: missionID) },
            projects: { [weak state] in state?.projects ?? [] },
            prepareDestination: { [weak state] draft in
                guard let state else {
                    throw CodeHostProviderError.malformedOutput("Alas is no longer available.")
                }
                return try await state.preparedMissionLegDraft(draft)
            },
            addLeg: { [weak state] draft, missionID in
                guard let state else {
                    throw CodeHostProviderError.malformedOutput("Alas is no longer available.")
                }
                return try await state.missions.addLeg(draft, to: missionID)
            },
            dismiss: { presented.wrappedValue = false }
        ))
    }

    var body: some View {
        DialogContainer(
            title: "Add Mission Leg",
            subtitle: "Add another repository to this Mission.",
            width: Self.width,
            content: {
                if let aggregate {
                    issueCard(aggregate)
                    DialogField(label: "Repository") {
                        ProjectPicker(selection: projectSelection, projects: candidateProjects)
                            .disabled(candidateProjects.count < 2 || actions.isSubmitting)
                    }
                    DialogField(label: "Base branch") {
                        BranchPicker(
                            selection: $model.base,
                            branches: model.branches,
                            isLoading: model.isLoadingBranches,
                            errorMessage: model.branchErrorMessage
                        )
                        .disabled(actions.isSubmitting)
                    }
                    DialogField(label: "Branch name") {
                        AlasField(
                            text: $model.branch,
                            monospaced: true,
                            inputFilter: .branchName
                        )
                        .disabled(actions.isSubmitting)
                    }
                    DialogField(label: "ACP agent") {
                        agentPicker
                    }
                    DialogField(label: "Repository instructions") {
                        TextEditor(text: $instructions)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.color("fg"))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 110, maxHeight: 170)
                            .padding(8)
                            .background(theme.color("bg-0"))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
                            )
                            .disabled(actions.isSubmitting)
                    }
                    if actions.isSubmitting {
                        progressRow("Adding Mission leg…")
                    } else if let validationMessage = model.validationMessage {
                        inlineError(validationMessage)
                    } else if instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        inlineError("Enter repository-specific instructions.")
                    } else if let errorMessage = actions.errorMessage ?? model.errorMessage {
                        inlineError(errorMessage)
                    }
                } else {
                    inlineError("The Mission is no longer available.")
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: actions.isSubmitting ? "Adding…" : "Add Leg",
            confirmStyle: .primary,
            onCancel: cancel,
            onConfirm: submit,
            confirmEnabled: canSubmit
        )
        .interactiveDismissDisabled(actions.isSubmitting)
        .task { await loadInitialProject() }
    }

    private var aggregate: MissionAggregate? {
        state.missions.aggregate(id: missionID)
    }

    private var candidateProjects: [ProjectConfig] {
        let ids = Set(model.candidateProjectIDs)
        return state.projects.filter { ids.contains($0.id) }
    }

    private var canSubmit: Bool {
        !actions.isSubmitting
            && aggregate != nil
            && model.validationMessage == nil
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var projectSelection: Binding<String> {
        Binding(
            get: { selectedProjectID },
            set: { projectID in
                selectedProjectID = projectID
                Task { await load(projectID) }
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
        .disabled(actions.isSubmitting || model.agentOptions.isEmpty)
    }

    private func issueCard(_ aggregate: MissionAggregate) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(aggregate.issue.identity.provider.displayName.uppercased()) · \(aggregate.issue.identity.repositorySlug) #\(aggregate.issue.identity.number)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.color("fg-muted"))
            Text(aggregate.issue.title)
                .font(.headline)
                .foregroundStyle(theme.color("fg"))
            Text(aggregate.issue.body.isEmpty ? "No issue description captured." : aggregate.issue.body)
                .font(.system(size: 12))
                .foregroundStyle(theme.color("fg-dim"))
                .textSelection(.enabled)
                .accessibilityIdentifier("add-mission-leg-shared-issue-body")
                .background(MissionAccessibilityMarker(identifier: "add-mission-leg-shared-issue-body"))
            Text("EXISTING LEGS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.color("fg-muted"))
                .padding(.top, 3)
            ForEach(aggregate.legs.sorted { lhs, rhs in
                if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
                return lhs.id.rawValue < rhs.id.rawValue
            }, id: \.id) { leg in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repository: \(projectName(for: leg.projectId)) · Project: \(leg.projectId)")
                    Text("Branch: \(leg.branch) · State: \(leg.state.rawValue.capitalized)")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.color("fg-dim"))
                .accessibilityIdentifier("add-mission-leg-existing-leg-\(leg.id.rawValue)")
                .background(MissionAccessibilityMarker(identifier: "add-mission-leg-existing-leg-\(leg.id.rawValue)"))
            }
            Text("Existing legs: \(MissionAggregateSummary.statusCopy(for: aggregate.legs))")
                .font(.caption)
                .foregroundStyle(theme.color("fg-dim"))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color("bg-0"))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        }
    }

    private func projectName(for projectID: String) -> String {
        state.projects.first(where: { $0.id == projectID })?.name ?? projectID
    }

    private func progressRow(_ title: String) -> some View {
        HStack(spacing: 8) {
            Spinner(lineWidth: 1.5, duration: 0.7)
                .frame(width: 14, height: 14)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-dim"))
        }
        .accessibilityElement(children: .combine)
    }

    private func inlineError(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadInitialProject() async {
        guard !didLoad, let aggregate else { return }
        didLoad = true
        let usedProjectIDs = Set(aggregate.legs.map(\.projectId))
        let selected = state.projects.first { !usedProjectIDs.contains($0.id) }?.id ?? ""
        selectedProjectID = selected
        guard !selected.isEmpty else {
            model.errorMessage = "Choose a repository that is not already used by this Mission."
            return
        }
        await load(selected)
    }

    private func load(_ projectID: String) async {
        guard let aggregate else { return }
        do {
            try await model.load(
                aggregate: aggregate,
                projects: state.projects,
                selectedProjectID: projectID
            )
        } catch {
            actions.errorMessage = AddMissionLegDialogActions.sanitizedError(error)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        Task {
            await actions.submit(
                missionID: missionID,
                selectedProjectID: selectedProjectID,
                instructions: instructions
            )
        }
    }

    private func cancel() {
        guard !actions.isSubmitting else { return }
        presented = false
    }
}

extension AddMissionLegModel.Environment {
    @MainActor
    static func live(state: AppState) -> Self {
        Self(
            branches: { [weak state] projectID in
                guard let project = state?.projects.first(where: { $0.id == projectID }) else {
                    throw CodeHostProviderError.malformedOutput("The selected repository is no longer available.")
                }
                let path = URL(fileURLWithPath: project.path)
                let git = GitService()
                let branches = try await git.branches(at: path)
                let localBranches = try await git.localBranches(at: path)
                let remotes = try await git.remotes(worktreePath: path)
                return AddMissionLegModel.BranchInventory(
                    names: branches,
                    remoteNames: Set(remotes.map(\.name)),
                    localBranchNames: Set(localBranches)
                )
            },
            configuredBase: { [weak state] _ in state?.config.worktrees.baseBranch ?? "main" },
            configuredBranchPrefix: { [weak state] _ in state?.config.worktrees.branchPrefix ?? "feature/" },
            reservedBranches: { [weak state] projectID in
                NewMissionDialogModel.Environment.activeMissionBranches(
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
                let reserved = NewMissionDialogModel.Environment.activeMissionDestinationPaths(
                    in: state.missions.aggregates,
                    projectID: projectID
                ).contains(candidate)
                let localDestinationExists = project.host == nil && FileManager.default.fileExists(atPath: candidate)
                return !localDestinationExists
                    && !reserved
                    && !state.projectsManager.worktrees(projectId: projectID).contains {
                        $0.path.standardizedFileURL.path == candidate
                    }
            }
        )
    }
}
