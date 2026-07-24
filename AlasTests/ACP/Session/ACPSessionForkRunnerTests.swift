import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP session fork context delivery")
struct ACPSessionForkRunnerTests {
    @Test("fork context serializes the inherited conversation")
    func forkContextSerializesInheritedConversation() {
        let context = ACPTranscriptMarkdown.forkContext(
            sourceAgentID: "claude",
            messages: [
                .user(id: UUID(), text: "Question", attachments: []),
                .agent(id: UUID(), StreamingText("Answer"))
            ]
        )

        #expect(context?.contains("The conversation below was imported from claude.") == true)
        #expect(context?.contains("## You\n\nQuestion") == true)
        #expect(context?.contains("## claude\n\nAnswer") == true)
    }

    @Test("first prompt sends inherited context privately and clears it durably")
    func firstPromptDeliversPrivateContext() async throws {
        let (runner, mock, session, persistence) = try await makeRunner()
        mock.script(method: "session/prompt") { _ in Data("null".utf8) }

        runner.sendNow(blocks: [.text("Continue")], queuedItemId: nil)

        try await waitUntil {
            mock.sent.contains { $0.method == "session/prompt" }
                && session.forkRecord?.contextDeliveryPending == false
        }
        await runner.flushPersistence()

        let request = try #require(mock.sent.first { $0.method == "session/prompt" })
        let promptBlocks = try #require(request.params as? ACPSessionPromptParams).prompt
        #expect(promptBlocks == [
            .text(try #require(ACPTranscriptMarkdown.forkContext(
                sourceAgentID: "claude",
                messages: Array(session.transcript.messages.prefix(2))
            ))),
            .text("Continue")
        ])
        #expect(session.transcript.messages.count == 3)
        #expect(try await persistence.loadFork(targetSessionID: session.id)?.contextDeliveryPending == false)
    }

    @Test("failed first prompt keeps private context pending for a queue retry")
    func failedFirstPromptKeepsContextPending() async throws {
        let (runner, mock, session, persistence) = try await makeRunner()
        mock.script(method: "session/prompt") { _ in throw ACPClientError.notRunning }
        session.enqueue(blocks: [.text("Continue")])
        runner.persistQueue()

        runner.flushQueueIfIdle()
        try await waitUntil { session.queue.first?.lastError != nil }

        #expect(session.forkRecord?.contextDeliveryPending == true)
        #expect(try await persistence.loadFork(targetSessionID: session.id)?.contextDeliveryPending == true)
        #expect(session.transcript.messages.count == 3)
        #expect(session.transcript.messages.allSatisfy {
            ACPTranscriptMarkdown.messageBody($0)?.contains("The conversation below was imported") != true
        })

        mock.script(method: "session/prompt") { _ in Data("null".utf8) }
        session.queue[0].lastError = nil
        runner.flushQueueIfIdle()
        try await waitUntil { session.queue.isEmpty }

        let userMessages = session.transcript.messages.filter {
            if case .user = $0 { return true }
            return false
        }
        #expect(userMessages.count == 2)
    }

    private func makeRunner() async throws -> (
        ACPSessionRunner,
        ACPMockClient,
        ACPSession,
        ACPSessionPersistence
    ) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-fork-runner-\(UUID()).sqlite").path
        let persistence = ACPSessionPersistence(path: path)
        let inherited = [
            ACPMessage.user(id: UUID(), text: "Question", attachments: []),
            ACPMessage.agent(id: UUID(), StreamingText("Answer"))
        ]
        let row = ACPSessionRow(
            id: "target", agentId: "codex", title: "Fork",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false
        )
        let fork = ACPSessionForkRecord(
            targetSessionID: row.id,
            sourceSessionID: "source",
            sourceAgentID: "claude",
            sourceBoundarySequence: 2,
            inheritedMessageCount: 2,
            phase: .ready,
            mechanism: .transcriptTransfer,
            contextDeliveryPending: true
        )
        let stored = try ACPSessionForkSnapshot(
            sourceBoundarySequence: 2,
            messages: [
                .init(role: ACPSessionForkConversationMessage.Role.user, text: "Question"),
                .init(role: ACPSessionForkConversationMessage.Role.agent, text: "Answer")
            ]
        ).copiedMessages(targetSessionID: row.id, createdAt: 0)
        try await persistence.createFork(session: row, messages: stored, record: fork)

        let session = ACPSession(id: row.id, agentId: row.agentId, worktreeId: "wt", title: row.title)
        session.agentState = .ready
        session.forkRecord = fork
        for message in inherited {
            session.transcript.appendMessage(message)
        }
        let mock = ACPMockClient()
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: nil,
            sessionId: session.id,
            worktreePath: FileManager.default.temporaryDirectory.path,
            persistence: persistence
        )
        return (runner, mock, session, persistence)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw TimeoutError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private struct TimeoutError: Error {}
}
