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

    @Test("pi is the only external MCP-injection adapter")
    func piIsExternal() throws {
        let pi = try #require(ACPLaunchCatalog.spec(for: "pi"))
        guard case let .external(hint) = pi.mcpInjection else {
            Issue.record("expected .external for pi")
            return
        }
        #expect(hint.contains("alas CLI"))
        #expect(hint.contains("pi-mcp-adapter"))
        for spec in ACPLaunchCatalog.specs where spec.agentID != "pi" {
            #expect(spec.mcpInjection == .sessionNew, "\(spec.agentID) should default to sessionNew")
        }
    }

    @Test("mergingExtraEnv overlays and preserves everything else")
    func mergingExtraEnv() throws {
        let base = try #require(ACPLaunchCatalog.spec(for: "pi"))
        let merged = base.mergingExtraEnv(["ALAS_SESSION_ID": "s1", "PATH": "/x"])
        #expect(merged.extraEnv["ALAS_SESSION_ID"] == "s1")
        #expect(merged.extraEnv["PATH"] == "/x")
        #expect(merged.agentID == base.agentID)
        #expect(merged.command == base.command)
        #expect(merged.mcpInjection == base.mcpInjection)
    }
}
