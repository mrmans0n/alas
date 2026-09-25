import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP session orchestration coordinator")
struct ACPSessionOrchestrationCoordinatorTests {
    @Test("pending delegated message delivery suppresses a parent completion before queue insertion")
    func pendingMessageDeliveryBlocksNextPromptOpportunity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = ACPOrchestrationPersistence(path: root.appendingPathComponent("delegations.sqlite").path)
        let manager = ACPSessionManager(worktreeId: "w", worktreePath: root.path,
            store: try ACPSessionStore(path: root.appendingPathComponent("sessions.sqlite").path),
            setupEvaluator: { _ in .missing(reason: "Test delivery remains local") })
        defer { manager.shutdownBackgroundTasks() }
        let parent = manager.createSession(id: "parent", agentId: "codex", autoRunDefault: false)
        _ = manager.createSession(id: "child", agentId: "codex", autoRunDefault: false)
        await manager.flushPersistence()
        parent.agentState = .ready
        let userID = parent.recordUserPrompt(text: "Explain the parser.", attachments: [])
        parent.transcript.appendMessage(.agent(id: UUID(), StreamingText("It reads tokens.")))
        let turn = NextPromptCompletedTurn(sessionID: parent.id, incarnation: parent.incarnation,
            promptID: parent.allocatePromptID(), userMessageID: userID,
            transcriptRevision: parent.transcript.messagesGeneration)
        var facts = NextPromptEligibilitySnapshot.Environment()
        facts.isEnabled = true
        facts.hasVerifiedModel = true
        facts.isRuntimeAvailable = true
        facts.isAppActive = true
        facts.isActiveVisibleWriter = true
        facts.hasComposerFocus = true
        let environment = facts
        #expect(NextPromptEligibilitySnapshot.live(session: parent, turn: turn, environment: environment) != nil)
        try await persistence.insert(.init(childSessionId: "child", parentSessionId: "parent", projectId: "p",
            parentWorktreeId: "w", childWorktreeId: "w", agentId: "codex", worktreeRequest: .current(worktreeId: "w"),
            phase: .ready, failureMessage: nil, createdAt: 1, updatedAt: 1))
        var observedPendingDelivery = false
        let coordinator = ACPSessionOrchestrationCoordinator(environment: .init(
            persistence: persistence, instanceId: "test", now: { 2 }, makeID: { UUID().uuidString },
            worktree: { _ in nil }, existingWorktree: { _, _ in nil }, configuredAgents: { [] },
            availableAgents: { _, _ in [] }, sessionLocation: { id in
                guard manager.liveSession(for: id) != nil else { return nil }
                return .init(origin: .init(sessionId: id, projectId: "p", worktreeId: "w"), manager: manager)
            }, manager: { _ in manager }, newWorktreeDestination: { _, _ in nil },
            createWorktree: { _, _, _ in .failure(.init(message: "unused")) }, rememberParent: { _, _ in },
            autoRunDefault: { false }, notifyChanged: {
                observedPendingDelivery = true
                #expect(parent.queue.isEmpty)
                #expect(parent.nextPromptWorkCount > 0)
                #expect(parent.hasPendingDelegatedMessages)
                #expect(NextPromptEligibilitySnapshot.live(session: parent, turn: turn, environment: environment) == nil)
            }))
        let response = await coordinator.send(origin: .init(sessionId: "child", projectId: "p", worktreeId: "w"),
                                              request: .init(targetSessionId: "parent", prompt: "Check the edge case."))
        guard case .text = response else {
            Issue.record("Expected queued delegated message")
            return
        }
        #expect(observedPendingDelivery)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while parent.nextPromptWorkCount != 0 {
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
        #expect(parent.hasPendingDelegatedMessages)
    }

    @Test("child remains failed when initial attach needs setup")
    func childStartPersistsAttachSetupFailure() async throws {
        let orchestrationPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-coordinator-\(UUID().uuidString).sqlite")
            .path
        let sessionPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-coordinator-session-\(UUID().uuidString).sqlite")
            .path
        let persistence = ACPOrchestrationPersistence(path: orchestrationPath)
        let sessionStore = try ACPSessionStore(path: sessionPath)
        let manager = ACPSessionManager(
            worktreeId: "worktree",
            worktreePath: "/tmp/worktree",
            store: sessionStore,
            setupEvaluator: { _ in .missing(reason: "Install Codex") }
        )
        _ = manager.createSession(id: "parent", agentId: "codex", autoRunDefault: false)
        let worktree = Worktree(
            id: "worktree",
            projectId: "project",
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/worktree"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        var now = 100
        let coordinator = ACPSessionOrchestrationCoordinator(environment: .init(
            persistence: persistence,
            instanceId: "instance",
            now: {
                now += 1
                return Int64(now)
            },
            makeID: { "child" },
            worktree: { $0 == worktree.id ? worktree : nil },
            existingWorktree: { _, _ in nil },
            configuredAgents: {
                [ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true)]
            },
            availableAgents: { _, _ in
                [ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true)]
            },
            sessionLocation: { sessionId in
                sessionId == "parent"
                    ? .init(origin: .init(sessionId: "parent", projectId: "project", worktreeId: "worktree"), manager: manager)
                    : nil
            },
            manager: { _ in manager },
            newWorktreeDestination: { _, _ in nil },
            createWorktree: { _, _, _ in .failure(.init(message: "unused")) },
            rememberParent: { _, _ in },
            autoRunDefault: { false },
            notifyChanged: {}
        ))

        let response = await coordinator.create(
            origin: .init(sessionId: "parent", projectId: "project", worktreeId: "worktree"),
            request: .init(prompt: "Investigate the parser.", agentId: nil, worktree: .current)
        )

        guard case .text = response else {
            Issue.record("Expected delegated session creation response")
            return
        }
        let record = try await eventuallyLoadDelegation(
            persistence: persistence,
            childSessionId: "child",
            matching: { $0.phase == .failed }
        )
        #expect(record.failureMessage == "Install Codex")
        #expect(record.pendingInitialPrompt == "Investigate the parser.")
    }

    @Test("delegated creation failure is persisted without starting the child")
    func delegatedCreationFailurePersistsMessage() async throws {
        let orchestrationPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-coordinator-\(UUID().uuidString).sqlite")
            .path
        let sessionPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-coordinator-session-\(UUID().uuidString).sqlite")
            .path
        let persistence = ACPOrchestrationPersistence(path: orchestrationPath)
        let sessionStore = try ACPSessionStore(path: sessionPath)
        let manager = ACPSessionManager(
            worktreeId: "worktree",
            worktreePath: "/tmp/worktree",
            store: sessionStore,
            setupEvaluator: { _ in .ready }
        )
        _ = manager.createSession(id: "parent", agentId: "codex", autoRunDefault: false)
        let worktree = Worktree(
            id: "worktree",
            projectId: "project",
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/worktree"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let coordinator = ACPSessionOrchestrationCoordinator(environment: .init(
            persistence: persistence,
            instanceId: "instance",
            now: { 100 },
            makeID: { "child" },
            worktree: { $0 == worktree.id ? worktree : nil },
            existingWorktree: { _, _ in nil },
            configuredAgents: {
                [ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true)]
            },
            availableAgents: { _, _ in
                [ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true)]
            },
            sessionLocation: { sessionId in
                sessionId == "parent"
                    ? .init(origin: .init(sessionId: "parent", projectId: "project", worktreeId: "worktree"), manager: manager)
                    : nil
            },
            manager: { _ in manager },
            newWorktreeDestination: { _, _ in URL(fileURLWithPath: "/tmp/feature") },
            createWorktree: { _, _, _ in .failure(.init(message: "branch exists")) },
            rememberParent: { _, _ in },
            autoRunDefault: { false },
            notifyChanged: {}
        ))

        let response = await coordinator.create(
            origin: .init(sessionId: "parent", projectId: "project", worktreeId: "worktree"),
            request: .init(prompt: "Investigate the parser.", agentId: nil, worktree: .new(branch: "feature", base: "main"))
        )

        guard case .text = response else {
            Issue.record("Expected delegated session creation response")
            return
        }
        let record = try await eventuallyLoadDelegation(
            persistence: persistence,
            childSessionId: "child",
            matching: { $0.phase == .failed }
        )
        #expect(record.failureMessage == "branch exists")
        #expect(record.pendingInitialPrompt == "Investigate the parser.")
    }

    @Test("delegated new worktree rejects invalid agents before creation")
    func delegatedNewWorktreeRejectsInvalidAgentBeforeCreation() async throws {
        let orchestrationPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-coordinator-\(UUID().uuidString).sqlite")
            .path
        let sessionPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-coordinator-session-\(UUID().uuidString).sqlite")
            .path
        let persistence = ACPOrchestrationPersistence(path: orchestrationPath)
        let sessionStore = try ACPSessionStore(path: sessionPath)
        let manager = ACPSessionManager(
            worktreeId: "worktree",
            worktreePath: "/tmp/worktree",
            store: sessionStore,
            setupEvaluator: { _ in .ready }
        )
        _ = manager.createSession(id: "parent", agentId: "codex", autoRunDefault: false)
        let worktree = Worktree(
            id: "worktree",
            projectId: "project",
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/worktree"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        var didCreateWorktree = false
        let coordinator = ACPSessionOrchestrationCoordinator(environment: .init(
            persistence: persistence,
            instanceId: "instance",
            now: { 100 },
            makeID: { "child" },
            worktree: { $0 == worktree.id ? worktree : nil },
            existingWorktree: { _, _ in nil },
            configuredAgents: {
                [ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true)]
            },
            availableAgents: { _, _ in
                [ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true)]
            },
            sessionLocation: { sessionId in
                sessionId == "parent"
                    ? .init(origin: .init(sessionId: "parent", projectId: "project", worktreeId: "worktree"), manager: manager)
                    : nil
            },
            manager: { _ in manager },
            newWorktreeDestination: { _, _ in URL(fileURLWithPath: "/tmp/feature") },
            createWorktree: { _, _, _ in
                didCreateWorktree = true
                return .failure(.init(message: "unused"))
            },
            rememberParent: { _, _ in },
            autoRunDefault: { false },
            notifyChanged: {}
        ))

        let response = await coordinator.create(
            origin: .init(sessionId: "parent", projectId: "project", worktreeId: "worktree"),
            request: .init(prompt: "Investigate the parser.", agentId: "codxe", worktree: .new(branch: "feature", base: "main"))
        )

        guard case .error(let message) = response else {
            Issue.record("Expected invalid agent to be rejected")
            return
        }
        #expect(message == "Agent is not enabled or ACP-capable: codxe")
        #expect(!didCreateWorktree)
        #expect(try await persistence.delegation(childSessionId: "child") == nil)
    }

    @Test("delegated creation awaits agent availability before validation")
    func delegatedCreationAwaitsAgentAvailabilityBeforeValidation() async throws {
        let orchestrationPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-coordinator-\(UUID().uuidString).sqlite")
            .path
        let sessionPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-coordinator-session-\(UUID().uuidString).sqlite")
            .path
        let persistence = ACPOrchestrationPersistence(path: orchestrationPath)
        let sessionStore = try ACPSessionStore(path: sessionPath)
        let manager = ACPSessionManager(
            worktreeId: "worktree",
            worktreePath: "/tmp/worktree",
            store: sessionStore,
            setupEvaluator: { _ in .ready }
        )
        _ = manager.createSession(id: "parent", agentId: "codex", autoRunDefault: false)
        let worktree = Worktree(
            id: "worktree",
            projectId: "project",
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/worktree"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        var didLoadAgents = false
        let coordinator = ACPSessionOrchestrationCoordinator(environment: .init(
            persistence: persistence,
            instanceId: "instance",
            now: { 100 },
            makeID: { "child" },
            worktree: { $0 == worktree.id ? worktree : nil },
            existingWorktree: { _, _ in nil },
            configuredAgents: {
                [ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true)]
            },
            availableAgents: { _, _ in
                didLoadAgents = true
                return [ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true)]
            },
            sessionLocation: { sessionId in
                sessionId == "parent"
                    ? .init(origin: .init(sessionId: "parent", projectId: "project", worktreeId: "worktree"), manager: manager)
                    : nil
            },
            manager: { _ in manager },
            newWorktreeDestination: { _, _ in nil },
            createWorktree: { _, _, _ in .failure(.init(message: "unused")) },
            rememberParent: { _, _ in },
            autoRunDefault: { false },
            notifyChanged: {}
        ))

        let response = await coordinator.create(
            origin: .init(sessionId: "parent", projectId: "project", worktreeId: "worktree"),
            request: .init(prompt: "Investigate the parser.", agentId: nil, worktree: .current)
        )

        guard case .text = response else {
            Issue.record("Expected delegated session creation response")
            return
        }
        #expect(didLoadAgents)
    }

    @Test("delegated existing worktree validates agents against the destination")
    func delegatedExistingWorktreeUsesDestinationAgentAvailability() async throws {
        let orchestrationPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-coordinator-\(UUID().uuidString).sqlite")
            .path
        let sessionPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-coordinator-session-\(UUID().uuidString).sqlite")
            .path
        let persistence = ACPOrchestrationPersistence(path: orchestrationPath)
        let sessionStore = try ACPSessionStore(path: sessionPath)
        let manager = ACPSessionManager(
            worktreeId: "origin",
            worktreePath: "/tmp/origin",
            store: sessionStore,
            setupEvaluator: { _ in .ready }
        )
        _ = manager.createSession(id: "parent", agentId: "codex", autoRunDefault: false)
        let origin = Worktree(
            id: "origin",
            projectId: "project",
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/origin"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let destination = Worktree(
            id: "feature",
            projectId: "project",
            name: "feature",
            branch: "feature",
            path: URL(fileURLWithPath: "/tmp/feature"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        var checkedWorktreeIDs: [String] = []
        let coordinator = ACPSessionOrchestrationCoordinator(environment: .init(
            persistence: persistence,
            instanceId: "instance",
            now: { 100 },
            makeID: { "child" },
            worktree: { $0 == origin.id ? origin : nil },
            existingWorktree: { _, id in id == destination.id ? destination : nil },
            configuredAgents: {
                [ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true)]
            },
            availableAgents: { _, worktree in
                checkedWorktreeIDs.append(worktree.id)
                if worktree.id == destination.id {
                    return [ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true)]
                }
                return []
            },
            sessionLocation: { sessionId in
                sessionId == "parent"
                    ? .init(origin: .init(sessionId: "parent", projectId: "project", worktreeId: origin.id), manager: manager)
                    : nil
            },
            manager: { worktree in worktree.id == destination.id ? manager : nil },
            newWorktreeDestination: { _, _ in nil },
            createWorktree: { _, _, _ in .failure(.init(message: "unused")) },
            rememberParent: { _, _ in },
            autoRunDefault: { false },
            notifyChanged: {}
        ))

        let response = await coordinator.create(
            origin: .init(sessionId: "parent", projectId: "project", worktreeId: origin.id),
            request: .init(prompt: "Investigate the parser.", agentId: nil, worktree: .existing(worktreeId: destination.id))
        )

        guard case .text = response else {
            Issue.record("Expected delegated session creation response")
            return
        }
        #expect(checkedWorktreeIDs.first == destination.id)
        #expect(checkedWorktreeIDs.contains(origin.id) == false)
    }

    @Test("persisted child start does not require live parent")
    func persistedChildStartUsesSavedAgentWhenParentClosed() async throws {
        let orchestrationPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-coordinator-\(UUID().uuidString).sqlite")
            .path
        let sessionPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-coordinator-session-\(UUID().uuidString).sqlite")
            .path
        let persistence = ACPOrchestrationPersistence(path: orchestrationPath)
        let sessionStore = try ACPSessionStore(path: sessionPath)
        let manager = ACPSessionManager(
            worktreeId: "worktree",
            worktreePath: "/tmp/worktree",
            store: sessionStore,
            setupEvaluator: { _ in .missing(reason: "Install Codex") }
        )
        _ = manager.createSession(id: "parent", agentId: "codex", autoRunDefault: false)
        let worktree = Worktree(
            id: "worktree",
            projectId: "project",
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/worktree"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        var sessionLocationCalls = 0
        let coordinator = ACPSessionOrchestrationCoordinator(environment: .init(
            persistence: persistence,
            instanceId: "instance",
            now: { 100 },
            makeID: { "child" },
            worktree: { $0 == worktree.id ? worktree : nil },
            existingWorktree: { _, _ in nil },
            configuredAgents: {
                [ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true)]
            },
            availableAgents: { _, destination in
                destination.id == worktree.id
                    ? [ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true)]
                    : []
            },
            sessionLocation: { sessionId in
                sessionLocationCalls += 1
                guard sessionLocationCalls == 1, sessionId == "parent" else { return nil }
                return .init(
                    origin: .init(sessionId: "parent", projectId: "project", worktreeId: worktree.id),
                    manager: manager
                )
            },
            manager: { _ in manager },
            newWorktreeDestination: { _, _ in nil },
            createWorktree: { _, _, _ in .failure(.init(message: "unused")) },
            rememberParent: { _, _ in },
            autoRunDefault: { false },
            notifyChanged: {}
        ))

        let response = await coordinator.create(
            origin: .init(sessionId: "parent", projectId: "project", worktreeId: worktree.id),
            request: .init(prompt: "Investigate the parser.", agentId: nil, worktree: .current)
        )

        guard case .text = response else {
            Issue.record("Expected delegated session creation response")
            return
        }
        let record = try await eventuallyLoadDelegation(
            persistence: persistence,
            childSessionId: "child",
            matching: { $0.phase == .failed }
        )
        #expect(record.failureMessage == "Install Codex")
        #expect(manager.liveSession(for: "child")?.agentId == "codex")
    }

    private struct OutcomeFixture {
        let coordinator: ACPSessionOrchestrationCoordinator
        let persistence: ACPOrchestrationPersistence
        let manager: ACPSessionManager
    }

    /// A parent session that exists but cannot attach (missing agent), so
    /// delivery leaves rows pending and unclaimed for inspection.
    private func makeOutcomeFixture(parentReachable: Bool = true) throws -> OutcomeFixture {
        let orchestrationPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-outcome-\(UUID().uuidString).sqlite").path
        let sessionPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-outcome-session-\(UUID().uuidString).sqlite").path
        let persistence = ACPOrchestrationPersistence(path: orchestrationPath)
        let manager = ACPSessionManager(
            worktreeId: "worktree",
            worktreePath: "/tmp/worktree",
            store: try ACPSessionStore(path: sessionPath),
            setupEvaluator: { _ in .missing(reason: "Install Codex") }
        )
        _ = manager.createSession(id: "parent", agentId: "codex", autoRunDefault: false)
        let worktree = Worktree(
            id: "worktree", projectId: "project", name: "feature-x", branch: "feature-x",
            path: URL(fileURLWithPath: "/tmp/worktree"), status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let coordinator = ACPSessionOrchestrationCoordinator(environment: .init(
            persistence: persistence,
            instanceId: "instance",
            now: { 900 },
            makeID: { UUID().uuidString },
            worktree: { parentReachable && $0 == worktree.id ? worktree : nil },
            existingWorktree: { _, _ in nil },
            configuredAgents: { [ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true)] },
            availableAgents: { _, _ in [ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true)] },
            sessionLocation: { sessionId in
                parentReachable && sessionId == "parent"
                    ? .init(origin: .init(sessionId: "parent", projectId: "project", worktreeId: "worktree"), manager: manager)
                    : nil
            },
            manager: { _ in parentReachable ? manager : nil },
            newWorktreeDestination: { _, _ in nil },
            createWorktree: { _, _, _ in .failure(.init(message: "unused")) },
            rememberParent: { _, _ in },
            autoRunDefault: { false },
            notifyChanged: {}
        ))
        return .init(coordinator: coordinator, persistence: persistence, manager: manager)
    }

    private func insertReadyChild(_ persistence: ACPOrchestrationPersistence) async throws {
        try await persistence.insert(.init(
            childSessionId: "child", parentSessionId: "parent", projectId: "project",
            parentWorktreeId: "worktree", childWorktreeId: "worktree", agentId: "codex",
            worktreeRequest: .current(worktreeId: "worktree"), pendingInitialPrompt: nil,
            phase: .ready, failureMessage: nil, createdAt: 100, updatedAt: 100
        ))
    }

    private func completion(
        result: ACPTurnCompletion.Result = .completed,
        startedAt: Int64 = 500,
        lastAgentText: String? = "Parser fixed."
    ) -> ACPTurnCompletion {
        .init(sessionId: "child", startedAt: startedAt, result: result,
              delegatedSource: nil, lastAgentText: lastAgentText)
    }

    @Test("unreported child completion wakes the parent")
    func unreportedCompletionWakesParent() async throws {
        let fixture = try makeOutcomeFixture()
        try await insertReadyChild(fixture.persistence)

        await fixture.coordinator.childTurnCompleted(completion())

        let pending = try await fixture.persistence.pendingMessages(targetSessionId: "parent")
        #expect(pending.count == 1)
        #expect(pending.first?.id == "outcome-child-500")
        #expect(pending.first?.kind == .prompt)
        #expect(pending.first?.sourceSessionId == "child")
        #expect(pending.first?.prompt.contains("finished its turn without sending a result") == true)
        #expect(pending.first?.prompt.contains("Parser fixed.") == true)
        #expect(pending.first?.prompt.contains("worktree feature-x") == true)
    }

    @Test("reported child completion only notices the parent")
    func reportedCompletionNotices() async throws {
        let fixture = try makeOutcomeFixture()
        try await insertReadyChild(fixture.persistence)
        try await fixture.persistence.markParentReport(childSessionId: "child", at: 600)

        await fixture.coordinator.childTurnCompleted(completion(startedAt: 500))

        let pending = try await fixture.persistence.pendingMessages(targetSessionId: "parent")
        #expect(pending.count == 1)
        #expect(pending.first?.kind == .notice)
        #expect(pending.first?.prompt == "Delegated session child (codex, worktree feature-x) finished its turn.")
    }

    @Test("an earlier report does not cover a later turn")
    func earlierReportDoesNotCoverLaterTurn() async throws {
        let fixture = try makeOutcomeFixture()
        try await insertReadyChild(fixture.persistence)
        try await fixture.persistence.markParentReport(childSessionId: "child", at: 600)

        await fixture.coordinator.childTurnCompleted(completion(startedAt: 700))

        let pending = try await fixture.persistence.pendingMessages(targetSessionId: "parent")
        #expect(pending.map(\.kind) == [.prompt])
        #expect(pending.first?.id == "outcome-child-700")
    }

    @Test("failed and cancelled turns produce wake and notice respectively")
    func failedAndCancelledTurns() async throws {
        let fixture = try makeOutcomeFixture()
        try await insertReadyChild(fixture.persistence)

        await fixture.coordinator.childTurnCompleted(completion(result: .failed("prompt failed: boom"), startedAt: 10))
        await fixture.coordinator.childTurnCompleted(completion(result: .cancelled, startedAt: 20))

        let pending = try await fixture.persistence.pendingMessages(targetSessionId: "parent")
        #expect(pending.map(\.kind) == [.prompt, .notice])
        #expect(pending.first?.prompt == "[alas system] Delegated session child (codex, worktree feature-x) failed: prompt failed: boom.")
    }

    @Test("duplicate completion events enqueue nothing new")
    func duplicateCompletionIsIdempotent() async throws {
        let fixture = try makeOutcomeFixture()
        try await insertReadyChild(fixture.persistence)

        await fixture.coordinator.childTurnCompleted(completion())
        await fixture.coordinator.childTurnCompleted(completion())

        #expect(try await fixture.persistence.pendingMessages(targetSessionId: "parent").count == 1)
    }

    @Test("sessions without a delegation record produce no outcome")
    func nonDelegatedSessionIsIgnored() async throws {
        let fixture = try makeOutcomeFixture()

        await fixture.coordinator.childTurnCompleted(completion())

        #expect(try await fixture.persistence.pendingMessageTargetSessionIds().isEmpty)
    }

    @Test("terminal children do not produce turn outcomes")
    func terminalChildIsIgnored() async throws {
        let fixture = try makeOutcomeFixture()
        try await insertReadyChild(fixture.persistence)
        try await fixture.persistence.updatePhase(childSessionId: "child", phase: .closed, failureMessage: nil, updatedAt: 200)

        await fixture.coordinator.childTurnCompleted(completion())

        #expect(try await fixture.persistence.pendingMessages(targetSessionId: "parent").isEmpty)
    }

    @Test("markChildFailed records the phase and wakes the parent once")
    func markChildFailedWakesParent() async throws {
        let fixture = try makeOutcomeFixture()
        try await insertReadyChild(fixture.persistence)

        await fixture.coordinator.markChildFailed(childSessionId: "child", message: "Agent is not enabled or ACP-capable: codex")
        await fixture.coordinator.markChildFailed(childSessionId: "child", message: "Agent is not enabled or ACP-capable: codex")

        let record = try #require(try await fixture.persistence.delegation(childSessionId: "child"))
        #expect(record.phase == .failed)
        #expect(record.failureMessage == "Agent is not enabled or ACP-capable: codex")
        let pending = try await fixture.persistence.pendingMessages(targetSessionId: "parent")
        #expect(pending.count == 1)
        #expect(pending.first?.id == "outcome-child-failed")
        #expect(pending.first?.kind == .prompt)
    }

    @Test("parent unavailable leaves the outcome pending without a claim")
    func parentUnavailableLeavesRowPending() async throws {
        let fixture = try makeOutcomeFixture(parentReachable: false)
        try await insertReadyChild(fixture.persistence)

        await fixture.coordinator.childTurnCompleted(completion())

        let pending = try await fixture.persistence.pendingMessages(targetSessionId: "parent")
        #expect(pending.count == 1)
        let store = try ACPOrchestrationStore(path: fixture.persistence.path)
        #expect(try store.claimedMessage(id: "outcome-child-500") == nil)
    }

    @Test("a child's session_send to its parent records the report time")
    func sendToParentMarksReport() async throws {
        let fixture = try makeOutcomeFixture()
        try await insertReadyChild(fixture.persistence)

        let response = await fixture.coordinator.send(
            origin: .init(sessionId: "child", projectId: "project", worktreeId: "worktree"),
            request: .init(targetSessionId: "parent", prompt: "Done: parser fixed.")
        )

        guard case .text = response else {
            Issue.record("Expected a queued response, got \(response)")
            return
        }
        let record = try #require(try await fixture.persistence.delegation(childSessionId: "child"))
        #expect(record.lastParentReportAt == 900)
    }

    private func eventuallyLoadDelegation(
        persistence: ACPOrchestrationPersistence,
        childSessionId: String,
        matching predicate: (ACPDelegationRecord) -> Bool
    ) async throws -> ACPDelegationRecord {
        for _ in 0..<50 {
            if let record = try await persistence.delegation(childSessionId: childSessionId),
               predicate(record) {
                return record
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(try await persistence.delegation(childSessionId: childSessionId))
    }
}
