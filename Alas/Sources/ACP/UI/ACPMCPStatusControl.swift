import SwiftUI

/// Session-scoped MCP attachment status. It is intentionally informational:
/// editing the project configuration only makes this summary stale, because
/// a different attachment plan cannot be applied until the next reconnect.
struct ACPMCPStatusControl: View {
    @Environment(\.designScale) private var scale
    @ObservedObject var session: ACPSession
    let currentServers: [ProjectMCPServer]
    var onInstallPiMCPAdapter: (() async -> Bool)? = nil
    var onSwitchToHTTP: (() -> Void)? = nil
    var onReconnect: (() -> Void)? = nil
    /// Enable/disable/approve affordance for repo-defined server rows; nil rows
    /// (app-level or not-enabled repo servers) render no control.
    var onToggleRepoServer: ((String, ACPMCPStatusState.RepoToggle) -> Void)? = nil
    @Environment(\.theme) private var theme
    @State private var popoverOpen = false
    @State private var hovering = false

    /// Lit while the pointer is over the pill or its popover is up, so the
    /// trigger stays visibly tied to the surface it opened.
    private var isLit: Bool { hovering || popoverOpen }

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
                HStack(spacing: scale.space[1]) {
                    Image(systemName: "server.rack")
                        .font(scale.meta.font(weight: .medium))
                    Text("MCP \(status.requestedCount)")
                        .font(scale.caption.font(weight: .semibold))
                    if status.skippedCount > 0 || status.hasBuiltInWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(scale.glyphFont)
                    }
                    if status.isStale {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(scale.glyphFont)
                    }
                }
                .foregroundStyle(foregroundColor(for: status))
                .padding(.horizontal, scale.space[2])
                .frame(height: 24)
                .background(backgroundColor(for: status))
                .clipShape(RoundedRectangle(cornerRadius: scale.radius.small, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: scale.radius.small, style: .continuous)
                        .strokeBorder(foregroundColor(for: status).opacity(isLit ? 0.5 : 0.28), lineWidth: 0.5)
                }
            }
            .buttonStyle(.toolbarControl)
            .onHover { hovering = $0 }
            .help(status.accessibilitySummary)
            .accessibilityLabel(status.accessibilitySummary)
            .popover(isPresented: $popoverOpen, arrowEdge: .top) {
                ACPMCPStatusPopover(
                    status: status,
                    onInstallPiMCPAdapter: onInstallPiMCPAdapter,
                    onSwitchToHTTP: onSwitchToHTTP,
                    onReconnect: onReconnect,
                    onToggleRepoServer: onToggleRepoServer
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
        foregroundColor(for: status).opacity(isLit ? 0.22 : 0.10)
    }
}

private struct ACPMCPStatusPopover: View {
    @Environment(\.designScale) private var scale
    enum InstallState { case idle, running, done, failed }

