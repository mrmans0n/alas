import Foundation
import Observation

@Observable
@MainActor
final class AddMissionLegModel {
    struct BranchInventory {
        let names: [String]
        let remoteNames: Set<String>
        let localBranchNames: Set<String>
    }

    enum PreparationError: LocalizedError, Equatable {
        case missionNotRunning
        case unavailableProject
        case branchLoadingFailed(String)
        case invalidInput(String)

        var errorDescription: String? {
            switch self {
            case .missionNotRunning:
                "Mission legs can only be added while the Mission is running."
            case .unavailableProject:
                "Choose a repository that is not already used by this Mission."
            case .branchLoadingFailed(let message):
                message
            case .invalidInput(let message):
                message
            }
        }
    }

    struct Environment {
        let branches: (String) async throws -> BranchInventory
        let configuredBase: (String) -> String
        let configuredBranchPrefix: (String) -> String
        let reservedBranches: (String) -> [String]
        let enabledACPAgents: () -> [AgentDefinition]
        let destination: (String, String) -> URL
        let destinationAvailable: (String, URL) -> Bool
    }

    var projectId = ""
    var base = ""
    var branch = ""
    var agentId = ""
    var errorMessage: String?
    private(set) var candidateProjectIDs: [String] = []
    private(set) var branches: [String] = []
    private(set) var isLoadingBranches = false
    private(set) var branchErrorMessage: String?
    private var remoteNames: Set<String> = []
    private var localBranchNames: Set<String> = []
    private var loadedProjectID: String?
    private var projectStates: [String: ProjectState] = [:]
    private var loadGeneration = 0

    private struct ProjectState {
        let inventory: BranchInventory
        var base: String
        var branch: String
        var agentID: String
    }

    @ObservationIgnored
    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    var agentOptions: [AgentDefinition] {
        NewWorktreeDialog.acpCapableAgents(from: environment.enabledACPAgents())
    }

