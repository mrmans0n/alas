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

    @Test("heuristic picks known id (effort) when present")
    func heuristicKnownId() {
        let opts = [
            ACPConfigOption(id: "effort", name: "Effort", currentValue: "medium",
                            options: [ACPConfigOptionItem(id: "medium", name: "Medium")])
        ]
        #expect(ACPAgentProfiles.heuristicThinkingId(from: opts) == "effort")
    }

    @Test("heuristic picks ThoughtLevel-category option when no known id")
    func heuristicByCategory() {
        let opts = [
            ACPConfigOption(id: "speed", name: "Speed", currentValue: "fast",
                            options: [ACPConfigOptionItem(id: "fast", name: "Fast")]),
            ACPConfigOption(id: "brainpower", name: "Brainpower", category: "ThoughtLevel",
                            currentValue: "high",
                            options: [ACPConfigOptionItem(id: "high", name: "High")])
        ]
        #expect(ACPAgentProfiles.heuristicThinkingId(from: opts) == "brainpower")
    }

    @Test("heuristic prefers known id over ThoughtLevel category")
    func heuristicKnownIdWins() {
        let opts = [
            ACPConfigOption(id: "brainpower", name: "Brainpower", category: "ThoughtLevel",
                            currentValue: "high",
                            options: [ACPConfigOptionItem(id: "high", name: "High")]),
            ACPConfigOption(id: "thinking", name: "Thinking", currentValue: "deep",
                            options: [ACPConfigOptionItem(id: "deep", name: "Deep")])
        ]
        #expect(ACPAgentProfiles.heuristicThinkingId(from: opts) == "thinking")
    }

    @Test("heuristic returns nil when nothing matches")
    func heuristicNoMatch() {
        let opts = [
            ACPConfigOption(id: "speed", name: "Speed", currentValue: "fast",
                            options: [ACPConfigOptionItem(id: "fast", name: "Fast")])
        ]
        #expect(ACPAgentProfiles.heuristicThinkingId(from: opts) == nil)
    }
}
