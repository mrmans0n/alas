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

    @Test("cli mode swaps MCP wording for alas CLI commands")
    func cliMode() throws {
        let text = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: true, isDelegated: false, userServerNames: [],
            mode: .cli(adapterInstalled: false)))
        #expect(text.contains("alas open"))
        #expect(text.contains("alas wt list"))
        #expect(text.contains("alas review"))
        #expect(text.contains("alas session"))
        #expect(!text.contains("MCP server \"alas\""))
        // no adapter → no tool-search hint
        #expect(!text.contains("tool search"))
    }

    @Test("cli mode delegated variant restricts session commands")
    func cliModeDelegated() throws {
        let text = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: true, isDelegated: true, userServerNames: [],
            mode: .cli(adapterInstalled: false)))
        #expect(text.contains("alas session send"))
        #expect(!text.contains("alas session new"))
        #expect(text.contains("delegated by a parent session"))
    }

    @Test("cli mode user servers depend on adapter state")
    func cliModeUserServers() throws {
        let installed = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: false, isDelegated: false, userServerNames: ["linear"],
            mode: .cli(adapterInstalled: true)))
        #expect(installed.contains("mcp()"))
        #expect(installed.contains("pi-mcp-adapter"))
        #expect(installed.contains("linear"))

        let missing = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: false, isDelegated: false, userServerNames: ["linear"],
            mode: .cli(adapterInstalled: false)))
        #expect(missing.contains("cannot be reached"))
        #expect(missing.contains("pi-mcp-adapter"))
    }

    @Test("default mode is unchanged mcp wording")
    func defaultModeUnchanged() throws {
        let text = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: true, isDelegated: false, userServerNames: []))
        #expect(text.contains("MCP server \"alas\""))
    }
}
