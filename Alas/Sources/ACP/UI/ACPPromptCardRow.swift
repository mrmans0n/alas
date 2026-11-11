import AppKit
import SwiftUI

/// What a prompt card needs from the app: live review-comment state and
/// the footer action. Nil in read-only hosts, which hide both.
struct ACPPromptCardContext {
    var reviewComments: ReviewCommentStatusModel?
    var perform: @MainActor (ACPPromptCard.Action) -> Void
    /// Alas commands the composer offers this session, badged in sent
    /// messages like the agent's own.
    var alasCommands: @MainActor () -> [ACPPromptSuggestion] = { [] }
    /// The toolbar Ship pill's current state, shown when hovering a `/ship`
    /// badge; nil where the session doesn't offer Ship.
    var shipStatus: (@MainActor () -> ACPShipStatus?)? = nil
    /// Opens a skill command's `SKILL.md`; nil where the host cannot.
    var openSkill: (@MainActor (ACPPromptSuggestion) -> Void)? = nil
}

/// What the `/ship` hover card shows about the session's PR or gg stack.
struct ACPShipStatus {
    let presentation: ShepherdPresentation
    /// The branch, or the gg stack, Ship would publish.
    let branch: String
    /// Leads `branch` while nothing is published.
    var unshippedLabel = "No PR yet for"
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
/// Outcome cards reuse it with empty `text`: nothing was sent, so there is
/// nothing to disclose.
struct PromptCardRow: View {
    @Environment(\.designScale) private var scale
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
                            .font(scale.metaFont)
                            .foregroundStyle(theme.color("fg-muted"))
                            .padding(.horizontal, scale.space[3]).padding(.bottom, scale.space[2])
                    }
                    ForEach(Array(card.sections.enumerated()), id: \.offset) { _, section in
                        sectionView(section)
                    }
                    if let action = card.action, let context { actionRow(action, context: context) }
                    if showsInstruction { instruction }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleInstruction)
            .background(theme.color("bg-2"))
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
            .overlay(RoundedRectangle(cornerRadius: scale.radius.medium).strokeBorder(theme.color("line"), lineWidth: 0.75))
            .frame(maxWidth: contentMaxWidth * 0.88, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header and facts

    /// A real button outside the queue, so keyboard and VoiceOver users can
    /// reach the disclosure the rest of the card offers by click.
    @ViewBuilder
    private var header: some View {
        if discloses {
            Button(action: toggleInstruction) { headerContent }
                .buttonStyle(.plain)
                .accessibilityValue(showsInstruction ? "Expanded" : "Collapsed")
        } else {
            headerContent
        }
    }

    /// Queue rows show only the header, and an outcome card sent nothing.
    private var discloses: Bool { !isCompact && !text.isEmpty }

    private var headerContent: some View {
        let style = Self.style(for: card.origin)
        return HStack(spacing: scale.space[2]) {
            Image(systemName: style.symbol)
                .font(scale.caption.font(weight: .semibold))
                .foregroundStyle(theme.color(style.tint))
                .frame(width: 18, height: 18)
                .background(theme.color(style.tint).opacity(0.16), in: RoundedRectangle(cornerRadius: scale.radius.small))
            Text(style.label)
                .font(scale.meta.font(weight: .medium))
                .foregroundStyle(theme.color("fg-faint"))
            Text(card.title)
                .font(scale.meta.font(weight: .semibold))
                .foregroundStyle(theme.color("fg"))
                .lineLimit(1)
                .truncationMode(.tail)
            if discloses {
                Spacer(minLength: 6)
                Image(systemName: "chevron.down")
                    .font(scale.glyphFont)
                    .foregroundStyle(theme.color("fg-faint"))
                    .rotationEffect(.degrees(showsInstruction ? 180 : 0))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var facts: some View {
        HStack(spacing: scale.space[2]) {
            ForEach(Array(card.facts.enumerated()), id: \.offset) { _, fact in
                Text(fact.text)
                    .font(scale.meta.font(design: fact.kind == .revision || fact.kind == .branch ? .monospaced : .default))
                    .foregroundStyle(theme.color("fg-muted"))
                    .lineLimit(1)
                    .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[0])
                    .background(theme.color("bg-3").opacity(0.7), in: RoundedRectangle(cornerRadius: scale.radius.small))
                    .overlay(RoundedRectangle(cornerRadius: scale.radius.small).strokeBorder(theme.color("line"), lineWidth: 0.75))
            }
        }
        .padding(.horizontal, scale.space[3])
        .padding(.bottom, scale.space[2])
    }

    // MARK: Sections

    private func sectionView(_ section: ACPPromptCard.Section) -> some View {
        VStack(alignment: .leading, spacing: scale.space[2]) {
            if let title = section.title {
                if card.origin == .review {
                    pathText(title)
                } else {
                    Text(title.uppercased())
                        .font(scale.caption.font(weight: .semibold))
                        .foregroundStyle(theme.color("fg-faint"))
                }
            }
            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                itemView(item)
            }
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(theme.color("line")).frame(height: 0.75) }
    }

    private func itemView(_ item: ACPPromptCard.Item) -> some View {
        let live = item.reviewCommentID.flatMap { context?.reviewComments?.status(for: $0) }
        let pill = Self.pill(status: item.status, live: live)
        return VStack(alignment: .leading, spacing: scale.space[1]) {
            if card.origin != .review, let path = item.location?.path { pathText(path) }
            HStack(spacing: scale.space[2]) {
                if let lines = Self.lineLabel(item.location) {
                    Text(lines)
                        .font(scale.caption.font(weight: .regular, design: .monospaced))
                        .foregroundStyle(theme.color("accent"))
                        .padding(.horizontal, scale.space[1])
                        .background(theme.color("accent").opacity(0.12), in: RoundedRectangle(cornerRadius: scale.radius.small))
                }
                if let side = item.location?.side {
                    Text(side).font(scale.caption.font(weight: .regular)).foregroundStyle(theme.color("fg-faint"))
                }
                if let author = item.author {
                    Text(author).font(scale.metaFont).foregroundStyle(theme.color("fg-muted"))
                }
                Spacer(minLength: 0)
                if let pill {
                    Text(pill.label)
                        .font(scale.caption.font(weight: .regular))
                        .foregroundStyle(theme.color(pill.tint))
                        .padding(.horizontal, scale.space[2])
                        .overlay(Capsule().strokeBorder(theme.color(pill.tint).opacity(0.4), lineWidth: 0.75))
                }
            }
            if let body = item.bodyMarkdown {
                ACPMarkdownText(raw: ACPMarkdownParser.hidingHTMLComments(body), typography: typography.flatteningHeadings())
            }
            if let excerpt = item.excerpt { excerptView(excerpt) }
            if live?.state == .resolved, let reply = live?.agentReply {
                Text("Agent: \(reply)")
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color("fg-muted"))
                    .lineLimit(2)
            }
            if let url = item.url {
                Button(card.origin == .shepherd && item.excerpt != nil ? "Full log" : "Open link") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.plain)
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg-faint"))
            }
        }
        .padding(.leading, scale.space[2])
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.color(Self.ruleTint(status: item.status, live: live, origin: card.origin))).frame(width: 2)
        }
    }

    @ViewBuilder
    private func excerptView(_ excerpt: ACPPromptCard.Excerpt) -> some View {
        switch excerpt.style {
        case .code:
            VStack(alignment: .leading, spacing: scale.space[0]) {
                Text("Commented code")
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(theme.color("fg-faint"))
                ACPMarkdownText(raw: Self.fenced(excerpt), typography: typography)
            }
        case .log:
            Text(excerpt.text)
                .font(.system(size: typography.codeSize, design: .monospaced))
                .foregroundStyle(theme.color("fg-muted"))
                .textSelection(.enabled)
                .padding(scale.space[2])
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.color("bg-3").opacity(0.6), in: RoundedRectangle(cornerRadius: scale.radius.medium))
        }
    }

    private func pathText(_ path: String) -> some View {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return (Text(directory.isEmpty ? "" : directory + "/").foregroundColor(theme.color("fg-faint"))
            + Text(name).foregroundColor(theme.color("fg")).fontWeight(.semibold))
            .font(scale.meta.font(design: .monospaced))
            .lineLimit(1)
            .truncationMode(.head)
    }

    // MARK: Footer

    /// The whole card discloses the exact instruction, like a tool card.
    private func toggleInstruction() {
        guard discloses else { return }
        showsInstruction.toggle()
        onInstructionExpandedChange?(showsInstruction)
    }

    private func actionRow(_ action: ACPPromptCard.Action, context: ACPPromptCardContext) -> some View {
        Button(Self.actionLabel(action)) { context.perform(action) }
            .buttonStyle(.plain)
            .font(scale.metaFont)
            .foregroundStyle(theme.color("accent"))
            .padding(.horizontal, scale.space[3])
            .padding(.vertical, scale.space[2])
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(theme.color("line")).frame(height: 0.75) }
    }

    private var instruction: some View {
        ACPMarkdownText(raw: text, typography: typography.flatteningHeadings())
            .padding(.horizontal, scale.space[3])
            .padding(.vertical, scale.space[2])
            .frame(maxWidth: .infinity, alignment: .leading)
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
        case .ship: OriginStyle(symbol: ShepherdBadgeState.noRequest.symbolName, label: "Ship", tint: "add")
        case .shepherd: OriginStyle(symbol: "arrow.triangle.2.circlepath", label: "PR shepherd", tint: "warn")
        case .merged: OriginStyle(symbol: ShepherdBadgeState.merged.symbolName, label: "Merged", tint: "add")
        case .closed: OriginStyle(symbol: ShepherdBadgeState.closed.symbolName, label: "Closed", tint: "fg-muted")
        case .queued: OriginStyle(symbol: ShepherdBadgeState.queued.symbolName, label: "Merge queue", tint: "caution")
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