    let status: ACPMCPStatusState
    var onInstallPiMCPAdapter: (() async -> Bool)? = nil
    var onSwitchToHTTP: (() -> Void)? = nil
    var onReconnect: (() -> Void)? = nil
    /// Enable/disable/approve affordance for repo-defined server rows; nil rows
    /// (app-level or not-enabled repo servers) render no control.
    var onToggleRepoServer: ((String, ACPMCPStatusState.RepoToggle) -> Void)? = nil
    @Environment(\.theme) private var theme
    @State private var installState: InstallState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MCP servers")
                    .font(scale.meta.font(weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                Spacer()
                Text(status.summaryText)
                    .font(scale.caption.font(weight: .medium))
                    .foregroundStyle(theme.color("fg-muted"))
            }
            .padding(.horizontal, scale.space[3])
            .padding(.vertical, scale.space[2])

            if status.isStale {
                HStack(spacing: scale.space[2]) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(scale.caption.font(weight: .semibold))
                    Text("New settings apply on reconnect.")
                        .font(scale.metaFont)
                }
                .foregroundStyle(theme.color("warn"))
                .padding(.horizontal, scale.space[3])
                .padding(.vertical, scale.space[2])
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.color("warn").opacity(0.10))
            }

            if status.hasBuiltInWarning {
                HStack(alignment: .top, spacing: scale.space[2]) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(scale.caption.font(weight: .semibold))
                    Text("The agent harness didn't start the Alas MCP server — it may be blocked by an enterprise MCP policy (stdio servers are commonly restricted).")
                        .font(scale.metaFont)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(theme.color("warn"))
                .padding(.horizontal, scale.space[3])
                .padding(.vertical, scale.space[2])
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.color("warn").opacity(0.10))
            }

            Divider().background(theme.color("line"))

            VStack(spacing: 0) {
                ForEach(status.externalRows ?? status.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: scale.space[2]) {
                        Image(systemName: row.isRequested ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(scale.metaFont)
                            .foregroundStyle(row.isRequested ? theme.color("accent") : theme.color("warn"))
                        VStack(alignment: .leading, spacing: scale.space[0]) {
                            Text(row.name)
                                .font(scale.meta.font(weight: .medium))
                                .foregroundStyle(theme.color("fg"))
                                .lineLimit(1)
                            Text("\(row.transport) - \(row.detail)")
                                .font(scale.caption.font(weight: .regular))
                                .foregroundStyle(theme.color("fg-muted"))
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if row.isRequested,
                           row.repoToggle == .disable,
                           let onToggleRepoServer {
                            Button("Disable") {
                                onToggleRepoServer(row.name, .disable)
                            }
                            .font(scale.caption.font(weight: .regular))
                        } else if row.repoToggle == .enable,
                                  let onToggleRepoServer {
                            Button("Enable") {
                                onToggleRepoServer(row.name, .enable)
                            }
                            .font(scale.caption.font(weight: .regular))
                        } else if row.repoToggle == .approve,
                                  let onToggleRepoServer {
                            Button("Approve") {
                                onToggleRepoServer(row.name, .approve)
                            }
                            .font(scale.caption.font(weight: .regular))
                        }
                    }
                    .padding(.horizontal, scale.space[3])
                    .padding(.vertical, scale.space[2])
                }
            }

            if status.showsAdapterInstallAction {
                installActionRow
            }

            if status.showsSwitchToHTTPAction, let onSwitchToHTTP {
                VStack(alignment: .leading, spacing: scale.space[2]) {
                    AlasButton(title: "Switch to HTTP transport", icon: "arrow.triangle.2.circlepath", style: .normal) {
                        onSwitchToHTTP()
                    }
                }
                .padding(.horizontal, scale.space[3])
                .padding(.vertical, scale.space[2])
            } else if status.hasBuiltInWarning {
                HStack(alignment: .top, spacing: scale.space[2]) {
                    Image(systemName: "info.circle")
                        .font(scale.caption.font(weight: .regular))
                    Text(builtInWarningDetail)
                        .font(scale.caption.font(weight: .regular))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(theme.color("fg-muted"))
                .padding(.horizontal, scale.space[3])
                .padding(.vertical, scale.space[2])
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if status.isStale || status.hasBuiltInWarning, let onReconnect {
                AlasButton(title: "Reconnect session", icon: "arrow.clockwise", style: .normal) {
                    onReconnect()
                }
                .padding(.horizontal, scale.space[3])
                .padding(.vertical, scale.space[2])
            }

            if let detail = status.preambleDetail {
                Divider().background(theme.color("line"))
                HStack(spacing: scale.space[2]) {
                    Image(systemName: "text.bubble")
                        .font(scale.caption.font(weight: .regular))
                    Text(detail)
                        .font(scale.caption.font(weight: .regular))
                }
                .foregroundStyle(theme.color("fg-muted"))
                .padding(.horizontal, scale.space[3])
                .padding(.vertical, scale.space[2])
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
        VStack(alignment: .leading, spacing: scale.space[2]) {
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
                HStack(spacing: scale.space[2]) {
                    ProgressView().controlSize(.small)
                    Text("Installing pi-mcp-adapter…")
                        .font(scale.metaFont)
                }
                .foregroundStyle(theme.color("fg-muted"))
            case .done:
                Text("Installed ✓ — reconnect to apply")
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color("add"))
            case .failed:
                Text("Install failed — see pi output")
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color("warn"))
            }
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
    }
}
