import Foundation
import Testing
@testable import Alas

private actor SQLiteWriteLock {
    let path: String

    init(path: String) {
        self.path = path
    }

    func hold(for seconds: TimeInterval, didLock: @Sendable () -> Void) throws {
        let database = try SQLiteDatabase(path: path)
        try database.exec("BEGIN IMMEDIATE")
        didLock()
        Thread.sleep(forTimeInterval: seconds)
        try database.exec("ROLLBACK")
    }
}

@MainActor
@Suite("ACP session persistence")
struct ACPSessionPersistenceTests {
    @Test("SQLite lock waits do not block the main actor")
    func lockWaitRunsOffMainActor() async throws {
        let url = temporaryDatabaseURL()
        let seed = try ACPSessionStore(path: url.path)
        try seed.upsertSession(row(id: "seed"))

        let lock = SQLiteWriteLock(path: url.path)
        let (locked, continuation) = AsyncStream<Void>.makeStream()
        let lockTask = Task {
            try await lock.hold(for: 0.4) {
                continuation.yield()
                continuation.finish()
            }
        }
        var iterator = locked.makeAsyncIterator()
        _ = await iterator.next()

        let persistence = ACPSessionPersistence(path: url.path)
        let startedAt = Date()
        let writeTask = Task {
            try await persistence.upsertSession(row(id: "waiter"))
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(Date().timeIntervalSince(startedAt) < 0.2)

        try await writeTask.value
        try await lockTask.value
        #expect(try await persistence.loadSession(id: "waiter") != nil)
    }

    @Test("manager preserves parent-before-child persistence order")
    func parentSessionPrecedesDraft() async throws {
        let url = temporaryDatabaseURL()
        let persistence = ACPSessionPersistence(path: url.path)
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            persistence: persistence
        )
        let session = manager.createSession(agentId: "claude")
        let draft = ACPComposerDraft(segments: [.text("ordered")])

        manager.persistComposerDraft(draft, for: session)
        manager.flushPendingDraftWrites()
        await manager.flushPersistence()

        #expect(try await persistence.loadSession(id: session.id) != nil)
        #expect(try await persistence.loadComposerDraftRecord(sessionId: session.id)?.draft == draft)
    }

