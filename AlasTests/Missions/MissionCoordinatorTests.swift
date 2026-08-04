import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("Mission coordinator")
struct MissionCoordinatorTests {
    private static let primaryDraft = MissionDraft(
        issue: MissionFixtures.issue(),
        projectId: "project-1",
        baseRef: "origin/main",
        baseRemoteName: "origin",
        branch: "fix/parser-crash",
        destinationPath: "/tmp/alas-mission",
        agentId: "codex",
        initialPromptId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        initialPrompt: "Fix issue #42."
    )

    private static let draft = primaryDraft

    private static let sdkDraft = MissionLegDraft(
        projectId: "project-sdk",
        baseRef: "origin/main",
        baseRemoteName: "origin",
        branch: "fix/parser-crash-sdk",
        destinationPath: "/tmp/alas-mission-sdk",
        agentId: "codex",
        initialPromptId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        preparedPrompt: "Fix the SDK integration for issue #42."
    )

    private static let serverDraft = MissionLegDraft(
        projectId: "project-server",
        baseRef: "origin/main",
        baseRemoteName: "origin",
        branch: "fix/parser-crash-server",
        destinationPath: "/tmp/alas-mission-server",
        agentId: "claude",
        initialPromptId: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        preparedPrompt: "Fix the server integration for issue #42."
    )

    // Break caught: serializing setup by Mission ID prevents two durable legs
    // from reaching their independent Git checkpoints together.
    @Test("secondary legs advance independently")
    func secondaryLegsAdvanceIndependently() async throws {
        let fake = MissionCoordinatorFake(suspendWorktreeCreation: true)
        let coordinator = MissionCoordinator(environment: fake.environment)
        let missionID = try await coordinator.create(Self.primaryDraft)
        await fake.waitForWorktreeStarts(count: 1)
        await fake.resumeWorktreeCreation(for: try #require(fake.startedLegIDs.first))
        _ = await fake.waitUntilSettled(missionID)
        fake.clearStartedLegIDs()

        async let first = coordinator.addLeg(missionID: missionID, draft: Self.sdkDraft)
        async let second = coordinator.addLeg(missionID: missionID, draft: Self.serverDraft)
        let legIDs = try await [first, second]

        await fake.waitForWorktreeStarts(count: 2)

        #expect(Set(fake.startedLegIDs) == Set(legIDs))

        for legID in legIDs {
            await fake.resumeWorktreeCreation(for: legID)
        }
    }

    // Break caught: applying a secondary setup failure to the aggregate state
    // would make a running Mission unavailable while another leg succeeds.
    @Test("secondary leg failure is isolated from sibling setup")
    func secondaryLegFailureIsIsolatedFromSiblingSetup() async throws {
        let fake = MissionCoordinatorFake(suspendWorktreeCreation: true)
        let coordinator = MissionCoordinator(environment: fake.environment)
        let missionID = try await coordinator.create(Self.primaryDraft)
        await fake.waitForWorktreeStarts(count: 1)
        await fake.resumeWorktreeCreation(for: try #require(fake.startedLegIDs.first))
        _ = await fake.waitUntilSettled(missionID)
        fake.clearStartedLegIDs()

        async let sdk = coordinator.addLeg(missionID: missionID, draft: Self.sdkDraft)
        async let server = coordinator.addLeg(missionID: missionID, draft: Self.serverDraft)
        let sdkLegID = try await sdk
        let serverLegID = try await server
        await fake.waitForWorktreeStarts(count: 2)
        fake.worktreeResultsByLegID[sdkLegID] = .failure(.init(message: "SDK Git failed"))

        await fake.resumeWorktreeCreation(for: sdkLegID)
        await fake.resumeWorktreeCreation(for: serverLegID)
        let aggregate = await fake.waitUntilLegsSettled(missionID, count: 2)

        #expect(aggregate.mission.state == .running)
        #expect(aggregate.legs.first(where: { $0.id == sdkLegID })?.state == .needsAttention)
        #expect(aggregate.legs.first(where: { $0.id == serverLegID })?.state == .running)
    }

    // Break caught: continuing with ACP after an in-flight Git operation returns
    // can start new external work after the Mission has completed.
    @Test("completion after Git returns prevents ACP startup")
    func completionAfterGitReturnsPreventsACPStartup() async throws {
        let fake = MissionCoordinatorFake(suspendWorktreeCreation: true)
        let coordinator = MissionCoordinator(environment: fake.environment)
        let missionID = try await coordinator.create(Self.primaryDraft)
        await fake.waitForWorktreeStarts(count: 1)

        var leg = try #require(try await fake.persistence.leg(
            missionID: missionID,
            legID: MissionLegID(rawValue: "id-2")
        ))
        leg.state = .ready
        leg.setupCheckpoint = .running
        leg.readinessEvidence = .init(kind: .legacy, observedAt: .now)
        try await fake.persistence.updateLeg(leg, event: nil)
        try await fake.persistence.complete(
            id: missionID,
            at: .now,
            event: MissionFixtures.event(
                id: "completed-after-git",
                missionID: missionID,
                legID: leg.id,
                kind: .completed
            )
        )
        let completed = try #require(try await fake.persistence.aggregate(id: missionID))

        await fake.resumeWorktreeCreation(for: leg.id)
        for _ in 0..<20 { await Task.yield() }

        #expect(fake.startACPCalls == 0)
        #expect(try await fake.persistence.aggregate(id: missionID) == completed)
    }

