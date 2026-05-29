import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSession.HydrationState")
struct ACPSessionHydrationStateTests {
    @Test("init defaults to .ready")
    func defaultsToReady() {
        let s = ACPSession(id: "s1", agentId: "claude", worktreeId: "wt", title: "t")
        #expect(s.hydrationState == .ready)
    }

    @Test("explicit loading init")
    func explicitLoading() {
        let s = ACPSession(id: "s1", agentId: "claude", worktreeId: "wt",
                           title: "t", hydrationState: .loading)
        #expect(s.hydrationState == .loading)
    }

    @Test("state transitions")
    func transitions() {
        let s = ACPSession(id: "s1", agentId: "claude", worktreeId: "wt",
                           title: "t", hydrationState: .loading)
        s.hydrationState = .ready
        #expect(s.hydrationState == .ready)
        s.hydrationState = .failed("boom")
        if case .failed(let m) = s.hydrationState { #expect(m == "boom") }
        else { #expect(Bool(false), "expected .failed") }
    }
}
