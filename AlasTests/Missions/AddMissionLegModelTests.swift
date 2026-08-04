import Foundation
import Testing
@testable import Alas

@MainActor
struct AddMissionLegModelTests {
    @Test("preparation excludes projects already used by the Mission across Spaces")
    func excludesUsedProjectsAndUsesSelectedProjectDefaults() async throws {
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running
        aggregate.legs = [
            MissionFixtures.runningLeg(projectId: "app", branch: "mission/42-app", ordinal: 0),
            MissionFixtures.runningLeg(projectId: "sdk", branch: "mission/42-sdk", ordinal: 1),
        ]
        let model = AddMissionLegModel(environment: environment())

        let draft = try await model.prepare(
            aggregate: aggregate,
            projects: [project(id: "app"), project(id: "sdk"), project(id: "server")],
            selectedProjectID: "server",
            instructions: "Update the server endpoint."
        )

        #expect(model.candidateProjectIDs == ["server"])
        #expect(model.base == "upstream/trunk")
        #expect(model.branch == "mission/42-fix-parser-crash")
        #expect(draft.projectId == "server")
        #expect(draft.baseRef == "upstream/trunk")
        #expect(draft.baseRemoteName == "upstream")
        #expect(draft.branch == "mission/42-fix-parser-crash")
        #expect(draft.destinationPath == "/tmp/worktrees/server/mission-42-fix-parser-crash")
        #expect(draft.agentId == "codex")
        #expect(draft.preparedPrompt.contains("Update the server endpoint."))
        #expect(draft.preparedPrompt.contains("app · mission/42-app · Running"))
        #expect(draft.preparedPrompt.contains("sdk · mission/42-sdk · Running"))
    }

    @Test("preparation rejects Missions that are not running")
    func rejectsNonRunningMissions() async {
        for state in [MissionState.creating, .readyToComplete, .completed] {
            var aggregate = MissionFixtures.creatingMission()
            aggregate.mission.state = state
            let model = AddMissionLegModel(environment: environment())

            await #expect(throws: AddMissionLegModel.PreparationError.self) {
                try await model.prepare(
                    aggregate: aggregate,
                    projects: [project(id: "server")],
                    selectedProjectID: "server",
                    instructions: "Update the server endpoint."
                )
            }
            #expect(model.errorMessage != nil)
        }
    }

    @Test("preparation returns a draft only after branch and destination validation")
    func validatesBranchAndDestinationBeforeReturningDraft() async throws {
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running

        let model = AddMissionLegModel(environment: environment())
        _ = try await model.prepare(
            aggregate: aggregate,
            projects: [project(id: "server")],
            selectedProjectID: "server",
            instructions: "Update the server endpoint."
        )
        model.branch = "invalid branch name"

        await #expect(throws: AddMissionLegModel.PreparationError.self) {
            try await model.prepare(
                aggregate: aggregate,
                projects: [project(id: "server")],
                selectedProjectID: "server",
                instructions: "Update the server endpoint."
            )
        }

        let unavailable = AddMissionLegModel(environment: environment(destinationAvailable: false))
        await #expect(throws: AddMissionLegModel.PreparationError.self) {
            try await unavailable.prepare(
                aggregate: aggregate,
                projects: [project(id: "server")],
                selectedProjectID: "server",
                instructions: "Update the server endpoint."
            )
        }
        #expect(unavailable.errorMessage != nil)
    }

    @Test("a stale repository load cannot replace the latest selection")
    func staleRepositoryLoadIsDiscarded() async throws {
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running
        let gate = AddLegBranchLoadGate()
        let model = AddMissionLegModel(environment: environment(branches: { projectID in
            if projectID == "server" {
                await gate.waitUntilReleased()
                return .init(names: ["origin/server"], remoteNames: ["origin"], localBranchNames: [])
            }
            return .init(names: ["upstream/mobile"], remoteNames: ["upstream"], localBranchNames: [])
        }))
        let projects = [project(id: "server"), project(id: "mobile")]

        let stale = Task {
            try await model.load(aggregate: aggregate, projects: projects, selectedProjectID: "server")
        }
        await gate.waitUntilStarted()
        try await model.load(aggregate: aggregate, projects: projects, selectedProjectID: "mobile")
        await gate.release()
        try await stale.value

        #expect(model.projectId == "mobile")
        #expect(model.branches == ["upstream/mobile"])
        #expect(model.base == "upstream/mobile")
    }

    @Test("switching back restores cached inventory and invalidates the stale load")
    func switchingBackRestoresCachedInventory() async throws {
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running
        let gate = AddLegBranchLoadGate()
        let model = AddMissionLegModel(environment: environment(branches: { projectID in
            if projectID == "mobile" {
                await gate.waitUntilReleased()
                return .init(names: ["mobile/main"], remoteNames: ["mobile"], localBranchNames: ["main"])
            }
            return .init(names: ["upstream/server"], remoteNames: ["upstream"], localBranchNames: ["server"])
        }))
        let projects = [project(id: "server"), project(id: "mobile")]

        try await model.load(aggregate: aggregate, projects: projects, selectedProjectID: "server")
        model.base = "upstream/server"
        model.branch = "mission/custom-server"
        let stale = Task {
            try await model.load(aggregate: aggregate, projects: projects, selectedProjectID: "mobile")
        }
        await gate.waitUntilStarted()

        try await model.load(aggregate: aggregate, projects: projects, selectedProjectID: "server")
        await gate.release()
        try await stale.value

        #expect(model.projectId == "server")
        #expect(model.branches == ["upstream/server"])
        #expect(model.base == "upstream/server")
        #expect(model.branch == "mission/custom-server")
    }

    private func environment(
        destinationAvailable: Bool = true,
        branches: ((String) async throws -> AddMissionLegModel.BranchInventory)? = nil
    ) -> AddMissionLegModel.Environment {
        .init(
            branches: branches ?? { _ in
                AddMissionLegModel.BranchInventory(
                    names: ["upstream/trunk", "trunk"],
                    remoteNames: ["upstream"],
                    localBranchNames: ["trunk"]
                )
            },
            configuredBase: { _ in "upstream/trunk" },
            configuredBranchPrefix: { _ in "mission/" },
            reservedBranches: { _ in [] },
            enabledACPAgents: { [agent(id: "codex")] },
            destination: { projectID, branch in
                URL(fileURLWithPath: "/tmp/worktrees/\(projectID)/\(branch.replacingOccurrences(of: "/", with: "-"))")
            },
            destinationAvailable: { _, _ in destinationAvailable }
        )
    }

    private func project(id: String) -> ProjectConfig {
        .init(
            id: id,
            name: id,
            path: "/tmp/\(id)",
            color: "blue",
            addedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func agent(id: String) -> AgentDefinition {
        .init(
            id: id,
            displayName: id.capitalized,
            binary: id,
            binaryOverride: nil,
            promptModeArgs: [],
            bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )
    }
}

private actor AddLegBranchLoadGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}