    @Test("completion while ACP startup is suspended preserves completed history")
    func completionWhileACPStartupIsSuspendedPreservesCompletedHistory() async throws {
        let fake = MissionCoordinatorFake(suspendACPStartup: true)
        let coordinator = MissionCoordinator(environment: fake.environment)
        let missionID = try await coordinator.create(Self.primaryDraft)
        await fake.waitForACPStarts(count: 1)

        let beforeCompletion = try #require(try await fake.persistence.aggregate(id: missionID))
        let legID = try #require(beforeCompletion.primaryLeg?.id)
        try await fake.persistence.complete(
            id: missionID,
            at: .now,
            event: MissionFixtures.event(
                id: "completed-during-agent-start",
                missionID: missionID,
                legID: legID,
                kind: .completed
            )
        )
        let completed = try #require(try await fake.persistence.aggregate(id: missionID))

        await fake.resumeACPStartup(for: legID)
        for _ in 0..<20 { await Task.yield() }

        #expect(try await fake.persistence.aggregate(id: missionID) == completed)
    }

    // Break caught: completion can race after the ACP session reservation is
    // durable but before the coordinator starts the next external operation.
    @Test("completion after session reservation prevents ACP startup")
    func completionAfterSessionReservationPreventsACPStartup() async throws {
        let fake = MissionCoordinatorFake(completeWhenSessionReserved: true)
        let coordinator = MissionCoordinator(environment: fake.environment)

        let missionID = try await coordinator.create(Self.primaryDraft)
        for _ in 0..<200 {
            if try await fake.persistence.aggregate(id: missionID)?.mission.state == .completed {
                break
            }
            await Task.yield()
        }

        let aggregate = try #require(try await fake.persistence.aggregate(id: missionID))
        #expect(aggregate.mission.state == .completed)
        #expect(aggregate.primaryLeg?.acpSessionId != nil)
        #expect(fake.startACPCalls == 0)
    }

    // Break caught: restart reconciliation awaits one creating leg to settle
    // before advancing the next, serializing otherwise independent Git work.
    @Test("restart advances creating legs independently")
    func restartAdvancesCreatingLegsIndependently() async throws {
        let fake = MissionCoordinatorFake(suspendWorktreeCreation: true)
        let coordinator = MissionCoordinator(environment: fake.environment)
        let missionID = try await coordinator.create(Self.primaryDraft)
        await fake.waitForWorktreeStarts(count: 1)
        await fake.resumeWorktreeCreation(for: try #require(fake.startedLegIDs.first))
        _ = await fake.waitUntilSettled(missionID)
        fake.clearStartedLegIDs()

        let aggregate = try #require(try await fake.persistence.aggregate(id: missionID))
        let now = Date()
        let sdkLeg = Self.leg(
            id: MissionLegID(rawValue: "restart-sdk"),
            missionID: missionID,
            ordinal: 1,
            draft: Self.sdkDraft,
            at: now
        )
        let serverLeg = Self.leg(
            id: MissionLegID(rawValue: "restart-server"),
            missionID: missionID,
            ordinal: 2,
            draft: Self.serverDraft,
            at: now
        )
        try await fake.persistence.addLeg(sdkLeg, event: MissionEvent(
            id: "restart-sdk-added",
            missionID: missionID,
            legID: sdkLeg.id,
            kind: .legAdded,
            message: "Mission leg added.",
            createdAt: now
        ))
        try await fake.persistence.addLeg(serverLeg, event: MissionEvent(
            id: "restart-server-added",
            missionID: missionID,
            legID: serverLeg.id,
            kind: .legAdded,
            message: "Mission leg added.",
            createdAt: now
        ))
        #expect(aggregate.mission.state == .running)

        let reconciliation = Task { @MainActor in
            await coordinator.reconcileInterrupted()
        }
        await fake.waitForWorktreeStarts(count: 2)

        #expect(Set(fake.startedLegIDs) == Set([sdkLeg.id, serverLeg.id]))

        await fake.resumeWorktreeCreation(for: sdkLeg.id)
        await fake.waitForWorktreeStarts(count: 2)
        await fake.resumeWorktreeCreation(for: serverLeg.id)
        await reconciliation.value
    }

    private static func leg(
        id: MissionLegID,
        missionID: MissionID,
        ordinal: Int,
        draft: MissionLegDraft,
        at: Date
    ) -> MissionLeg {
        MissionLeg(
            id: id,
            missionID: missionID,
            ordinal: ordinal,
            projectId: draft.projectId,
            baseRef: draft.baseRef,
            baseRemoteName: draft.baseRemoteName,
            branch: draft.branch,
            destinationPath: draft.destinationPath,
            worktreeId: nil,
            agentId: draft.agentId,
            acpSessionId: nil,
            initialPromptId: draft.initialPromptId,
            pendingInitialPrompt: draft.preparedPrompt,
            reviewIdentity: nil,
            createdAt: at,
            updatedAt: at
        )
    }

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
        #expect(aggregate.primaryLeg?.baseRemoteName == "origin")
        #expect(aggregate.primaryLeg?.worktreeLineageID == fake.worktree.lineageID)
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

    @Test("worktree reservation is durable before Git starts")
    func worktreeReservationIsDurableBeforeGitStarts() async throws {
        let fake = MissionCoordinatorFake()
        fake.aggregateObservedWhenGitStarted = true
        let coordinator = MissionCoordinator(environment: fake.environment)

        let id = try await coordinator.create(Self.draft)
        _ = await fake.waitUntilSettled(id)

        #expect(fake.worktreeReservationWasDurableWhenGitStarted)
    }

    @Test("worktree failure stops before ACP and preserves the planned leg")
    func worktreeFailureDoesNotStartACP() async throws {
        let fake = MissionCoordinatorFake(worktreeResult: .failure(.init(message: "branch exists\nretry later")))
        let coordinator = MissionCoordinator(environment: fake.environment)

        let id = try await coordinator.create(Self.draft)
        let aggregate = await fake.waitUntilSettled(id)

        #expect(fake.createWorktreeCalls == 1)
        #expect(fake.startACPCalls == 0)
        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.setupCheckpoint == .creatingWorktree)
        #expect(aggregate.mission.attentionReason == "branch exists retry later")
        #expect(aggregate.primaryLeg?.worktreeId == fake.worktree.id)
        #expect(aggregate.primaryLeg?.acpSessionId == nil)
        #expect(aggregate.primaryLeg?.pendingInitialPrompt == Self.draft.initialPrompt)
    }

