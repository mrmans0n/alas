import SwiftUI

/// Session-scoped MCP attachment status. It is intentionally informational:
/// editing the project configuration only makes this summary stale, because
/// a different attachment plan cannot be applied until the next reconnect.
struct ACPMCPStatusControl: View {
    @ObservedObject var session: ACPSession
    let currentServers: [ProjectMCPServer]
    var onInstallPiMCPAdapter: (() async -> Bool)? = nil
    var onSwitchToHTTP: (() -> Void)? = nil
    @Environment(\.theme) private var theme
    @State private var popoverOpen = false

    private var status: ACPMCPStatusState? {
        ACPMCPStatusState(
            summary: session.mcpAttachmentSummary,
            currentServers: currentServers,
            preamblePending: session.pendingMCPPreamble != nil,
            preambleSent: session.mcpPreambleSent,
            externalStatus: session.mcpExternalStatus,
            builtInRegistration: session.builtInMCPRegistration,
            adapterSupportsHTTP: session.adapterSupportsHTTPMCP
        )
    }

    var body: some View {
        if let status {
            Button {
                popoverOpen.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 11, weight: .medium))
                    Text("MCP \(status.requestedCount)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    if status.skippedCount > 0 || status.hasBuiltInWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                    }
                    if status.isStale {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .foregroundStyle(foregroundColor(for: status))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(backgroundColor(for: status))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(foregroundColor(for: status).opacity(0.28), lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)
            .help(status.accessibilitySummary)
            .accessibilityLabel(status.accessibilitySummary)
            .popover(isPresented: $popoverOpen, arrowEdge: .top) {
                ACPMCPStatusPopover(
                    status: status,
                    onInstallPiMCPAdapter: onInstallPiMCPAdapter,
                    onSwitchToHTTP: onSwitchToHTTP
                )
            }
        }
    }

    private func foregroundColor(for status: ACPMCPStatusState) -> Color {
        if status.isStale || status.skippedCount > 0 || status.hasBuiltInWarning {
            return theme.color("warn")
        }
        return theme.color("accent")
    }

    private func backgroundColor(for status: ACPMCPStatusState) -> Color {
        foregroundColor(for: status).opacity(0.10)
    }
}

private struct ACPMCPStatusPopover: View {
    enum InstallState { case idle, running, done, failed }

    let status: ACPMCPStatusState
    var onInstallPiMCPAdapter: (() async -> Bool)? = nil
    var onSwitchToHTTP: (() -> Void)? = nil
    @Environment(\.theme) private var theme
    @State private var installState: InstallState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MCP servers")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                Spacer()
                Text(status.summaryText)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.color("fg-muted"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if status.isStale {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                    Text("New settings apply on reconnect.")
                        .font(.system(size: 11))
                }
                .foregroundStyle(theme.color("warn"))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.color("warn").opacity(0.10))
            }

            if status.hasBuiltInWarning {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("The agent harness didn't start the Alas MCP server — it may be blocked by an enterprise MCP policy (stdio servers are commonly restricted).")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(theme.color("warn"))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.color("warn").opacity(0.10))
            }

            Divider().background(theme.color("line"))

            VStack(spacing: 0) {
                ForEach(status.externalRows ?? status.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: row.isRequested ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(row.isRequested ? theme.color("accent") : theme.color("warn"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(theme.color("fg"))
                                .lineLimit(1)
                            Text("\(row.transport) - \(row.detail)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(theme.color("fg-muted"))
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }

            if status.showsAdapterInstallAction {
                installActionRow
            }

            if status.showsSwitchToHTTPAction, let onSwitchToHTTP {
                VStack(alignment: .leading, spacing: 6) {
                    AlasButton(title: "Switch to HTTP transport", style: .subtle) {
                        onSwitchToHTTP()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else if status.hasBuiltInWarning {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                    Text(builtInWarningDetail)
                        .font(.system(size: 10.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(theme.color("fg-muted"))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let detail = status.preambleDetail {
                Divider().background(theme.color("line"))
                HStack(spacing: 7) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 10))
                    Text(detail)
                        .font(.system(size: 10.5))
                }
                .foregroundStyle(theme.color("fg-muted"))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 300)
        .background(theme.color("bg-1"))
    }

    private var builtInWarningDetail: String {
        switch status.builtInWarning {
        case .none:
            return ""
        case .canSwitchToHTTP:
            return "The HTTP transport switch is unavailable for this session."
        case .alreadyHTTP:
            return "Already using HTTP; check whether your agent policy allows http://localhost MCP servers."
        case .httpUnsupported:
            return "This agent does not advertise HTTP MCP support."
        }
    }

    @ViewBuilder
    private var installActionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch installState {
            case .idle:
                AlasButton(title: "Install pi-mcp-adapter", style: .subtle) {
                    guard let onInstallPiMCPAdapter else { return }
                    installState = .running
                    Task {
                        let success = await onInstallPiMCPAdapter()
                        installState = success ? .done : .failed
                    }
                }
            case .running:
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Installing pi-mcp-adapter…")
                        .font(.system(size: 11))
                }
                .foregroundStyle(theme.color("fg-muted"))
            case .done:
                Text("Installed ✓ — reconnect to apply")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("add"))
            case .failed:
                Text("Install failed — see pi output")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("warn"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
