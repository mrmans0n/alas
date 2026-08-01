import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("Mission coordinator")
struct MissionCoordinatorTests {
    private static let draft = MissionDraft(
        issue: MissionFixtures.issue(),
        projectId: "project-1",
        baseRef: "origin/main",
        branch: "fix/parser-crash",
        destinationPath: "/tmp/alas-mission",
        agentId: "codex",
        initialPromptId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        initialPrompt: "Fix issue #42."
    )

    @Test("success persists every checkpoint in order")
    func successPersistsEveryCheckpointInOrder() async throws {
        let fake = MissionCoordinatorFake()
        let coordinator = MissionCoordinator(environment: fake.environment)

        let id = try await coordinator.create(Self.draft)
        let aggregate = await fake.waitUntilSettled(id)

        #expect(fake.operations == [
            "insert:creatingWorktree",
            "createWorktree",
            "linkWorktree:startingAgent",
            "reserveSession",
            "startACP",
            "clearPrompt:running",
        ])
        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.setupCheckpoint == .running)
    }

    @Test("Mission is durable before Git starts")
    func missionIsDurableBeforeGitStarts() async throws {
        let fake = MissionCoordinatorFake()
        fake.aggregateObservedWhenGitStarted = true
        let coordinator = MissionCoordinator(environment: fake.environment)

        let id = try await coordinator.create(Self.draft)
        _ = await fake.waitUntilSettled(id)

        #expect(fake.missionWasDurableWhenGitStarted)
        #expect(fake.operations.first == "insert:creatingWorktree")
    }

    @Test("worktree failure stops before ACP and preserves the planned leg")
    func worktreeFailureDoesNotStartACP() async throws {
        let fake = MissionCoordinatorFake(worktreeResult: .failure(.init(message: "branch exists\nretry later")))
        let coordinator = MissionCoordinator(environment: fake.environment)

        let id = try await coordinator.create(Self.draft)
        let aggregate = await fake.waitUntilSettled(id)

        #expect(fake.createWorktreeCalls == 1)
        #expect(fake.startACPCalls == 0)
        #expect(aggregate.mission.state == .needsAttention)
        #expect(aggregate.mission.setupCheckpoint == .creatingWorktree)
        #expect(aggregate.mission.attentionReason == "branch exists retry later")
        #expect(aggregate.primaryLeg?.worktreeId == nil)
        #expect(aggregate.primaryLeg?.acpSessionId == nil)
        #expect(aggregate.primaryLeg?.pendingInitialPrompt == Self.draft.initialPrompt)
    }

    @Test("ACP failure preserves the worktree, stable session, and pending prompt")
    func acpFailurePreservesSuccessfulArtifacts() async throws {
        let fake = MissionCoordinatorFake(agentResult: .failure(.init(message: "Install Codex")))
        let coordinator = MissionCoordinator(environment: fake.environment)

        let id = try await coordinator.create(Self.draft)
        let aggregate = await fake.waitUntilSettled(id)

        #expect(fake.createWorktreeCalls == 1)
        #expect(fake.startACPCalls == 1)
        #expect(aggregate.mission.state == .needsAttention)
        #expect(aggregate.mission.setupCheckpoint == .startingAgent)
        #expect(aggregate.primaryLeg?.worktreeId == fake.worktree.id)
        #expect(aggregate.primaryLeg?.acpSessionId == fake.startedSessionIDs.first)
        #expect(aggregate.primaryLeg?.pendingInitialPrompt == Self.draft.initialPrompt)
    }

    @Test("agent retry never repeats successful Git")
    func agentFailureNeverRepeatsSuccessfulGit() async throws {
        let fake = MissionCoordinatorFake(agentResult: .failure(.init(message: "Install Codex")))
        let coordinator = MissionCoordinator(environment: fake.environment)
        let id = try await coordinator.create(Self.draft)
        _ = await fake.waitUntilSettled(id)

        fake.agentResult = nil
        await coordinator.retry(id: id)
        let aggregate = try #require(try await fake.persistence.aggregate(id: id))

        #expect(fake.createWorktreeCalls == 1)
        #expect(fake.startACPCalls == 2)
        #expect(Set(fake.startedSessionIDs).count == 1)
        #expect(aggregate.mission.state == .running)
    }

    @Test("agent replacement is persisted before retrying the agent checkpoint")
    func agentReplacementIsPersistedBeforeRetry() async throws {
        let fake = MissionCoordinatorFake(agentResult: .failure(.init(message: "Install Codex")))
        let controller = MissionController(environment: fake.environment)
        let id = try await controller.create(Self.draft, allowDuplicate: false)
        _ = await fake.waitUntilSettled(id)

        fake.agentResult = nil
        await controller.retry(id, agentId: "claude")
        let aggregate = try #require(try await fake.persistence.aggregate(id: id))

        #expect(fake.createWorktreeCalls == 1)
        #expect(fake.startedAgentIDs == ["codex", "claude"])
        #expect(aggregate.primaryLeg?.agentId == "claude")
        #expect(aggregate.mission.state == .running)
        #expect(controller.aggregate(id: id) == aggregate)
    }

    @Test("agent replacement is ignored outside the agent checkpoint")
    func agentReplacementIsIgnoredForWorktreeRetry() async throws {
        let fake = MissionCoordinatorFake(worktreeResult: .failure(.init(message: "Git failed")))
        let controller = MissionController(environment: fake.environment)
        let id = try await controller.create(Self.draft, allowDuplicate: false)
        _ = await fake.waitUntilSettled(id)

        fake.worktreeResult = .success(fake.worktree)
        await controller.retry(id, agentId: "claude")
        let aggregate = try #require(try await fake.persistence.aggregate(id: id))

        #expect(aggregate.primaryLeg?.agentId == "codex")
        #expect(fake.startedAgentIDs == ["codex"])
        #expect(aggregate.mission.state == .running)
    }

    @Test("restart reconciles an interrupted worktree by destination")
    func interruptedWorktreeReconcilesByDestination() async throws {
        let existing = MissionFixtures.creatingMission()
        let fake = MissionCoordinatorFake(existing: [existing])
        fake.worktreeAtDestination = fake.worktree
        let coordinator = MissionCoordinator(environment: fake.environment)

        await coordinator.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: existing.mission.id))

        #expect(fake.createWorktreeCalls == 0)
        #expect(fake.startACPCalls == 1)
        #expect(aggregate.primaryLeg?.worktreeId == fake.worktree.id)
        #expect(aggregate.mission.state == .running)
    }

    @Test("restart reuses a reserved ACP session ID")
    func interruptedACPReconcilesBySessionID() async throws {
        var existing = MissionFixtures.creatingMission()
        existing.mission.setupCheckpoint = .startingAgent
        existing.legs[0].worktreeId = "worktree-1"
        existing.legs[0].acpSessionId = "reserved-session"
        let fake = MissionCoordinatorFake(existing: [existing])
        let coordinator = MissionCoordinator(environment: fake.environment)

        await coordinator.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: existing.mission.id))

        #expect(fake.createWorktreeCalls == 0)
        #expect(fake.startedSessionIDs == ["reserved-session"])
        #expect(aggregate.primaryLeg?.acpSessionId == "reserved-session")
        #expect(aggregate.mission.state == .running)
    }

    @Test("startup reconciles a discovered artifact without repeating a settled failed command")
    func settledWorktreeFailureOnlyReconcilesItsArtifact() async throws {
        var existing = MissionFixtures.creatingMission()
        existing.mission.state = .needsAttention
        existing.mission.attentionReason = "Git response was lost."
        let fake = MissionCoordinatorFake(existing: [existing])
        fake.worktreeAtDestination = fake.worktree
        let coordinator = MissionCoordinator(environment: fake.environment)

        await coordinator.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: existing.mission.id))

        #expect(fake.createWorktreeCalls == 0)
        #expect(fake.startACPCalls == 0)
        #expect(aggregate.primaryLeg?.worktreeId == fake.worktree.id)
        #expect(aggregate.mission.state == .needsAttention)
        #expect(aggregate.mission.setupCheckpoint == .startingAgent)
    }

    @Test("startup does not automatically retry a settled agent failure")
    func startupDoesNotAutoRetrySettledFailure() async throws {
        var existing = MissionFixtures.creatingMission()
        existing.mission.state = .needsAttention
        existing.mission.setupCheckpoint = .startingAgent
        existing.mission.attentionReason = "Install Codex"
        existing.legs[0].worktreeId = "worktree-1"
        existing.legs[0].acpSessionId = "reserved-session"
        let fake = MissionCoordinatorFake(existing: [existing])
        let coordinator = MissionCoordinator(environment: fake.environment)

        await coordinator.reconcileInterrupted()

        #expect(fake.createWorktreeCalls == 0)
        #expect(fake.startACPCalls == 0)
    }

    @Test("duplicate creation is blocked unless explicitly allowed")
    func duplicateRequiresExplicitOverride() async throws {
        let fake = MissionCoordinatorFake()
        let coordinator = MissionCoordinator(environment: fake.environment)
        let firstID = try await coordinator.create(Self.draft)
        _ = await fake.waitUntilSettled(firstID)

        await #expect(throws: MissionStore.Error.duplicateActiveIssueIdentity) {
            try await coordinator.create(Self.draft)
        }
        let duplicateID = try await coordinator.create(Self.draft, allowDuplicate: true)
        _ = await fake.waitUntilSettled(duplicateID)

        #expect(try await fake.persistence.list(includeCompleted: false).count == 2)
    }

    @Test("controller load publishes persisted aggregates in Mission order")
    func controllerLoadsSortedAggregates() async {
        let older = MissionFixtures.creatingMission(
            id: "older",
            issue: MissionFixtures.issue(number: 41),
            createdAt: 100
        )
        let newer = MissionFixtures.creatingMission(
            id: "newer",
            issue: MissionFixtures.issue(number: 43),
            createdAt: 200
        )
        let fake = MissionCoordinatorFake(existing: [older, newer])
        let controller = MissionController(environment: fake.environment)

        await controller.load()

        #expect(controller.aggregates.map(\.mission.id) == [
            MissionID(rawValue: "newer"),
            MissionID(rawValue: "older"),
        ])
        #expect(controller.loadError == nil)
    }

    @Test("observers receive every durable success checkpoint")
    func notifiesAfterEveryCheckpoint() async throws {
        let fake = MissionCoordinatorFake()
        let coordinator = MissionCoordinator(environment: fake.environment)

        let id = try await coordinator.create(Self.draft)
        _ = await fake.waitUntilSettled(id)

        #expect(fake.notifications.map(NotificationSnapshot.init) == [
            NotificationSnapshot(state: .creating, checkpoint: .creatingWorktree, hasSession: false, clearedPrompt: false),
            NotificationSnapshot(state: .creating, checkpoint: .startingAgent, hasSession: false, clearedPrompt: false),
            NotificationSnapshot(state: .creating, checkpoint: .startingAgent, hasSession: true, clearedPrompt: false),
            NotificationSnapshot(state: .running, checkpoint: .running, hasSession: true, clearedPrompt: true),
        ])
    }
}

