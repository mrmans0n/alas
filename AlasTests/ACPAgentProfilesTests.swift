import Foundation
import Testing
@testable import Alas

@Suite("ACPAgentProfiles")
struct ACPAgentProfilesTests {
    @Test("claude uses modes for Mode, effort configOption for Thinking")
    func claude() {
        let p = ACPAgentProfiles.routing(for: "claude")
        #expect(p.modeSource == .modes)
        #expect(p.thinkingSource == .configOption(id: "effort"))
        #expect(p.autoRun == .supported)
    }

    @Test("codex uses reasoning_effort for Thinking")
    func codex() {
        let p = ACPAgentProfiles.routing(for: "codex")
        #expect(p.modeSource == .modes)
        #expect(p.thinkingSource == .configOption(id: "reasoning_effort"))
        #expect(p.autoRun == .supported)
    }

    @Test("opencode uses modes (agents) for Mode, effort for Thinking")
    func opencode() {
        let p = ACPAgentProfiles.routing(for: "opencode")
        #expect(p.modeSource == .modes)
        #expect(p.thinkingSource == .configOption(id: "effort"))
        #expect(p.autoRun == .supported)
    }

    @Test("pi puts thinking in modes, has no Mode and ignores autoRun")
    func pi() {
        let p = ACPAgentProfiles.routing(for: "pi")
        #expect(p.modeSource == .none)
        #expect(p.thinkingSource == .modes)
        #expect(p.autoRun == .ignored)
    }

    @Test("unknown agent falls back to modes for Mode + heuristic Thinking")
    func unknown() {
        let p = ACPAgentProfiles.routing(for: "some-new-agent")
        #expect(p.modeSource == .modes)
        #expect(p.thinkingSource == .heuristic)
        #expect(p.autoRun == .supported)
    }
}
