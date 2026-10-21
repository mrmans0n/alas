import AppKit
import SwiftUI

/// A sent symbol mention in the transcript: the composer badge's code-token
/// look. Click opens the symbol in the editor at the range that was sent;
/// hover shows what was sent, or the code now.
struct ACPSymbolBadge: View {
    let target: ACPSymbolReference.Target
    let snapshot: ACPSymbolSnapshot?
    /// Where the preview reads files; without it the badge has no preview.
    let root: URL?
    let typography: ACPChatTypography
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var isHovering = false
    @State private var showsPreview = false

    /// The target as sent; see `ACPSymbolReference.Target.asSent(snapshot:)`.
    private var sentTarget: ACPSymbolReference.Target { target.asSent(snapshot: snapshot) }

    private var containerText: String { target.container.map { $0 + "." } ?? "" }
    private var nameText: String { target.kind.isCallable ? target.name + "()" : target.name }
    private var countText: String? {
        sentTarget.includeCode
            ? ACPSymbolReference.Target.lineCountText(for: snapshot?.lineRange ?? target.lineRange) : nil
    }

    private var label: AttributedString {
        var container = AttributedString(containerText)
        container.foregroundColor = Color(nsColor: SymbolKind.class.badgeLabelColor)
        var name = AttributedString(nameText)
        name.foregroundColor = Color(nsColor: target.kind.badgeLabelColor)
        return container + name
    }

    var body: some View {
        Button {
            if let url = ACPSymbolReference.openURL(for: target, snapshot: snapshot) { openURL(url) }
        } label: {
            pill
        }
        .buttonStyle(.plain)
        .acpTrackingHover { isHovering = $0 }
        .onDisappear {
            isHovering = false
            showsPreview = false
        }
        .task(id: isHovering) {
            guard isHovering, root != nil else {
                showsPreview = false
                return
            }
            try? await Task.sleep(for: .seconds(ACPImageChipHoverController.hoverDelay))
            if !Task.isCancelled { showsPreview = true }
        }
        .popover(isPresented: $showsPreview, arrowEdge: .bottom) {
            if let root {
                ACPSymbolSentHoverView(target: sentTarget, snapshot: snapshot, root: root,
                                       typography: typography, theme: theme)
                    // A retried send can re-stamp the snapshot while the popover
                    // is open; a new snapshot gets a new model.
                    .id(snapshot)
            }
        }
    }

    private var pill: some View {
        HStack(spacing: 0) {
            if sentTarget.includeCode {
                Rectangle().fill(Color(nsColor: .controlAccentColor)).frame(width: 2)
            }
            HStack(spacing: 5) {
                Text(target.kind.badgeLetter)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color(nsColor: target.kind.badgeLabelColor))
                    .frame(width: 13, height: 13)
                    .background(Color(nsColor: target.kind.badgeBackground), in: RoundedRectangle(cornerRadius: 3))
                Text(label)
                    .font(Font(ACPMentionChipMetrics.labelFont))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 4)
            .padding(.trailing, 6)
            if let countText {
                HStack(spacing: 0) {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5)
                    Text(countText)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .padding(.horizontal, 5)
                }
                .background(Color(nsColor: ACPSymbolChipCell.countFill))
            }
        }
        .frame(height: 20)
        .background(Color(nsColor: ACPSymbolChipCell.pillFill))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5).strokeBorder(
                sentTarget.includeCode
                    ? Color(nsColor: NSColor.controlAccentColor.withAlphaComponent(0.6))
                    : Color(nsColor: .separatorColor),
                lineWidth: 0.75)
        )
        .contentShape(Rectangle())
    }
}

extension ACPSymbolReference.Target {
    /// The target as it was sent: code counts as included only when the
    /// snapshot carries it (a symbol missing at send time sent none). A message
    /// without a snapshot keeps the link's own flag.
    func asSent(snapshot: ACPSymbolSnapshot?) -> ACPSymbolReference.Target {
        var sent = self
        if let snapshot { sent.includeCode = snapshot.excerpt != nil }
        return sent
    }
}

