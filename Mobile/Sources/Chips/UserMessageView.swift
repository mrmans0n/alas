import AlasHighlight
import AlasRemoteKit
import SwiftUI
import UIKit

/// What a sent user message chips, and where its chips read their state.
struct UserMessageChips {
    /// Known commands, `/` included.
    var commands: [String]
    /// Sent symbol mentions by the `@label` the composer wrote; a label two symbols share stays text.
    var symbols: [String: RemoteUserMention]
    /// The message's collapsed pastes, against the text with their markers.
    var pasted: ACPPastedTextContents?
    var codeHost: CodeHostKind?
    var references: ReferenceCache?

    init(text: String, mentions: [RemoteUserMention], pastedSpans: [ACPPastedTextSpan],
         commands: [String], codeHost: CodeHostKind?, references: ReferenceCache?) {
        self.commands = commands
        self.codeHost = codeHost
        self.references = references
        pasted = ACPPastedTextContents(text: text, spans: pastedSpans)
        var symbols: [String: RemoteUserMention] = [:]
        var ambiguous: Set<String> = []
        for mention in mentions where mention.symbol != nil {
            let label = "@" + mention.name
            if let existing = symbols[label], existing.symbol != mention.symbol { ambiguous.insert(label) }
            symbols[label] = symbols[label] ?? mention
        }
        for label in ambiguous { symbols[label] = nil }
        self.symbols = symbols
    }

    /// Stands for a collapsed paste in the text markdown parses, so the
    /// paste's own markdown never shapes the message.
    static let markerOpen: Character = "\u{E000}"
    static let markerClose: Character = "\u{E001}"
    private static let marker = try! NSRegularExpression(pattern: "\u{E000}([0-9]+)\u{E001}")

    /// `text` with each pasted span from `offset` on replaced by its marker.
    /// A marker that lands in a code block or table, which draw without
    /// chips, gives its span's text back instead.
    func marked(_ text: String, from offset: Int) -> String {
        guard let pasted else { return text }
        let source = text as NSString
        var spans: [(range: NSRange, ordinal: Int)] = []
        var cursor = 0
        for span in pasted.spans where span.utf16Offset >= offset {
            let start = span.utf16Offset - offset
            guard start >= cursor, start + span.utf16Length <= source.length else { continue }
            spans.append((NSRange(location: start, length: span.utf16Length), span.ordinal))
            cursor = start + span.utf16Length
        }
        func build(keeping kept: Set<Int>) -> (text: String, markerStarts: [Int]) {
            var result = ""
            var starts: [Int] = []
            var cursor = 0
            for (index, span) in spans.enumerated() {
                result += source.substring(with: NSRange(location: cursor, length: span.range.location - cursor))
                if kept.contains(index) {
                    result += source.substring(with: span.range)
                } else {
                    starts.append(result.utf16.count)
                    result += "\(Self.markerOpen)\(span.ordinal)\(Self.markerClose)"
                }
                cursor = NSMaxRange(span.range)
            }
            return (result + source.substring(from: cursor), starts)
        }
        let marked = build(keeping: [])
        let verbatim = MarkdownBlock.verbatimLines(in: marked.text)
        guard !verbatim.isEmpty else { return marked.text }
        let lines = Self.lineStarts(marked.text as NSString)
        let kept = Set(marked.markerStarts.indices.filter { index in
            let line = lines.lastIndex { $0 <= marked.markerStarts[index] }.map { $0 + 1 } ?? 1
            return verbatim.contains { $0.contains(line) }
        })
        return kept.isEmpty ? marked.text : build(keeping: kept).text
    }

    /// Where each line starts, splitting as cmark does: `\n`, `\r\n` or `\r`.
    private static func lineStarts(_ text: NSString) -> [Int] {
        var starts = [0]
        var index = 0
        while index < text.length {
            let unit = text.character(at: index)
            index += 1
            if unit == 0x0D, index < text.length, text.character(at: index) == 0x0A { index += 1 }
            if unit == 0x0A || unit == 0x0D { starts.append(index) }
        }
        return starts
    }

