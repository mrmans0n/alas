import AppKit
import Combine

extension ACPTranscriptCoreTextRowView {
    // MARK: - Clicks

    /// What a press on the row lands on. Armed on mouse-down and fired on
    /// mouse-up only if the pointer is still over the same target, like the
    /// diff's expansion pills.
    enum HitTarget: Equatable {
        case expansionToggle
        case link(URL)
        /// The "Copy" button of the code block at this index.
        case codeCopy(Int)
    }

    /// Farther than this from the press, a drag is not a click.
    private static let clickSlop: CGFloat = 3

    enum PointerCursor {
        case arrow, pointingHand, iBeam
    }

    /// The row's markdown and its origin, for the rows that have text.
    var markdown: (layout: ACPTranscriptMarkdownLayout, origin: CGPoint)? {
        let width = bounds.width > 0 ? bounds.width : lastMeasuredWidth ?? 0
        guard width > 0 else { return nil }
        for case .markdown(let markdown, let origin, _) in layout(forWidth: width).items {
            return (markdown, origin)
        }
        return nil
    }

    private func codeCopyIndex(at point: NSPoint) -> Int? {
        guard let (markdown, origin) = markdown else { return nil }
        return markdown.codeBlocks.indices.first { index in
            markdown.copyButtonRect(index, copied: copiedCodeBlock == index).offsetBy(dx: origin.x, dy: origin.y).contains(point)
        }
    }

