import Combine
import SwiftUI

/// Muted single-line aside (e.g. "Agent disconnected.", "Blocked write
/// outside worktree: …"). Dashed bordered tag for visual lightness.
struct ACPSystemNoticeView: View {
    @Environment(\.designScale) private var scale
    let text: String
    @Environment(\.theme) private var theme
    var body: some View {
        if let goal = Self.goalEvent(text) {
            ACPGoalEventCard(isSet: goal.isSet, objective: goal.objective)
        } else {
            notice
        }
    }

    /// A `/goal` confirmation ("Goal set: …", "Goal cleared: …") split into
    /// its event and objective, so it can show as a card like Ship's.
    static func goalEvent(_ text: String) -> (isSet: Bool, objective: String)? {
        for (prefix, isSet) in [("Goal set: ", true), ("Goal cleared: ", false)] where text.hasPrefix(prefix) {
            return (isSet, String(text.dropFirst(prefix.count)))
        }
        return nil
    }

    private var notice: some View {
        HStack(spacing: scale.space[2]) {
            Image(systemName: iconName)
                .font(scale.caption.font(weight: .regular))
                .foregroundStyle(theme.color("fg-faint"))
            Text(text)
                .font(scale.metaFont.italic())
                .foregroundStyle(theme.color("fg-faint"))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[2])
        .background(theme.color("bg-1").opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("line"), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        )
    }

    /// Pick an icon based on the notice text. Interruption notices get
    /// a stop glyph; everything else stays on the generic info icon.
    private var iconName: String {
        let lower = text.lowercased()
        if lower.hasPrefix("interrupted") { return "stop.circle" }
        if lower.contains("reconnected") { return "checkmark.circle" }
        if lower.contains("disconnected") { return "bolt.slash" }
        return "info.circle"
    }
}

/// A goal set or cleared, in the same chrome as `PromptCardRow`'s Ship and
/// Review cards. The objective wraps in full, so there is nothing to disclose.
private struct ACPGoalEventCard: View {
    @Environment(\.designScale) private var scale
    let isSet: Bool
    let objective: String
    @Environment(\.theme) private var theme

    var body: some View {
        let tint = isSet ? "goal" : "fg-muted"
        HStack(alignment: .top, spacing: scale.space[2]) {
            Image(systemName: isSet ? "target" : "xmark")
                .font(scale.caption.font(weight: .semibold))
                .foregroundStyle(theme.color(tint))
                .frame(width: 18, height: 18)
                .background(theme.color(tint).opacity(0.16), in: RoundedRectangle(cornerRadius: scale.radius.small))
            Text(isSet ? "Goal set" : "Goal cleared")
                .font(scale.meta.font(weight: .medium))
                .foregroundStyle(theme.color("fg-faint"))
                .fixedSize()
                .padding(.top, scale.space[0])
            Text(objective)
                .font(scale.meta.font(weight: .semibold))
                .foregroundStyle(theme.color(isSet ? "fg" : "fg-muted"))
                .textSelection(.enabled)
                .padding(.top, scale.space[0])
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
        .background(theme.color("bg-2"))
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay(RoundedRectangle(cornerRadius: scale.radius.medium).strokeBorder(theme.color("line"), lineWidth: 0.75))
        .accessibilityElement(children: .combine)
    }
}

/// What a failure incident card can ask its host to do. Every decision about
/// what to offer stays in `ACPFailureIncidentPresentation`.
struct ACPFailureIncidentActions {
    /// Read live, never captured as a value: the rows that show a card are not
    /// re-created when runner state or writer ownership changes.
    var context: (String) -> ACPFailureActionContext
    var isActiveRetry: (String) -> Bool
    var retry: (String) -> Void
    var signIn: (String) -> Void
    var newSession: () -> Void
    /// Fires when the host's state may have changed; the card re-reads `context`.
    var changes: AnyPublisher<Void, Never>

    /// For hosts that only display transcripts.
    static var readOnly: Self {
        .init(
            context: { _ in .readOnly }, isActiveRetry: { _ in false }, retry: { _ in }, signIn: { _ in }, newSession: {},
            changes: Empty(completeImmediately: false).eraseToAnyPublisher())
    }

