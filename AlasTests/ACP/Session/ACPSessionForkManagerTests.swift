import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP session fork manager")
struct ACPSessionForkManagerTests {
    @Test("merge queues context in a restored busy source before optionally archiving the fork",
          arguments: [false, true])
    func mergeIntoRestoredSource(archive: Bool) async throws {
        let (manager, store, source, fork) = try await mergeFixture()
        manager.closeSession(id: source.id)
        let restored = try #require(manager.placeholderSession(id: source.id))
        await manager.hydrateIfNeeded(id: source.id)
        restored.transcript.streamingState = .streaming
        let builtInSummary = MCPAttachmentSummary(statuses: [
            .init(id: BuiltInAlasMCP.statusId, name: "alas", transport: .stdio, disposition: .requested),
        ], configurationFingerprint: "test")
        if archive {
            restored.builtInMCPRegistration = .registered
            restored.mcpAttachmentSummary = builtInSummary
        }
        restored.replaceComposerDraft(ACPComposerDraft(segments: [.text("Unsent draft")]))
        #expect(await manager.enqueuePrompt(id: UUID(), text: "Existing task", into: source.id))

        let sourceID = try await manager.mergeForkBack(id: fork.id, archive: archive)
        let queue = try store.loadQueue(sessionId: sourceID)
        let item = try #require(queue.last)
        let text = item.blocks.compactMap { block -> String? in
            guard case .text(let text) = block else { return nil }
            return text
        }.joined()
        #expect(sourceID == source.id)
        #expect(text.contains("New finding"))
        #expect(text.contains("session_read(") == archive)
        #expect(!text.contains("Inherited answer"))
        #expect(item.delegatedSource?.sessionId == fork.id)
        #expect(restored.transcript.streamingState == .streaming)
        #expect(queue.first?.blocks == [.text("Existing task")])
        #expect(restored.composerDraft == ACPComposerDraft(segments: [.text("Unsent draft")]))
        #expect(try store.loadSession(id: fork.id)?.archived == archive)
        #expect(try store.loadMessages(sessionId: fork.id).count == 2)
        if !archive {
            restored.builtInMCPRegistration = .registered
            restored.mcpAttachmentSummary = builtInSummary
            fork.transcript.appendMessage(.systemNotice(id: UUID(), text: "Reconnected"))
            manager.persistTrailingMessages(fork, fromIndex: 2)
            _ = try await manager.mergeForkBack(id: fork.id, archive: false)
            #expect(try store.loadQueue(sessionId: source.id).count == 2)
        }
        await manager.releaseAllOwnedLeases()
    }

