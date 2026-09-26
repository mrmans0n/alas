import AppKit
import Combine
import SwiftUI

extension NSAttributedString.Key {
    /// Full slash command (e.g. `/review`) carried by a leading command chip.
    static let commandChipName = NSAttributedString.Key("alas.acp.commandChipName")
}

/// Shared look for the slash-command pill: a solid icon cap followed by a
/// tinted name, drawn by the composer's attachment cell and by the
/// transcript's SwiftUI pill.
enum ACPCommandPillStyle {
    static let symbolName = "wand.and.sparkles"
    static let tint = NSColor.systemPurple
    static let capWidth: CGFloat = 18
    static let nameHorizontalPadding: CGFloat = 6
    static var nameColor: NSColor { tint.blended(withFraction: 0.55, of: .white) ?? .white }

    static func displayName(for command: String) -> String {
        command.hasPrefix("/") ? String(command.dropFirst()) : command
    }

    /// Top padding that centers the pill on the letters of the first line
    /// of `font`: the same rule `ACPMentionChipMetrics.baselineOffset` uses
    /// inside the composer, expressed from the line's top edge.
    static func topInset(forLineFont font: NSFont) -> CGFloat {
        let baselineFromTop = font.ascender
        let letterCenterFromBaseline = (font.ascender + font.descender) / 2
        return baselineFromTop - letterCenterFromBaseline - ACPMentionChipMetrics.height / 2
    }
}

/// A known slash command at the very start of a message.
enum ACPLeadingCommand {
    static func match(
        in text: String,
        suggestions: [ACPPromptSuggestion]
    ) -> (suggestion: ACPPromptSuggestion, rest: Substring)? {
        guard text.hasPrefix("/") else { return nil }
        let token = text.prefix { !$0.isWhitespace }
        guard let suggestion = suggestions.first(where: { $0.command == token }) else { return nil }
        var rest = text.dropFirst(token.count)
        // Only the single space that separates the command from its
        // argument (the same one the pill and the composer's own
        // hand-typed-command detection insert) is command syntax. A
        // newline right after the command is message structure — a blank
        // line, a new paragraph — and must stay in `rest` so multi-line
        // replies keep rendering below the pill instead of squeezed
        // beside it in the same row.
        if rest.first == " " {
            rest = rest.dropFirst()
        }
        return (suggestion, rest)
    }

    /// Whether inserting a single whitespace character at `range` would
    /// complete a leading known command still typed as plain text — the
    /// hand-typed counterpart to picking one from the `/` menu. Intended to
    /// be checked BEFORE the whitespace reaches the text view's own
    /// `insertText`, so the pill and the typed whitespace land in one edit
    /// instead of two: turning the command into a chip AFTER the whitespace
    /// already went through `super.insertText` would nest a second storage
    /// edit inside that keystroke's own typing-undo bookkeeping, corrupting
    /// it and crashing `NSUndoManager` on the next undo.
    static func chipTarget(
        completingWith insertedText: String,
        at range: NSRange,
        in storage: NSAttributedString,
        suggestions: [ACPPromptSuggestion]
    ) -> (range: NSRange, command: String)? {
        guard range.length == 0,
              insertedText.count == 1,
              let scalar = insertedText.unicodeScalars.first,
              CharacterSet.whitespacesAndNewlines.contains(scalar)
        else { return nil }
        let string = storage.string as NSString
        guard string.length > 0, string.character(at: 0) == 0x2F, // "/"
              storage.attribute(.attachment, at: 0, effectiveRange: nil) == nil
        else { return nil }
        let token = storage.string.prefix { !$0.isWhitespace }
        let tokenLength = (String(token) as NSString).length
        guard range.location == tokenLength,
              let suggestion = suggestions.first(where: { $0.command == token })
        else { return nil }
        return (NSRange(location: 0, length: tokenLength), suggestion.command)
    }

    @MainActor
    static func chip(for command: String, font: NSFont) -> NSAttributedString {
        let chip = NSMutableAttributedString(attachment: ACPCommandChipAttachment(command: command))
        chip.addAttributes([
            .commandChipName: command,
            .font: font,
        ], range: NSRange(location: 0, length: chip.length))
        return chip
    }

    /// Range of a leading known `/command` that should become a chip: only
    /// once whitespace follows it, so a command still being typed is left
    /// alone. The chip serializes back to the same text, so drafts compare
    /// equal before and after.
    static func chipTarget(
        in storage: NSAttributedString,
        suggestions: [ACPPromptSuggestion]
    ) -> (range: NSRange, command: String)? {
        let string = storage.string as NSString
        guard string.length > 1, string.character(at: 0) == 0x2F, // "/", so not already a chip
              let match = match(in: storage.string, suggestions: suggestions)
        else { return nil }
        let length = (match.suggestion.command as NSString).length
        guard length < string.length,
              let next = Unicode.Scalar(string.character(at: length)),
              CharacterSet.whitespacesAndNewlines.contains(next)
        else { return nil }
        return (NSRange(location: 0, length: length), match.suggestion.command)
    }

