import Foundation

/// Warning state for the built-in "alas" MCP server on the current attach.
/// Drives the status control's warning treatment and whether the
/// "switch to HTTP transport" action is offered.
enum BuiltInMCPWarning: Equatable {
    /// The built-in server is registered (or not requested) — no warning.
    case none
    /// Attached over stdio, not registered, and the adapter supports HTTP:
    /// switching transport is a viable remedy.
    case canSwitchToHTTP
    /// Already attached over HTTP but still not registered — switching
    /// transport would not help.
    case alreadyHTTP
    /// Attached over stdio, not registered, and the adapter has no HTTP MCP
    /// support, so offering the switch would loop back to stdio.
    case httpUnsupported
}

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
    let builtInWarning: BuiltInMCPWarning
    let hasBuiltInWarning: Bool
    let showsSwitchToHTTPAction: Bool

    init?(
        summary: MCPAttachmentSummary?,
        currentServers: [ProjectMCPServer],
        preamblePending: Bool = false,
        preambleSent: Bool = false,
        externalStatus: ACPMCPExternalStatus? = nil,
        builtInRegistration: MCPServerRegistration = .unknown,
        adapterSupportsHTTP: Bool = true
    ) {
        guard let summary,
              !summary.statuses.isEmpty || !currentServers.isEmpty else {
            return nil
        }

        // Derive the transport from what the session actually attached with —
        // the built-in status row — not the (possibly newer) config preference.
        let attachedBuiltInTransport = summary.statuses
            .first { $0.id == BuiltInAlasMCP.statusId }?.transport
        if builtInRegistration != .notRegistered {
            builtInWarning = .none
        } else if attachedBuiltInTransport == .http {
            // Already on HTTP and still not registered — the switch cannot help.
            builtInWarning = .alreadyHTTP
        } else if adapterSupportsHTTP {
            builtInWarning = .canSwitchToHTTP
        } else {
            // stdio + not registered, but the adapter has no HTTP MCP support:
            // switching would fall back to stdio again and loop.
            builtInWarning = .httpUnsupported
        }
        hasBuiltInWarning = builtInWarning != .none
        showsSwitchToHTTPAction = builtInWarning == .canSwitchToHTTP

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
        switch builtInWarning {
        case .none:
            break
        case .canSwitchToHTTP:
            parts.append("Alas MCP server not started — switch to HTTP transport")
        case .httpUnsupported:
            parts.append("Alas MCP server not started and this agent has no HTTP MCP support")
        case .alreadyHTTP:
            parts.append("Alas MCP server not started over HTTP")
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
        case .unavailableMember:
            return "Skipped: checkout member unavailable"
        }
    }
}
