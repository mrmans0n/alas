import Foundation
import Testing
@testable import Alas

@Suite("ACPLaunchCatalog")
struct ACPLaunchCatalogTests {
    @Test("every entry maps to a known AgentBuiltins id")
    func entriesMatchBuiltins() {
        let builtinIds = Set(AgentBuiltins.catalog.map(\.id))
        for spec in ACPLaunchCatalog.specs {
            #expect(builtinIds.contains(spec.agentID), "no AgentBuiltins entry for \(spec.agentID)")
        }
    }

    @Test("claude, gemini, opencode, cursor-agent, codex, copilot, pi are configured")
    func catalogCoverage() {
        let ids = Set(ACPLaunchCatalog.specs.map(\.agentID))
        #expect(ids.contains("claude"))
        #expect(ids.contains("gemini"))
        #expect(ids.contains("opencode"))
        #expect(ids.contains("cursor-agent"))
        #expect(ids.contains("codex"))
        #expect(ids.contains("copilot"))
        #expect(ids.contains("pi"))
    }
}
