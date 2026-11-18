import AlasHighlight
import AlasRemoteKit
import SwiftUI

/// The phone's `ACPQuestionAnswerCard`: a resolved question and its answers, with the options
/// behind "Details". Expansion is the transcript's, so the cell re-measures.
struct QuestionAnswerCard: View {
    let answer: ACPAnsweredQuestion
    let isExpanded: Bool
    let toggle: () -> Void

    private var hasDetails: Bool {
        answer.items.contains { !$0.options.isEmpty || $0.description?.isEmpty == false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble").accessibilityHidden(true)
                Text(answer.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Question")
                Spacer(minLength: 8)
                Label(answer.statusLabel, systemImage: statusIcon).foregroundStyle(Color.secondary)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 12) {
                if !answer.message.isEmpty {
                    Text(answer.message).font(.subheadline.weight(.medium))
                }
                ForEach(answer.items.indices, id: \.self) { index in
                    let item = answer.items[index]
                    VStack(alignment: .leading, spacing: 4) {
                        if item.question != answer.message {
                            Text(item.question).font(.subheadline.weight(.medium))
                        }
                        if let text = item.answer {
                            Text(text).font(.subheadline).foregroundStyle(Color.accentColor)
                        } else if answer.outcome == .answered {
                            Text("No answer provided").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if hasDetails {
                    Button(action: toggle) {
                        Label(isExpanded ? "Hide details" : "Details",
                              systemImage: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Hide question details" : "Show question details")
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                }
                if isExpanded { details }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            ForEach(answer.items.indices, id: \.self) { index in
                let item = answer.items[index]
                if !item.options.isEmpty || item.description?.isEmpty == false {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.question).font(.caption.weight(.semibold))
                        if let description = item.description, !description.isEmpty {
                            Text(description).font(.footnote)
                        }
                        ForEach(item.options.indices, id: \.self) { optionIndex in
                            let option = item.options[optionIndex]
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: option.selected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(option.selected ? Color.accentColor : Color(.tertiaryLabel))
                                    .accessibilityLabel(option.selected ? "Selected" : "Not selected")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title).foregroundStyle(.primary)
                                    if let description = option.description, !description.isEmpty {
                                        Text(description)
                                    }
                                }
                            }
                            .font(.footnote)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .foregroundStyle(.secondary)
    }

    private var statusIcon: String {
        switch answer.outcome {
        case .answered: "checkmark"
        case .skipped: "forward"
        case .cancelled: "xmark"
        case .opened: "arrow.up.right"
        }
    }
}

/// The phone's read-only `ACPFailureIncidentCard`: peers cannot retry, sign in or start a session.
struct FailureIncidentCard: View {
    let incident: RemoteFailureIncident

    var body: some View {
        let isError = incident.severity == .error
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isError ? "exclamationmark.octagon" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(isError ? Color.red : Color(.tertiaryLabel))
                    .accessibilityHidden(true)
                Text(incident.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isError ? .primary : .tertiary)
            }
            Text("\(incident.knownCategory.label) · \(incident.severity.label)")
                .font(.caption).foregroundStyle(.tertiary)
            if let details = incident.details {
                Text(details).font(.footnote).foregroundStyle(isError ? .secondary : .tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        .accessibilityElement(children: .combine)
    }
}

/// The phone's `PromptCardRow` for outcome cards: origin, title, facts and sections. Only a `.url`
/// action is shown, and it goes to the system.
struct OutcomeCard: View {
    let id: String
    let card: RemotePromptCard
    @Environment(\.openURL) private var openURL

    var body: some View {
        let style = Self.style(card.origin)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: style.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(style.tint)
                    .frame(width: 22, height: 22)
                    .background(style.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
                Text(style.label).font(.subheadline.weight(.medium)).foregroundStyle(.tertiary)
                Text(card.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if !card.facts.isEmpty {
                // Facts wrap onto their own lines on a narrow phone rather than truncating.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { facts }
                    VStack(alignment: .leading, spacing: 6) { facts }
                }
                .padding([.horizontal, .bottom], 12)
            }
            if card.sections.isEmpty, card.origin == .shepherd {
                Text("Nothing needs attention right now.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], 12)
            }
            ForEach(card.sections.indices, id: \.self) { section(card.sections[$0], index: $0) }
            if let url = card.actionURL {
                Button("Open in browser") { openURL(url) }
                    .font(.footnote)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Divider() }
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var facts: some View {
        ForEach(card.facts.indices, id: \.self) { index in
            let fact = card.facts[index]
            Text(fact.text)
                .font(fact.kind == .revision || fact.kind == .branch
                    ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private func section(_ section: RemotePromptCard.Section, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = section.title {
                if card.origin == .review {
                    pathText(title)
                } else {
                    Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            ForEach(section.items.indices, id: \.self) { itemIndex in
                item(section.items[itemIndex], id: "\(id):\(index):\(itemIndex)")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider() }
    }

    private func item(_ item: RemotePromptCard.Item, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if card.origin != .review, let path = item.location?.path { pathText(path) }
            HStack(spacing: 8) {
                if let lines = Self.lineLabel(item.location) {
                    Text(lines)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 4)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel(Self.lineLabel(item.location, spoken: true) ?? lines)
                }
                if let side = item.location?.side { Text(side).font(.caption).foregroundStyle(.tertiary) }
                if let author = item.author { Text(author).font(.footnote).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if let pill = Self.pill(item.status) {
                    Text(pill.label)
                        .font(.caption).foregroundStyle(pill.tint)
                        .padding(.horizontal, 6)
                        .overlay(Capsule().strokeBorder(pill.tint.opacity(0.4)))
                }
            }
            if let body = item.bodyMarkdown { AgentMarkdown(id: id, text: body) }
            if let excerpt = item.excerpt, excerpt.style == .code {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Commented code").font(.caption).foregroundStyle(.tertiary)
                    AgentMarkdown(id: "\(id):excerpt", text: Self.fenced(excerpt, path: item.location?.path))
                }
            } else if let excerpt = item.excerpt {
                Text(excerpt.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            if let url = item.url {
                Button(card.origin == .shepherd && item.excerpt != nil ? "Full log" : "Open link") { openURL(url) }
                    .font(.footnote)
            }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) { Rectangle().fill(Self.ruleTint(item.status, card.origin)).frame(width: 2) }
    }

    /// Directory dimmed, file name in bold, cut from the front.
    private func pathText(_ path: String) -> some View {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return (Text(directory.isEmpty ? "" : directory + "/").foregroundColor(.secondary)
            + Text(name).fontWeight(.semibold))
            .font(.system(.footnote, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.head)
    }

    /// "L12" or "L12–14"; spoken as "Line 12" or "Lines 12 to 14".
    private static func lineLabel(_ location: RemotePromptCard.Location?, spoken: Bool = false) -> String? {
        guard let start = location?.startLine else { return nil }
        guard let end = location?.endLine, end != start else { return spoken ? "Line \(start)" : "L\(start)" }
        return spoken ? "Lines \(start) to \(end)" : "L\(start)–\(end)"
    }

    /// A fence longer than any backtick run in the excerpt, so the code can't close it early. The
    /// language falls back to the commented file's.
    private static func fenced(_ excerpt: RemotePromptCard.Excerpt, path: String?) -> String {
        var longest = 0
        var run = 0
        for character in excerpt.text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let language = excerpt.language ?? ACPCodeLanguage.highlighterExtension(forPath: path) ?? ""
        return "\(fence)\(language)\n\(excerpt.text)\n\(fence)"
    }

    /// `PromptCardRow.style(for:)`, with the Mac theme's tints as system colours.
    private static func style(_ origin: RemotePromptCard.Origin) -> (symbol: String, label: String, tint: Color) {
        switch origin {
        case .review: ("text.bubble", "Review", .accentColor)
        case .ship: ("paperplane.fill", "Ship", .green)
        case .shepherd: ("arrow.triangle.2.circlepath", "PR shepherd", .orange)
        case .merged: ("checkmark.circle.fill", "Merged", .green)
        case .closed: ("xmark.circle", "Closed", .secondary)
        case .queued: ("list.bullet.rectangle", "Merge queue", .yellow)
        default: ("sparkles", "Alas", .secondary)
        }
    }

    private static func pill(_ status: RemotePromptCard.Item.Status?) -> (label: String, tint: Color)? {
        switch status {
        case .failed?: ("Failed", .red)
        case .cancelled?: ("Cancelled", .orange)
        default: nil
        }
    }

    private static func ruleTint(_ status: RemotePromptCard.Item.Status?, _ origin: RemotePromptCard.Origin) -> Color {
        if status == .failed || status == .conflict { return .red }
        if status == .cancelled || origin == .shepherd { return .orange }
        return .accentColor
    }
}