    @Test("takeover fences every write from the old owner")
    func staleLeaseTokenCannotWrite() async throws {
        let url = temporaryDatabaseURL()
        let persistence = ACPSessionPersistence(path: url.path)
        try await persistence.upsertSession(row(id: "session"))
        let now = Int64(Date().timeIntervalSince1970)
        let oldLease = try #require(try await persistence.claimLease(
            sessionId: "session",
            instanceId: "old",
            pid: Int64(getpid()),
            now: now,
            staleAfter: 15,
            leaseToken: "old-token"
        ))
        let newLease = try await persistence.seizeLease(
            sessionId: "session",
            instanceId: "new",
            pid: Int64(getpid()),
            now: now + 1,
            leaseToken: "new-token"
        )

        let oldWrite = try await persistence.setContextRecoveryPending(
            sessionId: "session",
            pending: true,
            fence: fence(for: oldLease)
        )
        #expect(!oldWrite)
        #expect(try await persistence.loadSession(id: "session")?.contextRecoveryPending == false)

        let newWrite = try await persistence.setContextRecoveryPending(
            sessionId: "session",
            pending: true,
            fence: fence(for: newLease)
        )
        #expect(newWrite)
        #expect(try await persistence.loadSession(id: "session")?.contextRecoveryPending == true)
    }

    @Test("a stale runner's fenced authStatus write cannot overwrite the new owner's status")
    func staleLeaseTokenCannotOverwriteAuthStatus() async throws {
        let url = temporaryDatabaseURL()
        let persistence = ACPSessionPersistence(path: url.path)
        try await persistence.upsertSession(row(id: "session"))
        let now = Int64(Date().timeIntervalSince1970)
        let oldLease = try #require(try await persistence.claimLease(
            sessionId: "session",
            instanceId: "old",
            pid: Int64(getpid()),
            now: now,
            staleAfter: 15,
            leaseToken: "old-token"
        ))
        let newLease = try await persistence.seizeLease(
            sessionId: "session",
            instanceId: "new",
            pid: Int64(getpid()),
            now: now + 1,
            leaseToken: "new-token"
        )

        // The new owner already persisted its own status.
        let newStatus = ACPAuthStatus(kind: .account, label: "New owner")
        #expect(try await persistence.setAuthStatus(
            sessionId: "session", status: newStatus, fence: fence(for: newLease)
        ))

        // The stale runner, still draining a buffered notification under
        // its now-superseded fence, must not be able to clobber it.
        let staleStatus = ACPAuthStatus(kind: .none, label: "Stale, from the old owner")
        #expect(!(try await persistence.setAuthStatus(
            sessionId: "session", status: staleStatus, fence: fence(for: oldLease)
        )))
        #expect(try await persistence.loadSession(id: "session")?.authStatus == newStatus)
    }

    @Test("remote transcript import rekeys rows and preserves this Mac's draft")
    func remoteReplicaPreservesLocalIdentityAndDraft() async throws {
        let writer = ACPSessionPersistence(path: temporaryDatabaseURL().path)
        let reader = ACPSessionPersistence(path: temporaryDatabaseURL().path)
        var source = row(id: "writer-local")
        source.remoteSessionId = "remote-conversation"
        var target = row(id: "reader-local")
        target.remoteSessionId = "remote-conversation"
        target.helperProcStdoutOffset = 42
        try await writer.upsertSession(source)
        try await reader.upsertSession(target)
        let draft = ACPComposerDraft(segments: [.text("my unsent draft")])
        try await reader.upsertComposerDraft(sessionId: target.id, draft: draft, updatedAt: 1)
        try await writer.enableReplicaExport(sessionId: source.id, recordId: "remote-record")
        let payload = Data(#"{"text":"hello /.alas-remote/writer-alias/literal"}"#.utf8)
        _ = try await writer.persistMessages([.init(id: "msg-writer-local-0", sessionId: source.id, kind: "agent", seq: 0, payload: payload, createdAt: 12)], fence: nil)
        let exported = try #require(try await writer.replicaChanges(sessionId: source.id, limit: 256))
        let entries = exported.entries.map { RemoteSessionReplicaEntry(kind: $0.kind, key: $0.key, payload: $0.payload, revision: 1) }
        try await reader.stageReplicaPage(sessionId: target.id, recordId: "remote-record", page: .init(cutoffRevision: 1, entries: entries, nextPageToken: nil))
        #expect(try await reader.commitReplicaImport(importGuard: .init(sessionId: target.id, expectedLocalFence: nil)) == 1)
        let hydrated = try await reader.mirrorSnapshot(sessionId: target.id)
        #expect(hydrated.wireMessages == [.agent(messageId: nil, text: "hello /.alas-remote/writer-alias/literal", phase: nil, metadata: nil)])
        #expect(hydrated.row.id == target.id)
        #expect(hydrated.row.helperProcStdoutOffset == 42)
        #expect(try await reader.loadComposerDraftRecord(sessionId: target.id)?.draft == draft)
    }

    @Test("acknowledging an older publication retains a newer streamed row")
    func replicaAcknowledgementRetainsNewerChange() async throws {
        let persistence = ACPSessionPersistence(path: temporaryDatabaseURL().path)
        try await persistence.upsertSession(row(id: "session"))
        try await persistence.enableReplicaExport(sessionId: "session", recordId: "record")
        _ = try await persistence.persistMessages([.init(id: "msg-session-0", sessionId: "session", kind: "agent", seq: 0, payload: Data(#"{"text":"old"}"#.utf8), createdAt: 1)], fence: nil)
        let first = try #require(try await persistence.replicaChanges(sessionId: "session", limit: 256))
        _ = try await persistence.persistMessages([.init(id: "msg-session-0", sessionId: "session", kind: "agent", seq: 0, payload: Data(#"{"text":"new"}"#.utf8), createdAt: 1)], fence: nil)
        try await persistence.acknowledgeReplicaChanges(sessionId: "session", export: first)
        let next = try #require(try await persistence.replicaChanges(sessionId: "session", limit: 256))
        #expect(next.entries.contains { $0.kind == .message && $0.key == "0" })
        let reader = ACPSessionPersistence(path: temporaryDatabaseURL().path)
        try await reader.upsertSession(row(id: "reader"))
        let entries = next.entries.map { RemoteSessionReplicaEntry(kind: $0.kind, key: $0.key, payload: $0.payload, revision: 2) }
        try await reader.stageReplicaPage(sessionId: "reader", recordId: "record", page: .init(cutoffRevision: 2, entries: entries, nextPageToken: nil))
        _ = try await reader.commitReplicaImport(importGuard: .init(sessionId: "reader", expectedLocalFence: nil))
        #expect(try await reader.mirrorSnapshot(sessionId: "reader").wireMessages == [.agent(messageId: nil, text: "new", phase: nil, metadata: nil)])
    }

    @Test("an unresolved remote parent survives takeover and later resolves without undoing promotion")
    func unresolvedParentSurvivesTakeoverAndResolvesLocally() async throws {
        let persistence = ACPSessionPersistence(path: temporaryDatabaseURL().path)
        try await persistence.upsertSession(row(id: "child-local"))
        let reference = Data(#"{"agentId":"claude","remoteSessionId":"parent-remote"}"#.utf8)
        try await persistence.stageReplicaPage(sessionId: "child-local", recordId: "child-record",
            page: .init(cutoffRevision: 1, entries: [.init(kind: .relationship, key: "ephemeralParent", payload: reference, revision: 1)], nextPageToken: nil))
        _ = try await persistence.commitReplicaImport(importGuard: .init(sessionId: "child-local", expectedLocalFence: nil))
        try await persistence.enableReplicaExport(sessionId: "child-local", recordId: "child-record")
        let publication = try #require(try await persistence.replicaChanges(sessionId: "child-local", limit: 256))
        let retained = try #require(publication.entries.first { $0.kind == .relationship && $0.key == "ephemeralParent" }?.payload)
        #expect(try JSONDecoder().decode([String: String].self, from: retained) == ["agentId": "claude", "remoteSessionId": "parent-remote"])
        var parent = row(id: "parent-local")
        parent.remoteSessionId = "parent-remote"
        try await persistence.upsertSession(parent)
        try await persistence.resolveReplicaRelations()
        #expect(try await persistence.loadSession(id: "child-local")?.ephemeralParentId == "parent-local")
        #expect(try await persistence.promoteEphemeralSession(id: "child-local"))
        try await persistence.resolveReplicaRelations()
        #expect(try await persistence.loadSession(id: "child-local")?.ephemeralParentId == nil)
    }

    @Test("unresolved delegated sources survive takeover and map when their sender becomes local", arguments: [false, true])
    func delegatedSourcesSurviveTakeover(subagent: Bool) async throws {
        let writerPath = temporaryDatabaseURL().path
        let readerPath = temporaryDatabaseURL().path
        let nextPath = temporaryDatabaseURL().path
        let writerStore = try ACPSessionStore(path: writerPath)
        var sender = row(id: "sender-writer")
        sender.remoteSessionId = "sender-remote"
        try writerStore.upsertSession(sender)
        try writerStore.upsertSession(row(id: "writer"))
        let writer = ACPSessionPersistence(path: writerPath)
        let reader = ACPSessionPersistence(path: readerPath)
        let next = ACPSessionPersistence(path: nextPath)
        try await reader.upsertSession(row(id: "reader"))
        try await next.upsertSession(row(id: "next"))
        var nextSender = row(id: "sender-next")
        nextSender.remoteSessionId = sender.remoteSessionId
        try await next.upsertSession(nextSender)
        try await writer.enableReplicaExport(sessionId: "writer", recordId: "record")
        let source = ACPDelegatedPromptSource(sessionId: sender.id, messageId: "inbox")
        let message = ACPMessage.user(id: UUID(), messageId: nil, text: "delegated input", attachments: [], delegatedSource: source)
        if subagent {
            try writerStore.upsertSubagentMessages([.init(id: "native-row", sessionId: "writer", subagentSessionId: "native/child", kind: message.kind, seq: 0, payload: ACPMessageCodec.encode(message), createdAt: 1)])
        } else {
            try writerStore.appendMessage(sessionId: "writer", id: "msg-writer-0", kind: message.kind, seq: 0, payload: ACPMessageCodec.encode(message), createdAt: 1)
        }
        try writerStore.upsertQueue(sessionId: "writer", items: [.init(blocks: [.text("queued input")], delegatedSource: source)])
        let first = try #require(try await writer.replicaChanges(sessionId: "writer", limit: 256))
        try await reader.stageReplicaPage(sessionId: "reader", recordId: "record", page: .init(cutoffRevision: 1, entries: first.entries.map { .init(kind: $0.kind, key: $0.key, payload: $0.payload, revision: 1) }, nextPageToken: nil))
        _ = try await reader.commitReplicaImport(importGuard: .init(sessionId: "reader", expectedLocalFence: nil))
        try await reader.enableReplicaExport(sessionId: "reader", recordId: "record")
        let takeover = try #require(try await reader.replicaChanges(sessionId: "reader", limit: 256))
        try await next.stageReplicaPage(sessionId: "next", recordId: "record", page: .init(cutoffRevision: 2, entries: takeover.entries.map { .init(kind: $0.kind, key: $0.key, payload: $0.payload, revision: 2) }, nextPageToken: nil))
        _ = try await next.commitReplicaImport(importGuard: .init(sessionId: "next", expectedLocalFence: nil))
        var readerSender = row(id: "sender-reader")
        readerSender.remoteSessionId = sender.remoteSessionId
        try await reader.upsertSession(readerSender)
        try await reader.resolveReplicaRelations()
        for (path, sessionId, senderId) in [(readerPath, "reader", "sender-reader"), (nextPath, "next", "sender-next")] {
            let store = try ACPSessionStore(path: path)
            let table = subagent ? "subagent_messages" : "messages"
            let payload = try #require(try store.db.query("SELECT payload FROM \(table) WHERE session_id=? AND seq=0", bindings: [sessionId]).first?["payload"] as? Data)
            let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
            let importedSource = try #require(object["delegatedSource"] as? [String: Any])
            #expect(importedSource["sessionId"] as? String == senderId)
            #expect(importedSource["messageId"] as? String == "inbox")
            #expect(try store.loadQueue(sessionId: sessionId).first?.delegatedSource == ACPDelegatedPromptSource(sessionId: senderId, messageId: "inbox"))
        }
    }

    enum RecoveryMutation: CaseIterable, Sendable { case prepare, rotate, bind }

    @Test("a replacement local writer fences every durable recovery transition", arguments: RecoveryMutation.allCases)
    func recoveryMutationsRejectReplacedLease(mutation: RecoveryMutation) async throws {
        let path = temporaryDatabaseURL().path
        let persistence = ACPSessionPersistence(path: path)
        var original = row(id: "session")
        original.remoteSessionId = "original"
        try await persistence.upsertSession(original)
        let lease = try await persistence.seizeLease(sessionId: original.id, instanceId: "A", pid: 1, now: 100, leaseToken: "old")
        let oldFence = fence(for: lease)
        if mutation != .prepare {
            try #require(try await persistence.prepareRemoteContextRecovery(fence: oldFence, procId: "recovery-proc"))
        }
        _ = try await persistence.seizeLease(sessionId: original.id, instanceId: "B", pid: 2, now: 101, leaseToken: "replacement")
        switch mutation {
        case .prepare:
            #expect(try await persistence.prepareRemoteContextRecovery(fence: oldFence, procId: "recovery-proc") == false)
        case .rotate:
            #expect(try await persistence.rotateRemoteRecoveryLease(fence: oldFence, pid: 1, now: 102, token: "next") == nil)
        case .bind:
            #expect(try await persistence.completeRemoteContextRecoveryBinding(fence: oldFence,
                procId: "recovery-proc", remoteSessionId: "recovered") == false)
        }
        let durable = try #require(try await persistence.loadSession(id: original.id))
        #expect(durable.remoteSessionId == (mutation == .prepare ? "original" : nil))
        #expect(durable.recoveryProcId == (mutation == .prepare ? nil : "recovery-proc"))
        #expect(try await persistence.loadLease(sessionId: original.id)?.token == "replacement")
    }

    @Test("recovery intent survives stale metadata and clears only for the matching bound process")
    func recoveryIntentSurvivesStaleMetadataUntilMatchingBind() async throws {
        let path = temporaryDatabaseURL().path
        let persistence = ACPSessionPersistence(path: path)
        var original = row(id: "session")
        original.remoteSessionId = "original"
        try await persistence.upsertSession(original)
        let lease = try await persistence.seizeLease(sessionId: original.id, instanceId: "A", pid: 1, now: 100, leaseToken: "old")
        let localFence = fence(for: lease)
        try #require(try await persistence.prepareRemoteContextRecovery(fence: localFence, procId: "recovery-proc"))
        try await persistence.upsertSession(original)
        let restarted = ACPSessionPersistence(path: path)
        let intent = try #require(try await restarted.loadSession(id: original.id))
        #expect(intent.remoteSessionId == nil)
        #expect(intent.recoveryProcId == "recovery-proc")
        #expect(intent.contextRecoveryPending)
        #expect(try await restarted.completeRemoteContextRecoveryBinding(fence: localFence,
            procId: "unrelated-proc", remoteSessionId: "wrong") == false)
        try #require(try await restarted.completeRemoteContextRecoveryBinding(fence: localFence,
            procId: "recovery-proc", remoteSessionId: "recovered"))
        let bound = try #require(try await restarted.loadSession(id: original.id))
        #expect(bound.remoteSessionId == "recovered")
        #expect(bound.recoveryProcId == nil)
        #expect(bound.contextRecoveryPending)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-persistence-\(UUID()).sqlite")
    }

    private func row(id: String) -> ACPSessionRow {
        let now = Int64(Date().timeIntervalSince1970)
        return ACPSessionRow(
            id: id,
            agentId: "claude",
            title: "New session",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: now,
            updatedAt: now,
            lastOpenedAt: now,
            archived: false
        )
    }

    private func fence(for lease: ACPSessionLease) -> ACPSessionLeaseFence {
        ACPSessionLeaseFence(
            sessionId: lease.sessionId,
            ownerInstance: lease.ownerInstance,
            token: lease.token
        )
    }
}
