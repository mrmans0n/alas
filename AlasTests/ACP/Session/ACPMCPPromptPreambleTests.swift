import Foundation
import Testing
@testable import Alas

@Suite("ACPMCPPromptPreamble")
struct ACPMCPPromptPreambleTests {
    @Test("active gg context uses loaded stack details")
    func activeGGContextWithStack() {
        let context = GGWorktreeContext.active(stackName: "loaded-name")
        #expect(AppState.ggPreambleSignal(
            context: context,
            snapshot: RightPaneGGStackSnapshot(
                stack: Self.stack,
                loadState: .loaded
            )
        ) == .stack(name: "loaded-name", entryCount: 3))
    }

    @Test("active gg context without current loaded metadata stays generic")
    func activeGGContextWithoutCurrentLoadedMetadata() {
        let context = GGWorktreeContext.active(stackName: "loaded-name")
        let states: [GGStackLoadState] = [
            .inactive,
            .loading,
            .empty,
            .failed("boom"),
        ]
        for loadState in states {
            #expect(AppState.ggPreambleSignal(
                context: context,
                snapshot: RightPaneGGStackSnapshot(
                    stack: Self.stack,
                    loadState: loadState
                )
            ) == .generic)
        }
        #expect(AppState.ggPreambleSignal(context: context, snapshot: nil) == .generic)
        #expect(AppState.ggPreambleSignal(
            context: context,
            snapshot: RightPaneGGStackSnapshot(stack: nil, loadState: .loaded)
        ) == .generic)
    }

    @Test("inactive gg context produces no gg preamble")
    func inactiveGGContext() {
        let stack = GGStack(
            name: "stale",
            base: "main",
            totalCommits: 1,
            syncedCommits: 1,
            currentPosition: nil,
            behindBase: nil,
            entries: []
        )
        #expect(AppState.ggPreambleSignal(
            context: .inactive(reason: .policyOff),
            snapshot: RightPaneGGStackSnapshot(
                stack: stack,
                loadState: .loaded
            )
        ) == .none)
    }

    private static let stack = GGStack(
        name: "loaded-name",
        base: "main",
        totalCommits: 3,
        syncedCommits: 2,
        currentPosition: nil,
        behindBase: nil,
        entries: []
    )

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

    @Test("mcp mode notes the alas CLI fallback for blocked servers")
    func mcpMentionsCLIFallback() {
        let text = ACPMCPPromptPreamble.text(
            builtInInjected: true,
            isDelegated: false,
            userServerNames: [],
            mode: .mcp
        )
        #expect(text?.contains("alas") == true)
        #expect(text?.contains("`alas` CLI") == true)
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
            mode: .cli(serverAvailability: .notInstalled)))
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
            mode: .cli(serverAvailability: .notInstalled)))
        #expect(text.contains("alas session send"))
        #expect(!text.contains("alas session new"))
        #expect(text.contains("delegated by a parent session"))
    }

    @Test("cli mode user servers depend on adapter server availability")
    func cliModeUserServers() throws {
        let available = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: false, isDelegated: false, userServerNames: ["linear"],
            mode: .cli(serverAvailability: .available)))
        #expect(available.contains("mcp()"))
        #expect(available.contains("pi-mcp-adapter"))
        #expect(available.contains("linear"))

        let notInstalled = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: false, isDelegated: false, userServerNames: ["linear"],
            mode: .cli(serverAvailability: .notInstalled)))
        #expect(notInstalled.contains("cannot be reached"))
        #expect(notInstalled.contains("pi-mcp-adapter"))

        let syncFailed = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: false, isDelegated: false, userServerNames: ["linear"],
            mode: .cli(serverAvailability: .syncFailed)))
        #expect(syncFailed.contains("linear"))
        #expect(syncFailed.contains("could not write .pi/mcp.json"))

        let userManaged = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: false, isDelegated: false, userServerNames: ["linear"],
            mode: .cli(serverAvailability: .userManaged)))
        #expect(userManaged.contains("linear"))
        #expect(userManaged.contains("existing .pi/mcp.json"))
        #expect(userManaged.contains("Alas did not add them"))

        let noServers = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: true, isDelegated: false, userServerNames: [],
            mode: .cli(serverAvailability: .noServers)))
        #expect(!noServers.contains("Additional MCP servers"))
        #expect(!noServers.contains("This project configures"))
    }

    @Test("default mode is unchanged mcp wording")
    func defaultModeUnchanged() throws {
        let text = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: true, isDelegated: false, userServerNames: []))
        #expect(text.contains("MCP server \"alas\""))
    }

    @Test func ggStackContextRendersNamedForm() throws {
        let text = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: true, isDelegated: false, userServerNames: [], mode: .mcp,
            ggStack: .init(stackName: "auth-flow", entryCount: 3, ggMCPAttached: true)
        ))
        #expect(text.contains("gg stacked-diffs stack \"auth-flow\" (3 entries)"))
        #expect(text.contains("gg absorb"))
        #expect(text.contains("gg sync"))
        #expect(text.contains("never push stack branches directly with `git push`"))
        #expect(text.contains("git-gud")) // MCP mention when attached
    }

    @Test func ggStackContextGenericFormAndNoMCPMention() throws {
        let text = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: true, isDelegated: false, userServerNames: [], mode: .cli(serverAvailability: .available),
            ggStack: .init(stackName: nil, entryCount: nil, ggMCPAttached: false)
        ))
        #expect(text.contains("gg stacked-diffs"))
        #expect(!text.contains("\"auth-flow\""))
        #expect(!text.contains("git-gud"))
    }

    @Test func stackOnlyPreambleIsEmitted() throws {
        // No built-in, no user servers — but a stack context alone still
        // produces a preamble. It must not claim MCP tools are attached.
        let text = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: false, isDelegated: false, userServerNames: [], mode: .mcp,
            ggStack: .init(stackName: "s", entryCount: 1, ggMCPAttached: false)
        ))
        #expect(!text.contains("MCP servers are attached"))
        #expect(text.contains("gg stacked-diffs"))
    }

    @Test func nilGGStackKeepsExistingBehavior() {
        #expect(ACPMCPPromptPreamble.text(
            builtInInjected: false, isDelegated: false, userServerNames: [], mode: .mcp
        ) == nil)
    }

    @Test func issueContextRendersInMCPAndCLIPreambles() throws {
        let issue = IssuePreambleContext(
            title: "Prevent parser crash",
            url: URL(string: "https://github.com/acme/app/issues/42")!,
            providerLabel: "GitHub",
            displayReference: "#42"
        )

        let mcp = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: false, isDelegated: false, userServerNames: [], issue: issue
        ))
        let cli = try #require(ACPMCPPromptPreamble.text(
            builtInInjected: false, isDelegated: false, userServerNames: [],
            mode: .cli(serverAvailability: .noServers), issue: issue
        ))

        let expected = "This worktree is attached to GitHub issue #42, \"Prevent parser crash\": https://github.com/acme/app/issues/42"
        #expect(mcp.contains(expected))
        #expect(cli.contains(expected))
    }
}