    private func link(at point: NSPoint) -> URL? {
        guard bounds.width > 0 else { return nil }
        for case .markdown(let markdown, let origin, _) in layout(forWidth: bounds.width).items {
            if let url = markdown.link(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y)) { return url }
        }
        return nil
    }

    private func hitTarget(at point: NSPoint) -> HitTarget? {
        guard bounds.width > 0 else { return nil }
        if let index = codeCopyIndex(at: point) { return .codeCopy(index) }
        if let url = link(at: point) { return .link(url) }
        guard actions.toggleExpanded != nil,
              layout(forWidth: bounds.width).toggleRect?.contains(point) == true
        else { return nil }
        return .expansionToggle
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A double-click's second press does not open or copy again; over a
        // link it selects the word, as text does.
        if let target = hitTarget(at: point), event.clickCount == 1 || target == .expansionToggle {
            armedHitTarget = target
            pressOrigin = point
            return
        }
        if let position = textPosition(at: point, inside: true) {
            window?.makeFirstResponder(self)
            beginTextSelection(
                at: position, point: point, clickCount: event.clickCount, extending: event.modifierFlags.contains(.shift)
            )
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if case .link = armedHitTarget, let pressOrigin {
            guard hypot(point.x - pressOrigin.x, point.y - pressOrigin.y) > Self.clickSlop else { return }
            // A drag from a link is not a click: it selects text from where it began.
            armedHitTarget = nil
            self.pressOrigin = nil
            guard let start = textPosition(at: pressOrigin) else { return }
            window?.makeFirstResponder(self)
            beginTextSelection(at: start, point: pressOrigin, clickCount: 1, extending: false)
        }
        guard isSelectingText else { return super.mouseDragged(with: event) }
        if let position = textPosition(at: point) {
            textSelection?.focus = position
        }
        autoscroll(with: event)
    }

    private func updateCursor(at point: NSPoint?) {
        var wanted = PointerCursor.arrow
        if let point {
            if link(at: point) != nil || codeCopyIndex(at: point) != nil {
                wanted = .pointingHand
            } else if textPosition(at: point, inside: true) != nil {
                wanted = .iBeam
            }
        }
        guard wanted != pointerCursor else { return }
        pointerCursor = wanted
        switch wanted {
        case .arrow: NSCursor.arrow.set()
        case .pointingHand: NSCursor.pointingHand.set()
        case .iBeam: NSCursor.iBeam.set()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isSelectingText {
            isSelectingText = false
            return
        }
        guard let armed = armedHitTarget else { return super.mouseUp(with: event) }
        armedHitTarget = nil
        pressOrigin = nil
        guard hitTarget(at: convert(event.locationInWindow, from: nil)) == armed else { return }
        perform(armed)
    }

    private func perform(_ target: HitTarget) {
        switch target {
        case .link(let url):
            actions.openURL(url)
        case .codeCopy(let index):
            copyCode(index, to: .general)
        case .expansionToggle:
            // A native tool call or thought is always collapsed; a group
            // header draws either state.
            if case .toolGroupHeader(_, _, let expanded) = content {
                actions.toggleExpanded?(!expanded)
            } else {
                actions.toggleExpanded?(true)
            }
        }
    }

    // MARK: - Text selection (ported from `DiffSplitCoreTextRowView`)

    /// Selected text, as UTF-16 offsets into the markdown's block texts.
    struct TextSelection: Equatable {
        struct Position: Comparable {
            var block: Int
            var index: Int

            static func < (lhs: Position, rhs: Position) -> Bool {
                (lhs.block, lhs.index) < (rhs.block, rhs.index)
            }
        }

        var anchor: Position
        var focus: Position

        var start: Position { min(anchor, focus) }
        var end: Position { max(anchor, focus) }
        var isEmpty: Bool { anchor == focus }

        /// The selected offsets within `block`, whose text is `length` long.
        func span(inBlock block: Int, length: Int) -> Range<Int>? {
            guard block >= start.block, block <= end.block else { return nil }
            let lower = block == start.block ? min(start.index, length) : 0
            let upper = block == end.block ? min(end.index, length) : length
            return lower..<max(lower, upper)
        }

        /// The selected text, blocks joined by newlines.
        func text(in texts: [String]) -> String {
            guard !isEmpty else { return "" }
            return (start.block...end.block).compactMap { block -> String? in
                guard texts.indices.contains(block) else { return nil }
                let text = texts[block] as NSString
                guard let span = span(inBlock: block, length: text.length) else { return nil }
                return text.substring(with: NSRange(location: span.lowerBound, length: span.count))
            }.joined(separator: "\n")
        }
    }

    /// The lines `selection` touches, full width, in view coordinates.
    func rect(covering selection: TextSelection) -> CGRect? {
        guard !selection.isEmpty, let (markdown, origin) = markdown else { return nil }
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for line in markdown.lines {
            guard let block = line.block,
                  TextSelection.Position(block: block, index: line.range.location) <= selection.end,
                  TextSelection.Position(block: block, index: NSMaxRange(line.range)) >= selection.start
            else { continue }
            minY = min(minY, line.origin.y)
            maxY = max(maxY, line.origin.y + line.height)
        }
        guard minY < maxY else { return nil }
        return CGRect(x: 0, y: origin.y + minY, width: bounds.width, height: maxY - minY)
    }

    /// Agent and user text is selectable; one-line rows are click targets.
    override var acceptsFirstResponder: Bool {
        switch content {
        case .agent, .user: true
        default: false
        }
    }

    override func becomeFirstResponder() -> Bool {
        // The selection's color depends on focus.
        if let rect = textSelection.flatMap(rect(covering:)) { invalidateTiles(rect) }
        return super.becomeFirstResponder()
    }

    /// The selection stays, drawn inactive, as a text view keeps it.
    override func resignFirstResponder() -> Bool {
        if let rect = textSelection.flatMap(rect(covering:)) { invalidateTiles(rect) }
        return super.resignFirstResponder()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let rect = textSelection.flatMap(rect(covering:)) { invalidateTiles(rect) }
    }

    /// The selectable line whose box is under or after `y`, in markdown coordinates.
    private static func selectableLine(atOrAfter y: CGFloat, in markdown: ACPTranscriptMarkdownLayout) -> ACPTranscriptMarkdownLayout.Line? {
        markdown.lines.first { $0.block != nil && y < $0.origin.y + $0.height }
    }

    /// The block and offset nearest `point`. Points above or below the text
    /// clamp to its start or end, as a drag past the edge does; with
    /// `inside`, only points over the markdown resolve.
    func textPosition(at point: NSPoint, inside: Bool = false) -> TextSelection.Position? {
        guard let (markdown, origin) = markdown else { return nil }
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        if inside, !CGRect(x: 0, y: 0, width: markdown.width, height: markdown.height).contains(local) { return nil }
        guard let line = Self.selectableLine(atOrAfter: local.y, in: markdown), let block = line.block else {
            guard let last = markdown.texts.indices.last else { return nil }
            return .init(block: last, index: (markdown.texts[last] as NSString).length)
        }
        // Between blocks, the next block's start.
        guard local.y >= line.origin.y, line.visibleLength > 0 else { return .init(block: block, index: line.range.location) }
        let index = CTLineGetStringIndexForPosition(line.line, CGPoint(x: local.x - line.origin.x, y: 0))
        guard index != kCFNotFound else { return .init(block: block, index: line.range.location) }
        return .init(block: block, index: min(max(index, line.range.location), line.range.location + line.visibleLength))
    }

    /// The offset of the character under `point`, not the nearest caret
    /// position, as `NSTextView` picks a double-clicked word.
    private func characterIndex(at point: NSPoint, near position: TextSelection.Position) -> Int {
        guard let (markdown, origin) = markdown else { return position.index }
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let line = Self.selectableLine(atOrAfter: local.y, in: markdown), line.block == position.block,
              line.visibleLength > 0, position.index > line.range.location,
              local.x - line.origin.x < CTLineGetOffsetForStringIndex(line.line, position.index, nil)
        else { return position.index }
        return (markdown.texts[position.block] as NSString).rangeOfComposedCharacterSequence(at: position.index - 1).location
    }

    private func beginTextSelection(at position: TextSelection.Position, point: NSPoint, clickCount: Int, extending: Bool) {
        isSelectingText = true
        if extending, var selection = textSelection {
            selection.focus = position
            textSelection = selection
            return
        }
        guard let texts = markdown?.layout.texts, texts.indices.contains(position.block) else { return }
        let text = texts[position.block] as NSString
        func select(_ range: NSRange) {
            textSelection = .init(
                anchor: .init(block: position.block, index: range.location), focus: .init(block: position.block, index: NSMaxRange(range))
            )
        }
        switch clickCount {
        case 2 where text.length > 0:
            let under = min(characterIndex(at: point, near: position), text.length - 1)
            select(NSAttributedString(string: text as String).doubleClick(at: under))
        case 3...:
            // The paragraph, as a text view's triple-click: a code line or a whole prose block.
            var paragraph = text.paragraphRange(for: NSRange(location: min(position.index, text.length), length: 0))
            while paragraph.length > 0, text.character(at: NSMaxRange(paragraph) - 1) == 0x0A {
                paragraph.length -= 1
            }
            select(paragraph)
        default:
            textSelection = .init(anchor: position, focus: position)
        }
    }

    func selectedText() -> String {
        guard let textSelection, let texts = markdown?.layout.texts else { return "" }
        return textSelection.text(in: texts)
    }

    /// Copies the selection to `pasteboard`; false when nothing is selected.
    @discardableResult
    func copySelection(to pasteboard: NSPasteboard) -> Bool {
        let text = selectedText()
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    @objc func copy(_ sender: Any?) {
        copySelection(to: .general)
    }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    /// The key commands this row handles; arrows and paging go on to the
    /// transcript's scroll view.
    private static let keyCommands: Set<Selector> = [#selector(cancelOperation(_:)), #selector(selectAll(_:))]

    override func doCommand(by selector: Selector) {
        if Self.keyCommands.contains(selector) {
            perform(selector, with: nil)
        } else {
            nextResponder?.doCommand(by: selector)
        }
    }

    override func insertText(_ insertString: Any) {
        nextResponder?.insertText(insertString)
    }

    /// Escape clears the selection first. A plain click leaves an empty
    /// one, kept as the anchor for a shift-click, that Escape passes over.
    override func cancelOperation(_ sender: Any?) {
        if textSelection.map({ !$0.isEmpty }) ?? false {
            textSelection = nil
        } else {
            nextResponder?.cancelOperation(sender)
        }
    }

    /// All of this row's text, not the transcript's.
    override func selectAll(_ sender: Any?) {
        guard let texts = markdown?.layout.texts, let last = texts.indices.last else { return }
        textSelection = .init(anchor: .init(block: 0, index: 0), focus: .init(block: last, index: (texts[last] as NSString).length))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard textSelection.map({ !$0.isEmpty }) ?? false else { return super.menu(for: event) }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        return menu
    }

    func selectAllForTesting() {
        selectAll(nil)
    }

    /// Copies code block `index`, as a click on its Copy button does.
    func copyCodeBlock(_ index: Int) {
        copyCode(index, to: codeCopyPasteboard)
    }

    private func copyCode(_ index: Int, to pasteboard: NSPasteboard) {
        guard let markdown = markdown?.layout, markdown.codeBlocks.indices.contains(index) else { return }
        pasteboard.clearContents()
        pasteboard.setString(markdown.codeBlocks[index].code, forType: .string)
        copiedCodeBlock = index
        codeCopyFeedbackTask?.cancel()
        let wait = codeCopyFeedbackWait
        codeCopyFeedbackTask = Task { @MainActor [weak self] in
            await wait()
            guard !Task.isCancelled else { return }
            self?.copiedCodeBlock = nil
        }
    }

    func clickCodeCopyForTesting(block: Int, pasteboard: NSPasteboard) -> Bool {
        guard let markdown = markdown?.layout, markdown.codeBlocks.indices.contains(block) else { return false }
        copyCode(block, to: pasteboard)
        return true
    }

    var copiedCodeBlockForTesting: Int? { copiedCodeBlock }
    var codeCopyFeedbackTaskForTesting: Task<Void, Never>? { codeCopyFeedbackTask }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Added once: an `.inVisibleRect` area follows the view, and replacing
        // it under the pointer fires a spurious exit/enter pair.
        guard trackingAreas.isEmpty else { return }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerMoved(toWindowLocation: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        pointerMoved(toWindowLocation: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isPointerCovered = false
        updateCursor(at: nil)
        setHovering(false)
    }

    /// Tracking areas still fire under overlays (launcher, palettes); a
    /// covered move behaves like leaving the row, once.
    private func pointerMoved(toWindowLocation location: NSPoint) {
        guard isTopmostHitTarget(atWindowLocation: location) else {
            if !isPointerCovered {
                isPointerCovered = true
                updateCursor(at: nil)
                setHovering(false)
            }
            return
        }
        isPointerCovered = false
        updateCursor(at: convert(location, from: nil))
        setHovering(true)
    }

    private func setHovering(_ inside: Bool) {
        guard inside != isHovering else { return }
        isHovering = inside
        if inside {
            if actions.menu != nil { ensureActionsButton() }
            hover.enter()
        } else {
            hover.leave()
        }
        // A tool row shows its timestamp while hovered; it is one line, so
        // only its first tile changes.
        if hoverChangesLayout {
            cachedLayout = nil
            tiles[0]?.setNeedsDisplay()
        }
    }

    /// Only a tool row with a timestamp lays out differently while hovered.
    private var hoverChangesLayout: Bool {
        if case .toolCall(_, _, _, let timestamp?, _) = content { return !timestamp.isEmpty }
        return false
    }

    /// Detaching a retained row clears hover without the pointer-exit delay.
    func resetHover() {
        isPointerCovered = false
        let wasHovering = isHovering
        isHovering = false
        hover.reset()
        isMenuOpen = false
        if wasHovering, hoverChangesLayout { cachedLayout = nil }
    }

    /// Creates, updates, or removes the button for the latest `actions`.
    func syncActionsButton() {
        if actions.menu == nil {
            actionsButton?.removeFromSuperview()
            actionsTimestamp?.removeFromSuperview()
            actionsButton = nil
            actionsTimestamp = nil
        } else if actions.showsActionsPermanently || isHovering {
            ensureActionsButton()
        }
        positionActions()
        refreshActionsVisibility()
    }

    /// Built on first hover, not with the row: every platform view costs a
    /// layout pass when its row mounts mid-scroll. Once built it stays
    /// mounted, toggling alpha, since removing it would dismiss an open menu.
    private func ensureActionsButton() {
        guard actionsButton == nil else { return }
        let button = ActionsButton()
        button.target = self
        button.action = #selector(showActionsMenu(_:))
        if let theme { button.apply(theme: theme) }
        addSubview(button)
        actionsButton = button
        // `@Published` publishes before it stores, so keep the delivered value.
        hoverObservation = hover.$isVisible.sink { [weak self] visible in
            MainActor.assumeIsolated {
                self?.isHoverVisible = visible
                self?.refreshActionsVisibility()
            }
        }
        positionActions()
        refreshActionsVisibility()
    }

    private var showsActions: Bool {
        actions.showsActionsPermanently || isMenuOpen || isHoverVisible
    }

    func refreshActionsVisibility() {
        guard let actionsButton else { return }
        let alpha: CGFloat = showsActions ? 1 : 0
        actionsButton.alphaValue = alpha
        actionsTimestamp?.alphaValue = alpha
    }

    /// Flush with the right edge of the reserved lane: the button's own
    /// padding makes the net inset `laneWidth - 8`; `y: -2` aligns it with the
    /// top of the content, as `ACPMessageGutter` does.
    func positionActions() {
        guard let actionsButton, lastMeasuredWidth != nil else { return }
        let column = columnRect
        let x = column.maxX + ACPMessageGutterLayout.laneWidth - 8 - ACPMessageGutterLayout.menuWidth
        let size = NSSize(width: ACPMessageGutterLayout.menuWidth, height: ACPMessageGutterLayout.menuWidth)
        actionsButton.frame = NSRect(origin: NSPoint(x: x, y: -2), size: size)
        let createdAt = actions.menu?.createdAt
        let showsInline = createdAt != nil
            && ACPTranscriptRowContent.showsInlineTimestamp(
                availableRowContentWidth: column.width,
                availableTrailingGutterWidth: (lastMeasuredWidth ?? 0) - column.maxX
            )
        guard showsInline, let createdAt, let theme else {
            actionsTimestamp?.removeFromSuperview()
            actionsTimestamp = nil
            return
        }
        let label = actionsTimestamp ?? makeTimestampLabel()
        label.stringValue = ACPMessageTimestampFormatter.string(for: createdAt)
        label.textColor = theme.nsColor("fg-faint")
        label.layer?.backgroundColor = theme.nsColor("bg-3").withAlphaComponent(0.92).cgColor
        label.sizeToFit()
        let labelSize = NSSize(width: label.frame.width + 12, height: label.frame.height + 8)
        label.frame = NSRect(
            x: x, y: actionsButton.frame.maxY + ACPMessageGutterLayout.timestampVerticalSpacing,
            width: labelSize.width, height: labelSize.height
        )
        label.layer?.cornerRadius = labelSize.height / 2
        label.alphaValue = actionsButton.alphaValue
    }

    private func makeTimestampLabel() -> NSTextField {
        let label = TimestampLabel(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        label.alignment = .center
        label.wantsLayer = true
        label.setAccessibilityElement(false)
        addSubview(label)
        actionsTimestamp = label
        return label
    }

    @objc private func showActionsMenu(_ sender: NSButton) {
        guard let input = actions.menu else { return }
        let menu = ACPMessageActionsMenu.make(input)
        menu.delegate = self
        menu.popUp(
            positioning: menu.items.first { $0.title == "Copy message" },
            at: NSPoint(x: 0, y: sender.bounds.height + 2),
            in: sender
        )
    }

    var actionsButtonForTesting: NSButton? { actionsButton }

    var isMenuOpenForTesting: Bool {
        get { isMenuOpen }
        set { isMenuOpen = newValue }
    }

    func hoverForTesting(_ inside: Bool) {
        setHovering(inside)
    }

    func flushHoverForTesting() {
        hover.flushPendingHide()
    }
}

extension ACPTranscriptCoreTextRowView: NSMenuItemValidation {
    /// Copy only with something selected.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(copy(_:)) ? !selectedText().isEmpty : true
    }
}

extension ACPTranscriptCoreTextRowView: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { isMenuOpen = true }
    func menuDidClose(_ menu: NSMenu) { isMenuOpen = false }
}

/// The "…" button, styled as `ACPMessageGutter` styles its SwiftUI wrapper.
final class ActionsButton: NSButton {
    private static let ellipsisImage = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Message actions")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        image = Self.ellipsisImage
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        toolTip = "Message actions"
        setAccessibilityLabel("Message actions")
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 0.5
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ACPMessageGutterLayout.menuWidth, height: ACPMessageGutterLayout.menuWidth)
    }

    /// A hidden button is not a click target, as `allowsHitTesting(false)` does for the SwiftUI one.
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue == 0 ? nil : super.hitTest(point)
    }

    @MainActor
    func apply(theme: Theme) {
        contentTintColor = theme.nsColor("fg-muted")
        layer?.backgroundColor = theme.nsColor("bg-3").withAlphaComponent(0.85).cgColor
        layer?.borderColor = theme.nsColor("line").cgColor
    }
}

/// The inline timestamp capsule under the button; never a hit target.
private final class TimestampLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
