import Foundation

/// Presentation-only state for the MCP attachment status control. The
/// planner's summary never retains resolved commands, environment values, or
/// headers, and this policy deliberately keeps the same boundary.
struct ACPMCPStatusState: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let name: String
        let transport: String
        let detail: String
        let isRequested: Bool
    }

    let requestedCount: Int
    let skippedCount: Int
    let isStale: Bool
    let rows: [Row]
    let preambleDetail: String?
    let externalRows: [Row]?
    let showsAdapterInstallAction: Bool
    let hasBuiltInWarning: Bool
    let showsSwitchToHTTPAction: Bool

    init?(
        summary: MCPAttachmentSummary?,
        currentServers: [ProjectMCPServer],
        preamblePending: Bool = false,
        preambleSent: Bool = false,
        externalStatus: ACPMCPExternalStatus? = nil,
        builtInRegistration: MCPServerRegistration = .unknown
    ) {
        guard let summary,
              !summary.statuses.isEmpty || !currentServers.isEmpty else {
            return nil
        }

        let builtInNotRegistered = (builtInRegistration == .notRegistered)
        hasBuiltInWarning = builtInNotRegistered
        // Derive the transport from what the session actually attached with —
        // the built-in status row — not the (possibly newer) config preference.
        let builtInTransport = summary.statuses
            .first { $0.id == BuiltInAlasMCP.statusId }?.transport
        showsSwitchToHTTPAction = builtInNotRegistered && builtInTransport == .stdio

        isStale = summary.configurationFingerprint
            != MCPAttachmentPlanner.configurationFingerprint(for: currentServers)
        rows = summary.statuses.map { Self.row($0) }

        if preamblePending {
            preambleDetail = "Context preamble pending — sent with the next prompt"
        } else if preambleSent {
            preambleDetail = "Context preamble sent"
        } else {
            preambleDetail = nil
        }

        if let externalStatus {
            let cliRow = Row(
                id: "external-cli", name: "alas tools",
                transport: "CLI",
                detail: externalStatus.cliActive
                    ? "via alas CLI (environment injected)"
                    : "unavailable (Alas CLI not injected)",
                isRequested: externalStatus.cliActive)
            let availability = externalStatus.adapterServerAvailability
            let adapterDetail: String
            let adapterIsRequested: Bool
            let adapterCountsAsSkipped: Bool
            switch availability {
            case .available:
                adapterDetail = "via pi-mcp-adapter"
                adapterIsRequested = true
                adapterCountsAsSkipped = false
            case .userManaged:
                adapterDetail = "using your existing .pi/mcp.json"
                adapterIsRequested = false
                adapterCountsAsSkipped = true
            case .syncFailed:
                adapterDetail = "config sync failed — see logs"
                adapterIsRequested = false
                adapterCountsAsSkipped = true
            case .notInstalled:
                adapterDetail = "requires the pi-mcp-adapter extension"
                adapterIsRequested = false
                adapterCountsAsSkipped = true
            case .noServers:
                adapterDetail = "via pi-mcp-adapter"
                adapterIsRequested = false
                adapterCountsAsSkipped = false
            }
            let adapterRow = Row(
                id: "external-adapter", name: "user MCP servers",
                transport: "pi-mcp-adapter",
                detail: adapterDetail,
                isRequested: adapterIsRequested)
            let skippedRows = externalStatus.skippedServerStatuses.map {
                Self.row($0, idPrefix: "external-skipped-")
            }
            let rows = [cliRow, adapterRow] + skippedRows
            externalRows = rows
            requestedCount = rows.count(where: \.isRequested)
            skippedCount = (cliRow.isRequested ? 0 : 1)
                + (adapterCountsAsSkipped ? 1 : 0)
                + skippedRows.count
            showsAdapterInstallAction = availability == .notInstalled
                && externalStatus.canInstallAdapterLocally
        } else {
            externalRows = nil
            requestedCount = summary.statuses.count { $0.disposition == .requested }
            skippedCount = summary.statuses.count - requestedCount
            showsAdapterInstallAction = false
        }
    }

    var summaryText: String {
        "\(requestedCount) requested"
    }

    var accessibilitySummary: String {
        var parts = ["MCP: \(requestedCount) requested"]
        if skippedCount > 0 {
            parts.append("\(skippedCount) skipped")
        }
        if isStale {
            parts.append("New settings apply on reconnect.")
        }
        return parts.joined(separator: ", ")
    }

    private static func row(_ status: MCPAttachmentServerStatus, idPrefix: String = "") -> Row {
        let transport: String
        switch status.transport {
        case .stdio: transport = "stdio"
        case .http: transport = "HTTP"
        case .sse: transport = "Legacy SSE"
        }

        switch status.disposition {
        case .requested:
            return .init(
                id: idPrefix + status.id,
                name: status.name,
                transport: transport,
                detail: "Requested",
                isRequested: true
            )
        case let .skipped(reason):
            return .init(
                id: idPrefix + status.id,
                name: status.name,
                transport: transport,
                detail: skipDetail(reason),
                isRequested: false
            )
        }
    }

    private static func skipDetail(_ reason: MCPAttachmentSkipReason) -> String {
        switch reason {
        case .unsupportedTransport:
            return "Skipped: unsupported transport"
        case let .missingVariable(variable):
            return "Skipped: missing \(variable)"
        case .invalidConfiguration:
            return "Skipped: invalid configuration"
        }
    }
}
