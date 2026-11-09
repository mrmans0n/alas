import AlasACP
import SwiftUI

struct ACPSessionForkPresentation: Equatable {
    let title: String
    let notice: String?

    init(
        sourceAgentName: String,
        mechanism: ACPSessionForkMechanism,
        via: ACPSessionForkVia? = nil,
        forkPoint: ACPSessionForkPoint? = nil,
        boundaryText: String? = nil
    ) {
        let suffix = via == .btw ? " via /btw" : ""
        switch mechanism {
        case .nativeACP:
            if case .matched(let echo)? = forkPoint?.outcome {
                switch echo.boundary {
                case .message:
                    let preview = boundaryText.map { Self.preview($0) } ?? ""
                    title = preview.isEmpty
                        ? "Forked from \(sourceAgentName)\(suffix) after this message"
                        : "Forked from \(sourceAgentName)\(suffix) after “\(preview)”"
                case .turn:
                    title = "Forked from \(sourceAgentName)\(suffix) after this turn"
                }
            } else {
                title = "Forked from \(sourceAgentName)\(suffix)"
            }
            notice = nil
        case .transcriptTransfer:
            title = "Conversation imported from \(sourceAgentName)\(suffix)"
            let base = "Provider-specific tool state, hidden context, and attachments were not transferred. This chat shares the source chat’s current worktree."
            if case .unmatched(let failure)? = forkPoint?.outcome {
                notice = Self.reason(failure, agent: sourceAgentName) + " " + base
            } else {
                notice = base
            }
        }
    }

    private static func reason(_ failure: ACPForkPointFailure, agent: String) -> String {
        switch failure {
        case .notFound:
            "\(agent) couldn't find this message in its history, so the conversation was imported instead of forked natively."
        case .malformed:
            "\(agent) rejected the fork point, so the conversation was imported instead of forked natively."
        case .unsupported:
            "This \(agent) version can't fork at an earlier message, so the conversation was imported instead of forked natively."
        case .sourceChanged:
            "The source chat changed this message before the fork started, so the conversation was imported instead of forked natively."
        case .missingEcho, .mismatchedEcho:
            "\(agent) forked at a different point, so that fork was discarded and the conversation was imported instead."
        case .unavailable:
            "\(agent) couldn't fork at this message right now, so the conversation was imported instead."
        }
    }

    /// First non-empty line, whitespace collapsed, cut with "…" past `limit`.
    static func preview(_ text: String, limit: Int = 48) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty } ?? ""
        guard line.count > limit else { return line }
        return String(line.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

struct ACPSessionForkDivider: View {
    @Environment(\.designScale) private var scale
    let presentation: ACPSessionForkPresentation
    let onOpenSource: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: scale.space[2]) {
            HStack(spacing: scale.space[2]) {
                Rectangle().fill(theme.color("line")).frame(height: 1)
                Button(presentation.title, action: onOpenSource)
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.color("accent"))
                    .help("Open source chat")
                Rectangle().fill(theme.color("line")).frame(height: 1)
            }
            if let notice = presentation.notice {
                Text(notice)
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color("fg-muted"))
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
