import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSessionManager")
struct ACPSessionManagerTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    private actor AsyncGate {
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func enterAndWait() async {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { continuation in
                entryWaiters.append(continuation)
            }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private func scriptInitialize(_ client: ACPMockClient) {
        client.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: nil,
                authMethods: []
            ))
        }
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

    @Test("ordinary stable prompt is persisted only once")
    func ordinaryStablePromptIsPersistedOnlyOnce() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-stable-prompt-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        _ = manager.createSession(id: "session", agentId: "codex", autoRunDefault: false)
        let promptID = UUID(uuidString: "C4A54F3E-C70B-4EB6-B20D-FC51E22D5C22")!

        #expect(await manager.enqueuePrompt(
            id: promptID,
            text: "Investigate.",
            into: "session"
        ))
        #expect(await manager.enqueuePrompt(
            id: promptID,
            text: "Investigate.",
            into: "session"
        ))

        let session = try #require(manager.liveSession(for: "session"))
        #expect(session.queue.count == 1)
        #expect(session.queue.first?.id == promptID)
        #expect(session.queue.first?.delegatedSource == ACPDelegatedPromptSource(
            sessionId: "mission:session",
            messageId: promptID.uuidString
        ))
        #expect(try store.loadQueue(sessionId: "session").map(\.id) == [promptID])
    }

    @Test("mission prompts stay ahead of scheduled prompts")
    func missionPromptStaysAheadOfScheduledPrompt() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-mission-schedule-order-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = manager.createSession(id: "session", agentId: "codex", autoRunDefault: false)
        session.enqueueScheduled(blocks: [.text("later")], scheduledAt: .distantFuture)
        let promptID = UUID()

        #expect(await manager.enqueuePrompt(id: promptID, text: "now", into: session.id))
        #expect(session.queue.map(\.blocks) == [[.text("now")], [.text("later")]])
        #expect(session.queue.map(\.scheduledAt) == [nil, .distantFuture])
    }

    @Test("scheduled prompt settlement waits for the matching prompt and idle turn")
    func scheduledPromptSettlementTracksItsQueueIDAndTurnEnd() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-scheduled-settlement-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = manager.createSession(id: "session", agentId: "codex", autoRunDefault: false)
        let promptID = UUID()
        session.queue = [QueuedPrompt(id: promptID, blocks: [.text("scheduled task")])]
        session.mcpAttachmentSummary = MCPAttachmentSummary(
            statuses: [.init(
                id: BuiltInAlasMCP.statusId,
                name: "Alas",
                transport: .stdio,
                disposition: .requested
            )],
            configurationFingerprint: "test"
        )
        session.builtInMCPRegistration = .registered
        let deadline = AsyncGate()
        let waiter = Task {
            await manager.waitForScheduledPrompt(
                for: session.id,
                promptID: promptID,
                timeout: .seconds(4),
                deadlineWaiter: { _ in await deadline.enterAndWait() }
            )
        }

        session.queue[0].status = .sending
        await deadline.waitUntilEntered()
        session.queue.removeAll()
        session.transcript.streamingState = .sending
        await Task.yield()
        session.transcript.streamingState = .idle
        let result = await waiter.value
        guard case .settled = result else {
            Issue.record("Expected the exact scheduled prompt and idle turn to settle, got \(result).")
            await deadline.release()
            return
        }
        await deadline.release()
    }

    @Test("removing a scheduled prompt before dispatch fails settlement")
    func scheduledPromptRemovalBeforeDispatchFails() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-scheduled-removed-before-dispatch-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = manager.createSession(id: "session", agentId: "codex", autoRunDefault: false)
        let promptID = UUID()
        session.mcpAttachmentSummary = MCPAttachmentSummary(
            statuses: [.init(
                id: BuiltInAlasMCP.statusId,
                name: "Alas",
                transport: .stdio,
                disposition: .requested
            )],
            configurationFingerprint: "test"
        )
        session.builtInMCPRegistration = .registered
        let waiter = Task {
            await manager.waitForScheduledPrompt(
                for: session.id,
                promptID: promptID,
                timeout: .seconds(4)
            )
        }

        await Task.yield()
        session.queue = [QueuedPrompt(id: promptID, blocks: [.text("scheduled task")])]
        #expect(session.removeFromQueue(id: promptID))

        let result = await withTaskGroup(
            of: ScheduledPromptSettlement?.self,
            returning: ScheduledPromptSettlement?.self
        ) { group in
            group.addTask { await waiter.value }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(250))
                return nil
            }
            let first = await group.next() ?? nil
            if first == nil {
                waiter.cancel()
            }
            group.cancelAll()
            return first
        }
        #expect(result == .failed("The scheduled ACP prompt was removed before dispatch."))
    }


    @Test("scheduled settlement distinguishes unrelated queued prompts")
    func scheduledPromptSettlementTracksUnrelatedQueuedPrompts() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-scheduled-unrelated-settlement-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = manager.createSession(id: "session", agentId: "codex", autoRunDefault: false)
        let promptID = UUID()
        let unrelatedPromptID = UUID()
        session.queue = [QueuedPrompt(id: promptID, blocks: [.text("scheduled task")])]
        session.mcpAttachmentSummary = MCPAttachmentSummary(
            statuses: [.init(
                id: BuiltInAlasMCP.statusId,
                name: "Alas",
                transport: .stdio,
                disposition: .requested
            )],
            configurationFingerprint: "test"
        )
        session.builtInMCPRegistration = .registered
        let deadline = AsyncGate()
        let waiter = Task {
            await manager.waitForScheduledPrompt(
                for: session.id,
                promptID: promptID,
                timeout: .seconds(4),
                deadlineWaiter: { _ in await deadline.enterAndWait() }
            )
        }

        session.queue[0].status = .sending
        await deadline.waitUntilEntered()
        session.queue.append(QueuedPrompt(id: unrelatedPromptID, blocks: [.text("follow-up")]))
        session.queue.removeAll { $0.id == promptID }
        session.queue[0].status = .sending
        session.transcript.streamingState = .sending
        session.queue.removeAll()
        session.transcript.streamingState = .idle

        let result = await waiter.value
        guard case .settledWithUnrelatedPrompt = result else {
            Issue.record("Expected unrelated queued work to remain distinguishable, got \(result).")
            await deadline.release()
            return
        }
        await deadline.release()
    }

    @Test("scheduled prompt timeout begins at dispatch and is cancellable")
    func scheduledPromptTimeoutUsesAnInjectedDeadline() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-scheduled-timeout-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = manager.createSession(id: "session", agentId: "codex", autoRunDefault: false)
        let promptID = UUID()
        session.queue = [QueuedPrompt(id: promptID, blocks: [.text("scheduled task")])]
        session.mcpAttachmentSummary = MCPAttachmentSummary(
            statuses: [.init(
                id: BuiltInAlasMCP.statusId,
                name: "Alas",
                transport: .stdio,
                disposition: .requested
            )],
            configurationFingerprint: "test"
        )
        session.builtInMCPRegistration = .registered
        let deadline = AsyncGate()
        let waiter = Task {
            await manager.waitForScheduledPrompt(
                for: session.id,
                promptID: promptID,
                timeout: .seconds(4),
                deadlineWaiter: { _ in await deadline.enterAndWait() }
            )
        }

        session.queue[0].status = .sending
        await deadline.waitUntilEntered()
        await deadline.release()
        #expect(await waiter.value == .timedOut)
    }

    @Test("remote queue clear notifies queue change")
    func remoteQueueClearNotifiesQueueChange() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-remote-queue-change-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        var changedSessions: [ACPSession.ID] = []
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            onQueueChanged: { sessionId, _ in changedSessions.append(sessionId) }
        )
        let session = manager.createSession(id: "session", agentId: "codex", autoRunDefault: false)
        session.enqueueScheduled(blocks: [.text("later")], scheduledAt: .distantFuture)

        #expect(await manager.acquireWriterLease(sessionId: session.id))
        await manager.queueClear(for: session.id)

        #expect(changedSessions == [session.id])
        #expect(session.queue.isEmpty)
    }

    @Test("remote queue remove ignores sending items without notifying")
    func remoteQueueRemoveSendingItemDoesNotNotify() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-remote-queue-remove-sending-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        var changedSessions: [ACPSession.ID] = []
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            onQueueChanged: { sessionId, _ in changedSessions.append(sessionId) }
        )
        let session = manager.createSession(id: "session", agentId: "codex", autoRunDefault: false)
        let itemId = UUID()
        session.queue.append(QueuedPrompt(id: itemId, blocks: [.text("sending")], status: .sending))

        #expect(await manager.acquireWriterLease(sessionId: session.id))
        await manager.queueRemove(for: session.id, itemId: itemId)

        #expect(changedSessions.isEmpty)
        #expect(session.queue.map(\.id) == [itemId])
    }

    @Test("remote queue retry ignores stale retry requests")
    func remoteQueueRetryIgnoresStaleRequests() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-remote-queue-retry-stale-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        var changedSessions: [ACPSession.ID] = []
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            onQueueChanged: { sessionId, _ in changedSessions.append(sessionId) }
        )
        let session = manager.createSession(id: "session", agentId: "codex", autoRunDefault: false)
        let sendingId = UUID()
        let pendingId = UUID()
        session.queue.append(QueuedPrompt(id: sendingId, blocks: [.text("sending")], status: .sending))
        session.queue.append(QueuedPrompt(id: pendingId, blocks: [.text("pending")], status: .pending))

        #expect(await manager.acquireWriterLease(sessionId: session.id))
        await manager.queueRetry(for: session.id, itemId: sendingId)
        await manager.queueRetry(for: session.id, itemId: pendingId)

        #expect(changedSessions.isEmpty)
        #expect(session.queue.map(\.id) == [sendingId, pendingId])
    }

    @Test("delegated prompt already recorded in the transcript is not requeued")
    func delegatedPromptRecordedInTranscriptIsNotRequeued() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-delegated-dedupe-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = manager.createSession(agentId: "claude")
        let source = ACPDelegatedPromptSource(sessionId: "parent", messageId: "message")
        session.transcript.messages.append(.user(
            id: UUID(),
            messageId: nil,
            text: "already sent",
            attachments: [],
            delegatedSource: source
        ))

        #expect(await manager.enqueueDelegatedPrompt(
            text: "already sent",
            source: source,
            into: session.id
        ))
        #expect(session.queue.isEmpty)
    }

    @Test("creating a session inserts it and persists the row")
    func create() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        let s = mgr.createSession(agentId: "claude")
        #expect(mgr.sessions[s.id] != nil)
        #expect(!s.restoredFromPersistence)
        await mgr.flushPersistence()
        let row = try store.loadSession(id: s.id)
        #expect(row?.agentId == "claude")
    }

    @Test("createSession seeds autoRun from the default when true")
    func createSessionSeedsAutoRunTrue() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-autorun-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        let s = mgr.createSession(agentId: "claude", autoRunDefault: true)
        #expect(s.autoRunEnabled == true)
        await mgr.flushPersistence()
        let row = try store.loadSession(id: s.id)
        #expect(row?.autoRun == true)
    }

    @Test("noteMessageActivity bumps the cached row's updatedAt without a store round-trip")
    func noteMessageActivityBumpsCachedRow() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-activity-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        let s = mgr.createSession(agentId: "claude")
        let created = mgr.sessionRows.first(where: { $0.id == s.id })?.updatedAt

        mgr.noteMessageActivity(sessionId: s.id, at: (created ?? 0) + 100)

        #expect(mgr.sessionRows.first(where: { $0.id == s.id })?.updatedAt == (created ?? 0) + 100)
    }

    @Test("noteMessageActivity never moves the cached updatedAt backward")
    func noteMessageActivityNeverRegresses() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-activity-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        let s = mgr.createSession(agentId: "claude")
        let created = mgr.sessionRows.first(where: { $0.id == s.id })?.updatedAt

        mgr.noteMessageActivity(sessionId: s.id, at: (created ?? 0) - 100)

        #expect(mgr.sessionRows.first(where: { $0.id == s.id })?.updatedAt == created)
    }

    @Test("createSession defaults autoRun to false")
    func createSessionDefaultsAutoRunFalse() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-autorun-off-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        let s = mgr.createSession(agentId: "claude")
        #expect(s.autoRunEnabled == false)
        await mgr.flushPersistence()
        let row = try store.loadSession(id: s.id)
        #expect(row?.autoRun == false)
    }

    @Test("placeholderSession marks store-backed sessions as restored from persistence")
    func placeholderSessionMarksRestoredFromPersistence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-restored-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "stored",
            agentId: "claude",
            title: "Stored",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 0,
            updatedAt: 0,
            lastOpenedAt: 0,
            archived: false
        ))
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)

        let session = try #require(mgr.placeholderSession(id: "stored"))
        let cached = try #require(mgr.placeholderSession(id: "stored"))

        #expect(session.restoredFromPersistence)
        #expect(cached === session)
        #expect(cached.restoredFromPersistence)
    }

    @Test("attach freshness uses persisted origin and remote id")
    func attachFreshnessUsesPersistedOriginAndRemoteId() {
        #expect(ACPSessionAttachFreshness.isFresh(
            restoredFromPersistence: false,
            remoteSessionId: nil
        ))
        #expect(!ACPSessionAttachFreshness.isFresh(
            restoredFromPersistence: false,
            remoteSessionId: "remote"
        ))
        #expect(!ACPSessionAttachFreshness.isFresh(
            restoredFromPersistence: true,
            remoteSessionId: nil
        ))
        #expect(!ACPSessionAttachFreshness.isFresh(
            restoredFromPersistence: true,
            remoteSessionId: "remote"
        ))
    }

    @Test("openSession restores persisted composer draft")
    func openSessionRestoresComposerDraft() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-draft-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let draft = ACPComposerDraft(segments: [.text("unsent prompt")])
        try store.upsertComposerDraft(sessionId: "s", draft: draft, updatedAt: 123)

        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = try #require(mgr.placeholderSession(id: "s"))
        await mgr.hydrateIfNeeded(id: "s")
        #expect(session.composerDraft == draft)
    }

    @Test("persistComposerDraft stores non-empty drafts and clears empty drafts")
    func persistComposerDraftStoresAndClears() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-draft-clear-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        let draft = ACPComposerDraft(segments: [.text("keep me")])

        mgr.persistComposerDraft(draft, for: session)
        #expect(session.composerDraft == draft)
        #expect(session.composerDraftRevision == 1)
        mgr.flushPendingDraftWrites()
        await mgr.flushPersistence()
        #expect(try store.loadComposerDraft(sessionId: session.id) == draft)

        mgr.persistComposerDraft(.empty, for: session)
        #expect(session.composerDraft == .empty)
        #expect(session.composerDraftRevision == 2)
        mgr.flushPendingDraftWrites()
        await mgr.flushPersistence()
        #expect(try store.loadComposerDraft(sessionId: session.id) == nil)
    }

    @Test("persisting composer drafts does not publish the whole session")
    func persistingComposerDraftDoesNotPublishWholeSession() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-draft-observation-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        let sessionStorageLabels = Set(Mirror(reflecting: session).children.compactMap(\.label))
        var sessionPublishCount = 0
        var composerPublishCount = 0
        let sessionCancellable = session.objectWillChange.sink { _ in
            sessionPublishCount += 1
        }
        let composerCancellable = session.composer.objectWillChange.sink { _ in
            composerPublishCount += 1
        }

        withExtendedLifetime((sessionCancellable, composerCancellable)) {
            mgr.persistComposerDraft(ACPComposerDraft(segments: [.text("typing")]), for: session)
        }

        #expect(!sessionStorageLabels.contains("_composerDraft"))
        #expect(!sessionStorageLabels.contains("_composerDraftRevision"))
        #expect(sessionPublishCount == 0)
        #expect(composerPublishCount == 1)
    }

    @Test("clearComposerDraft removes draft from memory and store")
    func clearComposerDraft() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-draft-clear-explicit-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        mgr.persistComposerDraft(ACPComposerDraft(segments: [.text("sent")]), for: session)

        mgr.clearComposerDraft(for: session)
        await mgr.flushPersistence()

        #expect(session.composerDraft == .empty)
        #expect(try store.loadComposerDraft(sessionId: session.id) == nil)
    }

    @Test("suspendComposerDraftForSubmission empties memory and durably saves SQLite")
    func suspendComposerDraftForSubmissionFlushesAndClears() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-draft-suspend-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        await mgr.flushPersistence()
        let existingMessage: ACPMessage = .user(id: UUID(), text: "old", attachments: [])
        session.transcript.messages.append(existingMessage)
        try store.appendMessage(
            sessionId: session.id,
            id: "m0",
            kind: existingMessage.kind,
            seq: 0,
            payload: try ACPMessageCodec.encode(existingMessage),
            createdAt: 1
        )
        let submitted = ACPComposerDraft(segments: [.text("sent")])

        // Schedule a debounced write but DO NOT flush — simulates the
        // common path where the user types and immediately submits before
        // the 300ms timer fires.
        mgr.persistComposerDraft(submitted, for: session)

        let suspendedRevision = mgr.suspendComposerDraftForSubmission(submitted, for: session)
        await mgr.flushPersistence()
        #expect(session.composerDraft == .empty)
        #expect(session.composerDraftRevision == suspendedRevision)
        // The explicit persistence barrier makes the recovery row durable.
        #expect(try store.loadComposerDraft(sessionId: session.id) == submitted)
        #expect(try store.loadComposerDraftRecord(sessionId: session.id)?.submittedAfterSeq == 0)
    }

    @Test("purgeSuspendedComposerDraft deletes SQLite only when revision matches")
    func purgeSuspendedComposerDraftRespectsRevision() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-draft-purge-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        let submitted = ACPComposerDraft(segments: [.text("sent")])

        mgr.persistComposerDraft(submitted, for: session)
        let suspendedRevision = mgr.suspendComposerDraftForSubmission(submitted, for: session)

        // Success path with no intervening typing: SQLite row is purged.
        mgr.purgeSuspendedComposerDraft(for: session, suspendedRevision: suspendedRevision)
        await mgr.flushPersistence()
        #expect(try store.loadComposerDraft(sessionId: session.id) == nil)

        // Re-suspend, then simulate the user typing while the prompt is
        // in flight: the new draft must survive a late completion's purge.
        mgr.persistComposerDraft(submitted, for: session)
        let suspendedAgain = mgr.suspendComposerDraftForSubmission(submitted, for: session)
        let newer = ACPComposerDraft(segments: [.text("newer")])
        mgr.persistComposerDraft(newer, for: session)
        mgr.purgeSuspendedComposerDraft(for: session, suspendedRevision: suspendedAgain)
        #expect(session.composerDraft == newer)
        mgr.flushPendingDraftWrites()
        await mgr.flushPersistence()
        #expect(try store.loadComposerDraft(sessionId: session.id) == newer)
    }

    @Test("reinstateSuspendedComposerDraft restores memory only when revision matches")
    func reinstateSuspendedComposerDraftRespectsRevision() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-draft-reinstate-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        let submitted = ACPComposerDraft(segments: [.text("sent")])

        // Failure with no intervening typing: in-memory draft is restored
        // so a still-mounted composer (or next re-mount) shows the text.
        mgr.persistComposerDraft(submitted, for: session)
        let suspendedRevision = mgr.suspendComposerDraftForSubmission(submitted, for: session)
        mgr.reinstateSuspendedComposerDraft(submitted, for: session, suspendedRevision: suspendedRevision)
        #expect(session.composerDraft == submitted)

        // Re-suspend, then simulate the user typing a new draft while the
        // prompt is in flight — a late failure must not stomp it.
        let suspendedAgain = mgr.suspendComposerDraftForSubmission(submitted, for: session)
        let newer = ACPComposerDraft(segments: [.text("newer")])
        mgr.persistComposerDraft(newer, for: session)
        mgr.reinstateSuspendedComposerDraft(submitted, for: session, suspendedRevision: suspendedAgain)
        #expect(session.composerDraft == newer)
    }

    @Test("re-mounting the composer after submit reads an empty initial draft")
    func remountAfterSubmitSeesEmptyDraft() async throws {
        // Regression for #353 follow-up: the second commit of #353 deferred
        // the in-memory draft clear to onPromptFinished. While the agent's
        // prompt RPC is in flight, a worktree switch dismantles the ACP
        // composer; re-mounting reads `session.composerDraft`, which was
        // never cleared, and the sent text reappears in the input. The new
        // suspend hook clears in-memory eagerly so a fresh coordinator
        // sees an empty initial draft.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-draft-remount-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        let submitted = ACPComposerDraft(segments: [.text("hello")])

        mgr.persistComposerDraft(submitted, for: session)
        _ = mgr.suspendComposerDraftForSubmission(submitted, for: session)
        await mgr.flushPersistence()

        // What `ACPInputField.makeCoordinator()` reads as `initialDraft`.
        #expect(session.composerDraft.isEmpty)
        // …while the persisted row is still durable for crash recovery
        // until the prompt is recorded and the completion fires.
        #expect(try store.loadComposerDraft(sessionId: session.id) == submitted)
    }

    @Test("detach normalizes a .sending queue head so re-attach can flush")
    func detachNormalizesSendingHead() async throws {
        // Regression: closing a tab while the flusher had promoted the
        // head to .sending used to leave the cached ACPSession with a
        // .sending head. The next openSession returns the cached object
        // (no `restoreQueue`), and the post-attach `flushQueueIfIdle`
        // sees `.sending` and no-ops — the queue is stuck until a full
        // app restart reloads from SQLite.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-detach-q-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        session.enqueue(blocks: [.text("queued")])
        session.markQueueHeadSending()
        #expect(session.queue[0].status == .sending)

        await mgr.detach(sessionId: session.id)
        #expect(session.queue[0].status == .pending)
    }

    @Test("attach normalizes an in-flight scheduled row before flushing")
    func attachNormalizesSendingScheduleBeforeFlush() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-attach-sending-schedule-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote")
        client.script(method: "session/prompt") { _ in Data("null".utf8) }
        let mgr = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = mgr.createSession(id: "session", agentId: "claude")
        session.enqueueScheduled(blocks: [.text("queued")], scheduledAt: Date().addingTimeInterval(-1))
        session.markQueueHeadSending()

        await mgr.attach(to: session.id, freshlyCreated: true)
        for _ in 0 ..< 20 where !session.queue.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(client.sent.contains { $0.method == "session/prompt" })
    }

    @Test("disconnected forced sending row stays retained")
    func disconnectedForcedSendingRowStaysRetained() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-disconnected-force-send-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote")
        let mgr = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = mgr.createSession(id: "session", agentId: "claude")
        await mgr.attach(to: session.id, freshlyCreated: true)
        session.queue.append(QueuedPrompt(blocks: [.text("forced")], status: .sending))
        session.transcript.streamingState = .sending
        session.agentState = .disconnected

        #expect(
            AppState(store: MemoryStore()).retainedACPSessionCleanupDelayForTesting(
                manager: mgr,
                sessionId: session.id
            ) == .milliseconds(250)
        )
    }

    private func scriptInitializeAdvertisingAuthStatus(_ client: ACPMockClient) {
        client.script(method: "initialize") { _ in
            """
            {
              "protocolVersion": 1,
              "agentCapabilities": { "_meta": { "authStatus": {} } },
              "authMethods": []
            }
            """.data(using: .utf8)!
        }
    }

    @Test("attach preserves a previously known authStatus when no fresh notification arrives")
    func attachPreservesAuthStatusWithoutFreshNotification() async throws {
        // Regression: a broker-adopted reattach to an already-running agent
        // serves `initialize` from a cached snapshot instead of re-running
        // it against the live process, so the agent never re-emits
        // `_auth/status_update` for this attach. Clearing the status
        // unconditionally would blank out an otherwise still-accurate
        // status; it must survive an attach that yields no new update, as
        // long as this attach's agent still advertises the extension.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-auth-status-preserved-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let client = ACPMockClient()
        scriptInitializeAdvertisingAuthStatus(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote")
        let mgr = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = mgr.createSession(id: "session", agentId: "claude")
        session.authStatus = .init(kind: .account, label: "Known-good status from a prior attach")

        await mgr.attach(to: session.id, freshlyCreated: true)

        #expect(session.authStatus?.label == "Known-good status from a prior attach")
    }

    @Test("attach clears a stale authStatus when the adapter no longer advertises the extension")
    func attachClearsAuthStatusWhenAdapterLacksExtension() async throws {
        // A session that previously had a signed-in status must not keep
        // showing it forever if it later attaches to an adapter/version
        // whose `initialize` response omits `_meta.authStatus` — that
        // adapter will never send an update to replace it.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-auth-status-unsupported-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote")
        let mgr = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = mgr.createSession(id: "session", agentId: "claude")
        session.authStatus = .init(kind: .account, label: "Stale status from an extension-capable agent")

        await mgr.attach(to: session.id, freshlyCreated: true)

        #expect(session.authStatus == nil)
    }

    @Test("a losing attach does not clear authStatus after standing down mid-flight")
    func losingAttachDoesNotClearAuthStatusAfterStandDown() async throws {
        // Regression: `leaseFence(sessionId:)` returning nil is not "no
        // fencing needed" (the persistence overload treats that as
        // permission to write unconditionally) — it means this attach lost
        // ownership while awaiting `initialize`. The clear must be skipped
        // entirely then, not performed unfenced.
        let gate = AsyncGate()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-auth-status-standdown-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let client = ACPMockClient()
        client.scriptAsync(method: "initialize") { _ in
            await gate.enterAndWait()
            return try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: nil,
                authMethods: []
            ))
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote")
        let mgr = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = mgr.createSession(id: "session", agentId: "claude")
        session.authStatus = .init(kind: .account, label: "Persisted by the new owner")

        let attachTask = Task { @MainActor in
            await mgr.attach(to: session.id, freshlyCreated: true)
        }
        await gate.waitUntilEntered()

        // Simulate a takeover landing while `initialize` is in flight:
        // `standDown` would remove this instance's ownership before the
        // attach resumes and reaches the clear.
        #expect(mgr._ownedLeases.contains(session.id))
        mgr._ownedLeases.remove(session.id)
        await gate.release()
        await attachTask.value

        #expect(session.authStatus?.label == "Persisted by the new owner")
    }

    @Test("a failed session creation clears a stale preserved authStatus")
    func failedSessionCreationClearsStaleAuthStatus() async throws {
        // Regression: preservation assumes a fresh process's own first
        // notification will arrive and correct a stale value moments
        // later — true only once the runner starts. If session creation
        // fails first (e.g. because the fresh process is actually signed
        // out), that notification is still buffered and never applied,
        // and the stale signed-in pill would otherwise sit right next to
        // the auth-required banner this same failure correctly triggers.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-auth-status-failed-new-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let client = ACPMockClient()
        scriptInitializeAdvertisingAuthStatus(client)
        client.script(method: "session/new") { _ in
            throw JSONRPCError(code: -32000, message: "Internal error: auth_required", data: nil)
        }
        let mgr = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = mgr.createSession(id: "session", agentId: "claude")
        session.authStatus = .init(kind: .account, label: "Stale, from before the agent lost auth")

        await mgr.attach(to: session.id, freshlyCreated: true)

        guard case .needsAuth = session.setupState else {
            Issue.record("expected .needsAuth setupState, got \(session.setupState)")
            return
        }
        #expect(session.authStatus == nil)
    }

    @Test("a non-auth session-creation failure still applies the agent's fresh authStatus")
    func nonAuthSessionCreationFailureAppliesFreshAuthStatus() async throws {
        // Regression (#1389): a restored `kind == .none` status re-applies
        // `.needsAuth` right after `initialize`, on the assumption that a
        // signed-in agent will correct it with its own `_auth/status_update`.
        // That notification used to be consumed only once the runner started,
        // i.e. after session creation succeeded — so a failure unrelated to
        // auth left the runner unstarted, the notification buffered, and the
        // stale signed-out banner up. The listener now runs from before the
        // session-creation call, so the live status wins either way.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-auth-status-nonauth-failure-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let client = ACPMockClient()
        scriptInitializeAdvertisingAuthStatus(client)
        let mgr = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = mgr.createSession(id: "session", agentId: "claude")
        session.authStatus = .init(kind: .none, label: "Not logged in")
        client.scriptAsync(method: "session/new") { _ in
            // A real agent announces its auth state as soon as the connection
            // is up, well before it answers `session/new`.
            client.emitAuthStatus(.init(kind: .account, label: "Claude Max"))
            for _ in 0 ..< 200 {
                if await MainActor.run(body: {
                    session.authStatus?.kind == ACPAuthStatus.Kind.account
                }) { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            throw JSONRPCError(code: -32000, message: "connection reset by peer", data: nil)
        }

        await mgr.attach(to: session.id, freshlyCreated: true)

        #expect(session.authStatus?.label == "Claude Max")
        if case .needsAuth = session.setupState {
            Issue.record("expected the stale auth banner to be dropped, got \(session.setupState)")
        }
    }

    @Test("a non-auth session-creation failure durably persists the agent's fresh authStatus")
    func nonAuthSessionCreationFailurePersistsFreshAuthStatus() async throws {
        // Regression (#1389, Codex review on this fix): the listener now
        // starts before session creation and enqueues its fenced authStatus
        // write onto the *runner's own* persistence queue — but a runner
        // that never gets registered (this failure path) is invisible to
        // `flushAllPersistence()`, which only walks registered runners.
        // Without an explicit flush of the abandoned runner before
        // `releaseWriterLease` releases the fence, that write races
        // `ACPSessionPersistence`'s actor mailbox against `releaseLease` and
        // can be silently rejected — correct in memory for this process, but
        // reverting to the stale status on the next restore. (The race is on
        // actor-call ordering, not wall-clock time, so it isn't reliably
        // reproducible by delaying this test; the flush closes it
        // unconditionally instead of relying on scheduling luck.) Assert the
        // durable side: a fresh manager instance over the same store must
        // see the live status, not the stale persisted one.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-auth-status-nonauth-durable-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let client = ACPMockClient()
        scriptInitializeAdvertisingAuthStatus(client)
        let mgr = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = mgr.createSession(id: "session", agentId: "claude")
        session.authStatus = .init(kind: .none, label: "Not logged in")
        await mgr.flushAllPersistence()
        client.scriptAsync(method: "session/new") { _ in
            client.emitAuthStatus(.init(kind: .account, label: "Claude Max"))
            for _ in 0 ..< 200 {
                if await MainActor.run(body: {
                    session.authStatus?.kind == ACPAuthStatus.Kind.account
                }) { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            throw JSONRPCError(code: -32000, message: "connection reset by peer", data: nil)
        }

        await mgr.attach(to: session.id, freshlyCreated: true)
        await mgr.releaseAllOwnedLeases()

        let secondClient = ACPMockClient()
        scriptInitializeAdvertisingAuthStatus(secondClient)
        let secondManager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: secondClient) }
        )
        guard let secondSession = secondManager.placeholderSession(id: "session") else {
            Issue.record("expected a placeholder session to hydrate from the persisted row")
            return
        }
        await secondManager.hydrateIfNeeded(id: secondSession.id)

        #expect(secondSession.authStatus?.label == "Claude Max")
    }

    @Test("a non-auth session-creation failure keeps a restored signed-out banner")
    func nonAuthSessionCreationFailureKeepsRestoredSignedOutBanner() async throws {
        // The flip side of the test above: when the failing attach produces no
        // fresh notification at all, the restored signed-out status is still
        // the best information available and its banner must stay up.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-auth-status-nonauth-silent-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let client = ACPMockClient()
        scriptInitializeAdvertisingAuthStatus(client)
        client.script(method: "session/new") { _ in
            throw JSONRPCError(code: -32000, message: "connection reset by peer", data: nil)
        }
        let mgr = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = mgr.createSession(id: "session", agentId: "claude")
        session.authStatus = .init(kind: .none, label: "Not logged in")

        await mgr.attach(to: session.id, freshlyCreated: true)

        #expect(session.authStatus?.kind == ACPAuthStatus.Kind.none)
        guard case .needsAuth = session.setupState else {
            Issue.record("expected .needsAuth setupState, got \(session.setupState)")
            return
        }
    }

    @Test("a failed session creation keeps a signed-out authStatus the failure agrees with")
    func failedSessionCreationKeepsSignedOutAuthStatus() async throws {
        // The auth-failure branch clears the status because a signed-in pill
        // next to the banner it raises is contradictory. A signed-out status
        // is the one kind the failure corroborates, so clearing it just loses
        // the label the pill/banner can show — and, after a restart, leaves
        // nothing to restore the banner from before the next attach.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-auth-status-failed-new-signed-out-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let client = ACPMockClient()
        scriptInitializeAdvertisingAuthStatus(client)
        client.script(method: "session/new") { _ in
            throw JSONRPCError(code: -32000, message: "Internal error: auth_required", data: nil)
        }
        let mgr = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = mgr.createSession(id: "session", agentId: "claude")
        session.authStatus = .init(kind: .none, label: "Not logged in")

        await mgr.attach(to: session.id, freshlyCreated: true)

        #expect(session.authStatus?.kind == ACPAuthStatus.Kind.none)
        guard case .needsAuth = session.setupState else {
            Issue.record("expected .needsAuth setupState, got \(session.setupState)")
            return
        }
    }

    @Test("a failed pending authenticate call clears a stale preserved authStatus")
    func failedPendingAuthenticateClearsStaleAuthStatus() async throws {
        // Same reasoning as the session-creation auth-failure case, but for
        // the earlier `connection.authenticate` early return: it also
        // happens before the runner starts, so a fresh process's buffered
        // initial notification is never consumed.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-auth-status-failed-authenticate-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let client = ACPMockClient()
        scriptInitializeAdvertisingAuthStatus(client)
        client.script(method: "authenticate") { _ in
            throw JSONRPCError(code: -32000, message: "Internal error: auth_required", data: nil)
        }
        let mgr = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = mgr.createSession(id: "session", agentId: "claude")
        session.authStatus = .init(kind: .account, label: "Stale, from before the agent lost auth")
        session.pendingAuthMethodId = "claude-ai-login"

        await mgr.attach(to: session.id, freshlyCreated: true)

        guard case .needsAuth = session.setupState else {
            Issue.record("expected .needsAuth setupState, got \(session.setupState)")
            return
        }
        #expect(session.authStatus == nil)
    }

    @Test("authStatus survives an app restart and is restored before any attach")
    func authStatusSurvivesAppRestart() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-auth-status-restart-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let firstClient = ACPMockClient()
        scriptInitializeAdvertisingAuthStatus(firstClient)
        scriptSessionResult(firstClient, method: "session/new", sessionId: "remote")
        let firstManager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: firstClient) }
        )
        let firstSession = firstManager.createSession(id: "session", agentId: "claude")
        await firstManager.attach(to: firstSession.id, freshlyCreated: true)
        firstClient.emitAuthStatus(.init(kind: .account, label: "Claude Max"))
        for _ in 0 ..< 100 where firstSession.authStatus == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(firstSession.authStatus?.label == "Claude Max")
        await firstManager.flushAllPersistence()
        // Release the writer lease so the second manager below can actually
        // become the writer instead of silently becoming a read-only mirror
        // (an app restart implies the first process, and its lease, is gone).
        await firstManager.releaseAllOwnedLeases()

        // Simulate an app restart: a brand-new manager instance reading the
        // same on-disk store, adopting an agent that (like a broker-served
        // cached `initialize`) sends no fresh notification this time.
        let secondClient = ACPMockClient()
        scriptInitializeAdvertisingAuthStatus(secondClient)
        scriptSessionResult(secondClient, method: "session/new", sessionId: "remote")
        let secondManager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: secondClient) }
        )
        guard let secondSession = secondManager.placeholderSession(id: "session") else {
            Issue.record("expected a placeholder session to hydrate from the persisted row")
            return
        }
        await secondManager.hydrateIfNeeded(id: secondSession.id)
        #expect(secondSession.authStatus?.label == "Claude Max")

        await secondManager.attach(to: secondSession.id, freshlyCreated: false)

        #expect(secondSession.authStatus?.label == "Claude Max")
    }

    @Test("a restored signed-out authStatus re-triggers the auth nudge banner")
    func restoredSignedOutAuthStatusReTriggersBanner() async throws {
        // Regression: `attach()` unconditionally resets `setupState` to
        // `.ready` before this point. A persisted `kind == .none` status
        // restored from a prior run (or preserved across a broker-adopted
        // reattach with no fresh notification) must re-trigger `.needsAuth`
        // here, or the user sees neither the banner (setupState says
        // `.ready`) nor the pill (hidden for `kind == .none` by design).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-auth-status-restart-none-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let firstClient = ACPMockClient()
        scriptInitializeAdvertisingAuthStatus(firstClient)
        scriptSessionResult(firstClient, method: "session/new", sessionId: "remote")
        let firstManager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: firstClient) }
        )
        let firstSession = firstManager.createSession(id: "session", agentId: "claude")
        await firstManager.attach(to: firstSession.id, freshlyCreated: true)
        firstClient.emitAuthStatus(.init(kind: .none, label: "Not logged in"))
        for _ in 0 ..< 100 where firstSession.authStatus == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await firstManager.flushAllPersistence()
        await firstManager.releaseAllOwnedLeases()

        let secondClient = ACPMockClient()
        scriptInitializeAdvertisingAuthStatus(secondClient)
        scriptSessionResult(secondClient, method: "session/new", sessionId: "remote")
        let secondManager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: secondClient) }
        )
        guard let secondSession = secondManager.placeholderSession(id: "session") else {
            Issue.record("expected a placeholder session to hydrate from the persisted row")
            return
        }
        await secondManager.hydrateIfNeeded(id: secondSession.id)

        await secondManager.attach(to: secondSession.id, freshlyCreated: false)

        #expect(secondSession.authStatus?.kind == ACPAuthStatus.Kind.none)
        guard case .needsAuth = secondSession.setupState else {
            Issue.record("expected .needsAuth setupState, got \(secondSession.setupState)")
            return
        }
    }

    @Test("a live authStatus update reaches the session after attach")
    func authStatusUpdateReachesSessionAfterAttach() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-auth-status-live-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let client = ACPMockClient()
        client.script(method: "initialize") { _ in
            """
            {
              "protocolVersion": 1,
              "agentCapabilities": { "_meta": { "authStatus": {} } },
              "authMethods": []
            }
            """.data(using: .utf8)!
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote")
        let mgr = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = mgr.createSession(id: "session", agentId: "claude")

        await mgr.attach(to: session.id, freshlyCreated: true)
        client.emitAuthStatus(.init(kind: .none, label: "Not logged in"))

        for _ in 0 ..< 100 where session.authStatus == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // `.none` through optional chaining is ambiguous between "the kind
        // is .none" and "the optional itself is nil" — spell out the type
        // to force the former (the classic Optional<Enum>.none gotcha).
        #expect(session.authStatus?.kind == ACPAuthStatus.Kind.none)
        guard case .needsAuth = session.setupState else {
            Issue.record("expected .needsAuth setupState, got \(session.setupState)")
            return
        }
    }

    @Test("queue force send reattaches disconnected sessions first")
    func queueForceSendReattachesDisconnectedSession() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-force-send-reattach-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(id: "session", agentId: "no-such-agent-\(UUID().uuidString)")
        session.agentState = .disconnected
        session.enqueueScheduled(blocks: [.text("later")], scheduledAt: .distantFuture)
        let itemId = try #require(session.queue.first?.id)

        await mgr.queueForceSend(for: session.id, itemId: itemId)

        #expect(session.agentState != .disconnected)
    }

    @Test("queue force send during attach sends after ready")
    func queueForceSendDuringAttachSendsAfterReady() async throws {
        let gate = AsyncGate()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-force-send-spawning-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let client = ACPMockClient()
        client.scriptAsync(method: "initialize") { _ in
            await gate.enterAndWait()
            return try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: nil,
                authMethods: []
            ))
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote")
        client.script(method: "session/prompt") { _ in Data("null".utf8) }
        let mgr = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = mgr.createSession(id: "session", agentId: "claude")
        session.enqueueScheduled(blocks: [.text("later")], scheduledAt: .distantFuture)
        let itemId = try #require(session.queue.first?.id)
        let attachTask = Task { @MainActor in
            await mgr.attach(to: session.id, freshlyCreated: true)
        }
        await gate.waitUntilEntered()

        await mgr.queueForceSend(for: session.id, itemId: itemId)
        #expect(client.sent.contains(where: { $0.method == "session/prompt" }) == false)
        await gate.release()
        await attachTask.value
        for _ in 0 ..< 50 where !client.sent.contains(where: { $0.method == "session/prompt" }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(client.sent.contains(where: { $0.method == "session/prompt" }))
    }

    @Test("queue force send during attach preserves every requested item")
    func queueForceSendDuringAttachPreservesEveryRequestedItem() async throws {
        let gate = AsyncGate()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-force-send-spawning-many-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let client = ACPMockClient()
        client.scriptAsync(method: "initialize") { _ in
            await gate.enterAndWait()
            return try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: nil,
                authMethods: []
            ))
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote")
        client.script(method: "session/prompt") { _ in Data("null".utf8) }
        let mgr = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = mgr.createSession(id: "session", agentId: "claude")
        session.enqueueScheduled(blocks: [.text("first")], scheduledAt: .distantFuture)
        session.enqueueScheduled(blocks: [.text("second")], scheduledAt: .distantFuture)
        let firstId = try #require(session.queue.first?.id)
        let secondId = try #require(session.queue.dropFirst().first?.id)
        let attachTask = Task { @MainActor in
            await mgr.attach(to: session.id, freshlyCreated: true)
        }
        await gate.waitUntilEntered()

        await mgr.queueForceSend(for: session.id, itemId: firstId)
        await mgr.queueForceSend(for: session.id, itemId: secondId)
        await gate.release()
        await attachTask.value
        for _ in 0 ..< 100 where client.sent.filter({ $0.method == "session/prompt" }).count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let prompts = try client.sent
            .filter { $0.method == "session/prompt" }
            .map { try #require($0.params as? ACPSessionPromptParams).prompt }
        #expect(prompts == [[.text("first")], [.text("second")]])
    }

    @Test("queue force send during pre-lease spawn is retained")
    func queueForceSendDuringPreLeaseSpawnIsRetained() async throws {
        var queueChanged = false
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-force-send-prelease-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            onQueueChanged: { _, _ in queueChanged = true }
        )
        let session = mgr.createSession(id: "session", agentId: "claude")
        session.agentState = .spawning
        session.enqueueScheduled(blocks: [.text("later")], scheduledAt: .distantFuture)
        let itemId = try #require(session.queue.first?.id)

        await mgr.queueForceSend(for: session.id, itemId: itemId)
        await mgr.flushPersistence()

        #expect(queueChanged)
        #expect(session.queue.first?.scheduledAt == nil)
        #expect(try store.loadQueue(sessionId: session.id).first?.scheduledAt == nil)
    }

    @Test("queue force send during recovering persistence keeps schedule parked")
    func queueForceSendDuringRecoveringPersistenceKeepsScheduleParked() async throws {
        var queueChanged = false
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-force-send-recovering-persistence-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            onQueueChanged: { _, _ in queueChanged = true }
        )
        let session = mgr.createSession(id: "session", agentId: "claude")
        session.agentState = .spawning
        session.enqueueScheduled(blocks: [.text("later")], scheduledAt: .distantFuture)
        let itemId = try #require(session.queue.first?.id)
        session.pendingQueuePersistenceCount = 1

        await mgr.queueForceSend(for: session.id, itemId: itemId)

        #expect(queueChanged)
        #expect(session.queue.first?.scheduledAt != nil)
    }

    @Test("stale force send during attach falls back to queue flush")
    func staleForceSendDuringAttachFallsBackToQueueFlush() async throws {
        let gate = AsyncGate()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-stale-force-send-spawning-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let client = ACPMockClient()
        client.scriptAsync(method: "initialize") { _ in
            await gate.enterAndWait()
            return try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: nil,
                authMethods: []
            ))
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote")
        client.script(method: "session/prompt") { request in
            let params = try #require(request.params as? ACPSessionPromptParams)
            #expect(params.prompt == [.text("fallback")])
            return Data("null".utf8)
        }
        let mgr = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = mgr.createSession(id: "session", agentId: "claude")
        session.enqueue(blocks: [.text("removed")])
        session.enqueue(blocks: [.text("fallback")])
        let removedId = try #require(session.queue.first?.id)
        let attachTask = Task { @MainActor in
            await mgr.attach(to: session.id, freshlyCreated: true)
        }
        await gate.waitUntilEntered()

        await mgr.queueForceSend(for: session.id, itemId: removedId)
        await mgr.queueRemove(for: session.id, itemId: removedId)
        await gate.release()
        await attachTask.value
        for _ in 0 ..< 50 where !client.sent.contains(where: { $0.method == "session/prompt" }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(client.sent.contains(where: { $0.method == "session/prompt" }))
    }

    @Test("persistQueue writes to SQLite without requiring a runner")
    func persistQueueWithoutRunner() async throws {
        // Regression: ACPTabView's queue actions used to call
        // `manager.runners[sessionId]?.persistQueue()`, which silently
        // no-oped when no runner was attached (setup nudge / launch
        // failure). Edits then lived only in memory; relaunch restored
        // the supposedly-removed prompts from SQLite.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-persist-q-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        session.enqueue(blocks: [.text("a")])
        session.enqueue(blocks: [.text("b")])

        mgr.persistQueue(for: session)
        await mgr.flushPersistence()
        let persisted = try store.loadQueue(sessionId: session.id)
        #expect(persisted == session.queue)

        session.clearPendingQueue()
        mgr.persistQueue(for: session)
        await mgr.flushPersistence()
        let afterClear = try store.loadQueue(sessionId: session.id)
        #expect(afterClear.isEmpty)
    }
}