extension NSAttributedString.Key {
    /// The `@name` an inline symbol badge stands for, so a copy spells it out.
    static let symbolMention = NSAttributedString.Key("alas.acp.symbolMention")
}

/// A user message's sent symbol mentions, keyed by the `@name` the composer
/// wrote for each one, which its paragraphs turn into inline badges.
struct ACPTranscriptSymbolMentions: Equatable {
    struct Mention: Equatable {
        let target: ACPSymbolReference.Target
        let snapshot: ACPSymbolSnapshot?

        /// The badge's target as sent: its code flag and line range.
        var sentTarget: ACPSymbolReference.Target {
            let sent = target.asSent(snapshot: snapshot)
            return ACPSymbolReference.Target(
                path: sent.path, name: sent.name, kind: sent.kind, container: sent.container,
                lineRange: snapshot?.lineRange ?? sent.lineRange, includeCode: sent.includeCode)
        }
    }

    let byLabel: [String: Mention]
    /// Where hover previews read files; nil shows none.
    let root: URL?

    /// Nil when the message has no symbol mention. A name two different
    /// symbols share stays text: nothing tells which one it means.
    init?(attachments: [ACPMessage.Attachment], root: URL?) {
        var byLabel: [String: Mention] = [:]
        var ambiguous: Set<String> = []
        for attachment in attachments {
            guard let target = ACPSymbolReference.target(fromURI: attachment.uri) else { continue }
            let label = "@" + (attachment.name ?? target.displayName)
            if let existing = byLabel[label] {
                if existing.target != target { ambiguous.insert(label) }
                continue
            }
            byLabel[label] = Mention(target: target, snapshot: attachment.symbol)
        }
        for label in ambiguous { byLabel[label] = nil }
        guard !byLabel.isEmpty else { return nil }
        self.byLabel = byLabel
        self.root = root
    }
}

extension EnvironmentValues {
    /// Set by `ACPUserMessageText` on messages that mention symbols.
    @Entry var acpSymbolMentions: ACPTranscriptSymbolMentions? = nil
}

/// Image-backed symbol badge for transcript paragraphs, drawn by the
/// composer's cell.
final class ACPTranscriptSymbolChipAttachment: NSTextAttachment {
    let mention: ACPTranscriptSymbolMentions.Mention

    @MainActor
    init(mention: ACPTranscriptSymbolMentions.Mention) {
        self.mention = mention
        super.init(data: nil, ofType: nil)
        let cell = ACPSymbolChipCell(target: mention.sentTarget)
        let size = cell.cellSize
        image = NSImage(size: size, flipped: true) { rect in
            MainActor.assumeIsolated { cell.draw(withFrame: rect, in: nil) }
            return true
        }
        bounds = NSRect(x: 0, y: ACPMentionChipMetrics.baselineOffset, width: size.width, height: size.height)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Inline symbol badges in submitted user-message markdown.
enum ACPTranscriptSymbolChip {
    /// Replaces each `@name` of a mentioned symbol with its badge. The name
    /// must start at a word boundary and end before an identifier character
    /// or a `.member`. Links, inline code, and other chips stay as they are.
    @MainActor
    @discardableResult
    static func chipify(_ rendered: NSMutableAttributedString, mentions: ACPTranscriptSymbolMentions) -> Int {
        let source = rendered.string as NSString
        var matches: [(range: NSRange, mention: ACPTranscriptSymbolMentions.Mention)] = []
        // Longest first, so `@Type.member()` wins over `@Type` at the same spot.
        for (label, mention) in mentions.byLabel.sorted(by: { $0.key.count > $1.key.count }) {
            var searchStart = 0
            while searchStart < source.length {
                let range = source.range(
                    of: label, options: .literal,
                    range: NSRange(location: searchStart, length: source.length - searchStart))
                guard range.location != NSNotFound else { break }
                searchStart = NSMaxRange(range)
                guard isBoundary(before: range, in: source), isBoundary(after: range, in: source),
                      !matches.contains(where: { NSIntersectionRange($0.range, range).length > 0 }),
                      !isExcluded(range, in: rendered)
                else { continue }
                matches.append((range, mention))
            }
        }
        for match in matches.sorted(by: { $0.range.location > $1.range.location }) {
            let chip = NSMutableAttributedString(attachment: ACPTranscriptSymbolChipAttachment(mention: match.mention))
            var attributes = rendered.attributes(at: match.range.location, effectiveRange: nil)
            attributes[.attachment] = nil
            attributes[.symbolMention] = source.substring(with: match.range)
            chip.addAttributes(attributes, range: NSRange(location: 0, length: chip.length))
            rendered.replaceCharacters(in: match.range, with: chip)
        }
        return matches.count
    }

    @MainActor
    static func hit(
        at point: NSPoint, in textView: NSTextView
    ) -> (range: NSRange, mention: ACPTranscriptSymbolMentions.Mention)? {
        guard let storage = textView.textStorage else { return nil }
        var hit: (range: NSRange, mention: ACPTranscriptSymbolMentions.Mention)?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let attachment = value as? ACPTranscriptSymbolChipAttachment,
                  let rect = textView.upstreamReferenceAnchorRect(for: range),
                  rect.insetBy(dx: -1, dy: -1).contains(point) else { return }
            hit = (range, attachment.mention)
            stop.pointee = true
        }
        return hit
    }

    private static func isIdentifier(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return true }
        return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }

