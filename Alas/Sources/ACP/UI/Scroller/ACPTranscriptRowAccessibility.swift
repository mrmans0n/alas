import AppKit

/// A native transcript row's text as navigable static text, ported from the
/// diff's `CodeAccessibilityElement`: whole value, characters, and visual
/// lines, with the selection bound to the row's. The value is the rendered
/// block texts joined by newlines, the same text copy puts on the pasteboard.
/// The text is immutable after init; the line starts are refreshed only on the
/// main actor by the owning row, and AppKit only reads it on the main thread.
final class ACPTranscriptTextAccessibilityElement: NSAccessibilityElement, @unchecked Sendable {
    typealias Position = ACPTranscriptCoreTextRowView.TextSelection.Position

    let texts: [String]
    private let text: NSString
    /// Where each block starts in `text`.
    private let blockStarts: [Int]
    /// Where each visual line starts in `text`. Refreshed on relayout, so
    /// the element keeps its identity while the wrapping changes.
    private var lineStarts: [Int] = []

    /// `lines` are the (block, offset in block) starts of the drawn lines.
    init(texts: [String], lines: [Position]) {
        var starts: [Int] = []
        var location = 0
        for block in texts {
            starts.append(location)
            location += (block as NSString).length + 1
        }
        self.texts = texts
        text = texts.joined(separator: "\n") as NSString
        blockStarts = starts
        super.init()
        updateLines(lines)
    }

    var lineStartsForTesting: [Int] { lineStarts }

    /// Replaces the visual line starts after the text re-wrapped.
    @discardableResult
    func updateLines(_ lines: [Position]) -> Bool {
        var starts = lines.compactMap { line in blockStarts.indices.contains(line.block) ? blockStarts[line.block] + line.index : nil }
        if starts.first != 0 { starts.insert(0, at: 0) }
        defer { lineStarts = starts }
        return starts != lineStarts
    }

    override func accessibilityValue() -> Any? { text as String }
    override func accessibilityNumberOfCharacters() -> Int { text.length }

    /// The lines the enclosing scroll view shows, set by the row.
    var visibleLines: (@MainActor @Sendable () -> (start: Position, end: Position)?)?

    override func accessibilityVisibleCharacterRange() -> NSRange {
        guard let visibleLines else { return NSRange(location: 0, length: text.length) }
        guard let lines = MainActor.assumeIsolated({ visibleLines() }) else { return NSRange(location: 0, length: 0) }
        let start = offset(of: lines.start)
        return NSRange(location: start, length: max(0, offset(of: lines.end) - start))
    }

    override func accessibilityString(for range: NSRange) -> String? {
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return nil }
        return text.substring(with: range)
    }

    override func accessibilityLine(for index: Int) -> Int {
        max(0, (lineStarts.lastIndex { $0 <= index }) ?? 0)
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        guard lineStarts.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : text.length
        return NSRange(location: lineStarts[line], length: end - lineStarts[line])
    }

    /// The screen rect of the text from one position to another, set by the
    /// row that draws it.
    var frameForRange: (@MainActor @Sendable (_ start: Position, _ end: Position) -> NSRect?)?
    /// The row's selection, and a way to replace it, so assistive apps can
    /// read and set it as in a text view.
    var selection: (@MainActor @Sendable () -> (start: Position, end: Position)?)?
    var select: (@MainActor @Sendable (_ start: Position, _ end: Position) -> Void)?

    private func offset(of position: Position) -> Int {
        guard blockStarts.indices.contains(position.block) else { return text.length }
        return min(blockStarts[position.block] + position.index, text.length)
    }

    func position(at offset: Int) -> Position {
        let offset = min(max(0, offset), text.length)
        guard let block = blockStarts.lastIndex(where: { $0 <= offset }) else { return Position(block: 0, index: 0) }
        return Position(block: block, index: min(offset - blockStarts[block], (texts[block] as NSString).length))
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        guard let selection, let span = MainActor.assumeIsolated({ selection() }) else { return NSRange(location: 0, length: 0) }
        let start = offset(of: span.start)
        return NSRange(location: start, length: max(0, offset(of: span.end) - start))
    }

    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        guard let select, range.location != NSNotFound else { return }
        let start = position(at: range.location), end = position(at: NSMaxRange(range))
        MainActor.assumeIsolated { select(start, end) }
    }

    override func accessibilitySelectedText() -> String? {
        accessibilityString(for: accessibilitySelectedTextRange())
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard range.location != NSNotFound, range.location <= text.length, let frameForRange else { return accessibilityFrame() }
        let start = position(at: range.location), end = position(at: NSMaxRange(range))
        // AppKit asks on the main thread.
        return MainActor.assumeIsolated { frameForRange(start, end) } ?? accessibilityFrame()
    }
}

/// A code block's drawn Copy button as an accessible button, so VoiceOver
/// and Full Keyboard Access reach it as they do `CodeBlockView`'s.
final class ACPTranscriptCodeCopyAccessibilityElement: NSAccessibilityElement, @unchecked Sendable {
    private let press: @MainActor @Sendable () -> Void

    init(press: @escaping @MainActor @Sendable () -> Void) {
        self.press = press
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel("Copy code")
    }

    override func accessibilityPerformPress() -> Bool {
        // AppKit asks on the main thread.
        let press = press
        MainActor.assumeIsolated { press() }
        return true
    }
}

/// A code block's drawn language label, read as static text as in the SwiftUI block's header.
final class ACPTranscriptCodeLabelAccessibilityElement: NSAccessibilityElement, @unchecked Sendable {
    init(label: String) {
        super.init()
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label)
    }
}

/// A drawn Markdown link as an accessible link, so VoiceOver and Full
/// Keyboard Access can reach and open it as in the text view renderer.
final class ACPTranscriptLinkAccessibilityElement: NSAccessibilityElement, @unchecked Sendable {
    let url: URL
    /// The link's rect on each line it covers, in the row's coordinates. A
    /// wrapped link is hit-tested by these, not by their union, which also
    /// covers plain text beside it.
    var fragments: [CGRect] = []
    private let open: @MainActor @Sendable (URL) -> Void

    init(url: URL, text: String, open: @escaping @MainActor @Sendable (URL) -> Void) {
        self.url = url
        self.open = open
        super.init()
        setAccessibilityRole(.link)
        setAccessibilityLabel(text)
        setAccessibilityURL(url)
    }

    override func accessibilityPerformPress() -> Bool {
        // AppKit asks on the main thread.
        let open = open, url = url
        MainActor.assumeIsolated { open(url) }
        return true
    }
}
