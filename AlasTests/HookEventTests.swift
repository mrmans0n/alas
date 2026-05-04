import Testing
import Foundation
@testable import Alas

struct HookEventTests {
    @Test func decodesStop() throws {
        let json = #"{"session_id":"abc","kind":"stop","timestamp":"2026-05-03T12:00:00Z","summary":"Done."}"#
        let ev = try HookEvent.decode(json.data(using: .utf8)!)
        #expect(ev.sessionId == "abc")
        #expect(ev.kind == "stop")
        #expect(ev.summary == "Done.")
    }

    @Test func decodesAwaitingNoSummary() throws {
        let json = #"{"session_id":"x","kind":"awaiting","timestamp":"2026-05-03T12:00:00Z"}"#
        let ev = try HookEvent.decode(json.data(using: .utf8)!)
        #expect(ev.summary == nil)
    }
}
