import Foundation
import Testing
@testable import Alas

@MainActor
struct AddMissionLegDialogTests {
    @Test func submissionIgnoresDuplicatesWhileInFlight() async throws {
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running

        let model = AddMissionLegModel(environment: Self.environment())
        let gate = SubmissionGate()
        var dismissed = false
        let actions = AddMissionLegDialogActions(
            model: model,
            aggregate: { aggregate },
            projects: { [Self.project(id: "project-1"), Self.project(id: "server")] },
            prepareDestination: { $0 },
            addLeg: { draft, missionID in
                await gate.started(draft: draft, missionID: missionID)
                await gate.waitUntilReleased()
                return MissionLegID(rawValue: "leg-server")
            },
            dismiss: { dismissed = true }
        )

        async let first: MissionLegID? = actions.submit(
            missionID: aggregate.mission.id,
            selectedProjectID: "server",
            instructions: "Wire the server leg."
        )
        await gate.waitUntilStarted()
        let second = await actions.submit(
            missionID: aggregate.mission.id,
            selectedProjectID: "server",
            instructions: "Wire the server leg."
        )
        await gate.release()
        let firstResult = await first

        #expect(firstResult == MissionLegID(rawValue: "leg-server"))
        #expect(second == nil)
        #expect(await gate.submissionCount == 1)
        #expect(dismissed)
    }

    @Test func submissionKeepsDialogOpenAndShowsSanitizedError() async throws {
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running

        let model = AddMissionLegModel(environment: Self.environment())
        var dismissed = false
        let actions = AddMissionLegDialogActions(
            model: model,
            aggregate: { aggregate },
            projects: { [Self.project(id: "project-1"), Self.project(id: "server")] },
            prepareDestination: { $0 },
            addLeg: { _, _ in
                throw CodeHostProviderError.malformedOutput("token ghp_secret leaked")
            },
            dismiss: { dismissed = true }
        )

        let result = await actions.submit(
            missionID: aggregate.mission.id,
            selectedProjectID: "server",
            instructions: "Wire the server leg."
        )

        #expect(result == nil)
        #expect(!dismissed)
        #expect(actions.errorMessage == "token [redacted] leaked")
        #expect(!actions.isSubmitting)
    }

    private static func environment() -> AddMissionLegModel.Environment {
        .init(
            branches: { _ in
                AddMissionLegModel.BranchInventory(
                    names: ["origin/main", "main"],
                    remoteNames: ["origin"],
                    localBranchNames: ["main"]
                )
            },
            configuredBase: { _ in "origin/main" },
            configuredBranchPrefix: { _ in "mission/" },
            reservedBranches: { _ in [] },
            enabledACPAgents: { [agent(id: "codex")] },
            destination: { projectID, branch in
                URL(fileURLWithPath: "/tmp/worktrees/\(projectID)/\(branch.replacingOccurrences(of: "/", with: "-"))")
            },
            destinationAvailable: { _, _ in true }
        )
    }

    private static func project(id: String) -> ProjectConfig {
        .init(
            id: id,
            name: id,
            path: "/tmp/\(id)",
            color: "blue",
            addedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private static func agent(id: String) -> AgentDefinition {
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

private actor SubmissionGate {
    private(set) var submissionCount = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func started(draft _: MissionLegDraft, missionID _: MissionID) {
        submissionCount += 1
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilStarted() async {
        if submissionCount > 0 { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
