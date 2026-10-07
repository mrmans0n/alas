import Combine
import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("Session summary activity")
struct SessionSummaryActivityTests {
    @Test(arguments: [
        "prompt allocation", "queue", "transcript streaming", "permission", "question", "retry",
        "recovery", "delegated work", "auto-run"
    ])
    func mutationEntryPointsSignalSynchronously(_ mutation: String) {
        let session = ACPSession(id: "activity", agentId: "codex", worktreeId: "w", title: "Activity")
        var signalled = false
        let observation = session.nextPromptActivity.sink { signalled = true }

        switch mutation {
        case "prompt allocation": _ = session.allocatePromptID()
        case "queue": session.enqueue(blocks: [.text("queued")])
        case "transcript streaming": session.apply(.agentMessageChunk(.text("streamed")))
        case "permission":
            session.transcript.pendingPermission = .init(
                id: .string("permission"),
                params: .init(sessionId: session.id, toolCall: .init(toolCallId: "tool"), options: [])
            )
        case "question":
            session.transcript.pendingQuestion = .init(
                id: .string("question"),
                params: .init(toolCallId: "tool", title: nil, questions: [])
            )
        case "retry":
            session.apply(.sessionInfoUpdate(.init(title: nil, metadata: AnyCodable([
                "codex": AnyCodable(["error": AnyCodable(["willRetry": AnyCodable(true)])])
            ]))))
        case "recovery": _ = session.beginConnectionRecovery()
        case "delegated work": session.registerSubagent(.init(subagentSessionId: "child"))
        default: session.autoRunEnabled = true
        }

        #expect(signalled)
        withExtendedLifetime(observation) {}
    }

    /// Agents send these after a turn ends; signalling would consume the turn's next-prompt offer.
    @Test(arguments: ["usage", "commands", "models", "mode", "model", "config", "title", "retry cleared"])
    func trailingMetadataUpdatesDoNotSignal(_ kind: String) {
        let session = ACPSession(id: "activity", agentId: "codex", worktreeId: "w", title: "Activity")
        var signalled = false
        let observation = session.nextPromptActivity.sink { signalled = true }

        switch kind {
        case "usage": session.apply(.usageUpdate(.init(used: 100, size: 1000, cost: nil)))
        case "commands": session.apply(.availableCommandsUpdate([]))
        case "models": session.apply(.availableModelsUpdate([]))
        case "mode": session.apply(.currentModeUpdate(modeId: "plan"))
        case "model": session.apply(.currentModelUpdate(modelId: "model"))
        case "config": session.apply(.sessionConfigOptionsUpdate([]))
        case "title": session.apply(.sessionInfoUpdate(.init(title: "Renamed")))
        default:
            session.apply(.sessionInfoUpdate(.init(title: nil, metadata: AnyCodable([
                "codex": AnyCodable(["error": AnyCodable(["willRetry": AnyCodable(false)])])
            ]))))
        }

        #expect(!signalled)
        withExtendedLifetime(observation) {}
    }

    @Test func goalMetadataSignalsOnlyWhenTheGoalChanges() {
        let session = ACPSession(id: "activity", agentId: "codex", worktreeId: "w", title: "Activity")
        var signals = 0
        let observation = session.nextPromptActivity.sink { signals += 1 }
        let goal = AnyCodable(["goal": AnyCodable(["objective": AnyCodable("Ship it")])])

        session.apply(.sessionInfoUpdate(.init(title: nil, metadata: goal)))
        #expect(signals == 1)
        session.apply(.sessionInfoUpdate(.init(title: nil, metadata: goal)))
        #expect(signals == 1)
        withExtendedLifetime(observation) {}
    }

    @Test func managerTeardownSignalsSynchronously() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ACPSessionStore(path: root.appendingPathComponent("session.sqlite").path)
        let manager = ACPSessionManager(worktreeId: "w", worktreePath: root.path, store: store)
        let session = manager.createSession(id: "teardown", agentId: "codex", autoRunDefault: false)
        var signalled = false
        let observation = session.nextPromptTeardown.sink { signalled = true }

        manager.closeSession(id: session.id)

        #expect(signalled)
        manager.shutdownBackgroundTasks()
        withExtendedLifetime(observation) {}
    }
}
