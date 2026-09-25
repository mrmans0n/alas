import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSessionManager attach restore", .serialized)
struct ACPSessionManagerAttachRestoreTests {
    @Test("restart supersedes a suspended setup attempt and preserves the queued prompt")
    func restartSupersedesSuspendedSetupAttempt() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let setupGate = AttachPhaseGate()
        let setupCount = PromptCounter()
        let replacementClient = ACPMockClient()
        scriptInitialize(replacementClient)
        scriptSessionResult(replacementClient, method: "session/new", sessionId: "remote-replacement")
        var launchCount = 0
        let manager = ACPSessionManager(
            worktreeId: "wt", worktreePath: "/tmp/wt", store: store,
            setupEvaluator: { _ in
                if await setupCount.next() == 1 {
                    await setupGate.enterAndWait()
                }
                return .ready
            },
            connectionFactory: { _, _, _ in
                launchCount += 1
                return ACPConnection(client: replacementClient)
            }
        )
        let session = manager.createSession(agentId: "claude")
        session.enqueue(blocks: [.text("queued prompt")])
        let originalAttach = Task { await manager.attach(to: session.id, freshlyCreated: true) }
        try await waitUntilAsync { await setupGate.hasEntered }

        let coalescedAttach = Task { await manager.attach(to: session.id, freshlyCreated: false) }
        let restart = Task { await manager.restartConnection(to: session.id) }
        let duplicateRestart = Task { await manager.restartConnection(to: session.id) }

        try await waitUntilAsync(timeoutNanos: 1_000_000_000) {
            session.agentState == .ready && launchCount == 1
        }
        #expect(await setupGate.hasEntered)
        #expect(session.agentState == .ready)
        #expect(launchCount == 1)
        #expect(session.remoteSessionId == "remote-replacement")
        #expect(session.queue.count == 1)

        let replacementRunner = manager.runners[session.id]
        let replacementLease = try store.loadLease(sessionId: session.id)
        await setupGate.release()
        await originalAttach.value
        await coalescedAttach.value
        await restart.value
        await duplicateRestart.value