    /// One rendered paragraph with its chips: pasted text, symbols, commands
    /// and references, in the Mac's order. Inline code and links stay text.
    @MainActor
    func render(_ text: AttributedString, font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in text.runs {
            let piece = String(text[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
            let intent = run.inlinePresentationIntent ?? []
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                attributes[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            // `MarkdownBlock` marks inline code with a tint and nothing else.
            if run.backgroundColor != nil {
                attributes[.font] = UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.94, weight: .regular)
                attributes[.backgroundColor] = UIColor.secondaryLabel.withAlphaComponent(0.12)
                attributes[Self.keepsText] = true
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[Self.keepsText] = true
            }
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        chipPasted(result, font: font)
        chip(result, font: font) { source in
            SymbolMentionText.labelRanges(Array(symbols.keys), in: source).compactMap { match in
                guard let mention = symbols[match.label], let symbol = mention.symbol else { return nil }
                let lines = symbol.includesCode ? symbol.lineRange.count : nil
                return (match.range, ChipModel.symbol(name: mention.name, kind: SymbolKind(rawValue: symbol.kind), lines: lines),
                        mention)
            }
        }
        chip(result, font: font) { source in
            SlashCommandText.chipTargets(in: (source as String) + " ", commands: commands).map {
                ($0.range, ChipModel.command(name: $0.command, isAlas: $0.command == ChipActions.ship.command), nil)
            }
        }
        if let codeHost {
            chip(result, font: font) { source in
                UpstreamReferenceText.references(in: source as String, host: codeHost).map {
                    ($0.range, ChipModel.reference($0.reference, host: codeHost, kind: nil), nil)
                }
            }
        }
        return result
    }

    @MainActor
    private func chipPasted(_ string: NSMutableAttributedString, font: UIFont) {
        let source = string.string as NSString
        for match in Self.marker.matches(in: string.string, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let ordinal = Int(source.substring(with: match.range(at: 1))),
                  let content = pasted?.content(ordinal: ordinal) else { continue }
            let chip = NSMutableAttributedString(
                attributedString: ChipAttachment.string(.pasted(ordinal: ordinal, text: content), font: font))
            chip.addAttribute(Self.spelling, value: content, range: NSRange(location: 0, length: chip.length))
            string.replaceCharacters(in: match.range, with: chip)
        }
    }

    /// Replaces each found range with its chip, last first, skipping inline
    /// code, links and existing chips.
    @MainActor
    private func chip(
        _ string: NSMutableAttributedString, font: UIFont,
        find: (NSString) -> [(NSRange, ChipModel, RemoteUserMention?)]
    ) {
        let source = string.string as NSString
        let found = find(source).filter { range, _, _ in
            guard NSMaxRange(range) <= source.length else { return false }
            var plain = true
            string.enumerateAttributes(in: range) { attributes, _, stop in
                if attributes[.attachment] != nil || attributes[Self.keepsText] != nil {
                    plain = false
                    stop.pointee = true
                }
            }
            return plain
        }
        for (range, model, mention) in found.sorted(by: { $0.0.location > $1.0.location }) {
            let chip = NSMutableAttributedString(
                attributedString: ChipAttachment.string(model, sent: mention, references: references, font: font))
            chip.addAttribute(Self.spelling, value: source.substring(with: range), range: NSRange(location: 0, length: chip.length))
            string.replaceCharacters(in: range, with: chip)
        }
    }

    /// Marks inline code and links, which never become chips.
    private static let keepsText = NSAttributedString.Key("alas.chips.keepsText")
    /// What a chip stands for in the sent text, for Copy.
    static let spelling = NSAttributedString.Key("alas.chips.spelling")

    /// `text` with each chip written out as the text it stands for.
    static func spelled(_ text: NSAttributedString) -> String {
        var result = ""
        let source = text.string as NSString
        // By attachment: two chips side by side that spell the same stay two.
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let chip = value == nil ? nil : text.attribute(spelling, at: range.location, effectiveRange: nil) as? String
            result += chip ?? source.substring(with: range)
        }
        return result
    }
}

/// A read-only text view whose Copy writes chips out, as the composer's does.
final class SpellingTextView: UITextView {
    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else { return super.copy(sender) }
        UIPasteboard.general.string = UserMessageChips.spelled(attributedText.attributedSubstring(from: selectedRange))
    }
}

/// Read-only message text with chips, sized to its text so a short message
/// keeps a narrow bubble.
struct ChipText: UIViewRepresentable {
    let text: AttributedString
    let chips: UserMessageChips
    @Environment(\.chipActions) private var actions
    @Environment(\.openURL) private var openURL