    var validationMessage: String? {
        guard candidateProjectIDs.contains(projectId) else {
            return "Choose a repository that is not already used by this Mission."
        }
        guard !isLoadingBranches else { return "Wait for repository branches to finish loading." }
        guard branchErrorMessage == nil else { return "Reload repository branches before adding a Mission leg." }
        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Choose a base branch."
        }
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else { return "Enter a branch name." }
        if case .invalid(let message) = GitNameValidator.validateBranchName(trimmedBranch) {
            return message
        }
        guard !branches.contains(trimmedBranch) else {
            return "Choose a branch that does not already exist."
        }
        guard !environment.reservedBranches(projectId).contains(trimmedBranch) else {
            return "Another active Mission already reserves this branch."
        }
        guard !agentOptions.isEmpty else {
            return "Enable an ACP-capable agent in Settings before adding a Mission leg."
        }
        guard agentOptions.contains(where: { $0.id == agentId }) else {
            return "Choose an enabled ACP-capable agent."
        }
        return nil
    }

    func load(
        aggregate: MissionAggregate,
        projects: [ProjectConfig],
        selectedProjectID: String
    ) async throws {
        guard aggregate.mission.state == .running else {
            throw fail(.missionNotRunning)
        }

        let usedProjectIDs = Set(aggregate.legs.map(\.projectId))
        candidateProjectIDs = projects.map(\.id).filter { !usedProjectIDs.contains($0) }
        guard candidateProjectIDs.contains(selectedProjectID) else {
            throw fail(.unavailableProject)
        }
        if let loadedProjectID,
           loadedProjectID == projectId,
           var current = projectStates[loadedProjectID] {
            current.base = base
            current.branch = branch
            current.agentID = agentId
            projectStates[loadedProjectID] = current
        }

        loadGeneration += 1
        let generation = loadGeneration
        projectId = selectedProjectID
        errorMessage = nil
        branchErrorMessage = nil
        if let cached = projectStates[selectedProjectID] {
            branches = cached.inventory.names
            remoteNames = cached.inventory.remoteNames
            localBranchNames = cached.inventory.localBranchNames
            base = cached.base
            branch = cached.branch
            agentId = cached.agentID
            loadedProjectID = selectedProjectID
            isLoadingBranches = false
            return
        }

        branches = []
        remoteNames = []
        localBranchNames = []
        isLoadingBranches = true
        defer {
            if loadGeneration == generation {
                isLoadingBranches = false
            }
        }
        do {
            let inventory = try await environment.branches(selectedProjectID)
            guard loadGeneration == generation, projectId == selectedProjectID else { return }
            branches = inventory.names
            remoteNames = inventory.remoteNames
            localBranchNames = inventory.localBranchNames
            base = NewWorktreeDialog.preferredBaseBranch(
                availableBranches: inventory.names,
                configuredDefault: environment.configuredBase(selectedProjectID)
            )
            branch = availableBranch(
                seededBy: MissionBranchName.make(
                    issueNumber: aggregate.issue.identity.number,
                    title: aggregate.issue.title,
                    prefix: environment.configuredBranchPrefix(selectedProjectID)
                ),
                occupied: inventory.names + environment.reservedBranches(selectedProjectID)
            )
            agentId = agentOptions.first?.id ?? ""
            loadedProjectID = selectedProjectID
            projectStates[selectedProjectID] = ProjectState(
                inventory: inventory,
                base: base,
                branch: branch,
                agentID: agentId
            )
        } catch {
            guard loadGeneration == generation, projectId == selectedProjectID else { return }
            let failure = PreparationError.branchLoadingFailed(error.localizedDescription)
            branchErrorMessage = failure.errorDescription
            throw fail(failure)
        }
    }

    func prepare(
        aggregate: MissionAggregate,
        projects: [ProjectConfig],
        selectedProjectID: String,
        instructions: String
    ) async throws -> MissionLegDraft {
        do {
            try await load(
                aggregate: aggregate,
                projects: projects,
                selectedProjectID: selectedProjectID
            )
        } catch let error as PreparationError {
            throw error
        } catch {
            throw fail(.branchLoadingFailed(error.localizedDescription))
        }

        guard let validationMessage else {
            let normalizedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = environment.destination(projectId, normalizedBranch).standardizedFileURL
            guard environment.destinationAvailable(projectId, destination) else {
                throw fail(.invalidInput("Choose a destination that does not already contain a worktree."))
            }
            guard let project = projects.first(where: { $0.id == projectId }) else {
                throw fail(.unavailableProject)
            }
            let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedInstructions.isEmpty else {
                throw fail(.invalidInput("Enter repository-specific instructions."))
            }
            errorMessage = nil
            return MissionLegDraft(
                projectId: projectId,
                baseRef: normalizedBase,
                baseRemoteName: MissionBaseReference.remoteName(
                    in: normalizedBase,
                    knownRemoteNames: remoteNames,
                    localBranchNames: localBranchNames
                ),
                branch: normalizedBranch,
                destinationPath: destination.path,
                agentId: agentId,
                initialPromptId: UUID(),
                preparedPrompt: MissionLegPromptBuilder.build(
                    issue: aggregate.issue,
                    existingLegs: aggregate.legs,
                    existingProjectNames: Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) }),
                    projectName: project.name,
                    branch: normalizedBranch,
                    instructions: trimmedInstructions
                )
            )
        }
        throw fail(.invalidInput(validationMessage))
    }

    private func availableBranch(seededBy seed: String, occupied rawOccupied: [String]) -> String {
        var occupied = Set(rawOccupied)
        for name in rawOccupied {
            guard let remoteName = remoteNames
                .filter({ name.hasPrefix("\($0)/") })
                .max(by: { $0.count < $1.count })
            else { continue }
            occupied.insert(String(name.dropFirst(remoteName.count + 1)))
        }
        guard !occupied.contains(seed) else {
            var suffix = 2
            while occupied.contains("\(seed)-\(suffix)") { suffix += 1 }
            return "\(seed)-\(suffix)"
        }
        return seed
    }

    private func fail(_ error: PreparationError) -> PreparationError {
        errorMessage = error.errorDescription
        return error
    }
}