    /// Non-undoable form for wholesale draft restores.
    @MainActor
    static func chipify(_ storage: NSMutableAttributedString, suggestions: [ACPPromptSuggestion], font: NSFont) {
        guard let target = chipTarget(in: storage, suggestions: suggestions) else { return }
        storage.replaceCharacters(in: target.range, with: chip(for: target.command, font: font))
    }
}

// MARK: - Composer chip

final class ACPCommandChipAttachment: NSTextAttachment {
    let command: String

    @MainActor
    init(command: String) {
        self.command = command
        super.init(data: nil, ofType: nil)
        attachmentCell = ACPCommandChipCell(command: command)
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class ACPCommandChipCell: NSTextAttachmentCell {
    private let label: String

    init(command: String) {
        self.label = ACPCommandPillStyle.displayName(for: command)
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError() }

    private var size: NSSize {
        let textWidth = (label as NSString).size(withAttributes: [.font: ACPMentionChipMetrics.labelFont]).width
        return NSSize(
            width: ACPCommandPillStyle.capWidth + ceil(textWidth) + 2 * ACPCommandPillStyle.nameHorizontalPadding,
            height: ACPMentionChipMetrics.height
        )
    }

    override var cellSize: NSSize { size }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: ACPMentionChipMetrics.baselineOffset(
            for: NSFont.systemFont(ofSize: 13),
            attachmentHeight: size.height
        ))
    }

    override func cellFrame(for textContainer: NSTextContainer,
                            proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint,
                            characterIndex charIndex: Int) -> NSRect {
        let font = textContainer.layoutManager?.textStorage?.attribute(
            .font, at: charIndex, effectiveRange: nil
        ) as? NSFont ?? NSFont.systemFont(ofSize: 13)
        return NSRect(
            x: 0,
            y: ACPMentionChipMetrics.baselineOffset(for: font, attachmentHeight: size.height),
            width: size.width,
            height: size.height
        )
    }

    override func draw(withFrame frame: NSRect, in controlView: NSView?) {
        let tint = ACPCommandPillStyle.tint
        let rect = frame.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        let capRect = NSRect(x: rect.minX, y: rect.minY, width: ACPCommandPillStyle.capWidth, height: rect.height)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        tint.withAlphaComponent(0.16).setFill()
        rect.fill()
        tint.withAlphaComponent(0.55).setFill()
        capRect.fill()
        NSGraphicsContext.restoreGraphicsState()

        tint.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 0.75
        path.stroke()

        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let icon = NSImage(systemSymbolName: ACPCommandPillStyle.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let iconRect = NSRect(
                x: capRect.midX - icon.size.width / 2,
                y: capRect.midY - icon.size.height / 2,
                width: icon.size.width,
                height: icon.size.height
            )
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: ACPMentionChipMetrics.labelFont,
            .foregroundColor: ACPCommandPillStyle.nameColor,
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(
            x: capRect.maxX + ACPCommandPillStyle.nameHorizontalPadding,
            y: frame.minY + (frame.height - textSize.height) / 2
        ), withAttributes: attrs)
    }

    override func highlight(_ flag: Bool, withFrame frame: NSRect, in controlView: NSView?) {
        draw(withFrame: frame, in: controlView)
    }
}

// MARK: - Hover card

/// Name, argument hint, and full description of a slash command.
struct ACPCommandHoverCard: View {
    let suggestion: ACPPromptSuggestion

    static func hasDetails(_ suggestion: ACPPromptSuggestion) -> Bool {
        !(suggestion.description ?? "").isEmpty || !(suggestion.hint ?? "").isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: ACPCommandPillStyle.symbolName)
                    .foregroundStyle(Color(nsColor: ACPCommandPillStyle.tint))
                Text(suggestion.command)
                    .font(.system(size: 13, weight: .semibold))
            }
            if let hint = suggestion.hint, !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let description = suggestion.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
    }
}

/// Debounced hover popover for the composer's command chip.
@MainActor
final class ACPCommandChipHoverController {
    private var popover: NSPopover?
    private var showWork: DispatchWorkItem?
    private var target: NSRange?

