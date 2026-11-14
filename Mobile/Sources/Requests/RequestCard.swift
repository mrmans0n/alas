import AlasRemoteKit
import SwiftUI

extension TranscriptSession {
    var hasPendingRequest: Bool {
        shows(permission, .permission) || shows(question, .question) || shows(plan, .plan) || shows(elicitation, .elicitation)
    }

    /// A request is shown until this phone answers it.
    func shows(_ request: (some Any)?, _ kind: RequestKind) -> Bool {
        request != nil && !answered.contains(kind)
    }

    /// Keys a card's state on the request itself: an identical re-send keeps it, a different
    /// request (even one reusing the wire id) resets it.
    func cardID(_ kind: RequestKind) -> String {
        "\(kind)-\(requestRevisions[kind] ?? 0)"
    }
}

extension EnvironmentValues {
    /// True when the card floats above the composer (glass); false inside a list (flat).
    @Entry var cardFloats = false
}

/// The pending request of a session, one card per kind. Shown above the composer and in the
/// Inbox. Per-card state lives in the kind's view and is keyed by `cardID`, so a request the
/// host re-sends right after resolving it (resubscribe, take-over) keeps what was typed.
struct RequestCard: View {
    let session: TranscriptSession

    var body: some View {
        Group {
            if let permission = session.permission, session.shows(permission, .permission) {
                PermissionCard(session: session, payload: permission).id(session.cardID(.permission))
            } else if let question = session.question, session.shows(question, .question) {
                QuestionCard(session: session, payload: question).id(session.cardID(.question))
            } else if let plan = session.plan, session.shows(plan, .plan) {
                PlanCard(session: session, payload: plan).id(session.cardID(.plan))
            } else if let elicitation = session.elicitation, session.shows(elicitation, .elicitation) {
                ElicitationCard(session: session, payload: elicitation).id(session.cardID(.elicitation))
            }
        }
        // A resolve-then-resend burst must not flash.
        .transaction { $0.animation = nil }
        .disabled(session.hostState != .online)
    }
}

/// Shared frame: tinted icon, kind label, title, then the kind's content.
struct CardChrome<Content: View>: View {
    let icon: String
    let tint: Color
    let kind: String
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.cardFloats) private var floats

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.16), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind).font(.caption2.weight(.bold)).textCase(.uppercase).tracking(0.6).foregroundStyle(tint)
                    Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardSurface(floats: floats))
    }
}

struct CardSurface: ViewModifier {
    let floats: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        if floats {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(Color(.secondarySystemBackground), in: shape)
        }
    }
}

/// A full-width action: filled when primary, outlined otherwise.
struct CardButton: View {
    let title: String
    var subtitle: String?
    var primary = false
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        let label = VStack(spacing: 2) {
            Text(title).font(.body.weight(.semibold))
            if let subtitle { Text(subtitle).font(.caption).opacity(0.75) }
        }
        .frame(maxWidth: .infinity, minHeight: 28)
        if primary {
            Button(role: role, action: action) { label }
                .buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.roundedRectangle(radius: 16))
        } else {
            Button(role: role, action: action) { label }
                .buttonStyle(.bordered).controlSize(.large).buttonBorderShape(.roundedRectangle(radius: 16))
        }
    }
}

// MARK: Permission

private struct PermissionCard: View {
    let session: TranscriptSession
    let payload: RemotePermissionPayload