        #expect(session.agentState == .ready)
        #expect(manager.runners[session.id] === replacementRunner)
        #expect(session.remoteSessionId == "remote-replacement")
        #expect(session.queue.count == 1)
        #expect(replacementLease != nil)
        #expect(try store.loadLease(sessionId: session.id)?.token == replacementLease?.token)
    }

    @Test("a stalled replacement attach can be restarted")
    func stalledReplacementAttachCanBeRestarted() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let initializeGate = AttachPhaseGate()
        let initialClient = ACPMockClient()
        let stalledClient = ACPMockClient()
        let replacementClient = ACPMockClient()
        scriptInitialize(initialClient)
        scriptSessionResult(initialClient, method: "session/new", sessionId: "remote-initial")
        stalledClient.scriptAsync(method: "initialize") { _ in
            await initializeGate.enterAndWait()
            return try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: nil,
                authMethods: []
            ))
        }
        scriptSessionResult(stalledClient, method: "session/new", sessionId: "remote-stalled")
        scriptInitialize(replacementClient)
        scriptSessionResult(replacementClient, method: "session/new", sessionId: "remote-replacement")
        var launchCount = 0
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in
                launchCount += 1
                if launchCount == 1 { return ACPConnection(client: initialClient) }
                if launchCount == 2 { return ACPConnection(client: stalledClient) }
                return ACPConnection(client: replacementClient)
            }
        )
        let session = manager.createSession(agentId: "claude")
        await manager.attach(to: session.id, freshlyCreated: true)
        #expect(session.agentState == .ready)

        let stalledRestart = Task { await manager.restartConnection(to: session.id) }
        defer { Task { await initializeGate.release() } }
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await initializeGate.hasEntered
        }

        #expect(session.connectionRestartInProgress == false)
        let nextRestart = Task { await manager.restartConnection(to: session.id) }
        try? await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            launchCount == 3 && session.agentState == .ready
        }

        await initializeGate.release()
        await stalledRestart.value
        await nextRestart.value

        #expect(launchCount == 3)
        #expect(session.agentState == .ready)
        #expect(!session.connectionRestartInProgress)
        await manager.detach(sessionId: session.id)
    }

    @Test("a superseded recovery restart cannot exhaust its current replacement")
    func supersededRecoveryRestartDoesNotExhaustReplacement() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let initialClient = ACPMockClient()
        let staleClient = ACPMockClient()
        let currentClient = ACPMockClient()
        let staleInitializeGate = AttachPhaseGate()
        let currentInitializeGate = AttachPhaseGate()
        scriptInitialize(initialClient)
        scriptSessionResult(initialClient, method: "session/new", sessionId: "remote-initial")
        staleClient.scriptAsync(method: "initialize") { _ in
            await staleInitializeGate.enterAndWait()
            return try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: nil,
                authMethods: []
            ))
        }
        scriptSessionResult(staleClient, method: "session/new", sessionId: "remote-stale")
        currentClient.scriptAsync(method: "initialize") { _ in
            await currentInitializeGate.enterAndWait()
            return try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: nil,
                authMethods: []
            ))
        }
        scriptSessionResult(currentClient, method: "session/new", sessionId: "remote-current")
        var launchCount = 0
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in
                launchCount += 1
                if launchCount == 1 { return ACPConnection(client: initialClient) }
                if launchCount == 2 { return ACPConnection(client: staleClient) }
                return ACPConnection(client: currentClient)
            }
        )
        let session = manager.createSession(agentId: "claude")
        await manager.attach(to: session.id, freshlyCreated: true)
        #expect(session.agentState == .ready)
        #expect(session.beginConnectionRecovery())
        defer {
            Task { await staleInitializeGate.release() }
            Task { await currentInitializeGate.release() }
        }

        let staleRestart = Task { await manager.restartConnection(to: session.id) }
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await staleInitializeGate.hasEntered
        }
        let currentRestart = Task { await manager.restartConnection(to: session.id) }
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await currentInitializeGate.hasEntered && session.agentState == .spawning
        }

        await staleInitializeGate.release()
        await staleRestart.value

        #expect(session.agentState == .spawning)
        #expect(session.connectionRecoveryState == .reconnecting(attempt: nil, maxAttempts: nil))

        await currentInitializeGate.release()
        await currentRestart.value

        #expect(session.agentState == .ready)
        #expect(session.connectionRecoveryState == nil)
        #expect(launchCount == 3)
        await manager.detach(sessionId: session.id)
    }

    @Test("a superseded automatic reattach cannot exhaust its replacement's recovery")
    func supersededRecoveryReattachDoesNotExhaustReplacement() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let initialClient = ACPMockClient()
        let staleClient = ACPMockClient()
        let currentClient = ACPMockClient()
        let staleInitializeGate = AttachPhaseGate()
        let currentInitializeGate = AttachPhaseGate()
        scriptInitialize(initialClient)
        scriptSessionResult(initialClient, method: "session/new", sessionId: "remote-initial")
        staleClient.scriptAsync(method: "initialize") { _ in
            await staleInitializeGate.enterAndWait()
            return try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: nil,
                authMethods: []
            ))
        }
        scriptSessionResult(staleClient, method: "session/new", sessionId: "remote-stale")
        currentClient.scriptAsync(method: "initialize") { _ in
            await currentInitializeGate.enterAndWait()
            return try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: nil,
                authMethods: []
            ))
        }
        scriptSessionResult(currentClient, method: "session/new", sessionId: "remote-current")
        var launchCount = 0
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in
                launchCount += 1
                if launchCount == 1 { return ACPConnection(client: initialClient) }
                if launchCount == 2 { return ACPConnection(client: staleClient) }
                return ACPConnection(client: currentClient)
            }
        )
        let session = manager.createSession(agentId: "claude")
        await manager.attach(to: session.id, freshlyCreated: true)
        #expect(session.agentState == .ready)
        #expect(session.beginConnectionRecovery())
        session.agentState = .disconnected
        defer {
            Task { await staleInitializeGate.release() }
            Task { await currentInitializeGate.release() }
        }

        let staleReattach = Task { await manager.reattach(to: session.id) }
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await staleInitializeGate.hasEntered
        }
        let currentRestart = Task { await manager.restartConnection(to: session.id) }
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await currentInitializeGate.hasEntered && session.agentState == .spawning
        }

        await staleInitializeGate.release()
        await staleReattach.value

        #expect(session.agentState == .spawning)
        #expect(session.connectionRecoveryState == .reconnecting(attempt: nil, maxAttempts: nil))

        await currentInitializeGate.release()
        await currentRestart.value

        #expect(session.agentState == .ready)
        #expect(session.connectionRecoveryState == nil)
        #expect(launchCount == 3)
        await manager.detach(sessionId: session.id)
    }

    @Test("closing a suspended setup attempt clears its attachment marker")
    func closingSuspendedSetupAttemptClearsAttachmentMarker() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let setupGate = AttachPhaseGate()
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in
                await setupGate.enterAndWait()
                return .ready
            }
        )
        let session = manager.createSession(agentId: "claude")
        let attach = Task { await manager.attach(to: session.id, freshlyCreated: true) }
        try await waitUntilAsync { await setupGate.hasEntered }
        #expect(manager.isAttachingForTest(session.id))

        try await manager.disposeSession(id: session.id)
        await setupGate.release()
        await attach.value

        #expect(!manager.isAttachingForTest(session.id))
        #expect(!manager.hasActiveCheckpointWriter)
    }

    @Test("deleting a session during broker startup shuts down its owned connection")
    func deletingDuringBrokerStartupShutsDownAttemptConnection() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let service = ManagerBrokerServiceProxy(stallOpen: true)
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { service },
            attachmentStartupTimeout: .seconds(10)
        )
        let session = manager.createSession(agentId: "claude")
        let attach = Task { await manager.attach(to: session.id, freshlyCreated: true) }
        try await waitUntilAsync { await service.openGate.hasEntered }

        try await manager.disposeSession(id: session.id)
        await service.openGate.release()
        await attach.value

        #expect(await service.closed.count == 1)
    }

    @Test("restart uses a fresh broker when the old shutdown times out")
    func restartUsesFreshBrokerWhenOldShutdownTimesOut() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let service = ManagerBrokerServiceProxy(stallClose: true, stallSendMethod: "initialize")
        let isolatedService = ManagerBrokerService(generation: 8, supportsPromptResponses: true)
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { service },
            isolatedBrokerServiceFactory: { isolatedService },
            attachmentStartupTimeout: .seconds(10),
            restartTeardownTimeout: .milliseconds(50)
        )
        let session = manager.createSession(agentId: "claude")
        let originalAttach = Task { await manager.attach(to: session.id, freshlyCreated: true) }
        defer {
            Task {
                await service.closeGate.release()
                await service.sendGate.release()
            }
        }
        try await waitUntilAsync { await service.sendGate.hasEntered }

        let restart = Task { await manager.restartConnection(to: session.id) }
        try await waitUntilAsync { await service.closeGate.hasEntered }
        #expect(await service.closeGate.hasWaiters)
        #expect(await service.opened.count == 1)
        #expect(session.agentState != .ready)

        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            let isolatedOpenCount = await isolatedService.opened.count
            return session.agentState == .ready && isolatedOpenCount == 1
        }
        #expect(await service.opened.count == 1)
        let oldBrokerId = await service.opened.first?.brokerId
        let replacementBrokerId = await isolatedService.opened.first?.brokerId
        #expect(oldBrokerId != replacementBrokerId)

        await service.closeGate.release()
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await service.closed.count == 1
        }

        #expect(await service.closed.count > 0)
        let replacementRunner = manager.runners[session.id]
        await service.sendGate.release()
        await originalAttach.value
        await restart.value

        #expect(session.agentState == .ready)
        #expect(manager.runners[session.id] === replacementRunner)
        #expect(await service.closed.count > 0)
    }

    @Test("old runner queue persistence stays fenced after restart changes owners")
    func oldRunnerQueuePersistenceStaysFencedAfterRestartChangesOwners() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-restart-fence")
        let manager = manager(store: store, client: client)
        let session = manager.createSession(agentId: "claude")
        await manager.attach(to: session.id, freshlyCreated: true)
        await manager.flushAllPersistence()

        let oldRunner = try #require(manager.runners[session.id])
        let replacementQueue = QueuedPrompt(blocks: [.text("new owner queue")])
        let staleQueue = QueuedPrompt(blocks: [.text("old runner queue")])
        var queueAfterOldRunnerWrite: [QueuedPrompt] = []
        manager.beforeRestartRunnerStopForTesting = { sessionId in
            do {
                let oldLease = try #require(try store.loadLease(sessionId: sessionId))
                try store.seizeLease(
                    sessionId: sessionId,
                    instanceId: "replacement-owner",
                    pid: Int64(getpid()),
                    now: oldLease.heartbeatAt + 1,
                    leaseToken: "replacement-token"
                )
                try store.upsertQueue(sessionId: sessionId, items: [replacementQueue])
                session.queue = [staleQueue]
                oldRunner.persistQueue()
                await oldRunner.flushPersistence()
                queueAfterOldRunnerWrite = try store.loadQueue(sessionId: sessionId)
            } catch {
                Issue.record("Could not stage the replacement lease: \(error)")
            }
        }

        await manager.restartConnection(to: session.id)

        #expect(queueAfterOldRunnerWrite == [replacementQueue])
        #expect(try store.loadQueue(sessionId: session.id) == [replacementQueue])
    }

    @Test("attaching an already-ready session preserves its live update callback")
    func attachingReadySessionPreservesLiveUpdateCallback() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-ready")
        let manager = manager(store: store, client: client)
        let session = manager.createSession(agentId: "claude")

        await manager.attach(to: session.id, freshlyCreated: true)
        let liveRunner = try #require(manager.runners[session.id])

        await manager.attach(to: session.id, freshlyCreated: false)
        #expect(manager.runners[session.id] === liveRunner)

        client.emit(.init(
            sessionId: "remote-ready",
            update: .agentMessageChunk(.text("still connected"))
        ))
        try await waitUntil { session.transcript.messages.count == 1 }

        if let message = session.transcript.messages.first,
           case .agent(_, _, let text) = message {
            #expect(text.value == "still connected")
        } else {
            Issue.record("Expected the existing runner's live update to reach the transcript")
        }
        await manager.detach(sessionId: session.id)
    }

    @Test("a stalled broker startup falls back to an isolated service")
    func stalledBrokerStartupFallsBackToIsolatedService() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        var storedRow = row(id: "stalled-broker-session", remoteSessionId: nil)
        storedRow.acpBrokerId = "persisted-stalled-broker"
        storedRow.acpBrokerGeneration = 7
        storedRow.acpBrokerAcknowledgedCursor = 42
        try store.upsertSession(storedRow)
        let sharedService = ManagerBrokerServiceProxy(stallOpen: true)
        let isolatedService = ManagerBrokerService()
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { sharedService },
            isolatedBrokerServiceFactory: { isolatedService },
            attachmentStartupTimeout: .milliseconds(50),
            restartTeardownTimeout: .milliseconds(50)
        )
        let session = try #require(manager.placeholderSession(id: "stalled-broker-session"))
        await manager.hydrateIfNeeded(id: session.id)
        session.enqueue(blocks: [.text("keep this queued")])

        let originalAttach = Task { await manager.attach(to: session.id, freshlyCreated: true) }
        try await waitUntilAsync { await sharedService.openGate.hasEntered }
        let restart = Task { await manager.restartConnection(to: session.id) }

        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            let opened = await isolatedService.opened
            return session.agentState == .ready && !opened.isEmpty
        }
        let originalBrokerId = await sharedService.opened.first?.brokerId
        let isolatedBrokerId = await isolatedService.opened.first?.brokerId
        #expect(originalBrokerId != isolatedBrokerId)
        #expect(await isolatedService.attached.first?.acknowledgedCursor == ACPBrokerEventCursor(rawValue: 0))
        #expect(await sharedService.openGate.hasWaiters)
        #expect(session.agentState == .ready)
        #expect(session.queue.count == 1)
        let replacementRunner = manager.runners[session.id]
        let replacementLease = try store.loadLease(sessionId: session.id)

        await sharedService.openGate.release()
        await originalAttach.value
        await restart.value

        #expect(session.agentState == .ready)
        #expect(manager.runners[session.id] === replacementRunner)
        #expect(session.remoteSessionId == "remote-broker")
        #expect(session.queue.count == 1)
        #expect(try store.loadLease(sessionId: session.id)?.token == replacementLease?.token)
    }

    @Test("a timed-out isolated broker is closed if its open completes late")
    func lateIsolatedBrokerOpenIsClosedAfterTimeout() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let sharedService = ManagerBrokerServiceProxy(stallOpen: true)
        let isolatedService = ManagerBrokerServiceProxy(stallOpen: true)
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { sharedService },
            isolatedBrokerServiceFactory: { isolatedService },
            attachmentStartupTimeout: .milliseconds(50),
            restartTeardownTimeout: .milliseconds(50)
        )
        let session = manager.createSession(agentId: "claude")
        let originalAttach = Task { await manager.attach(to: session.id, freshlyCreated: true) }
        try await waitUntilAsync { await sharedService.openGate.hasEntered }
        let restart = Task { await manager.restartConnection(to: session.id) }
        try await waitUntilAsync { await isolatedService.openGate.hasEntered }
        await restart.value

        await isolatedService.openGate.release()
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await isolatedService.closed.count == 1
        }
        #expect(await isolatedService.detached.isEmpty)

        await sharedService.openGate.release()
        await originalAttach.value
    }

    @Test("closing during isolated broker startup shuts down the attempt-owned broker")
    func closingDuringIsolatedBrokerStartupShutsDownAttemptOwnedBroker() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let sharedService = ManagerBrokerServiceProxy(stallOpen: true)
        let isolatedService = ManagerBrokerServiceProxy(stallOpen: true)
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { sharedService },
            isolatedBrokerServiceFactory: { isolatedService },
            attachmentStartupTimeout: .milliseconds(500),
            restartTeardownTimeout: .seconds(1)
        )
        let session = manager.createSession(agentId: "claude")
        let attach = Task { await manager.attach(to: session.id, freshlyCreated: true) }
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await sharedService.openGate.hasEntered
        }
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await isolatedService.openGate.hasEntered
        }

        await manager.detach(sessionId: session.id)
        await isolatedService.openGate.release()
        await sharedService.openGate.release()
        await attach.value
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            let isolatedClosedCount = await isolatedService.closed.count
            let sharedClosedCount = await sharedService.closed.count
            return isolatedClosedCount == 1 && sharedClosedCount == 1
        }

        #expect(await isolatedService.detached.isEmpty)
        #expect(await sharedService.detached.isEmpty)
    }

    @Test("detaching during isolated broker initialization closes the fallback broker")
    func detachingDuringIsolatedBrokerInitializationClosesFallbackBroker() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let sharedService = ManagerBrokerServiceProxy(stallOpen: true)
        let isolatedService = ManagerBrokerServiceProxy(stallSendMethod: "initialize")
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { sharedService },
            isolatedBrokerServiceFactory: { isolatedService },
            attachmentStartupTimeout: .milliseconds(50),
            restartTeardownTimeout: .seconds(1)
        )
        let session = manager.createSession(agentId: "claude")
        let attach = Task { await manager.attach(to: session.id, freshlyCreated: true) }
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await sharedService.openGate.hasEntered
        }
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await isolatedService.sendGate.hasEntered
        }

        await manager.detach(sessionId: session.id)

        #expect(await isolatedService.closed.count == 1)
        #expect(await isolatedService.detached.isEmpty)

        await isolatedService.sendGate.release()
        await sharedService.openGate.release()
        await attach.value
    }

    @Test("a timed-out primary broker is closed if its open completes late")
    func latePrimaryBrokerOpenIsClosedAfterTimeout() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let primaryService = ManagerBrokerServiceProxy(stallOpen: true)
        let isolatedService = ManagerBrokerServiceProxy()
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { primaryService },
            isolatedBrokerServiceFactory: { isolatedService },
            attachmentStartupTimeout: .milliseconds(50),
            restartTeardownTimeout: .milliseconds(50)
        )
        let session = manager.createSession(agentId: "claude")
        let attach = Task { await manager.attach(to: session.id, freshlyCreated: true) }
        try await waitUntilAsync { await primaryService.openGate.hasEntered }
        await attach.value
        #expect(session.agentState == .ready)

        await primaryService.openGate.release()
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await primaryService.completedOpenCount == 1
        }
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await primaryService.closed.count + primaryService.detached.count >= 1
        }
        #expect(await primaryService.closed.count == 1)
        #expect(await primaryService.detached.isEmpty)
        #expect(await isolatedService.opened.count == 1)
    }

    @Test("a timed-out isolated broker cannot register after startup resumes")
    func isolatedBrokerResumingAfterTimeoutDoesNotRegister() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let sharedService = ManagerBrokerServiceProxy(stallOpen: true)
        let isolatedService = ManagerBrokerServiceProxy(stallOpen: true)
        let registrationGate = AttachPhaseGate()
        let shutdownGate = AttachPhaseGate()
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { sharedService },
            isolatedBrokerServiceFactory: { isolatedService },
            attachmentStartupTimeout: .milliseconds(50),
            restartTeardownTimeout: .milliseconds(50)
        )
        manager.beforeBrokerClientRegistrationForTesting = { isolated in
            if isolated { await registrationGate.enterAndWait() }
        }
        manager.afterBrokerClientShutdownRequestedForTesting = { isolated in
            if isolated { await shutdownGate.enterAndWait() }
        }
        let session = manager.createSession(agentId: "claude")
        let originalAttach = Task { await manager.attach(to: session.id, freshlyCreated: true) }
        try await waitUntilAsync { await sharedService.openGate.hasEntered }
        let restart = Task { await manager.restartConnection(to: session.id) }
        try await waitUntilAsync { await registrationGate.hasEntered }
        try await waitUntilAsync { await shutdownGate.hasEntered }
        await registrationGate.release()
        try await Task.sleep(for: .milliseconds(50))
        let openedBeforeShutdownContinued = await isolatedService.opened

        await shutdownGate.release()
        await isolatedService.openGate.release()
        await restart.value

        #expect(openedBeforeShutdownContinued.isEmpty)
        #expect(await isolatedService.detached.isEmpty)

        await sharedService.openGate.release()
        await originalAttach.value
    }

    @Test("a blocked old detach does not hold the replacement connection")
    func blockedOldDetachDoesNotHoldReplacement() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let service = ManagerBrokerServiceProxy(stallDetach: true)
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { service },
            isolatedBrokerServiceFactory: { ManagerBrokerService() },
            attachmentStartupTimeout: .milliseconds(50),
            restartTeardownTimeout: .milliseconds(50)
        )
        let session = manager.createSession(id: "stalled-detach-session", agentId: "claude")
        await manager.attach(to: session.id, freshlyCreated: true)
        let oldRunner = try #require(manager.runners[session.id])
        let restart = Task { await manager.restartConnection(to: session.id) }

        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await service.detachGate.hasEntered
                && session.agentState == .ready
                && manager.runners[session.id] !== oldRunner
        }
        #expect(await service.detachGate.hasWaiters)
        let replacementRunner = manager.runners[session.id]
        let replacementLease = try store.loadLease(sessionId: session.id)
        await service.detachGate.release()
        await restart.value

        #expect(session.agentState == .ready)
        #expect(manager.runners[session.id] === replacementRunner)
        #expect(session.remoteSessionId == "remote-broker")
        #expect(try store.loadLease(sessionId: session.id)?.token == replacementLease?.token)
    }

    @Test("a late retiring detach timeout retries the attach in a fresh broker namespace")
    func lateRetiringDetachTimeoutRetriesAttachInFreshBrokerNamespace() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let sharedService = ManagerBrokerServiceProxy(stallDetach: true)
        let isolatedService = ManagerBrokerService()
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { sharedService },
            isolatedBrokerServiceFactory: { isolatedService },
            attachmentStartupTimeout: .seconds(10),
            restartTeardownTimeout: .milliseconds(50)
        )
        let session = manager.createSession(id: "late-detach-fresh-namespace", agentId: "claude")
        await manager.attach(to: session.id, freshlyCreated: true)
        await manager.flushAllPersistence()
        let originalRunner = try #require(manager.runners[session.id])
        let originalLease = try store.loadLease(sessionId: session.id)
        let originalBrokerId = try await #require(sharedService.opened.first?.brokerId)

        let restart = Task { await manager.restartConnection(to: session.id) }
        defer {
            Task {
                // The retirement detach's cancelled operation task still
                // waits on the gate; release it so the actor winds down.
                await sharedService.detachGate.release()
            }
        }

        // The replacement initializes on the shared broker namespace while
        // the retiring connection's detach is still stalled.
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await sharedService.detachGate.hasEntered
                && session.agentState != .ready
                && manager.runners[session.id] == nil
        }
        #expect(await sharedService.detached.count == 1)

        // The detach times out without the gate ever being released — the
        // retry must not wait on the wedged broker. The attach abandons that
        // connection and re-runs in an isolated namespace.
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            let isolatedOpenCount = await isolatedService.opened.count
            return session.agentState == .ready && isolatedOpenCount == 1
        }
        let isolatedBrokerId = try await #require(isolatedService.opened.first?.brokerId)
        #expect(isolatedBrokerId.rawValue.hasPrefix("fallback-"))
        #expect(isolatedBrokerId != originalBrokerId)

        let retriedRunner = try #require(manager.runners[session.id])
        #expect(retriedRunner !== originalRunner)
        let retriedLease = try store.loadLease(sessionId: session.id)
        #expect(retriedLease != nil)
        #expect(retriedLease?.token != originalLease?.token)

        // The abandoned replacement unwinds: its broker connection is closed.
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await sharedService.closed.count >= 1
        }
        #expect(session.agentState == .ready)
        await restart.value

        #expect(session.agentState == .ready)
        #expect(manager.runners[session.id] === retriedRunner)
        await manager.detach(sessionId: session.id)
    }

    @Test("restart detaches the retiring broker without closing it before replacement initialization")
    func restartRetainsRetiringBrokerUntilReplacementInitialization() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let service = ManagerBrokerService()
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { service },
            isolatedBrokerServiceFactory: { ManagerBrokerService() },
            attachmentStartupTimeout: .milliseconds(50),
            restartTeardownTimeout: .milliseconds(50)
        )
        let session = manager.createSession(id: "restart-retiring-broker", agentId: "claude")
        await manager.attach(to: session.id, freshlyCreated: true)
        #expect(session.agentState == .ready)

        await manager.restartConnection(to: session.id)

        #expect(session.agentState == .ready)
        #expect(await service.closed.isEmpty)
        #expect(await service.detached.count == 1)
        await manager.detach(sessionId: session.id)
    }

    @Test("restart retains a registered runner's broker while attach restoration is in flight")
    func restartRetainsRegisteredRunnerBrokerDuringAttachRestoration() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let retiringService = ManagerBrokerService()
        let replacementService = ManagerBrokerServiceProxy(stallSendMethod: "initialize")
        let registrationGate = ManagerBrokerGate()
        var serviceFactoryCalls = 0
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: {
                serviceFactoryCalls += 1
                if serviceFactoryCalls == 1 { return retiringService }
                return replacementService
            },
            isolatedBrokerServiceFactory: { ManagerBrokerService() },
            attachmentStartupTimeout: .seconds(10),
            restartTeardownTimeout: .seconds(1)
        )
        let session = manager.createSession(id: "restart-registered-runner", agentId: "claude")
        var registrationCount = 0
        manager.afterRunnerRegistrationForTesting = { _ in
            registrationCount += 1
            guard registrationCount == 1 else { return }
            await registrationGate.wait()
        }
        defer {
            Task {
                await registrationGate.release()
                await replacementService.sendGate.release()
            }
        }

        let initialAttach = Task { await manager.attach(to: session.id, freshlyCreated: true) }
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await registrationGate.hasEntered && manager.runners[session.id] != nil
        }
        #expect(session.agentState == .spawning)

        let restart = Task { await manager.restartConnection(to: session.id) }
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await replacementService.sendGate.hasEntered
        }

        #expect(await retiringService.closed.isEmpty)

        await registrationGate.release()
        await replacementService.sendGate.release()
        await initialAttach.value
        await restart.value

        #expect(session.agentState == .ready)
        #expect(await retiringService.closed.isEmpty)
        #expect(await retiringService.detached.count == 1)
        await manager.detach(sessionId: session.id)
    }

    @Test("disposing during restart does not strand a reopened session attachment")
    func disposingDuringRestartDoesNotStrandReopenedAttachment() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let service = ManagerBrokerServiceProxy(stallDetach: true)
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { service },
            isolatedBrokerServiceFactory: { ManagerBrokerService() },
            restartTeardownTimeout: .seconds(5)
        )
        let session = manager.createSession(id: "reopened-after-restart-dispose", agentId: "claude")
        await manager.attach(to: session.id, freshlyCreated: true)
        await manager.flushPersistence()

        let restart = Task { await manager.restartConnection(to: session.id) }
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await service.detachGate.hasEntered
        }

        try await manager.disposeSession(id: session.id)
        await service.detachGate.release()
        await restart.value

        let reopenedSession = try #require(manager.placeholderSession(id: session.id))
        await manager.hydrateIfNeeded(id: reopenedSession.id)
        let previousOpenCount = await service.opened.count
        let reopenedAttach = Task {
            await manager.attach(to: reopenedSession.id, freshlyCreated: false)
        }

        let openStart = DispatchTime.now().uptimeNanoseconds
        while await service.opened.count == previousOpenCount,
              DispatchTime.now().uptimeNanoseconds - openStart < 2_000_000_000 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let reopenedConnectionStarted = await service.opened.count > previousOpenCount

        let readyStart = DispatchTime.now().uptimeNanoseconds
        while reopenedSession.agentState != .ready,
              DispatchTime.now().uptimeNanoseconds - readyStart < 3_000_000_000 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let reopenedAttachmentCompleted = reopenedSession.agentState == .ready
        if !reopenedAttachmentCompleted {
            // Let the test fail on the stranded waiter without leaving an
            // unstructured attachment task behind on the broken behavior.
            await manager.restartConnection(to: reopenedSession.id)
        }
        await reopenedAttach.value

        #expect(reopenedConnectionStarted)
        #expect(reopenedAttachmentCompleted)
        #expect(reopenedSession.agentState == .ready)
        await manager.detach(sessionId: reopenedSession.id)
    }

    @Test("restored queue preserves uncertainty fields and marks legacy sends uncertain")
    func restoredQueuePreservesDeliveryUncertainty() async throws {
        let pending = QueuedPrompt(blocks: [.text("not sent")])
        #expect(pending.normalizedAfterRestore().lastError == nil)

        let legacySending = QueuedPrompt(blocks: [.text("possibly sent")], status: .sending)
            .normalizedAfterRestore()
        #expect(legacySending.status == .pending)
        #expect(legacySending.lastError?.localizedCaseInsensitiveContains("delivery is uncertain") == true)

        let id = UUID()
        let prompt = try queuedPromptFixture(
            id: id,
            text: "uncertain prompt",
            status: .pending,
            brokerGeneration: 7,
            deliveryUncertain: true,
            lastError: QueuedPrompt.deliveryUncertaintyMessage
        )
        let encoded = try JSONEncoder().encode(prompt)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["dispatchedBrokerGeneration"] as? Int == 7)
        #expect(object["deliveryUncertain"] as? Bool == true)
        #expect(try JSONDecoder().decode(QueuedPrompt.self, from: encoded) == prompt)

        var oldPendingJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(pending)) as? [String: Any])
        oldPendingJSON.removeValue(forKey: "dispatchedBrokerGeneration")
        oldPendingJSON.removeValue(forKey: "deliveryUncertain")
        let oldPendingData = try JSONSerialization.data(withJSONObject: oldPendingJSON)
        let decodedOldPending = try JSONDecoder().decode(QueuedPrompt.self, from: oldPendingData)
        #expect(decodedOldPending.dispatchedBrokerGeneration == nil)
        #expect(!decodedOldPending.deliveryUncertain)
        #expect(decodedOldPending.normalizedAfterRestore().lastError == nil)

        var oldSendingJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacySending)) as? [String: Any])
        oldSendingJSON["status"] = QueuedPrompt.Status.sending.rawValue
        oldSendingJSON.removeValue(forKey: "dispatchedBrokerGeneration")
        oldSendingJSON.removeValue(forKey: "deliveryUncertain")
        let oldSendingData = try JSONSerialization.data(withJSONObject: oldSendingJSON)
        let decodedOldSending = try JSONDecoder().decode(QueuedPrompt.self, from: oldSendingData)
        #expect(decodedOldSending.normalizedAfterRestore().deliveryUncertain)

        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        try store.upsertQueue(sessionId: "local", items: [prompt])
        let manager = manager(store: store, client: ACPMockClient())
        let restoredSession = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        #expect(restoredSession.queue == [prompt])
        #expect(restoredSession.queue.first?.deliveryUncertain == true)
        #expect(restoredSession.queue.first?.lastError == QueuedPrompt.deliveryUncertaintyMessage)
    }

    @Test("same broker generation replays uncertain-in-flight key through durable deduplication")
    func sameGenerationRestartReplaysDurableQueueKey() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let service = ManagerBrokerService(generation: 7, supportsPromptResponses: true)
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { service },
            attachmentStartupTimeout: .milliseconds(50),
            restartTeardownTimeout: .milliseconds(50)
        )
        let session = manager.createSession(id: "same-generation-queue-session", agentId: "claude")
        await manager.attach(to: session.id, freshlyCreated: true)
        await manager.flushAllPersistence()

        let dispatched = try queuedPromptFixture(
            text: "broker already completed this",
            status: .sending,
            brokerGeneration: 7
        )
        session.queue = [dispatched]
        manager.persistQueue(for: session)
        await manager.flushAllPersistence()

        let firstDelivery = try await service.send(ACPBrokerSendParams(
            brokerId: ACPBrokerID(rawValue: "local-\(session.id)"),
            generation: ACPBrokerGeneration(rawValue: 7),
            operationKey: ACPBrokerOperationKey(rawValue: dispatched.brokerOperationKey),
            method: "session/prompt",
            params: .object([:])
        ))
        #expect(!firstDelivery.replayed)

        await manager.restartConnection(to: session.id)
        try await waitUntil { session.queue.isEmpty }

        let replayedKeys = await service.replayedPromptOperationKeys.map(\.rawValue)
        #expect(replayedKeys == [dispatched.brokerOperationKey])
        #expect(session.agentState == .ready)
    }

    @Test("fresh broker leaves old queued prompts blocked while sending never-dispatched work")
    func newBrokerGenerationBlocksOnlyPossiblyDeliveredPrompts() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let sharedService = ManagerBrokerService(generation: 7, supportsPromptResponses: true)
        let isolatedService = ManagerBrokerService(generation: 8, supportsPromptResponses: true)
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { sharedService },
            isolatedBrokerServiceFactory: { isolatedService },
            attachmentStartupTimeout: .milliseconds(50),
            restartTeardownTimeout: .milliseconds(50)
        )
        let session = manager.createSession(id: "uncertain-queue-session", agentId: "claude")
        await manager.attach(to: session.id, freshlyCreated: true)
        await manager.flushAllPersistence()

        let neverSent = QueuedPrompt(blocks: [.text("never sent")])
        let possiblySent = try queuedPromptFixture(
            text: "sent but not acknowledged",
            status: .sending,
            brokerGeneration: 7
        )
        let pendingFromOldBroker = try queuedPromptFixture(
            text: "normalized after an interrupted send",
            status: .pending,
            brokerGeneration: 7
        )
        session.queue = [neverSent, possiblySent, pendingFromOldBroker]
        manager.persistQueue(for: session)
        await manager.flushAllPersistence()

        await sharedService.holdNextOpen()
        let oldRunner = try #require(manager.runners[session.id])
        let restart = Task { await manager.restartConnection(to: session.id) }
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await sharedService.openGate.hasEntered
                && session.agentState == .ready
                && manager.runners[session.id] !== oldRunner
        }
        await sharedService.openGate.release()
        await restart.value
        await manager.flushAllPersistence()

        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            let promptSends = await isolatedService.sent.filter { $0.method == "session/prompt" }
            return session.queue.map(\.id) == [possiblySent.id, pendingFromOldBroker.id]
                && promptSends.count == 1
        }
        #expect(session.queue.map(\.id) == [possiblySent.id, pendingFromOldBroker.id])
        #expect(session.queue.allSatisfy { $0.lastError?.localizedCaseInsensitiveContains("delivery is uncertain") == true })
        let promptSends = await isolatedService.sent.filter { $0.method == "session/prompt" }
        #expect(promptSends.count == 1)
        #expect(promptSends.first?.operationKey.rawValue == neverSent.brokerOperationKey)
    }

    @Test("restart before queued prompt handoff keeps the prompt eligible for delivery")
    func restartBeforeQueuedPromptHandoffKeepsPromptEligible() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let sharedService = ManagerBrokerService(generation: 7, supportsPromptResponses: true)
        let isolatedService = ManagerBrokerService(generation: 8, supportsPromptResponses: true)
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { sharedService },
            isolatedBrokerServiceFactory: { isolatedService },
            attachmentStartupTimeout: .milliseconds(50),
            restartTeardownTimeout: .milliseconds(50)
        )
        let session = manager.createSession(id: "pre-handoff-restart-session", agentId: "claude")
        await manager.attach(to: session.id, freshlyCreated: true)
        await manager.flushAllPersistence()

        let queued = QueuedPrompt(blocks: [.text("not handed off yet")])
        session.queue = [queued]
        manager.persistQueue(for: session)
        await manager.flushAllPersistence()

        let oldRunner = try #require(manager.runners[session.id])
        let provenanceGate = AttachPhaseGate()
        defer {
            Task {
                await provenanceGate.release()
                await sharedService.openGate.release()
            }
        }
        oldRunner.queueDispatchProvenancePersistedForTesting = { _ in
            await provenanceGate.enterAndWait()
        }
        oldRunner.flushQueueIfIdle()
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await provenanceGate.hasEntered
        }
        #expect(session.queue.first?.dispatchedBrokerGeneration == ACPBrokerGeneration(rawValue: 7))
        #expect(await sharedService.sent.filter { $0.method == "session/prompt" }.isEmpty)

        await sharedService.holdNextOpen()
        let restart = Task { await manager.restartConnection(to: session.id) }
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await sharedService.openGate.hasEntered
                && session.agentState == .ready
                && manager.runners[session.id] !== oldRunner
        }
        await sharedService.openGate.release()
        await restart.value
        await manager.flushAllPersistence()

        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            let sends = await isolatedService.sent.filter { $0.method == "session/prompt" }
            return sends.count == 1 && session.queue.isEmpty
        }
        let replacementPrompt = try #require(
            await isolatedService.sent.first { $0.method == "session/prompt" }
        )
        #expect(replacementPrompt.operationKey.rawValue == queued.brokerOperationKey)
        #expect(session.queue.isEmpty)

        await provenanceGate.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await sharedService.sent.filter { $0.method == "session/prompt" }.isEmpty)
        #expect(try store.loadQueue(sessionId: session.id).isEmpty)
    }

    @Test("detaching before queued prompt handoff keeps the prompt eligible")
    func detachBeforeQueuedPromptHandoffKeepsPromptEligible() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let oldService = ManagerBrokerService(generation: 7, supportsPromptResponses: true)
        let replacementService = ManagerBrokerService(generation: 8, supportsPromptResponses: true)
        var serviceFactoryCalls = 0
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: {
                serviceFactoryCalls += 1
                return serviceFactoryCalls == 1 ? oldService : replacementService
            },
            isolatedBrokerServiceFactory: { replacementService },
            attachmentStartupTimeout: .seconds(2)
        )
        let session = manager.createSession(id: "pre-handoff-detach-session", agentId: "claude")
        await manager.attach(to: session.id, freshlyCreated: true)
        await manager.flushAllPersistence()

        let queued = QueuedPrompt(blocks: [.text("not handed off before detach")])
        session.queue = [queued]
        manager.persistQueue(for: session)
        await manager.flushAllPersistence()

        let oldRunner = try #require(manager.runners[session.id])
        let provenanceGate = AttachPhaseGate()
        defer {
            Task { await provenanceGate.release() }
        }
        oldRunner.queueDispatchProvenancePersistedForTesting = { _ in
            await provenanceGate.enterAndWait()
        }
        oldRunner.flushQueueIfIdle()
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await provenanceGate.hasEntered
        }
        #expect(session.queue.first?.dispatchedBrokerGeneration == ACPBrokerGeneration(rawValue: 7))
        #expect(await oldService.sent.filter { $0.method == "session/prompt" }.isEmpty)

        await manager.detach(sessionId: session.id)
        await provenanceGate.release()
        try await Task.sleep(for: .milliseconds(50))

        #expect(session.queue.first?.status == .pending)
        #expect(session.queue.first?.dispatchedBrokerGeneration == nil)
        #expect(session.queue.first?.deliveryUncertain == false)
        #expect(await oldService.sent.filter { $0.method == "session/prompt" }.isEmpty)
        #expect(try store.loadQueue(sessionId: session.id).first?.dispatchedBrokerGeneration == nil)

        let reopenedSession = try #require(manager.placeholderSession(id: session.id))
        await manager.hydrateIfNeeded(id: reopenedSession.id)
        await manager.attach(to: reopenedSession.id, freshlyCreated: false)
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await replacementService.sent.contains { $0.method == "session/prompt" }
        }
        await manager.flushAllPersistence()

        let replacementPrompt = try #require(
            await replacementService.sent.first { $0.method == "session/prompt" }
        )
        #expect(replacementPrompt.operationKey.rawValue == queued.brokerOperationKey)
        #expect(reopenedSession.queue.isEmpty)
        #expect(try store.loadQueue(sessionId: session.id).isEmpty)
        await manager.detach(sessionId: session.id)
    }

    @Test("restart fences a suspended takeover continuation")
    func restartFencesSuspendedTakeoverContinuation() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let sessionId = "restart-during-takeover-session"
        try store.upsertSession(row(id: sessionId, remoteSessionId: "remote-takeover"))
        let now = Int64(Date().timeIntervalSince1970)
        #expect(try store.claimLease(
            sessionId: sessionId,
            instanceId: "previous-owner",
            pid: Int64(getpid()),
            now: now,
            staleAfter: 60
        ))

        let takeoverGate = AttachPhaseGate()
        let setupGate = AttachPhaseGate()
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-takeover")
        var launchCount = 0
        var takeoverResumed = false
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            instanceId: "taking-over-owner",
            setupEvaluator: { _ in
                await setupGate.enterAndWait()
                return .ready
            },
            connectionFactory: { _, _, _ in
                launchCount += 1
                return ACPConnection(client: client)
            }
        )
        manager.beforeTakeoverAttachForTesting = { _ in
            await takeoverGate.enterAndWait()
            takeoverResumed = true
        }
        let session = try #require(manager.placeholderSession(id: sessionId))
        await manager.hydrateIfNeeded(id: session.id)
        await manager.refreshMirror(sessionId: session.id)

        #expect(await manager.takeOver(sessionId: session.id))
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await takeoverGate.hasEntered
        }
        #expect(session.agentState == .spawning)

        let restart = Task { await manager.restartConnection(to: session.id) }
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            await setupGate.hasEntered
        }
        await takeoverGate.release()
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            takeoverResumed
        }
        #expect(session.agentState == .spawning)

        await setupGate.release()
        await restart.value
        try await waitUntilAsync(timeoutNanos: 2_000_000_000) {
            session.agentState == .ready && manager.runners[session.id] != nil
        }
        #expect(launchCount == 1)
        #expect(session.agentState == .ready)
        await manager.detach(sessionId: session.id)
    }

    @Test("retrying uncertain queued prompt advances its durable key once")
    func retryingUncertainQueuedPromptAdvancesOperationAttempt() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-retry")
        client.script(method: "session/prompt") { _ in Data("null".utf8) }
        let manager = manager(store: store, client: client)
        let session = manager.createSession(agentId: "claude")
        await manager.attach(to: session.id, freshlyCreated: true)

        let uncertain = try queuedPromptFixture(
            text: "deliver only on request",
            status: .pending,
            brokerGeneration: 7,
            deliveryUncertain: true,
            lastError: "Delivery is uncertain. Retry to send this prompt again."
        )
        session.queue = [uncertain]
        manager.persistQueue(for: session)
        await manager.flushAllPersistence()

        await manager.queueRetry(for: session.id, itemId: uncertain.id)
        await manager.queueRetry(for: session.id, itemId: uncertain.id)
        try await waitUntil { session.queue.isEmpty }

        let promptRequests = client.sent.filter { $0.method == "session/prompt" }
        #expect(promptRequests.count == 1)
        #expect(promptRequests.first?.brokerOperationKey == QueuedPrompt(
            id: uncertain.id,
            blocks: uncertain.blocks,
            brokerOperationAttempt: 1
        ).brokerOperationKey)
    }

    @Test("new session attaches the current project MCP plan")
    func newSessionAttachesCurrentProjectMCPPlan() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let configuredServers = [ProjectMCPServer.stdio(name: "filesystem", command: "mcp-files")]
        let manager = manager(store: store, client: client, mcpProjectContextProvider: {
            MCPProjectContext(projectDirectory: "/tmp/project", configuredServers: configuredServers)
        })
        let session = manager.createSession(agentId: "claude")

        await manager.attach(to: session.id, freshlyCreated: true)

        let params = try #require(client.sent.last?.params as? ACPSessionNewParams)
        #expect(params.mcpServers == [.stdio(name: "filesystem", command: "mcp-files", args: [], env: [])])
        let summary = try #require(session.mcpAttachmentSummary)
        #expect(summary.statuses == [.init(id: "0", name: "filesystem", transport: .stdio, disposition: .requested)])
        #expect(summary.configurationFingerprint == MCPAttachmentPlanner.configurationFingerprint(for: configuredServers))
    }

    @Test("local attach uses broker client and persists durable broker state")
    func localAttachUsesBrokerClientAndPersistsDurableState() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let broker = ManagerBrokerService()
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { broker }
        )
        let session = manager.createSession(id: "local-session-1", agentId: "claude")

        await manager.attach(to: session.id, freshlyCreated: true)
        await manager.flushAllPersistence()

        let openParams = try await #require(broker.opened.first)
        #expect(openParams.brokerId == ACPBrokerID(rawValue: "local-local-session-1"))
        #expect(openParams.sessionId == "local-session-1")
        #expect(openParams.command.isEmpty == false)
        #expect(openParams.cwd == "/tmp/wt")
        #expect(openParams.env["PATH"] != nil)
        #expect(await broker.sent.map(\.method) == ["initialize", "session/new"])
        #expect(session.remoteSessionId == "remote-broker")
        #expect(session.agentState == .ready)

        let row = try #require(try store.loadSession(id: "local-session-1"))
        #expect(row.remoteSessionId == "remote-broker")
        #expect(row.acpBrokerId == "local-local-session-1")
        #expect(row.acpBrokerGeneration == 7)
        #expect(row.acpBrokerAcknowledgedCursor == 0)
    }

    @Test("auth-required runner teardown notifies queue cleanup")
    func authRequiredRunnerTeardownNotifiesQueueCleanup() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        let method = terminalAuthMethod()
        scriptInitialize(client, authMethods: [method])
        scriptSessionResult(client, method: "session/new", sessionId: "remote-auth")
        client.script(method: "session/prompt") { _ in
            throw JSONRPCError(
                code: -32000,
                message: "Internal error: authentication required",
                data: nil
            )
        }
        var queueChanges: [(ACPSession.ID, Bool)] = []
        let manager = manager(store: store, client: client, onQueueChanged: { sessionId, retainActivePrompt in
            queueChanges.append((sessionId, retainActivePrompt))
        })
        let session = manager.createSession(id: "auth-session", agentId: "claude")
        await manager.attach(to: session.id, freshlyCreated: true)

        await manager.sendPrompt(for: session.id, text: "hello", attachments: []) { _ in }
        try await waitUntil {
            queueChanges.contains { $0.0 == session.id && $0.1 == false }
        }

        #expect(session.agentState == .failed("authentication required"))
        #expect(queueChanges.contains { $0.0 == session.id && $0.1 == false })
    }

    @Test("bootstrap attaches overdue persisted scheduled queues")
    func bootstrapAttachesOverduePersistedScheduledQueues() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let seeded = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let seededSession = seeded.createSession(id: "scheduled-session", agentId: "claude")
        seeded.enqueueWhileRecovering(
            text: "overdue",
            attachments: [],
            scheduledAt: Date().addingTimeInterval(-1),
            into: seededSession.id
        )
        await seeded.flushPersistence()

        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-scheduled")
        client.script(method: "session/prompt") { _ in Data("null".utf8) }
        let manager = manager(store: store, client: client)

        let bootstrapped = await manager.bootstrapScheduledQueueSessions()
        try await waitUntilAsync {
            client.sent.contains { $0.method == "session/prompt" }
        }

        #expect(bootstrapped == [seededSession.id])
        #expect(try store.loadQueue(sessionId: seededSession.id).isEmpty)
    }

    @Test("bootstrap defers future scheduled queues until deadline")
    func bootstrapDefersFutureScheduledQueuesUntilDeadline() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: nil))
        try store.upsertQueue(sessionId: "local", items: [
            QueuedPrompt(blocks: [.text("later")], scheduledAt: Date().addingTimeInterval(60))
        ])
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = manager(store: store, client: client)

        let bootstrapped = await manager.bootstrapScheduledQueueSessions()

        #expect(bootstrapped == ["local"])
        #expect(client.sent.isEmpty)
    }

    @Test("bootstrapped scheduled mirror claims released lease at deadline")
    func bootstrappedScheduledMirrorClaimsReleasedLeaseAtDeadline() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-existing"))
        try store.upsertQueue(sessionId: "local", items: [
            QueuedPrompt(blocks: [.text("due soon")], scheduledAt: Date().addingTimeInterval(0.3))
        ])
        try store.seizeLease(
            sessionId: "local",
            instanceId: "OTHER",
            pid: Int64(getpid()),
            now: Int64(Date().timeIntervalSince1970)
        )
        let lease = try #require(try store.loadLease(sessionId: "local"))
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-existing")
        client.script(method: "session/prompt") { _ in Data("null".utf8) }
        let manager = manager(store: store, client: client)

        let bootstrapped = await manager.bootstrapScheduledQueueSessions()
        try store.releaseLease(sessionId: "local", instanceId: "OTHER", leaseToken: lease.token)
        try await waitUntil(timeoutNanos: 2_000_000_000) {
            client.sent.contains { $0.method == "session/prompt" }
        }
        try await waitUntil(timeoutNanos: 2_000_000_000) {
            (try? store.loadQueue(sessionId: "local").isEmpty) == true
        }

        #expect(bootstrapped == ["local"])
        #expect(try store.loadQueue(sessionId: "local").isEmpty)
    }

    @Test("reopened local broker session attaches from persisted cursor")
    func reopenedLocalBrokerSessionAttachesFromPersistedCursor() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(.init(
            id: "local-session-1",
            agentId: "claude",
            title: "Stored session",
            titleSource: .placeholder,
            remoteSessionId: "remote-old",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            acpBrokerId: "broker-existing",
            acpBrokerGeneration: 7,
            acpBrokerAcknowledgedCursor: 4,
            createdAt: 0,
            updatedAt: 0,
            lastOpenedAt: 0,
            archived: false
        ))
        let broker = ManagerBrokerService()
        await broker.setSnapshotResults(
            initializeResult: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([
                    "loadSession": .bool(true),
                    "sessionCapabilities": .object(["resume": .object([:])])
                ]),
                "authMethods": .array([])
            ]),
            remoteSessionResult: .object([
                "sessionId": .string("remote-restored"),
                "availableModels": .array([]),
                "availableModes": .array([]),
                "promptSuggestions": .array([]),
                "configOptions": .array([])
            ])
        )
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { broker }
        )

        let session = try #require(manager.placeholderSession(id: "local-session-1"))
        await manager.hydrateIfNeeded(id: session.id)
        await manager.attach(to: session.id, freshlyCreated: false)
        await manager.flushAllPersistence()

        let openParams = try await #require(broker.opened.first)
        #expect(openParams.brokerId == ACPBrokerID(rawValue: "broker-existing"))
        let attachParams = try await #require(broker.attached.first)
        #expect(attachParams.acknowledgedCursor == ACPBrokerEventCursor(rawValue: 4))
        #expect(await broker.sent.isEmpty)
        #expect(session.remoteSessionId == "remote-restored")
        #expect(session.agentState == .ready)

        let row = try #require(try store.loadSession(id: "local-session-1"))
        #expect(row.acpBrokerId == "broker-existing")
        #expect(row.acpBrokerGeneration == 7)
        #expect(row.acpBrokerAcknowledgedCursor == 4)
    }

    @Test("reopened session uses session/load")
    func reopenedSessionUsesLoad() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-restored")
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        let methods = client.sent.map(\.method)
        #expect(methods == ["initialize", "session/load"])
        #expect(session.remoteSessionId == "remote-restored")
        #expect(session.contextRestoreWarning == nil)
        #expect(try store.loadSession(id: "local")?.remoteSessionId == "remote-restored")
    }

    @Test("fresh session/new sets a pending MCP preamble when servers attach")
    func freshSessionSetsPendingPreamble() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let configuredServers = [ProjectMCPServer.stdio(name: "filesystem", command: "mcp-files")]
        let manager = manager(store: store, client: client, mcpProjectContextProvider: {
            MCPProjectContext(projectDirectory: "/tmp/project", configuredServers: configuredServers)
        })
        let session = manager.createSession(agentId: "claude")

        await manager.attach(to: session.id, freshlyCreated: true)

        #expect(session.pendingMCPPreamble?.contains("filesystem") == true)
        #expect(session.mcpPreambleSent == false)
    }

    @Test("loaded session does not reset the MCP preamble")
    func loadedSessionDoesNotResetPreamble() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-restored")
        let configuredServers = [ProjectMCPServer.stdio(name: "filesystem", command: "mcp-files")]
        let manager = manager(store: store, client: client, mcpProjectContextProvider: {
            MCPProjectContext(projectDirectory: "/tmp/project", configuredServers: configuredServers)
        })

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize", "session/load"])
        #expect(session.pendingMCPPreamble == nil)
    }

    @Test("fresh remote session preamble omits built-in but names a surviving user server")
    func freshRemoteSessionPreambleOmitsBuiltInButNamesUserServer() async throws {
        let root = "/srv/task4-remote-preamble-\(UUID().uuidString)"
        RemoteHostRegistry.shared.register(root: root, host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: root) }
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        client.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: .init(mcpCapabilities: .init(http: true)),
                authMethods: []
            ))
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let configuredServers = [
            ProjectMCPServer(
                id: UUID().uuidString,
                name: "docs",
                transport: .http(url: "https://mcp.example.com/docs", headers: [])
            )
        ]
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: root,
            store: store,
            remoteAdapterResolver: { _, _, _ in
                .ready(.init(adapterPath: "/home/dev/.alas/acp/codex/bin/codex-acp", nodeBinDirectory: ""))
            },
            connectionFactory: { _, _, _ in ACPConnection(client: client) },
            mcpProjectContextProvider: {
                MCPProjectContext(projectDirectory: root, configuredServers: configuredServers)
            }
        )
        let session = manager.createSession(agentId: "codex")

        await manager.attach(to: session.id, freshlyCreated: true)

        let preamble = try #require(session.pendingMCPPreamble)
        #expect(preamble.contains("(built-in)") == false)
        #expect(preamble.contains("docs") == true)
        #expect(session.mcpPreambleSent == false)
    }

    @Test("local attach merges alas CLI env into the launch spec")
    func localAttachMergesCLIEnv() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        var capturedSpec: ACPLaunchSpec?
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { spec, _, _ in
                capturedSpec = spec
                return ACPConnection(client: client)
            }
        )
        let session = manager.createSession(agentId: "claude")
        manager.alasCLIEnvProvider = { _, sessionId in
            ["ALAS_SESSION_ID": sessionId, "PATH": "/managed/bin:/usr/bin"]
        }

        await manager.attach(to: session.id, freshlyCreated: true)

        let spec = try #require(capturedSpec)
        #expect(spec.extraEnv["ALAS_SESSION_ID"] == session.id)
        #expect(spec.extraEnv["PATH"] == "/managed/bin:/usr/bin")
        #expect(session.terminalHost.sessionEnv["ALAS_SESSION_ID"] == session.id)
        #expect(session.terminalHost.sessionEnv["PATH"] == "/managed/bin:/usr/bin")
    }

    @Test("remote attach skips alas CLI env")
    func remoteAttachSkipsCLIEnv() async throws {
        let root = "/srv/task3-remote-cli-env-\(UUID().uuidString)"
        RemoteHostRegistry.shared.register(root: root, host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: root) }
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        var capturedSpec: ACPLaunchSpec?
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: root,
            store: store,
            remoteAdapterResolver: { _, _, _ in
                .ready(.init(adapterPath: "/home/dev/.alas/acp/codex/bin/codex-acp", nodeBinDirectory: ""))
            },
            connectionFactory: { spec, _, _ in
                capturedSpec = spec
                return ACPConnection(client: client)
            }
        )
        let session = manager.createSession(agentId: "codex")
        manager.alasCLIEnvProvider = { _, sessionId in
            ["ALAS_SESSION_ID": sessionId, "PATH": "/managed/bin:/usr/bin"]
        }

        await manager.attach(to: session.id, freshlyCreated: true)

        let spec = try #require(capturedSpec)
        #expect(spec.extraEnv["ALAS_SESSION_ID"] == nil)
        #expect(spec.extraEnv["PATH"] != "/managed/bin:/usr/bin")
    }

    @Test("fresh pi attach with CLI env active produces a CLI-mode preamble")
    func freshPiAttachProducesCLIModePreamble() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = manager.createSession(agentId: ACPLaunchCatalog.spec(for: "pi")!.agentID)
        manager.alasCLIEnvProvider = { _, sessionId in
            ["ALAS_SESSION_ID": sessionId, "PATH": "/managed/bin:/usr/bin"]
        }

        await manager.attach(to: session.id, freshlyCreated: true)

        let preamble = try #require(session.pendingMCPPreamble)
        #expect(preamble.contains("alas open"))
        #expect(!preamble.contains("MCP server \"alas\""))
    }

    @Test("local pi attach invokes the external MCP status provider")
    func localPiAttachInvokesExternalMCPStatusProvider() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = manager.createSession(agentId: ACPLaunchCatalog.spec(for: "pi")!.agentID)
        var providerCalled = false
        manager.externalMCPStatusProvider = { _ in
            providerCalled = true
            return (adapterState: .installed, configOutcome: .wrote, userServerNames: [], skippedServerStatuses: [], requestedServerStatuses: [])
        }

        await manager.attach(to: session.id, freshlyCreated: true)

        #expect(providerCalled)
        #expect(session.mcpExternalStatus?.adapterState == .installed)
        #expect(session.mcpExternalStatus?.configOutcome == .wrote)
    }

    @Test("pi attach preamble names http/sse-only servers from the external plan")
    func piAttachPreambleNamesExternalPlanServers() async throws {
        // Regression guard: `wireMCPServers` is planned against pi's real
        // (http/sse-less) ACP capabilities and would drop an http/sse-only
        // server, but `.pi/mcp.json` is written from the external plan's
        // all-transports resolution and DOES include it. The preamble must
        // use the external status's resolved names, not `wireMCPServers`,
        // or it silently omits the `mcp()` hint for exactly the servers
        // this feature exists to surface.
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = manager.createSession(agentId: ACPLaunchCatalog.spec(for: "pi")!.agentID)
        manager.alasCLIEnvProvider = { _, sessionId in
            ["ALAS_SESSION_ID": sessionId, "PATH": "/managed/bin:/usr/bin"]
        }
        manager.externalMCPStatusProvider = { _ in
            (adapterState: .installed, configOutcome: .wrote, userServerNames: ["docs-http"], skippedServerStatuses: [], requestedServerStatuses: [])
        }

        await manager.attach(to: session.id, freshlyCreated: true)

        let preamble = try #require(session.pendingMCPPreamble)
        #expect(preamble.contains("docs-http"))
        #expect(preamble.contains("mcp()"))
    }

    @Test("remote pi attach skips the external MCP status provider")
    func remotePiAttachSkipsExternalMCPStatusProvider() async throws {
        let root = "/srv/task5-remote-external-mcp-\(UUID().uuidString)"
        RemoteHostRegistry.shared.register(root: root, host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: root) }
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: root,
            store: store,
            remoteAdapterResolver: { _, _, _ in
                .ready(.init(adapterPath: "/home/dev/.alas/acp/pi/bin/pi-acp", nodeBinDirectory: ""))
            },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = manager.createSession(agentId: ACPLaunchCatalog.spec(for: "pi")!.agentID)
        var providerCalled = false
        manager.externalMCPStatusProvider = { _ in
            providerCalled = true
            return (adapterState: .installed, configOutcome: .wrote, userServerNames: [], skippedServerStatuses: [], requestedServerStatuses: [])
        }

        await manager.attach(to: session.id, freshlyCreated: true)

        #expect(!providerCalled)
        #expect(session.mcpExternalStatus?.adapterState == .unknown)
        #expect(session.mcpExternalStatus?.cliActive == false)
        #expect(session.mcpExternalStatus?.configOutcome == nil)
    }

    @Test("remote pi attach preserves configured MCP server names as unavailable")
    func remotePiAttachPreservesConfiguredMCPServerNames() async throws {
        let root = "/srv/task5-remote-external-mcp-names-\(UUID().uuidString)"
        RemoteHostRegistry.shared.register(root: root, host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: root) }
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let configuredServers = [
            ProjectMCPServer.stdio(name: "linear", command: "linear-mcp")
        ]
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: root,
            store: store,
            remoteAdapterResolver: { _, _, _ in
                .ready(.init(adapterPath: "/home/dev/.alas/acp/pi/bin/pi-acp", nodeBinDirectory: ""))
            },
            connectionFactory: { _, _, _ in ACPConnection(client: client) },
            mcpProjectContextProvider: {
                MCPProjectContext(projectDirectory: root, configuredServers: configuredServers)
            }
        )
        let session = manager.createSession(agentId: ACPLaunchCatalog.spec(for: "pi")!.agentID)

        await manager.attach(to: session.id, freshlyCreated: true)

        #expect(session.mcpExternalStatus?.userServerNames == ["linear"])
        #expect(session.mcpExternalStatus?.adapterServerAvailability == .notInstalled)
        #expect(session.mcpExternalStatus?.canInstallAdapterLocally == false)
        let preamble = try #require(session.pendingMCPPreamble)
        #expect(preamble.contains("linear"))
        #expect(preamble.contains("cannot be reached"))
    }

    @Test("Codex-style load response without session id restores normally")
    func codexStyleLoadResponseWithoutSessionIdRestoresNormally() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            Data("""
            {
              "models": {
                "currentModelId": "gpt-5",
                "availableModels": []
              },
              "modes": {
                "currentModeId": "default",
                "availableModes": []
              },
              "configOptions": []
            }
            """.utf8)
        }
        client.script(method: "session/new") { _ in
            Issue.record("session/new should not be called when session/load succeeds without a sessionId")
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize", "session/load"])
        #expect(session.remoteSessionId == "remote-old")
        #expect(session.currentModel == "gpt-5")
        #expect(session.currentMode == "default")
        #expect(session.contextRestoreWarning == nil)
        #expect(try store.loadSession(id: "local")?.remoteSessionId == "remote-old")
    }

    @Test("reopened session reapplies its persisted model after load")
    func reopenedSessionReappliesPersistedModel() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet"
        ))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [
                    .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "opus", name: "Opus"),
                ],
                availableModes: [],
                currentModel: "opus",
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        client.script(method: "session/set_model") { _ in Data("{}".utf8) }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        try await waitUntil {
            client.sent.map(\.method) == ["initialize", "session/load", "session/set_model"]
        }
        let params = try #require(client.sent.last?.params as? ACPSessionSetModelParams)
        #expect(params.sessionId == "remote-old")
        #expect(params.modelId == "sonnet")
        #expect(session.currentModel == "sonnet")
    }

    @Test("user model and mode edits follow reconnect restoration")
    func userModelAndModeEditsFollowReconnectRestoration() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet",
            currentMode: "plan"
        ))
        let client = ACPMockClient()
        let modelGate = AttachPhaseGate()
        let modeGate = AttachPhaseGate()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [
                    .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "opus", name: "Opus"),
                    .init(id: "haiku", name: "Haiku"),
                ],
                availableModes: [
                    .init(id: "default", name: "Default"),
                    .init(id: "plan", name: "Plan"),
                    .init(id: "ask", name: "Ask"),
                ],
                currentModel: "opus",
                currentMode: "default",
                promptSuggestions: []
            ))
        }
        client.scriptAsync(method: "session/set_model") { _ in
            await modelGate.enterAndWait()
            return Data("{}".utf8)
        }
        client.scriptAsync(method: "session/set_mode") { _ in
            await modeGate.enterAndWait()
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))

        await manager.hydrateIfNeeded(id: "local")
        let attachTask = Task {
            await manager.attach(to: session.id, freshlyCreated: false)
        }
        try await waitUntilAsync { await modelGate.hasEntered }

        await manager.setModel(for: session.id, modelId: "haiku")
        #expect(client.sent.filter { $0.method == "session/set_model" }.count == 1)
        await modelGate.release()
        try await waitUntilAsync { await modeGate.hasEntered }

        await manager.setMode(for: session.id, modeId: "ask")
        #expect(client.sent.filter { $0.method == "session/set_mode" }.count == 1)
        await modeGate.release()
        await attachTask.value
        await manager.flushAllPersistence()

        let selectionRequests = client.sent.filter {
            $0.method == "session/set_model" || $0.method == "session/set_mode"
        }
        #expect(selectionRequests.map(\.method) == [
            "session/set_model",
            "session/set_mode",
            "session/set_model",
            "session/set_mode",
        ])
        let modelParams = try selectionRequests
            .filter { $0.method == "session/set_model" }
            .map { try #require($0.params as? ACPSessionSetModelParams) }
        let modeParams = try selectionRequests
            .filter { $0.method == "session/set_mode" }
            .map { try #require($0.params as? ACPSessionSetModeParams) }
        #expect(modelParams.map(\.modelId) == ["sonnet", "haiku"])
        #expect(modeParams.map(\.modeId) == ["plan", "ask"])
        #expect(session.currentModel == "haiku")
        #expect(session.currentMode == "ask")
        #expect(try store.loadSession(id: "local")?.currentModel == "haiku")
        #expect(try store.loadSession(id: "local")?.currentMode == "ask")
    }

    @Test("pre-attach model and mode picks apply after lease acquisition")
    func preAttachModelAndModePicksApplyAfterLeaseAcquisition() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet",
            currentMode: "plan"
        ))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [
                    .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "haiku", name: "Haiku"),
                ],
                availableModes: [
                    .init(id: "default", name: "Default"),
                    .init(id: "plan", name: "Plan"),
                    .init(id: "ask", name: "Ask"),
                ],
                currentModel: "sonnet",
                currentMode: "default",
                promptSuggestions: []
            ))
        }
        client.script(method: "session/set_model") { _ in Data("{}".utf8) }
        client.script(method: "session/set_mode") { _ in Data("{}".utf8) }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))

        await manager.hydrateIfNeeded(id: "local")
        await manager.setModel(for: session.id, modelId: "haiku")
        await manager.setMode(for: session.id, modeId: "ask")
        manager.renameSession(id: session.id, title: "Renamed", source: .manual)
        #expect(client.sent.isEmpty)

        await manager.flushAllPersistence()
        #expect(session.currentModel == "haiku")
        #expect(session.currentMode == "ask")
        #expect(try store.loadSession(id: "local")?.title == "Renamed")
        #expect(try store.loadSession(id: "local")?.currentModel == "sonnet")
        #expect(try store.loadSession(id: "local")?.currentMode == "plan")

        await manager.attach(to: session.id, freshlyCreated: false)
        try await waitUntil {
            client.sent.map(\.method) == [
                "initialize",
                "session/load",
                "session/set_model",
                "session/set_mode",
            ]
        }
        await manager.flushAllPersistence()

        let modelParams = try #require(
            client.sent.first { $0.method == "session/set_model" }?.params as? ACPSessionSetModelParams
        )
        let modeParams = try #require(
            client.sent.first { $0.method == "session/set_mode" }?.params as? ACPSessionSetModeParams
        )
        #expect(modelParams.modelId == "haiku")
        #expect(modeParams.modeId == "ask")
        #expect(session.currentModel == "haiku")
        #expect(session.currentMode == "ask")
        #expect(try store.loadSession(id: "local")?.currentModel == "haiku")
        #expect(try store.loadSession(id: "local")?.currentMode == "ask")
    }

    @Test("manual detach clears deferred model and mode picks")
    func manualDetachClearsDeferredModelModePicks() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet",
            currentMode: "plan"
        ))
        let firstClient = ACPMockClient()
        let secondClient = ACPMockClient()
        let modelGate = AttachPhaseGate()
        scriptInitialize(firstClient)
        scriptInitialize(secondClient)
        firstClient.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [
                    .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "haiku", name: "Haiku"),
                    .init(id: "opus", name: "Opus"),
                ],
                availableModes: [
                    .init(id: "plan", name: "Plan"),
                    .init(id: "act", name: "Act"),
                ],
                currentModel: "opus",
                currentMode: "plan",
                promptSuggestions: []
            ))
        }
        firstClient.scriptAsync(method: "session/set_model") { _ in
            await modelGate.enterAndWait()
            return Data("{}".utf8)
        }
        secondClient.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [
                    .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "haiku", name: "Haiku"),
                    .init(id: "opus", name: "Opus"),
                ],
                availableModes: [
                    .init(id: "plan", name: "Plan"),
                    .init(id: "act", name: "Act"),
                ],
                currentModel: "haiku",
                currentMode: "act",
                promptSuggestions: []
            ))
        }
        secondClient.script(method: "session/set_model") { _ in Data("{}".utf8) }
        secondClient.script(method: "session/set_mode") { _ in Data("{}".utf8) }

        let clients = [firstClient, secondClient]
        var connectionIndex = 0
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in
                let client = clients[connectionIndex]
                connectionIndex += 1
                return ACPConnection(client: client)
            }
        )
        let session = try #require(manager.placeholderSession(id: "local"))
        manager.retainSession(id: session.id)
        defer { manager.releaseSession(id: session.id) }

        await manager.hydrateIfNeeded(id: session.id)
        let firstAttach = Task {
            await manager.attach(to: session.id, freshlyCreated: false)
        }
        try await waitUntilAsync { await modelGate.hasEntered }

        await manager.setModel(for: session.id, modelId: "haiku")
        await manager.setMode(for: session.id, modeId: "act")
        await manager.detach(sessionId: session.id)
        await manager.setModel(for: session.id, modelId: "sonnet")
        await manager.setMode(for: session.id, modeId: "plan")
        await modelGate.release()
        await firstAttach.value

        await manager.attach(to: session.id, freshlyCreated: false)
        await manager.flushAllPersistence()

        let modelParams = try secondClient.sent
            .filter { $0.method == "session/set_model" }
            .map { try #require($0.params as? ACPSessionSetModelParams) }
        let modeParams = try secondClient.sent
            .filter { $0.method == "session/set_mode" }
            .map { try #require($0.params as? ACPSessionSetModeParams) }
        #expect(modelParams.map(\.modelId) == ["sonnet"])
        #expect(modeParams.map(\.modeId) == ["plan"])
        #expect(session.currentModel == "sonnet")
        #expect(session.currentMode == "plan")
        #expect(try store.loadSession(id: session.id)?.currentModel == "sonnet")
        #expect(try store.loadSession(id: session.id)?.currentMode == "plan")
    }

    @Test("model and mode picks are rejected on a live mirror")
    func modelAndModePicksAreRejectedOnLiveMirror() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet",
            currentMode: "plan"
        ))
        let now = Int64(Date().timeIntervalSince1970)
        #expect(try store.claimLease(
            sessionId: "local",
            instanceId: "other-instance",
            pid: Int64(getpid()),
            now: now,
            staleAfter: 60
        ))

        let client = ACPMockClient()
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.refreshMirror(sessionId: "local")

        await manager.setModel(for: session.id, modelId: "haiku")
        await manager.setMode(for: session.id, modeId: "ask")

        #expect(client.sent.isEmpty)
        #expect(session.currentModel == "sonnet")
        #expect(session.currentMode == "plan")
        #expect(try store.loadSession(id: "local")?.currentModel == "sonnet")
        #expect(try store.loadSession(id: "local")?.currentMode == "plan")
    }

    @Test("model and mode picks wait for the initial lease claim")
    func modelAndModePicksWaitForInitialLeaseClaim() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet",
            currentMode: "plan"
        ))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [
                    .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "haiku", name: "Haiku"),
                ],
                availableModes: [
                    .init(id: "default", name: "Default"),
                    .init(id: "plan", name: "Plan"),
                    .init(id: "ask", name: "Ask"),
                ],
                currentModel: "sonnet",
                currentMode: "default",
                promptSuggestions: []
            ))
        }
        client.script(method: "session/set_model") { _ in Data("{}".utf8) }
        client.script(method: "session/set_mode") { _ in Data("{}".utf8) }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")

        // Simulate a stale local ownership marker while the first lease
        // observation is pending. A pick must not write without its token.
        session.agentState = .spawning
        manager._ownedLeases.insert(session.id)
        await manager.setModel(for: session.id, modelId: "haiku")
        await manager.setMode(for: session.id, modeId: "ask")
        await manager.flushAllPersistence()

        #expect(client.sent.isEmpty)
        #expect(session.currentModel == "haiku")
        #expect(session.currentMode == "ask")
        #expect(try store.loadSession(id: "local")?.currentModel == "sonnet")
        #expect(try store.loadSession(id: "local")?.currentMode == "plan")

        session.agentState = .idle
        await manager.attach(to: session.id, freshlyCreated: false)
        try await waitUntil {
            client.sent.map(\.method) == [
                "initialize",
                "session/load",
                "session/set_model",
                "session/set_mode",
            ]
        }
        await manager.flushAllPersistence()

        #expect(session.currentModel == "haiku")
        #expect(session.currentMode == "ask")
        #expect(try store.loadSession(id: "local")?.currentModel == "haiku")
        #expect(try store.loadSession(id: "local")?.currentMode == "ask")
    }

    @Test("rapid model and mode picks reach the agent in selection order")
    func rapidModelAndModePicksReachAgentInSelectionOrder() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet",
            currentMode: "plan"
        ))
        let client = ACPMockClient()
        let modelGate = AttachPhaseGate()
        let promptGate = PromptGate()
        let appliedSelections = ModelModeSelectionRecorder()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [
                    .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "haiku", name: "Haiku"),
                    .init(id: "opus", name: "Opus"),
                ],
                availableModes: [
                    .init(id: "plan", name: "Plan"),
                    .init(id: "act", name: "Act"),
                ],
                currentModel: "sonnet",
                currentMode: "plan",
                promptSuggestions: []
            ))
        }
        client.scriptAsync(method: "session/set_model") { request in
            let params = try #require(request.params as? ACPSessionSetModelParams)
            if params.modelId == "haiku" {
                await modelGate.enterAndWait()
            }
            await appliedSelections.append("model:\(params.modelId)")
            return Data("{}".utf8)
        }
        client.scriptAsync(method: "session/set_mode") { request in
            let params = try #require(request.params as? ACPSessionSetModeParams)
            await appliedSelections.append("mode:\(params.modeId)")
            return Data("{}".utf8)
        }
        client.scriptAsync(method: "session/prompt") { _ in
            await promptGate.waitInPrompt()
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: session.id)
        await manager.attach(to: session.id, freshlyCreated: false)

        manager.enqueueModelSelection(for: session.id, modelId: "haiku")
        try await waitUntilAsync { await modelGate.hasEntered }
        manager.enqueueModeSelection(for: session.id, modeId: "act")
        let lastSelection = manager.enqueueModelSelection(for: session.id, modelId: "opus")
        var firstPromptCompleted: Bool?
        var secondPromptCompleted: Bool?
        let firstAccepted = manager.submit(
            sessionId: session.id,
            text: "use the selected model",
            attachments: [],
            intent: .auto
        ) { succeeded in
            firstPromptCompleted = succeeded
        }
        let secondAccepted = manager.submit(
            sessionId: session.id,
            text: "keep the following prompt ordered",
            attachments: [],
            intent: .auto
        ) { succeeded in
            secondPromptCompleted = succeeded
        }
        #expect(firstAccepted)
        #expect(secondAccepted)
        await Task.yield()
        #expect(!client.sent.contains { $0.method == "session/prompt" })
        await modelGate.release()
        await lastSelection.value
        await manager.flushAllPersistence()

        #expect(await appliedSelections.values == [
            "model:haiku",
            "mode:act",
            "model:opus",
        ])
        #expect(session.currentModel == "opus")
        #expect(session.currentMode == "act")
        #expect(try store.loadSession(id: session.id)?.currentModel == "opus")
        #expect(try store.loadSession(id: session.id)?.currentMode == "act")
        try await waitUntilAsync { await promptGate.hasEntered }
        #expect(client.sent.filter { $0.method == "session/prompt" }.count == 1)
        await promptGate.release()
        try await waitUntil {
            client.sent.filter { $0.method == "session/prompt" }.count == 2
        }
        try await waitUntil { firstPromptCompleted != nil && secondPromptCompleted != nil }
        #expect(firstPromptCompleted == true)
        #expect(secondPromptCompleted == true)
        #expect(client.sent.filter {
            $0.method == "session/set_model" ||
                $0.method == "session/set_mode" ||
                $0.method == "session/prompt"
        }.map(\.method) == [
            "session/set_model",
            "session/set_mode",
            "session/set_model",
            "session/prompt",
            "session/prompt",
        ])
    }

    @Test("a later model pick waits for prompt RPC handoff")
    func laterModelPickWaitsForPromptRPCHandoff() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet",
            currentMode: "plan"
        ))
        let client = ACPMockClient()
        let modelGate = AttachPhaseGate()
        let checkpointGate = PromptGate()
        let promptGate = PromptGate()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [
                    .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "haiku", name: "Haiku"),
                    .init(id: "opus", name: "Opus"),
                ],
                availableModes: [.init(id: "plan", name: "Plan")],
                currentModel: "sonnet",
                currentMode: "plan",
                promptSuggestions: []
            ))
        }
        client.scriptAsync(method: "session/set_model") { request in
            let params = try #require(request.params as? ACPSessionSetModelParams)
            if params.modelId == "haiku" {
                await modelGate.enterAndWait()
            }
            return Data("{}".utf8)
        }
        client.scriptAsync(method: "session/prompt") { _ in
            await promptGate.waitInPrompt()
            return Data("{}".utf8)
        }
        let manager = manager(
            store: store,
            client: client,
            onCheckpointCapture: { _, _ in
                await checkpointGate.waitInPrompt()
                return nil
            }
        )
        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: session.id)
        await manager.attach(to: session.id, freshlyCreated: false)
        let initialRequestCount = client.sent.count

        let firstSelection = manager.enqueueModelSelection(for: session.id, modelId: "haiku")
        try await waitUntilAsync { await modelGate.hasEntered }
        var promptCompleted: Bool?
        let accepted = manager.submit(
            sessionId: session.id,
            text: "submit before changing the model again",
            attachments: [],
            intent: .auto
        ) { succeeded in
            promptCompleted = succeeded
        }
        #expect(accepted)
        let laterSelection = manager.enqueueModelSelection(for: session.id, modelId: "opus")

        await modelGate.release()
        await firstSelection.value
        try await waitUntilAsync { await checkpointGate.hasEntered }
        await Task.yield()

        let beforeHandoff = client.sent.dropFirst(initialRequestCount).filter {
            $0.method == "session/set_model" || $0.method == "session/prompt"
        }
        #expect(beforeHandoff.map(\.method) == ["session/set_model"])
        #expect((beforeHandoff.first?.params as? ACPSessionSetModelParams)?.modelId == "haiku")

        await checkpointGate.release()
        try await waitUntil {
            client.sent.dropFirst(initialRequestCount).contains { $0.method == "session/prompt" }
        }
        try await waitUntil {
            client.sent.dropFirst(initialRequestCount).contains {
                guard $0.method == "session/set_model",
                      let params = $0.params as? ACPSessionSetModelParams else { return false }
                return params.modelId == "opus"
            }
        }
        await laterSelection.value

        let orderedRequests = client.sent.dropFirst(initialRequestCount).filter {
            $0.method == "session/set_model" || $0.method == "session/prompt"
        }
        #expect(orderedRequests.map(\.method) == [
            "session/set_model",
            "session/prompt",
            "session/set_model",
        ])
        #expect(orderedRequests.compactMap {
            ($0.params as? ACPSessionSetModelParams)?.modelId
        } == ["haiku", "opus"])

        await promptGate.release()
        try await waitUntil { promptCompleted != nil }
        #expect(promptCompleted == true)
    }

    @Test("queued prompt holds a later model pick until RPC handoff")
    func queuedPromptHoldsLaterModelPickUntilHandoff() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet",
            currentMode: "plan"
        ))
        let client = ACPMockClient()
        let modelGate = AttachPhaseGate()
        let activePromptGate = PromptGate()
        let queuedPromptGate = PromptGate()
        let promptCounter = PromptCounter()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [
                    .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "haiku", name: "Haiku"),
                    .init(id: "opus", name: "Opus"),
                ],
                availableModes: [.init(id: "plan", name: "Plan")],
                currentModel: "sonnet",
                currentMode: "plan",
                promptSuggestions: []
            ))
        }
        client.scriptAsync(method: "session/set_model") { request in
            let params = try #require(request.params as? ACPSessionSetModelParams)
            if params.modelId == "haiku" {
                await modelGate.enterAndWait()
            }
            return Data("{}".utf8)
        }
        client.scriptAsync(method: "session/prompt") { _ in
            switch await promptCounter.next() {
            case 1:
                await activePromptGate.waitInPrompt()
            case 2:
                await queuedPromptGate.waitInPrompt()
            default:
                break
            }
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: session.id)
        await manager.attach(to: session.id, freshlyCreated: false)
        var activePromptCompleted: Bool?
        #expect(manager.submit(
            sessionId: session.id,
            text: "active turn",
            attachments: [],
            intent: .auto
        ) { activePromptCompleted = $0 })
        try await waitUntilAsync { await activePromptGate.hasEntered }

        let firstSelection = manager.enqueueModelSelection(for: session.id, modelId: "haiku")
        try await waitUntilAsync { await modelGate.hasEntered }
        var queuedPromptCompleted: Bool?
        #expect(manager.submit(
            sessionId: session.id,
            text: "queue this prompt",
            attachments: [],
            intent: .auto
        ) { queuedPromptCompleted = $0 })
        let laterSelection = manager.enqueueModelSelection(for: session.id, modelId: "opus")

        await modelGate.release()
        await firstSelection.value
        try await waitUntil {
            session.queue.count == 1 && queuedPromptCompleted == true
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.sent.compactMap {
            ($0.params as? ACPSessionSetModelParams)?.modelId
        } == ["haiku"])

        await activePromptGate.release()
        try await waitUntilAsync { await queuedPromptGate.hasEntered }
        await laterSelection.value

        let orderedRequests = client.sent.filter {
            $0.method == "session/prompt" || $0.method == "session/set_model"
        }
        #expect(orderedRequests.map(\.method) == [
            "session/prompt",
            "session/set_model",
            "session/prompt",
            "session/set_model",
        ])
        #expect(orderedRequests.compactMap {
            ($0.params as? ACPSessionSetModelParams)?.modelId
        } == ["haiku", "opus"])

        await queuedPromptGate.release()
        try await waitUntil {
            activePromptCompleted == true
                && queuedPromptCompleted == true
                && session.queue.isEmpty
                && session.transcript.streamingState == .idle
        }
    }

    @Test("local queue mutations release later model picks", arguments: ["edit", "remove", "clear"])
    func localQueueMutationsReleaseLaterModelPicks(_ mutation: String) async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet",
            currentMode: "plan"
        ))
        let client = ACPMockClient()
        let modelGate = AttachPhaseGate()
        let activePromptGate = PromptGate()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [
                    .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "haiku", name: "Haiku"),
                    .init(id: "opus", name: "Opus"),
                ],
                availableModes: [.init(id: "plan", name: "Plan")],
                currentModel: "sonnet",
                currentMode: "plan",
                promptSuggestions: []
            ))
        }
        client.scriptAsync(method: "session/set_model") { request in
            let params = try #require(request.params as? ACPSessionSetModelParams)
            if params.modelId == "haiku" {
                await modelGate.enterAndWait()
            }
            return Data("{}".utf8)
        }
        client.scriptAsync(method: "session/prompt") { _ in
            await activePromptGate.waitInPrompt()
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: session.id)
        await manager.attach(to: session.id, freshlyCreated: false)
        var activePromptCompleted: Bool?
        #expect(manager.submit(
            sessionId: session.id,
            text: "active turn",
            attachments: [],
            intent: .auto
        ) { activePromptCompleted = $0 })
        try await waitUntilAsync { await activePromptGate.hasEntered }

        let firstSelection = manager.enqueueModelSelection(for: session.id, modelId: "haiku")
        try await waitUntilAsync { await modelGate.hasEntered }
        var queuedPromptCompleted: Bool?
        #expect(manager.submit(
            sessionId: session.id,
            text: "remove this queued prompt",
            attachments: [],
            intent: .auto
        ) { queuedPromptCompleted = $0 })
        let laterSelection = manager.enqueueModelSelection(for: session.id, modelId: "opus")

        await modelGate.release()
        await firstSelection.value
        try await waitUntil { session.queue.count == 1 && queuedPromptCompleted == true }
        let queuedItemId = try #require(session.queue.first?.id)
        if mutation == "edit" {
            await manager.queueEditIntoComposer(for: session.id, itemId: queuedItemId)
        } else if mutation == "remove" {
            await manager.queueRemove(for: session.id, itemId: queuedItemId)
        } else {
            await manager.queueClear(for: session.id)
        }
        await laterSelection.value

        #expect(session.queue.isEmpty)
        if mutation == "edit" {
            #expect(session.composerDraft.segments == [.text("remove this queued prompt")])
        }
        #expect(client.sent.filter {
            $0.method == "session/prompt"
        }.count == 1)
        #expect(client.sent.compactMap {
            ($0.params as? ACPSessionSetModelParams)?.modelId
        } == ["haiku", "opus"])

        await activePromptGate.release()
        try await waitUntil { activePromptCompleted == true && session.transcript.streamingState == .idle }
    }

    @Test("detaching cancels a prompt behind model selection")
    func detachingCancelsPromptBehindModelSelection() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet",
            currentMode: "plan"
        ))
        let client = ACPMockClient()
        let modelGate = AttachPhaseGate()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [
                    .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "haiku", name: "Haiku"),
                ],
                availableModes: [.init(id: "plan", name: "Plan")],
                currentModel: "sonnet",
                currentMode: "plan",
                promptSuggestions: []
            ))
        }
        client.scriptAsync(method: "session/set_model") { request in
            let params = try #require(request.params as? ACPSessionSetModelParams)
            if params.modelId == "haiku" {
                await modelGate.enterAndWait()
            }
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))
        manager.retainSession(id: session.id)
        defer { manager.releaseSession(id: session.id) }

        await manager.hydrateIfNeeded(id: session.id)
        await manager.attach(to: session.id, freshlyCreated: false)
        let selection = manager.enqueueModelSelection(for: session.id, modelId: "haiku")
        try await waitUntilAsync { await modelGate.hasEntered }

        var promptCompleted: Bool?
        let accepted = manager.submit(
            sessionId: session.id,
            text: "do not send after detach",
            attachments: [],
            intent: .auto
        ) { succeeded in
            promptCompleted = succeeded
        }
        #expect(accepted)

        await manager.detach(sessionId: session.id)
        await modelGate.release()
        await selection.value
        try await waitUntil { promptCompleted != nil }

        #expect(promptCompleted == false)
        #expect(!client.sent.contains { $0.method == "session/prompt" })
        #expect(session.agentState == .idle)
    }

    @Test("losing writer lease cancels a prompt behind model selection")
    func losingWriterLeaseCancelsPromptBehindModelSelection() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet",
            currentMode: "plan"
        ))
        let client = ACPMockClient()
        let modelGate = AttachPhaseGate()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [
                    .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "haiku", name: "Haiku"),
                ],
                availableModes: [.init(id: "plan", name: "Plan")],
                currentModel: "sonnet",
                currentMode: "plan",
                promptSuggestions: []
            ))
        }
        client.scriptAsync(method: "session/set_model") { request in
            let params = try #require(request.params as? ACPSessionSetModelParams)
            if params.modelId == "haiku" {
                await modelGate.enterAndWait()
            }
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))

        await manager.hydrateIfNeeded(id: session.id)
        await manager.attach(to: session.id, freshlyCreated: false)
        let selection = manager.enqueueModelSelection(for: session.id, modelId: "haiku")
        try await waitUntilAsync { await modelGate.hasEntered }

        var promptCompleted: Bool?
        let accepted = manager.submit(
            sessionId: session.id,
            text: "do not send after losing the lease",
            attachments: [],
            intent: .auto
        ) { succeeded in
            promptCompleted = succeeded
        }
        #expect(accepted)

        try store.seizeLease(
            sessionId: session.id,
            instanceId: "OTHER",
            pid: Int64(getpid()),
            now: Int64(Date().timeIntervalSince1970)
        )
        await modelGate.release()
        await selection.value
        try await waitUntil { promptCompleted != nil }

        #expect(promptCompleted == false)
        #expect(!client.sent.contains { $0.method == "session/prompt" })
    }

    @Test("reopened session reapplies persisted mode and config options after load")
    func reopenedSessionReappliesPersistedConfiguration() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let persistedConfigOptionValues: [String: ACPConfigValue] = [
            "effort": .string("high"),
            "permission": .string("unrestricted"),
            "autoApprove": .boolean(true),
            "removed": .string("legacy"),
            "effortWithStaleValue": .string("ultra"),
        ]
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "omp",
            currentMode: "plan",
            configOptionValues: persistedConfigOptionValues
        ))
        let client = ACPMockClient()
        let configGate = PromptGate()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [],
                availableModes: [
                    .init(id: "default", name: "Default"),
                    .init(id: "plan", name: "Plan"),
                ],
                currentModel: nil,
                currentMode: "default",
                promptSuggestions: [],
                configOptions: [
                    ACPConfigOption(
                        id: "effort",
                        name: "Thinking",
                        currentValue: "medium",
                        options: [
                            .init(id: "medium", name: "Medium"),
                            .init(id: "high", name: "High"),
                        ]
                    ),
                    ACPConfigOption(
                        id: "permission",
                        name: "Permission",
                        currentValue: "ask",
                        options: [
                            .init(id: "ask", name: "Ask"),
                            .init(id: "unrestricted", name: "Unrestricted"),
                        ]
                    ),
                    ACPConfigOption(
                        id: "autoApprove",
                        name: "Auto approve",
                        type: "boolean",
                        currentValue: .boolean(false)
                    ),
                    ACPConfigOption(
                        id: "effortWithStaleValue",
                        name: "Other effort",
                        currentValue: "medium",
                        options: [.init(id: "medium", name: "Medium")]
                    ),
                ]
            ))
        }
        client.script(method: "session/set_mode") { _ in Data("{}".utf8) }
        client.scriptAsync(method: "session/set_config_option") { _ in
            await configGate.waitInPrompt()
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        session.autoRunEnabled = true
        manager.persist(session)
        let attachTask = Task {
            await manager.attach(to: session.id, freshlyCreated: false)
        }
        try await waitUntilAsync { await configGate.hasEntered }
        await manager.flushAllPersistence()
        #expect(try store.loadSession(id: "local")?.configOptionValues == persistedConfigOptionValues)
        await configGate.release()
        await attachTask.value
        await manager.flushAllPersistence()
        #expect(client.sent.map(\.method) == [
            "initialize",
            "session/load",
            "session/set_mode",
            "session/set_config_option",
            "session/set_config_option",
            "session/set_config_option",
        ])
        let modeParams = try #require(client.sent[2].params as? ACPSessionSetModeParams)
        #expect(modeParams.modeId == "plan")
        let configParams = try client.sent.dropFirst(3).map {
            try #require($0.params as? ACPSessionSetConfigOptionParams)
        }
        #expect(configParams.map(\.configId) == ["effort", "permission", "autoApprove"])
        #expect(configParams.map(\.value) == [
            .string("high"),
            .string("unrestricted"),
            .boolean(true),
        ])
        #expect(session.currentMode == "plan")
        #expect(ACPConfigOption.currentValues(in: session.availableConfigOptions) == [
            "effort": .string("high"),
            "permission": .string("unrestricted"),
            "autoApprove": .boolean(true),
            "effortWithStaleValue": .string("medium"),
        ])
        #expect(try store.loadSession(id: "local")?.configOptionValues ==
            ACPConfigOption.currentValues(in: session.availableConfigOptions))
    }

    @Test("reopened session preserves config edits made while load is pending")
    func reopenedSessionPreservesConfigEditsMadeWhileLoadIsPending() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            configOptionValues: ["effort": .string("medium")]
        ))
        let client = ACPMockClient()
        let loadGate = AttachPhaseGate()
        scriptInitialize(client)
        client.scriptAsync(method: "session/load") { _ in
            await loadGate.enterAndWait()
            return try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: "default",
                promptSuggestions: [],
                configOptions: [
                    ACPConfigOption(
                        id: "effort",
                        name: "Thinking",
                        currentValue: "medium",
                        options: [
                            .init(id: "medium", name: "Medium"),
                            .init(id: "high", name: "High"),
                        ]
                    ),
                ]
            ))
        }
        client.script(method: "session/set_config_option") { _ in Data("{}".utf8) }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))

        await manager.hydrateIfNeeded(id: "local")
        session.availableConfigOptions = [
            ACPConfigOption(
                id: "effort",
                name: "Thinking",
                currentValue: "medium",
                options: [
                    .init(id: "medium", name: "Medium"),
                    .init(id: "high", name: "High"),
                ]
            ),
        ]
        let attachTask = Task {
            await manager.attach(to: session.id, freshlyCreated: false)
        }
        try await waitUntilAsync { await loadGate.hasEntered }

        let pendingUpdate = manager.setConfigOption(
            for: session.id,
            configId: "effort",
            value: .string("high")
        )
        if let pendingUpdate {
            await pendingUpdate.value
        }
        await manager.flushAllPersistence()
        #expect(try store.loadSession(id: "local")?.configOptionValues == [
            "effort": .string("high"),
        ])

        await loadGate.release()
        await attachTask.value
        await manager.flushAllPersistence()

        let configRequest = try #require(client.sent.last)
        #expect(configRequest.method == "session/set_config_option")
        let params = try #require(configRequest.params as? ACPSessionSetConfigOptionParams)
        #expect(params.configId == "effort")
        #expect(params.value == .string("high"))
        #expect(ACPConfigOption.currentValues(in: session.availableConfigOptions) == [
            "effort": .string("high"),
        ])
        #expect(try store.loadSession(id: "local")?.configOptionValues == [
            "effort": .string("high"),
        ])
    }

    @Test("user config edits wait for persisted restoration requests")
    func userConfigEditsWaitForPersistedRestorationRequests() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            configOptionValues: ["effort": .string("high")]
        ))
        let client = ACPMockClient()
        let restoreGate = AttachPhaseGate()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: "default",
                promptSuggestions: [],
                configOptions: [
                    ACPConfigOption(
                        id: "effort",
                        name: "Thinking",
                        currentValue: "medium",
                        options: [
                            .init(id: "medium", name: "Medium"),
                            .init(id: "high", name: "High"),
                        ]
                    ),
                ]
            ))
        }
        client.scriptAsync(method: "session/set_config_option") { _ in
            await restoreGate.enterAndWait()
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))

        await manager.hydrateIfNeeded(id: "local")
        let attachTask = Task {
            await manager.attach(to: session.id, freshlyCreated: false)
        }
        try await waitUntilAsync { await restoreGate.hasEntered }

        let restoreRequestsBeforeUserEdit = try client.sent
            .filter { $0.method == "session/set_config_option" }
            .map { try #require($0.params as? ACPSessionSetConfigOptionParams) }
        #expect(restoreRequestsBeforeUserEdit.map(\.value) == [.string("high")])

        _ = manager.setConfigOption(
            for: session.id,
            configId: "effort",
            value: .string("medium")
        )
        await manager.flushAllPersistence()
        #expect(try store.loadSession(id: "local")?.configOptionValues == [
            "effort": .string("medium"),
        ])

        await restoreGate.release()
        await attachTask.value
        await manager.flushAllPersistence()

        let configRequests = try client.sent
            .filter { $0.method == "session/set_config_option" }
            .map { try #require($0.params as? ACPSessionSetConfigOptionParams) }
        #expect(configRequests.map(\.value) == [
            .string("high"),
            .string("medium"),
        ])
        #expect(ACPConfigOption.currentValues(in: session.availableConfigOptions) == [
            "effort": .string("medium"),
        ])
        #expect(try store.loadSession(id: "local")?.configOptionValues == [
            "effort": .string("medium"),
        ])
    }

    @Test("restoration applies later values refreshed by a successful response")
    func restorationAppliesLaterValuesRefreshedBySuccessfulResponse() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            configOptionValues: [
                "effort": .string("high"),
                "permission": .string("unrestricted"),
            ]
        ))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: "default",
                promptSuggestions: [],
                configOptions: [
                    ACPConfigOption(
                        id: "effort",
                        name: "Thinking",
                        currentValue: "medium",
                        options: [
                            .init(id: "medium", name: "Medium"),
                            .init(id: "high", name: "High"),
                        ]
                    ),
                    ACPConfigOption(
                        id: "permission",
                        name: "Permission",
                        currentValue: "ask",
                        options: [
                            .init(id: "ask", name: "Ask"),
                            .init(id: "unrestricted", name: "Unrestricted"),
                        ]
                    ),
                ]
            ))
        }
        client.script(method: "session/set_config_option") { request in
            let params = try #require(request.params as? ACPSessionSetConfigOptionParams)
            if params.configId == "effort" {
                return try JSONEncoder().encode(ACPSessionSetConfigOptionResult(
                    configOptions: [
                        ACPConfigOption(
                            id: "effort",
                            name: "Thinking",
                            currentValue: "high",
                            options: [
                                .init(id: "medium", name: "Medium"),
                                .init(id: "high", name: "High"),
                            ]
                        ),
                        ACPConfigOption(
                            id: "permission",
                            name: "Permission refreshed",
                            currentValue: "ask",
                            options: [
                                .init(id: "ask", name: "Ask"),
                                .init(id: "unrestricted", name: "Unrestricted"),
                            ]
                        ),
                    ]
                ))
            }
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))

        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)
        await manager.flushAllPersistence()

        let configRequests = try client.sent
            .filter { $0.method == "session/set_config_option" }
            .map { try #require($0.params as? ACPSessionSetConfigOptionParams) }
        #expect(configRequests.map(\.configId) == ["effort", "permission"])
        #expect(configRequests.map(\.value) == [
            .string("high"),
            .string("unrestricted"),
        ])
        #expect(session.availableConfigOptions.first(where: { $0.id == "permission" })?.name ==
            "Permission refreshed")
        #expect(try store.loadSession(id: "local")?.configOptionValues == [
            "effort": .string("high"),
            "permission": .string("unrestricted"),
        ])
    }

    @Test("failed boolean config update rolls back live and persisted values")
    func failedBooleanConfigUpdateRollsBackLiveAndPersistedValues() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            configOptionValues: ["autoApprove": .boolean(false)]
        ))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: "default",
                promptSuggestions: [],
                configOptions: [
                    ACPConfigOption(
                        id: "autoApprove",
                        name: "Auto approve",
                        type: "boolean",
                        currentValue: .boolean(false)
                    ),
                ]
            ))
        }
        client.script(method: "session/set_config_option") { _ in
            throw ACPClientError.noScript(method: "session/set_config_option")
        }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))

        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)
        let update = try #require(manager.setConfigOption(
            for: session.id,
            configId: "autoApprove",
            value: .boolean(true)
        ))
        await update.value
        await manager.flushAllPersistence()

        #expect(ACPConfigOption.currentValues(in: session.availableConfigOptions) == [
            "autoApprove": .boolean(false),
        ])
        #expect(try store.loadSession(id: "local")?.configOptionValues == [
            "autoApprove": .boolean(false),
        ])
    }

    @Test("failed config-option restoration retains valid saved values")
    func failedConfigOptionRestorationRetainsValidSavedValues() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            configOptionValues: [
                "effort": .string("high"),
                "stale": .string("ultra"),
                "removed": .string("obsolete"),
            ]
        ))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: "default",
                promptSuggestions: [],
                configOptions: [
                    ACPConfigOption(
                        id: "effort",
                        name: "Thinking",
                        currentValue: "medium",
                        options: [
                            .init(id: "medium", name: "Medium"),
                            .init(id: "high", name: "High"),
                        ]
                    ),
                    ACPConfigOption(
                        id: "stale",
                        name: "Other",
                        currentValue: "medium",
                        options: [.init(id: "medium", name: "Medium")]
                    ),
                ]
            ))
        }
        client.script(method: "session/set_config_option") { _ in
            throw ACPClientError.noScript(method: "session/set_config_option")
        }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))

        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)
        let runner = try #require(manager.runners[session.id])
        session.autoRunEnabled = true
        manager.persist(session)
        await manager.flushAllPersistence()
        runner.persistSessionRow()
        await runner.flushPersistence()
        await manager.flushAllPersistence()

        #expect(client.sent.map(\.method) == [
            "initialize",
            "session/load",
            "session/set_config_option",
        ])
        #expect(ACPConfigOption.currentValues(in: session.availableConfigOptions) == [
            "effort": .string("medium"),
            "stale": .string("medium"),
        ])
        #expect(try store.loadSession(id: "local")?.configOptionValues == [
            "effort": .string("high"),
            "stale": .string("medium"),
        ])
    }

    @Test("failed mode restoration keeps the agent-loaded mode")
    func failedModeRestorationKeepsAgentLoadedMode() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            currentMode: "plan"
        ))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [],
                availableModes: [
                    .init(id: "default", name: "Default"),
                    .init(id: "plan", name: "Plan"),
                ],
                currentModel: nil,
                currentMode: "default",
                promptSuggestions: []
            ))
        }
        client.script(method: "session/set_mode") { _ in
            throw ACPClientError.noScript(method: "session/set_mode")
        }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))

        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)
        await manager.flushAllPersistence()

        #expect(client.sent.map(\.method) == [
            "initialize",
            "session/load",
            "session/set_mode",
        ])
        #expect(session.currentMode == "default")
        #expect(try store.loadSession(id: "local")?.currentMode == "default")
    }

    @Test("failed attach releases config-option persistence deferral")
    func failedAttachReleasesConfigOptionPersistenceDeferral() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            configOptionValues: ["effort": .string("medium")]
        ))
        let client = ACPMockClient()
        client.script(method: "initialize") { _ in
            throw ACPClientError.noScript(method: "initialize")
        }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        session.availableConfigOptions = [ACPConfigOption(
            id: "effort",
            name: "Thinking",
            currentValue: "medium",
            options: [
                .init(id: "medium", name: "Medium"),
                .init(id: "high", name: "High"),
            ]
        )]

        await manager.attach(to: session.id, freshlyCreated: false)
        session.availableConfigOptions = [ACPConfigOption(
            id: "effort",
            name: "Thinking",
            currentValue: "high",
            options: [
                .init(id: "medium", name: "Medium"),
                .init(id: "high", name: "High"),
            ]
        )]
        manager.persist(session)
        await manager.flushAllPersistence()

        #expect(client.sent.map(\.method) == ["initialize"])
        #expect(try store.loadSession(id: "local")?.configOptionValues == [
            "effort": .string("high"),
        ])
    }

    @Test("live config-option persistence refreshes manager cache")
    func liveConfigOptionPersistenceRefreshesManagerCache() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let initialValues: [String: ACPConfigValue] = ["effort": .string("medium")]
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            configOptionValues: initialValues
        ))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: [],
                configOptions: [ACPConfigOption(
                    id: "effort",
                    name: "Thinking",
                    currentValue: "medium",
                    options: [
                        .init(id: "medium", name: "Medium"),
                        .init(id: "high", name: "High"),
                    ]
                )]
            ))
        }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        let updatedValues: [String: ACPConfigValue] = ["effort": .string("high")]
        client.emit(.init(
            sessionId: "remote-old",
            update: .sessionConfigOptionsUpdate([ACPConfigOption(
                id: "effort",
                name: "Thinking",
                currentValue: "high",
                options: [
                    .init(id: "medium", name: "Medium"),
                    .init(id: "high", name: "High"),
                ]
            )])
        ))
        try await waitUntilAsync {
            let persistedValues = (try? store.loadSession(id: "local"))?.configOptionValues
            let cachedValues = await manager.persistedSessionRow(id: "local")?.configOptionValues
            return persistedValues == updatedValues && cachedValues == updatedValues
        }

        let cachedRow = await manager.persistedSessionRow(id: "local")
        #expect(cachedRow?.configOptionValues == updatedValues)
        let runner = try #require(manager.runners[session.id])
        await runner.flushPersistence()
        await manager.flushAllPersistence()

        let newerValues: [String: ACPConfigValue] = ["effort": .string("medium")]
        session.availableConfigOptions = [ACPConfigOption(
            id: "effort",
            name: "Thinking",
            currentValue: "medium",
            options: [
                .init(id: "medium", name: "Medium"),
                .init(id: "high", name: "High"),
            ]
        )]
        manager.persist(session)
        await manager.flushPersistence()
        #expect(try store.loadSession(id: "local")?.configOptionValues == newerValues)

        session.availableConfigOptions = [ACPConfigOption(
            id: "effort",
            name: "Thinking",
            currentValue: "high",
            options: [
                .init(id: "medium", name: "Medium"),
                .init(id: "high", name: "High"),
            ]
        )]
        runner.persistSessionRow()
        session.availableConfigOptions = [ACPConfigOption(
            id: "effort",
            name: "Thinking",
            currentValue: "medium",
            options: [
                .init(id: "medium", name: "Medium"),
                .init(id: "high", name: "High"),
            ]
        )]
        await runner.flushPersistence()
        await manager.flushAllPersistence()
        #expect(await manager.persistedSessionRow(id: "local")?.configOptionValues == newerValues)
        #expect(try store.loadSession(id: "local")?.configOptionValues == newerValues)
        await manager.detach(sessionId: session.id)
    }

    @Test("configuration restoration preserves concurrent option changes")
    func configurationRestorationPreservesConcurrentOptionChanges() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let persistedValues: [String: ACPConfigValue] = [
            "effort": .string("high"),
            "permission": .string("unrestricted"),
        ]
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            configOptionValues: persistedValues
        ))
        let client = ACPMockClient()
        let configGate = PromptGate()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: [],
                configOptions: [
                    ACPConfigOption(
                        id: "effort",
                        name: "Thinking",
                        currentValue: "medium",
                        options: [
                            .init(id: "medium", name: "Medium"),
                            .init(id: "high", name: "High"),
                        ]
                    ),
                    ACPConfigOption(
                        id: "permission",
                        name: "Permission",
                        currentValue: "ask",
                        options: [
                            .init(id: "ask", name: "Ask"),
                            .init(id: "unrestricted", name: "Unrestricted"),
                            .init(id: "allow", name: "Allow"),
                        ]
                    ),
                ]
            ))
        }
        client.scriptAsync(method: "session/set_config_option") { _ in
            await configGate.waitInPrompt()
            throw NSError(domain: "ACPSessionManagerAttachRestoreTests", code: 1)
        }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        let attachTask = Task {
            await manager.attach(to: session.id, freshlyCreated: false)
        }
        try await waitUntilAsync { await configGate.hasEntered }

        client.emit(.init(
            sessionId: "remote-old",
            update: .sessionConfigOptionsUpdate([
                ACPConfigOption(
                    id: "effort",
                    name: "Reasoning",
                    currentValue: "high",
                    options: [
                        .init(id: "high", name: "High"),
                        .init(id: "ultra", name: "Ultra"),
                    ]
                ),
                ACPConfigOption(
                    id: "permission",
                    name: "Permission",
                    currentValue: "ask",
                    options: [
                        .init(id: "ask", name: "Ask"),
                        .init(id: "unrestricted", name: "Unrestricted"),
                        .init(id: "allow", name: "Allow"),
                    ]
                ),
            ])
        ))
        try await waitUntilAsync {
            session.availableConfigOptions.first { $0.id == "effort" }?.name == "Reasoning"
        }
        if let index = session.availableConfigOptions.firstIndex(where: { $0.id == "permission" }) {
            let option = session.availableConfigOptions[index]
            session.availableConfigOptions[index] = ACPConfigOption(
                id: option.id,
                name: option.name,
                type: option.type,
                category: option.category,
                currentValue: .string("allow"),
                options: option.options
            )
            manager.persist(session)
        }

        await configGate.release()
        await attachTask.value
        await manager.flushAllPersistence()

        let configParams = try client.sent
            .filter { $0.method == "session/set_config_option" }
            .map { try #require($0.params as? ACPSessionSetConfigOptionParams) }
        #expect(configParams.map(\.configId) == ["effort"])
        #expect(session.availableConfigOptions.first { $0.id == "effort" }?.name == "Reasoning")
        #expect(session.availableConfigOptions.first { $0.id == "effort" }?.currentValue == .string("high"))
        #expect(session.availableConfigOptions.first { $0.id == "permission" }?.currentValue == .string("allow"))
        #expect(try store.loadSession(id: "local")?.configOptionValues == [
            "effort": .string("high"),
            "permission": .string("allow"),
        ])
        await manager.detach(sessionId: session.id)
    }

    @Test("reopened session reapplies a persisted config-option model after load")
    func reopenedSessionReappliesPersistedConfigOptionModel() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet"
        ))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [],
                availableModes: [],
                currentModel: "opus",
                currentMode: nil,
                promptSuggestions: [],
                configOptions: [ACPConfigOption(
                    id: "model",
                    name: "Model",
                    category: "model",
                    currentValue: "opus",
                    options: [
                        .init(id: "sonnet", name: "Sonnet"),
                        .init(id: "opus", name: "Opus"),
                    ])]
            ))
        }
        client.script(method: "session/set_config_option") { _ in
            """
            {"configOptions":[
                {"id":"model","name":"Model","type":"select","category":"model","currentValue":"opus",
                 "options":[{"value":"sonnet","name":"Sonnet"},{"value":"opus","name":"Opus"}]},
                {"id":"effort","name":"Effort","type":"select","currentValue":"high",
                 "options":[{"value":"high","name":"High"}]}
            ]}
            """.data(using: .utf8)!
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize", "session/load", "session/set_config_option"])
        let params = try #require(client.sent.last?.params as? ACPSessionSetConfigOptionParams)
        #expect(params.sessionId == "remote-old")
        #expect(params.configId == "model")
        #expect(params.value == .string("sonnet"))
        #expect(session.currentModel == "sonnet")
        #expect(session.availableConfigOptions.first?.currentStringValue == "sonnet")
        #expect(session.availableConfigOptions.count == 2)
    }

    @Test("reopened config-only session records its already-selected model")
    func reopenedConfigOnlySessionRecordsAlreadySelectedModel() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old", agentId: "codex", currentModel: "opus"))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old", availableModels: [], availableModes: [], currentModel: nil,
                currentMode: nil, promptSuggestions: [], configOptions: [ACPConfigOption(
                    id: "model", name: "Model", category: "model", currentValue: "opus",
                    options: [.init(id: "opus", name: "Opus")])]
            ))
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize", "session/load"])
        #expect(session.currentModel == "opus")
    }

    @Test("reopened config-only session persists loaded model when row has no model")
    func reopenedConfigOnlySessionPersistsLoadedModelWhenRowHasNoModel() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old", agentId: "codex", currentModel: nil))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old", availableModels: [], availableModes: [], currentModel: nil,
                currentMode: nil, promptSuggestions: [], configOptions: [ACPConfigOption(
                    id: "model", name: "Model", category: "model", currentValue: "opus",
                    options: [.init(id: "opus", name: "Opus")])]
            ))
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize", "session/load"])
        #expect(session.currentModel == "opus")
        try await waitUntil {
            (try? store.loadSession(id: "local"))?.currentModel == "opus"
        }
    }

    @Test("reopened config-option session keeps the loaded model when restoration fails")
    func reopenedConfigOptionSessionKeepsLoadedModelWhenRestorationFails() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet"
        ))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: [],
                configOptions: [ACPConfigOption(
                    id: "model",
                    name: "Model",
                    category: "model",
                    currentValue: "opus",
                    options: [
                        .init(id: "sonnet", name: "Sonnet"),
                        .init(id: "opus", name: "Opus"),
                    ])]
            ))
        }
        client.script(method: "session/set_config_option") { _ in
            throw ACPClientError.noScript(method: "session/set_config_option")
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(session.currentModel == "opus")
        #expect(session.availableConfigOptions.first?.currentStringValue == "opus")
        try await waitUntil {
            (try? store.loadSession(id: "local"))?.currentModel == "opus"
        }
    }

    @Test("reopened config-option session clears stale model when restoration fails without loaded value")
    func reopenedConfigOptionSessionClearsStaleModelWhenRestorationFailsWithoutLoadedValue() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet"
        ))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: [],
                configOptions: [ACPConfigOption(
                    id: "model",
                    name: "Model",
                    category: "model",
                    currentValue: nil as ACPConfigValue?,
                    options: [
                        .init(id: "sonnet", name: "Sonnet"),
                        .init(id: "opus", name: "Opus"),
                    ])]
            ))
        }
        client.script(method: "session/set_config_option") { _ in
            throw ACPClientError.noScript(method: "session/set_config_option")
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(session.currentModel == nil)
        #expect(session.availableConfigOptions.first?.currentStringValue == nil)
        try await waitUntil {
            (try? store.loadSession(id: "local"))?.currentModel == nil
        }
    }

    @Test("reopened config-option session preserves model reselected during restoration")
    func reopenedConfigOptionSessionPreservesModelReselectedDuringRestoration() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet"
        ))
        let client = ACPMockClient()
        let modelGate = PromptGate()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: [],
                configOptions: [ACPConfigOption(
                    id: "model",
                    name: "Model",
                    category: "model",
                    currentValue: "opus",
                    options: [
                        .init(id: "sonnet", name: "Sonnet"),
                        .init(id: "opus", name: "Opus"),
                    ])]
            ))
        }
        client.scriptAsync(method: "session/set_config_option") { _ in
            await modelGate.waitInPrompt()
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        let attachTask = Task {
            await manager.attach(to: session.id, freshlyCreated: false)
        }

        try await waitUntilAsync { await modelGate.hasEntered }
        session.currentModel = "opus"
        session.availableConfigOptions[0] = ACPConfigOption(
            id: "model",
            name: "Model",
            category: "model",
            currentValue: "opus",
            options: [
                .init(id: "sonnet", name: "Sonnet"),
                .init(id: "opus", name: "Opus"),
            ])
        await modelGate.release()
        await attachTask.value

        #expect(session.currentModel == "opus")
        #expect(session.availableConfigOptions.first?.currentStringValue == "opus")
    }

    @Test("config-option selection after load is restored against the loaded value")
    func configOptionSelectionAfterLoadIsRestoredAgainstLoadedValue() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "opus"
        ))
        let client = ACPMockClient()
        let lockStore = try ACPSessionStore(path: store.path)
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            let data = try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: [],
                configOptions: [ACPConfigOption(
                    id: "model",
                    name: "Model",
                    category: "model",
                    currentValue: "opus",
                    options: [
                        .init(id: "sonnet", name: "Sonnet"),
                        .init(id: "opus", name: "Opus"),
                    ])]
            ))
            try lockStore.db.exec("BEGIN IMMEDIATE")
            return data
        }
        client.script(method: "session/set_config_option") { _ in Data("{}".utf8) }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        defer { try? lockStore.db.exec("ROLLBACK") }
        let attachTask = Task {
            await manager.attach(to: session.id, freshlyCreated: false)
        }

        try await waitUntil {
            session.availableConfigOptions.first?.currentStringValue == "opus"
        }
        session.currentModel = "sonnet"
        session.availableConfigOptions[0] = ACPConfigOption(
            id: "model",
            name: "Model",
            category: "model",
            currentValue: "sonnet",
            options: [
                .init(id: "sonnet", name: "Sonnet"),
                .init(id: "opus", name: "Opus"),
            ])
        manager.pendingModel[session.id] = "sonnet"
        try lockStore.db.exec("COMMIT")
        await attachTask.value

        let params = client.sent.compactMap { $0.params as? ACPSessionSetConfigOptionParams }
        #expect(params.map(\.value) == [.string("sonnet")])
        #expect(session.currentModel == "sonnet")
        #expect(session.availableConfigOptions.first?.currentStringValue == "sonnet")
    }

    @Test("reopened config-option session preserves option changed during restoration")
    func reopenedConfigOptionSessionPreservesOptionChangedDuringRestoration() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet"
        ))
        let client = ACPMockClient()
        let modelGate = PromptGate()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: [],
                configOptions: [
                    ACPConfigOption(
                        id: "model",
                        name: "Model",
                        category: "model",
                        currentValue: "opus",
                        options: [
                            .init(id: "sonnet", name: "Sonnet"),
                            .init(id: "opus", name: "Opus"),
                        ]),
                    ACPConfigOption(
                        id: "effort",
                        name: "Effort",
                        currentValue: "low",
                        options: [
                            .init(id: "low", name: "Low"),
                            .init(id: "high", name: "High"),
                        ]),
                ]
            ))
        }
        client.scriptAsync(method: "session/set_config_option") { _ in
            await modelGate.waitInPrompt()
            return try JSONEncoder().encode(ACPSessionSetConfigOptionResult(configOptions: [
                ACPConfigOption(
                    id: "model",
                    name: "Model",
                    category: "model",
                    currentValue: "sonnet",
                    options: [
                        .init(id: "sonnet", name: "Sonnet"),
                        .init(id: "opus", name: "Opus"),
                    ]),
                ACPConfigOption(
                    id: "effort",
                    name: "Effort",
                    currentValue: "low",
                    options: [
                        .init(id: "low", name: "Low"),
                        .init(id: "high", name: "High"),
                    ]),
            ]))
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        let attachTask = Task {
            await manager.attach(to: session.id, freshlyCreated: false)
        }

        try await waitUntilAsync { await modelGate.hasEntered }
        session.availableConfigOptions[1] = ACPConfigOption(
            id: "effort",
            name: "Effort",
            currentValue: "high",
            options: [
                .init(id: "low", name: "Low"),
                .init(id: "high", name: "High"),
            ])
        await modelGate.release()
        await attachTask.value

        #expect(session.currentModel == "sonnet")
        #expect(session.availableConfigOptions.first(where: { $0.id == "model" })?.currentStringValue == "sonnet")
        #expect(session.availableConfigOptions.first(where: { $0.id == "effort" })?.currentStringValue == "high")
    }

    @Test("reopened session keeps the loaded model when restoration fails")
    func reopenedSessionKeepsLoadedModelWhenRestorationFails() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet"
        ))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [
                    .init(id: "opus", name: "Opus"),
                ],
                availableModes: [],
                currentModel: "opus",
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        client.script(method: "session/set_model") { _ in
            throw ACPClientError.noScript(method: "session/set_model")
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        try await waitUntil {
            client.sent.map(\.method) == ["initialize", "session/load", "session/set_model"]
        }
        #expect(session.currentModel == "opus")
        try await waitUntil {
            (try? store.loadSession(id: "local"))?.currentModel == "opus"
        }
    }

    @Test("reopened session restores its model before flushing queued prompts")
    func reopenedSessionRestoresModelBeforeFlushingQueuedPrompts() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet"
        ))
        try store.upsertQueue(sessionId: "local", items: [
            QueuedPrompt(blocks: [.text("queued prompt")])
        ])
        let client = ACPMockClient()
        let modelGate = PromptGate()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [
                    .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "opus", name: "Opus"),
                ],
                availableModes: [],
                currentModel: "opus",
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        client.scriptAsync(method: "session/set_model") { _ in
            await modelGate.waitInPrompt()
            return Data("{}".utf8)
        }
        client.script(method: "session/prompt") { _ in Data("null".utf8) }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        let attachTask = Task {
            await manager.attach(to: session.id, freshlyCreated: false)
        }

        try await waitUntilAsync { await modelGate.hasEntered }
        #expect(client.sent.filter { $0.method == "session/prompt" }.isEmpty)
        await modelGate.release()
        await attachTask.value

        try await waitUntil {
            client.sent.map(\.method) == ["initialize", "session/load", "session/set_model", "session/prompt"]
        }
    }

    @Test("fresh attach serializes model edits before flushing queued prompts")
    func freshAttachSerializesModelEditsBeforeFlushingQueuedPrompts() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: nil,
            agentId: "codex",
            currentModel: nil
        ))
        let client = ACPMockClient()
        let modelGate = AttachPhaseGate()
        let modelRequestCounter = PromptCounter()
        scriptInitialize(client)
        client.script(method: "session/new") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-new",
                availableModels: [
                    .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "haiku", name: "Haiku"),
                ],
                availableModes: [],
                currentModel: "opus",
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        client.scriptAsync(method: "session/set_model") { _ in
            if await modelRequestCounter.next() == 1 {
                await modelGate.enterAndWait()
            }
            return Data("{}".utf8)
        }
        client.script(method: "session/prompt") { _ in Data("null".utf8) }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.setModel(for: session.id, modelId: "sonnet")
        session.enqueue(blocks: [.text("queued prompt")])
        let attachTask = Task {
            await manager.attach(to: session.id, freshlyCreated: true)
        }

        try await waitUntilAsync { await modelGate.hasEntered }
        await manager.setModel(for: session.id, modelId: "haiku")
        #expect(client.sent.filter { $0.method == "session/set_model" }.count == 1)
        #expect(client.sent.filter { $0.method == "session/prompt" }.isEmpty)
        await modelGate.release()
        await attachTask.value
        try await waitUntil {
            client.sent.map(\.method) == [
                "initialize",
                "session/new",
                "session/set_model",
                "session/set_model",
                "session/prompt",
            ]
        }
        await manager.flushAllPersistence()

        #expect(client.sent.map(\.method) == [
            "initialize",
            "session/new",
            "session/set_model",
            "session/set_model",
            "session/prompt",
        ])
        let modelParams = try client.sent
            .filter { $0.method == "session/set_model" }
            .map { try #require($0.params as? ACPSessionSetModelParams) }
        #expect(modelParams.map(\.modelId) == ["sonnet", "haiku"])
        #expect(session.currentModel == "haiku")
        #expect(try store.loadSession(id: "local")?.currentModel == "haiku")
    }

    @Test("reopened session stays detached when closed during model restoration")
    func reopenedSessionStaysDetachedWhenClosedDuringModelRestoration() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet"
        ))
        let client = ACPMockClient()
        let modelGate = PromptGate()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [
                    .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "opus", name: "Opus"),
                ],
                availableModes: [],
                currentModel: "opus",
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        client.scriptAsync(method: "session/set_model") { _ in
            await modelGate.waitInPrompt()
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        let attachTask = Task {
            await manager.attach(to: session.id, freshlyCreated: false)
        }

        try await waitUntilAsync { await modelGate.hasEntered }
        await manager.detach(sessionId: session.id)
        await modelGate.release()
        await attachTask.value

        #expect(session.agentState == .idle)
        #expect(manager.runners[session.id] == nil)
    }

    @Test("reopened session stays disconnected when stream ends during model restoration")
    func reopenedSessionStaysDisconnectedWhenStreamEndsDuringModelRestoration() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet"
        ))
        let client = ACPMockClient()
        let modelGate = PromptGate()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [
                    .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "opus", name: "Opus"),
                ],
                availableModes: [],
                currentModel: "opus",
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        client.scriptAsync(method: "session/set_model") { _ in
            await modelGate.waitInPrompt()
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        let attachTask = Task {
            await manager.attach(to: session.id, freshlyCreated: false)
        }

        try await waitUntilAsync { await modelGate.hasEntered }
        await client.shutdown()
        try await waitUntil {
            session.agentState == .disconnected
        }
        await modelGate.release()
        await attachTask.value

        #expect(session.agentState == .disconnected)
    }

    @Test("reopened session preserves newer mode selected during model restoration")
    func reopenedSessionPreservesNewerModeSelectedDuringModelRestoration() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            remoteSessionId: "remote-old",
            agentId: "codex",
            currentModel: "sonnet"
        ))
        let client = ACPMockClient()
        let modelGate = PromptGate()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [
                    .init(id: "sonnet", name: "Sonnet"),
                    .init(id: "opus", name: "Opus"),
                ],
                availableModes: [
                    .init(id: "default", name: "Default"),
                    .init(id: "plan", name: "Plan"),
                    .init(id: "act", name: "Act"),
                ],
                currentModel: "opus",
                currentMode: "default",
                promptSuggestions: []
            ))
        }
        client.scriptAsync(method: "session/set_model") { _ in
            await modelGate.waitInPrompt()
            return Data("{}".utf8)
        }
        client.script(method: "session/set_mode") { _ in Data("{}".utf8) }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        manager.pendingMode[session.id] = "plan"
        let attachTask = Task {
            await manager.attach(to: session.id, freshlyCreated: false)
        }

        try await waitUntilAsync { await modelGate.hasEntered }
        await manager.setMode(for: session.id, modeId: "act")
        await modelGate.release()
        await attachTask.value

        #expect(session.currentMode == "act")
        let modeParams = client.sent.compactMap { $0.params as? ACPSessionSetModeParams }
        #expect(modeParams.map(\.modeId) == ["act"])
    }

    @Test("replayed load history is ignored when a session is already hydrated")
    func replayedLoadHistoryIgnoredWhenHydrated() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        try appendMessage(
            .user(
                id: UUID(),
                text: "look at this",
                attachments: [
                    .init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png")
                ]
            ),
            to: store,
            seq: 0
        )
        try appendMessage(
            .agent(id: UUID(), StreamingText("the image looks good")),
            to: store,
            seq: 1
        )
        try appendMessage(
            .toolCall(.init(
                toolCallId: "tool-1",
                title: "Read file",
                kind: "read",
                status: "completed",
                content: "done"
            )),
            to: store,
            seq: 2
        )
        let client = ACPMockClient()
        scriptInitialize(client)
        client.scriptAsync(method: "session/load") { _ in
            client.emit(.init(sessionId: "remote-old", update: .userMessageChunk(.text("look at this"))))
            client.emit(.init(sessionId: "remote-old", update: .agentMessageChunk(.text("the image looks good"))))
            client.emit(.init(sessionId: "remote-old", update: .toolCall(.init(
                toolCallId: "tool-1",
                title: "Read file",
                kind: "read",
                status: "completed",
                content: [.content(.text("done"))],
                locations: nil,
                rawInput: nil,
                rawOutput: nil
            ))))
            return try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-restored",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        client.script(method: "session/prompt") { _ in
            client.emit(.init(sessionId: "remote-restored", update: .agentMessageChunk(.text("prompt response"))))
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        #expect(session.transcript.messages.count == 3)

        await manager.attach(to: session.id, freshlyCreated: false)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(client.yieldedUpdateCount == 3)
        #expect(client.sent.map(\.method) == ["initialize", "session/load"])
        #expect(session.transcript.messages.count == 3)
        #expect(try store.loadMessages(sessionId: "local").count == 3)
        guard case .user(_, _, let text, let attachments, _) = session.transcript.messages[0] else {
            Issue.record("Expected hydrated user message to remain first")
            return
        }
        #expect(text == "look at this")
        #expect(attachments == [
            .init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png")
        ])

        client.emit(.init(sessionId: "remote-restored", update: .agentMessageChunk(.text("live follow-up"))))
        try await waitUntil { session.transcript.messages.count == 4 }
        guard case .agent(_, _, let liveText) = session.transcript.messages[3] else {
            Issue.record("Expected post-load live update to be applied")
            return
        }
        #expect(liveText.value == "live follow-up")

        let runner = try #require(manager.runners[session.id])
        var delivered: Bool?
        runner.send(text: "next prompt", attachments: []) { succeeded in
            delivered = succeeded
        }
        try await waitUntil {
            delivered == true
                && session.transcript.streamingState == .idle
                && session.transcript.messages.count == 6
        }
    }

    @Test("mirror refresh syncs generated title metadata")
    func mirrorRefreshSyncsGeneratedTitleMetadata() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(.init(
            id: "local",
            agentId: "claude",
            title: "Old generated",
            titleSource: ACPSessionTitleSource.generated,
            remoteSessionId: "remote-old",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 0,
            updatedAt: 0,
            lastOpenedAt: 0,
            archived: false
        ))
        var titleCallbacks: [(ACPSession.ID, String)] = []
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            onSessionTitleUpdated: { titleCallbacks.append(($0, $1)) },
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: ACPMockClient()) }
        )

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        #expect(session.title == "Old generated")
        #expect(session.titleSource == ACPSessionTitleSource.generated)

        #expect(try store.updateGeneratedTitleIfNotManual(
            id: "local",
            title: "Adapter Title",
            updatedAt: 10
        ))

        await manager.refreshMirror(sessionId: "local")

        #expect(session.title == "Adapter Title")
        #expect(session.titleSource == .provider)
        #expect(manager.recent.first?.title == "Adapter Title")
        #expect(titleCallbacks.count == 1)
        #expect(titleCallbacks.first?.0 == "local")
        #expect(titleCallbacks.first?.1 == "Adapter Title")
    }

    @Test("fresh attach exposes initializing phase while initialize is pending")
    func freshAttachExposesInitializingPhaseWhileInitializeIsPending() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        let gate = AttachPhaseGate()
        client.scriptAsync(method: "initialize") { _ in
            await gate.enterAndWait()
            return try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: nil,
                authMethods: []
            ))
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = manager(store: store, client: client)
        let session = manager.createSession(agentId: "claude")

        let attachTask = Task { await manager.attach(to: session.id, freshlyCreated: true) }
        try await waitUntilAsync { await gate.hasEntered }

        #expect(session.firstRunConnectingPhase == .initializing)

        await gate.release()
        await attachTask.value
        #expect(session.firstRunConnectingPhase == nil)
        #expect(session.agentState == .ready)
    }

    @Test("fresh attach exposes creating session phase while session new is pending")
    func freshAttachExposesCreatingSessionPhaseWhileNewIsPending() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        let gate = AttachPhaseGate()
        client.scriptAsync(method: "session/new") { _ in
            await gate.enterAndWait()
            return try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-new",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        let manager = manager(store: store, client: client)
        let session = manager.createSession(agentId: "claude")

        let attachTask = Task { await manager.attach(to: session.id, freshlyCreated: true) }
        try await waitUntilAsync { await gate.hasEntered }

        #expect(session.firstRunConnectingPhase == .creatingSession)

        await gate.release()
        await attachTask.value
        #expect(session.firstRunConnectingPhase == nil)
        #expect(session.agentState == .ready)
    }

    @Test("restored attach does not expose first-run phase")
    func restoredAttachDoesNotExposeFirstRunPhase() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        let client = ACPMockClient()
        scriptInitialize(client)
        let gate = AttachPhaseGate()
        client.scriptAsync(method: "session/load") { _ in
            await gate.enterAndWait()
            return try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")

        let attachTask = Task { await manager.attach(to: session.id, freshlyCreated: false) }
        try await waitUntilAsync { await gate.hasEntered }

        #expect(session.firstRunConnectingPhase == nil)

        await gate.release()
        await attachTask.value
    }

    @Test("fresh session keeps updates emitted during session new")
    func freshSessionKeepsUpdatesEmittedDuringNew() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        client.scriptAsync(method: "session/new") { _ in
            client.emit(.init(sessionId: "remote-new", update: .agentMessageChunk(.text("welcome"))))
            return try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-new",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        let manager = manager(store: store, client: client)
        let session = manager.createSession(agentId: "claude")

        await manager.attach(to: session.id, freshlyCreated: true)
        try await waitUntil { session.transcript.messages.count == 1 }

        guard case .agent(_, _, let text) = session.transcript.messages[0] else {
            Issue.record("Expected fresh session update to be applied")
            return
        }
        #expect(text.value == "welcome")
    }

    @Test("non-replaying load still flushes queued prompt")
    func nonReplayingLoadStillFlushesQueuedPrompt() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        try appendMessage(
            .user(id: UUID(), text: "prior prompt", attachments: []),
            to: store,
            seq: 0
        )
        try store.upsertQueue(sessionId: "local", items: [
            QueuedPrompt(blocks: [.text("queued prompt")])
        ])
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-restored")
        client.script(method: "session/prompt") { request in
            let params = try #require(request.params as? ACPSessionPromptParams)
            #expect(params.sessionId == "remote-restored")
            #expect(params.prompt == [.text("queued prompt")])
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        try await waitUntil {
            client.sent.map(\.method) == ["initialize", "session/load", "session/prompt"]
                && session.queue.isEmpty
        }
        #expect(session.transcript.messages.count == 2)
        guard case .user(_, _, let text, _, _) = session.transcript.messages[1] else {
            Issue.record("Expected queued prompt to append after hydrated transcript")
            return
        }
        #expect(text == "queued prompt")
    }

    @Test("load failure falls back to session/new and auto-sends transcript context")
    func loadFailureFallsBackToNewAndAutoSendsTranscriptContext() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        let priorPrompt: ACPMessage = .user(id: UUID(), text: "prior prompt", attachments: [])
        try store.appendMessage(
            sessionId: "local", id: "m0", kind: priorPrompt.kind, seq: 0,
            payload: ACPMessageCodec.encode(priorPrompt), createdAt: 0
        )
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            throw JSONRPCError(code: -32601, message: "Method not found", data: nil)
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        client.script(method: "session/prompt") { request in
            let params = try #require(request.params as? ACPSessionPromptParams)
            #expect(params.sessionId == "remote-new")
            let block = try #require(params.prompt.first)
            guard case .text(let text) = block else {
                Issue.record("Expected text prompt block")
                return Data("null".utf8)
            }
            #expect(text.contains("prior prompt"))
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        try await waitUntil {
            client.sent.map(\.method) == ["initialize", "session/load", "session/new", "session/prompt"]
                && session.contextRestoreWarning == nil
        }
        #expect(session.remoteSessionId == "remote-new")
        #expect(session.contextRecoveryStatus == .restored)
        let row = try #require(try store.loadSession(id: "local"))
        #expect(row.remoteSessionId == "remote-new")
        #expect(!row.contextRecoveryPending)
    }

    @Test("pending force send waits for transcript recovery")
    func pendingForceSendWaitsForTranscriptRecovery() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        let priorPrompt: ACPMessage = .user(id: UUID(), text: "prior prompt", attachments: [])
        try appendMessage(priorPrompt, to: store, seq: 0)
        let forced = QueuedPrompt(blocks: [.text("forced prompt")])
        try store.upsertQueue(sessionId: "local", items: [forced])
        let newSessionGate = AttachPhaseGate()
        let recoveryGate = PromptGate()
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            throw JSONRPCError(code: -32601, message: "Method not found", data: nil)
        }
        client.scriptAsync(method: "session/new") { _ in
            await newSessionGate.enterAndWait()
            return try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-new",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        client.scriptAsync(method: "session/prompt") { request in
            let params = try #require(request.params as? ACPSessionPromptParams)
            if params.prompt.contains(where: { block in
                guard case .text(let text) = block else { return false }
                return text.contains("prior prompt")
            }) {
                await recoveryGate.waitInPrompt()
            }
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")

        let attachTask = Task { @MainActor in
            await manager.attach(to: session.id, freshlyCreated: false)
        }
        for _ in 0 ..< 50 where !(await newSessionGate.hasEntered) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await newSessionGate.hasEntered)
        await manager.queueForceSend(for: session.id, itemId: forced.id)
        await newSessionGate.release()
        try await waitUntil { client.sent.filter { $0.method == "session/prompt" }.count == 1 }
        await recoveryGate.release()
        await attachTask.value
        try await waitUntil { client.sent.filter { $0.method == "session/prompt" }.count == 2 }

        let prompts = client.sent.compactMap { $0.params as? ACPSessionPromptParams }
        #expect(prompts.count == 2)
        let recoveryBlock = try #require(prompts.first?.prompt.first)
        guard case .text(let recovery) = recoveryBlock else {
            Issue.record("Expected transcript recovery prompt first")
            return
        }
        #expect(recovery.contains("prior prompt"))
        let forcedBlock = try #require(prompts.last?.prompt.first)
        guard case .text(let forcedPrompt) = forcedBlock else {
            Issue.record("Expected forced queued prompt after recovery")
            return
        }
        #expect(forcedPrompt == "forced prompt")
    }

    @Test("new auth failure enters needsAuth with initialized auth method")
    func newAuthFailureEntersNeedsAuthWithInitializedAuthMethod() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        let method = terminalAuthMethod()
        scriptInitialize(client, authMethods: [method])
        client.script(method: "session/new") { _ in
            throw JSONRPCError(code: -32000, message: "Internal error: 401 Unauthorized", data: nil)
        }
        let manager = manager(store: store, client: client)
        let session = manager.createSession(agentId: "claude")

        await manager.attach(to: session.id, freshlyCreated: true)

        #expect(client.sent.map(\.method) == ["initialize", "session/new"])
        #expect(session.authMethods == [method])
        #expect(session.setupState == .needsAuth(methods: [method], reason: "401 Unauthorized"))
        #expect(session.lastError?.contains("401 Unauthorized") == true)
        #expect(manager.runners[session.id] == nil)
        if case .failed(let message) = session.agentState {
            #expect(message == "401 Unauthorized")
        } else {
            Issue.record("Expected failed agent state")
        }
    }

    @Test("load auth failure does not fall back to session new")
    func loadAuthFailureDoesNotFallBackToSessionNew() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        try appendMessage(
            .user(id: UUID(), text: "prior prompt", attachments: []),
            to: store,
            seq: 0
        )
        let client = ACPMockClient()
        let method = terminalAuthMethod()
        scriptInitialize(client, authMethods: [method])
        client.script(method: "session/load") { _ in
            throw JSONRPCError(code: -32000, message: "auth_required: 401", data: nil)
        }
        client.script(method: "session/new") { _ in
            Issue.record("session/new should not be called after auth-related session/load failure")
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize", "session/load"])
        #expect(session.remoteSessionId == "remote-old")
        #expect(session.authMethods == [method])
        #expect(session.setupState == .needsAuth(methods: [method], reason: "auth_required: 401"))
        #expect(session.lastError?.contains("auth_required: 401") == true)
        #expect(session.contextRecoveryStatus == nil)
        if case .failed(let message) = session.agentState {
            #expect(message == "auth_required: 401")
        } else {
            Issue.record("Expected failed agent state")
        }
    }

    @Test("pending auth method authenticates before creating session")
    func pendingAuthMethodAuthenticatesBeforeSessionCreate() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        let method = terminalAuthMethod()
        scriptInitialize(client, authMethods: [method])
        client.script(method: "authenticate") { req in
            let params = try #require(req.params as? ACPAuthenticateParams)
            #expect(params.methodId == method.id)
            return Data()
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = manager(store: store, client: client)
        let session = manager.createSession(agentId: "claude")
        session.pendingAuthMethodId = method.id

        await manager.attach(to: session.id, freshlyCreated: true)

        #expect(client.sent.map(\.method) == ["initialize", "authenticate", "session/new"])
        #expect(session.pendingAuthMethodId == nil)
        #expect(session.agentState == .ready)
    }

    @Test("prompt auth failure removes runner and blocks queue retry on failed connection")
    func promptAuthFailureRemovesRunnerAndBlocksQueueRetryOnFailedConnection() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        let method = terminalAuthMethod()
        scriptInitialize(client, authMethods: [method])
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        client.script(method: "session/prompt") { _ in
            throw JSONRPCError(code: -32000, message: "login required", data: nil)
        }
        let manager = manager(store: store, client: client)
        let session = manager.createSession(agentId: "claude")

        await manager.attach(to: session.id, freshlyCreated: true)
        let runner = try #require(manager.runners[session.id])
        session.enqueue(blocks: [.text("queued")])
        runner.persistQueue()

        runner.flushQueueIfIdle()
        try await waitUntil {
            manager.runners[session.id] == nil
                && session.setupState == .needsAuth(methods: [method], reason: "login required")
        }

        #expect(client.shutdownCount == 1)
        #expect(client.sent.map(\.method) == ["initialize", "session/new", "session/prompt"])
        #expect(session.queue.count == 1)
        #expect(session.queue[0].status == .pending)
        #expect(session.queue[0].lastError == nil)
        #expect(session.transcript.streamingState == .idle)

        session.queue[0].lastError = nil
        manager.persistQueue(for: session)
        manager.runners[session.id]?.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(client.sent.map(\.method) == ["initialize", "session/new", "session/prompt"])
    }

    @Test("direct auth failure leaves queued follow-up pending")
    func directAuthFailureLeavesQueuedFollowUpPending() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        let gate = AuthPromptFailureGate()
        let method = terminalAuthMethod()
        scriptInitialize(client, authMethods: [method])
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        client.scriptAsync(method: "session/prompt") { _ in
            try await gate.handlePrompt()
        }
        let manager = manager(store: store, client: client)
        let session = manager.createSession(agentId: "claude")

        await manager.attach(to: session.id, freshlyCreated: true)
        let runner = try #require(manager.runners[session.id])
        runner.send(blocks: [.text("first")], intent: .auto)
        try await waitUntilAsync { await gate.hasEntered }
        runner.send(blocks: [.text("follow-up")], intent: .auto)

        await gate.release()
        try await waitUntil {
            manager.runners[session.id] == nil
                && session.setupState == .needsAuth(methods: [method], reason: "login required")
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(client.sent.map(\.method) == ["initialize", "session/new", "session/prompt"])
        #expect(session.queue.count == 1)
        #expect(session.queue[0].status == .pending)
        #expect(session.queue[0].lastError == nil)
        #expect(session.queue[0].blocks == [.text("follow-up")])
        #expect(session.transcript.streamingState == .idle)
    }

    @Test("submit while needsAuth rejects prompt and preserves draft")
    func submitWhileNeedsAuthRejectsPromptAndPreservesDraft() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let manager = manager(store: store, client: ACPMockClient())
        let session = manager.createSession(agentId: "claude")
        let method = terminalAuthMethod()
        let draft = ACPComposerDraft(segments: [.text("do not clear me")])
        session.authMethods = [method]
        session.setupState = .needsAuth(methods: [method], reason: "login required")
        session.agentState = .failed("login required")
        session.replaceComposerDraft(draft)
        var completed: Bool?

        let accepted = manager.submit(
            sessionId: session.id,
            text: "do not clear me",
            attachments: [],
            intent: .auto,
            draft: draft
        ) { succeeded in
            completed = succeeded
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(accepted == false)
        #expect(completed == nil)
        #expect(session.queue.isEmpty)
        #expect(session.composerDraft == draft)
        #expect(session.setupState == .needsAuth(methods: [method], reason: "login required"))
    }

    @Test("load fallback automatically sends transcript recovery before queued prompt")
    func loadFallbackAutomaticallySendsTranscriptRecoveryBeforeQueuedPrompt() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        try appendMessage(
            .user(id: UUID(), text: "Prior context", attachments: []),
            to: store,
            seq: 0
        )
        try store.upsertQueue(sessionId: "local", items: [
            QueuedPrompt(blocks: [.text("queued prompt")])
        ])
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            throw JSONRPCError(code: -32601, message: "Method not found", data: nil)
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        client.script(method: "session/prompt") { _ in Data("null".utf8) }
        client.script(method: "session/prompt") { _ in Data("null".utf8) }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        try await waitUntil {
            client.sent.filter { $0.method == "session/prompt" }.count == 2
                && session.queue.isEmpty
        }
        #expect(session.contextRestoreWarning == nil)
        #expect(try store.loadSession(id: "local")?.contextRecoveryPending == false)
        let prompts = client.sent.compactMap { $0.params as? ACPSessionPromptParams }
        #expect(prompts.count == 2)
        let firstBlock = try #require(prompts.first?.prompt.first)
        guard case .text(let recovery) = firstBlock else {
            Issue.record("Expected transcript recovery prompt first")
            return
        }
        #expect(recovery.contains("Prior context"))
        #expect(prompts.last?.prompt == [.text("queued prompt")])
        #expect(session.queue.isEmpty)
        #expect(try store.loadSession(id: "local")?.contextRecoveryPending == false)
    }

    @Test("load fallback keeps pending fork context out of generic recovery")
    func loadFallbackDefersPendingForkContextUntilFirstPrompt() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let inherited = try ACPSessionForkSnapshot(
            sourceBoundarySequence: 0,
            messages: [.init(role: .user, text: "Prior context")]
        ).copiedMessages(targetSessionID: "local", createdAt: 0)
        let fork = ACPSessionForkRecord(
            targetSessionID: "local",
            sourceSessionID: "source",
            sourceAgentID: "claude",
            sourceBoundarySequence: 0,
            inheritedMessageCount: 1,
            phase: .ready,
            mechanism: .transcriptTransfer,
            contextDeliveryPending: true
        )
        try store.createFork(session: row(remoteSessionId: "remote-old"), messages: inherited, record: fork)

        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            throw JSONRPCError(code: -32601, message: "Method not found", data: nil)
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize", "session/load", "session/new"])
        #expect(session.contextRecoveryStatus != .sendingTranscript)
        #expect(session.contextRestoreWarning == nil)
        #expect(try store.loadSession(id: "local")?.contextRecoveryPending == false)
        #expect(session.forkRecord?.contextDeliveryPending == true)
    }

    @Test("failed automatic transcript recovery keeps queued prompt blocked")
    func failedAutomaticTranscriptRecoveryKeepsQueuedPromptBlocked() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        try appendMessage(
            .user(id: UUID(), text: "Prior context", attachments: []),
            to: store,
            seq: 0
        )
        try store.upsertQueue(sessionId: "local", items: [
            QueuedPrompt(blocks: [.text("queued prompt")])
        ])
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            throw JSONRPCError(code: -32601, message: "Method not found", data: nil)
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        client.script(method: "session/prompt") { _ in
            throw ACPClientError.noScript(method: "session/prompt")
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        try await waitUntil {
            session.contextRecoveryStatus == .failed("Transcript recovery failed.")
                && session.transcript.streamingState == .idle
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(client.sent.filter { $0.method == "session/prompt" }.count == 1)
        #expect(session.queue.count == 1)
        #expect(session.queue.first?.status == .pending)
        #expect(session.queue.first?.lastError == nil)
        #expect(try store.loadSession(id: "local")?.contextRecoveryPending == true)
    }

    @Test("superseded load failure does not persist transcript recovery")
    func supersededLoadFailureDoesNotPersistTranscriptRecovery() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        try appendMessage(
            .user(id: UUID(), text: "Prior context", attachments: []),
            to: store,
            seq: 0
        )
        let originalClient = ACPMockClient()
        let replacementClient = ACPMockClient()
        let originalLoadGate = AttachPhaseGate()
        let replacementLoadGate = AttachPhaseGate()
        scriptInitialize(originalClient)
        originalClient.scriptAsync(method: "session/load") { _ in
            await originalLoadGate.enterAndWait()
            throw NSError(domain: "ACPSessionManagerAttachRestoreTests", code: 2)
        }
        scriptSessionResult(originalClient, method: "session/new", sessionId: "remote-stale")
        scriptInitialize(replacementClient)
        replacementClient.scriptAsync(method: "session/load") { _ in
            await replacementLoadGate.enterAndWait()
            return try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-current",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        var connectionCount = 0
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in
                connectionCount += 1
                return ACPConnection(client: connectionCount == 1 ? originalClient : replacementClient)
            }
        )

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: session.id)
        let originalAttach = Task { await manager.attach(to: session.id, freshlyCreated: false) }
        try await waitUntilAsync { await originalLoadGate.hasEntered }

        let restart = Task { await manager.restartConnection(to: session.id) }
        try await waitUntilAsync { await replacementLoadGate.hasEntered }
        #expect(session.contextRecoveryStatus == .restoring)

        await originalLoadGate.release()
        await originalAttach.value

        #expect(!originalClient.sent.contains { $0.method == "session/new" })
        #expect(session.contextRecoveryStatus == .restoring)
        #expect(try store.loadSession(id: session.id)?.contextRecoveryPending == false)

        await replacementLoadGate.release()
        await restart.value

        #expect(session.agentState == .ready)
        #expect(try store.loadSession(id: session.id)?.contextRecoveryPending == false)
    }

    @Test("missing remote id falls back to session/new without warning for empty session")
    func missingRemoteIdFallsBackToNewWithoutWarningForEmptySession() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: nil))
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        let methods = client.sent.map(\.method)
        #expect(methods == ["initialize", "session/new"])
        #expect(session.remoteSessionId == "remote-new")
        #expect(session.contextRestoreWarning == nil)
        let row = try #require(try store.loadSession(id: "local"))
        #expect(row.remoteSessionId == "remote-new")
        #expect(!row.contextRecoveryPending)
    }

    @Test("missing remote id warns and sends transcript recovery for nonempty session")
    func missingRemoteIdWarnsAndSendsTranscriptRecoveryForNonemptySession() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: nil))
        try appendMessage(
            .user(id: UUID(), text: "Recover this context", attachments: []),
            to: store,
            seq: 0
        )
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        client.script(method: "session/prompt") { _ in Data("null".utf8) }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        try await waitUntil {
            client.sent.map(\.method) == ["initialize", "session/new", "session/prompt"]
                && session.contextRestoreWarning == nil
        }
        #expect(session.remoteSessionId == "remote-new")
        #expect(session.contextRecoveryStatus == .restored)
        let prompt = try #require(client.sent.last?.params as? ACPSessionPromptParams)
        let block = try #require(prompt.prompt.first)
        guard case .text(let recovery) = block else {
            Issue.record("Expected recovery prompt")
            return
        }
        #expect(recovery.contains("Recover this context"))
        let row = try #require(try store.loadSession(id: "local"))
        #expect(row.remoteSessionId == "remote-new")
        #expect(!row.contextRecoveryPending)
    }

    @Test("pending context recovery auto-sends after restart")
    func pendingContextRecoveryAutoSendsAfterRestart() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-new"))
        try store.setContextRecoveryPending(sessionId: "local", pending: true)
        try appendMessage(
            .user(id: UUID(), text: "Context before restart", attachments: []),
            to: store,
            seq: 0
        )
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-new")
        client.script(method: "session/prompt") { request in
            let params = try #require(request.params as? ACPSessionPromptParams)
            #expect(params.sessionId == "remote-new")
            let block = try #require(params.prompt.first)
            guard case .text(let text) = block else {
                Issue.record("Expected text prompt block")
                return Data("null".utf8)
            }
            #expect(text.contains("Context before restart"))
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        try await waitUntil {
            client.sent.map(\.method) == ["initialize", "session/load", "session/prompt"]
                && session.contextRestoreWarning == nil
        }
        #expect(session.contextRecoveryStatus == .restored)
        #expect(try store.loadSession(id: "local")?.contextRecoveryPending == false)
    }

    @Test("session/load -32602 surfaces the agent's own message instead of a generic one")
    func loadInvalidParamsSurfacesReadableMessage() async throws {
        // OpenCode v2 returns -32602 from session/load when `cwd` no longer
        // matches the session's stored directory. No local transcript means
        // there is nothing to auto-resend, so the warning this sets is not
        // immediately cleared and can be asserted directly.
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        try store.setContextRecoveryPending(sessionId: "local", pending: true)
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            throw JSONRPCError(code: -32602, message: "cwd mismatch: session was created in /a, request has /b", data: nil)
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        try await waitUntil {
            client.sent.map(\.method) == ["initialize", "session/load", "session/new"]
        }
        #expect(session.contextRestoreWarning?.message.contains("cwd mismatch") == true)
    }

    @Test("attach retry clears stale warning before setup failure")
    func attachRetryClearsStaleWarningBeforeSetupFailure() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .missing(reason: "missing") }
        )
        let session = manager.createSession(agentId: "claude")
        session.contextRestoreWarning = .init(
            message: "old warning",
            canSendTranscript: true
        )

        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(session.setupState == .needsSetup(reason: "missing"))
        #expect(session.agentState == .failed("missing"))
        #expect(session.contextRestoreWarning == nil)
    }

    @Test("remote managed adapter absence maps to needs setup")
    func remoteManagedAdapterAbsenceMapsToNeedsSetup() async throws {
        let root = "/srv/task4-missing-\(UUID().uuidString)"
        RemoteHostRegistry.shared.register(root: root, host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: root) }
        let store = try ACPSessionStore(path: tmpStorePath())
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: root,
            store: store,
            remoteAdapterResolver: { _, _, _ in
                .missing(reason: "codex-acp is not installed on devbox.")
            }
        )
        let session = manager.createSession(agentId: "codex")

        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(session.setupState == .needsSetup(reason: "codex-acp is not installed on devbox."))
        #expect(session.agentState == .failed("codex-acp is not installed on devbox."))
    }

    @Test("remote prerequisite failure maps to setup error")
    func remotePrerequisiteFailureMapsToSetupError() async throws {
        let root = "/srv/task4-error-\(UUID().uuidString)"
        RemoteHostRegistry.shared.register(root: root, host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: root) }
        let store = try ACPSessionStore(path: tmpStorePath())
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: root,
            store: store,
            remoteAdapterResolver: { _, _, _ in
                .error(message: "Node.js and npm are unavailable.")
            }
        )
        let session = manager.createSession(agentId: "codex")

        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(session.setupState == .setupError(reason: "Node.js and npm are unavailable."))
        #expect(session.agentState == .failed("Node.js and npm are unavailable."))
    }

    @Test("remote setup resolution is reused for absolute launch")
    func remoteSetupResolutionIsReusedForAbsoluteLaunch() async throws {
        let root = "/srv/task4-ready-\(UUID().uuidString)"
        RemoteHostRegistry.shared.register(root: root, host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: root) }
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        final class Capture {
            var resolverCalls = 0
            var launchSpec: ACPLaunchSpec?
        }
        let capture = Capture()
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: root,
            store: store,
            remoteAdapterResolver: { _, descriptor, _ in
                capture.resolverCalls += 1
                #expect(descriptor == .codex)
                return .ready(.init(
                    adapterPath: "/home/dev/.alas/acp/codex/bin/codex-acp",
                    nodeBinDirectory: "/home/dev/node/v22/bin"
                ))
            },
            connectionFactory: { spec, host, _ in
                #expect(host == "devbox")
                capture.launchSpec = spec
                return ACPConnection(client: client)
            }
        )
        let session = manager.createSession(agentId: "codex")

        await manager.attach(to: session.id, freshlyCreated: true)

        #expect(capture.resolverCalls == 1)
        #expect(capture.launchSpec?.command == "/home/dev/.alas/acp/codex/bin/codex-acp")
        #expect(capture.launchSpec?.remoteNodeBinDirectory == "/home/dev/node/v22/bin")
        #expect(session.setupState == .ready)
    }

    @Test("load failure followed by new failure leaves stale warning cleared")
    func loadFailureFollowedByNewFailureLeavesStaleWarningCleared() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            throw JSONRPCError(code: -32601, message: "Method not found", data: nil)
        }
        client.script(method: "session/new") { _ in
            throw JSONRPCError(code: -32000, message: "new failed", data: nil)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        session.contextRestoreWarning = .init(
            message: "old warning",
            canSendTranscript: true
        )
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize", "session/load", "session/new"])
        #expect(session.remoteSessionId == "remote-old")
        #expect(session.contextRestoreWarning == nil)
        if case .failed(let message) = session.agentState {
            #expect(message.contains("new failed"))
        } else {
            Issue.record("Expected failed agent state")
        }
        #expect(try store.loadSession(id: "local")?.remoteSessionId == "remote-old")
    }

    @Test("send transcript context clears warning")
    func sendTranscriptContextClearsWarning() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-new"))
        try appendMessage(
            .user(id: UUID(), text: "What changed?", attachments: []),
            to: store,
            seq: 0
        )
        try appendMessage(
            .agent(id: UUID(), StreamingText("We changed persistence.")),
            to: store,
            seq: 1
        )
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-new")
        client.script(method: "session/prompt") { request in
            let params = try #require(request.params as? ACPSessionPromptParams)
            #expect(params.sessionId == "remote-new")
            #expect(params.prompt.count == 1)
            let block = try #require(params.prompt.first)
            guard case .text(let text) = block else {
                Issue.record("Expected text prompt block")
                return Data("null".utf8)
            }
            #expect(text.contains("The previous agent context for this pane could not be restored."))
            #expect(text.contains("## You\n\nWhat changed?"))
            #expect(text.contains("## Agent\n\nWe changed persistence."))
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)
        session.contextRestoreWarning = .init(
            message: "Agent context could not be restored.",
            canSendTranscript: true
        )
        let messageCountBefore = session.transcript.messages.count

        let accepted = manager.sendTranscriptAsContext(sessionId: session.id, agentName: "Agent")

        #expect(accepted)
        try await waitUntil { session.contextRestoreWarning == nil }
        #expect(session.transcript.messages.count == messageCountBefore)
        #expect(client.sent.map(\.method) == ["initialize", "session/load", "session/prompt"])
    }

    @Test("send transcript context clears persisted recovery pending flag")
    func sendTranscriptContextClearsPersistedPendingFlag() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-new"))
        try appendMessage(
            .user(id: UUID(), text: "What changed?", attachments: []),
            to: store,
            seq: 0
        )
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-new")
        client.script(method: "session/prompt") { _ in Data("null".utf8) }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)
        try store.setContextRecoveryPending(sessionId: "local", pending: true)
        session.contextRestoreWarning = .init(
            message: "Agent context could not be restored.",
            canSendTranscript: true
        )

        #expect(session.contextRestoreWarning?.canSendTranscript == true)
        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: "Agent"))
        try await waitUntil { session.contextRestoreWarning == nil }
        #expect(try store.loadSession(id: "local")?.contextRecoveryPending == false)
    }

    @Test("failed transcript context send keeps warning and transcript")
    func failedTranscriptContextSendKeepsWarningAndTranscript() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-new"))
        try appendMessage(
            .user(id: UUID(), text: "What changed?", attachments: []),
            to: store,
            seq: 0
        )
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-new")
        client.script(method: "session/prompt") { _ in
            throw ACPClientError.noScript(method: "session/prompt")
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)
        let warning = ACPSession.ContextRestoreWarning(
            message: "Agent context could not be restored.",
            canSendTranscript: true
        )
        session.contextRestoreWarning = warning
        let messageCountBefore = session.transcript.messages.count

        let accepted = manager.sendTranscriptAsContext(sessionId: session.id, agentName: "Agent")

        #expect(accepted)
        try await waitUntil {
            client.sent.filter { $0.method == "session/prompt" }.count == 1
                && session.transcript.streamingState == .idle
        }
        #expect(session.contextRestoreWarning == warning)
        #expect(session.contextRecoveryStatus == .failed("Transcript recovery failed."))
        #expect(session.transcript.messages.count == messageCountBefore)
    }

    @Test("cancelled recovery context send reports not delivered")
    func cancelledRecoveryContextSendReportsNotDelivered() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-new"))
        try appendMessage(
            .user(id: UUID(), text: "What changed?", attachments: []),
            to: store,
            seq: 0
        )
        let client = ACPMockClient()
        let gate = PromptGate()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-new")
        client.scriptAsync(method: "session/prompt") { _ in
            await gate.waitInPrompt()
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)
        let runner = try #require(manager.runners[session.id])
        let warning = ACPSession.ContextRestoreWarning(
            message: "Agent context could not be restored.",
            canSendTranscript: true
        )
        session.contextRestoreWarning = warning
        var delivered: Bool?

        runner.sendRecoveryContext("recovery context") { result in
            delivered = result
        }
        try await waitUntilAsync { await gate.hasEntered }
        await runner.userCancel()
        await gate.release()
        try await waitUntil { delivered != nil }
        #expect(delivered == false)
        #expect(session.transcript.streamingState == .idle)
        #expect(session.contextRestoreWarning == warning)
    }

    @Test("recovery context completion drains queued prompt")
    func recoveryContextCompletionDrainsQueuedPrompt() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-new"))
        try appendMessage(
            .user(id: UUID(), text: "What changed?", attachments: []),
            to: store,
            seq: 0
        )
        let client = ACPMockClient()
        let gate = PromptGate()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-new")
        client.scriptAsync(method: "session/prompt") { _ in
            await gate.waitInPrompt()
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)
        let runner = try #require(manager.runners[session.id])

        runner.sendRecoveryContext("recovery context")
        try await waitUntilAsync { await gate.hasEntered }
        runner.send(blocks: [.text("normal prompt")], intent: .auto)

        #expect(session.queue.count == 1)
        await gate.release()
        try await waitUntil {
            client.sent.filter { $0.method == "session/prompt" }.count == 2
                && session.queue.isEmpty
                && session.transcript.streamingState == .idle
        }

        let prompts = client.sent.filter { $0.method == "session/prompt" }
        let second = try #require(prompts.last?.params as? ACPSessionPromptParams)
        #expect(second.prompt == [.text("normal prompt")])
    }

    @Test("recovery context superseded by a steer clears the restoring status")
    func recoveryContextSupersededBySteerClearsStatus() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-new"))
        try appendMessage(
            .user(id: UUID(), text: "What changed?", attachments: []),
            to: store,
            seq: 0
        )
        let client = ACPMockClient()
        let recoveryGate = PromptGate()
        let steerGate = PromptGate()
        let promptCount = PromptCounter()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-new")
        // Gate the first (recovery) prompt so it stays in flight while the
        // user steers, and hold the steer's replacement prompt so it still
        // owns the transport when the recovery RPC finally returns.
        client.scriptAsync(method: "session/prompt") { _ in
            switch await promptCount.next() {
            case 1: await recoveryGate.waitInPrompt()
            case 2: await steerGate.waitInPrompt()
            default: break
            }
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)
        let runner = try #require(manager.runners[session.id])
        session.contextRestoreWarning = .init(
            message: "Agent context could not be restored.",
            canSendTranscript: true
        )

        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: "Agent"))
        #expect(session.contextRecoveryStatus == .sendingTranscript)
        try await waitUntilAsync { await recoveryGate.hasEntered }

        // User steers a new prompt while the recovery context is still in
        // flight — the steer's replacement prompt takes over the transport.
        runner.steer(blocks: [.text("actually do this instead")])

        // The recovery RPC now returns, superseded by the steer. The
        // "Restoring…" spinner must resolve rather than strand forever.
        await recoveryGate.release()
        try await waitUntil { session.contextRecoveryStatus != .sendingTranscript }

        await steerGate.release()
    }

    @Test("recovery context superseded by a newer prompt clears the restoring status")
    func recoveryContextSupersededByNewerPromptClearsStatus() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-new"))
        try appendMessage(
            .user(id: UUID(), text: "What changed?", attachments: []),
            to: store,
            seq: 0
        )
        let client = ACPMockClient()
        let recoveryGate = PromptGate()
        let newerPromptGate = PromptGate()
        let promptCount = PromptCounter()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-new")
        client.scriptAsync(method: "session/prompt") { _ in
            switch await promptCount.next() {
            case 1: await recoveryGate.waitInPrompt()
            case 2: await newerPromptGate.waitInPrompt()
            default: break
            }
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)
        let runner = try #require(manager.runners[session.id])
        session.contextRestoreWarning = .init(
            message: "Agent context could not be restored.",
            canSendTranscript: true
        )

        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: "Agent"))
        #expect(session.contextRecoveryStatus == .sendingTranscript)
        try await waitUntilAsync { await recoveryGate.hasEntered }

        runner.sendNow(blocks: [.text("actually do this instead")], queuedItemId: nil)
        try await waitUntilAsync { await newerPromptGate.hasEntered }

        await recoveryGate.release()
        try await waitUntil { session.contextRecoveryStatus != .sendingTranscript }

        await newerPromptGate.release()
    }

    @Test("replaced runner recovery completion cannot overwrite current recovery status", arguments: [false, true])
    func replacedRunnerRecoveryCompletionCannotOverwriteCurrentStatus(shouldFail: Bool) async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-new"))
        try appendMessage(
            .user(id: UUID(), text: "What changed?", attachments: []),
            to: store,
            seq: 0
        )
        let originalClient = ACPMockClient()
        let replacementClient = ACPMockClient()
        let recoveryGate = PromptGate()
        scriptInitialize(originalClient)
        scriptSessionResult(originalClient, method: "session/load", sessionId: "remote-new")
        originalClient.scriptAsync(method: "session/prompt") { _ in
            await recoveryGate.waitInPrompt()
            if shouldFail {
                throw JSONRPCError(code: -32000, message: "late recovery failure", data: nil)
            }
            return Data("null".utf8)
        }
        scriptInitialize(replacementClient)
        scriptSessionResult(replacementClient, method: "session/load", sessionId: "remote-new")
        var connectionCount = 0
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in
                connectionCount += 1
                return ACPConnection(client: connectionCount == 1 ? originalClient : replacementClient)
            }
        )

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: session.id)
        await manager.attach(to: session.id, freshlyCreated: false)
        let originalRunner = try #require(manager.runners[session.id])
        session.contextRestoreWarning = .init(
            message: "Agent context could not be restored.",
            canSendTranscript: true
        )

        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: "Agent"))
        try await waitUntilAsync { await recoveryGate.hasEntered }

        await manager.restartConnection(to: session.id)
        #expect(manager.runners[session.id] !== originalRunner)
        #expect(session.agentState == .ready)
        session.contextRecoveryStatus = .restored

        await recoveryGate.release()
        try await Task.sleep(for: .milliseconds(100))

        #expect(session.contextRecoveryStatus == .restored)
        await manager.detach(sessionId: session.id)
    }

    @Test("transcript context prompt requires conversation")
    func transcriptContextPromptRequiresConversation() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = manager.createSession(agentId: "claude")
        session.appendSystemNotice("Agent context could not be restored.")

        #expect(manager.transcriptContextPrompt(for: session, agentName: "Agent") == nil)
        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: "Agent") == false)
    }

    @Test("send transcript context rejects unavailable states")
    func sendTranscriptContextRejectsUnavailableStates() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = manager.createSession(agentId: "claude")
        session.recordUserPrompt(text: "What changed?", attachments: [])

        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: nil) == false)

        session.contextRestoreWarning = .init(message: "warning", canSendTranscript: false)
        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: nil) == false)

        session.contextRestoreWarning = .init(message: "warning", canSendTranscript: true)
        session.agentState = .ready
        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: nil) == false)

        session.transcript.streamingState = .streaming
        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: nil) == false)

        session.transcript.streamingState = .idle
        session.enqueue(blocks: [.text("queued")])
        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: nil) == false)
    }

    @Test("attach waits for tail-first hydration backfill before runner setup")
    func attachWaitsForBackfill() async throws {
        // Persist enough messages that hydration splits into a tail-first
        // apply + background backfill — otherwise the bug being guarded
        // against (runner constructed against a partial transcript) can't
        // even materialise.
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        let total = ACPTranscript.tailWindow * 3
        for i in 0..<total {
            try appendMessage(
                .user(id: UUID(), text: "m\(i)", attachments: []),
                to: store, seq: Int64(i))
        }

        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-restored")

        // Capture the in-memory transcript length at the moment attach decides
        // setup is ready. With the fix in place, attach awaits backfill first,
        // so the captured count matches the full persisted length. Without
        // the fix, only the tail window has been applied.
        final class Captured { var count: Int = -1 }
        let captured = Captured()
        let mgrBox: UnsafeMutablePointer<ACPSessionManager?> = .allocate(capacity: 1)
        mgrBox.initialize(to: nil)
        defer { mgrBox.deinitialize(count: 1)
        mgrBox.deallocate() }
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in
                captured.count = mgrBox.pointee?.sessions["local"]?.transcript.messages.count ?? -2
                return .ready
            },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        mgrBox.pointee = manager

        _ = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        // Sanity check: hydrateIfNeeded returned with only the tail applied.
        #expect(manager.sessions["local"]?.transcript.messages.count == ACPTranscript.tailWindow)

        await manager.attach(to: "local", freshlyCreated: false)

        #expect(captured.count == total,
                "setup evaluator must observe the fully-materialised transcript")
        #expect(manager.sessions["local"]?.transcript.messages.count == total)
    }

    private func tmpStorePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-attach-restore-\(UUID()).sqlite").path
    }

    private func appendMessage(
        _ message: ACPMessage,
        to store: ACPSessionStore,
        seq: Int64
    ) throws {
        // Matches `ACPSessionRunner.persistIndices`'s own id convention
        // (`msg-<sessionId>-<index>`) — a row hydrated under any OTHER id
        // looks, to that same convention, like a DIFFERENT row at this
        // array position, so a live reconciliation that persists the
        // position it resolved to (correctly, since that write is real)
        // creates a duplicate instead of updating this one.
        try store.appendMessage(
            sessionId: "local",
            id: "msg-local-\(seq)",
            kind: message.kind,
            seq: seq,
            payload: ACPMessageCodec.encode(message),
            createdAt: seq
        )
    }

    private func waitUntil(
        timeoutNanos: UInt64 = 10_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanos {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitUntilAsync(
        timeoutNanos: UInt64 = 10_000_000_000,
        condition: @escaping () async -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !(await condition()) {
            if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanos {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func row(
        id: String = "local",
        remoteSessionId: String?,
        agentId: String = "claude",
        currentModel: String? = nil,
        currentMode: String? = nil,
        configOptionValues: [String: ACPConfigValue] = [:]
    ) -> ACPSessionRow {
        ACPSessionRow(
            id: id,
            agentId: agentId,
            title: "Stored session",
            titleSource: .placeholder,
            remoteSessionId: remoteSessionId,
            currentModel: currentModel,
            currentMode: currentMode,
            configOptionValues: configOptionValues,
            autoRun: false,
            createdAt: 0,
            updatedAt: 0,
            lastOpenedAt: 0,
            archived: false
        )
    }

    private func manager(
        store: ACPSessionStore,
        client: ACPMockClient,
        mcpProjectContextProvider: ACPSessionManager.MCPProjectContextProvider? = nil,
        onQueueChanged: ((ACPSession.ID, Bool) -> Void)? = nil,
        onCheckpointCapture: (@MainActor (_ prompt: String, _ hasAttachments: Bool) async -> CheckpointID?)? = nil
    ) -> ACPSessionManager {
        ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            onQueueChanged: onQueueChanged,
            onCheckpointCapture: onCheckpointCapture,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) },
            mcpProjectContextProvider: mcpProjectContextProvider
        )
    }

    private func scriptInitialize(
        _ client: ACPMockClient,
        authMethods: [ACPInitializeResult.ACPAuthMethod] = []
    ) {
        client.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: nil,
                authMethods: authMethods
            ))
        }
    }

    private func terminalAuthMethod() -> ACPInitializeResult.ACPAuthMethod {
        ACPInitializeResult.ACPAuthMethod(
            id: "claude-login",
            name: "Claude Login",
            kind: .terminal
        )
    }

    private func scriptSessionResult(_ client: ACPMockClient, method: String, sessionId: String) {
        client.script(method: method) { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: sessionId,
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }
    }

