import Combine
import SwiftUI

/// What the parent's transcript needs to show the children its `session_new`
/// calls started. Read live: mounted rows are not re-created when a child's
/// delegation changes.
struct ACPDelegatedChildActions {
    /// Read in the card's body, so a delegation change reloads its summary.
    var revision: () -> Int
    /// The child's summary; nil when the id is not a child of this session.
    var summary: (String) async -> ACPOrchestrationSessionSummary?
    /// Fires when the child's runtime state changes, which the revision
    /// misses: a permission prompt shown or answered.
    var runtimeChanges: (ACPOrchestrationSessionSummary) -> AnyPublisher<Void, Never>
    var agentName: (String) -> String
    var open: (ACPOrchestrationSessionSummary) -> Void
}

/// A `session_new` call in the parent transcript, shown as the child it
/// started: agent, role, task and live state, with a button that opens the
/// child. Falls back to the plain tool card when the child is unknown here.
struct ACPDelegatedChildCard<Fallback: View>: View {
    @Environment(\.designScale) private var scale
    @Environment(\.theme) private var theme
    let toolCall: ACPToolCall
    let childSessionId: String
    let actions: ACPDelegatedChildActions
    @ViewBuilder let fallback: () -> Fallback
    @State private var summary: ACPOrchestrationSessionSummary?
    @State private var loaded = false
    @State private var runtimeTick = 0

    var body: some View {
        let revision = actions.revision()
        content
            .task(id: "\(revision)-\(runtimeTick)") {
                summary = await actions.summary(childSessionId)
                loaded = true
            }
            // Resubscribed on a delegation change, which may bring the child's
            // live session up.
            .task(id: "\(revision)-\(summary?.worktreeId ?? "")") {
                guard let summary else { return }
                for await _ in actions.runtimeChanges(summary).values {
                    runtimeTick &+= 1
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let summary {
            card(summary)
        } else if loaded {
            fallback()
        } else {
            // Hold the row's height while the summary loads.
            fallback().hidden()
        }
    }

    private func card(_ summary: ACPOrchestrationSessionSummary) -> some View {
        let failed = summary.state == "failed" || summary.state == "reported_failed"
        return HStack(alignment: .firstTextBaseline, spacing: scale.space[2]) {
            Image(systemName: "arrow.down.right")
                .font(scale.caption.font(weight: .semibold))
                .foregroundStyle(theme.color("fg-faint"))
            VStack(alignment: .leading, spacing: scale.space[0]) {
                HStack(spacing: scale.space[2]) {
                    Text([actions.agentName(summary.agentId), summary.role].compactMap { $0 }.joined(separator: " · "))
                        .font(scale.meta.font(weight: .semibold))
                        .foregroundStyle(theme.color("fg-muted"))
                        .lineLimit(1)
                    Text(ACPDelegatedSessionsPolicy.statusLabel(for: summary.state))
                        .font(scale.caption.font(weight: .regular))
                        .foregroundStyle(failed ? theme.color("del") : theme.color("fg-faint"))
                    if ACPDelegatedSessionsPolicy.isWorking(summary.state) {
                        Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 11, height: 11)
                    }
                }
                if let task = ACPDelegatedSessionsPolicy.task(fromRawInput: toolCall.rawInput) {
                    Text(task)
                        .font(scale.metaFont)
                        .foregroundStyle(theme.color("fg-faint"))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            Button("Open") { actions.open(summary) }
                .buttonStyle(.plain)
                .font(scale.caption.font(weight: .semibold))
                .foregroundStyle(theme.color("accent"))
                .accessibilityLabel("Open child session")
        }
        .help(summary.failure ?? ACPDelegatedSessionsPolicy.statusLabel(for: summary.state))
    }
}