private struct NotificationSnapshot: Equatable {
    let state: MissionState
    let checkpoint: MissionSetupCheckpoint
    let hasSession: Bool
    let clearedPrompt: Bool

    init(_ aggregate: MissionAggregate) {
        state = aggregate.mission.state
        checkpoint = aggregate.mission.setupCheckpoint
        hasSession = aggregate.primaryLeg?.acpSessionId != nil
        clearedPrompt = aggregate.primaryLeg?.pendingInitialPrompt == nil
    }

    init(
        state: MissionState,
        checkpoint: MissionSetupCheckpoint,
        hasSession: Bool,
        clearedPrompt: Bool
    ) {
        self.state = state
        self.checkpoint = checkpoint
        self.hasSession = hasSession
        self.clearedPrompt = clearedPrompt
    }
}

@MainActor
private final class MissionCoordinatorFake {
    let persistence: MissionPersistence
    let worktree = Worktree(
        id: "worktree-1",
        projectId: "project-1",
        name: "fix/parser-crash",
        branch: "fix/parser-crash",
        path: URL(fileURLWithPath: "/tmp/alas-mission"),
        status: .clean,
        lastActivity: Date(timeIntervalSince1970: 100)
    )

    var worktreeResult: Result<Worktree, WorktreeCreationFailure>
    var agentResult: Result<ACPSession.ID, MissionCoordinator.MissionOperationFailure>?
    var worktreeAtDestination: Worktree?
    var aggregateObservedWhenGitStarted = false
    private(set) var missionWasDurableWhenGitStarted = false
    private(set) var createWorktreeCalls = 0
    private(set) var startACPCalls = 0
    private(set) var startedSessionIDs: [String] = []
    private(set) var startedAgentIDs: [String] = []
    private(set) var operations: [String] = []
    private(set) var notifications: [MissionAggregate] = []

