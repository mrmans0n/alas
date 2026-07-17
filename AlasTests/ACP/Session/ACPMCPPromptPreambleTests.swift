import Testing
@testable import Alas

@Suite("ACPMCPPromptPreamble")
struct ACPMCPPromptPreambleTests {
    @Test("nothing attached produces no preamble")
    func nothingAttached() {
        #expect(ACPMCPPromptPreamble.text(
            builtInInjected: false, isDelegated: false, userServerNames: []) == nil)
    }

    @Test("root built-in preamble names every tool and the search hint")
    func rootBuiltIn() throws {
        let text = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: true, isDelegated: false, userServerNames: []))
        #expect(text.hasPrefix("<alas-workspace-context>"))
        #expect(text.hasSuffix("</alas-workspace-context>"))
        for tool in ACPMCPPromptPreamble.builtInToolNames {
            #expect(text.contains(tool), "missing tool \(tool)")
        }
        #expect(text.contains("tool search"))
        #expect(text.contains("\"alas\""))
        #expect(!text.contains("Additional MCP servers"))
    }

    @Test("delegated preamble omits session_new and explains delegation")
    func delegated() throws {
        let text = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: true, isDelegated: true, userServerNames: []))
        #expect(!text.contains("session_new"))
        #expect(text.contains("delegated by a parent session"))
        #expect(text.contains("session_send"))
    }

    @Test("user servers are listed by name")
    func userServers() throws {
        let text = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: false, isDelegated: false,
            userServerNames: ["linear", "sentry"]))
        #expect(text.contains("Additional MCP servers attached: linear, sentry."))
        #expect(!text.contains("\"alas\""))
    }

    @Test("built-in plus user servers renders both sections")
    func builtInPlusUserServers() throws {
        let text = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: true, isDelegated: false,
            userServerNames: ["linear"]))
        #expect(text.contains("\"alas\""))
        #expect(text.contains("Additional MCP servers attached: linear."))
    }

    @Test("tool name list matches the Rust server inventory")
    func toolNameInventory() {
        // Mirrors `tool_definitions` in AlasCLI/crates/alas/src/mcp.rs.
        // The Rust unit test asserting name order is the authority; update
        // BOTH when tools change.
        #expect(ACPMCPPromptPreamble.builtInToolNames == [
            "open", "notify",
            "session_list", "session_new", "session_send",
            "worktree_list", "worktree_switch", "worktree_new", "worktree_delete",
            "review", "review_comments", "review_reply", "review_resolve",
            "review_comment_add", "review_finish",
        ])
    }
}
