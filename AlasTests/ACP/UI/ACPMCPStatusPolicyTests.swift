import Testing
@testable import Alas

@Suite("ACPMCPStatusState")
struct ACPMCPStatusPolicyTests {
    @Test("does not display before an MCP attachment plan exists")
    func absentSummaryDoesNotDisplay() {
        #expect(ACPMCPStatusState(summary: nil, currentServers: []) == nil)
    }

    @Test("summarizes requested and skipped servers without secret values")
    func summarizesRequestedAndSkippedServers() {
        let token = "never-display-this"
        let summary = MCPAttachmentSummary(statuses: [
            .init(id: "0", name: "filesystem", transport: .stdio, disposition: .requested),
            .init(id: "1", name: "remote", transport: .http, disposition: .skipped(.missingVariable("MCP_TOKEN"))),
            .init(id: "2", name: "legacy", transport: .sse, disposition: .skipped(.unsupportedTransport))
        ], configurationFingerprint: MCPAttachmentPlanner.configurationFingerprint(for: []))

        let state = ACPMCPStatusState(summary: summary, currentServers: [])

        #expect(state?.requestedCount == 1)
        #expect(state?.skippedCount == 2)
        #expect(state?.rows.map(\.detail) == [
            "Requested",
            "Skipped: missing MCP_TOKEN",
            "Skipped: unsupported transport"
        ])
        #expect(state?.rows[2].transport == "Legacy SSE")
        #expect(!(state?.accessibilitySummary.contains(token) ?? true))
    }

    @Test("marks settings changes stale until reconnect")
    func marksChangedConfigurationStale() {
        let attached = [ProjectMCPServer.stdio(name: "filesystem", command: "mcp-files")]
        let changed = [ProjectMCPServer.stdio(name: "filesystem", command: "mcp-files-v2")]
        let summary = MCPAttachmentSummary(
            statuses: [.init(id: "0", name: "filesystem", transport: .stdio, disposition: .requested)],
            configurationFingerprint: MCPAttachmentPlanner.configurationFingerprint(for: attached)
        )

        let current = ACPMCPStatusState(summary: summary, currentServers: attached)
        let stale = ACPMCPStatusState(summary: summary, currentServers: changed)

        #expect(current?.isStale == false)
        #expect(stale?.isStale == true)
        #expect(stale?.accessibilitySummary == "MCP: 1 requested, New settings apply on reconnect.")
    }

    @Test("shows a stale zero-server state after MCP servers are added")
    func showsStaleStateWhenServersAreAddedAfterAttach() {
        let added = [ProjectMCPServer.stdio(name: "filesystem", command: "mcp-files")]
        let summary = MCPAttachmentSummary(
            statuses: [],
            configurationFingerprint: MCPAttachmentPlanner.configurationFingerprint(for: [])
        )

        let state = ACPMCPStatusState(summary: summary, currentServers: added)

        #expect(state?.requestedCount == 0)
        #expect(state?.isStale == true)
    }

    @Test("preamble detail reflects pending, sent, and none")
    func preambleDetailStates() throws {
        let summary = MCPAttachmentSummary(
            statuses: [.init(id: "a", name: "alas", transport: .stdio, disposition: .requested)],
            configurationFingerprint: "fp")

        let pending = try #require(ACPMCPStatusState(
            summary: summary, currentServers: [], preamblePending: true, preambleSent: false))
        #expect(pending.preambleDetail == "Context preamble pending — sent with the next prompt")

        let sent = try #require(ACPMCPStatusState(
            summary: summary, currentServers: [], preamblePending: false, preambleSent: true))
        #expect(sent.preambleDetail == "Context preamble sent")

        let none = try #require(ACPMCPStatusState(
            summary: summary, currentServers: []))
        #expect(none.preambleDetail == nil)
    }
}
