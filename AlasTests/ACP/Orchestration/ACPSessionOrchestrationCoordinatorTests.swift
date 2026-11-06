import Foundation
import Combine
import Testing
@testable import Alas

private extension ACPOrchestrationPersistence {
    /// Keep the first inbox read suspended while the parent finishes its turn.
    func holdInboxReads(until release: DispatchSemaphore, started: CheckedContinuation<Void, Never>) {
        started.resume()
        _ = release.wait(timeout: .now() + 30)
    }
}
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
            createWorktree: { _, _, _, _ in .failure(.init(message: "unused")) }, rememberParent: { _, _ in },
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
            createWorktree: { _, _, _, _ in .failure(.init(message: "unused")) },
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
            createWorktree: { _, _, _, recordDestination in
                // The prepared destination (remote home swapped, virtual) is
                // recorded before the checkout would be created.
                try? await recordDestination(URL(fileURLWithPath: "/.alas-remote/mini/home/remote/feature"))
                return .failure(.init(message: "branch exists"))
            },
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
        #expect(record.worktreeRequest.destinationPath == "/.alas-remote/mini/home/remote/feature")
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
            createWorktree: { _, _, _, _ in
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
            createWorktree: { _, _, _, _ in .failure(.init(message: "unused")) },
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
            createWorktree: { _, _, _, _ in .failure(.init(message: "unused")) },
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
            createWorktree: { _, _, _, _ in .failure(.init(message: "unused")) },
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

    @Test("a delegated child is not started in a worktree that stopped admitting sessions")
    func delegatedChildRespectsWorktreeAdmission() async throws {
        let fixture = try makeAdmissionFixture { _, _ in
            "Wait for the current worktree operation to finish before starting sessions."
        }
        await fixture.createChild()
        let record = try await eventuallyLoadDelegation(
            persistence: fixture.persistence, childSessionId: "child", matching: { $0.phase == .failed }
        )
        #expect(record.failureMessage == "Wait for the current worktree operation to finish before starting sessions.")
        #expect(fixture.parentManager.liveSession(for: "child") == nil)
    }

    /// Admission can replace the worktree's manager (its project changed);
    /// the child starts in the manager left after admission.
    @Test
    func delegatedChildStartsInTheManagerAdmissionLeaves() async throws {
        var replacement: ACPSessionManager?
        var fixture: AdmissionFixture!
        fixture = try makeAdmissionFixture { _, _ in
            replacement = fixture.makeManager()
            fixture.current = replacement
            return nil
        }
        await fixture.createChild()
        _ = try await eventuallyLoadDelegation(
            persistence: fixture.persistence, childSessionId: "child", matching: { $0.phase == .failed }
        )
        #expect(fixture.parentManager.liveSession(for: "child") == nil)
        #expect(replacement?.liveSession(for: "child") != nil)
    }

    @MainActor
    private final class AdmissionFixture {
        let persistence: ACPOrchestrationPersistence
        let sessionStore: ACPSessionStore
        let parentManager: ACPSessionManager
        var current: ACPSessionManager?
        var coordinator: ACPSessionOrchestrationCoordinator!

        init(persistence: ACPOrchestrationPersistence, sessionStore: ACPSessionStore) {
            self.persistence = persistence
            self.sessionStore = sessionStore
            parentManager = ACPSessionManager(
                worktreeId: "worktree", worktreePath: "/tmp/worktree", store: sessionStore,
                setupEvaluator: { _ in .missing(reason: "Install Codex") }
            )
            current = parentManager
        }

        func makeManager() -> ACPSessionManager {
            ACPSessionManager(
                worktreeId: "worktree", worktreePath: "/tmp/worktree", store: sessionStore,
                setupEvaluator: { _ in .missing(reason: "Install Codex") }
            )
        }

        func createChild() async {
            let response = await coordinator.create(
                origin: .init(sessionId: "parent", projectId: "project", worktreeId: "worktree"),
                request: .init(prompt: "Investigate the parser.", agentId: nil, worktree: .current)
            )
            guard case .text = response else {
                Issue.record("Expected delegated session creation response")
                return
            }
        }
    }

    private func makeAdmissionFixture(
        admitChild: @escaping @MainActor (_ worktree: Worktree, _ agentID: String) async -> String?
    ) throws -> AdmissionFixture {
        let directory = FileManager.default.temporaryDirectory
        let fixture = AdmissionFixture(
            persistence: ACPOrchestrationPersistence(
                path: directory.appendingPathComponent("acp-orchestration-coordinator-\(UUID().uuidString).sqlite").path
            ),
            sessionStore: try ACPSessionStore(
                path: directory.appendingPathComponent("acp-orchestration-coordinator-session-\(UUID().uuidString).sqlite").path
            )
        )
        _ = fixture.parentManager.createSession(id: "parent", agentId: "codex", autoRunDefault: false)
        let worktree = Worktree(
            id: "worktree", projectId: "project", name: "main", branch: "main",
            path: URL(fileURLWithPath: "/tmp/worktree"), status: .clean, lastActivity: Date(timeIntervalSince1970: 0)
        )
        let codex = ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true)
        var sessionLocationCalls = 0
        fixture.coordinator = ACPSessionOrchestrationCoordinator(environment: .init(
            persistence: fixture.persistence,
            instanceId: "instance",
            now: { 100 },
            makeID: { "child" },
            worktree: { $0 == worktree.id ? worktree : nil },
            existingWorktree: { _, _ in nil },
            configuredAgents: { [codex] },
            availableAgents: { _, destination in destination.id == worktree.id ? [codex] : [] },
            sessionLocation: { [weak fixture] sessionId in
                sessionLocationCalls += 1
                guard let fixture, sessionLocationCalls == 1, sessionId == "parent" else { return nil }
                return .init(
                    origin: .init(sessionId: "parent", projectId: "project", worktreeId: worktree.id),
                    manager: fixture.parentManager
                )
            },
            manager: { [weak fixture] _ in fixture?.current },
            newWorktreeDestination: { _, _ in nil },
            createWorktree: { _, _, _, _ in .failure(.init(message: "unused")) },
            rememberParent: { _, _ in },
            autoRunDefault: { false },
            notifyChanged: {},
            admitChild: admitChild
        ))
        return fixture
    }

    private func makeModelSelectionFixture(
        client: ACPMockClient,
        launchModels: [ACPAgentModelCatalog.Model]? = nil,
        reasoningRefreshTimeout: Duration = .seconds(30),
        waitForChildResultBatch: @escaping @Sendable () async -> Void = {},
        notifyChanged: @escaping () -> Void = {},
        setupEvaluator: @escaping ACPSessionManager.ACPSetupEvaluator = { _ in .ready },
        project: ProjectConfig? = nil,
        worktreeIsListed: Bool = true,
        admitChild: @escaping @MainActor (Worktree, String) async -> String? = { _, _ in nil },
        autoRunDefault: Bool = false,
        skipsRepoHook: Bool = false,
        peerWorktreeBase: Result<String, ACPSessionOrchestrationCoordinator.WorktreeCreationError> = .success("origin/main"),
        onPeerWorktree: @escaping (_ base: String) -> Void = { _ in },
        peers: (any ACPDelegationPeers)? = nil,
        originRemote: String? = "github.com/o/r",
        nowMillis: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        pause: @escaping (Duration) async -> Void = { _ in await Task.yield() },
        makeID: @escaping () -> String = { "child" }
    ) throws -> (coordinator: ACPSessionOrchestrationCoordinator, persistence: ACPOrchestrationPersistence, manager: ACPSessionManager) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acp-model-selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let persistence = ACPOrchestrationPersistence(path: root.appendingPathComponent("delegations.sqlite").path)
        // Wired as AppState wires it.
        let manager = ACPSessionManager(
            worktreeId: "worktree",
            worktreePath: root.path,
            store: try ACPSessionStore(path: root.appendingPathComponent("sessions.sqlite").path),
            setupEvaluator: setupEvaluator,
            connectionFactory: { _, _, _ in ACPConnection(client: client) },
            delegatedSelectionHoldResolver: { id in
                do {
                    return ACPSessionOrchestrationPolicy.selectionHoldDecision(
                        target: try await persistence.delegation(childSessionId: id)
                    )
                } catch {
                    return nil
                }
            },
            delegatedReasoningRefreshTimeout: reasoningRefreshTimeout
        )
        _ = manager.createSession(id: "parent", agentId: "claude", autoRunDefault: false)
        let worktree = Worktree(
            id: "worktree", projectId: "project", name: "main", branch: "main", path: root,
            status: .clean, lastActivity: Date(timeIntervalSince1970: 0)
        )
        let claude = ACPOrchestrationAgent(id: "claude", isEnabled: true, isACPCapable: true)
        let coordinator = ACPSessionOrchestrationCoordinator(environment: .init(
            persistence: persistence, instanceId: "instance", now: { 100 }, nowMillis: nowMillis,
            waitForChildResultBatch: waitForChildResultBatch, makeID: makeID,
            worktree: { $0 == worktree.id ? worktree : nil },
            existingWorktree: { _, selector in
                // Resolved as the host resolves it.
                guard case .matched(let match) = AlasCLIWorktreeResolver.resolve(
                    target: selector, worktrees: worktreeIsListed ? [worktree] : []
                ) else { return nil }
                return match
            },
            configuredAgents: { [claude] }, availableAgents: { _, _ in [claude] },
            launchModels: { _, _ in launchModels },
            sessionLocation: { sessionId in
                manager.liveSession(for: sessionId) == nil
                    ? nil
                    : .init(origin: .init(sessionId: sessionId, projectId: "project", worktreeId: "worktree"), manager: manager)
            },
            manager: { _ in manager },
            newWorktreeDestination: { _, branch in root.appendingPathComponent(branch) },
            createWorktree: { _, _, _, _ in .failure(.init(message: "unused")) }, rememberParent: { _, _ in },
            autoRunDefault: { autoRunDefault }, notifyChanged: notifyChanged,
            pause: pause,
            admitChild: admitChild,
            project: { $0 == project?.id ? project : nil },
            createPeerWorktree: { _, _, base, _ in
                onPeerWorktree(base)
                return .success(.init(worktree: worktree, skippedRepoHook: skipsRepoHook))
            },
            resolvePeerWorktreeBase: { _, _, _, _ in peerWorktreeBase },
            machineName: { "Mini" },
            delegationPeers: { peers },
            originRemote: { _ in originRemote },
            resolvePeerWorktree: { selector, worktrees in
                switch AlasCLIWorktreeResolver.resolve(target: selector, worktrees: worktrees) {
                case .matched(let match): .matched(match)
                case .missing: .missing
                case .ambiguous(let labels): .ambiguous(labels)
                }
            }
        ))
        return (coordinator, persistence, manager)
    }

    /// A Claude-shaped agent: models through `session/set_model`, reasoning
    /// through the `effort` config option. The child connects first, so it
    /// owns `remote-1`.
    private func makeSelectionClient(configOptions: [ACPConfigOption] = []) -> ACPMockClient {
        let client = ACPMockClient()
        client.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(protocolVersion: 1, agentCapabilities: nil, authMethods: []))
        }
        var remoteSessions = 0
        client.script(method: "session/new") { _ in
            remoteSessions += 1
            return try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-\(remoteSessions)",
                availableModels: [.init(id: "default", name: "Default"), .init(id: "opus", name: "Opus")],
                availableModes: [], currentModel: "default", currentMode: nil, promptSuggestions: [],
                configOptions: configOptions
            ))
        }
        client.script(method: "session/set_model") { _ in Data("{}".utf8) }
        client.script(method: "session/set_config_option") { _ in Data("{}".utf8) }
        client.script(method: "session/prompt") { _ in Data(#"{"stopReason":"end_turn"}"#.utf8) }
        return client
    }

    /// The child's selection changes and prompts, in the order it sent them.
    private func childRequests(_ client: ACPMockClient) -> [String] {
        client.sent.compactMap { request -> String? in
            switch request.params {
            case let params as ACPSessionSetModelParams where params.sessionId == "remote-1":
                return "set_model:\(params.modelId)"
            case let params as ACPSessionSetConfigOptionParams where params.sessionId == "remote-1":
                return "set_config_option:\(params.configId)=\(params.value)"
            case let params as ACPSessionPromptParams where params.sessionId == "remote-1":
                let text = params.prompt.compactMap { block -> String? in
                    guard case .text(let text) = block else { return nil }
                    return text
                }.joined()
                return "prompt:" + (text.components(separatedBy: "\n").last ?? text)
            default:
                return nil
            }
        }
    }

    private func selectedChildRecord(phase: ACPDelegationPhase = .starting) -> ACPDelegationRecord {
        .init(
            childSessionId: "child", parentSessionId: "parent", projectId: "project",
            parentWorktreeId: "worktree", childWorktreeId: "worktree", agentId: "claude",
            worktreeRequest: .current(worktreeId: "worktree"), pendingInitialPrompt: "Review the parser.",
            phase: phase, failureMessage: nil, createdAt: 1, updatedAt: 1,
            modelSelection: ACPDelegatedModelSelection(model: "opus", reasoning: nil)
        )
    }

    @Test("a requested model is acknowledged before the first prompt; a refused one fails the child without prompting", arguments: [true, false])
    func modelSelectionPrecedesFirstPrompt(agentAcceptsModel: Bool) async throws {
        let client = makeSelectionClient()
        client.script(method: "session/set_model") { _ in
            guard agentAcceptsModel else {
                throw JSONRPCError(code: -32602, message: "Unknown model", data: nil)
            }
            return Data("{}".utf8)
        }
        let fixture = try makeModelSelectionFixture(client: client)
        defer { fixture.manager.shutdownBackgroundTasks() }

        let response = await fixture.coordinator.create(
            origin: .init(sessionId: "parent", projectId: "project", worktreeId: "worktree"),
            request: .init(prompt: "Review the parser.", agentId: nil, worktree: .current,
                           modelSelection: ACPDelegatedModelSelection(model: "opus", reasoning: nil))
        )
        guard case .text = response else {
            Issue.record("Expected delegated session creation response")
            return
        }
        #expect(try await fixture.persistence.delegation(childSessionId: "child")?.modelSelection?.model == "opus")

        if agentAcceptsModel {
            try await waitUntil { childRequests(client).count == 2 }
            #expect(childRequests(client) == ["set_model:opus", "prompt:Review the parser."])
            #expect(fixture.manager.liveSession(for: "child")?.currentModel == "opus")
        } else {
            let record = try await eventuallyLoadDelegation(
                persistence: fixture.persistence, childSessionId: "child", matching: { $0.phase == .failed }
            )
            #expect(record.phase == .failed)
            #expect(record.failureMessage?.contains("did not apply model opus") == true)
            #expect(record.pendingInitialPrompt == "Review the parser.")
            #expect(childRequests(client) == ["set_model:opus"])
            #expect(fixture.manager.liveSession(for: "child")?.queue.isEmpty == true)
        }
    }

    enum ParentCompletionBoundary: CaseIterable {
        case idle, readingInbox, collecting
    }

    @Test("nearby child results produce one parent turn while notices stay informational", arguments: ParentCompletionBoundary.allCases)
    func nearbyResultsShareOneParentTurn(boundary: ParentCompletionBoundary) async throws {
        let parentIsBusy = boundary != .idle
        let gate = GenerationGate()
        let activeTurn = GenerationGate()
        let client = makeSelectionClient()
        var promptCount = 0
        client.scriptAsync(method: "session/prompt") { _ in
            promptCount += 1
            if parentIsBusy && promptCount == 1 { await activeTurn.wait() }
            return Data(#"{"stopReason":"end_turn"}"#.utf8)
        }
        var observedManager: ACPSessionManager?
        var noticePrecededReportAcceptance = false
        let fixture = try makeModelSelectionFixture(client: client, waitForChildResultBatch: { await gate.wait() }, notifyChanged: {
            guard let parent = observedManager?.liveSession(for: "parent"),
                  parent.transcript.messages.contains(where: { message in
                      guard case .systemNotice(_, let text) = message else { return false }
                      return text == "Child turn completed."
                  }) else { return }
            if !parent.queue.contains(where: { $0.delegatedSource?.deliveries.contains { $0.messageId == "first" } == true }) {
                noticePrecededReportAcceptance = true
            }
        })
        observedManager = fixture.manager
        defer { fixture.manager.shutdownBackgroundTasks() }
        await fixture.manager.attach(to: "parent", freshlyCreated: true)
        try #require(fixture.manager.isWriter(for: "parent"))
        let parent = try #require(fixture.manager.liveSession(for: "parent"))
        if parentIsBusy {
            try #require(fixture.manager.runners["parent"]).send(text: "Parent work", attachments: [])
            await activeTurn.waitUntilStarted()
            #expect(await fixture.manager.enqueueDelegatedPrompt(text: "Earlier child result",
                source: .init(sessionId: "earlier", messageId: "earlier", senderRelationship: "child"), into: "parent"))
        }
        var first = selectedChildRecord(phase: .ready)
        first.role = "planner"
        try await fixture.persistence.insert(first)
        try await fixture.persistence.enqueue(.init(id: "first", sourceSessionId: "child", targetSessionId: "parent", prompt: "Report from planner child: Plan ready.", createdAt: 1))
        let releaseInbox = DispatchSemaphore(value: 0)
        defer { releaseInbox.signal() }
        if boundary == .readingInbox {
            await withCheckedContinuation { started in
                Task.detached { await fixture.persistence.holdInboxReads(until: releaseInbox, started: started) }
            }
        }
        var deliveryStarted = false
        let delivery = Task {
            deliveryStarted = true
            await fixture.coordinator.deliverPendingMessages(to: "parent", manager: fixture.manager)
        }
        if boundary == .readingInbox {
            try await waitUntil { deliveryStarted }
            await activeTurn.release()
            try await waitUntil { parent.transcript.streamingState == .idle }
            #expect(promptCount == 1)
            releaseInbox.signal()
        }
        await gate.waitUntilStarted()
        if boundary == .collecting {
            await activeTurn.release()
            try await waitUntil { parent.transcript.streamingState == .idle }
            #expect(promptCount == 1)
        }
        try await fixture.persistence.insert(.init(childSessionId: "reviewer", parentSessionId: "parent", projectId: "project", parentWorktreeId: "worktree", childWorktreeId: "worktree", agentId: "claude", worktreeRequest: .current(worktreeId: "worktree"), phase: .ready, failureMessage: nil, createdAt: 2, updatedAt: 2, role: "reviewer"))
        try await fixture.persistence.enqueue(.init(id: "second", sourceSessionId: "reviewer", targetSessionId: "parent", prompt: "Report from reviewer child: Review ready.", createdAt: 2))
        try await fixture.persistence.enqueue(.init(id: "notice", sourceSessionId: "child", targetSessionId: "parent", prompt: "Child turn completed.", createdAt: 3, kind: .notice))
        await fixture.coordinator.deliverPendingMessages(to: "parent", manager: fixture.manager)
        await gate.release()
        await delivery.value
        try await waitUntil {
            !childRequests(client).isEmpty && parent.queue.isEmpty && parent.transcript.streamingState == .idle
        }
        let prompts = client.sent.compactMap { $0.params as? ACPSessionPromptParams }
        #expect(prompts.count == (parentIsBusy ? 2 : 1))
        let text = prompts.flatMap(\.prompt).compactMap { block -> String? in
            guard case .text(let text) = block else { return nil }
            return text
        }.joined()
        #expect(text.contains("Plan ready."))
        #expect(text.contains("Review ready."))
        #expect(!text.contains("Child turn completed."))
        #expect(!noticePrecededReportAcceptance)
        #expect(try await fixture.persistence.pendingMessages(targetSessionId: "parent").isEmpty)
        #expect(!parent.hasPendingDelegatedMessages)
    }

    @Test("a parent archived during collection keeps results pending without waking")
    func archivedParentIsNotWokenAfterCollection() async throws {
        let gate = GenerationGate()
        let client = makeSelectionClient()
        let fixture = try makeModelSelectionFixture(client: client, waitForChildResultBatch: { await gate.wait() })
        defer { fixture.manager.shutdownBackgroundTasks() }
        await fixture.manager.attach(to: "parent", freshlyCreated: true)
        try await fixture.persistence.insert(selectedChildRecord(phase: .ready))
        try await fixture.persistence.enqueue(.init(id: "report", sourceSessionId: "child", targetSessionId: "parent", prompt: "Result ready.", createdAt: 1))
        let delivery = Task { await fixture.coordinator.deliverPendingMessages(to: "parent", manager: fixture.manager) }
        await gate.waitUntilStarted()
        fixture.manager.setArchived(id: "parent", archived: true)
        await fixture.manager.flushPersistence()
        await gate.release()
        await delivery.value
        #expect(client.sent.allSatisfy { $0.method != "session/prompt" })
        #expect(try await fixture.persistence.pendingMessages(targetSessionId: "parent").map(\.id) == ["report"])
    }

    @Test("a child role is persisted, listed and sent in its initial context")
    func childRoleReachesInitialContext() async throws {
        let client = makeSelectionClient()
        let fixture = try makeModelSelectionFixture(client: client)
        defer { fixture.manager.shutdownBackgroundTasks() }
        let origin = ACPOrchestrationSessionOrigin(sessionId: "parent", projectId: "project", worktreeId: "worktree")
        let response = await fixture.coordinator.create(origin: origin,
            request: .init(prompt: "Review the parser.", agentId: nil, worktree: .current, role: " reviewer "))
        guard case .text = response else {
            Issue.record("Expected a delegated child")
            return
        }
        try await waitUntil { !childRequests(client).isEmpty }
        let prompt = try #require(client.sent.compactMap { $0.params as? ACPSessionPromptParams }.first)
        let text = prompt.prompt.compactMap { block -> String? in
            guard case .text(let text) = block else { return nil }
            return text
        }.joined()
        #expect(text.contains("Your role in this delegated task is reviewer."))
        #expect(text.contains("Review the parser."))
        #expect(try await fixture.persistence.delegation(childSessionId: "child")?.role == "reviewer")
        guard case .text(let lines) = await fixture.coordinator.list(origin: origin) else {
            Issue.record("Expected a session list")
            return
        }
        let listed = try JSONDecoder().decode(ACPOrchestrationListResponse.self, from: Data(lines.joined(separator: "\n").utf8))
        #expect(listed.sessions.first { $0.sessionId == "child" }?.role == "reviewer")
    }

    @Test("a model missing from this launch's catalog is rejected before any child exists")
    func unknownModelIsRejectedBeforeCreation() async throws {
        let fixture = try makeModelSelectionFixture(
            client: ACPMockClient(),
            launchModels: [.init(id: "opus", name: "Opus")]
        )
        defer { fixture.manager.shutdownBackgroundTasks() }

        let response = await fixture.coordinator.create(
            origin: .init(sessionId: "parent", projectId: "project", worktreeId: "worktree"),
            request: .init(prompt: "Review the parser.", agentId: nil, worktree: .current,
                           modelSelection: ACPDelegatedModelSelection(model: "gpt-5.2", reasoning: nil))
        )

        #expect(response == .error("Model gpt-5.2 is not offered by agent claude. Available: opus."))
        #expect(try await fixture.persistence.delegation(childSessionId: "child") == nil)
        #expect(fixture.manager.liveSession(for: "child") == nil)
    }

    @Test("a prompt typed in a selected child's tab waits for the model, and runs after the initial prompt")
    func composerPromptWaitsForModelSelection() async throws {
        let client = makeSelectionClient()
        let setModel = GenerationGate()
        client.scriptAsync(method: "session/set_model") { _ in
            await setModel.wait()
            return Data("{}".utf8)
        }
        let fixture = try makeModelSelectionFixture(client: client)
        defer { fixture.manager.shutdownBackgroundTasks() }

        _ = await fixture.coordinator.create(
            origin: .init(sessionId: "parent", projectId: "project", worktreeId: "worktree"),
            request: .init(prompt: "Review the parser.", agentId: nil, worktree: .current,
                           modelSelection: ACPDelegatedModelSelection(model: "opus", reasoning: nil))
        )
        await setModel.waitUntilStarted()
        let child = try #require(fixture.manager.liveSession(for: "child"))
        #expect(child.agentState == .ready)
        try #require(fixture.manager.runners["child"]).send(text: "Also check the lexer.", attachments: [])

        #expect(child.queue.count == 1)
        await setModel.release()
        try await waitUntil { childRequests(client).count == 3 }
        #expect(childRequests(client) == [
            "set_model:opus", "prompt:Review the parser.", "prompt:Also check the lexer.",
        ])
    }

    /// Startup recovery of a child that crashed after queueing its initial
    /// prompt, when the child's tab was also restored and attached first.
    @Test("a restored tab attaching a selected child before recovery cannot run its queued initial prompt")
    func restoredAttachHoldsInitialPromptForRecovery() async throws {
        let client = makeSelectionClient()
        let setModel = GenerationGate()
        client.scriptAsync(method: "session/set_model") { _ in
            await setModel.wait()
            return Data("{}".utf8)
        }
        let fixture = try makeModelSelectionFixture(client: client)
        defer { fixture.manager.shutdownBackgroundTasks() }
        let record = selectedChildRecord()
        try await fixture.persistence.insert(record)
        _ = fixture.manager.createSession(id: "child", agentId: "claude")
        let initial = fixture.coordinator.initialPromptSource(for: record)
        #expect(await fixture.manager.enqueueDelegatedPrompt(text: "Review the parser.", source: initial, into: "child"))

        // The tab's attach wins the race with recovery.
        await fixture.manager.attach(to: "child", freshlyCreated: true)
        #expect(fixture.manager.liveSession(for: "child")?.agentState == .ready)
        #expect(childRequests(client).isEmpty)

        // Recovery still takes the prompt back and reapplies the selection.
        let withheld = fixture.manager.withholdQueuedDelegatedPrompt(messageId: initial.messageId, in: "child")
        #expect(withheld == "Review the parser.")
        let selection = try #require(record.modelSelection)
        let selecting = Task { await fixture.coordinator.queueInitialPromptAfterModelSelection(
            selection, record: record, prompt: "Review the parser.", manager: fixture.manager
        ) }
        await setModel.waitUntilStarted()
        #expect(!fixture.manager.isIdleForProjectRebinding)
        var readiness: Bool?
        let subscription = fixture.manager.projectRebindingReadiness.sink { readiness = $0 }
        defer { subscription.cancel() }
        #expect(await awaitCondition(within: .seconds(1)) { readiness == false })
        await setModel.release()
        #expect(await selecting.value)
        #expect(childRequests(client) == ["set_model:opus"])
        fixture.manager.releaseDelegatedSelectionHold("child")
        try await waitUntil { childRequests(client).count == 2 }
        #expect(childRequests(client) == ["set_model:opus", "prompt:Review the parser."])
        #expect(await awaitCondition { readiness == true })
    }

    enum ReasoningRefresh: CaseIterable {
        case published, neverPublished, modelChangedMeanwhile
    }

    @Test("reasoning published only after the model switch is applied; otherwise the child fails", arguments: ReasoningRefresh.allCases)
    func reasoningWaitsForPostSwitchOptions(refresh: ReasoningRefresh) async throws {
        let client = makeSelectionClient()
        let fixture = try makeModelSelectionFixture(
            client: client,
            reasoningRefreshTimeout: refresh == .neverPublished ? .milliseconds(100) : .seconds(30)
        )
        defer { fixture.manager.shutdownBackgroundTasks() }

        _ = await fixture.coordinator.create(
            origin: .init(sessionId: "parent", projectId: "project", worktreeId: "worktree"),
            request: .init(prompt: "Review the parser.", agentId: nil, worktree: .current,
                           modelSelection: ACPDelegatedModelSelection(model: "opus", reasoning: "high"))
        )
        // The `session/set_model` reply is handled, and reasoning checked
        // against the default model's (absent) options, before the update.
        try await waitUntil { fixture.manager.liveSession(for: "child")?.currentModel == "opus" }
        if refresh == .modelChangedMeanwhile {
            // The user picks another model in the child's tab during the wait.
            await fixture.manager.enqueueModelSelection(for: "child", modelId: "default").value
        }
        if refresh != .neverPublished {
            client.emit(.init(sessionId: "remote-1", update: .sessionConfigOptionsUpdate([ACPConfigOption(
                id: "effort", name: "Effort", currentValue: "low",
                options: [.init(id: "low", name: "Low"), .init(id: "high", name: "High")]
            )])))
        }
        if refresh == .published {
            try await waitUntil { childRequests(client).count == 3 }
            #expect(childRequests(client) == [
                "set_model:opus", "set_config_option:effort=\(ACPConfigValue.string("high"))", "prompt:Review the parser.",
            ])
            return
        }
        let record = try await eventuallyLoadDelegation(
            persistence: fixture.persistence, childSessionId: "child", matching: { $0.phase == .failed }
        )
        if refresh == .neverPublished {
            #expect(record.failureMessage == ACPDelegatedModelSelectionError.reasoningUnsupported(agentId: "claude").errorDescription)
        } else {
            #expect(record.failureMessage?.contains("the model changed while the selection was being applied") == true)
        }
        #expect(!childRequests(client).contains { $0.hasPrefix("prompt:") })
    }

    @Test("after a model switch the reasoning is sent even when the old model's chip already shows it")
    func reasoningIsReappliedAfterModelSwitch() async throws {
        let client = makeSelectionClient(configOptions: [ACPConfigOption(
            id: "effort", name: "Effort", currentValue: "high",
            options: [.init(id: "low", name: "Low"), .init(id: "high", name: "High")]
        )])
        let fixture = try makeModelSelectionFixture(client: client)
        defer { fixture.manager.shutdownBackgroundTasks() }

        _ = await fixture.coordinator.create(
            origin: .init(sessionId: "parent", projectId: "project", worktreeId: "worktree"),
            request: .init(prompt: "Review the parser.", agentId: nil, worktree: .current,
                           modelSelection: ACPDelegatedModelSelection(model: "opus", reasoning: "high"))
        )

        try await waitUntil { childRequests(client).count == 3 }
        #expect(childRequests(client) == [
            "set_model:opus", "set_config_option:effort=\(ACPConfigValue.string("high"))", "prompt:Review the parser.",
        ])
    }

    /// Two instances sharing the store: this one restored the child, with
    /// its initial prompt queued, while it was starting; the other one then
    /// finished starting it, or failed it.
    @Test("a hold another instance resolved is lifted on the next attach, without a failed child's initial prompt", arguments: [
        ACPDelegationPhase.ready, .failed,
    ])
    func holdResolvedElsewhereIsLiftedOnAttach(phase: ACPDelegationPhase) async throws {
        let client = makeSelectionClient()
        let fixture = try makeModelSelectionFixture(client: client)
        defer { fixture.manager.shutdownBackgroundTasks() }
        let record = selectedChildRecord()
        try await fixture.persistence.insert(record)
        _ = fixture.manager.createSession(id: "child", agentId: "claude")
        #expect(await fixture.manager.enqueueDelegatedPrompt(
            text: "Review the parser.", source: fixture.coordinator.initialPromptSource(for: record), into: "child"
        ))
        await fixture.manager.attach(to: "child", freshlyCreated: true)
        try #require(fixture.manager.runners["child"]).send(text: "Also check the lexer.", attachments: [])
        #expect(fixture.manager.liveSession(for: "child")?.queue.count == 2)

        try await fixture.persistence.updatePhase(childSessionId: "child", phase: phase, failureMessage: nil, updatedAt: 2)
        await fixture.manager.attach(to: "child", freshlyCreated: false)

        let expected = phase == .ready
            ? ["prompt:Review the parser.", "prompt:Also check the lexer."]
            : ["prompt:Also check the lexer."]
        try await waitUntil { childRequests(client).count == expected.count && fixture.manager.liveSession(for: "child")?.queue.isEmpty == true }
        #expect(childRequests(client) == expected)
    }

    @Test("messages held for a child whose model selection failed are discarded, never delivered")
    func failedSelectedChildDropsHeldMessages() async throws {
        let fixture = try makeModelSelectionFixture(client: ACPMockClient())
        defer { fixture.manager.shutdownBackgroundTasks() }
        try await fixture.persistence.insert(selectedChildRecord())
        try await fixture.persistence.enqueue(.init(
            id: "follow-up", sourceSessionId: "parent", targetSessionId: "child",
            prompt: "Also check the lexer.", createdAt: 2
        ))
        let held = try await fixture.persistence.delegation(childSessionId: "child")
        #expect(ACPSessionOrchestrationPolicy.defersInboxDelivery(target: held))

        await fixture.coordinator.markChildFailed(childSessionId: "child", message: "Model opus is not offered by agent claude.")

        #expect(try await fixture.persistence.pendingMessages(targetSessionId: "child").isEmpty)
        let failed = try await fixture.persistence.delegation(childSessionId: "child")
        #expect(ACPSessionOrchestrationPolicy.defersInboxDelivery(target: failed))
    }

    private struct OutcomeFixture {
        let coordinator: ACPSessionOrchestrationCoordinator
        let persistence: ACPOrchestrationPersistence
        let manager: ACPSessionManager
        var sessionPath = ""
    }

    /// A parent session that exists but cannot attach (missing agent), so
    /// delivery leaves rows pending and unclaimed for inspection.
    private func makeOutcomeFixture(
        parentReachable: Bool = true,
        readScope: ACPOrchestrationSessionOrigin? = nil,
        blockedKeys: Set<String> = [],
        escalationSeconds: Int = 30,
        scheduleEscalationCheck: @escaping (Int, @escaping @Sendable () async -> Void) -> Void = { _, _ in },
        pause: @escaping (Duration) async -> Void = { _ in },
        releaseReferencedSession: (() -> Void)? = nil,
        sessionPath: String? = nil,
        onSessionLookup: @escaping (String) -> Void = { _ in }
    ) throws -> OutcomeFixture {
        let orchestrationPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-outcome-\(UUID().uuidString).sqlite").path
        let reopensStore = sessionPath != nil
        let sessionPath = sessionPath ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-outcome-session-\(UUID().uuidString).sqlite").path
        let persistence = ACPOrchestrationPersistence(path: orchestrationPath)
        let manager = ACPSessionManager(
            worktreeId: "worktree",
            worktreePath: "/tmp/worktree",
            store: try ACPSessionStore(path: sessionPath),
            setupEvaluator: { _ in .missing(reason: "Install Codex") }
        )
        if !reopensStore {
            _ = manager.createSession(id: "parent", agentId: "codex", autoRunDefault: false)
        }
        let worktree = Worktree(
            id: "worktree", projectId: "project", name: "feature-x", branch: "feature-x",
            path: URL(fileURLWithPath: "/tmp/worktree"), status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let coordinator = ACPSessionOrchestrationCoordinator(environment: .init(
            persistence: persistence,
            instanceId: "instance",
            now: { 900 },
            nowMillis: { 900 },
            blockedRequestKeys: { _ in blockedKeys },
            escalationDelaySeconds: { escalationSeconds },
            scheduleEscalationCheck: scheduleEscalationCheck,
            makeID: { UUID().uuidString },
            worktree: { parentReachable && $0 == worktree.id ? worktree : nil },
            existingWorktree: { _, _ in nil },
            configuredAgents: { [ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true)] },
            availableAgents: { _, _ in [ACPOrchestrationAgent(id: "codex", isEnabled: true, isACPCapable: true)] },
            sessionLocation: { sessionId in
                onSessionLookup(sessionId)
                return parentReachable && manager.liveSession(for: sessionId) != nil
                    ? .init(origin: .init(sessionId: sessionId, projectId: readScope?.projectId ?? "project",
                                          worktreeId: readScope?.worktreeId ?? "worktree"), manager: manager)
                    : nil
            },
            referencedSessionLocation: { sessionId, _ in
                manager.liveSession(for: sessionId) != nil
                    ? .init(
                        origin: .init(sessionId: sessionId, projectId: "project", worktreeId: "worktree"),
                        manager: manager, release: releaseReferencedSession
                    )
                    : nil
            },
            manager: { _ in parentReachable ? manager : nil },
            newWorktreeDestination: { _, _ in nil },
            createWorktree: { _, _, _, _ in .failure(.init(message: "unused")) },
            rememberParent: { _, _ in },
            autoRunDefault: { false },
            notifyChanged: {},
            pause: pause,
            machineName: { "Studio" }
        ))
        return .init(coordinator: coordinator, persistence: persistence, manager: manager, sessionPath: sessionPath)
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
        lastAgentText: String? = "Parser fixed.",
        delegatedSource: ACPDelegatedPromptSource? = nil
    ) -> ACPTurnCompletion {
        .init(sessionId: "child", startedAt: startedAt, result: result,
              delegatedSource: delegatedSource, lastAgentText: lastAgentText)
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

    /// A child whose turn settled at its result while its own subagent still
    /// runs reports to the parent only once that work ends, with the answer
    /// its follow-up ended on rather than the interim text, even across a
    /// reconnect its adapter survives. A follow-up the user stopped reports
    /// as a cancelled turn.
    @Test("a settling child reports once its background work ends", arguments: ["finishes", "reconnects", "stopped"])
    func settlingChildReportsAfterBackgroundWork(ending: String) async throws {
        let fixture = try makeOutcomeFixture()
        try await insertReadyChild(fixture.persistence)
        let child = fixture.manager.createSession(id: "child", agentId: "claude", autoRunDefault: false)
        child.agentState = .ready
        child.settlesAtResult = true
        child.registerSubagent(.init(subagentSessionId: "sub"))

        await fixture.coordinator.childTurnCompleted(completion(lastAgentText: "Started a background agent."))
        #expect(try await fixture.persistence.pendingMessages(targetSessionId: "parent").isEmpty)

        var cycle = ACPBackgroundTask(ownerSessionId: "child", asyncTaskId: "cycle", name: "Claude is working")
        cycle.taskType = "turn"
        if ending == "stopped" { child.saveBackgroundTask(cycle) }
        if ending == "reconnects" {
            child.agentState = .disconnected
            // The coordinator's check was queued first on the main actor.
            await Task { @MainActor in }.value
            child.agentState = .ready
        }
        child.apply(.agentMessageChunk(.init(messageId: "final", content: .text("Parser fixed for real."))))
        child.applySubagentState(.init(subagentSessionId: "sub", state: .completed))
        if ending == "stopped" {
            cycle.state = "stopped"
            child.saveBackgroundTask(cycle)
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var pending = try await fixture.persistence.pendingMessages(targetSessionId: "parent")
        while pending.isEmpty {
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
            pending = try await fixture.persistence.pendingMessages(targetSessionId: "parent")
        }
        #expect(pending.map(\.id) == ["outcome-child-500"])
        if ending == "stopped" {
            #expect(pending.first?.kind == .notice)
            #expect(pending.first?.prompt == "Delegated session child (codex, worktree feature-x) had its turn cancelled.")
            return
        }
        #expect(pending.first?.prompt.contains("Parser fixed for real.") == true)
        #expect(pending.first?.prompt.contains("Started a background agent.") == false)
    }

    @Test(arguments: [ACPStopReason(), ACPStopReason(rawValue: .string("refusal"))])
    func stoppedChildWakesParentWithAnExplicitOutcome(reason: ACPStopReason) async throws {
        let fixture = try makeOutcomeFixture()
        try await insertReadyChild(fixture.persistence)
        try await fixture.persistence.markParentReport(childSessionId: "child", at: 600)
        let stopped = completion(result: .stopped(reason))
        await fixture.coordinator.childTurnCompleted(stopped)
        await fixture.coordinator.childTurnCompleted(stopped)
        let pending = try await fixture.persistence.pendingMessages(targetSessionId: "parent")
        #expect(pending.count == 1)
        #expect(pending.first?.kind == .prompt)
        #expect(pending.first?.prompt == "[alas system] Delegated session child (codex, worktree feature-x) stopped: \(reason.summary).")
        #expect(try await fixture.persistence.delegation(childSessionId: "child")?.phase == .ready)
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
        #expect(pending.last?.prompt == "Delegated session child (codex, worktree feature-x) had its turn cancelled.")
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

    @Test("a PR shepherd turn on a delegated child is not reported to the parent")
    func shepherdTurnOnChildIsIgnored() async throws {
        let fixture = try makeOutcomeFixture()
        try await insertReadyChild(fixture.persistence)

        await fixture.coordinator.childTurnCompleted(completion(
            delegatedSource: .shepherd(recordKey: "github:owner/repo#7", messageID: UUID())
        ))

        #expect(try await fixture.persistence.pendingMessageTargetSessionIds().isEmpty)
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

    @Test("a child's session_send to its parent is framed as its report and records the report time")
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
        let pending = try await fixture.persistence.pendingMessages(targetSessionId: "parent")
        #expect(pending.map(\.prompt) == [
            "[alas system] Report from delegated session child (codex, worktree feature-x) via session_send:\nDone: parser fixed."
        ])
    }

    // MARK: - Starting a child for a paired Mac

    private func peerProject(path: String = "/tmp/worktree", host: String? = nil, kind: ProjectKind = .git) -> ProjectConfig {
        var project = ProjectConfig(id: "project", name: "project", path: path, color: "blue", addedAt: .distantPast)
        project.host = host
        project.kind = kind
        return project
    }

    private func peerStart(
        peer: String = "s1",
        target: ACPPeerChildTarget,
        modelSelection: ACPDelegatedModelSelection? = nil,
        autoRun: Bool = false,
        childID: String = "child"
    ) -> ACPPeerChildStart {
        .init(
            childID: childID, peerServerId: peer, projectID: "project", target: target, agentID: "claude",
            modelSelection: modelSelection, role: nil, autoRun: autoRun, prompt: "Review the parser."
        )
    }

    private func insertPeerChild(_ persistence: ACPOrchestrationPersistence) async throws {
        try await persistence.insert(.init(
            childSessionId: "child", parentSessionId: ACPPeerParent.sentinel(serverId: "s1"), projectId: "project",
            parentWorktreeId: "worktree", childWorktreeId: "worktree", agentId: "codex",
            worktreeRequest: .current(worktreeId: "worktree"), pendingInitialPrompt: nil,
            phase: .ready, failureMessage: nil, createdAt: 100, updatedAt: 100
        ))
    }

    private func outbox(_ persistence: ACPOrchestrationPersistence) async throws -> [ACPPeerOutboxEntry] {
        try await persistence.outbox(peerServerId: "s1", after: 0, maxBytes: 1 << 20).entries
    }

    private func checkout(of manager: ACPSessionManager) -> ACPPeerChildTarget {
        .worktree(path: manager.worktreePath)
    }

    /// Auto-run comes from the peer's request, not this Mac's default.
    @Test(arguments: [true, false])
    func startForPeerRecordsSentinelParentAndStartsChild(autoRun: Bool) async throws {
        let client = makeSelectionClient()
        let fixture = try makeModelSelectionFixture(client: client, project: peerProject(), autoRunDefault: !autoRun)
        defer { fixture.manager.shutdownBackgroundTasks() }

        let result = await fixture.coordinator.startForPeer(peerStart(target: checkout(of: fixture.manager), autoRun: autoRun))

        #expect(result == .started(sessionId: "child", state: "starting"))
        let started = try #require(try await fixture.persistence.delegation(childSessionId: "child"))
        #expect(started.parentSessionId == "peer:s1")
        #expect(started.peerServerId == nil)
        try await waitUntil { childRequests(client) == ["prompt:Review the parser."] }
        #expect(fixture.manager.liveSession(for: "child")?.autoRunEnabled == autoRun)
        _ = try await eventuallyLoadDelegation(
            persistence: fixture.persistence, childSessionId: "child", matching: { $0.phase == .ready }
        )
    }

    @Test func repeatedStartReturnsTheSameChild() async throws {
        let client = makeSelectionClient()
        let fixture = try makeModelSelectionFixture(client: client, project: peerProject())
        defer { fixture.manager.shutdownBackgroundTasks() }

        let target = checkout(of: fixture.manager)
        let first = await fixture.coordinator.startForPeer(peerStart(target: target))
        let second = await fixture.coordinator.startForPeer(peerStart(target: target))
        let otherPeer = await fixture.coordinator.startForPeer(peerStart(peer: "s2", target: target))

        #expect(first == .started(sessionId: "child", state: "starting"))
        guard case .started(let id, _) = second else {
            Issue.record("Expected the same child, got \(second)")
            return
        }
        #expect(id == "child")
        guard case .refused = otherPeer else {
            Issue.record("Expected another peer to be refused, got \(otherPeer)")
            return
        }
        try await waitUntil { !childRequests(client).isEmpty }
        #expect(childRequests(client) == ["prompt:Review the parser."])
        #expect(try await fixture.persistence.children(parentSessionId: "peer:s1").count == 1)
        #expect(try await fixture.persistence.children(parentSessionId: "peer:s2").isEmpty)
    }

    enum TargetKind: CaseIterable {
        case sshProject, folderProject, operationHeld, archived, unknownModel, sessionAlreadyExists
        /// The resolver would match these to the checkout; a peer's path must
        /// name it exactly.
        case pathInsideTheCheckout, branchName
    }

    @Test(arguments: TargetKind.allCases)
    func unsuitableTargetIsRefusedWithAReason(kind: TargetKind) async throws {
        let fixture = try makeModelSelectionFixture(
            client: ACPMockClient(),
            launchModels: [.init(id: "opus", name: "Opus")],
            project: peerProject(host: kind == .sshProject ? "mini" : nil, kind: kind == .folderProject ? .folder : .git),
            worktreeIsListed: kind != .archived,
            admitChild: { _, _ in kind == .operationHeld ? "Another operation holds the worktree." : nil }
        )
        defer { fixture.manager.shutdownBackgroundTasks() }
        if kind == .sessionAlreadyExists { _ = fixture.manager.createSession(id: "child", agentId: "claude") }

        let target: ACPPeerChildTarget = switch kind {
        case .pathInsideTheCheckout: .worktree(path: fixture.manager.worktreePath + "/removed-nested-worktree")
        case .branchName: .worktree(path: "main")
        default: checkout(of: fixture.manager)
        }

        let result = await fixture.coordinator.startForPeer(peerStart(
            target: target,
            modelSelection: kind == .unknownModel ? ACPDelegatedModelSelection(model: "gpt-5.2", reasoning: nil) : nil
        ))

        guard case .refused(let reason) = result else {
            Issue.record("Expected a refusal, got \(result)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(try await fixture.persistence.delegation(childSessionId: "child") == nil)
    }

    @Test func outcomeOfPeerChildReachesOutboxNotAnySession() async throws {
        var lookups: [String] = []
        let fixture = try makeOutcomeFixture(onSessionLookup: { lookups.append($0) })
        try await insertPeerChild(fixture.persistence)

        await fixture.coordinator.childTurnCompleted(completion())

        let entries = try await outbox(fixture.persistence)
        #expect(entries.map(\.messageId) == ["outcome-child-500"])
        #expect(entries.first?.kind == .prompt)
        #expect(entries.first?.prompt == "[alas system] Delegated session child (codex, worktree feature-x) on Studio finished. Its final message:\nParser fixed.")
        #expect(try await fixture.persistence.pendingMessageTargetSessionIds().isEmpty)
        #expect(!lookups.contains("peer:s1"))
    }

    @Test func otherPeerOutcomesNameTheMachine() async throws {
        let fixture = try makeOutcomeFixture()
        try await insertPeerChild(fixture.persistence)

        await fixture.coordinator.childTurnCompleted(completion(result: .failed("boom")))

        let entries = try await outbox(fixture.persistence)
        #expect(entries.first?.prompt == "[alas system] Delegated session child (codex, worktree feature-x, on Studio) failed: boom.")
    }

    @Test func sessionSendFromPeerChildExplainsThatTheFinalMessageIsTheReport() async throws {
        let fixture = try makeOutcomeFixture()
        try await insertPeerChild(fixture.persistence)

        let response = await fixture.coordinator.send(
            origin: .init(sessionId: "child", projectId: "project", worktreeId: "worktree"),
            request: .init(targetSessionId: ACPPeerParent.sentinel(serverId: "s1"), prompt: "Done")
        )

        guard case .error(let message) = response else {
            Issue.record("Expected an error, got \(response)")
            return
        }
        #expect(message.contains("final message is your report"))
        #expect(try await outbox(fixture.persistence).isEmpty)
        #expect(try await fixture.persistence.pendingMessageTargetSessionIds().isEmpty)
    }

    @Test func blockedPeerChildEscalatesThroughOutbox() async throws {
        let fixture = try makeOutcomeFixture(blockedKeys: ["n42"])
        try await insertPeerChild(fixture.persistence)

        await fixture.coordinator.childBlocked(testBlocker())
        await fixture.coordinator.escalateBlockerIfStillBlocked(testBlocker())

        let entries = try await outbox(fixture.persistence)
        #expect(entries.map(\.messageId) == ["blocker-child-n42-notice", "blocker-child-n42"])
        #expect(entries.map(\.kind) == [.notice, .prompt])
    }

    /// The agent acknowledges no model, so the child ends with the reason and
    /// its prompt never runs on the agent's default.
    @Test func unavailableModelFailsChildRatherThanFallingBack() async throws {
        let client = makeSelectionClient()
        client.script(method: "session/set_model") { _ in
            throw JSONRPCError(code: -32602, message: "Unknown model", data: nil)
        }
        let fixture = try makeModelSelectionFixture(client: client, project: peerProject())
        defer { fixture.manager.shutdownBackgroundTasks() }

        _ = await fixture.coordinator.startForPeer(peerStart(
            target: checkout(of: fixture.manager),
            modelSelection: ACPDelegatedModelSelection(model: "opus", reasoning: nil)
        ))

        let record = try await eventuallyLoadDelegation(
            persistence: fixture.persistence, childSessionId: "child", matching: { $0.phase == .failed }
        )
        #expect(record.failureMessage?.contains("did not apply model opus") == true)
        #expect(try await outbox(fixture.persistence).map(\.messageId) == ["outcome-child-failed"])
        #expect(childRequests(client) == ["set_model:opus"])
    }

    /// Sign-in needed or agent not installed: a failure outcome, not a child
    /// sitting idle with its prompt queued.
    @Test func agentThatCannotStartFailsChildThroughOutbox() async throws {
        let client = makeSelectionClient()
        let fixture = try makeModelSelectionFixture(
            client: client, setupEvaluator: { _ in .missing(reason: "Install Claude") }, project: peerProject()
        )
        defer { fixture.manager.shutdownBackgroundTasks() }

        _ = await fixture.coordinator.startForPeer(peerStart(target: checkout(of: fixture.manager)))

        let record = try await eventuallyLoadDelegation(
            persistence: fixture.persistence, childSessionId: "child", matching: { $0.phase == .failed }
        )
        #expect(record.failureMessage == "Install Claude")
        let entries = try await outbox(fixture.persistence)
        #expect(entries.map(\.messageId) == ["outcome-child-failed"])
        #expect(entries.first?.prompt.contains("Install Claude") == true)
        #expect(childRequests(client).isEmpty)
    }

    private let newWorktree = ACPPeerChildTarget.newWorktree(branch: "fix/parser", base: "main", expectedBaseSHA: "abc")

    /// Which stale bases there are is `PeerWorktreeBaseTests`' business: any
    /// reason fails the child, before a worktree exists.
    @Test func expectedBaseMismatchFailsChild() async throws {
        var bases: [String] = []
        let client = makeSelectionClient()
        let fixture = try makeModelSelectionFixture(
            client: client, project: peerProject(), peerWorktreeBase: .failure(.init(message: "main is stale")),
            onPeerWorktree: { bases.append($0) }
        )
        defer { fixture.manager.shutdownBackgroundTasks() }

        let result = await fixture.coordinator.startForPeer(peerStart(target: newWorktree))

        #expect(result == .started(sessionId: "child", state: "creating_worktree"))
        let record = try await eventuallyLoadDelegation(
            persistence: fixture.persistence, childSessionId: "child", matching: { $0.phase == .failed }
        )
        #expect(record.failureMessage == "main is stale")
        #expect(bases.isEmpty)
        #expect(try await outbox(fixture.persistence).map(\.messageId) == ["outcome-child-failed"])
        #expect(childRequests(client).isEmpty)
    }

    @Test func newWorktreeBranchesFromTheResolvedBase() async throws {
        var bases: [String] = []
        let client = makeSelectionClient()
        let fixture = try makeModelSelectionFixture(
            client: client, project: peerProject(), onPeerWorktree: { bases.append($0) }
        )
        defer { fixture.manager.shutdownBackgroundTasks() }

        _ = await fixture.coordinator.startForPeer(peerStart(target: newWorktree))

        try await waitUntil { childRequests(client) == ["prompt:Review the parser."] }
        #expect(bases == ["origin/main"])
        #expect(try await outbox(fixture.persistence).isEmpty)
    }

    @Test func skippedHookProducesANotice() async throws {
        let client = makeSelectionClient()
        let fixture = try makeModelSelectionFixture(client: client, project: peerProject(), skipsRepoHook: true)
        defer { fixture.manager.shutdownBackgroundTasks() }

        _ = await fixture.coordinator.startForPeer(peerStart(target: newWorktree))

        try await waitUntil { childRequests(client) == ["prompt:Review the parser."] }
        let entries = try await outbox(fixture.persistence)
        #expect(entries.map(\.kind) == [.notice])
        #expect(entries.first?.prompt.contains("hook") == true)
        #expect(entries.first?.prompt.contains("Mini") == true)
    }

    private let parentOrigin = ACPOrchestrationSessionOrigin(sessionId: "parent", projectId: "project", worktreeId: "worktree")

    /// A ready child with a live session whose transcript holds `messages`.
    private func insertLiveChild(_ fixture: OutcomeFixture, messages: [ACPMessage]) async throws -> ACPSession {
        try await insertReadyChild(fixture.persistence)
        let session = fixture.manager.createSession(id: "child", agentId: "codex", autoRunDefault: false)
        session.transcript.messages = messages
        return session
    }

    private func decoded<T: Decodable>(_ type: T.Type, _ response: AlasCLIResponse) throws -> T {
        guard case .text(let lines) = response, let line = lines.first else {
            Issue.record("Expected a JSON response, got \(response)")
            throw CancellationError()
        }
        return try JSONDecoder().decode(T.self, from: Data(line.utf8))
    }

    @Test("a parent reads and searches its child's transcript; a sibling cannot")
    func readAndSearchChildTranscript() async throws {
        let fixture = try makeOutcomeFixture()
        _ = try await insertLiveChild(fixture, messages: [
            .user(id: UUID(), text: "Fix the parser", attachments: []),
            .agent(id: UUID(), StreamingText("Parser fixed.")),
        ])

        let read = try decoded(ACPOrchestrationReadResponse.self, await fixture.coordinator.perform(
            origin: parentOrigin, .read(.init(targetSessionId: "child"))
        ))
        let search = try decoded(ACPOrchestrationSearchResponse.self, await fixture.coordinator.perform(
            origin: parentOrigin, .search(.init(query: "PARSER", limit: 1))
        ))
        let sibling = await fixture.coordinator.perform(
            origin: .init(sessionId: "sibling", projectId: "project", worktreeId: "worktree"),
            .read(.init(targetSessionId: "child"))
        )

        #expect(read.entries.map(\.text) == ["Fix the parser", "Parser fixed."])
        #expect(search.matches.map(\.sessionId) == ["child"])
        #expect(search.truncated)
        #expect(sibling == .error("Only a direct parent, child, or this session's fork transcript can be read."))
    }

    @Test("only the recorded source reads a fork, including archived and evicted forks",
          arguments: [false, true], [false, true])
    func sourceReadsForkTranscript(archive: Bool, checkout: Bool) async throws {
        let origin = checkout
            ? ACPOrchestrationSessionOrigin(sessionId: "parent", projectId: "checkout-owner", worktreeId: "checkout-owner")
            : parentOrigin
        let fixture = try makeOutcomeFixture(readScope: origin)
        let source = try #require(fixture.manager.liveSession(for: "parent"))
        let message = ACPMessage.agent(id: UUID(), StreamingText("Inherited answer"))
        source.transcript.appendMessage(message)
        fixture.manager.persistTrailingMessages(source, fromIndex: 0)
        await fixture.manager.flushAllPersistence()
        let fork = try await fixture.manager.createFork(
            sourceSessionID: source.id, boundary: .init(stableID: message.stableId, kind: .agent),
            targetAgentID: "claude", autoRunDefault: false
        )
        fork.transcript.appendMessage(.agent(id: UUID(), StreamingText("New finding")))
        fixture.manager.persistTrailingMessages(fork, fromIndex: 1)
        fixture.manager.setArchived(id: fork.id, archived: archive)
        await fixture.manager.flushAllPersistence()
        fixture.manager.closeSession(id: fork.id)

        let response = await fixture.coordinator.read(
            origin: origin, request: .init(targetSessionId: fork.id, offset: 1)
        )
        let page = try decoded(ACPOrchestrationReadResponse.self, response)
        #expect(page.entries.map(\.text) == ["New finding"])
        for deniedOrigin in [
            ACPOrchestrationSessionOrigin(sessionId: "sibling", projectId: origin.projectId, worktreeId: origin.worktreeId),
            ACPOrchestrationSessionOrigin(sessionId: "parent", projectId: "other", worktreeId: origin.worktreeId),
        ] {
            let denied = await fixture.coordinator.read(origin: deniedOrigin, request: .init(targetSessionId: fork.id))
            #expect(denied == .error("Only a direct parent, child, or this session's fork transcript can be read."))
        }
        let send = await fixture.coordinator.send(origin: origin, request: .init(targetSessionId: fork.id, prompt: "Run this"))
        guard case .error = send else { Issue.record("Fork read access must not grant send access")
        return }
    }

    @Test("a session reads another session only once the user attaches it to one of its prompts, then lets it go")
    func readUserAttachedSession() async throws {
        var releases = 0
        let fixture = try makeOutcomeFixture(releaseReferencedSession: { releases += 1 })
        let other = fixture.manager.createSession(id: "other", agentId: "codex", autoRunDefault: false)
        other.transcript.messages = [.user(id: UUID(), text: "Plan the release", attachments: [])]
        let read: () async -> AlasCLIResponse = {
            await fixture.coordinator.perform(origin: self.parentOrigin, .read(.init(targetSessionId: "other")))
        }

        #expect(await read() == .error("Only a direct parent, child, or this session's fork transcript can be read."))

        fixture.manager.liveSession(for: "parent")?.transcript.messages = [.user(
            id: UUID(), text: "Use @Release ",
            attachments: [.init(uri: ACPSessionReference.uri(sessionId: "other"), name: "Release")]
        )]
        let attached = try decoded(ACPOrchestrationReadResponse.self, await read())

        #expect(attached.entries.map(\.text) == ["Plan the release"])
        #expect(releases == 1)
    }

    @Test("session_wait returns once a running child settles, or reports the timeout")
    func waitForRunningChild() async throws {
        var child: ACPSession?
        // The child's turn ends while the wait is paused between polls.
        let fixture = try makeOutcomeFixture(pause: { _ in child?.transcript.streamingState = .idle })
        child = try await insertLiveChild(fixture, messages: [.agent(id: UUID(), StreamingText("Parser fixed."))])

        child?.transcript.streamingState = .streaming
        let timedOut = try decoded(ACPOrchestrationWaitResponse.self, await fixture.coordinator.perform(
            origin: parentOrigin, .wait(.init(targetSessionIds: ["child"], timeoutMillis: 0))
        ))
        let settled = try decoded(ACPOrchestrationWaitResponse.self, await fixture.coordinator.perform(
            origin: parentOrigin, .wait(.init(targetSessionIds: ["child", "child"]))
        ))

        #expect(timedOut.timedOut)
        #expect(timedOut.sessions.map(\.state) == ["running"])
        #expect(!settled.timedOut)
        #expect(settled.sessions == [.init(
            sessionId: "child", state: "idle", settled: true, lastAgentText: "Parser fixed.", failure: nil
        )])
    }

    @Test("a child that answered with a plan reports it to session_wait and session_read")
    func waitAndReadReportChildPlan() async throws {
        let fixture = try makeOutcomeFixture()
        let plan = ACPPlanDocument(planId: "item_1", kind: .markdown, markdown: "# Plan\n- parse", file: nil)
        _ = try await insertLiveChild(fixture, messages: [
            .user(id: UUID(), text: "Plan the parser fix", attachments: []),
            .agent(id: UUID(), StreamingText("Here is the plan.")),
            .planDocument(id: UUID(), plan),
        ])

        let wait = try decoded(ACPOrchestrationWaitResponse.self, await fixture.coordinator.perform(
            origin: parentOrigin, .wait(.init(targetSessionIds: ["child"], timeoutMillis: 0))
        ))
        let read = try decoded(ACPOrchestrationReadResponse.self, await fixture.coordinator.perform(
            origin: parentOrigin, .read(.init(targetSessionId: "child"))
        ))

        #expect(wait.sessions.map(\.settled) == [true])
        #expect(wait.sessions.first?.lastAgentText == "# Plan\n- parse")
        #expect(read.entries.map(\.text) == ["Plan the parser fix", "Here is the plan.", "# Plan\n- parse"])
    }

    @Test("only a direct parent may wait on or interrupt a session")
    func childControlRequiresParent() async throws {
        let fixture = try makeOutcomeFixture()
        _ = try await insertLiveChild(fixture, messages: [])
        let childOrigin = ACPOrchestrationSessionOrigin(sessionId: "child", projectId: "project", worktreeId: "worktree")

        let interruptParent = await fixture.coordinator.perform(origin: childOrigin, .interrupt(targetSessionId: "parent"))
        let waitParent = await fixture.coordinator.perform(origin: childOrigin, .wait(.init(targetSessionIds: ["parent"])))
        let idleChild = try decoded(ACPOrchestrationInterruptResponse.self, await fixture.coordinator.perform(
            origin: parentOrigin, .interrupt(targetSessionId: "child")
        ))

        #expect(interruptParent == .error("Only a direct child session can be interrupted."))
        #expect(waitParent == .error("Only direct child sessions can be waited on: parent"))
        #expect(idleChild == .init(sessionId: "child", cancelRequested: false))
    }

    @Test("a ready child with no live session and no reachable store is not reported settled")
    func waitKeepsUnreachableChildUnsettled() async throws {
        let fixture = try makeOutcomeFixture()
        try await insertReadyChild(fixture.persistence)

        let response = try decoded(ACPOrchestrationWaitResponse.self, await fixture.coordinator.perform(
            origin: parentOrigin, .wait(.init(targetSessionIds: ["child"], timeoutMillis: 0))
        ))

        #expect(response.timedOut)
        #expect(response.sessions.map(\.settled) == [false])
    }

    @Test("a settled child that is not live here reports its stored result")
    func waitLoadsStoredResultOfNonLiveChild() async throws {
        let fixture = try makeOutcomeFixture()
        try await insertReadyChild(fixture.persistence)
        let store = try ACPSessionStore(path: fixture.sessionPath)
        try store.upsertSession(.init(id: "child", agentId: "codex", title: "Child",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let message: ACPMessage = .agent(id: UUID(), StreamingText("Parser fixed."))
        try store.appendMessage(sessionId: "child", id: "m0", kind: message.kind,
                                seq: 0, payload: try ACPMessageCodec.encode(message), createdAt: 1)

        let response = try decoded(ACPOrchestrationWaitResponse.self, await fixture.coordinator.perform(
            origin: parentOrigin, .wait(.init(targetSessionIds: ["child"], timeoutMillis: 0))
        ))

        #expect(response.sessions.map(\.settled) == [true])
        #expect(response.sessions.first?.lastAgentText == "Parser fixed.")
    }

    /// A JSON-RPC failure ends here too, so it needs no incident row to be reported.
    @Test func waitReportsLiveTurnFailure() async throws {
        let fixture = try makeOutcomeFixture()
        let child = try await insertLiveChild(fixture, messages: [.agent(id: UUID(), StreamingText("Partial."))])
        child.turnFailure = "prompt failed: boom"

        let response = try decoded(ACPOrchestrationWaitResponse.self, await fixture.coordinator.perform(
            origin: parentOrigin, .wait(.init(targetSessionIds: ["child"], timeoutMillis: 0))
        ))

        #expect(response.sessions.first?.settled == true)
        #expect(response.sessions.first?.failure == "prompt failed: boom")
    }

    /// A failure is rewritten only when a turn ends. While the child runs it
    /// describes the last turn, and a parent reading it would give up on this one.
    @Test(arguments: [false, true])
    func waitReportsNoFailureWhileTheChildRuns(fromRow: Bool) async throws {
        let fixture = try makeOutcomeFixture()
        let row = ACPMessage.failureIncident(id: UUID(), try .fixture(title: "Model overloaded", endedTurn: true))
        let child = try await insertLiveChild(fixture, messages: fromRow ? [row] : [])
        if !fromRow { child.turnFailure = "prompt failed: boom" }
        child.transcript.streamingState = .streaming

        let response = try decoded(ACPOrchestrationWaitResponse.self, await fixture.coordinator.perform(
            origin: parentOrigin, .wait(.init(targetSessionIds: ["child"], timeoutMillis: 0))
        ))

        #expect(response.sessions.first?.settled == false)
        #expect(response.sessions.first?.failure == nil)
    }

    @Test func waitReportsStoredTurnFailure() async throws {
        let fixture = try makeOutcomeFixture()
        try await insertReadyChild(fixture.persistence)
        let store = try ACPSessionStore(path: fixture.sessionPath)
        try store.upsertSession(.init(id: "child", agentId: "codex", title: "Child",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let messages: [ACPMessage] = [
            .user(id: UUID(), text: "Fix it", attachments: []),
            .failureIncident(id: UUID(), try .fixture(title: "Model overloaded", endedTurn: true)),
        ]
        for (seq, message) in messages.enumerated() {
            try store.appendMessage(sessionId: "child", id: "m\(seq)", kind: message.kind,
                                    seq: Int64(seq), payload: try ACPMessageCodec.encode(message), createdAt: 1)
        }

        let response = try decoded(ACPOrchestrationWaitResponse.self, await fixture.coordinator.perform(
            origin: parentOrigin, .wait(.init(targetSessionIds: ["child"], timeoutMillis: 0))
        ))

        #expect(response.sessions.first?.settled == true)
        #expect(response.sessions.first?.failure == "Model overloaded")
    }

    enum RetriedHead: Sendable {
        case resume, wake
    }

    private func waitFailure(_ fixture: OutcomeFixture) async throws -> String? {
        try decoded(ACPOrchestrationWaitResponse.self, await fixture.coordinator.perform(
            origin: parentOrigin, .wait(.init(targetSessionIds: ["child"], timeoutMillis: 0))
        )).sessions.first?.failure
    }

    /// A retried item or a wake records no user row, so only the retry's own
    /// result can close the failure. A cancelled retry says nothing about it.
    @Test(.timeLimit(.minutes(1)), arguments: [
        (RetriedHead.resume, #"{"stopReason":"end_turn"}"#, String?.none),
        (.wake, #"{"stopReason":"end_turn"}"#, nil),
        (.wake, #"{"stopReason":"max_tokens"}"#, nil),
        (.wake, #"{"stopReason":"end_turn","_meta":{"sessionFailure":{"version":1,"id":"t:limit","revision":1,"severity":"error","title":"Limit","kind":"quota_exhausted"}}}"#, nil),
        (.wake, #"{"stopReason":"cancelled"}"#, "Model overloaded"),
        (.wake, #"{"stopReason":"end_turn","_meta":{"sessionFailure":{"version":1,"id":"t:again","revision":1,"severity":"error","title":"Still overloaded"}}}"#, "Still overloaded"),
    ])
    func waitFollowsARetriedTurn(head: RetriedHead, retriedResponse: String, expected: String?) async throws {
        let fixture = try makeOutcomeFixture()
        let session = try await insertLiveChild(fixture, messages: [])
        let store = try ACPSessionStore(path: fixture.sessionPath)
        try store.upsertSession(.init(id: "child", agentId: "codex", title: "Child",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let mock = ACPMockClient()
        mock.script(method: "initialize") { _ in
            Data(#"{"protocolVersion":1,"_meta":{"sessionFailure":{"version":1}}}"#.utf8)
        }
        let failed = try JSONSerialization.data(withJSONObject: ["stopReason": "end_turn", "_meta": ["sessionFailure": [
            "version": 1, "id": "t:error", "revision": 1, "severity": "error", "title": "Model overloaded",
        ] as [String: Any]]] as [String: Any])
        mock.script(method: "session/prompt") { _ in failed }
        let connection = ACPConnection(client: mock)
        try await connection.initialize()
        session.sessionFailure = .init()
        session.agentState = .ready
        var completions: [ACPTurnCompletion] = []
        let runner = ACPSessionRunner(
            session: session, connection: connection, store: store, sessionId: "child",
            worktreePath: FileManager.default.temporaryDirectory.path,
            onTurnCompleted: { completions.append($0) }
        )
        runner.start()
        defer { runner.stop() }
        switch head {
        case .resume:
            let limit = ACPUsageLimit(detectedAt: Date(), resetSource: .unknown, probeAttempt: 0, resettable: true)
            session.usageLimit = limit
            session.upsertUsageLimitResume(limit: limit, scheduledAt: Date().addingTimeInterval(-1))
        case .wake:
            session.transcript.streamingState = .awaitingPermission
            session.applyBackgroundTask(.init(sessionUpdate: "async_task_state_update", asyncTaskId: "job",
                state: "completed"), ownerSessionId: "child")
            await runner.reconcileBackgroundTasks(adapterSurvived: true, previousTaskIds: [])
            await runner.flushPersistence()
            session.transcript.streamingState = .idle
        }
        let item = try #require(session.queue.first)
        runner.flushQueueIfIdle()
        try await waitUntil { !completions.isEmpty }
        await runner.flushPersistence()
        #expect(try await waitFailure(fixture) == "Model overloaded")

        let retried = Data(retriedResponse.utf8)
        mock.script(method: "session/prompt") { _ in retried }
        runner.forceSendQueuedItem(id: item.id)
        try await waitUntil { completions.count == 2 }
        await runner.flushPersistence()

        #expect(try await waitFailure(fixture) == expected)
        let reloaded = try makeOutcomeFixture(sessionPath: fixture.sessionPath)
        try await insertReadyChild(reloaded.persistence)
        #expect(try await waitFailure(reloaded) == expected)
        #expect(reloaded.manager.liveSession(for: "child")?.transcript.messages.contains { $0.kind == "system" } == true)
    }

    @Test("interrupting a running child this instance does not drive reports no cancellation")
    func interruptWithoutWriterLease() async throws {
        let fixture = try makeOutcomeFixture()
        let child = try await insertLiveChild(fixture, messages: [])
        child.transcript.streamingState = .streaming

        let response = try decoded(ACPOrchestrationInterruptResponse.self, await fixture.coordinator.perform(
            origin: parentOrigin, .interrupt(targetSessionId: "child")
        ))

        #expect(response == .init(sessionId: "child", cancelRequested: false))
    }

    private func eventuallyLoadDelegation(
        persistence: ACPOrchestrationPersistence,
        childSessionId: String,
        matching predicate: (ACPDelegationRecord) -> Bool
    ) async throws -> ACPDelegationRecord {
        try await waitUntil {
            (try? await persistence.delegation(childSessionId: childSessionId)).flatMap { $0 }.map(predicate) == true
        }
        return try #require(try await persistence.delegation(childSessionId: childSessionId))
    }

    /// The suite's one polling helper. A deadline, not a fixed number of
    /// short polls: a child start that attaches a session can take well over
    /// half a second on loaded CI.
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await !condition() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func testBlocker(_ key: String = "n42") -> ACPChildBlocker {
        .init(sessionId: "child", requestKey: key, kind: .permission, summary: "Write file")
    }

    @Test("a blocked child notices its parent immediately")
    func blockedChildNoticesParent() async throws {
        let fixture = try makeOutcomeFixture()
        try await insertReadyChild(fixture.persistence)

        await fixture.coordinator.childBlocked(testBlocker())

        let pending = try await fixture.persistence.pendingMessages(targetSessionId: "parent")
        #expect(pending.count == 1)
        #expect(pending.first?.kind == .notice)
        #expect(pending.first?.id == "blocker-child-n42-notice")
        #expect(pending.first?.prompt.contains("waiting for a human decision") == true)
    }

    @Test("a still-blocked child escalates to a wake")
    func stillBlockedChildEscalates() async throws {
        let fixture = try makeOutcomeFixture(blockedKeys: ["n42"])
        try await insertReadyChild(fixture.persistence)
        await fixture.coordinator.childBlocked(testBlocker())

        await fixture.coordinator.escalateBlockerIfStillBlocked(testBlocker())

        let pending = try await fixture.persistence.pendingMessages(targetSessionId: "parent")
        #expect(pending.map(\.kind) == [.notice, .prompt])
        #expect(pending.last?.id == "blocker-child-n42")
        #expect(pending.last?.prompt.contains("cannot approve") == true)
    }

    @Test("a resolved block never escalates")
    func resolvedBlockDoesNotEscalate() async throws {
        let fixture = try makeOutcomeFixture(blockedKeys: [])
        try await insertReadyChild(fixture.persistence)
        await fixture.coordinator.childBlocked(testBlocker())

        await fixture.coordinator.escalateBlockerIfStillBlocked(testBlocker())

        let pending = try await fixture.persistence.pendingMessages(targetSessionId: "parent")
        #expect(pending.map(\.kind) == [.notice])
    }

    @Test("being blocked on a different request does not escalate the first")
    func differentBlockDoesNotEscalate() async throws {
        let fixture = try makeOutcomeFixture(blockedKeys: ["n99"])
        try await insertReadyChild(fixture.persistence)
        await fixture.coordinator.childBlocked(testBlocker())

        await fixture.coordinator.escalateBlockerIfStillBlocked(testBlocker())

        #expect(try await fixture.persistence.pendingMessages(targetSessionId: "parent").map(\.kind) == [.notice])
    }

    @Test("repeated detection of the same block adds nothing")
    func repeatedBlockIsIdempotent() async throws {
        let fixture = try makeOutcomeFixture()
        try await insertReadyChild(fixture.persistence)

        await fixture.coordinator.childBlocked(testBlocker())
        await fixture.coordinator.childBlocked(testBlocker())

        #expect(try await fixture.persistence.pendingMessages(targetSessionId: "parent").count == 1)
    }

    @Test("a session with no delegation record produces no blocker outcome")
    func nonDelegatedBlockIsIgnored() async throws {
        let fixture = try makeOutcomeFixture()

        await fixture.coordinator.childBlocked(testBlocker())

        #expect(try await fixture.persistence.pendingMessageTargetSessionIds().isEmpty)
    }

    @Test("a terminal child produces no blocker outcome")
    func terminalChildBlockIsIgnored() async throws {
        let fixture = try makeOutcomeFixture()
        try await insertReadyChild(fixture.persistence)
        try await fixture.persistence.updatePhase(
            childSessionId: "child", phase: .closed, failureMessage: nil, updatedAt: 200
        )

        await fixture.coordinator.childBlocked(testBlocker())

        #expect(try await fixture.persistence.pendingMessages(targetSessionId: "parent").isEmpty)
    }

    @Test("escalation disabled by config notices but never wakes")
    func escalationDisabledNoticesOnly() async throws {
        let fixture = try makeOutcomeFixture(blockedKeys: ["n42"], escalationSeconds: 0)
        try await insertReadyChild(fixture.persistence)

        await fixture.coordinator.childBlocked(testBlocker())
        await fixture.coordinator.escalateBlockerIfStillBlocked(testBlocker())

        #expect(try await fixture.persistence.pendingMessages(targetSessionId: "parent").map(\.kind) == [.notice])
    }

    @Test("a positive delay schedules exactly one re-check; a zero delay schedules none")
    func schedulesTheReCheckOnlyWhenEnabled() async throws {
        // Proves the scheduling wiring directly, rather than only inferring it
        // from every other test's fixture leaving the default no-op scheduler
        // in place and simply not hanging.
        final class ScheduleRecorder: @unchecked Sendable {
            var calls: [Int] = []
        }
        let recorder = ScheduleRecorder()
        let fixture = try makeOutcomeFixture(
            escalationSeconds: 30,
            scheduleEscalationCheck: { delay, _ in recorder.calls.append(delay) }
        )
        try await insertReadyChild(fixture.persistence)
        await fixture.coordinator.childBlocked(testBlocker())
        #expect(recorder.calls == [30])

        let disabledFixture = try makeOutcomeFixture(
            escalationSeconds: 0,
            scheduleEscalationCheck: { delay, _ in recorder.calls.append(delay) }
        )
        try await insertReadyChild(disabledFixture.persistence)
        await disabledFixture.coordinator.childBlocked(testBlocker())
        #expect(recorder.calls == [30])
    }

    // MARK: Delegating to a peer

    @MainActor
    private final class FakePeers: ACPDelegationPeers {
        var peers: [ACPDelegationPeerInfo]
        var discovery: Result<ACPPeerDiscovery, ACPPeerError>
        private(set) var discoverCalls: [(serverId: String, repository: String?)] = []
        /// Answers `start` in order; once used up, the child started.
        var startResults: [Result<ACPPeerStartReply, ACPPeerError>] = []
        var onStart: ((ACPPeerChildStartRequest) async -> Void)?
        private(set) var startCalls: [ACPPeerChildStartRequest] = []
        var sendResult: Result<Void, ACPPeerError> = .success(())
        private(set) var sendCalls: [(sessionID: String, prompt: String)] = []
        var readResult: Result<Data, ACPPeerError> = .success(Data("{\"from\":\"peer\"}".utf8))
        private(set) var readCalls: [(sessionID: String, offset: Int?, limit: Int?, maxChars: Int?)] = []
        var interruptResult: Result<Bool, ACPPeerError> = .success(true)
        private(set) var interruptCalls: [String] = []
        /// Answers `status`. Suspended on `statusGate` first while one is set.
        var statusAnswer: (_ serverId: String, _ ids: [String]) -> Result<Data, ACPPeerError> = { _, ids in
            FakePeers.status(ids, state: "idle", settled: true)
        }
        var statusGate: AsyncStream<Void>?
        private(set) var statusCalls: [(serverId: String, ids: [String])] = []
        var onOutboxChanged: (@MainActor (String) -> Void)?
        var onAvailabilityChanged: (@MainActor (String) -> Void)?

        init(peers: [ACPDelegationPeerInfo], discovery: Result<ACPPeerDiscovery, ACPPeerError> = .success(FakePeers.offer())) {
            self.peers = peers
            self.discovery = discovery
        }

        static func status(_ ids: [String], state: String, settled: Bool) -> Result<Data, ACPPeerError> {
            .success(try! JSONEncoder().encode(ACPOrchestrationWaitResponse(
                sessions: ids.map { .init(sessionId: $0, state: state, settled: settled, lastAgentText: "text", failure: nil) },
                timedOut: !settled
            )))
        }

        static func offer(projects: [String] = ["alas"], access: String = "autoRun") -> ACPPeerDiscovery {
            ACPPeerDiscovery(
                access: access,
                projects: projects.map { .init(id: "id-\($0)", name: $0) },
                worktrees: projects.flatMap { name in
                    [
                        ACPPeerDiscovery.Worktree(projectID: "id-\(name)", path: "/Users/m/\(name)", branch: "main", isArchived: false),
                        ACPPeerDiscovery.Worktree(projectID: "id-\(name)", path: "/Users/m/\(name)-old", branch: "old", isArchived: true),
                    ]
                },
                agents: [
                    .init(id: "codex", name: "Codex", isDefault: true, unavailableProjectIDs: []),
                    .init(id: "claude", name: "Claude", isDefault: false, unavailableProjectIDs: projects.map { "id-\($0)" }),
                ]
            )
        }

        func discover(serverId: String, repository: String?) async -> Result<ACPPeerDiscovery, ACPPeerError> {
            discoverCalls.append((serverId, repository))
            return discovery
        }
        func start(serverId: String, _ start: ACPPeerChildStartRequest) async -> Result<ACPPeerStartReply, ACPPeerError> {
            startCalls.append(start)
            await onStart?(start)
            guard !startResults.isEmpty else { return .success(.init(sessionID: start.childID, state: "starting")) }
            return startResults.removeFirst()
        }
        func send(serverId: String, sessionID: String, prompt: String) async -> Result<Void, ACPPeerError> {
            sendCalls.append((sessionID, prompt))
            return sendResult
        }
        func read(serverId: String, sessionID: String, offset: Int?, limit: Int?, maxChars: Int?) async -> Result<Data, ACPPeerError> {
            readCalls.append((sessionID, offset, limit, maxChars))
            return readResult
        }
        func status(serverId: String, sessionIDs: [String]) async -> Result<Data, ACPPeerError> {
            statusCalls.append((serverId, sessionIDs))
            if let statusGate { for await _ in statusGate { break } }
            return statusAnswer(serverId, sessionIDs)
        }
        func interrupt(serverId: String, sessionID: String) async -> Result<Bool, ACPPeerError> {
            interruptCalls.append(sessionID)
            return interruptResult
        }
        func outbox(serverId: String, after: Int64) async -> Result<ACPPeerOutboxPage, ACPPeerError> { .failure(.notFound) }
    }

    /// Moves on every pause, so a wait that never settles still ends.
    private final class TestClock {
        var millis: Int64 = 1_000
        var step: Int64 = 250
    }

    private func insertRemoteChild(
        _ persistence: ACPOrchestrationPersistence, id: String = "child", parent: String = "parent",
        server: String = "srv-1", phase: ACPDelegationPhase = .ready
    ) async throws {
        try await persistence.insert(ACPDelegationRecord(
            childSessionId: id, parentSessionId: parent, projectId: "project", parentWorktreeId: "worktree",
            agentId: "codex", worktreeRequest: .current(worktreeId: "worktree"), phase: phase,
            createdAt: 1, updatedAt: 1, peerServerId: server
        ))
    }

    private func phase(_ persistence: ACPOrchestrationPersistence, _ id: String = "child") async throws -> ACPDelegationPhase? {
        try await persistence.delegation(childSessionId: id)?.phase
    }

    private static func peer(
        _ name: String, id: String, state: ACPDelegationPeerState = .online, supportsDelegation: Bool = true
    ) -> ACPDelegationPeerInfo {
        .init(name: name, serverId: id, state: state, supportsDelegation: supportsDelegation)
    }

    private static let peerOrigin = ACPOrchestrationSessionOrigin(sessionId: "parent", projectId: "project", worktreeId: "worktree")

    private func peerCreate(
        _ fixture: (coordinator: ACPSessionOrchestrationCoordinator, persistence: ACPOrchestrationPersistence, manager: ACPSessionManager),
        peer: String = "mini", project: String? = nil, worktree: ACPDelegatedSessionWorktreeTarget = .new(branch: "fix", base: "main")
    ) async -> AlasCLIResponse {
        await fixture.coordinator.create(
            origin: Self.peerOrigin,
            request: .init(prompt: "Do it", agentId: nil, worktree: worktree, peer: peer, project: project)
        )
    }

    private func errorMessage(_ response: AlasCLIResponse) -> String {
        guard case .error(let message) = response else { return "not an error: \(response)" }
        return message
    }

    @Test("a peer with the implicit current worktree is refused before the peer is contacted")
    func peerWithImplicitWorktreeIsAnError() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        let fixture = try makeModelSelectionFixture(client: makeSelectionClient(), peers: peers)

        let message = errorMessage(await peerCreate(fixture, worktree: .current))

        #expect(message.contains("--worktree") && message.contains("--new-worktree"))
        #expect(peers.discoverCalls.isEmpty)
    }

    @Test("two peers sharing a name are listed with their server ids")
    func ambiguousPeerNameListsServerIds() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1"), Self.peer("mini", id: "srv-2")])
        let fixture = try makeModelSelectionFixture(client: makeSelectionClient(), peers: peers)

        let message = errorMessage(await peerCreate(fixture))

        #expect(message.contains("srv-1") && message.contains("srv-2"))
        #expect(peers.discoverCalls.isEmpty)
    }

    @Test("a server id wins over a name, and an unknown peer lists the paired ones")
    func unknownPeerListsPeers() async throws {
        let peers = FakePeers(peers: [Self.peer("srv-2", id: "srv-1"), Self.peer("studio", id: "srv-2")])
        let fixture = try makeModelSelectionFixture(client: makeSelectionClient(), peers: peers)

        let unknown = errorMessage(await peerCreate(fixture, peer: "nope"))
        #expect(unknown.contains("srv-2") && unknown.contains("studio") && unknown.contains("srv-1"))

        _ = await peerCreate(fixture, peer: "srv-2")
        #expect(peers.discoverCalls.map(\.serverId) == ["srv-2"])

        let none = try makeModelSelectionFixture(client: makeSelectionClient(), peers: nil)
        #expect(errorMessage(await peerCreate(none)).contains("No paired Macs"))
    }

    @Test("agent_list shows the paired Macs without calling any of them")
    func agentListAddsPeersWithoutCallingThem() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1", state: .offline, supportsDelegation: false)])
        let fixture = try makeModelSelectionFixture(client: makeSelectionClient(), peers: peers)

        let response = await fixture.coordinator.discoverAgents(origin: Self.peerOrigin, worktree: nil, peer: nil)

        let decoded = try decodeAgentList(response)
        #expect(decoded.peers == [.init(serverId: "srv-1", name: "mini", state: "offline", supportsDelegation: false)])
        #expect(decoded.peer == nil)
        #expect(peers.discoverCalls.isEmpty)
    }

    @Test("agent_list for a peer sends the parent's origin and reports the matching projects")
    func agentListForPeerSendsParentOriginAsRepository() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        let fixture = try makeModelSelectionFixture(client: makeSelectionClient(), peers: peers)

        let decoded = try decodeAgentList(await fixture.coordinator.discoverAgents(origin: Self.peerOrigin, worktree: nil, peer: "mini"))

        #expect(peers.discoverCalls.map(\.repository) == ["github.com/o/r"])
        #expect(decoded.peers == nil)
        #expect(decoded.peer == .init(serverId: "srv-1", name: "mini", access: "autoRun", projects: [
            .init(id: "id-alas", name: "alas", worktrees: [.init(name: "alas", branch: "main", path: "/Users/m/alas")]),
        ]))
        #expect(decoded.agents.map(\.id) == ["codex", "claude"])
        #expect(decoded.agents.map(\.available) == [true, false])
    }

    @Test("a peer that cannot be used is named with its state and gets no request", arguments: [
        (ACPDelegationPeerState.offline, false, "cannot be reached"),
        (.unverified, false, "cannot be reached"),
        (.offline, true, "cannot be reached"),
        (.incompatible, false, "Update Alas"),
        (.online, false, "Update Alas"),
    ])
    func unusablePeerIsReportedWithoutARequest(state: ACPDelegationPeerState, supports: Bool, wording: String) async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1", state: state, supportsDelegation: supports)])
        let fixture = try makeModelSelectionFixture(client: makeSelectionClient(), peers: peers)

        let listed = errorMessage(await fixture.coordinator.discoverAgents(origin: Self.peerOrigin, worktree: nil, peer: "mini"))
        let created = errorMessage(await peerCreate(fixture))

        for message in [listed, created] {
            #expect(message.contains("mini") && message.contains(wording))
            if state != .online { #expect(message.contains(state.rawValue)) }
        }
        #expect(peers.discoverCalls.isEmpty)
    }

    @Test("several matching projects need --project, which picks by id or name")
    func multipleMatchingProjectsRequireProject() async throws {
        let peers = FakePeers(
            peers: [Self.peer("mini", id: "srv-1")], discovery: .success(FakePeers.offer(projects: ["alas", "alas-fork"]))
        )
        let fixture = try makeModelSelectionFixture(client: makeSelectionClient(), peers: peers, makeID: { UUID().uuidString })

        let message = errorMessage(await peerCreate(fixture))
        #expect(message.contains("alas") && message.contains("alas-fork") && message.contains("--project"))

        _ = await peerCreate(fixture, project: "id-alas-fork")
        #expect(peers.startCalls.last?.target == .newWorktree(projectID: "id-alas-fork", branch: "fix", base: "main", expectedBaseSHA: nil))
        _ = await peerCreate(fixture, project: "alas")
        #expect(peers.startCalls.last?.target == .newWorktree(projectID: "id-alas", branch: "fix", base: "main", expectedBaseSHA: nil))
        #expect(errorMessage(await peerCreate(fixture, project: "other")).contains("alas-fork"))
    }

    @Test("a parent without an origin remote needs --project")
    func parentWithoutOriginNeedsProject() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        let fixture = try makeModelSelectionFixture(client: makeSelectionClient(), peers: peers, originRemote: nil)

        #expect(errorMessage(await peerCreate(fixture)).contains("--project"))
        _ = await peerCreate(fixture, project: "alas")
        #expect(peers.startCalls.count == 1)
        #expect(peers.discoverCalls.map(\.repository) == [nil, nil])
    }

    @Test("--worktree is resolved against the peer's worktrees, and --project needs --peer")
    func peerWorktreeAndProjectRules() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        let fixture = try makeModelSelectionFixture(client: makeSelectionClient(), peers: peers)

        _ = await peerCreate(fixture, worktree: .existing(worktreeId: "main"))
        #expect(peers.startCalls.last?.target == .worktree(projectID: "id-alas", path: "/Users/m/alas"))
        let missing = errorMessage(await peerCreate(fixture, worktree: .existing(worktreeId: "old")))
        #expect(missing.contains("old") && missing.contains("main"))

        let stray = await fixture.coordinator.create(
            origin: Self.peerOrigin,
            request: .init(prompt: "Do it", agentId: nil, worktree: .current, project: "alas")
        )
        #expect(errorMessage(stray).contains("--peer"))
    }

    @Test("a delegated child cannot name a peer, and the peer is not contacted")
    func delegatedChildCannotUsePeer() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        let fixture = try makeModelSelectionFixture(client: makeSelectionClient(), peers: peers)
        try await fixture.persistence.insert(.init(
            childSessionId: "parent", parentSessionId: "root", projectId: "project",
            parentWorktreeId: "worktree", childWorktreeId: "worktree", agentId: "claude",
            worktreeRequest: .current(worktreeId: "worktree"), phase: .ready, failureMessage: nil, createdAt: 1, updatedAt: 1
        ))

        let created = errorMessage(await peerCreate(fixture))
        let listed = try decodeAgentList(await fixture.coordinator.discoverAgents(origin: Self.peerOrigin, worktree: nil, peer: nil))
        let listedForPeer = errorMessage(await fixture.coordinator.discoverAgents(origin: Self.peerOrigin, worktree: nil, peer: "mini"))

        #expect(created.contains("cannot create child sessions"))
        #expect(listedForPeer.contains("cannot create child sessions"))
        #expect(!listed.canDelegate && listed.peers == nil)
        #expect(peers.discoverCalls.isEmpty)
    }

    // MARK: Acting on a child on a peer

    /// A fixture whose parent cannot take a delivery, so a wake stays readable
    /// in its inbox.
    private func remoteFixture(
        peers: FakePeers, clock: TestClock = TestClock(), onPause: @escaping () -> Void = {}
    ) throws -> (coordinator: ACPSessionOrchestrationCoordinator, persistence: ACPOrchestrationPersistence, manager: ACPSessionManager) {
        try makeModelSelectionFixture(
            client: makeSelectionClient(), setupEvaluator: { _ in .missing(reason: "Stays local") },
            peers: peers, nowMillis: { clock.millis }, pause: { _ in
                clock.millis += clock.step
                onPause()
                await Task.yield()
            }
        )
    }

    private func wait(
        _ fixture: (coordinator: ACPSessionOrchestrationCoordinator, persistence: ACPOrchestrationPersistence, manager: ACPSessionManager),
        _ ids: [String] = ["child"], timeoutMillis: Int = 1_000
    ) async throws -> ACPOrchestrationWaitResponse {
        try decoded(ACPOrchestrationWaitResponse.self, await fixture.coordinator.wait(
            origin: Self.peerOrigin, request: .init(targetSessionIds: ids, timeoutMillis: timeoutMillis)
        ))
    }

    /// The prompt goes as the user wrote it, since the peer adds the role
    /// itself; auto-run is the parent's, and everything else is the peer's to
    /// check.
    @Test func createWritesRecordBeforeSending() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        let fixture = try remoteFixture(peers: peers)
        fixture.manager.liveSession(for: "parent")?.autoRunEnabled = true
        let persistence = fixture.persistence
        final class Seen { var record: ACPDelegationRecord? }
        let seen = Seen()
        peers.onStart = { start in seen.record = try? await persistence.delegation(childSessionId: start.childID) }

        let response = try decoded(ACPOrchestrationNewResponse.self, await fixture.coordinator.create(
            origin: Self.peerOrigin,
            request: .init(
                prompt: "Do it", agentId: "codex", worktree: .new(branch: "fix", base: "main"),
                modelSelection: .init(model: "m", reasoning: "high"), role: "reviewer", peer: "mini"
            )
        ))

        #expect(peers.startCalls == [ACPPeerChildStartRequest(
            childID: "child", target: .newWorktree(projectID: "id-alas", branch: "fix", base: "main", expectedBaseSHA: nil),
            agentID: "codex", modelID: "m", reasoning: "high", role: "reviewer", autoRun: true, prompt: "Do it"
        )])
        let written = try #require(seen.record)
        #expect(written.phase == .starting && written.peerServerId == "srv-1" && written.childWorktreeId == nil)
        #expect(written.parentSessionId == "parent" && written.projectId == "project")
        #expect(written.worktreeRequest == .current(worktreeId: "worktree"))
        #expect(try await phase(persistence) == .ready)
        #expect(response.state == "starting" && response.peer == "mini" && response.worktreeId == nil)
    }

    @Test func newWorktreeWithoutABaseAsksForOne() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        let fixture = try remoteFixture(peers: peers)

        let message = errorMessage(await peerCreate(fixture, worktree: .new(branch: "fix", base: nil)))

        #expect(message.contains("--base"))
        #expect(peers.startCalls.isEmpty)
        #expect(try await phase(fixture.persistence) == nil)
    }

    /// The caller hears the reason in the tool's answer, so nothing wakes it.
    @Test(arguments: [
        ACPPeerError.refused("Agent access is off."), .outdated(peer: "mini"), .notFound, .revoked(peer: "mini"),
    ])
    func refusedStartFailsRecordAndReturnsReason(error: ACPPeerError) async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        peers.startResults = [.failure(error)]
        let fixture = try remoteFixture(peers: peers)

        let message = errorMessage(await peerCreate(fixture))

        let record = try #require(try await fixture.persistence.delegation(childSessionId: "child"))
        #expect(record.phase == .failed && record.failureMessage == message)
        #expect(try await fixture.persistence.pendingMessages(targetSessionId: "parent").isEmpty)
        await fixture.coordinator.retryPeerStarts(serverId: "srv-1")
        #expect(peers.startCalls.count == 1)
    }

    @Test func lostStartAnswerIsRetriedOnceWithSameID() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        peers.startResults = [.failure(.unreachable(peer: "mini"))]
        let fixture = try remoteFixture(peers: peers)

        let response = try decoded(ACPOrchestrationNewResponse.self, await peerCreate(fixture))

        #expect(response.state == "starting" && response.peer == "mini" && response.note?.contains("retr") == true)
        #expect(try await phase(fixture.persistence) == .starting)

        await fixture.coordinator.retryPeerStarts(serverId: "srv-1")
        await fixture.coordinator.retryPeerStarts(serverId: "srv-1")

        #expect(peers.startCalls.count == 2 && peers.startCalls[0] == peers.startCalls[1])
        #expect(try await phase(fixture.persistence) == .ready)
    }

    @Test(arguments: [
        ACPPeerError.unreachable(peer: "mini"), .refused("Agent access is off."),
    ])
    func secondFailedStartFailsChildWithAWake(second: ACPPeerError) async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        peers.startResults = [.failure(.unreachable(peer: "mini")), .failure(second)]
        let fixture = try remoteFixture(peers: peers)
        _ = await peerCreate(fixture)

        await fixture.coordinator.retryPeerStarts(serverId: "srv-1")

        #expect(try await phase(fixture.persistence) == .failed)
        let wake = try await fixture.persistence.pendingMessages(targetSessionId: "parent")
        #expect(wake.map(\.id) == ["outcome-child-failed"])
        #expect(wake.first?.prompt.contains("on mini") == true)
    }

    /// An availability signal also fires as a peer goes away.
    @Test func retryDoesNotSpendTheAttemptWhileThePeerIsDown() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        peers.startResults = [.failure(.unreachable(peer: "mini"))]
        let fixture = try remoteFixture(peers: peers)
        _ = await peerCreate(fixture)
        peers.peers = [Self.peer("mini", id: "srv-1", state: .offline)]

        await fixture.coordinator.retryPeerStarts(serverId: "srv-1")

        #expect(peers.startCalls.count == 1)
        #expect(try await phase(fixture.persistence) == .starting)
    }

    /// A signal arriving during the first attempt must not spend the retry,
    /// or send a second copy of a start still in flight.
    @Test func retryLeavesAStartStillInFlightAlone() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        let fixture = try remoteFixture(peers: peers)
        let coordinator = fixture.coordinator
        peers.onStart = { _ in await coordinator.retryPeerStarts(serverId: "srv-1") }

        _ = await peerCreate(fixture)

        #expect(peers.startCalls.count == 1)
        #expect(try await phase(fixture.persistence) == .ready)
    }

    /// A restart forgets where the child was to run, so it cannot be sent
    /// again. The peer says whether the start ever arrived.
    @Test(arguments: [
        (state: "running", expected: ACPDelegationPhase.ready, wakes: false),
        (state: ACPOrchestrationWaitResponse.Session.goneState, expected: .failed, wakes: true),
    ])
    func startCutOffByARestartAsksThePeer(state: String, expected: ACPDelegationPhase, wakes: Bool) async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        peers.statusAnswer = { _, ids in FakePeers.status(ids, state: state, settled: state != "running") }
        let fixture = try remoteFixture(peers: peers)
        try await insertRemoteChild(fixture.persistence, phase: .starting)

        await fixture.coordinator.retryPeerStarts(serverId: "srv-1")

        #expect(peers.startCalls.isEmpty)
        #expect(try await phase(fixture.persistence) == expected)
        #expect(try await !fixture.persistence.pendingMessages(targetSessionId: "parent").isEmpty == wakes)
    }

    @Test func sendReadInterruptGoToThePeer() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        let fixture = try remoteFixture(peers: peers)
        try await insertRemoteChild(fixture.persistence)

        let sent = try decoded(ACPOrchestrationSendResponse.self, await fixture.coordinator.send(
            origin: Self.peerOrigin, request: .init(targetSessionId: "child", prompt: "More")
        ))
        let read = await fixture.coordinator.read(
            origin: Self.peerOrigin, request: .init(targetSessionId: "child", offset: 2, limit: 3, maxChars: 4)
        )
        let interrupted = try decoded(ACPOrchestrationInterruptResponse.self, await fixture.coordinator.interrupt(
            origin: Self.peerOrigin, targetSessionId: "child"
        ))

        #expect(sent.state == "queued")
        #expect(peers.sendCalls.map(\.prompt) == ["More"])
        #expect(try await fixture.persistence.pendingMessages(targetSessionId: "child").isEmpty)
        guard case .text(let lines) = read else { throw TestFailure("expected text, got \(read)") }
        #expect(lines == ["{\"from\":\"peer\"}"])
        let readCall = try #require(peers.readCalls.first)
        #expect(readCall.offset == 2 && readCall.limit == 3 && readCall.maxChars == 4)
        #expect(interrupted.cancelRequested && peers.interruptCalls == ["child"])
    }

    @Test func actionsOnAPeerThatCannotBeReachedNameIt() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        peers.sendResult = .failure(.unreachable(peer: "mini"))
        peers.readResult = .failure(.unreachable(peer: "mini"))
        peers.interruptResult = .failure(.unreachable(peer: "mini"))
        let fixture = try remoteFixture(peers: peers)
        try await insertRemoteChild(fixture.persistence)

        for response in [
            await fixture.coordinator.send(origin: Self.peerOrigin, request: .init(targetSessionId: "child", prompt: "More")),
            await fixture.coordinator.read(origin: Self.peerOrigin, request: .init(targetSessionId: "child")),
            await fixture.coordinator.interrupt(origin: Self.peerOrigin, targetSessionId: "child"),
        ] {
            #expect(errorMessage(response).contains("mini"))
        }
        #expect(try await phase(fixture.persistence) == .ready)
    }

    /// A start that has not reached the peer yet has nothing there to find,
    /// which proves nothing about the child.
    @Test func actionsBeforeTheChildReachedThePeerSaySo() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        peers.sendResult = .failure(.notFound)
        peers.interruptResult = .failure(.notFound)
        let fixture = try remoteFixture(peers: peers)
        try await insertRemoteChild(fixture.persistence, phase: .starting)

        let sent = errorMessage(await fixture.coordinator.send(
            origin: Self.peerOrigin, request: .init(targetSessionId: "child", prompt: "More")
        ))
        let interrupted = try decoded(ACPOrchestrationInterruptResponse.self, await fixture.coordinator.interrupt(
            origin: Self.peerOrigin, targetSessionId: "child"
        ))

        #expect(sent.contains("not started"))
        #expect(!interrupted.cancelRequested)
        #expect(try await phase(fixture.persistence) == .starting)
    }

    @Test func failedChildTakesNoMessage() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        let fixture = try remoteFixture(peers: peers)
        try await insertRemoteChild(fixture.persistence, phase: .failed)

        let message = errorMessage(await fixture.coordinator.send(
            origin: Self.peerOrigin, request: .init(targetSessionId: "child", prompt: "More")
        ))

        #expect(message.contains("not available"))
        #expect(peers.sendCalls.isEmpty)
    }

    /// Asks no peer: a row's stored phase is all `session_list` reports.
    @Test func listShowsPeerName() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        let fixture = try remoteFixture(peers: peers)
        try await insertRemoteChild(fixture.persistence)
        try await insertRemoteChild(fixture.persistence, id: "forgotten", server: "srv-9", phase: .starting)

        let listed = try decoded(ACPOrchestrationListResponse.self, await fixture.coordinator.list(origin: Self.peerOrigin))

        let child = try #require(listed.sessions.first { $0.sessionId == "child" })
        #expect(child.peer == "mini" && child.state == "idle" && child.worktreeId.isEmpty && child.relationship == "child")
        let forgotten = try #require(listed.sessions.first { $0.sessionId == "forgotten" })
        #expect(forgotten.peer == "srv-9" && forgotten.state == "starting")
        #expect(listed.sessions.first { $0.sessionId == "parent" }?.peer == nil)
        #expect(peers.statusCalls.isEmpty)
    }

    @Test func waitReportsChildStateFromStatus() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        peers.statusAnswer = { _, ids in FakePeers.status(ids, state: "running", settled: false) }
        let clock = TestClock()
        // Too slow to reach the polling interval: only the signal can cause a
        // new question.
        clock.step = 1
        let fixture = try remoteFixture(peers: peers, clock: clock, onPause: {
            peers.statusAnswer = { _, ids in FakePeers.status(ids, state: "idle", settled: true) }
            peers.onOutboxChanged?("srv-1")
        })
        try await insertRemoteChild(fixture.persistence)

        let answer = try await wait(fixture)

        #expect(peers.statusCalls.map(\.ids) == [["child"], ["child"]])
        let session = try #require(answer.sessions.first)
        #expect(session.state == "idle" && session.settled && session.lastAgentText == "text" && !answer.timedOut)
    }

    @Test func waitStopsAtItsDeadline() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        peers.statusAnswer = { _, ids in FakePeers.status(ids, state: "running", settled: false) }
        let clock = TestClock()
        let fixture = try remoteFixture(peers: peers, clock: clock)
        try await insertRemoteChild(fixture.persistence)

        let answer = try await wait(fixture, timeoutMillis: 5_000)

        #expect(answer.timedOut && answer.sessions.first?.state == "running" && answer.sessions.first?.settled == false)
        #expect(clock.millis == 6_000)
        // Asked on the interval, not on every look at the clock.
        #expect((2...3).contains(peers.statusCalls.count))
    }

    /// A peer's answer can take a minute to fail, far past any wait's timeout
    /// and past the CLI's read timeout, and the next slice of the same wait
    /// shares the question rather than stacking up another.
    @Test(.timeLimit(.minutes(1))) func waitDoesNotBlockOnAPeerThatDoesNotAnswer() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        let (gate, release) = AsyncStream<Void>.makeStream()
        peers.statusGate = gate
        let clock = TestClock()
        let fixture = try remoteFixture(peers: peers, clock: clock)
        try await insertRemoteChild(fixture.persistence)

        let first = try await wait(fixture)
        let second = try await wait(fixture)

        #expect(first.timedOut && second.timedOut && first.sessions.first?.settled == false)
        #expect(peers.statusCalls.count == 1)
        release.finish()
    }

    @Test(arguments: [
        (error: ACPPeerError.unreachable(peer: "mini"), state: "peer_unreachable", settled: true),
        (error: .outdated(peer: "mini"), state: "peer_unreachable", settled: true),
        (error: .revoked(peer: "mini"), state: "peer_unreachable", settled: true),
        // A refusal says nothing about the child: it is not gone.
        (error: .refused("Busy."), state: "idle", settled: false),
        (error: .notFound, state: "idle", settled: false),
    ])
    func waitOnAFailedStatus(error: ACPPeerError, state: String, settled: Bool) async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        peers.statusAnswer = { _, _ in .failure(error) }
        let clock = TestClock()
        let fixture = try remoteFixture(peers: peers, clock: clock)
        try await insertRemoteChild(fixture.persistence)

        let answer = try await wait(fixture)

        #expect(answer.sessions.first?.state == state && answer.sessions.first?.settled == settled)
        #expect(answer.timedOut != settled)
        #expect(settled ? clock.millis < 2_000 : clock.millis == 2_000)
        #expect(try await phase(fixture.persistence) == .ready)
    }

    /// `gone` is reported and nothing else happens: failing the child is the
    /// outage logic's call. A child still starting has not reached the peer,
    /// so there it means nothing yet.
    @Test func goneIsSettledOnlyForAChildThatStarted() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        peers.statusAnswer = { _, ids in FakePeers.status(ids, state: "gone", settled: true) }
        let clock = TestClock()
        let fixture = try remoteFixture(peers: peers, clock: clock)
        try await insertRemoteChild(fixture.persistence)
        try await insertRemoteChild(fixture.persistence, id: "young", phase: .starting)

        let gone = try await wait(fixture, ["child"])
        let young = try await wait(fixture, ["young"])

        #expect(gone.sessions.first?.state == "gone" && gone.sessions.first?.settled == true && !gone.timedOut)
        #expect(try await phase(fixture.persistence) == .ready)
        #expect(young.sessions.first?.state == "starting" && young.sessions.first?.settled == false && young.timedOut)
    }

    /// One answer in the caller's order, each peer asked for its own children
    /// in batches it accepts; a child already failed here costs no question.
    @Test func waitAnswersForLocalAndPeerChildrenTogether() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1"), Self.peer("studio", id: "srv-2")])
        peers.statusAnswer = { serverId, ids in
            serverId == "srv-1" ? FakePeers.status(ids, state: "idle", settled: true) : .failure(.unreachable(peer: "studio"))
        }
        let fixture = try remoteFixture(peers: peers)
        let many = (0..<(ACPDelegatedSessionWaitRequest.maxSessions + 1)).map { "many-\($0)" }
        for id in many { try await insertRemoteChild(fixture.persistence, id: id) }
        try await insertRemoteChild(fixture.persistence, id: "away", server: "srv-2")
        try await insertRemoteChild(fixture.persistence, id: "failed", server: "srv-2", phase: .failed)
        try await fixture.persistence.insert(.init(
            childSessionId: "local", parentSessionId: "parent", projectId: "project", parentWorktreeId: "worktree",
            childWorktreeId: "worktree", agentId: "codex", worktreeRequest: .current(worktreeId: "worktree"),
            phase: .failed, failureMessage: "Local trouble", createdAt: 1, updatedAt: 1
        ))
        let ids = ["local", "away"] + many + ["failed"]

        let answer = try await wait(fixture, ids)

        #expect(answer.sessions.map(\.sessionId) == ids && !answer.timedOut)
        #expect(answer.sessions.first?.failure == "Local trouble")
        #expect(answer.sessions[1].state == "peer_unreachable")
        #expect(answer.sessions[2].state == "idle")
        #expect(answer.sessions.last?.state == "failed")
        let toMini = peers.statusCalls.filter { $0.serverId == "srv-1" }.map(\.ids.count).sorted()
        #expect(toMini == [1, ACPDelegatedSessionWaitRequest.maxSessions])
        #expect(peers.statusCalls.filter { $0.serverId == "srv-2" }.map(\.ids) == [["away"]])
    }

    @Test func siblingAndGrandchildRulesStillApply() async throws {
        let peers = FakePeers(peers: [Self.peer("mini", id: "srv-1")])
        let fixture = try remoteFixture(peers: peers)
        try await insertRemoteChild(fixture.persistence, id: "someone-elses", parent: "other")
        try await insertRemoteChild(fixture.persistence, id: "other-project")
        let elsewhere = ACPOrchestrationSessionOrigin(sessionId: "parent", projectId: "elsewhere", worktreeId: "worktree")

        for (origin, target) in [(Self.peerOrigin, "someone-elses"), (elsewhere, "other-project")] {
            let coordinator = fixture.coordinator
            #expect(errorMessage(await coordinator.send(origin: origin, request: .init(targetSessionId: target, prompt: "More"))).contains("direct"))
            #expect(errorMessage(await coordinator.read(origin: origin, request: .init(targetSessionId: target))).contains("direct"))
            #expect(errorMessage(await coordinator.wait(origin: origin, request: .init(targetSessionIds: [target]))).contains("direct"))
            #expect(errorMessage(await coordinator.interrupt(origin: origin, targetSessionId: target)).contains("direct"))
        }
        #expect(peers.sendCalls.isEmpty && peers.readCalls.isEmpty && peers.statusCalls.isEmpty && peers.interruptCalls.isEmpty)
    }

    private func decodeAgentList(_ response: AlasCLIResponse) throws -> ACPDelegationAgentListResponse {
        guard case .text(let lines) = response, let line = lines.first else {
            throw TestFailure("expected text, got \(response)")
        }
        return try JSONDecoder().decode(ACPDelegationAgentListResponse.self, from: Data(line.utf8))
    }

    private struct TestFailure: Error { let message: String; init(_ message: String) { self.message = message } }
}
