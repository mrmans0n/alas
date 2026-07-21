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

    @Test("external status replaces rows and drives the install action")
    func externalStatusRows() throws {
        let summary = MCPAttachmentSummary(
            statuses: [.init(id: "a", name: "alas", transport: .stdio, disposition: .requested)],
            configurationFingerprint: "fp")

        let available = try #require(ACPMCPStatusState(
            summary: summary, currentServers: [],
            externalStatus: .init(cliActive: true, adapterState: .installed,
                                  configOutcome: .wrote, hint: "h", userServerNames: ["linear"])))
        let rows = try #require(available.externalRows)
        #expect(rows.count == 2)
        #expect(rows[0].detail == "via alas CLI (environment injected)")
        #expect(rows[1].detail == "via pi-mcp-adapter")
        #expect(rows[1].isRequested == true)
        #expect(available.requestedCount == 2)
        #expect(available.skippedCount == 0)
        #expect(available.showsAdapterInstallAction == false)

        let notInstalled = try #require(ACPMCPStatusState(
            summary: summary, currentServers: [],
            externalStatus: .init(cliActive: false, adapterState: .missing,
                                  configOutcome: nil, hint: "h", userServerNames: ["linear"])))
        let mrows = try #require(notInstalled.externalRows)
        #expect(mrows[0].detail == "unavailable (Alas CLI not injected)")
        #expect(mrows[1].detail == "requires the pi-mcp-adapter extension")
        #expect(mrows[1].isRequested == false)
        #expect(notInstalled.requestedCount == 0)
        #expect(notInstalled.skippedCount == 2)
        #expect(notInstalled.showsAdapterInstallAction == true)

        let remoteNotInstalled = try #require(ACPMCPStatusState(
            summary: summary, currentServers: [],
            externalStatus: .init(cliActive: false, adapterState: .unknown,
                                  configOutcome: nil, hint: "h", userServerNames: ["linear"],
                                  canInstallAdapterLocally: false)))
        let remoteRows = try #require(remoteNotInstalled.externalRows)
        #expect(remoteRows[1].detail == "requires the pi-mcp-adapter extension")
        #expect(remoteNotInstalled.showsAdapterInstallAction == false)

        let skippedExternal = try #require(ACPMCPStatusState(
            summary: summary, currentServers: [],
            externalStatus: .init(
                cliActive: true, adapterState: .installed, configOutcome: .noServers,
                hint: "h", userServerNames: [],
                skippedServerStatuses: [
                    .init(
                        id: "bad-token", name: "linear", transport: .stdio,
                        disposition: .skipped(.missingVariable("LINEAR_TOKEN")))
                ])))
        let skippedRows = try #require(skippedExternal.externalRows)
        #expect(skippedRows.map(\.id).contains("external-skipped-bad-token"))
        #expect(skippedRows.map(\.detail).contains("Skipped: missing LINEAR_TOKEN"))
        #expect(skippedExternal.requestedCount == 1)
        #expect(skippedExternal.skippedCount == 1)

        let noServers = try #require(ACPMCPStatusState(
            summary: summary, currentServers: [],
            externalStatus: .init(cliActive: true, adapterState: .missing,
                                  configOutcome: nil, hint: "h", userServerNames: [])))
        #expect(noServers.requestedCount == 1)
        #expect(noServers.skippedCount == 0)
        #expect(noServers.showsAdapterInstallAction == false)

        let userManaged = try #require(ACPMCPStatusState(
            summary: summary, currentServers: [],
            externalStatus: .init(cliActive: true, adapterState: .installed,
                                  configOutcome: .refusedUnmanaged, hint: "h", userServerNames: ["linear"])))
        let userManagedRows = try #require(userManaged.externalRows)
        #expect(userManagedRows[1].detail == "using your existing .pi/mcp.json")
        #expect(userManagedRows[1].isRequested == false)
        // an unmanaged file means the extension IS installed — no install action
        #expect(userManaged.showsAdapterInstallAction == false)

        let syncFailed = try #require(ACPMCPStatusState(
            summary: summary, currentServers: [],
            externalStatus: .init(cliActive: true, adapterState: .installed,
                                  configOutcome: .failed, hint: "h", userServerNames: ["linear"])))
        let failedRows = try #require(syncFailed.externalRows)
        #expect(failedRows[1].detail == "config sync failed — see logs")
        #expect(failedRows[1].isRequested == false)
        // the adapter extension itself is installed, so no install action
        #expect(syncFailed.showsAdapterInstallAction == false)

        // no external status → unchanged classic behavior
        let classic = try #require(ACPMCPStatusState(summary: summary, currentServers: []))
        #expect(classic.externalRows == nil)
    }

    private func builtInSummary(transport: MCPTransportKind = .stdio) -> MCPAttachmentSummary {
        let status = MCPAttachmentServerStatus(
            id: BuiltInAlasMCP.statusId, name: "alas",
            transport: transport, disposition: .requested)
        return MCPAttachmentSummary(statuses: [status], configurationFingerprint: "fp")
    }

    @Test("notRegistered on stdio offers the HTTP switch when the adapter supports http")
    func offersSwitch() {
        let state = ACPMCPStatusState(
            summary: builtInSummary(transport: .stdio), currentServers: [],
            builtInRegistration: .notRegistered,
            adapterSupportsHTTP: true)
        #expect(state?.builtInWarning == .canSwitchToHTTP)
        #expect(state?.hasBuiltInWarning == true)
        #expect(state?.showsSwitchToHTTPAction == true)
    }

    @Test("notRegistered on stdio without http support warns but hides the switch")
    func warnsNoSwitchWhenAdapterLacksHTTP() {
        let state = ACPMCPStatusState(
            summary: builtInSummary(transport: .stdio), currentServers: [],
            builtInRegistration: .notRegistered,
            adapterSupportsHTTP: false)
        #expect(state?.builtInWarning == .httpUnsupported)
        #expect(state?.hasBuiltInWarning == true)
        #expect(state?.showsSwitchToHTTPAction == false)
    }

    @Test("notRegistered on http warns without the switch")
    func warnsNoSwitchOnHTTP() {
        let state = ACPMCPStatusState(
            summary: builtInSummary(transport: .http), currentServers: [],
            builtInRegistration: .notRegistered,
            adapterSupportsHTTP: true)
        #expect(state?.builtInWarning == .alreadyHTTP)
        #expect(state?.hasBuiltInWarning == true)
        #expect(state?.showsSwitchToHTTPAction == false)
    }

    @Test("registered shows no warning")
    func registeredNoWarning() {
        let state = ACPMCPStatusState(
            summary: builtInSummary(transport: .stdio), currentServers: [],
            builtInRegistration: .registered,
            adapterSupportsHTTP: true)
        #expect(state?.builtInWarning == BuiltInMCPWarning.none)
        #expect(state?.hasBuiltInWarning == false)
        #expect(state?.showsSwitchToHTTPAction == false)
    }
}