    @Test("missing durable worktree lineage stops before ACP")
    func missingWorktreeLineageDoesNotStartACP() async throws {
        var worktree = MissionCoordinatorFake().worktree
        worktree.lineageID = nil
        let fake = MissionCoordinatorFake(worktreeResult: .success(worktree))
        let coordinator = MissionCoordinator(environment: fake.environment)

        let id = try await coordinator.create(Self.draft)
        let aggregate = await fake.waitUntilSettled(id)

        #expect(fake.createWorktreeCalls == 1)
        #expect(fake.startACPCalls == 0)
        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.setupCheckpoint == .creatingWorktree)
        #expect(aggregate.mission.attentionReason == "Could not establish a durable identity for the Mission worktree. Retry this Mission.")
        #expect(aggregate.primaryLeg?.worktreeLineageID == nil)
    }

    @Test("new Mission creation does not adopt an unrelated existing destination")
    func newMissionCreationDoesNotAdoptExistingDestination() async throws {
        let fake = MissionCoordinatorFake()
        fake.worktreeAtDestination = fake.worktree
        let coordinator = MissionCoordinator(environment: fake.environment)

        let id = try await coordinator.create(Self.draft)
        let aggregate = await fake.waitUntilSettled(id)

        #expect(fake.createWorktreeCalls == 0)
        #expect(fake.startACPCalls == 0)
        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.setupCheckpoint == .creatingWorktree)
        #expect(aggregate.mission.attentionReason == "A worktree already exists at the Mission destination. Choose a different branch or remove the existing worktree.")
        #expect(aggregate.primaryLeg?.worktreeId == nil)
    }

    @Test("ACP failure preserves the worktree, stable session, and pending prompt")
    func acpFailurePreservesSuccessfulArtifacts() async throws {
        let fake = MissionCoordinatorFake(agentResult: .failure(.init(message: "Install Codex")))
        let coordinator = MissionCoordinator(environment: fake.environment)

        let id = try await coordinator.create(Self.draft)
        let aggregate = await fake.waitUntilSettled(id)

        #expect(fake.createWorktreeCalls == 1)
        #expect(fake.startACPCalls == 1)
        #expect(aggregate.mission.state == .running)
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

    @Test("agent retry rejects a replacement worktree on another branch")
    func agentRetryRejectsWrongBranchReplacement() async throws {
        var retrying = MissionFixtures.creatingMission()
        retrying.mission.state = .needsAttention
        retrying.mission.setupCheckpoint = .startingAgent
        retrying.legs[0].state = .needsAttention
        retrying.legs[0].setupCheckpoint = .startingAgent
        retrying.legs[0].worktreeId = "worktree-1"
        retrying.legs[0].acpSessionId = "session-1"
        let fake = MissionCoordinatorFake(existing: [retrying])
        fake.worktree.branch = "unrelated-branch"
        fake.worktreeAtDestination = fake.worktree
        let controller = MissionController(environment: fake.environment)

        await controller.retry(retrying.mission.id, legID: retrying.legs[0].id)
        let aggregate = try #require(try await fake.persistence.aggregate(id: retrying.mission.id))

        #expect(fake.startACPCalls == 0)
        #expect(aggregate.primaryLeg?.state == .needsAttention)
        #expect(aggregate.primaryLeg?.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage)
    }

    @Test("missing worktree recovery restarts the worktree checkpoint")
    func missingWorktreeRecoveryRestartsWorktreeCheckpoint() async throws {
        var missing = MissionFixtures.creatingMission()
        missing.mission.state = .running
        missing.mission.setupCheckpoint = .running
        missing.legs[0].state = .running
        missing.legs[0].setupCheckpoint = .running
        missing.legs[0].worktreeId = "missing-worktree"
        missing.legs[0].acpSessionId = "missing-session"
        missing.legs[0].pendingInitialPrompt = nil
        let fake = MissionCoordinatorFake(
            existing: [missing],
            agentResult: .failure(.init(message: "Install Codex"))
        )
        fake.worktreeAtDestination = nil
        let controller = MissionController(environment: fake.environment)

        await controller.recordMissingWorktree(missing.mission.id, legID: missing.legs[0].id)
        let marked = try #require(try await fake.persistence.aggregate(id: missing.mission.id))
        #expect(marked.primaryLeg?.state == .needsAttention)
        #expect(marked.primaryLeg?.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage)

        await controller.retry(missing.mission.id, legID: missing.legs[0].id)
        let recovered = await fake.waitUntilSettled(missing.mission.id)

        #expect(fake.createWorktreeCalls == 1)
        #expect(fake.startACPCalls == 1)
        #expect(fake.startedPromptIDs == [missing.legs[0].initialPromptId])
        #expect(recovered.primaryLeg?.state == .needsAttention)
        #expect(recovered.primaryLeg?.setupCheckpoint == .startingAgent)
        #expect(recovered.primaryLeg?.worktreeId == fake.worktree.id)
        #expect(recovered.primaryLeg?.acpSessionId != "missing-session")
        #expect(recovered.primaryLeg?.pendingInitialPrompt != nil)
    }

    @Test("recreate retry restores a matching worktree that reappeared")
    func recreateRetryRestoresReappearedWorktree() async throws {
        var missing = MissionFixtures.creatingMission()
        missing.mission.state = .needsAttention
        missing.mission.setupCheckpoint = .running
        missing.mission.attentionReason = MissionReadinessEvaluator.missingWorktreeMessage
        missing.legs[0].state = .needsAttention
        missing.legs[0].setupCheckpoint = .running
        missing.legs[0].attentionReason = MissionReadinessEvaluator.missingWorktreeMessage
        missing.legs[0].worktreeId = "worktree-1"
        missing.legs[0].worktreeLineageID = "lineage-1"
        missing.legs[0].acpSessionId = "session-1"
        missing.legs[0].pendingInitialPrompt = nil
        let fake = MissionCoordinatorFake(existing: [missing])
        let controller = MissionController(environment: fake.environment)

        await controller.retry(missing.mission.id, legID: missing.legs[0].id)
        let recovered = try #require(try await fake.persistence.aggregate(id: missing.mission.id))

        #expect(fake.createWorktreeCalls == 0)
        #expect(fake.startACPCalls == 0)
        #expect(recovered.primaryLeg?.state == .running)
        #expect(recovered.primaryLeg?.setupCheckpoint == .running)
        #expect(recovered.primaryLeg?.worktreeId == "worktree-1")
        #expect(recovered.primaryLeg?.worktreeLineageID == "lineage-1")
        #expect(recovered.primaryLeg?.acpSessionId == "session-1")
        #expect(recovered.primaryLeg?.pendingInitialPrompt == nil)
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

    @Test("agent replacement uses a fresh persisted ACP session with the replacement agent")
    func agentReplacementCreatesSessionForReplacementAgent() async throws {
        let fake = MissionCoordinatorFake(agentResult: .failure(.init(message: "Install Codex")))
        fake.idValues = ["mission", "leg", "created", "worktree", "old-session", "new-session"]
        let sessionStore = try ACPSessionStore(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("mission-agent-replacement-\(UUID()).sqlite").path)
        let sessionManager = ACPSessionManager(
            worktreeId: fake.worktree.id,
            worktreePath: fake.worktree.path.path,
            store: sessionStore
        )
        sessionManager.createSession(id: "old-session", agentId: "codex")
        await sessionManager.flushPersistence()
        fake.startACPOverride = { leg, _ in
            guard let sessionID = leg.acpSessionId else {
                return .failure(.init(message: "Missing session"))
            }
            if await sessionManager.persistedSessionRow(id: sessionID) == nil {
                sessionManager.createSession(id: sessionID, agentId: leg.agentId)
                await sessionManager.flushPersistence()
            }
            return .failure(.init(message: "Install \(leg.agentId)"))
        }
        let controller = MissionController(environment: fake.environment)

        let id = try await controller.create(Self.draft, allowDuplicate: false)
        _ = await fake.waitUntilSettled(id)
        await controller.retry(id, agentId: "claude")
        let firstRetry = try #require(try await fake.persistence.aggregate(id: id))
        let replacementSessionID = try #require(firstRetry.primaryLeg?.acpSessionId)

        #expect(replacementSessionID != "old-session")
        #expect(try sessionStore.loadSession(id: "old-session")?.agentId == "codex")
        #expect(try sessionStore.loadSession(id: replacementSessionID)?.agentId == "claude")

        await controller.retry(id, agentId: "claude")
        let repeatedRetry = try #require(try await fake.persistence.aggregate(id: id))
        #expect(repeatedRetry.primaryLeg?.acpSessionId == replacementSessionID)
        #expect(try sessionStore.loadSession(id: replacementSessionID)?.agentId == "claude")
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

    @Test("failed optimistic worktree stays eligible for Mission worktree retry")
    func failedOptimisticWorktreeDoesNotSatisfyMissionDestination() async throws {
        let project = ProjectConfig(
            id: "project-1",
            name: "Alas",
            path: "/tmp/alas",
            color: "teal",
            addedAt: .now
        )
        let state = AppState(store: MissionProjectStore(projects: [project]))
        let failed = Worktree(
            id: "optimistic-worktree",
            projectId: project.id,
            name: "fix/parser-crash",
            branch: "fix/parser-crash",
            path: URL(fileURLWithPath: Self.draft.destinationPath),
            status: .running,
            lastActivity: .now,
            lineageID: "optimistic-worktree-lineage"
        )
        state.projectsManager.insertOptimisticWorktree(failed)
        state.projectsManager.setOperationState(
            id: failed.id,
            state: .createFailed(
                projectId: project.id,
                message: "branch exists",
                base: Self.draft.baseRef,
                ggWorktreeMode: .off
            )
        )

        #expect(state.missionWorktreeAtDestination(
            projectID: project.id,
            destinationPath: Self.draft.destinationPath
        ) == nil)

        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .needsAttention
        aggregate.mission.attentionReason = "branch exists"
        let fake = MissionCoordinatorFake(existing: [aggregate])
        var retryGitCalls = 0
        let coordinator = MissionCoordinator(environment: .init(
            persistence: fake.persistence,
            now: { Date() },
            makeID: { UUID().uuidString },
            worktreeAtDestination: { projectID, destinationPath in
                state.missionWorktreeAtDestination(projectID: projectID, destinationPath: destinationPath)
            },
            createWorktree: { _ in
                retryGitCalls += 1
                state.projectsManager.setOperationState(id: failed.id, state: nil)
                return .success(failed)
            },
            startACP: { leg, _ in .success(leg.acpSessionId ?? "") },
            notifyChanged: { _ in }
        ))

        await coordinator.retry(id: aggregate.mission.id)

        #expect(retryGitCalls == 1)
        #expect(try await fake.persistence.aggregate(id: aggregate.mission.id)?.mission.state == .running)
    }

    @Test("delete-failed worktree satisfies the Mission artifact checkpoint")
    func deleteFailedWorktreeSatisfiesMissionDestination() async throws {
        let project = ProjectConfig(
            id: "project-1",
            name: "Alas",
            path: "/tmp/alas",
            color: "teal",
            addedAt: .now
        )
        let state = AppState(store: MissionProjectStore(projects: [project]))
        let retained = Worktree(
            id: "retained-worktree",
            projectId: project.id,
            name: "fix/parser-crash",
            branch: "fix/parser-crash",
            path: URL(fileURLWithPath: Self.draft.destinationPath),
            status: .dirty,
            lastActivity: .now,
            lineageID: "retained-worktree-lineage"
        )
        state.projectsManager.insertOptimisticWorktree(retained)
        state.projectsManager.setOperationState(
            id: retained.id,
            state: .deleteFailed(message: "worktree contains changes")
        )

        #expect(state.missionWorktreeAtDestination(
            projectID: project.id,
            destinationPath: Self.draft.destinationPath
        ) == retained)

        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .needsAttention
        aggregate.mission.attentionReason = "retrying worktree setup"
        aggregate.legs[0].worktreeId = retained.id
        let fake = MissionCoordinatorFake(existing: [aggregate])
        var retryGitCalls = 0
        let coordinator = MissionCoordinator(environment: .init(
            persistence: fake.persistence,
            now: { Date() },
            makeID: { UUID().uuidString },
            worktreeAtDestination: { projectID, destinationPath in
                state.missionWorktreeAtDestination(projectID: projectID, destinationPath: destinationPath)
            },
            createWorktree: { _ in
                retryGitCalls += 1
                return .failure(.init(message: "should not create a duplicate worktree"))
            },
            startACP: { leg, _ in .success(leg.acpSessionId ?? "") },
            notifyChanged: { _ in }
        ))

        await coordinator.retry(id: aggregate.mission.id)

        #expect(retryGitCalls == 0)
        #expect(try await fake.persistence.aggregate(id: aggregate.mission.id)?.mission.state == .running)
    }

    @Test("checkpoint persistence failure becomes recoverable attention")
    func checkpointPersistenceFailureBecomesAttention() async throws {
        let fake = MissionCoordinatorFake()
        // The worktree checkpoint event collides with the already persisted
        // creation event. The following ID lets the recovery attention event win.
        fake.idValues = ["mission", "leg", "created-event", "created-event", "attention-event"]
        let coordinator = MissionCoordinator(environment: fake.environment)

        let id = try await coordinator.create(Self.draft)
        let aggregate = await fake.waitUntilSettled(id)

        #expect(fake.createWorktreeCalls == 1)
        #expect(fake.startACPCalls == 0)
        #expect(aggregate.mission.state == .running)
        #expect(aggregate.mission.setupCheckpoint == .creatingWorktree)
        #expect(aggregate.mission.attentionReason == "Could not persist Mission setup progress. Retry this Mission.")
        #expect(aggregate.primaryLeg?.worktreeId == fake.worktree.id)
        #expect(fake.reportedFailures.isEmpty)
    }

    @Test("agent checkpoint persistence failure does not leave the initial prompt retryable")
    func agentCheckpointPersistenceFailureClearsPromptBeforeRecovery() async throws {
        let fake = MissionCoordinatorFake()
        // The agent checkpoint event collides after ACP startup has succeeded.
        // The recovery event should persist the consumed prompt receipt.
        fake.idValues = [
            "mission",
            "leg",
            "created-event",
            "worktree-event",
            "session",
            "created-event",
            "attention-event",
        ]
        let coordinator = MissionCoordinator(environment: fake.environment)

        let id = try await coordinator.create(Self.draft)
        let failed = await fake.waitUntilSettled(id)

        #expect(fake.startACPCalls == 1)
        #expect(fake.startedPromptIDs == [Self.draft.initialPromptId])
        #expect(failed.mission.state == .running)
        #expect(failed.mission.setupCheckpoint == .startingAgent)
        #expect(failed.primaryLeg?.pendingInitialPrompt == nil)

        await coordinator.retry(id: id)
        let recovered = try #require(try await fake.persistence.aggregate(id: id))

        #expect(fake.startACPCalls == 2)
        #expect(fake.startedPromptIDs == [Self.draft.initialPromptId])
        #expect(recovered.mission.state == .running)
        #expect(recovered.mission.setupCheckpoint == .running)
    }

    @Test("agent startup failure after prompt consumption does not leave the initial prompt retryable")
    func agentStartupFailureAfterPromptConsumptionClearsPromptBeforeRecovery() async throws {
        let fake = MissionCoordinatorFake()
        fake.startACPOverride = { leg, _ in
            .failure(.init(
                message: "Install Codex",
                consumedInitialPrompt: leg.pendingInitialPrompt != nil
            ))
        }
        let coordinator = MissionCoordinator(environment: fake.environment)

        let id = try await coordinator.create(Self.draft)
        let failed = await fake.waitUntilSettled(id)

        #expect(fake.startACPCalls == 1)
        #expect(fake.startedPromptIDs == [Self.draft.initialPromptId])
        #expect(failed.mission.state == .running)
        #expect(failed.mission.setupCheckpoint == .startingAgent)
        #expect(failed.mission.attentionReason == "Install Codex")
        #expect(failed.primaryLeg?.pendingInitialPrompt == nil)

        fake.startACPOverride = nil
        await coordinator.retry(id: id)
        let recovered = try #require(try await fake.persistence.aggregate(id: id))

        #expect(fake.startACPCalls == 2)
        #expect(fake.startedPromptIDs == [Self.draft.initialPromptId])
        #expect(recovered.mission.state == .running)
        #expect(recovered.mission.setupCheckpoint == .running)
    }

    @Test("agent replacement starts a fresh delegation after prompt consumption")
    func agentReplacementStartsFreshDelegationAfterPromptConsumption() async throws {
        let fake = MissionCoordinatorFake()
        fake.idValues = [
            "mission",
            "leg",
            "created-event",
            "worktree-event",
            "started-session",
            "created-event",
            "attention-event",
        ]
        let controller = MissionController(environment: fake.environment)

        let id = try await controller.create(Self.draft, allowDuplicate: false)
        let failed = await fake.waitUntilSettled(id)
        #expect(failed.primaryLeg?.pendingInitialPrompt == nil)

        await controller.retry(id, agentId: "claude")
        let recovered = try #require(try await fake.persistence.aggregate(id: id))

        #expect(fake.startACPCalls == 2)
        #expect(fake.startedAgentIDs == ["codex", "claude"])
        #expect(fake.startedPromptIDs == [Self.draft.initialPromptId, Self.draft.initialPromptId])
        #expect(fake.startedPrompts.last == Self.draft.initialPrompt)
        #expect(recovered.primaryLeg?.agentId == "claude")
        #expect(recovered.primaryLeg?.acpSessionId != "started-session")
        #expect(recovered.primaryLeg?.pendingInitialPrompt == nil)
        #expect(recovered.mission.state == .running)
    }

    @Test("agent replacement targets a secondary leg")
    func agentReplacementTargetsSecondaryLeg() async throws {
        let fake = MissionCoordinatorFake()
        let coordinator = MissionCoordinator(environment: fake.environment)
        let controller = MissionController(environment: fake.environment)
        let missionID = try await coordinator.create(Self.primaryDraft)
        _ = await fake.waitUntilSettled(missionID)

        fake.agentResult = .failure(.init(message: "Install Codex"))
        let sdkLegID = try await coordinator.addLeg(missionID: missionID, draft: Self.sdkDraft)
        let failed = await fake.waitUntilLegsSettled(missionID, count: 1)
        let failedLeg = try #require(failed.legs.first(where: { $0.id == sdkLegID }))
        #expect(failedLeg.state == .needsAttention)
        #expect(failedLeg.agentId == "codex")
        let failedSessionID = failedLeg.acpSessionId

        fake.agentResult = nil
        await controller.retry(missionID, legID: sdkLegID, agentId: "claude")
        let recovered = await fake.waitUntilLegsSettled(missionID, count: 1)
        let recoveredLeg = try #require(recovered.legs.first(where: { $0.id == sdkLegID }))

        #expect(Array(fake.startedAgentIDs.suffix(2)) == ["codex", "claude"])
        #expect(fake.startedPrompts.last == Self.sdkDraft.preparedPrompt)
        #expect(recoveredLeg.state == .running)
        #expect(recoveredLeg.agentId == "claude")
        #expect(recoveredLeg.acpSessionId != failedSessionID)
    }

    @Test("available worktree recovery targets a secondary leg")
    func availableWorktreeRecoveryTargetsSecondaryLeg() async throws {
        let fake = MissionCoordinatorFake()
        let coordinator = MissionCoordinator(environment: fake.environment)
        let controller = MissionController(environment: fake.environment)
        let missionID = try await coordinator.create(Self.primaryDraft)
        _ = await fake.waitUntilSettled(missionID)
        let sdkLegID = try await coordinator.addLeg(missionID: missionID, draft: Self.sdkDraft)
        _ = await fake.waitUntilLegsSettled(missionID, count: 1)
        let startCount = fake.startACPCalls

        await controller.recordMissingWorktree(missionID, legID: sdkLegID)
        let marked = try #require(try await fake.persistence.aggregate(id: missionID))
        let markedLeg = try #require(marked.legs.first(where: { $0.id == sdkLegID }))
        #expect(markedLeg.state == .needsAttention)
        #expect(markedLeg.pendingInitialPrompt != nil)

        await controller.recordAvailableWorktree(missionID, legID: sdkLegID)
        let recovered = await fake.waitUntilLegsSettled(missionID, count: 1)
        let recoveredLeg = try #require(recovered.legs.first(where: { $0.id == sdkLegID }))
        let primaryLeg = try #require(recovered.primaryLeg)

        #expect(fake.startACPCalls == startCount + 1)
        #expect(fake.startedPrompts.last == Self.sdkDraft.preparedPrompt)
        #expect(recoveredLeg.state == .running)
        #expect(recoveredLeg.pendingInitialPrompt == nil)
        #expect(primaryLeg.state == .running)
    }

    @Test("restart reuses the recorded worktree at the Mission destination")
    func interruptedWorktreeReusesRecordedDestinationArtifact() async throws {
        var existing = MissionFixtures.creatingMission()
        existing.legs[0].worktreeId = "worktree-1"
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

    @Test("restart does not recover a worktree without durable lineage")
    func interruptedWorktreeRejectsLineageLessDestinationArtifact() async throws {
        var existing = MissionFixtures.creatingMission()
        existing.mission.state = .needsAttention
        existing.mission.attentionReason = "Git response was lost."
        existing.legs[0].worktreeId = "worktree-1"
        let fake = MissionCoordinatorFake(existing: [existing])
        fake.worktree.lineageID = nil
        fake.worktreeAtDestination = fake.worktree
        let coordinator = MissionCoordinator(environment: fake.environment)

        await coordinator.reconcileInterrupted()
        let reconciled = try #require(try await fake.persistence.aggregate(id: existing.mission.id))

        #expect(reconciled.mission.setupCheckpoint == .creatingWorktree)
        #expect(reconciled.primaryLeg?.worktreeLineageID == nil)

        await coordinator.retry(id: existing.mission.id)
        let retried = await fake.waitUntilSettled(existing.mission.id)

        #expect(fake.startACPCalls == 0)
        #expect(retried.mission.state == .running)
        #expect(retried.mission.setupCheckpoint == .creatingWorktree)
        #expect(retried.mission.attentionReason == "Could not establish a durable identity for the Mission worktree. Retry this Mission.")
        #expect(retried.primaryLeg?.worktreeLineageID == nil)
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
        existing.legs[0].worktreeId = "worktree-1"
        let fake = MissionCoordinatorFake(existing: [existing])
        fake.worktreeAtDestination = fake.worktree
        let coordinator = MissionCoordinator(environment: fake.environment)

        await coordinator.reconcileInterrupted()
        let aggregate = try #require(try await fake.persistence.aggregate(id: existing.mission.id))

        #expect(fake.createWorktreeCalls == 0)
        #expect(fake.startACPCalls == 0)
        #expect(aggregate.primaryLeg?.worktreeId == fake.worktree.id)
        #expect(aggregate.mission.state == .running)
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
            NotificationSnapshot(state: .creating, checkpoint: .creatingWorktree, hasWorktree: false, hasSession: false, clearedPrompt: false),
            NotificationSnapshot(state: .creating, checkpoint: .creatingWorktree, hasWorktree: true, hasSession: false, clearedPrompt: false),
            NotificationSnapshot(state: .creating, checkpoint: .startingAgent, hasWorktree: true, hasSession: false, clearedPrompt: false),
            NotificationSnapshot(state: .creating, checkpoint: .startingAgent, hasWorktree: true, hasSession: true, clearedPrompt: false),
            NotificationSnapshot(state: .running, checkpoint: .running, hasWorktree: true, hasSession: true, clearedPrompt: true),
        ])
    }
}