    private static func isBoundary(before range: NSRange, in source: NSString) -> Bool {
        guard range.location > 0 else { return true }
        let previous = source.character(at: range.location - 1)
        return !isIdentifier(previous) && previous != UInt16(UInt8(ascii: "@")) && previous != UInt16(UInt8(ascii: "."))
    }

    private static func isBoundary(after range: NSRange, in source: NSString) -> Bool {
        let end = NSMaxRange(range)
        guard end < source.length else { return true }
        let next = source.character(at: end)
        if isIdentifier(next) { return false }
        guard next == UInt16(UInt8(ascii: ".")), end + 1 < source.length else { return true }
        return !isIdentifier(source.character(at: end + 1))
    }

    @MainActor
    private static func isExcluded(_ range: NSRange, in rendered: NSAttributedString) -> Bool {
        var excluded = false
        rendered.enumerateAttributes(in: range) { attributes, _, stop in
            if attributes[.link] != nil || attributes[.attachment] != nil
                || ACPMarkdownInlineRenderer.isInlineCode(attributes) {
                excluded = true
                stop.pointee = true
            }
        }
        return excluded
    }
}

/// Debounced hover popover for inline symbol badges: what was sent, or the
/// code now, like the badge above the bubble.
@MainActor
final class ACPTranscriptSymbolChipHoverController {
    private var popover: NSPopover?
    private var showWork: DispatchWorkItem?
    private var target: NSRange?

    func scheduleShow(
        range: NSRange,
        mention: ACPTranscriptSymbolMentions.Mention,
        root: URL,
        typography: ACPChatTypography,
        theme: Theme,
        in textView: NSTextView
    ) {
        guard target != range else { return }
        hide()
        target = range
        let work = DispatchWorkItem { [weak self, weak textView] in
            guard let self, let textView, self.target == range,
                  let anchor = textView.upstreamReferenceAnchorRect(for: range) else { return }
            let preview = ACPSymbolSentHoverView(
                target: mention.target.asSent(snapshot: mention.snapshot), snapshot: mention.snapshot,
                root: root, typography: typography, theme: theme)
            let hosting = NSHostingController(rootView: preview.environment(\.theme, theme))
            hosting.sizingOptions = [.preferredContentSize]
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentViewController = hosting
            popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
            self.popover = popover
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ACPImageChipHoverController.hoverDelay, execute: work)
    }

    func hide() {
        showWork?.cancel()
        showWork = nil
        target = nil
        popover?.performClose(nil)
        popover = nil
    }
}
