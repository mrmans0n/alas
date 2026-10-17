import AppKit
import SwiftUI

/// What a prompt card needs from the app: live review-comment state and
/// the footer action. Nil in read-only hosts, which hide both.
struct ACPPromptCardContext {
    var reviewComments: ReviewCommentStatusModel?
    var perform: @MainActor (ACPPromptCard.Action) -> Void
    /// The toolbar Ship pill's current state, shown when hovering a `/ship`
    /// badge; nil where the session doesn't offer Ship.
    var shipStatus: (@MainActor () -> ACPShipStatus?)? = nil
}

/// What the `/ship` hover card shows about the session's PR.
struct ACPShipStatus {
    let presentation: ShepherdPresentation
    let branch: String
}

private struct ACPPromptCardContextKey: EnvironmentKey {
    static let defaultValue: ACPPromptCardContext? = nil
}

extension EnvironmentValues {
    /// Re-injected into each hosted transcript row by `ACPTranscriptScroller.wrapRow`.
    var acpPromptCardContext: ACPPromptCardContext? {
        get { self[ACPPromptCardContextKey.self] }
        set { self[ACPPromptCardContextKey.self] = newValue }
    }
}

/// A turn Alas injected (review feedback, Ship, PR shepherd), shown from its
/// structured card. The exact instruction the agent got is one click away.
struct PromptCardRow: View {
    let card: ACPPromptCard
    let text: String
    let contentMaxWidth: CGFloat
    let typography: ACPChatTypography
    /// Queue rows show only the header and facts.
    var isCompact = false
    var onInstructionExpandedChange: ((Bool) -> Void)?
    @State private var showsInstruction: Bool
    @Environment(\.theme) private var theme
    @Environment(\.acpPromptCardContext) private var context

