import SwiftUI

/// Inline permission card. Visual mirrors the design's pending edit card —
/// teal glow border, "Awaiting approval" pulse, body summary, sticky
/// Accept/Reject action row.
struct ACPPermissionPrompt: View {
    @ObservedObject var session: ACPSession
    let policy: ACPPermissionPolicy
    let scopeKey: String
    @Environment(\.theme) private var theme

    var body: some View {
        if let pending = session.transcript.pendingPermission {
            content(for: pending.params)
        }
    }

    @ViewBuilder
    private func content(for params: ACPPermissionRequestParams) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(params)
            commandBody(params)
            actionRow(params)
        }
        .background(
            LinearGradient(
                colors: [theme.color("bg-2").opacity(0.6), theme.color("bg-1").opacity(0.6)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.color("accent").opacity(0.55), lineWidth: 1)
        )
        .shadow(color: theme.color("accent").opacity(0.10), radius: 16, y: 4)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }

    /// Header is now a short status row only. The long command / details
    /// move into `commandBody` so they don't fight the title for space.
    @ViewBuilder
    private func header(_ params: ACPPermissionRequestParams) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.color("accent").opacity(0.18))
                Image(systemName: "hand.raised")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.color("accent"))
            }
            .frame(width: 18, height: 18)

            Text("Permission")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(theme.color("accent"))

            if let kind = params.toolCall.kind, !kind.isEmpty {
                Text("· \(kind)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-faint"))
            }

            Spacer(minLength: 6)

            PendingPulse()
                .frame(width: 6, height: 6)
            Text("Awaiting approval")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(theme.color("accent"))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(theme.color("accent").opacity(0.08))
    }

    /// The actual `Allow … ?` body. Title (e.g. the command) sits on its
    /// own line; if the agent included a separate content block (e.g. a
    /// preview of stdin), that follows below in monospace.
    @ViewBuilder
    private func commandBody(_ params: ACPPermissionRequestParams) -> some View {
        let title = params.toolCall.title ?? params.toolCall.toolCallId
        let summary = commandSummary(params)
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow this?")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(theme.color("fg-faint"))
            Text(title)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(theme.color("fg"))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let summary, !summary.isEmpty, summary != title {
                Text(summary)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.color("fg-muted"))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(theme.color("bg-0").opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
    }

    @ViewBuilder
    private func actionRow(_ params: ACPPermissionRequestParams) -> some View {
        HStack(spacing: 10) {
            Spacer()
            ForEach(params.options) { opt in
                Button {
                    handle(option: opt, scopeKey: scopeKey)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: glyph(for: opt))
                            .font(.system(size: 10))
                        Text(opt.name)
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(background(for: opt))
                    .foregroundStyle(foreground(for: opt))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(border(for: opt), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(theme.color("bg-1").opacity(0.55))
        .overlay(alignment: .top) {
            Rectangle().fill(theme.color("line-soft")).frame(height: 0.5)
        }
    }

    // MARK: - per-option styling

    private func isPrimary(_ opt: ACPPermissionOption) -> Bool {
        opt.kind == "allow_once" || opt.kind == "allow_always"
    }

    private func isDestructive(_ opt: ACPPermissionOption) -> Bool {
        opt.kind == "reject_once" || opt.kind == "reject_always"
    }

    private func glyph(for opt: ACPPermissionOption) -> String {
        if isDestructive(opt) { return "xmark" }
        if isPrimary(opt) { return "checkmark" }
        return "circle"
    }

    private func background(for opt: ACPPermissionOption) -> Color {
        if opt.kind == "allow_once" { return theme.color("accent") }
        if isDestructive(opt) { return theme.color("bg-3") }
        return theme.color("bg-3")
    }

    private func foreground(for opt: ACPPermissionOption) -> Color {
        if opt.kind == "allow_once" { return theme.color("bg-0") }
        return theme.color("fg")
    }

    private func border(for opt: ACPPermissionOption) -> Color {
        if opt.kind == "allow_once" { return theme.color("accent") }
        return theme.color("line")
    }

    // MARK: - extraction + dispatch

    private func commandSummary(_ p: ACPPermissionRequestParams) -> String? {
        guard let blocks = p.toolCall.content else { return nil }
        for b in blocks { if case .text(let s) = b { return s } }
        return nil
    }

    private func handle(option: ACPPermissionOption, scopeKey: String) {
        let decision: ACPPermissionDecision = option.kind.hasPrefix("allow") ? .allow : .deny
        let persistScope: ACPPermissionScopeKind?
        switch option.kind {
        case "allow_once", "reject_once":     persistScope = nil
        case "allow_always", "reject_always": persistScope = .project
        default:                              persistScope = .session
        }
        Task {
            await policy.userDecided(
                scopeKey: scopeKey,
                optionId: option.optionId,
                decision: decision,
                persistScope: persistScope
            )
        }
    }
}

private struct PendingPulse: View {
    @State private var pulse = false
    @Environment(\.theme) private var theme
    var body: some View {
        Circle()
            .fill(theme.color("accent"))
            .overlay(
                Circle()
                    .strokeBorder(theme.color("accent").opacity(0.5), lineWidth: 2)
                    .scaleEffect(pulse ? 2.2 : 1)
                    .opacity(pulse ? 0 : 0.6)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
            )
            .onAppear { pulse = true }
    }
}
