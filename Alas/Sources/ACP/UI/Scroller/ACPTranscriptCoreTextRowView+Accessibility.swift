import AppKit

extension ACPTranscriptCoreTextRowView {
    // MARK: - Accessibility

    /// Agent and user rows hold text; the others are one-line buttons.
    private var hasTextArea: Bool {
        switch content {
        case .agent, .user: true
        default: false
        }
    }

    override func isAccessibilityElement() -> Bool {
        content != nil && !hasTextArea
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        guard content != nil else { return super.accessibilityRole() }
        return hasTextArea ? .group : .button
    }

    override func accessibilityLabel() -> String? {
        switch content {
        case .thought(let label), .toolGroupHeader(let label, _, _):
            return label
        case .toolCall(let presentation, let target, let duration, _, let failed):
            let name = [presentation.label, target].compactMap { $0 }.joined(separator: " ")
            return [name, duration, failed ? "failed" : nil].compactMap { $0 }.joined(separator: ", ")
        case .agent, .user, nil:
            return super.accessibilityLabel()
        }
    }

    override func accessibilityValue() -> Any? {
        switch content {
        case .toolGroupHeader(_, _, let expanded): expanded ? "Expanded" : "Collapsed"
        // A native tool call or thought is always collapsed.
        case .thought, .toolCall: "Collapsed"
        case .agent, .user, nil: super.accessibilityValue()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard !hasTextArea, let toggle = actions.toggleExpanded else { return false }
        if case .toolGroupHeader(_, _, let expanded) = content {
            toggle(!expanded)
        } else {
            toggle(true)
        }
        return true
    }

    override func accessibilityChildren() -> [Any]? {
        // The system's list may omit subviews, so add the actions button
        // explicitly unless it is already there.
        var children = super.accessibilityChildren() ?? []
        let (button, elements, links, copies) = MainActor.assumeIsolated {
            (actionsButton as NSButton?, textAccessibilityElements(), linkAccessibilityElements(), codeCopyAccessibilityElements())
        }
        if let button, !children.contains(where: { $0 as AnyObject === button }) { children.append(button) }
        return children + elements + links + copies
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        // AppKit asks on the main thread.
        let hit: (
            button: NSButton?, copy: ACPTranscriptCodeCopyAccessibilityElement?,
            link: ACPTranscriptLinkAccessibilityElement?, element: ACPTranscriptTextAccessibilityElement?
        ) =
            MainActor.assumeIsolated {
                guard let window else { return (nil, nil, nil, nil) }
                let local = convert(window.convertPoint(fromScreen: point), from: nil)
                // A visible actions button answers for itself.
                if let actionsButton, actionsButton.alphaValue > 0, actionsButton.frame.contains(local) { return (actionsButton, nil, nil, nil) }
                if let copy = codeCopyAccessibilityElements().first(where: { $0.accessibilityFrameInParentSpace().contains(local) }) {
                    return (nil, copy, nil, nil)
                }
                if let link = linkAccessibilityElements().first(where: { $0.accessibilityFrameInParentSpace().contains(local) }) {
                    return (nil, nil, link, nil)
                }
                return (nil, nil, nil, textAccessibilityElements().first { $0.accessibilityFrameInParentSpace().contains(local) })
            }
        if let button = hit.button { return button }
        if let copy = hit.copy { return copy }
        if let link = hit.link { return link }
        let element = hit.element
        return element ?? super.accessibilityHitTest(point)
    }

    private static func lineStarts(of markdown: ACPTranscriptMarkdownLayout) -> [TextSelection.Position] {
        markdown.lines.compactMap { line in
            line.block.map { TextSelection.Position(block: $0, index: line.range.location) }
        }
    }

    /// Keeps a held element's lines current when the text re-wraps, since
    /// assistive apps may query it without asking the row for its children.
    func refreshTextElement(from layout: Layout) {
        guard let textElement else { return }
        for case .markdown(let markdown, _, _) in layout.items where markdown.texts == textElement.texts {
            if textElement.updateLines(Self.lineStarts(of: markdown)) {
                NSAccessibility.post(element: textElement, notification: .layoutChanged)
            }
            return
        }
    }

    /// Markdown links, framed over their drawn text (the union of a wrapped
    /// link's line rects).
    func linkAccessibilityElements() -> [ACPTranscriptLinkAccessibilityElement] {
        guard hasTextArea, let (markdown, origin) = markdown else { return [] }
        let spans = markdown.linkSpans()
        if linkElements.map(\.url) != spans.map(\.url) {
            linkElements = spans.map { span in
                let element = ACPTranscriptLinkAccessibilityElement(url: span.url, text: span.text) { [weak self] url in
                    self?.actions.openURL(url)
                }
                element.setAccessibilityParent(self)
                return element
            }
        }
        for (element, span) in zip(linkElements, spans) {
            let frame = span.rects.dropFirst().reduce(span.rects[0]) { $0.union($1) }
            element.setAccessibilityFrameInParentSpace(frame.offsetBy(dx: origin.x, dy: origin.y))
        }
        return linkElements
    }

    /// Code-block Copy buttons, framed where they are drawn.
    func codeCopyAccessibilityElements() -> [ACPTranscriptCodeCopyAccessibilityElement] {
        guard hasTextArea, let (markdown, origin) = markdown else { return [] }
        if codeCopyElements.count != markdown.codeBlocks.count {
            codeCopyElements = markdown.codeBlocks.indices.map { index in
                let element = ACPTranscriptCodeCopyAccessibilityElement { [weak self] in self?.copyCodeBlock(index) }
                element.setAccessibilityParent(self)
                return element
            }
        }
        for (index, element) in codeCopyElements.enumerated() {
            element.setAccessibilityFrameInParentSpace(
                markdown.copyButtonRect(index, copied: copiedCodeBlock == index).offsetBy(dx: origin.x, dy: origin.y)
            )
        }
        return codeCopyElements
    }

    private func textAccessibilityElements() -> [ACPTranscriptTextAccessibilityElement] {
        guard hasTextArea, let (markdown, origin) = markdown, !markdown.texts.isEmpty else { return [] }
        let lines = Self.lineStarts(of: markdown)
        let element: ACPTranscriptTextAccessibilityElement
        if let textElement, textElement.texts == markdown.texts {
            element = textElement
            element.updateLines(lines)
        } else {
            element = ACPTranscriptTextAccessibilityElement(texts: markdown.texts, lines: lines)
            element.setAccessibilityRole(.textArea)
            element.setAccessibilityParent(self)
            element.frameForRange = { [weak self] start, end in
                guard let self, let window else { return nil }
                return textRect(from: start, to: end).map { window.convertToScreen(convert($0, to: nil)) }
            }
            element.selection = { [weak self] in
                guard let selection = self?.textSelection else { return nil }
                return (selection.start, selection.end)
            }
            element.select = { [weak self] start, end in
                self?.textSelection = .init(anchor: start, focus: end)
            }
            element.visibleLines = { [weak self] in self?.visibleTextPositions() }
            textElement = element
        }
        element.setAccessibilityFrameInParentSpace(CGRect(origin: origin, size: CGSize(width: markdown.width, height: markdown.height)))
        return [element]
    }

    /// The rect of the text from `start` to `end`, in view coordinates.
    private func textRect(from start: TextSelection.Position, to end: TextSelection.Position) -> CGRect? {
        guard let (markdown, origin) = markdown else { return nil }
        var result: CGRect?
        for line in markdown.lines {
            guard let block = line.block else { continue }
            let first = line.range.location, last = first + line.visibleLength
            let from = block == start.block ? max(start.index, first) : first
            let to = block == end.block ? min(end.index, last) : last
            guard block >= start.block, block <= end.block, from <= to else { continue }
            let x1 = CTLineGetOffsetForStringIndex(line.line, from, nil), x2 = CTLineGetOffsetForStringIndex(line.line, to, nil)
            let rect = CGRect(
                x: origin.x + line.origin.x + min(x1, x2), y: origin.y + line.origin.y, width: max(1, abs(x2 - x1)), height: line.height
            )
            result = result.map { $0.union(rect) } ?? rect
        }
        return result
    }

    /// The first and last text positions the enclosing scroll view shows.
    private func visibleTextPositions() -> (start: TextSelection.Position, end: TextSelection.Position)? {
        guard let (markdown, origin) = markdown else { return nil }
        let visible = visibleRect
        let shown = markdown.lines.filter { line in
            line.block != nil && line.origin.y + origin.y + line.height > visible.minY && line.origin.y + origin.y < visible.maxY
        }
        guard let first = shown.first, let last = shown.last, let firstBlock = first.block, let lastBlock = last.block else { return nil }
        return (
            .init(block: firstBlock, index: first.range.location),
            .init(block: lastBlock, index: last.range.location + last.visibleLength)
        )
    }
}