    func scheduleShow(range: NSRange, suggestion: ACPPromptSuggestion, in textView: ACPNSTextView) {
        guard target != range else { return }
        hide()
        guard ACPCommandHoverCard.hasDetails(suggestion) else { return }
        target = range
        let work = DispatchWorkItem { [weak self, weak textView] in
            guard let self, let textView, self.target == range,
                  let anchor = textView.imageChipAnchorRect(for: range) else { return }
            let hosting = NSHostingController(rootView: ACPCommandHoverCard(suggestion: suggestion))
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentViewController = hosting
            popover.contentSize = hosting.view.fittingSize
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

// MARK: - Transcript pill

struct ACPCommandPill: View {
    let suggestion: ACPPromptSuggestion
    @State private var isHovering = false
    @State private var showsCard = false

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: ACPCommandPillStyle.symbolName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: ACPCommandPillStyle.capWidth, height: ACPMentionChipMetrics.height)
                .background(Color(nsColor: ACPCommandPillStyle.tint).opacity(0.55))
            Text(ACPCommandPillStyle.displayName(for: suggestion.command))
                .font(Font(ACPMentionChipMetrics.labelFont))
                .foregroundStyle(Color(nsColor: ACPCommandPillStyle.nameColor))
                .lineLimit(1)
                .padding(.horizontal, ACPCommandPillStyle.nameHorizontalPadding)
                .frame(height: ACPMentionChipMetrics.height)
        }
        .background(Color(nsColor: ACPCommandPillStyle.tint).opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color(nsColor: ACPCommandPillStyle.tint).opacity(0.6), lineWidth: 0.75)
        )
        .fixedSize()
        .onHover { isHovering = $0 }
        .task(id: isHovering) {
            guard isHovering, ACPCommandHoverCard.hasDetails(suggestion) else {
                if showsCard { showsCard = false }
                return
            }
            try? await Task.sleep(for: .seconds(ACPImageChipHoverController.hoverDelay))
            if !Task.isCancelled { showsCard = true }
        }
        .popover(isPresented: $showsCard, arrowEdge: .bottom) {
            ACPCommandHoverCard(suggestion: suggestion)
        }
    }
}

/// User-message text with a leading known slash command rendered as a pill.
/// Observes only the session's command list, so a streaming transcript never
/// re-renders this row.
struct ACPUserMessageText: View {
    /// The raw message text — NOT pre-spliced with image markers. Detecting
    /// the leading command has to run against this first: an image chip
    /// attached before the user typed the command carries no wire text of
    /// its own but still gets a `` `🖼 …` `` marker spliced in ahead of it,
    /// and that marker would otherwise cover up the leading `/` before
    /// `ACPLeadingCommand.match` ever saw it.
    let text: String
    let attachments: [ACPMessage.Attachment]
    let typography: ACPChatTypography
    let session: ACPSession
    @State private var suggestions: [ACPPromptSuggestion]
    @Environment(\.acpUpstreamReferenceStore) private var upstreamReferences
    @State private var upstreamHost: CodeHostKind?

    init(text: String, attachments: [ACPMessage.Attachment], typography: ACPChatTypography, session: ACPSession) {
        self.text = text
        self.attachments = attachments
        self.typography = typography
        self.session = session
        _suggestions = State(initialValue: session.promptSuggestions)
    }

    var body: some View {
        content
            .environment(\.acpUpstreamReferenceChipping, chipping)
            .onReceive(session.$promptSuggestions) { latest in
                if latest != suggestions { suggestions = latest }
            }
            .onReceive(upstreamReferences?.$remote.eraseToAnyPublisher()
                ?? Just<CodeHostRemote?>(nil).eraseToAnyPublisher()) { remote in
                if remote?.kind != upstreamHost { upstreamHost = remote?.kind }
            }
            .onAppear { upstreamReferences?.resolveRemote() }
    }

    private var chipping: ACPUpstreamReferenceChipping? {
        guard let upstreamReferences, let upstreamHost else { return nil }
        return ACPUpstreamReferenceChipping(store: upstreamReferences, host: upstreamHost)
    }

    @ViewBuilder
    private var content: some View {
        if let match = ACPLeadingCommand.match(in: text, suggestions: suggestions) {
            // Markers are spliced into `rest` only, with each image's
            // offset (captured against the FULL message) re-anchored by
            // however many characters the command consumed — an image
            // attached before the command still gets a marker, now at the
            // front of `rest`, rather than one glued to a pill it can't
            // render next to.
            let consumed = text.count - match.rest.count
            let rest = ACPUserMessageImageMarkers.displayText(
                text: String(match.rest),
                attachments: attachments,
                offsetAdjustment: -consumed
            )
            // Multi-line content (a blank line, a following paragraph) goes
            // below the pill in its own row instead of the same HStack —
            // squeezing a whole markdown block into the row beside the pill
            // would turn the message into a two-column layout and swallow
            // its line breaks.
            if rest.contains(where: \.isNewline) {
                VStack(alignment: .leading, spacing: 4) {
                    ACPCommandPill(suggestion: match.suggestion)
                    if !rest.isEmpty {
                        ACPMarkdownText(raw: rest, typography: typography)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 6) {
                    ACPCommandPill(suggestion: match.suggestion)
                        .padding(.top, ACPCommandPillStyle.topInset(
                            forLineFont: typography.appKitFont(size: typography.paragraphSize)
                        ))
                    if !rest.isEmpty {
                        ACPMarkdownText(raw: rest, typography: typography)
                    }
                }
            }
        } else {
            ACPMarkdownText(
                raw: ACPUserMessageImageMarkers.displayText(text: text, attachments: attachments),
                typography: typography
            )
        }
    }
}