private struct NotificationSnapshot: Equatable {
    let state: MissionState
    let checkpoint: MissionSetupCheckpoint
    let hasWorktree: Bool
    let hasSession: Bool
    let clearedPrompt: Bool

    init(_ aggregate: MissionAggregate) {
        state = aggregate.mission.state
        checkpoint = aggregate.mission.setupCheckpoint
        hasWorktree = aggregate.primaryLeg?.worktreeId != nil
        hasSession = aggregate.primaryLeg?.acpSessionId != nil
        clearedPrompt = aggregate.primaryLeg?.pendingInitialPrompt == nil
    }

    init(
        state: MissionState,
        checkpoint: MissionSetupCheckpoint,
        hasWorktree: Bool,
        hasSession: Bool,
        clearedPrompt: Bool
    ) {
        self.state = state
        self.checkpoint = checkpoint
        self.hasWorktree = hasWorktree
        self.hasSession = hasSession
        self.clearedPrompt = clearedPrompt
    }
}

@MainActor
private final class MissionCoordinatorFake {
    let persistence: MissionPersistence
    private let store: MissionStore
    var worktree = Worktree(
        id: "worktree-1",
        projectId: "project-1",
        name: "fix/parser-crash",
        branch: "fix/parser-crash",
        path: URL(fileURLWithPath: "/tmp/alas-mission"),
        status: .clean,
        lastActivity: Date(timeIntervalSince1970: 100),
        lineageID: "lineage-1"
    )