    @Test("merge reserves the fork against local prompts while source delivery is suspended",
          arguments: [false, true])
    func mergeBlocksLocalTurns(archive: Bool) async throws {
        let (manager, store, source, fork) = try await mergeFixture(attachFork: true)
        fork.contextRestoreWarning = .init(message: "Restore context", canSendTranscript: true)
        #expect(manager.runners[fork.id] != nil)
        #expect(fork.agentState == .ready)
        // The merge enters its reservation synchronously; its lease acquisition
        // then yields to this task before source delivery can complete.
        let admission = Task { @MainActor in
            #expect(fork.nextPromptWorkCount > 0)
            #expect(manager.sendTranscriptAsContext(sessionId: fork.id, agentName: "Codex") == false)
            #expect(fork.contextRecoveryStatus != .sendingTranscript)
            let accepted = manager.submit(sessionId: fork.id, text: "New turn", attachments: [], intent: .auto,
                                          onCompleted: { _ in })
            #expect(!accepted)
            #expect(!fork.queue.contains { $0.blocks == [.text("New turn")] })
            #expect(await manager.enqueuePrompt(id: UUID(), text: "Queued turn", into: fork.id) == false)
            #expect(await manager.enqueueDelegatedPrompt(text: "Child result", source: .init(sessionId: "child", messageId: "result"),
                                                         into: fork.id) == false)
        }
        #expect(try await manager.mergeForkBack(id: fork.id, archive: archive) == source.id)
        await admission.value
        #expect(try store.loadQueue(sessionId: source.id).count == 1)
        #expect(fork.queue.isEmpty)
        #expect(try store.loadSession(id: fork.id)?.archived == archive)
        if !archive {
            #expect(await manager.enqueuePrompt(id: UUID(), text: "After merge", into: fork.id))
        }
        await manager.releaseAllOwnedLeases()
    }

    @Test("fork takeover during source restoration prevents context delivery",
          arguments: [false, true])
    func mergeRejectsForkTakeover(archive: Bool) async throws {
        let (manager, store, source, fork) = try await mergeFixture()
        try #require(store.loadLease(sessionId: source.id) == nil)
        // Seize the fork at the source claim itself. A polling task can miss
        // that window and run after context has already been delivered.
        try store.db.exec("""
            CREATE TRIGGER seize_fork_on_source_claim AFTER INSERT ON session_leases
            WHEN NEW.session_id = '\(source.id)'
            BEGIN
                UPDATE session_leases
                SET owner_instance = 'other', lease_token = 'takeover', heartbeat_at = NEW.heartbeat_at
                WHERE session_id = '\(fork.id)';
            END
            """)
        await #expect(throws: ACPSessionForkMergeError.forkUnavailable) {
            try await manager.mergeForkBack(id: fork.id, archive: archive)
        }
        #expect(try store.loadLease(sessionId: fork.id)?.ownerInstance == "other")
        #expect(try store.loadQueue(sessionId: source.id).isEmpty)
        #expect(try store.loadSession(id: fork.id)?.archived == false)
        #expect(manager._heartbeatTasks[fork.id] == nil)
        #expect(manager._heartbeatTasks[source.id] == nil)
        await manager.releaseAllOwnedLeases()
    }

    @Test("rejected merges leave the fork unarchived and the source queue empty",
          arguments: ["busy", "empty", "archived", "missing", "leased", "forkLeased", "readUnavailable", "write"])
    func rejectedMergeKeepsFork(reason: String) async throws {
        let (manager, store, source, fork) = try await mergeFixture()
        let expected: ACPSessionForkMergeError
        switch reason {
        case "busy":
            fork.transcript.streamingState = .awaitingInput
            expected = .forkBusy
        case "empty":
            fork.transcript.messages.removeLast()
            expected = .noConversation
        case "archived":
            try store.setArchived(id: source.id, archived: true)
            expected = .sourceUnavailable
        case "missing":
            try store.deleteSession(id: source.id)
            expected = .sourceUnavailable
        case "forkLeased":
            // The mirror cache has not observed the other writer yet.
            #expect(!manager.isMirror(sessionId: fork.id))
            _ = try store.claimLease(sessionId: fork.id, instanceId: "other", pid: Int64(getpid()),
                                     now: Int64(Date().timeIntervalSince1970), staleAfter: 15)
            expected = .forkUnavailable
        case "readUnavailable":
            fork.transcript.appendMessage(.agent(id: UUID(), StreamingText(String(repeating: "Long finding", count: 1_000))))
            expected = .sourceReadUnavailable
        case "write":
            try store.db.exec("""
                CREATE TRIGGER reject_merge_queue BEFORE INSERT ON session_queue
                BEGIN SELECT RAISE(ABORT, 'queue write rejected'); END
                """)
            expected = .deliveryFailed
        default:
            _ = try store.claimLease(sessionId: source.id, instanceId: "other", pid: Int64(getpid()),
                                     now: Int64(Date().timeIntervalSince1970), staleAfter: 15)
            expected = .sourceReadOnly
        }
        await #expect(throws: expected) {
            try await manager.mergeForkBack(id: fork.id, archive: reason != "forkLeased")
        }
        #expect(try store.loadSession(id: fork.id)?.archived == false)
        #expect(try store.loadQueue(sessionId: source.id).isEmpty)
        #expect(source.queue.isEmpty)
        await manager.releaseAllOwnedLeases()
    }

    private func mergeFixture(attachFork: Bool = false) async throws -> (ACPSessionManager, ACPSessionStore, ACPSession, ACPSession) {
        let store = try ACPSessionStore(path: temporaryPath())
        let client = ACPMockClient()
        client.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(protocolVersion: 1, agentCapabilities: nil, authMethods: []))
        }
        client.script(method: "session/new") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(sessionId: "remote-fork", availableModels: [],
                                                        availableModes: [], currentModel: nil, currentMode: nil,
                                                        promptSuggestions: []))
        }
        client.script(method: "session/prompt") { _ in Data(#"{"stopReason":"end_turn"}"#.utf8) }
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store,
                                        setupEvaluator: { _ in .ready },
                                        connectionFactory: { _, _, _ in ACPConnection(client: client) })
        let source = manager.createSession(agentId: "claude")
        source.transcript.appendMessage(.agent(id: UUID(), StreamingText("Inherited answer")))
        manager.persistTrailingMessages(source, fromIndex: 0)
        await manager.flushAllPersistence()
        let boundary = try #require(source.transcript.messages.first)
        let fork = try await manager.createFork(
            sourceSessionID: source.id, boundary: .init(stableID: boundary.stableId, kind: .agent),
            targetAgentID: "codex", autoRunDefault: false
        )
        fork.transcript.appendMessage(.agent(id: UUID(), StreamingText("New finding")))
        manager.persistTrailingMessages(fork, fromIndex: 1)
        await manager.flushAllPersistence()
        if attachFork { await manager.attach(to: fork.id, freshlyCreated: true) }
        return (manager, store, source, fork)
    }

    @Test("createFork copies through selected boundary and leaves source unchanged")
    func createsLocalFork() async throws {
        let path = temporaryPath()
        let store = try ACPSessionStore(path: path)
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let source = manager.createSession(agentId: "claude")
        await manager.flushPersistence()
        let user: ACPMessage = .user(id: UUID(), text: "one", attachments: [])
        let agent: ACPMessage = .agent(id: UUID(), StreamingText("two"))
        let later: ACPMessage = .user(id: UUID(), text: "three", attachments: [])
        for message in [user, agent, later] {
            let index = source.transcript.messages.count
            source.transcript.appendMessage(message)
            try store.appendMessage(
                sessionId: source.id,
                id: "msg-\(source.id)-\(index)",
                kind: message.kind,
                seq: Int64(index),
                payload: try ACPMessageCodec.encode(message),
                createdAt: Int64(index)
            )
        }
        let sourceBefore = try store.loadMessages(sessionId: source.id)

        let target = try await manager.createFork(
            sourceSessionID: source.id,
            boundary: .init(stableID: agent.stableId, kind: .agent),
            targetAgentID: "codex",
            autoRunDefault: false
        )

        #expect(target.agentId == "codex")
        #expect(target.title == "New session (fork)")
        #expect(target.transcript.messages.count == 2)
        #expect(target.forkRecord?.mechanism == .transcriptTransfer)
        #expect(try store.loadMessages(sessionId: source.id) == sourceBefore)

        let targetID = target.id
        await manager.releaseAllOwnedLeases()
        let restoredStore = try ACPSessionStore(path: path)
        let restoredManager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: restoredStore
        )
        let restored = try #require(restoredManager.placeholderSession(id: targetID))
        await restoredManager.hydrateIfNeeded(id: targetID)
        await restoredManager.awaitBackfill(id: targetID)

        #expect(restored.forkRecord?.mechanism == .transcriptTransfer)
        #expect(restored.forkRecord?.contextDeliveryPending == true)
        #expect(restored.transcript.messages.count == 2)
    }

    @Test("pending transcript context prevents a native child fork")
    func pendingTranscriptContextForcesTranscriptTransfer() async throws {
        let store = try ACPSessionStore(path: temporaryPath())
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let root = manager.createSession(agentId: "claude")
        await manager.flushPersistence()
        let message: ACPMessage = .agent(id: UUID(), StreamingText("Root answer"))
        root.transcript.appendMessage(message)
        try store.appendMessage(
            sessionId: root.id,
            id: "msg-\(root.id)-0",
            kind: message.kind,
            seq: 0,
            payload: try ACPMessageCodec.encode(message),
            createdAt: 0
        )

        let pendingSource = try await manager.createFork(
            sourceSessionID: root.id,
            boundary: .init(stableID: message.stableId, kind: .agent),
            targetAgentID: "codex",
            autoRunDefault: false
        )
        pendingSource.remoteSessionId = "remote-pending-source"
        pendingSource.sessionCapabilities = .init(fork: .init())
        let pendingBoundary = try #require(pendingSource.transcript.messages.last)

        let target = try await manager.createFork(
            sourceSessionID: pendingSource.id,
            boundary: .init(stableID: pendingBoundary.stableId, kind: .agent),
            targetAgentID: "codex",
            autoRunDefault: false
        )

        #expect(pendingSource.forkRecord?.mechanism == .transcriptTransfer)
        #expect(pendingSource.forkRecord?.contextDeliveryPending == true)
        #expect(target.forkRecord?.phase == .ready)
        #expect(target.forkRecord?.mechanism == .transcriptTransfer)
        #expect(target.forkRecord?.contextDeliveryPending == true)
    }

    @Test("createFork releases a lease acquired only for a successful snapshot")
    func successfulSnapshotReleasesTemporaryLease() async throws {
        let store = try ACPSessionStore(path: temporaryPath())
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            instanceId: "forker"
        )
        let source = manager.createSession(agentId: "claude")
        await manager.flushPersistence()
        let message: ACPMessage = .agent(id: UUID(), StreamingText("Answer"))
        source.transcript.appendMessage(message)
        try store.appendMessage(
            sessionId: source.id,
            id: "msg-\(source.id)-0",
            kind: message.kind,
            seq: 0,
            payload: try ACPMessageCodec.encode(message),
            createdAt: 0
        )

        _ = try await manager.createFork(
            sourceSessionID: source.id,
            boundary: .init(stableID: message.stableId, kind: .agent),
            targetAgentID: "codex",
            autoRunDefault: false
        )

        #expect(try store.loadLease(sessionId: source.id) == nil)
        #expect(!manager._ownedLeases.contains(source.id))
    }

    @Test("createFork releases a temporary snapshot lease after an error")
    func failedSnapshotReleasesTemporaryLease() async throws {
        let store = try ACPSessionStore(path: temporaryPath())
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            instanceId: "forker"
        )
        let source = manager.createSession(agentId: "claude")
        await manager.flushPersistence()

        await #expect(throws: ACPSessionForkSnapshotError.self) {
            try await manager.createFork(
                sourceSessionID: source.id,
                boundary: .init(stableID: "missing", kind: .agent),
                targetAgentID: "codex",
                autoRunDefault: false
            )
        }

        #expect(try store.loadLease(sessionId: source.id) == nil)
        #expect(!manager._ownedLeases.contains(source.id))
    }

    @Test("createFork preserves a source lease that was already owned")
    func successfulSnapshotPreservesExistingLease() async throws {
        let store = try ACPSessionStore(path: temporaryPath())
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            instanceId: "forker"
        )
        let source = manager.createSession(agentId: "claude")
        await manager.flushPersistence()
        let message: ACPMessage = .agent(id: UUID(), StreamingText("Answer"))
        source.transcript.appendMessage(message)
        try store.appendMessage(
            sessionId: source.id,
            id: "msg-\(source.id)-0",
            kind: message.kind,
            seq: 0,
            payload: try ACPMessageCodec.encode(message),
            createdAt: 0
        )
        #expect(await manager.acquireWriterLease(sessionId: source.id))

        _ = try await manager.createFork(
            sourceSessionID: source.id,
            boundary: .init(stableID: message.stableId, kind: .agent),
            targetAgentID: "codex",
            autoRunDefault: false
        )

        #expect(try store.loadLease(sessionId: source.id)?.ownerInstance == "forker")
        #expect(manager._ownedLeases.contains(source.id))
        await manager.releaseWriterLease(sessionId: source.id)
    }

    @Test("createFork rejects a cached source lease lost to takeover")
    func staleOwnedLeaseIsRejected() async throws {
        let store = try ACPSessionStore(path: temporaryPath())
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            instanceId: "forker"
        )
        let source = manager.createSession(agentId: "claude")
        await manager.flushPersistence()
        let message: ACPMessage = .agent(id: UUID(), StreamingText("Answer"))
        source.transcript.appendMessage(message)
        try store.appendMessage(
            sessionId: source.id,
            id: "msg-\(source.id)-0",
            kind: message.kind,
            seq: 0,
            payload: try ACPMessageCodec.encode(message),
            createdAt: 0
        )
        #expect(await manager.acquireWriterLease(sessionId: source.id))
        try store.seizeLease(
            sessionId: source.id,
            instanceId: "other-instance",
            pid: Int64(getpid()),
            now: Int64(Date().timeIntervalSince1970)
        )

        await #expect(throws: ACPSessionForkCreationError.sourceReadOnly) {
            try await manager.createFork(
                sourceSessionID: source.id,
                boundary: .init(stableID: message.stableId, kind: .agent),
                targetAgentID: "codex",
                autoRunDefault: false
            )
        }

        #expect(try store.loadLease(sessionId: source.id)?.ownerInstance == "other-instance")
        #expect(!manager._ownedLeases.contains(source.id))
    }

    @Test("side-question fork of a streaming parent stays hidden and skips its unpersisted tail")
    func sideQuestionForkOfStreamingParent() async throws {
        let store = try ACPSessionStore(path: temporaryPath())
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let parent = manager.createSession(agentId: "claude", autoRunDefault: true)
        await manager.flushPersistence()
        let persisted: [ACPMessage] = [
            .user(id: UUID(), text: "one", attachments: []),
            .agent(id: UUID(), StreamingText("two")),
            .user(id: UUID(), text: "three", attachments: []),
        ]
        for (index, message) in persisted.enumerated() {
            parent.transcript.appendMessage(message)
            try store.appendMessage(
                sessionId: parent.id,
                id: "msg-\(parent.id)-\(index)",
                kind: message.kind,
                seq: Int64(index),
                payload: try ACPMessageCodec.encode(message),
                createdAt: Int64(index)
            )
        }
        parent.transcript.appendMessage(.agent(id: UUID(), StreamingText("partial")))
        parent.transcript.streamingState = .streaming
        let boundary = try #require(ACPSideQuestionBoundaryPolicy.boundary(
            messages: parent.transcript.messages,
            isTurnActive: true
        ))

        await #expect(throws: ACPSessionForkSnapshotError.transcriptMismatch) {
            try await manager.createFork(
                sourceSessionID: parent.id, boundary: boundary,
                targetAgentID: "claude", autoRunDefault: true
            )
        }
        let side = try await manager.createFork(
            sourceSessionID: parent.id, boundary: boundary,
            targetAgentID: "claude", autoRunDefault: true,
            ephemeralTitle: "/btw: why?"
        )

        #expect(side.transcript.messages.count == 2)
        #expect(side.autoRunEnabled == false)
        #expect(side.forkRecord?.via == .btw)
        // Attaching persists the session, which must not list it either.
        manager.persist(side)
        #expect(!manager.recent.contains { $0.id == side.id })
        #expect(try store.loadSession(id: side.id)?.ephemeralParentId == parent.id)
        #expect(try !store.recentSessions().contains { $0.id == side.id })
    }

    // Can't leave a self-approving mode.
    private nonisolated static let bypassOnly = #"""
        {"sessionId":"remote","modes":{"currentModeId":"bypass","availableModes":[
          {"id":"default","name":"Manual","_meta":{"kind":"standard"}},
          {"id":"bypass","name":"Bypass","_meta":{"kind":"full_access"}}]}}
        """#
    private nonisolated static let noModes = #"{"sessionId":"remote"}"#

    @Test(
        "a side question needs a read-only mode only on agents whose read-only mode holds",
        arguments: [
            ("claude", bypassOnly, false),
            ("claude", noModes, false),
            ("opencode", bypassOnly, true),
            ("opencode", noModes, true),
        ]
    )
    func sideQuestionReadOnlyMode(agentId: String, sessionNewResponse: String, sends: Bool) async throws {
        struct SetModeRejected: Error {}
        let client = ACPMockClient()
        client.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: .init(sessionCapabilities: .init(resume: nil, close: nil)),
                authMethods: []
            ))
        }
        client.script(method: "session/new") { _ in Data(sessionNewResponse.utf8) }
        client.script(method: "session/set_mode") { _ in throw SetModeRejected() }
        let store = try ACPSessionStore(path: temporaryPath())
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let parent = manager.createSession(agentId: agentId)

        let side = try? await manager.startSideQuestion(parentID: parent.id, question: "why?")

        #expect((side != nil) == sends)
        #expect(manager.sideQuestions[parent.id]?.isSubmitted == sends)
        if !sends {
            #expect(!client.sent.contains { $0.method == "session/prompt" })
            #expect(manager.sideQuestions[parent.id]?.sessionID == nil)
            #expect(manager.sideQuestions[parent.id]?.error == ACPSideQuestionError.unsafeMode.errorDescription)
        }
        if let side { await manager.detach(sessionId: side.id) }
    }

    @Test("streaming agent is ineligible while earlier messages remain eligible")
    func messageEligibility() {
        let session = ACPSession(
            id: "s", agentId: "claude", worktreeId: "wt",
            title: "Session", hydrationState: .ready
        )
        session.transcript.appendMessage(.user(id: UUID(), text: "old", attachments: []))
        session.transcript.appendMessage(.agent(id: UUID(), StreamingText("old answer")))
        session.transcript.appendMessage(.user(id: UUID(), text: "new", attachments: []))
        session.transcript.appendMessage(.agent(id: UUID(), StreamingText("partial")))
        session.transcript.streamingState = .streaming

        #expect(session.canForkMessage(at: 0))
        #expect(session.canForkMessage(at: 1))
        #expect(session.canForkMessage(at: 2))
        #expect(!session.canForkMessage(at: 3))
    }

    @Test("createFork seeds the target's suggestions only from a same-agent non-empty source")
    func forkSuggestionSeeding() async throws {
        // Needs a live attach to seed the source's list; drive it through the
        // runner's own persist path instead of poking store state directly —
        // that path is covered by the runner, so here set the stored list the
        // way attach/hydration leaves it.
        let store = try ACPSessionStore(path: temporaryPath())
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            instanceId: "forker"
        )
        let suggestions = [
            ACPPromptSuggestion(command: "/review", description: "Review"),
        ]
        let source = manager.createSession(agentId: "claude")
        await manager.flushPersistence()
        try store.setPromptSuggestions(sessionId: source.id, suggestions: suggestions)
        source.promptSuggestions = suggestions

        let user: ACPMessage = .user(id: UUID(), text: "one", attachments: [])
        let agent: ACPMessage = .agent(id: UUID(), StreamingText("two"))
        for message in [user, agent] {
            let index = source.transcript.messages.count
            source.transcript.appendMessage(message)
            try store.appendMessage(
                sessionId: source.id,
                id: "msg-\(source.id)-\(index)",
                kind: message.kind,
                seq: Int64(index),
                payload: try ACPMessageCodec.encode(message),
                createdAt: Int64(index)
            )
        }

        let sameAgent = try await manager.createFork(
            sourceSessionID: source.id,
            boundary: .init(stableID: agent.stableId, kind: .agent),
            targetAgentID: "claude",
            autoRunDefault: false
        )
        let crossAgent = try await manager.createFork(
            sourceSessionID: source.id,
            boundary: .init(stableID: agent.stableId, kind: .agent),
            targetAgentID: "codex",
            autoRunDefault: false
        )

        #expect(sameAgent.promptSuggestions == suggestions)
        #expect(crossAgent.promptSuggestions.isEmpty)

        let sameAgentID = sameAgent.id
        let crossAgentID = crossAgent.id
        await manager.flushAllPersistence()
        let restoredStore = try ACPSessionStore(path: store.path)
        #expect(try restoredStore.loadSession(id: sameAgentID)?.promptSuggestions == suggestions)
        #expect(try restoredStore.loadSession(id: crossAgentID)?.promptSuggestions == nil)
    }

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-fork-manager-\(UUID()).sqlite").path
    }
}