    var body: some View {
        CardChrome(icon: "lock.shield.fill", tint: .orange, kind: "Permission",
                   title: payload.title ?? "Allow \u{201C}\(payload.toolName)\u{201D}?") {
            if let server = payload.mcpServerName {
                Label(server, systemImage: "server.rack")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
            if let command = payload.commandSummary, !command.isEmpty {
                // Never truncated: a long command scrolls instead.
                let text = Text(command)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ViewThatFits(in: .vertical) {
                    text
                    ScrollView { text }.frame(height: 170)
                }
                .frame(maxHeight: 170)
                .padding(12)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if let reason = payload.reason, !reason.isEmpty {
                Text(reason).font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                ForEach(payload.options, id: \.optionId) { option in
                    CardButton(title: option.name, subtitle: option.description, primary: isFilled(option)) {
                        session.answerPermission(optionId: option.optionId)
                    }
                }
            }
        }
    }

    private func isFilled(_ option: RemotePermissionOption) -> Bool {
        payload.defaultToNo ? option.kind == "reject_once" : option.kind.hasPrefix("allow")
    }
}

// MARK: Question

private struct QuestionCard: View {
    let session: TranscriptSession
    let payload: RemoteQuestionPayload
    @State private var chosen: [String: Set<String>] = [:]

    var body: some View {
        CardChrome(icon: "questionmark.bubble.fill", tint: .blue, kind: "Question",
                   title: payload.title ?? (payload.questions.count == 1 ? "The agent has a question" : "The agent has questions")) {
            ForEach(payload.questions, id: \.id) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.prompt).font(.subheadline.weight(.semibold))
                    ForEach(question.options, id: \.id) { option in
                        optionRow(question, option)
                    }
                }
            }
            CardButton(title: "Submit", primary: true) {
                session.answerQuestion(payload.questions.map { q in
                    RemoteQuestionAnswer(questionId: q.id, selectedOptionIds: q.options.map(\.id).filter { chosen[q.id]?.contains($0) == true })
                })
            }
            .disabled(!payload.questions.allSatisfy { !(chosen[$0.id] ?? []).isEmpty })
        }
    }

    private func optionRow(_ question: RemoteQuestion, _ option: RemoteQuestionOption) -> some View {
        let on = chosen[question.id]?.contains(option.id) == true
        let symbol = question.allowMultiple ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle")
        return Button {
            var set = chosen[question.id] ?? []
            if question.allowMultiple {
                if on { set.remove(option.id) } else { set.insert(option.id) }
            } else {
                set = [option.id]
            }
            chosen[question.id] = set
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(on ? Color.accentColor : .secondary)
                Text(option.label).foregroundStyle(.primary).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(on ? Color.accentColor.opacity(0.14) : Color(.secondarySystemBackground).opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: Plan

private struct PlanCard: View {
    let session: TranscriptSession
    let payload: RemotePlanPayload
    @State private var rejecting = false
    @State private var reason = ""

    private var trimmedReason: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        CardChrome(icon: "list.clipboard.fill", tint: .purple, kind: "Plan", title: payload.name) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !payload.overview.isEmpty { Text(payload.overview).font(.subheadline).foregroundStyle(.secondary) }
                    if !payload.plan.isEmpty { AgentMarkdown(id: "plan-\(payload.toolCallId)", text: payload.plan) }
                    todoList(payload.todos)
                    // Phased plans may carry all their tasks here, with no top-level todos.
                    ForEach(Array(payload.phases.enumerated()), id: \.offset) { _, phase in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(phase.name).font(.subheadline.weight(.semibold))
                            todoList(phase.todos)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .scrollBounceBehavior(.basedOnSize)
            if rejecting {
                TextField("Why not? The agent will see this.", text: $reason, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(12)
                    .background(Color(.secondarySystemBackground).opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack(spacing: 8) {
                    CardButton(title: "Back") { rejecting = false }
                    CardButton(title: "Send", primary: true, role: .destructive) {
                        session.answerPlan(action: "reject", reason: trimmedReason)
                    }
                    .disabled(trimmedReason.isEmpty)
                }
            } else {
                HStack(spacing: 8) {
                    CardButton(title: "Reject") { rejecting = true }
                    CardButton(title: "Accept", primary: true) { session.answerPlan(action: "accept", reason: nil) }
                }
            }
        }
    }

    private func todoList(_ todos: [RemotePlanTodo]) -> some View {
        ForEach(todos, id: \.id) { todo in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon(todo.status)).foregroundStyle(todo.status == "completed" ? Color.green : .secondary)
                Text(todo.content).font(.subheadline)
            }
        }
    }

    private func icon(_ status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.dotted"
        default: "circle"
        }
    }
}

// MARK: Elicitation

private struct ElicitationCard: View {
    let session: TranscriptSession
    let payload: RemoteElicitationPayload
    @Environment(\.openURL) private var openURL

    /// Only web links with a host, as on the Mac.
    private var webURL: URL? {
        guard let url = payload.url.flatMap(URL.init(string:)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil else { return nil }
        return url
    }

    var body: some View {
        CardChrome(icon: "text.badge.checkmark", tint: .teal, kind: "Request", title: payload.title ?? "The agent needs input") {
            Text(payload.message).font(.subheadline).foregroundStyle(.secondary)
            if payload.mode == "url" {
                if let url = webURL {
                    Label(url.absoluteString, systemImage: "globe")
                        .font(.subheadline.weight(.medium))
                        .textSelection(.enabled)
                    CardButton(title: "Open in Browser", primary: true) {
                        // Accepted only once the link actually opened.
                        openURL(url) { opened in
                            if opened { session.answerElicitation(action: "accept", content: [:]) }
                        }
                    }
                } else {
                    Label("This link can\u{2019}t be opened.", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline).foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    CardButton(title: "Decline") { session.answerElicitation(action: "decline", content: nil) }
                    CardButton(title: "Cancel") { session.answerElicitation(action: "cancel", content: nil) }
                }
            } else {
                ElicitationFormView(session: session, payload: payload)
            }
        }
    }
}
