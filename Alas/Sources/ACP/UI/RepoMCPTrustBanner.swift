import SwiftUI

/// Non-blocking banner listing repo-defined MCP servers that still need a
/// trust decision (docs/plans/2026-09-17-repo-local-config-design.md,
/// "MCP servers and trust"). Approving attaches them to future sessions;
/// declining keeps them off without nagging.
struct RepoMCPTrustBanner: View {
    @Environment(\.designScale) private var scale
    let pendingServers: [ProjectMCPServer]
    let approvalQueue: RepoHookApprovalQueue
    let onApproveAll: () -> Void
    let onDeclineAll: () -> Void
    /// Per-server decisions from the review sheet. Nil disables the affordance.
    var onApproveServer: ((ProjectMCPServer) -> Void)? = nil
    var onDeclineServer: ((ProjectMCPServer) -> Void)? = nil

    @State private var showsReview = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: scale.space[2]) {
            Image(systemName: "lock.shield")
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg-faint"))
            Text(Self.headline(serverCount: pendingServers.count))
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg-muted"))
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer()
            Button("Review…") { showsReview = true }
                .buttonStyle(.plain)
                .font(scale.metaFont)
            Button("Approve All") { onApproveAll() }
                .font(scale.metaFont)
            Button {
                onDeclineAll()
            } label: {
                Image(systemName: "xmark")
                    .font(scale.caption.font(weight: .regular))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
        .background(theme.color("bg-1").opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.color("line"))
                .frame(height: 0.5)
        }
        .sheet(isPresented: $showsReview) {
            reviewSheet
        }
    }

    var reviewSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Repo-defined MCP servers")
                .font(.system(size: 16, weight: .semibold)) // design-literal: the one dialog title
                .padding(.bottom, scale.space[1])
            Text("Defined by this repo's .alas/config.json. Nothing attaches until you approve it; decline keeps it off and silent.")
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg-muted"))
                .padding(.bottom, scale.space[3])
            ScrollView {
                VStack(alignment: .leading, spacing: scale.space[2]) {
                    ForEach(pendingServers) { server in
                        VStack(alignment: .leading, spacing: scale.space[0]) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(server.name)
                                    .font(scale.meta.font(weight: .semibold))
                                Spacer()
                                if let onApproveServer, let onDeclineServer {
                                    HStack(spacing: scale.space[2]) {
                                        Button("Approve") { onApproveServer(server) }
                                            .font(scale.caption.font(weight: .regular))
                                        Button {
                                            onDeclineServer(server)
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(scale.glyphFont)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Decline \(server.name)")
                                    }
                                }
                            }
                            Text(Self.detail(for: server.transport))
                                .font(scale.metaFont)
                                .foregroundStyle(theme.color("fg-muted"))
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, scale.space[2])
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(theme.color("line"))
                                .frame(height: 0.5)
                        }
                    }
                }
                .padding(.vertical, scale.space[1])
            }
            HStack {
                Spacer()
                Button("Approve All") {
                    onApproveAll()
                    showsReview = false
                }
                Button("Decline") {
                    onDeclineAll()
                    showsReview = false
                }
            }
            .padding(.top, scale.space[3])
        }
        .padding(scale.space[4])
        .frame(width: 420)
        .modifier(RepoHookApprovalPresentationHandler(approvalQueue: approvalQueue))
    }

    static func headline(serverCount: Int) -> String {
        serverCount == 1
            ? "This repo defines 1 MCP server — approve it to enable it."
            : "This repo defines \(serverCount) MCP servers — approve them to enable them."
    }

    /// Read-only detail for the review sheet: command or URL, plus
    /// environment/header names only — never their values.
    static func detail(for transport: ProjectMCPTransport) -> String {
        switch transport {
        case let .stdio(command, args, environment):
            let names = environment.isEmpty
                ? ""
                : " · env: \(environment.map(\.name).joined(separator: ", "))"
            let arguments = args.isEmpty ? "" : " \(args.joined(separator: " "))"
            return "command: \(command)\(arguments)\(names)"
        case let .http(url, headers):
            return "url: \(url)\(headerNames(headers))"
        case let .sse(url, headers):
            return "sse url: \(url)\(headerNames(headers))"
        }
    }

    private static func headerNames(_ headers: [MCPKeyValue]) -> String {
        headers.isEmpty ? "" : " · headers: \(headers.map(\.name).joined(separator: ", "))"
    }
}
