import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP session fork manager")
struct ACPSessionForkManagerTests {
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

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-fork-manager-\(UUID()).sqlite").path
    }
}
