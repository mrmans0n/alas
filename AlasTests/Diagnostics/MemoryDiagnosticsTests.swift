import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("MemoryDiagnostics")
struct MemoryDiagnosticsTests {
    @Test("snapshot rolls up per-session accounting across managers")
    func rollup() {
        let store1 = try? ACPSessionStore(path: NSTemporaryDirectory() + "diag1-\(UUID()).sqlite")
        let store2 = try? ACPSessionStore(path: NSTemporaryDirectory() + "diag2-\(UUID()).sqlite")
        let m1 = ACPSessionManager(worktreeId: "w1", worktreePath: "/tmp", store: store1!)
        let m2 = ACPSessionManager(worktreeId: "w2", worktreePath: "/tmp", store: store2!)
        let s1 = m1.createSession(agentId: "claude")
        s1.transcript.messages.append(.user(id: UUID(), text: "abc", attachments: []))
        let s2 = m2.createSession(agentId: "claude")
        s2.transcript.messages.append(.agent(id: UUID(), StreamingText("hello world")))

        let diag = MemoryDiagnostics()
        diag.attach(manager: m1)
        diag.attach(manager: m2)

        let snap = diag.snapshot()
        #expect(snap.sessionCount == 2)
        #expect(snap.transcriptBytes == 14)
        #expect(snap.perSession.count == 2)
        #expect(snap.physFootprint > 0)
    }

    @Test("detach removes the manager from rollup")
    func detach() {
        let store = try? ACPSessionStore(path: NSTemporaryDirectory() + "diag3-\(UUID()).sqlite")
        let m = ACPSessionManager(worktreeId: "w1", worktreePath: "/tmp", store: store!)
        _ = m.createSession(agentId: "claude")
        let diag = MemoryDiagnostics()
        diag.attach(manager: m)
        diag.detach(worktreeId: "w1")
        #expect(diag.snapshot().sessionCount == 0)
    }
}
