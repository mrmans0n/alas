import AppKit
import Combine
import SwiftUI

extension NSAttributedString.Key {
    /// Full slash command (e.g. `/review`) carried by a command chip.
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
    static var nameColor: NSColor { tint.chipLabelColor }

    static func displayName(for command: String) -> String {
        command.hasPrefix("/") ? String(command.dropFirst()) : command
    }

    /// Top padding that puts the pill's label on the baseline of the first
    /// line of `font`: the same rule `ACPMentionChipMetrics.baselineOffset`
    /// applies to inline chips, expressed from the line's top edge.
    static func topInset(forLineFont font: NSFont) -> CGFloat {
        font.ascender - (ACPMentionChipMetrics.height - ACPMentionChipMetrics.labelBaselineInset)
    }
}

/// Prism colors shared by the native attachment and SwiftUI badges.
enum ACPAlasPrismStyle {
    static let base = NSColor(calibratedRed: 0.145, green: 0.137, blue: 0.188, alpha: 1)
    static let border = NSColor(calibratedRed: 0.635, green: 0.569, blue: 0.871, alpha: 0.6)
    static let colors: [NSColor] = [
        .clear,
        NSColor(calibratedRed: 0.443, green: 0.612, blue: 1, alpha: 0.35),
        NSColor(calibratedRed: 0.804, green: 0.514, blue: 0.929, alpha: 0.55),
        NSColor(calibratedRed: 1, green: 0.702, blue: 0.831, alpha: 0.35),
        NSColor(calibratedRed: 0.553, green: 0.945, blue: 0.882, alpha: 0.35),
        .clear,
    ]
    static let locations: [CGFloat] = [0, 0.25, 0.43, 0.57, 0.75, 1]
    static let gradient = NSGradient(colors: colors, atLocations: locations, colorSpace: .deviceRGB)!
    static let swiftUIGradient = Gradient(stops: zip(colors, locations).map {
        .init(color: Color(nsColor: $0.0), location: $0.1)
    })

    static func position(at time: TimeInterval, reducedMotion: Bool) -> CGFloat {
        guard !reducedMotion else { return 0.5 }
        let phase = time.truncatingRemainder(dividingBy: 4.5) / 4.5
        let progress = min(1, max(0, (phase - 0.15) / 0.6))
        return CGFloat(progress * progress * (3 - 2 * progress))
    }

    static func draw(in rect: NSRect, time: TimeInterval, reducedMotion: Bool) {
        base.setFill()
        rect.fill()
        let center = rect.minX + rect.width * (-0.65 + 2.3 * position(at: time, reducedMotion: reducedMotion))
        gradient.draw(
            from: NSPoint(x: center - rect.width * 0.5, y: rect.minY),
            to: NSPoint(x: center + rect.width * 0.5, y: rect.maxY),
            options: []
        )
    }
}

struct ACPAlasPrismBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reducedMotion)) { context in
            GeometryReader { geometry in
                let position = ACPAlasPrismStyle.position(
                    at: context.date.timeIntervalSinceReferenceDate, reducedMotion: reducedMotion
                )
                Color(nsColor: ACPAlasPrismStyle.base)
                    .overlay {
                        LinearGradient(
                            gradient: ACPAlasPrismStyle.swiftUIGradient,
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .offset(x: geometry.size.width * (-1.15 + 2.3 * position))
                    }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ACPAlasCommandBadge: View {
    var body: some View {
        Text("Alas")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background { ACPAlasPrismBackground() }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color(nsColor: ACPAlasPrismStyle.border), lineWidth: 0.75)
            }
            .help("Handled by Alas, not sent to the agent")
    }
}

/// Known slash commands in a message: the leading one the transcript renders
/// as a pill, and every one the composer turns into a chip.
enum ACPSlashCommand {
    /// A known slash command at the very start of a message.
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
    /// complete a known command still typed as plain text — the hand-typed
    /// counterpart to picking one from the `/` menu. Intended to
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
        let end = range.location
        guard end <= string.length,
              end == string.length || isWhitespace(string.character(at: end))
        else { return nil }
        var start = end
        while start > 0, !isWhitespace(string.character(at: start - 1)) { start -= 1 }
        let tokenRange = NSRange(location: start, length: end - start)
        guard let command = knownCommand(in: string, at: tokenRange, suggestions: suggestions),
              !isInCode(start, in: string)
        else { return nil }
        return (tokenRange, command)
    }

