import SwiftUI

private struct ACPConnectionRecoveryPresentation {
    let title: String
    let detail: String
    let actionTitle: String?
    let symbolName: String

    static func make(
        state: ACPConnectionRecoveryState,
        queuedMessageCount: Int,
        now: Date
    ) -> Self {
        let queuedDetail = queueDetail(count: queuedMessageCount)
        switch state {
        case .disconnected:
            return .init(
                title: "Agent process exited",
                detail: joined("Reconnect to continue.", queuedDetail),
                actionTitle: "Reconnect",
                symbolName: "bolt.slash"
            )
        case .waiting(let attempt, let maxAttempts, let retryAt):
            let seconds = Int(max(0, retryAt.timeIntervalSince(now)).rounded(.up))
            return .init(
                title: "Connection lost",
                detail: joined(
                    "Reconnecting in \(seconds)s (attempt \(attempt) of \(maxAttempts)).",
                    queuedDetail
                ),
                actionTitle: "Reconnect now",
                symbolName: "bolt.slash"
            )
        case .reconnecting(let attempt, let maxAttempts):
            let attemptDetail: String
            if let attempt, let maxAttempts {
                attemptDetail = "Attempt \(attempt) of \(maxAttempts)."
            } else {
                attemptDetail = "Bringing the agent process back up."
            }
            return .init(
                title: "Reconnecting…",
                detail: joined(attemptDetail, queuedDetail),
                actionTitle: nil,
                symbolName: "arrow.triangle.2.circlepath"
            )
        case .exhausted(let attempts):
            let failureDetail = attempts.map {
                "Automatic retries stopped after \($0) attempts."
            } ?? "The reconnect attempt failed."
            return .init(
                title: "Couldn’t reconnect",
                detail: joined(failureDetail, queuedDetail),
                actionTitle: "Try again",
                symbolName: "exclamationmark.arrow.triangle.2.circlepath"
            )
        }
    }

    private static func queueDetail(count: Int) -> String? {
        guard count > 0 else { return nil }
        let noun = count == 1 ? "message" : "messages"
        return "\(count) \(noun) queued; \(count == 1 ? "it" : "they") will send after reconnection."
    }

    private static func joined(_ first: String, _ second: String?) -> String {
        guard let second else { return first }
        return "\(first) \(second)"
    }
}

struct ACPConnectionRecoveryCard: View {
    let state: ACPConnectionRecoveryState
    let queuedMessageCount: Int
    let reconnectAvailable: Bool
    let onReconnect: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        if case .waiting = state {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                card(now: context.date)
            }
        } else {
            card(now: Date())
        }
    }

    private func card(now: Date) -> some View {
        let presentation = ACPConnectionRecoveryPresentation.make(
            state: state,
            queuedMessageCount: queuedMessageCount,
            now: now
        )
        return HStack(spacing: 10) {
            Image(systemName: presentation.symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                Text(presentation.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-muted"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if reconnectAvailable, let actionTitle = presentation.actionTitle {
                Button(actionTitle, action: onReconnect)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(theme.color("accent"))
                    .help(actionTitle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.color("bg-1").opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(statusColor.opacity(0.45), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.title)
    }

    private var statusColor: Color {
        if case .reconnecting = state {
            return theme.color("accent")
        }
        return theme.color("del")
    }
}

/// Toolbar pill that surfaces the ACP agent process lifecycle. Renders
/// nothing while the runner is `.idle` or `.ready` and a labeled chip
/// otherwise (spawning / disconnected / failed). Styled to sit next to
/// `ACPPlanPill` without clashing.
struct ACPRecoveryPill: View {
    @ObservedObject var session: ACPSession
    @Environment(\.theme) private var theme

    var body: some View {
        if let label = label {
            HStack(spacing: 6) {
                statusDot(animating: isAnimating)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(theme.color("bg-1"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .help(helpText)
            .transition(.opacity)
        }
    }

    private var label: String? {
        if let recovery = session.connectionRecoveryState {
            switch recovery {
            case .waiting, .reconnecting: return "Reconnecting…"
            case .disconnected: return "Disconnected"
            case .exhausted: return "Reconnect failed"
            }
        }
        switch session.agentState {
        case .idle, .ready: return nil
        case .spawning: return "Reconnecting…"
        case .disconnected: return "Disconnected"
        case .failed: return "Failed"
        }
    }

    private var helpText: String {
        if let recovery = session.connectionRecoveryState {
            switch recovery {
            case .waiting:
                return "Connection lost. Retrying automatically; sending a message also reconnects."
            case .reconnecting:
                return "Bringing the agent process back up…"
            case .disconnected:
                return "Agent process exited. Will reconnect on next send."
            case .exhausted:
                return "Automatic reconnect attempts stopped. Try again from the transcript."
            }
        }
        if case .failed(let reason) = session.agentState {
            return "Failed: \(reason)"
        }
        return session.agentState == .spawning ? "Bringing the agent process back up…" : ""
    }

    private var isAnimating: Bool {
        if case .waiting = session.connectionRecoveryState { return true }
        if case .reconnecting = session.connectionRecoveryState { return true }
        if case .spawning = session.agentState { return true }
        return false
    }

    @ViewBuilder
    private func statusDot(animating: Bool) -> some View {
        Circle()
            .fill(theme.color("accent"))
            .frame(width: 6, height: 6)
            .opacity(animating ? 0.4 : 1.0)
            .animation(animating
                ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                : .default,
                value: animating)
    }
}