    init(
        card: ACPPromptCard, text: String, contentMaxWidth: CGFloat, typography: ACPChatTypography,
        isCompact: Bool = false, instructionExpanded: Bool = false,
        onInstructionExpandedChange: ((Bool) -> Void)? = nil
    ) {
        self.card = card
        self.text = text
        self.contentMaxWidth = contentMaxWidth
        self.typography = typography
        self.isCompact = isCompact
        self.onInstructionExpandedChange = onInstructionExpandedChange
        _showsInstruction = State(initialValue: instructionExpanded)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if !card.facts.isEmpty { facts }
                if !isCompact {
                    if card.sections.isEmpty, card.origin == .shepherd {
                        Text("Nothing needs attention right now.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.color("fg-muted"))
                            .padding(.horizontal, 12).padding(.bottom, 8)
                    }
                    ForEach(Array(card.sections.enumerated()), id: \.offset) { _, section in
                        sectionView(section)
                    }
                    footer
                }
            }
            .background(theme.color("bg-2"))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color("line"), lineWidth: 0.75))
            .frame(maxWidth: contentMaxWidth * 0.88, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header and facts

    private var header: some View {
        let style = Self.style(for: card.origin)
        return HStack(spacing: 8) {
            Image(systemName: style.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.color(style.tint))
                .frame(width: 18, height: 18)
                .background(theme.color(style.tint).opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
            Text(style.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.color("fg-faint"))
            Text(card.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.color("fg"))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var facts: some View {
        HStack(spacing: 6) {
            ForEach(Array(card.facts.enumerated()), id: \.offset) { _, fact in
                Text(fact.text)
                    .font(.system(size: 11, design: fact.kind == .revision || fact.kind == .branch ? .monospaced : .default))
                    .foregroundStyle(theme.color("fg-muted"))
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(theme.color("bg-3").opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.color("line"), lineWidth: 0.75))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: Sections

    private func sectionView(_ section: ACPPromptCard.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = section.title {
                if card.origin == .review {
                    pathText(title)
                } else {
                    Text(title.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(theme.color("fg-faint"))
                }
            }
            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                itemView(item)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(theme.color("line")).frame(height: 0.75) }
    }

    private func itemView(_ item: ACPPromptCard.Item) -> some View {
        let live = item.reviewCommentID.flatMap { context?.reviewComments?.status(for: $0) }
        let pill = Self.pill(status: item.status, live: live)
        return VStack(alignment: .leading, spacing: 4) {
            if card.origin != .review, let path = item.location?.path { pathText(path) }
            HStack(spacing: 6) {
                if let lines = Self.lineLabel(item.location) {
                    Text(lines)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.color("accent"))
                        .padding(.horizontal, 5)
                        .background(theme.color("accent").opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
                if let side = item.location?.side {
                    Text(side).font(.system(size: 10.5)).foregroundStyle(theme.color("fg-faint"))
                }
                if let author = item.author {
                    Text(author).font(.system(size: 11)).foregroundStyle(theme.color("fg-muted"))
                }
                Spacer(minLength: 0)
                if let pill {
                    Text(pill.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.color(pill.tint))
                        .padding(.horizontal, 7)
                        .overlay(Capsule().strokeBorder(theme.color(pill.tint).opacity(0.4), lineWidth: 0.75))
                }
            }
            if let body = item.bodyMarkdown {
                ACPMarkdownText(raw: body, typography: typography.flatteningHeadings())
            }
            if let excerpt = item.excerpt { excerptView(excerpt) }
            if live?.state == .resolved, let reply = live?.agentReply {
                Text("Agent: \(reply)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.color("fg-muted"))
                    .lineLimit(2)
            }
            if let url = item.url {
                Button(card.origin == .shepherd && item.excerpt != nil ? "Full log" : "Open link") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-faint"))
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.color(Self.ruleTint(status: item.status, live: live, origin: card.origin))).frame(width: 2)
        }
    }

    @ViewBuilder
    private func excerptView(_ excerpt: ACPPromptCard.Excerpt) -> some View {
        switch excerpt.style {
        case .code:
            VStack(alignment: .leading, spacing: 2) {
                Text("Commented code")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.color("fg-faint"))
                ACPMarkdownText(raw: Self.fenced(excerpt), typography: typography)
            }
        case .log:
            Text(excerpt.text)
                .font(.system(size: typography.codeSize, design: .monospaced))
                .foregroundStyle(theme.color("fg-muted"))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.color("bg-3").opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func pathText(_ path: String) -> some View {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return (Text(directory.isEmpty ? "" : directory + "/").foregroundColor(theme.color("fg-faint"))
            + Text(name).foregroundColor(theme.color("fg")).fontWeight(.semibold))
            .font(.system(size: 11.5, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.head)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                if let action = card.action, let context {
                    Button(Self.actionLabel(action)) { context.perform(action) }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.color("accent"))
                }
                Spacer(minLength: 0)
                Button {
                    showsInstruction.toggle()
                    onInstructionExpandedChange?(showsInstruction)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showsInstruction ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                        Text("Instruction sent to agent")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.color("fg-muted"))
                .accessibilityValue(showsInstruction ? "Expanded" : "Collapsed")
            }
            .font(.system(size: 11.5))
            if showsInstruction {
                ACPMarkdownText(raw: text, typography: typography.flatteningHeadings())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Rectangle().fill(theme.color("line")).frame(height: 0.75) }
    }

    // MARK: Decisions

    private struct OriginStyle {
        let symbol: String
        let label: String
        let tint: String
    }

    private static func style(for origin: ACPPromptCard.Origin) -> OriginStyle {
        switch origin {
        case .review: OriginStyle(symbol: "text.bubble", label: "Review", tint: "accent")
        case .ship: OriginStyle(symbol: "arrow.up.circle", label: "Ship", tint: "add")
        case .shepherd: OriginStyle(symbol: "arrow.triangle.2.circlepath", label: "PR shepherd", tint: "warn")
        default: OriginStyle(symbol: "sparkles", label: "Alas", tint: "fg-muted")
        }
    }

    private static func lineLabel(_ location: ACPPromptCard.Location?) -> String? {
        guard let start = location?.startLine else { return nil }
        guard let end = location?.endLine, end != start else { return "L\(start)" }
        return "L\(start)–\(end)"
    }

    private static func pill(
        status: ACPPromptCard.Item.Status?, live: ReviewCommentStatusModel.Status?
    ) -> (label: String, tint: String)? {
        if let live {
            switch live.state {
            case .active: return ("Open", "fg-muted")
            case .resolved: return ("Resolved", "add")
            case .dismissed: return ("Dismissed", "fg-faint")
            }
        }
        switch status {
        case .failed?: return ("Failed", "del")
        case .cancelled?: return ("Cancelled", "warn")
        default: return nil
        }
    }

    private static func ruleTint(
        status: ACPPromptCard.Item.Status?, live: ReviewCommentStatusModel.Status?, origin: ACPPromptCard.Origin
    ) -> String {
        if live?.state == .resolved { return "add" }
        if status == .failed || status == .conflict { return "del" }
        if status == .cancelled || origin == .shepherd { return "warn" }
        return "accent"
    }

    private static func actionLabel(_ action: ACPPromptCard.Action) -> String {
        switch action {
        case .url: "Open in browser"
        case .reviewSession, .reviewChanges: "Open in Review"
        }
    }

    /// A fence longer than any backtick run in the excerpt, so the code
    /// can't close it early.
    private static func fenced(_ excerpt: ACPPromptCard.Excerpt) -> String {
        var longest = 0
        var run = 0
        for character in excerpt.text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\(excerpt.language ?? "")\n\(excerpt.text)\n\(fence)"
    }
}