    /// Whether `location` is inside code while the user is still typing
    /// there: a fenced block (closed or still open) or an inline code span,
    /// counting a backtick run still open at `location` as code — the same
    /// open-span rule as the upstream-reference keystroke path.
    static func isInCode(_ location: Int, in string: NSString) -> Bool {
        // Through the character AT `location`, so a span left open before
        // it extends over it rather than ending exactly on it.
        let prefix = string.substring(to: min(location + 1, string.length)) as NSString
        return (codeRanges(in: string) + ACPUpstreamReferenceDetector.codeRanges(in: prefix, unclosedRunsExtendToEnd: true))
            .contains { NSLocationInRange(location, $0) }
    }

    /// Fenced blocks as the composer's editor sees them (an unclosed fence
    /// runs to the end of the text) plus closed inline code spans.
    private static func codeRanges(in string: NSString) -> [NSRange] {
        MarkdownFenceEditing.blocks(in: string as String).map(\.outerRange)
            + ACPUpstreamReferenceDetector.codeRanges(in: string, unclosedRunsExtendToEnd: false)
    }

    @MainActor
    static func chip(for command: String, font: NSFont, suggestions: [ACPPromptSuggestion]) -> NSAttributedString {
        let isAlas = suggestions.contains { $0.command == command && ACPAlasSlashCommand.isAlasCommand($0) }
        let chip = NSMutableAttributedString(attachment: ACPCommandChipAttachment(command: command, isAlas: isAlas))
        chip.addAttributes([
            .commandChipName: command,
            .font: font,
        ], range: NSRange(location: 0, length: chip.length))
        return chip
    }

