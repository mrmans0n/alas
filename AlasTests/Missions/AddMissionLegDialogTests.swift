import AppKit
import Foundation
import SwiftUI
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

    @Test(arguments: [
        "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UUuuVVvvWWwwXXxxYYyyZZzz",
        "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
        "glpat-abcdefghijklmnopqrstuvwxyz0123456789",
        "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature",
        "https://octocat:super-secret@github.com/acme/alas.git",
    ])
    func errorRedactionCoversProviderTokensAndURLCredentials(secret: String) {
        let error = CodeHostProviderError.malformedOutput("Request failed: \(secret)")

        let displayed = AddMissionLegDialogActions.sanitizedError(error)

        #expect(!displayed.contains(secret))
        #expect(displayed.contains("[redacted]"))
    }

    @Test func liveRemoteDestinationValidationIgnoresLocalFilesystemCollision() throws {
        let localCollision = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-add-leg-remote-collision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localCollision, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localCollision) }
        let project = ProjectConfig(
            id: "remote-project",
            name: "remote-project",
            path: "/workspace/remote-project",
            color: "blue",
            addedAt: Date(timeIntervalSince1970: 100),
            host: "devbox"
        )
        let state = AppState()
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        let environment = AddMissionLegModel.Environment.live(state: state)

        #expect(environment.destinationAvailable(project.id, localCollision))
    }

    @Test func dialogShowsSharedIssueBodyAndExistingLegManifest() async throws {
        let fixture = try DialogFixture()
        await fixture.state.missions.load()
        let dialog = AddMissionLegDialog(
            presented: .constant(true),
            state: fixture.state,
            missionID: fixture.aggregate.mission.id
        )
        .environment(\.theme, try ThemeStore().current)
        let host = NSHostingController(rootView: dialog)
        host.view.frame = NSRect(x: 0, y: 0, width: 720, height: 860)
        host.view.layoutSubtreeIfNeeded()

        #expect(subview(
            withAccessibilityIdentifier: "add-mission-leg-shared-source-body",
            in: host.view
        ) != nil)
        for leg in fixture.aggregate.legs {
            #expect(subview(
                withAccessibilityIdentifier: "add-mission-leg-existing-leg-\(leg.id.rawValue)",
                in: host.view
            ) != nil)
        }
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

@MainActor
private func subview(withAccessibilityIdentifier identifier: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == identifier { return view }
    return view.subviews.lazy.compactMap {
        subview(withAccessibilityIdentifier: identifier, in: $0)
    }.first
}

@MainActor
private struct DialogFixture {
    let aggregate: MissionAggregate
    let state: AppState

    init() throws {
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running
        let secondary = MissionLeg(
            id: MissionLegID(rawValue: "mission-1-leg-2"),
            missionID: aggregate.mission.id,
            ordinal: 1,
            projectId: "project-2",
            baseRef: "upstream/trunk",
            branch: "fix/server-parser-crash",
            destinationPath: "/tmp/alas-server-mission",
            worktreeId: "worktree-2",
            agentId: "codex",
            acpSessionId: "session-2",
            initialPromptId: UUID(),
            pendingInitialPrompt: nil,
            reviewIdentity: nil,
            state: .running,
            setupCheckpoint: .running
        )
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("add-mission-leg-dialog-\(UUID().uuidString).sqlite")
        let persistence = MissionPersistence(path: databaseURL.path)
        let store = try MissionStore(path: databaseURL.path)
        try store.insert(aggregate)
        try store.addLeg(
            secondary,
            event: MissionFixtures.event(
                id: "mission-1-event-leg-2",
                missionID: aggregate.mission.id,
                legID: secondary.id,
                kind: .legAdded,
                createdAt: 101
            )
        )
        aggregate.legs.append(secondary)
        let projects = [
            ProjectConfig(id: "project-1", name: "Alas", path: "/tmp/alas", color: "blue", addedAt: .now),
            ProjectConfig(id: "project-2", name: "Server", path: "/tmp/server", color: "green", addedAt: .now),
            ProjectConfig(id: "project-3", name: "Web", path: "/tmp/web", color: "purple", addedAt: .now),
        ]
        state = AppState(
            store: DialogStore(projects: projects),
            missionPersistence: persistence
        )
        self.aggregate = aggregate
    }
}

private struct DialogStore: PersistenceStoreProtocol {
    let projects: [ProjectConfig]

    func write<T: Encodable>(_: T, to _: URL) throws {}

    func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? {
        if T.self == ProjectsFile.self { return ProjectsFile(projects: projects) as? T }
        if T.self == SpacesFile.self {
            return SpacesFile(activeSpaceId: "default", spaces: []) as? T
        }
        if T.self == AppConfig.self { return AppConfig.defaults as? T }
        return nil
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