private actor AttachPhaseGate {
        private var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        var hasEntered: Bool { entered }

        func enterAndWait() async {
            if released { return }
            entered = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private actor PromptGate {
        private var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        var hasEntered: Bool { entered }

        func waitInPrompt() async {
            if released { return }
            entered = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private actor PromptCounter {
        private var count = 0

        func next() -> Int {
            count += 1
            return count
        }
    }
    private actor ModelModeSelectionRecorder {
        private(set) var values: [String] = []

        func append(_ value: String) {
            values.append(value)
        }
    }

    private actor AuthPromptFailureGate {
        private var entered = false
        private var released = false
        private var attempts = 0
        private var continuation: CheckedContinuation<Void, Never>?

        var hasEntered: Bool { entered }

        func handlePrompt() async throws -> Data {
            attempts += 1
            guard attempts == 1 else {
                return Data("null".utf8)
            }
            if !released {
                entered = true
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }
            throw JSONRPCError(code: -32000, message: "login required", data: nil)
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }
}

private actor ManagerBrokerGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var hasEntered: Bool { entered }
    var hasWaiters: Bool { !waiters.isEmpty }

    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private func queuedPromptFixture(
    id: UUID = UUID(),
    text: String,
    status: QueuedPrompt.Status,
    brokerGeneration: UInt64?,
    deliveryUncertain: Bool = false,
    lastError: String? = nil
) throws -> QueuedPrompt {
    let prompt = QueuedPrompt(
        id: id,
        blocks: [.text(text)],
        status: status,
        lastError: lastError
    )
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(prompt)) as? [String: Any])
    object["deliveryUncertain"] = deliveryUncertain
    if let brokerGeneration {
        object["dispatchedBrokerGeneration"] = brokerGeneration
    }
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(QueuedPrompt.self, from: data)
}

private actor ManagerBrokerService: ACPBrokerServicing {
    let openGate = ManagerBrokerGate()
    private let generation: UInt64
    private let supportsPromptResponses: Bool
    private var shouldHoldNextOpen = false
    private var completedOperationKeys: Set<ACPBrokerOperationKey> = []
    private(set) var replayedPromptOperationKeys: [ACPBrokerOperationKey] = []
    var opened: [ACPBrokerOpenParams] = []
    var attached: [ACPBrokerAttachParams] = []
    var sent: [ACPBrokerSendParams] = []
    var notified: [ACPBrokerNotifyParams] = []
    var responded: [ACPBrokerRespondParams] = []
    var acks: [ACPBrokerAckParams] = []
    var detached: [ACPBrokerDetachParams] = []
    var closed: [ACPBrokerCloseParams] = []
    var snapshotInitializeResult: ACPBrokerJSONValue?
    var snapshotRemoteSessionResult: ACPBrokerJSONValue?

    init(generation: UInt64 = 7, supportsPromptResponses: Bool = false) {
        self.generation = generation
        self.supportsPromptResponses = supportsPromptResponses
    }

    func holdNextOpen() {
        shouldHoldNextOpen = true
    }

    func setSnapshotResults(
        initializeResult: ACPBrokerJSONValue?,
        remoteSessionResult: ACPBrokerJSONValue?
    ) {
        snapshotInitializeResult = initializeResult
        snapshotRemoteSessionResult = remoteSessionResult
    }

    func open(_ params: ACPBrokerOpenParams) async throws -> ACPBrokerOpenResult {
        if shouldHoldNextOpen {
            shouldHoldNextOpen = false
            await openGate.wait()
        }
        opened.append(params)
        return ACPBrokerOpenResult(snapshot: snapshot(params: params), adopted: false)
    }

    func attach(_ params: ACPBrokerAttachParams) async throws -> ACPBrokerAttachResult {
        attached.append(params)
        return ACPBrokerAttachResult(
            snapshot: snapshot(brokerId: params.brokerId, acknowledgedCursor: params.acknowledgedCursor),
            events: []
        )
    }

    func send(_ params: ACPBrokerSendParams) async throws -> ACPBrokerSendResult {
        sent.append(params)
        let result: ACPBrokerJSONValue
        var replayed = false
        switch params.method {
        case "initialize":
            result = .object([
                "protocolVersion": .number(1),
                "authMethods": .array([])
            ])
        case "session/new":
            result = .object([
                "sessionId": .string("remote-broker"),
                "availableModels": .array([]),
                "availableModes": .array([]),
                "promptSuggestions": .array([]),
                "configOptions": .array([])
            ])
        case "session/load" where supportsPromptResponses:
            result = .object([
                "sessionId": .string("remote-broker"),
                "availableModels": .array([]),
                "availableModes": .array([]),
                "promptSuggestions": .array([]),
                "configOptions": .array([])
            ])
        case "session/prompt" where supportsPromptResponses:
            replayed = !completedOperationKeys.insert(params.operationKey).inserted
            if replayed {
                replayedPromptOperationKeys.append(params.operationKey)
            }
            result = .object(["stopReason": .string("end_turn")])
        default:
            throw ACPClientError.noScript(method: params.method)
        }
        return ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: UInt64(sent.count)),
            replayed: replayed,
            result: result,
            pending: nil
        )
    }

    func notify(_ params: ACPBrokerNotifyParams) async throws -> ACPBrokerSimpleOK {
        notified.append(params)
        return ACPBrokerSimpleOK(ok: true)
    }

    func respond(_ params: ACPBrokerRespondParams) async throws -> ACPBrokerSimpleOK {
        responded.append(params)
        return ACPBrokerSimpleOK(ok: true)
    }

    func ack(_ params: ACPBrokerAckParams) async throws -> ACPBrokerSimpleOK {
        acks.append(params)
        return ACPBrokerSimpleOK(ok: true)
    }

    func detach(_ params: ACPBrokerDetachParams) async throws -> ACPBrokerSimpleOK {
        detached.append(params)
        return ACPBrokerSimpleOK(ok: true)
    }

    func close(_ params: ACPBrokerCloseParams) async throws -> ACPBrokerSimpleOK {
        closed.append(params)
        return ACPBrokerSimpleOK(ok: true)
    }

    private func snapshot(params: ACPBrokerOpenParams) -> ACPBrokerSnapshot {
        ACPBrokerSnapshot(
            metadata: ACPBrokerMetadata(
                brokerId: params.brokerId,
                generation: ACPBrokerGeneration(rawValue: generation),
                alasSessionId: params.sessionId,
                adapterProgram: params.command,
                adapterArgs: params.args,
                cwd: params.cwd,
                envKeys: params.env.keys.sorted(),
                createdAtMillis: 10
            ),
            initializeResult: snapshotInitializeResult,
            remoteSessionResult: snapshotRemoteSessionResult,
            turnState: .idle,
            acknowledgedCursor: ACPBrokerEventCursor(rawValue: 0),
            journalTail: ACPBrokerEventCursor(rawValue: 0),
            pendingRequests: [],
            operations: []
        )
    }

    private func snapshot(
        brokerId: ACPBrokerID,
        acknowledgedCursor: ACPBrokerEventCursor
    ) -> ACPBrokerSnapshot {
        ACPBrokerSnapshot(
            metadata: ACPBrokerMetadata(
                brokerId: brokerId,
                generation: ACPBrokerGeneration(rawValue: generation),
                alasSessionId: "local-session-1",
                adapterProgram: "mock",
                adapterArgs: [],
                cwd: "/tmp/wt",
                envKeys: [],
                createdAtMillis: 10
            ),
            initializeResult: snapshotInitializeResult,
            remoteSessionResult: snapshotRemoteSessionResult,
            turnState: .idle,
            acknowledgedCursor: acknowledgedCursor,
            journalTail: ACPBrokerEventCursor(rawValue: 0),
            pendingRequests: [],
            operations: []
        )
    }
}