    private var idCounter = 0
    private var clock: TimeInterval = 1_000

    init(
        existing: [MissionAggregate] = [],
        worktreeResult: Result<Worktree, WorktreeCreationFailure>? = nil,
        agentResult: Result<ACPSession.ID, MissionCoordinator.MissionOperationFailure>? = nil
    ) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mission-coordinator-\(UUID().uuidString).sqlite")
            .path
        let store = try! MissionStore(path: path)
        for aggregate in existing {
            try! store.insert(aggregate)
        }
        persistence = MissionPersistence(path: path)
        self.worktreeResult = worktreeResult ?? .success(worktree)
        self.agentResult = agentResult
        if existing.contains(where: { $0.primaryLeg?.worktreeId != nil }) {
            worktreeAtDestination = worktree
        }
    }

    var environment: MissionCoordinator.Environment {
        .init(
            persistence: persistence,
            now: { [weak self] in
                guard let self else { return .distantPast }
                self.clock += 1
                return Date(timeIntervalSince1970: self.clock)
            },
            makeID: { [weak self] in
                guard let self else { return UUID().uuidString }
                self.idCounter += 1
                return "id-\(self.idCounter)"
            },
            worktreeAtDestination: { [weak self] projectID, path in
                guard let self,
                      projectID == self.worktree.projectId,
                      URL(fileURLWithPath: path).standardizedFileURL.path == self.worktree.path.standardizedFileURL.path
                else { return nil }
                return self.worktreeAtDestination
            },
            createWorktree: { [weak self] leg in
                guard let self else { return .failure(.init(message: "Fake released")) }
                self.createWorktreeCalls += 1
                self.operations.append("createWorktree")
                if self.aggregateObservedWhenGitStarted {
                    self.missionWasDurableWhenGitStarted = (try? await self.persistence.aggregate(id: leg.missionID)) != nil
                }
                if case .success(let worktree) = self.worktreeResult {
                    self.worktreeAtDestination = worktree
                }
                return self.worktreeResult
            },
            startACP: { [weak self] leg, _ in
                guard let self else {
                    return .failure(.init(message: "Fake released"))
                }
                self.startACPCalls += 1
                self.operations.append("startACP")
                self.startedAgentIDs.append(leg.agentId)
                self.startedSessionIDs.append(leg.acpSessionId ?? "")
                return self.agentResult ?? .success(leg.acpSessionId ?? "")
            },
            notifyChanged: { [weak self] aggregate in
                guard let self else { return }
                self.notifications.append(aggregate)
                if aggregate.events.last?.kind == .created, aggregate.primaryLeg?.worktreeId == nil {
                    self.operations.append("insert:creatingWorktree")
                } else if aggregate.mission.setupCheckpoint == .startingAgent,
                          aggregate.primaryLeg?.worktreeId != nil,
                          aggregate.primaryLeg?.acpSessionId == nil {
                    self.operations.append("linkWorktree:startingAgent")
                } else if aggregate.mission.setupCheckpoint == .startingAgent,
                          aggregate.primaryLeg?.acpSessionId != nil,
                          aggregate.mission.state == .creating,
                          aggregate.events.last?.kind == .worktreeCreated {
                    self.operations.append("reserveSession")
                } else if aggregate.mission.state == .running,
                          aggregate.primaryLeg?.pendingInitialPrompt == nil {
                    self.operations.append("clearPrompt:running")
                }
            }
        )
    }

    func waitUntilSettled(_ id: MissionID) async -> MissionAggregate {
        for _ in 0..<200 {
            if let aggregate = try? await persistence.aggregate(id: id),
               aggregate.mission.state != .creating,
               notifications.last(where: { $0.mission.id == id })?.mission.state == aggregate.mission.state {
                return aggregate
            }
            await Task.yield()
        }
        return try! await persistence.aggregate(id: id)!
    }
}
