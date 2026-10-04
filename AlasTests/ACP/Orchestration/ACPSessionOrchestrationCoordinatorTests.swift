import Foundation
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

    private func makeModelSelectionFixture(
        client: ACPMockClient,
        launchModels: [ACPAgentModelCatalog.Model]? = nil,
        reasoningRefreshTimeout: Duration = .seconds(30),
        waitForChildResultBatch: @escaping @Sendable () async -> Void = {},
        notifyChanged: @escaping () -> Void = {}
    ) throws -> (coordinator: ACPSessionOrchestrationCoordinator, persistence: ACPOrchestrationPersistence, manager: ACPSessionManager) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acp-model-selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let persistence = ACPOrchestrationPersistence(path: root.appendingPathComponent("delegations.sqlite").path)
        // Wired as AppState wires it.
        let manager = ACPSessionManager(
            worktreeId: "worktree",
            worktreePath: root.path,
            store: try ACPSessionStore(path: root.appendingPathComponent("sessions.sqlite").path),
            setupEvaluator: { _ in .ready },
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
            persistence: persistence, instanceId: "instance", now: { 100 },
            waitForChildResultBatch: waitForChildResultBatch, makeID: { "child" },
            worktree: { $0 == worktree.id ? worktree : nil }, existingWorktree: { _, _ in nil },
            configuredAgents: { [claude] }, availableAgents: { _, _ in [claude] },
            launchModels: { _, _ in launchModels },
            sessionLocation: { sessionId in
                manager.liveSession(for: sessionId) == nil
                    ? nil
                    : .init(origin: .init(sessionId: sessionId, projectId: "project", worktreeId: "worktree"), manager: manager)
            },
            manager: { _ in manager }, newWorktreeDestination: { _, _ in nil },
            createWorktree: { _, _, _, _ in .failure(.init(message: "unused")) }, rememberParent: { _, _ in },
            autoRunDefault: { false }, notifyChanged: notifyChanged
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
        #expect(await fixture.coordinator.queueInitialPromptAfterModelSelection(
            selection, record: record, prompt: "Review the parser.", manager: fixture.manager
        ))
        #expect(childRequests(client) == ["set_model:opus"])
        fixture.manager.releaseDelegatedSelectionHold("child")
        try await waitUntil { childRequests(client).count == 2 }
        #expect(childRequests(client) == ["set_model:opus", "prompt:Review the parser."])
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
    }

    /// A parent session that exists but cannot attach (missing agent), so
    /// delivery leaves rows pending and unclaimed for inspection.
    private func makeOutcomeFixture(
        parentReachable: Bool = true,
        blockedKeys: Set<String> = [],
        escalationSeconds: Int = 30,
        scheduleEscalationCheck: @escaping (Int, @escaping @Sendable () async -> Void) -> Void = { _, _ in }
    ) throws -> OutcomeFixture {
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
                parentReachable && sessionId == "parent"
                    ? .init(origin: .init(sessionId: "parent", projectId: "project", worktreeId: "worktree"), manager: manager)
                    : nil
            },
            manager: { _ in parentReachable ? manager : nil },
            newWorktreeDestination: { _, _ in nil },
            createWorktree: { _, _, _, _ in .failure(.init(message: "unused")) },
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
        #expect(pending.last?.prompt == "Delegated session child (codex, worktree feature-x) had its turn cancelled by the user.")
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
}