    private static var font: UIFont { .preferredFont(forTextStyle: .body) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = SpellingTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.tapHandler = ChipTapHandler(textView: view) { [weak coordinator = context.coordinator] attachment in
            coordinator?.actions?.card(for: attachment.chip, sent: attachment.sent)
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.openURL = openURL
        // A looked-up reference redraws its chip; the attachments read the cache as they draw.
        let entries = chips.references?.entries ?? [:]
        if context.coordinator.shown.map({
            $0.text != text || $0.commands != chips.commands || $0.codeHost != chips.codeHost || $0.entries != entries
        }) ?? true {
            view.attributedText = chips.render(text, font: Self.font)
            context.coordinator.shown = (text, chips.commands, chips.codeHost, entries)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let bounds = uiView.attributedText.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil)
        let fitted = min(width, ceil(bounds.width) + 1)
        let height = uiView.sizeThatFits(CGSize(width: fitted, height: .greatestFiniteMagnitude)).height
        return CGSize(width: fitted, height: ceil(height))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        /// What the text view shows: the text, and what decides its chips.
        var shown: (text: AttributedString, commands: [String], codeHost: CodeHostKind?,
                    entries: [CodeHostReference: ReferenceCache.Entry])?
        var tapHandler: ChipTapHandler?
        var actions: ChipActions?
        var openURL: OpenURLAction?

        /// Links go where the transcript sends them: a worktree file opens in the file viewer.
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content, let openURL else { return defaultAction }
            return UIAction { _ in openURL(url) }
        }
    }
}

extension EnvironmentValues {
    /// The screen's chip cards; nil where chips open nothing.
    @Entry var chipActions: ChipActions? = nil
}

/// A sent message's badges and bubble, as the Mac's user row: mention and
/// symbol badges and one row per typed reference above, then the text with
/// a leading command pulled out as its own pill.
struct UserMessageBody<Menu: View>: View {
    let id: String
    let text: String
    let mentions: [RemoteUserMention]
    let pastedSpans: [ACPPastedTextSpan]
    var session: TranscriptSession?
    /// The bubble's long-press menu.
    @ViewBuilder let menu: () -> Menu
    @Environment(\.chipActions) private var actions

    private var chips: UserMessageChips {
        let commands = (session?.config?.availableCommands ?? []).map(\.command) + [ChipActions.ship.command]
        return UserMessageChips(text: text, mentions: mentions, pastedSpans: pastedSpans, commands: commands,
                                codeHost: session?.config?.codeHost?.kind, references: session?.references)
    }

    var body: some View {
        let chips = chips
        let references = Self.references(in: chips.pasted?.typedText ?? text, host: chips.codeHost)
        VStack(alignment: .trailing, spacing: 6) {
            if !mentions.isEmpty {
                FlowRow { ForEach(Array(mentions.enumerated()), id: \.offset) { _, mention in MentionBadge(mention: mention) } }
            }
            ForEach(references, id: \.self) { reference in
                ReferenceRow(reference: reference, cache: session?.references)
            }
            if !text.isEmpty { bubble(chips) }
        }
        .task(id: references) {
            if !references.isEmpty { session?.resolve(references) }
        }
    }

