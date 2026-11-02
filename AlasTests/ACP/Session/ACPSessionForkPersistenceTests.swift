import Foundation
import Testing
@testable import Alas

@Suite("ACP session fork persistence")
struct ACPSessionForkPersistenceTests {
    @Test("fork row, copied messages, and metadata commit together")
    func atomicCreateAndLoad() throws {
        let store = try ACPSessionStore(path: temporaryPath())
        let row = targetRow(id: "target")
        let messages = [
            ACPStoredMessage(
                id: "msg-target-0", sessionId: "target", kind: "user", seq: 0,
                payload: Data(#"{"messageId":null,"text":"hello","attachments":[],"delegatedSource":null}"#.utf8),
                createdAt: 1
            )
        ]
        let record = forkRecord(target: "target", phase: .ready, mechanism: .transcriptTransfer)

        try store.createFork(session: row, messages: messages, record: record)

        #expect(try store.loadSession(id: "target") == row)
        #expect(try store.loadMessages(sessionId: "target") == messages)
        #expect(try store.loadFork(targetSessionID: "target") == record)
    }

    @Test("fork create rolls back when a copied message conflicts")
    func atomicRollback() throws {
        let store = try ACPSessionStore(path: temporaryPath())
        try store.upsertSession(targetRow(id: "existing"))
        try store.appendMessage(
            sessionId: "existing", id: "collision", kind: "system", seq: 0,
            payload: Data(#"{"messageId":null,"text":"existing"}"#.utf8), createdAt: 0
        )
        let conflicting = ACPStoredMessage(
            id: "collision", sessionId: "target", kind: "user", seq: 0,
            payload: Data(#"{"messageId":null,"text":"fork","attachments":[],"delegatedSource":null}"#.utf8),
            createdAt: 1
        )

        var didThrow = false
        do {
            try store.createFork(
                session: targetRow(id: "target"),
                messages: [conflicting],
                record: forkRecord(target: "target", phase: .ready, mechanism: .transcriptTransfer)
            )
        } catch {
            didThrow = true
        }
        #expect(didThrow)
        #expect(try store.loadSession(id: "target") == nil)
        #expect(try store.loadFork(targetSessionID: "target") == nil)
    }

    @Test("finalize and clear pending context survive hydration")
    func finalizeAndHydrate() async throws {
        let path = temporaryPath()
        let persistence = ACPSessionPersistence(path: path)
        let initial = forkRecord(target: "target", phase: .negotiatingNative, mechanism: nil)
        try await persistence.createFork(
            session: targetRow(id: "target"),
            messages: [],
            record: initial
        )
        try await persistence.finalizeFork(
            targetSessionID: "target",
            mechanism: .transcriptTransfer,
            remoteSessionID: nil
        )

        let hydrated = try await persistence.hydrate(sessionId: "target")
        #expect(hydrated.forkRecord?.phase == .ready)
        #expect(hydrated.forkRecord?.mechanism == .transcriptTransfer)
        #expect(hydrated.forkRecord?.contextDeliveryPending == true)

        try await persistence.clearForkContextDeliveryPending(targetSessionID: "target")
        #expect(try await persistence.loadFork(targetSessionID: "target")?.contextDeliveryPending == false)
    }

    @Test("fork point and its outcome persist, and a later finalize without one keeps it",
          arguments: [
              ACPSessionForkPoint.Outcome.matched(.init(boundary: .message, messageId: "m1", matchedBy: .id)),
              .unmatched(.notFound)
          ])
    func forkPointRoundTrip(outcome: ACPSessionForkPoint.Outcome) async throws {
        let persistence = ACPSessionPersistence(path: temporaryPath())
        let point = ACPSessionForkPoint(
            target: .init(messageId: "m1", messageFingerprint: "sha256:abc", messageOccurrence: 2),
            boundary: .message
        )
        var initial = forkRecord(target: "target", phase: .negotiatingNative, mechanism: nil)
        initial.forkPoint = point
        try await persistence.createFork(session: targetRow(id: "target"), messages: [], record: initial)
        #expect(try await persistence.loadFork(targetSessionID: "target")?.forkPoint?.target == point.target)

        var resolved = point
        resolved.outcome = outcome
        try await persistence.finalizeFork(
            targetSessionID: "target", mechanism: .transcriptTransfer, remoteSessionID: nil, forkPoint: resolved
        )
        let hydrated = try await persistence.hydrate(sessionId: "target")
        #expect(hydrated.forkRecord?.forkPoint?.outcome == outcome)
        #expect(hydrated.forkRecord?.contextDeliveryPending == true)

        try await persistence.finalizeFork(
            targetSessionID: "target", mechanism: .transcriptTransfer, remoteSessionID: nil, forkPoint: nil
        )
        #expect(try await persistence.loadFork(targetSessionID: "target")?.forkPoint == resolved)
    }

    @Test("a damaged fork point blob loads as no fork point", arguments: ["{not json", #"{"target":{}}"#])
    func corruptForkPointLoadsAsNil(blob: String) throws {
        let store = try ACPSessionStore(path: temporaryPath())
        let record = forkRecord(target: "target", phase: .ready, mechanism: .transcriptTransfer)
        try store.createFork(session: targetRow(id: "target"), messages: [], record: record)
        try store.db.exec("UPDATE session_forks SET fork_point = ?", bindings: [blob])

        let loaded = try #require(try store.loadFork(targetSessionID: "target"))
        #expect(loaded.forkPoint == nil)
        #expect(loaded == record)
    }

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-fork-\(UUID()).sqlite").path
    }

    private func targetRow(id: String) -> ACPSessionRow {
        .init(
            id: id, agentId: "codex", title: "Source (fork)",
            titleSource: .generated, currentModel: nil, currentMode: nil,
            autoRun: false, createdAt: 1, updatedAt: 1, lastOpenedAt: 1,
            archived: false
        )
    }

    private func forkRecord(
        target: String,
        phase: ACPSessionForkCreationPhase,
        mechanism: ACPSessionForkMechanism?
    ) -> ACPSessionForkRecord {
        .init(
            targetSessionID: target,
            sourceSessionID: "source",
            sourceAgentID: "claude",
            sourceBoundarySequence: 2,
            inheritedMessageCount: 1,
            phase: phase,
            mechanism: mechanism,
            contextDeliveryPending: mechanism == .transcriptTransfer
        )
    }
}