    @MainActor
    static func driven(
        by manager: ACPSessionManager, session: ACPSession, newSession: @escaping () -> Void
    ) -> Self {
        let sessionId = session.id
        return .init(
            context: { [manager] incidentId in
                manager.failureActionContext(sessionId: sessionId, incidentId: incidentId) ?? .readOnly
            },
            isActiveRetry: { [session] incidentId in session.retryStatus?.incidentId == incidentId },
            retry: { [manager] incidentId in manager.retryFailedPrompt(sessionId: sessionId, incidentId: incidentId) },
            signIn: { [manager] reason in manager.requestSignIn(sessionId: sessionId, reason: reason) },
            newSession: newSession,
            // `ACPSession` does not forward its transcript, which owns `streamingState`.
            // `objectWillChange` fires before the change lands, so hop to the next main-queue turn to re-read.
            changes: Publishers.Merge3(
                manager.objectWillChange, session.objectWillChange, session.transcript.objectWillChange
            )
            .map { _ in () }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher())
    }
}

/// A failure the agent reported, in the notice style, with the recovery actions
/// the adapter listed and this surface can run.
struct ACPFailureIncidentCard: View {
    @Environment(\.designScale) private var scale
    let incident: ACPFailureIncident
    let actions: ACPFailureIncidentActions
    @State private var context: ACPFailureActionContext
    @State private var isActiveRetry: Bool
    @Environment(\.theme) private var theme

    init(incident: ACPFailureIncident, actions: ACPFailureIncidentActions) {
        self.incident = incident
        self.actions = actions
        _context = State(initialValue: actions.context(incident.record.id))
        _isActiveRetry = State(initialValue: actions.isActiveRetry(incident.record.id))
    }

    var body: some View {
        let presentation = ACPFailureIncidentPresentation.make(incident, context: context, isActiveRetry: isActiveRetry)
        VStack(alignment: .leading, spacing: scale.space[1]) {
            HStack(alignment: .firstTextBaseline, spacing: scale.space[2]) {
                Image(systemName: incident.record.severity == .error ? "exclamationmark.octagon" : "exclamationmark.triangle")
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(tint(presentation.tone))
                Text(presentation.title)
                    .font(scale.meta.font(weight: .medium))
                    .foregroundStyle(theme.color(presentation.tone == .muted ? "fg-faint" : "fg"))
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            Text("\(presentation.categoryLabel) · \(presentation.severityLabel)")
                .font(scale.caption.font(weight: .regular))
                .foregroundStyle(theme.color("fg-faint"))
            if let details = presentation.details {
                Text(details)
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color(presentation.tone == .muted ? "fg-faint" : "fg-muted"))
                    .textSelection(.enabled)
            }
            if !presentation.actions.isEmpty {
                HStack(spacing: scale.space[2]) {
                    ForEach(presentation.actions, id: \.self) { action in
                        Button(action.title) { run(action) }
                            .buttonStyle(.borderless)
                            .font(scale.metaFont)
                    }
                }
            }
        }
        .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[2])
        .background(theme.color("bg-1").opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("line"), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        )
        .onReceive(actions.changes) {
            context = actions.context(incident.record.id)
            isActiveRetry = actions.isActiveRetry(incident.record.id)
        }
    }

    private func tint(_ tone: ACPFailureIncidentPresentation.Tone) -> Color {
        switch tone {
        case .error: theme.color("del")
        case .warningActive: theme.color("warn")
        case .muted: theme.color("fg-faint")
        }
    }

    private func run(_ action: ACPFailureAction) {
        switch action {
        case .retry: actions.retry(incident.record.id)
        case .login: actions.signIn(incident.record.title)
        case .newSession: actions.newSession()
        }
    }
}

/// Transient floating card above the composer pill for a live ACP
/// `session.notices` update. Distinct from `ACPSystemNoticeView` above:
/// that one is a muted transcript row for persisted client-side asides,
/// this one is dismissible chrome for an agent-sent, never-persisted
/// out-of-band event. Each severity gets a distinct color/icon; an
/// unrecognized (including `_`-prefixed) severity falls back to the
/// `info` style per spec.
struct ACPSessionNoticeBanner: View {
    @Environment(\.designScale) private var scale
    let notice: ACPSessionNotice
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: scale.space[2]) {
            Image(systemName: iconName)
                .font(scale.metaFont)
                .foregroundStyle(accentColor)
                .padding(.top, scale.space[0])
            VStack(alignment: .leading, spacing: scale.space[0]) {
                Text(notice.title)
                    .font(scale.meta.font(weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                if let description = notice.description, !description.isEmpty {
                    Text(description)
                        .font(scale.metaFont)
                        .foregroundStyle(theme.color("fg-muted"))
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(theme.color("fg-faint"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
        .background(.ultraThinMaterial)
        .background(accentColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(accentColor.opacity(0.35), lineWidth: 0.75)
        )
        .padding(.bottom, scale.space[2])
    }

    private var accentColor: Color {
        notice.severity.behavesAsInfo ? theme.color("info")
            : (notice.severity == .warning ? theme.color("warn") : theme.color("del"))
    }

    private var iconName: String {
        if notice.severity.behavesAsInfo { return "info.circle" }
        return notice.severity == .warning ? "exclamationmark.triangle" : "exclamationmark.octagon"
    }
}