    /// Ownership can change during lease takeover without changing draft text.
    @MainActor
    static func refreshChipOwnership(in storage: NSAttributedString, suggestions: [ACPPromptSuggestion]) {
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let attachment = value as? ACPCommandChipAttachment else { return }
            let isAlas = suggestions.contains {
                $0.command == attachment.command && ACPAlasSlashCommand.isAlasCommand($0)
            }
            attachment.updateOwnership(isAlas: isAlas)
        }
    }

    /// Ranges of known `/command` tokens that should become chips, in
    /// order. A token counts when it starts the text or follows whitespace,
    /// and only once whitespace follows it, so a command still being typed
    /// is left alone. Tokens inside code spans or fenced blocks stay text.
    /// Chips serialize back to the same text, so drafts compare equal
    /// before and after.
    static func chipTargets(
        in string: String,
        suggestions: [ACPPromptSuggestion]
    ) -> [(range: NSRange, command: String)] {
        guard !suggestions.isEmpty else { return [] }
        let string = string as NSString
        var targets: [(range: NSRange, command: String)] = []
        var index = 0
        while index < string.length {
            guard !isWhitespace(string.character(at: index)) else {
                index += 1
                continue
            }
            let start = index
            while index < string.length, !isWhitespace(string.character(at: index)) { index += 1 }
            let tokenRange = NSRange(location: start, length: index - start)
            if index < string.length,
               let command = knownCommand(in: string, at: tokenRange, suggestions: suggestions) {
                targets.append((tokenRange, command))
            }
        }
        guard !targets.isEmpty else { return [] }
        let code = codeRanges(in: string)
        return targets.filter { target in !code.contains { NSLocationInRange(target.range.location, $0) } }
    }

    /// Non-undoable form for wholesale draft restores.
    @MainActor
    static func chipify(_ storage: NSMutableAttributedString, suggestions: [ACPPromptSuggestion], font: NSFont) {
        for target in chipTargets(in: storage.string, suggestions: suggestions).reversed() {
            storage.replaceCharacters(
                in: target.range, with: chip(for: target.command, font: font, suggestions: suggestions)
            )
        }
    }

    /// Chips commands in a fragment about to replace `range` of `storage`,
    /// returning whether any chip formed. The text on either side of
    /// `range` decides whether the fragment's edges are token boundaries
    /// and whether it lands inside code, so `/review` pasted right after
    /// `abc`, or between a code span's backticks, stays text.
    @MainActor
    @discardableResult
    static func chipify(
        _ fragment: NSMutableAttributedString,
        replacing range: NSRange,
        in storage: NSAttributedString,
        suggestions: [ACPPromptSuggestion],
        font: NSFont
    ) -> Bool {
        let string = storage.string as NSString
        let prefix = string.substring(to: range.location)
        let suffix = string.substring(from: NSMaxRange(range))
        let offset = (prefix as NSString).length
        let targets = chipTargets(in: prefix + fragment.string + suffix, suggestions: suggestions)
            .filter { $0.range.location >= offset && NSMaxRange($0.range) <= offset + fragment.length }
        for target in targets.reversed() {
            fragment.replaceCharacters(
                in: NSRange(location: target.range.location - offset, length: target.range.length),
                with: chip(for: target.command, font: font, suggestions: suggestions)
            )
        }
        return !targets.isEmpty
    }

    private static func knownCommand(
        in string: NSString,
        at tokenRange: NSRange,
        suggestions: [ACPPromptSuggestion]
    ) -> String? {
        guard tokenRange.length > 1, string.character(at: tokenRange.location) == 0x2F else { return nil } // "/"
        let token = string.substring(with: tokenRange)
        return suggestions.first(where: { $0.command == token })?.command
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

// MARK: - Composer chip

final class ACPCommandChipAttachment: NSTextAttachment {
    let command: String
    @MainActor private(set) var isAlas: Bool

    @MainActor
    init(command: String, isAlas: Bool) {
        self.command = command
        self.isAlas = isAlas
        super.init(data: nil, ofType: nil)
        attachmentCell = ACPCommandChipCell(command: command, isAlas: isAlas)
    }

    @MainActor
    func updateOwnership(isAlas: Bool) {
        guard self.isAlas != isAlas else { return }
        self.isAlas = isAlas
        attachmentCell = ACPCommandChipCell(command: command, isAlas: isAlas)
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class ACPCommandChipCell: NSTextAttachmentCell {
    private let label: String
    private let isAlas: Bool
    private var animationTimer: Timer?
    private weak var animationView: NSView?
    private var animationFrame = NSRect.zero
    private var editingObserver: (any NSObjectProtocol)?
    private var accessibilityObserver: (any NSObjectProtocol)?

    init(command: String, isAlas: Bool) {
        self.isAlas = isAlas
        self.label = ACPCommandPillStyle.displayName(for: command)
        super.init(textCell: "")
        if isAlas {
            accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.stopAnimation()
                    self.animationView?.setNeedsDisplay(self.animationFrame)
                }
            }
        }
    }
    required init(coder: NSCoder) { fatalError() }

    isolated deinit {
        animationTimer?.invalidate()
        if let editingObserver { NotificationCenter.default.removeObserver(editingObserver) }
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        if let editingObserver { NotificationCenter.default.removeObserver(editingObserver) }
        editingObserver = nil
    }

    private func animate(in view: NSView?, frame: NSRect) {
        guard isAlas else { return }
        animationView = view
        animationFrame = frame
        if editingObserver == nil, let storage = (view as? NSTextView)?.textStorage {
            editingObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Undo may retain a removed attachment. Stop its timer;
                    // the next draw restarts only chips still in the text.
                    self?.stopAnimation()
                    if let self { self.animationView?.setNeedsDisplay(self.animationFrame) }
                }
            }
        }
        guard animationTimer == nil, view?.window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                guard let view = self.animationView,
                      let window = view.window, window.isVisible,
                      !view.isHiddenOrHasHiddenAncestor,
                      view.visibleRect.intersects(self.animationFrame),
                      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                    self.stopAnimation()
                    return
                }
                view.setNeedsDisplay(self.animationFrame)
            }
        }
        timer.tolerance = 1 / 120
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private var size: NSSize {
        let textWidth = (label as NSString).size(withAttributes: [.font: ACPMentionChipMetrics.labelFont]).width
        return NSSize(
            width: ACPCommandPillStyle.capWidth + ceil(textWidth) + 2 * ACPCommandPillStyle.nameHorizontalPadding,
            height: ACPMentionChipMetrics.height
        )
    }

    override var cellSize: NSSize { size }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: ACPMentionChipMetrics.baselineOffset)
    }

    override func cellFrame(for textContainer: NSTextContainer,
                            proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint,
                            characterIndex charIndex: Int) -> NSRect {
        NSRect(
            x: 0,
            y: ACPMentionChipMetrics.baselineOffset,
            width: size.width,
            height: size.height
        )
    }

    override func draw(withFrame frame: NSRect, in controlView: NSView?) {
        animate(in: controlView, frame: frame)
        let tint = ACPCommandPillStyle.tint
        let rect = frame.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        let capRect = NSRect(x: rect.minX, y: rect.minY, width: ACPCommandPillStyle.capWidth, height: rect.height)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if isAlas {
            ACPAlasPrismStyle.draw(
                in: rect, time: Date.timeIntervalSinceReferenceDate,
                reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
            NSColor.white.withAlphaComponent(0.08).setFill()
            capRect.fill()
        } else {
            tint.withAlphaComponent(0.16).setFill()
            rect.fill()
            tint.withAlphaComponent(0.55).setFill()
            capRect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        (isAlas ? ACPAlasPrismStyle.border : tint.withAlphaComponent(0.6)).setStroke()
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
            .foregroundColor: isAlas ? NSColor.white : ACPCommandPillStyle.nameColor,
        ]
        (label as NSString).draw(at: NSPoint(
            x: capRect.maxX + ACPCommandPillStyle.nameHorizontalPadding,
            y: ACPMentionChipMetrics.labelOriginY(in: frame)
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

    private var isAlas: Bool { ACPAlasSlashCommand.isAlasCommand(suggestion) }
    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: ACPCommandPillStyle.symbolName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: ACPCommandPillStyle.capWidth, height: ACPMentionChipMetrics.height)
                .background(isAlas ? Color.white.opacity(0.08) : Color(nsColor: ACPCommandPillStyle.tint).opacity(0.55))
            Text(ACPCommandPillStyle.displayName(for: suggestion.command))
                .font(Font(ACPMentionChipMetrics.labelFont))
                .foregroundStyle(isAlas ? .white : Color(nsColor: ACPCommandPillStyle.nameColor))
                .lineLimit(1)
                .padding(.horizontal, ACPCommandPillStyle.nameHorizontalPadding)
                .frame(height: ACPMentionChipMetrics.height)
        }
        .background {
            if isAlas {
                ACPAlasPrismBackground()
            } else {
                Color(nsColor: ACPCommandPillStyle.tint).opacity(0.16)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(
                    isAlas ? Color(nsColor: ACPAlasPrismStyle.border)
                        : Color(nsColor: ACPCommandPillStyle.tint).opacity(0.6),
                    lineWidth: 0.75
                )
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
    /// `ACPSlashCommand.match` ever saw it.
    let text: String
    let attachments: [ACPMessage.Attachment]
    let typography: ACPChatTypography
    let session: ACPSession
    /// False for remote sessions, where a local existence check says nothing.
    let chipsAbsolutePaths: Bool
    @State private var suggestions: [ACPPromptSuggestion]
    @Environment(\.acpUpstreamReferenceStore) private var upstreamReferences
    @State private var upstreamHost: CodeHostKind?

    init(
        text: String,
        attachments: [ACPMessage.Attachment],
        typography: ACPChatTypography,
        session: ACPSession,
        chipsAbsolutePaths: Bool
    ) {
        self.text = text
        self.attachments = attachments
        self.typography = typography
        self.session = session
        self.chipsAbsolutePaths = chipsAbsolutePaths
        _suggestions = State(initialValue: session.promptSuggestions)
    }

    var body: some View {
        content
            .environment(\.acpUpstreamReferenceChipping, chipping)
            .environment(\.acpAbsolutePathChipping, chipsAbsolutePaths)
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
        if let match = ACPSlashCommand.match(in: text, suggestions: suggestions) {
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
