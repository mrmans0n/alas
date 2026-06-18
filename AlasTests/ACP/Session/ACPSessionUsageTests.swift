import Testing
import Foundation
@testable import Alas

@MainActor
@Suite("ACPSession usage")
struct ACPSessionUsageTests {
    @Test("usage_update sets contextUsage and touches no transcript rows")
    func setsUsage() {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let touched = session.apply(.usageUpdate(.init(used: 5000, size: 200000, cost: nil)))
        #expect(touched.isEmpty)
        #expect(session.contextUsage == .init(used: 5000, size: 200000, cost: nil))
    }

    @Test("size <= 0 leaves contextUsage nil")
    func ignoresZeroSize() {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        _ = session.apply(.usageUpdate(.init(used: 10, size: 0, cost: nil)))
        #expect(session.contextUsage == nil)
    }

    @Test("currentModelDisplayName resolves id to model name")
    func displayName() {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        _ = session.apply(.availableModelsUpdate([.init(id: "opus", name: "Claude Opus")]))
        _ = session.apply(.currentModelUpdate(modelId: "opus"))
        #expect(session.currentModelDisplayName == "Claude Opus")
    }
}
