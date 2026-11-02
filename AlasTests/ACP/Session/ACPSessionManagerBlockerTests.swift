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

    @Test("only a blocking question contributes its own id",
          arguments: [ACPUserInputRequest.Delivery.blocking, .optional])
    func reportsQuestionAndPlanKeys(delivery: ACPUserInputRequest.Delivery) throws {
        let manager = try makeManager()
        let session = manager.createSession(id: "s", agentId: "codex", autoRunDefault: false)
        let params = try JSONDecoder().decode(
            ACPElicitationRequestParams.self,
            from: Data(codexAsyncFormJSON(
                meta: delivery == .blocking ? "null" : #"{"codex":{"delivery":"async"}}"#
            ).utf8)
        )
        let request = try #require(ACPUserInputRequest.elicitation(.init(id: .number(5), params: params)))
        session.transcript.pendingUserInputs.append(request)

        let keys = manager.blockedRequestKeys(for: "s")

        #expect(keys.contains(ACPChildBlocker.requestKey(request.id)) == (delivery == .blocking))
        // A different request's key must not appear.
        #expect(!keys.contains(ACPChildBlocker.requestKey(UUID())))
    }
}