    var worktreeResult: Result<Worktree, WorktreeCreationFailure>
    var worktreeResultsByLegID: [MissionLegID: Result<Worktree, WorktreeCreationFailure>] = [:]
    var agentResult: Result<ACPSession.ID, MissionCoordinator.MissionOperationFailure>?
    var worktreeAtDestination: Worktree?
    var startACPOverride: ((MissionLeg, Worktree) async -> Result<ACPSession.ID, MissionCoordinator.MissionOperationFailure>)?
    var aggregateObservedWhenGitStarted = false
    private(set) var missionWasDurableWhenGitStarted = false
    private(set) var worktreeReservationWasDurableWhenGitStarted = false
    private(set) var createWorktreeCalls = 0
    private(set) var startACPCalls = 0
    private(set) var startedSessionIDs: [String] = []
    private(set) var startedPromptIDs: [UUID] = []
    private(set) var startedPrompts: [String] = []
    private(set) var startedAgentIDs: [String] = []
    private(set) var startedLegIDs: [MissionLegID] = []
    private(set) var operations: [String] = []
    private(set) var notifications: [MissionAggregate] = []
    private(set) var reportedFailures: [(MissionID?, String)] = []

    private var idCounter = 0
    private var clock: TimeInterval = 1_000
    private let suspendWorktreeCreation: Bool
    private let suspendACPStartup: Bool
    private let completeWhenSessionReserved: Bool
    private var startedLegs: [MissionLegID: MissionLeg] = [:]
    private var worktreeCreationContinuations: [
        MissionLegID: CheckedContinuation<Result<Worktree, WorktreeCreationFailure>, Never>
    ] = [:]
    private var acpStartupContinuations: [
        MissionLegID: CheckedContinuation<
            Result<ACPSession.ID, MissionCoordinator.MissionOperationFailure>,
            Never
        >
    ] = [:]
    var idValues: [String] = []