    @ViewBuilder
    private func bubble(_ chips: UserMessageChips) -> some View {
        Group {
            if let match = SlashCommandText.match(in: text, commands: chips.commands),
               case let restOffset = text.utf16.count - match.rest.utf16.count,
               chips.pasted?.spansStart(atOrAfter: restOffset) ?? true {
                let pill = CommandPill(name: match.command)
                let rest = chips.marked(String(match.rest), from: restOffset)
                // A longer message goes under the pill instead of squeezed beside it.
                if rest.contains(where: \.isNewline) {
                    VStack(alignment: .leading, spacing: 6) {
                        pill
                        if !rest.isEmpty { AgentMarkdown(id: id + ":rest", text: rest, session: session, chips: chips) }
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        pill.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        if !rest.isEmpty { AgentMarkdown(id: id + ":rest", text: rest, session: session, chips: chips) }
                    }
                }
            } else {
                AgentMarkdown(id: id + ":user", text: chips.marked(text, from: 0), session: session, chips: chips)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 18))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18))
        .contextMenu { menu() }
    }

    /// Each reference typed outside code, once, in order.
    static func references(in text: String, host: CodeHostKind?) -> [CodeHostReference] {
        guard let host else { return [] }
        var seen = Set<CodeHostReference>()
        return UpstreamReferenceText.references(in: text, host: host).map(\.reference).filter { seen.insert($0).inserted }
    }
}

/// A leading command, as its own pill; a tap opens its card.
private struct CommandPill: View {
    let name: String
    @Environment(\.chipActions) private var actions

    var body: some View {
        let model = ChipModel.command(name: name, isAlas: name == ChipActions.ship.command)
        ChipCardButton(card: { actions?.card(for: model) }) { ChipView(model: model) }
    }
}

/// A sent file, folder, session or symbol mention above the bubble.
private struct MentionBadge: View {
    let mention: RemoteUserMention
    @Environment(\.chipActions) private var actions

    var body: some View {
        ChipCardButton(card: { actions?.card(for: .mention(name: mention.name), sent: mention) }) {
            HStack(spacing: 5) {
                if let symbol = mention.symbol {
                    SymbolKindBadge(kind: SymbolKind(rawValue: symbol.kind), side: 14)
                } else {
                    Image(systemName: RemoteUserMention.iconName(kind: mention.kind))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(mention.name).font(.caption.monospaced().weight(.medium)).lineLimit(1).truncationMode(.middle)
                if let symbol = mention.symbol, symbol.includesCode {
                    Text(ChipStyle.lineCount(symbol.lineRange.count)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color(.separator), lineWidth: 0.5) }
        }
        .accessibilityLabel("\(RemoteUserMention.accessibilityNoun(kind: mention.kind)) \(mention.name)")
    }
}

/// A typed PR/MR or issue reference: its title and state, once looked up.
private struct ReferenceRow: View {
    let reference: CodeHostReference
    let cache: ReferenceCache?

    var body: some View {
        let entry = cache?.entries[reference]
        ChipCardButton(card: { cache.map { AnyView(ReferenceCard(reference: reference, cache: $0)) } }) {
            HStack(spacing: 6) {
                Image(systemName: Self.isIssue(entry) ? "smallcircle.filled.circle" : "arrow.triangle.pull")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(reference.spelling).font(.caption.monospaced().weight(.semibold))
                if case .loaded(let summary) = entry {
                    Text(summary.title).font(.caption).lineLimit(1)
                    StateBadge(state: summary.state)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color(.secondarySystemBackground).opacity(0.8), in: .rect(cornerRadius: 8))
        }
    }

    private static func isIssue(_ entry: ReferenceCache.Entry?) -> Bool {
        if case .loaded(let summary) = entry { return summary.kind == .issue }
        return false
    }
}

/// A tappable label whose card opens in a popover, kept a popover on iPhone.
struct ChipCardButton<Label: View>: View {
    let card: () -> AnyView?
    @ViewBuilder let label: Label
    @State private var shown: AnyView?

    var body: some View {
        Button { shown = card() } label: { label }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(get: { shown != nil }, set: { if !$0 { shown = nil } })) {
                shown.presentationCompactAdaptation(.popover)
            }
    }
}

/// Badges laid out in rows that wrap, right-aligned like the bubble.
private struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { row in row.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, row.count - 1)) }.max() ?? 0
        let height = rows.map { $0.map(\.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        var index = 0
        for row in rows(subviews, width: bounds.width) {
            let rowWidth = row.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, row.count - 1))
            var x = bounds.maxX - rowWidth
            let height = row.map(\.height).max() ?? 0
            for size in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += height + spacing
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]]
        var used: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if !rows[rows.count - 1].isEmpty, used + spacing + size.width > width {
                rows.append([])
                used = 0
            }
            used += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].append(size)
        }
        return rows
    }
}