private actor ManagerBrokerServiceProxy: ACPBrokerServicing {
    let openGate = ManagerBrokerGate()
    let detachGate = ManagerBrokerGate()
    let closeGate = ManagerBrokerGate()
    let sendGate = ManagerBrokerGate()
    private let base = ManagerBrokerService()
    private let stallOpen: Bool
    private let stallDetach: Bool
    private let stallClose: Bool
    private let stallSendMethod: String?
    private var hasStalledSend = false
    private(set) var completedOpenCount = 0
    private(set) var opened: [ACPBrokerOpenParams] = []
    private(set) var closed: [ACPBrokerCloseParams] = []
    private(set) var detached: [ACPBrokerDetachParams] = []

    init(
        stallOpen: Bool = false,
        stallDetach: Bool = false,
        stallClose: Bool = false,
        stallSendMethod: String? = nil
    ) {
        self.stallOpen = stallOpen
        self.stallDetach = stallDetach
        self.stallClose = stallClose
        self.stallSendMethod = stallSendMethod
    }

    func open(_ params: ACPBrokerOpenParams) async throws -> ACPBrokerOpenResult {
        opened.append(params)
        if stallOpen { await openGate.wait() }
        let result = try await base.open(params)
        completedOpenCount += 1
        return result
    }

    func attach(_ params: ACPBrokerAttachParams) async throws -> ACPBrokerAttachResult {
        try await base.attach(params)
    }

    func send(_ params: ACPBrokerSendParams) async throws -> ACPBrokerSendResult {
        if !hasStalledSend, params.method == stallSendMethod {
            hasStalledSend = true
            await sendGate.wait()
        }
        return try await base.send(params)
    }

    func notify(_ params: ACPBrokerNotifyParams) async throws -> ACPBrokerSimpleOK {
        try await base.notify(params)
    }

    func respond(_ params: ACPBrokerRespondParams) async throws -> ACPBrokerSimpleOK {
        try await base.respond(params)
    }

    func ack(_ params: ACPBrokerAckParams) async throws -> ACPBrokerSimpleOK {
        try await base.ack(params)
    }

    func detach(_ params: ACPBrokerDetachParams) async throws -> ACPBrokerSimpleOK {
        detached.append(params)
        if stallDetach { await detachGate.wait() }
        return try await base.detach(params)
    }

    func close(_ params: ACPBrokerCloseParams) async throws -> ACPBrokerSimpleOK {
        closed.append(params)
        if stallClose { await closeGate.wait() }
        return try await base.close(params)
    }
}