    init(
        existing: [MissionAggregate] = [],
        worktreeResult: Result<Worktree, WorktreeCreationFailure>? = nil,
        agentResult: Result<ACPSession.ID, MissionCoordinator.MissionOperationFailure>? = nil,
        suspendWorktreeCreation: Bool = false,
        suspendACPStartup: Bool = false,
        completeWhenSessionReserved: Bool = false
    ) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mission-coordinator-\(UUID().uuidString).sqlite")
            .path
        let store = try! MissionStore(path: path)
        for aggregate in existing {
            try! store.insert(aggregate)
        }
        persistence = MissionPersistence(path: path)
        self.store = store
        self.worktreeResult = worktreeResult ?? .success(worktree)
        self.agentResult = agentResult
        self.suspendWorktreeCreation = suspendWorktreeCreation
        self.suspendACPStartup = suspendACPStartup
        self.completeWhenSessionReserved = completeWhenSessionReserved
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
                if !self.idValues.isEmpty {
                    return self.idValues.removeFirst()
                }
                self.idCounter += 1
                return "id-\(self.idCounter)"
            },
            plannedWorktreeID: { [weak self] leg in
                guard let self else { return .failure(.init(message: "Fake released")) }
                return .success(self.worktree(for: leg).id)
            },
            worktreeAtDestination: { [weak self] projectID, path in
                guard let self else { return nil }
                if projectID == self.worktree.projectId,
                   URL(fileURLWithPath: path).standardizedFileURL.path == self.worktree.path.standardizedFileURL.path {
                    return self.worktreeAtDestination
                }
                return self.createdWorktrees.first { worktree in
                    worktree.projectId == projectID
                        && worktree.path.standardizedFileURL.path
                            == URL(fileURLWithPath: path).standardizedFileURL.path
                }
            },
            createWorktree: { [weak self] leg in
                guard let self else { return .failure(.init(message: "Fake released")) }
                self.createWorktreeCalls += 1
                self.startedLegIDs.append(leg.id)
                self.startedLegs[leg.id] = leg
                self.operations.append("createWorktree")
                if self.aggregateObservedWhenGitStarted {
                    let aggregate = try? await self.persistence.aggregate(id: leg.missionID)
                    self.missionWasDurableWhenGitStarted = aggregate != nil
                    self.worktreeReservationWasDurableWhenGitStarted = aggregate?.legs.first(where: { $0.id == leg.id })?.worktreeId == self.worktree(for: leg).id
                }
                let result = self.worktreeResult(for: leg)
                if self.suspendWorktreeCreation {
                    return await withCheckedContinuation { continuation in
                        self.worktreeCreationContinuations[leg.id] = continuation
                    }
                }
                self.recordCreatedWorktree(result)
                return result
            },
            startACP: { [weak self] leg, _ in
                guard let self else {
                    return .failure(.init(message: "Fake released"))
                }
                self.startACPCalls += 1
                self.operations.append("startACP")
                self.startedAgentIDs.append(leg.agentId)
                self.startedSessionIDs.append(leg.acpSessionId ?? "")
                if let prompt = leg.pendingInitialPrompt {
                    self.startedPromptIDs.append(leg.initialPromptId)
                    self.startedPrompts.append(prompt)
                }
                if self.suspendACPStartup {
                    return await withCheckedContinuation { continuation in
                        self.acpStartupContinuations[leg.id] = continuation
                    }
                }
                if let startACPOverride = self.startACPOverride {
                    return await startACPOverride(leg, self.worktree)
                }
                return self.agentResult ?? .success(leg.acpSessionId ?? "")
            },
            notifyChanged: { [weak self] aggregate in
                guard let self else { return }
                self.notifications.append(aggregate)
                if self.completeWhenSessionReserved,
                   aggregate.primaryLeg?.acpSessionId != nil,
                   aggregate.mission.state != .completed {
                    let now = self.clockDate()
                    try! self.store.complete(
                        id: aggregate.mission.id,
                        at: now,
                        event: MissionFixtures.event(
                            id: "completed-after-session-reservation",
                            missionID: aggregate.mission.id,
                            legID: aggregate.primaryLeg?.id,
                            kind: .completed,
                            createdAt: now.timeIntervalSince1970
                        )
                    )
                }
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
            },
            reportFailure: { [weak self] id, message in
                self?.reportedFailures.append((id, message))
            }
        )
    }

    private func clockDate() -> Date {
        clock += 1
        return Date(timeIntervalSince1970: clock)
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

    func waitForWorktreeStarts(count: Int) async {
        for _ in 0..<200 {
            if startedLegIDs.count >= count { return }
            await Task.yield()
        }
    }

    func waitForACPStarts(count: Int) async {
        for _ in 0..<200 {
            if startACPCalls >= count { return }
            await Task.yield()
        }
    }

    func clearStartedLegIDs() {
        startedLegIDs = []
    }

    func resumeWorktreeCreation(for legID: MissionLegID) async {
        guard let continuation = worktreeCreationContinuations.removeValue(forKey: legID) else { return }
        let result = worktreeResult(for: legID)
        recordCreatedWorktree(result)
        continuation.resume(returning: result)
    }

    func resumeACPStartup(for legID: MissionLegID) async {
        guard let continuation = acpStartupContinuations.removeValue(forKey: legID) else { return }
        continuation.resume(returning: agentResult ?? .success("session-\(legID.rawValue)"))
    }

    func waitUntilLegsSettled(_ id: MissionID, count: Int) async -> MissionAggregate {
        for _ in 0..<200 {
            if let aggregate = try? await persistence.aggregate(id: id),
               aggregate.legs.count >= count + 1,
               aggregate.legs.filter({ $0.ordinal > 0 }).allSatisfy({ $0.state != .creating }) {
                return aggregate
            }
            await Task.yield()
        }
        return try! await persistence.aggregate(id: id)!
    }

    private var createdWorktrees: [Worktree] = []

    private func worktree(for leg: MissionLeg) -> Worktree {
        if leg.projectId == worktree.projectId,
           URL(fileURLWithPath: leg.destinationPath).standardizedFileURL.path
                == worktree.path.standardizedFileURL.path {
            return worktree
        }
        return Worktree(
            id: "worktree-\(leg.id.rawValue)",
            projectId: leg.projectId,
            name: leg.branch,
            branch: leg.branch,
            path: URL(fileURLWithPath: leg.destinationPath),
            status: .clean,
            lastActivity: .now,
            lineageID: "lineage-\(leg.id.rawValue)"
        )
    }

    private func worktreeResult(for leg: MissionLeg) -> Result<Worktree, WorktreeCreationFailure> {
        if let result = worktreeResultsByLegID[leg.id] { return result }
        if leg.projectId == worktree.projectId,
           URL(fileURLWithPath: leg.destinationPath).standardizedFileURL.path
                == worktree.path.standardizedFileURL.path {
            return worktreeResult
        }
        switch worktreeResult {
        case .failure(let failure):
            return .failure(failure)
        case .success:
            return .success(worktree(for: leg))
        }
    }

    private func worktreeResult(for legID: MissionLegID) -> Result<Worktree, WorktreeCreationFailure> {
        guard let leg = startedLegs[legID] else {
            return worktreeResultsByLegID[legID] ?? worktreeResult
        }
        return worktreeResult(for: leg)
    }

    private func recordCreatedWorktree(_ result: Result<Worktree, WorktreeCreationFailure>) {
        if case .success(let worktree) = result {
            if worktree.projectId == self.worktree.projectId,
               worktree.path.standardizedFileURL.path == self.worktree.path.standardizedFileURL.path {
                worktreeAtDestination = worktree
            } else {
                createdWorktrees.removeAll { $0.id == worktree.id }
                createdWorktrees.append(worktree)
            }
        }
    }
}

private struct MissionProjectStore: PersistenceStoreProtocol {
    let projects: [ProjectConfig]

    func write<T: Encodable>(_: T, to _: URL) throws {}

    func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? {
        T.self == ProjectsFile.self ? ProjectsFile(projects: projects) as? T : nil
    }
}
