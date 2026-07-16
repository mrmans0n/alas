import Foundation
import Testing
@testable import Alas

@Suite("ACP orchestration store")
struct ACPOrchestrationStoreTests {
    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-orchestration-\(UUID().uuidString).sqlite")
            .path
    }

    private func newRecord(
        childSessionId: String = "child",
        parentSessionId: String = "parent",
        request: ACPDelegatedWorktreeRequest = .current(worktreeId: "parent-worktree")
    ) -> ACPDelegationRecord {
        .init(
            childSessionId: childSessionId,
            parentSessionId: parentSessionId,
            projectId: "project",
            parentWorktreeId: "parent-worktree",
            childWorktreeId: request.worktreeId,
            agentId: "codex",
            worktreeRequest: request,
            pendingInitialPrompt: "Investigate the parser.",
            phase: .starting,
            failureMessage: nil,
            createdAt: 100,
            updatedAt: 100
        )
    }

    @Test("creates schema and preserves delegation records across reopen")
    func persistsDelegationAcrossReopen() throws {
        let path = temporaryPath()
        let record = newRecord()

        do {
            let store = try ACPOrchestrationStore(path: path)
            #expect(try store.currentSchemaVersion() == ACPOrchestrationStore.targetSchemaVersion)
            try store.insert(record)
            #expect(try store.delegation(childSessionId: "child") == record)
            #expect(try store.children(parentSessionId: "parent") == [record])
            #expect(try store.parent(childSessionId: "child") == record)
        }

        let reopened = try ACPOrchestrationStore(path: path)
        #expect(try reopened.delegation(childSessionId: "child") == record)
    }

    @Test("round trips every worktree request")
    func roundTripsWorktreeRequests() throws {
        let path = temporaryPath()
        let store = try ACPOrchestrationStore(path: path)
        let requests: [ACPDelegatedWorktreeRequest] = [
            .current(worktreeId: "current"),
            .existing(worktreeId: "existing"),
            .new(
                branch: "delegate/parser",
                base: "origin/main",
                destinationPath: "/tmp/alas-delegate-parser",
                optimisticId: "optimistic"
            ),
        ]

        for (index, request) in requests.enumerated() {
            let record = newRecord(
                childSessionId: "child-\(index)",
                request: request
            )
            try store.insert(record)
            #expect(try store.delegation(childSessionId: record.childSessionId) == record)
        }
    }

    @Test("updates creation phase, worktree, failure, and pending prompt")
    func updatesDelegationLifecycle() throws {
        let path = temporaryPath()
        let store = try ACPOrchestrationStore(path: path)
        try store.insert(newRecord(request: .new(
            branch: "delegate/parser",
            base: nil,
            destinationPath: "/tmp/alas-delegate-parser",
            optimisticId: "optimistic"
        )))

        try store.updateChildWorktree(
            childSessionId: "child",
            worktreeId: "real-worktree",
            phase: .starting,
            updatedAt: 110
        )
        try store.updatePhase(
            childSessionId: "child",
            phase: .failed,
            failureMessage: "Could not create worktree.",
            updatedAt: 120
        )
        try store.clearPendingInitialPrompt(childSessionId: "child", updatedAt: 130)

        let record = try #require(try store.delegation(childSessionId: "child"))
        #expect(record.childWorktreeId == "real-worktree")
        #expect(record.phase == .failed)
        #expect(record.failureMessage == "Could not create worktree.")
        #expect(record.pendingInitialPrompt == nil)
        #expect(record.updatedAt == 130)
    }

    @Test("rejects a duplicate child session id")
    func rejectsDuplicateChild() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        try store.insert(newRecord())

        #expect(throws: ACPOrchestrationStore.Error.duplicateChildSession("child")) {
            try store.insert(newRecord(parentSessionId: "different-parent"))
        }
    }

    @Test("stores and atomically claims a delegated message")
    func claimsMessageOnceAcrossHandles() throws {
        let path = temporaryPath()
        let a = try ACPOrchestrationStore(path: path)
        let b = try ACPOrchestrationStore(path: path)
        let message = ACPDelegatedMessage(
            id: "message",
            sourceSessionId: "parent",
            targetSessionId: "child",
            prompt: "Please check malformed UTF-8.",
            createdAt: 100
        )
        try a.enqueue(message)

        let claimedByA = try a.claimMessage(
            id: "message",
            instanceId: "instance-a",
            token: "token-a",
            now: 110,
            staleAfter: 30
        )
        let claimedByB = try b.claimMessage(
            id: "message",
            instanceId: "instance-b",
            token: "token-b",
            now: 110,
            staleAfter: 30
        )

        #expect(claimedByA?.message == message)
        #expect(claimedByB == nil)
        #expect(try b.claimedMessage(id: "message")?.instanceId == "instance-a")
    }

    @Test("messages with the same timestamp preserve insertion order")
    func messagesWithSameTimestampPreserveInsertionOrder() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        try store.enqueue(.init(
            id: "z-message",
            sourceSessionId: "parent",
            targetSessionId: "child",
            prompt: "first",
            createdAt: 100
        ))
        try store.enqueue(.init(
            id: "a-message",
            sourceSessionId: "parent",
            targetSessionId: "child",
            prompt: "second",
            createdAt: 100
        ))

        #expect(try store.pendingMessages(targetSessionId: "child").map(\.id) == ["z-message", "a-message"])
    }

    @Test("released inbox claim can be immediately reclaimed")
    func releasesMessageClaim() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        let message = ACPDelegatedMessage(
            id: "message",
            sourceSessionId: "parent",
            targetSessionId: "child",
            prompt: "Please retry delivery.",
            createdAt: 100
        )
        try store.enqueue(message)
        let claim = try #require(try store.claimMessage(
            id: "message",
            instanceId: "mirror-instance",
            token: "mirror-token",
            now: 110,
            staleAfter: 60
        ))

        try store.releaseMessageClaim(id: message.id, claim: claim.claim)

        #expect(try store.claimMessage(
            id: "message",
            instanceId: "writer-instance",
            token: "writer-token",
            now: 110,
            staleAfter: 60
        )?.message == message)
    }

    @Test("expired inbox claim can be reclaimed and delivery removes message")
    func reclaimsExpiredMessageAndRemovesItAfterDelivery() throws {
        let store = try ACPOrchestrationStore(path: temporaryPath())
        let message = ACPDelegatedMessage(
            id: "message",
            sourceSessionId: "child",
            targetSessionId: "parent",
            prompt: "The parser accepts malformed UTF-8.",
            createdAt: 100
        )
        try store.enqueue(message)
        _ = try store.claimMessage(
            id: "message",
            instanceId: "stale-instance",
            token: "stale-token",
            now: 100,
            staleAfter: 10
        )

        let claim = try #require(try store.claimMessage(
            id: "message",
            instanceId: "new-instance",
            token: "new-token",
            now: 111,
            staleAfter: 10
        ))
        try store.removeDeliveredMessage(id: "message", claim: claim.claim)

        #expect(try store.pendingMessages(targetSessionId: "parent") == [])
    }
}
