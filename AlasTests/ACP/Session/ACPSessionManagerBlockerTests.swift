import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP session manager blocker keys")
struct ACPSessionManagerBlockerTests {
    private func makeManager() throws -> ACPSessionManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-blocker-\(UUID().uuidString).sqlite")
        return ACPSessionManager(
            worktreeId: "worktree",
            worktreePath: "/tmp/worktree",
            store: try ACPSessionStore(path: url.path),
            setupEvaluator: { _ in .ready }
        )
    }

    @Test("no keys for an unknown or unblocked session")
    func emptyWhenNothingBlocked() throws {
        let manager = try makeManager()
        #expect(manager.blockedRequestKeys(for: "nope").isEmpty)
        _ = manager.createSession(id: "s", agentId: "codex", autoRunDefault: false)
        #expect(manager.blockedRequestKeys(for: "s").isEmpty)
    }

    @Test("pending questions and plans contribute their own ids")
    func reportsQuestionAndPlanKeys() throws {
        let manager = try makeManager()
        let session = manager.createSession(id: "s", agentId: "codex", autoRunDefault: false)
        let questionId = UUID()
        session.transcript.pendingUserInputs.append(
            .init(
                id: questionId,
                source: .cursor(
                    id: .number(5),
                    params: ACPQuestionRequestParams(toolCallId: "tool", title: "Pick one", questions: [])
                ),
                title: "Pick one",
                message: "pick one",
                fields: [],
                mode: .form
            )
        )

        let keys = manager.blockedRequestKeys(for: "s")

        #expect(keys.contains(ACPChildBlocker.requestKey(questionId)))
        // A different request's key must not appear.
        #expect(!keys.contains(ACPChildBlocker.requestKey(UUID())))
    }
}
