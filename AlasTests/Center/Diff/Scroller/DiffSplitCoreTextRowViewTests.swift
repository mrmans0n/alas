import AppKit
import CoreText
import Testing
@testable import Alas

@MainActor
@Suite struct DiffSplitCoreTextRowViewTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var theme: Theme { try! ThemeStore().current }

    /// A split result for a hunk replacing `old` lines with `new` lines.
    private func result(old: [String], new: [String]) -> DiffPaneTextDocumentBuilder.SplitResult {
        var body = old.filter { !$0.isEmpty }.map { "-" + $0 }
        body += new.map { "+" + $0 }
        let oldCount = old.filter { !$0.isEmpty }.count
        let diff = DiffParser.parse("@@ -1,\(oldCount) +1,\(new.count) @@\n" + body.joined(separator: "\n") + "\n")
        let model = DiffDisplayModelBuilder.build(diff: diff, filePath: "Sources/Example.swift")
        let rows = model.groups.flatMap(\.rows)
        return DiffPaneTextDocumentBuilder.buildSplit(rows: rows, fileExtension: "swift", font: font, showWhitespace: false, theme: theme)
    }

    @Test(arguments: [false, true])
    func inlineBackgroundEnclosesItsGlyphs(wraps: Bool) throws {
        let text = NSAttributedString(string: "MMMM", attributes: [
            .font: font, .foregroundColor: NSColor.white, .backgroundColor: NSColor.red,
        ])
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: text,
            lines: [.init(kind: .add, range: NSRange(location: 0, length: text.length))]
        )
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        view.configure(
            stacked: DiffPaneTextDocumentBuilder.StackedResult(code: document, gutter: NSAttributedString(string: "")),
            font: font, theme: theme, wraps: wraps
        )
        view.updateLayer()
        let tile = try #require(view.layer?.sublayers?.first { $0.value(forKey: "tileIndex") != nil })
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 80, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        tile.delegate?.draw?(tile, in: context.cgContext)
        var backgroundRows: [Int] = []
        var glyphRows: [Int] = []
        for y in 0..<80 {
            for x in 0..<100 {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.redComponent > 0.9 && color.greenComponent < 0.1 {
                    backgroundRows.append(y)
                } else if color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9 {
                    glyphRows.append(y)
                }
            }
        }
        let backgroundTop = try #require(backgroundRows.min())
        let backgroundBottom = try #require(backgroundRows.max())
        let glyphTop = try #require(glyphRows.min())
        let glyphBottom = try #require(glyphRows.max())
        #expect(backgroundTop <= glyphTop)
        #expect(backgroundBottom >= glyphBottom)
    }

    @Test func narrowContentCannotScroll() {
        var model = DiffSplitHorizontalScroll(oldContentWidth: 100, newContentWidth: 100, oldViewportWidth: 300, newViewportWidth: 300)
        #expect(model.maxOffset(.new) == 0)
        let moved = model.scroll(.new, byPoints: 50)
        #expect(!moved)
        #expect(model.offset(.new) == 0)
    }

    @Test func scrollingOneSideLeavesTheOtherAndClamps() {
        var model = DiffSplitHorizontalScroll(oldContentWidth: 900, newContentWidth: 900, oldViewportWidth: 300, newViewportWidth: 300)
        let forward = model.scroll(.new, byPoints: 1_000)
        #expect(forward)
        #expect(model.offset(.new) == 600)
        #expect(model.offset(.old) == 0)
        let back = model.scroll(.new, byPoints: -2_000)
        #expect(back)
        #expect(model.offset(.new) == 0)
    }

    @Test func resizeClampsOffset() {
        var model = DiffSplitHorizontalScroll(oldContentWidth: 900, newContentWidth: 900, oldViewportWidth: 300, newViewportWidth: 300)
        _ = model.scroll(.new, byPoints: 600)
        model.setViewportWidths(old: 800, new: 800)
        #expect(model.offset(.new) == 100)
    }

    private func mountedRow(newLine: String) -> (DiffSplitCoreTextRowView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 200))
        window.contentView?.addSubview(view)
        view.configure(result: result(old: [], new: [newLine]), font: font, theme: theme)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    private final class ForwardingProbe: NSResponder {
        var forwarded = 0
        override func scrollWheel(with event: NSEvent) { forwarded += 1 }
    }

    @Test func horizontalScrollOverTheNewSideMovesOnlyThatSide() {
        let (view, window) = mountedRow(newLine: String(repeating: "w", count: 300))
        defer { window.close() }
        let handled = view.scroll(deltaX: -40, deltaY: 0, isPrecise: true, at: NSPoint(x: 900, y: 20))
        #expect(handled)
        #expect(view.horizontalScroll.offset(.new) == 40)
        #expect(view.horizontalScroll.offset(.old) == 0)
    }

    @Test func verticalWheelEventsGoToTheNextResponder() throws {
        let (view, window) = mountedRow(newLine: String(repeating: "w", count: 300))
        defer { window.close() }
        let probe = ForwardingProbe()
        view.nextResponder = probe
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -40, wheel2: 0, wheel3: 0))
        view.scrollWheel(with: try #require(NSEvent(cgEvent: cgEvent)))
        #expect(probe.forwarded == 1)
    }

    @Test func highlightingACommentKeepsTheScrollOffset() {
        let lines = result(old: [], new: [String(repeating: "w", count: 300)])
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 1200, height: 100))
        view.configure(result: lines, font: font, theme: theme)
        view.layout()
        _ = view.scroll(deltaX: -40, deltaY: 0, isPrecise: true, at: NSPoint(x: 900, y: 20))
        let highlight = DiffReviewCommentHighlight(path: "Sources/Example.swift", side: .new, line: 1)
        view.configure(result: lines, font: font, theme: theme, review: .init(activeHighlight: highlight))
        #expect(view.horizontalScroll.offset(.new) == 40)
    }

    @Test func resizingUpdatesTheViewportWithoutALayoutPass() {
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        view.configure(result: result(old: [], new: [String(repeating: "w", count: 300)]), font: font, theme: theme)
        let before = view.horizontalScroll.newViewportWidth
        view.setFrameSize(NSSize(width: 1200, height: 100))
        #expect(view.horizontalScroll.newViewportWidth > before)
    }

    /// One trackpad gesture: (phase, momentum phase, dx, dy) per event.
    @Test(arguments: [
        // Begins sideways: later mostly vertical events still scroll sideways.
        ([(NSEvent.Phase.began, NSEvent.Phase(), CGFloat(-10), CGFloat(1)), (.changed, [], -1, -6), ([], .changed, -1, -6)], true, [true, true, true]),
        // Begins vertical: later sideways jitter goes to the review.
        ([(.began, [], -1, -10), (.changed, [], -8, -2)], true, [false, false]),
        // Nothing to scroll sideways: the review gets everything.
        ([(.began, [], -10, 0)], false, [false]),
        // Mouse wheels have no phases and are decided per event.
        ([([], [], -10, 0), ([], [], 0, -10)], true, [true, false]),
    ] as [([(NSEvent.Phase, NSEvent.Phase, CGFloat, CGFloat)], Bool, [Bool])])
    func gesturesKeepTheAxisTheyBeganOn(events: [(NSEvent.Phase, NSEvent.Phase, CGFloat, CGFloat)], canScroll: Bool, expected: [Bool]) {
        var gesture = DiffSplitScrollGesture()
        let claims = events.map {
            gesture.claims(phase: $0.0, momentumPhase: $0.1, deltaX: $0.2, deltaY: $0.3, canScroll: canScroll)
        }
        #expect(claims == expected)
    }

    @Test func newContentResetsBothSidesToTheLeadingEdge() {
        let (view, window) = mountedRow(newLine: String(repeating: "w", count: 300))
        defer { window.close() }
        _ = view.scroll(deltaX: -40, deltaY: 0, isPrecise: true, at: NSPoint(x: 900, y: 20))
        view.configure(result: result(old: [], new: [String(repeating: "v", count: 300)]), font: font, theme: theme)
        #expect(view.horizontalScroll.offset(.new) == 0)
        #expect(view.horizontalScroll.offset(.old) == 0)
    }

    @Test func draggingTheScrollerMovesTheOffset() {
        let (view, window) = mountedRow(newLine: String(repeating: "w", count: 300))
        defer { window.close() }
        let scroller = view.scrollerForTesting(.new)
        scroller.doubleValue = 0.5
        _ = scroller.sendAction(scroller.action, to: scroller.target)
        #expect(abs(view.horizontalScroll.offset(.new) - view.horizontalScroll.maxOffset(.new) / 2) < 1)
    }

    @Test(arguments: [
        ([10, 30], [20, 10], [0, 20, 50]),
        ([], [10, 20], [0, 10, 30]),
        ([0], [0], [0, 10]),
    ] as [([CGFloat], [CGFloat], [CGFloat])])
    func rowsAreAsTallAsTheirTallerSide(old: [CGFloat], new: [CGFloat], expected: [CGFloat]) {
        #expect(DiffSplitCoreTextRowView.rowTops(oldHeights: old, newHeights: new, minimum: 10) == expected)
    }

    @Test(arguments: [
        // Partly covered rows on both ends count.
        (CGFloat(10), CGFloat(25), 0..<2),
        (25, 55, 1..<3),
        // A span ending exactly on a row top does not reach that row.
        (0, 20, 0..<1),
        // Above the code (the header) or below it: nothing.
        (-30, 0, 0..<0),
        (60, 90, 0..<0),
    ])
    func spansCoverTheRowsTheyTouch(minY: CGFloat, maxY: CGFloat, expected: Range<Int>) {
        #expect(DiffSplitCoreTextRowView.visibleRows(from: minY, to: maxY, rowTops: [0, 20, 50, 60]) == expected)
    }

    @Test(arguments: [
        // Within one tile, and straddling a tile edge.
        (CGFloat(0), CGFloat(100), 0..<1),
        (500, 600, 0..<2),
        // Clamped to the row: the last tile is short, and nothing lies beyond it.
        (1100, 5000, 2..<3),
        (-1000, -10, 0..<0),
        (1200, 1300, 0..<0),
    ])
    func rectsTouchTheTilesUnderThem(minY: CGFloat, maxY: CGFloat, expected: Range<Int>) {
        let rect = NSRect(x: 0, y: minY, width: 800, height: maxY - minY)
        #expect(DiffSplitCoreTextRowView.tileRange(covering: rect, height: 1200, tileHeight: 512) == expected)
    }

    @Test(arguments: [
        (DiffSplitCoreTextRowView.Side.old, false),
        (.new, false),
        (.old, true),
        (.new, true),
    ])
    func codeSitsRightOfItsGutterInItsPane(side: DiffSplitCoreTextRowView.Side, stacked: Bool) {
        let column = DiffSplitCoreTextRowView.codeColumn(side, containerWidth: 800, stacked: stacked, gutter: 50)
        let expected: (minX: CGFloat, width: CGFloat)
        if stacked {
            expected = side == .new ? (50, 750) : (0, 0)
        } else {
            let frames = DiffPaneSplitGeometry.frames(containerWidth: 800)
            let pane = side == .old ? frames.oldPane : frames.newPane
            expected = (pane.minX + 50, pane.width - 50)
        }
        #expect(column.minX == expected.minX)
        #expect(column.width == expected.width)
    }

    @Test(arguments: [CGFloat(13), 24], [DiffContextBoundary.above, .below])
    func expansionRowsCenterLabelsWithChevrons(fontSize: CGFloat, boundary: DiffContextBoundary) throws {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let document = expandableSplit(font: font, boundary: boundary).oldCode
        let line = { (index: Int) in
            document.attributedString.attributedSubstring(from: document.lines[index].range)
        }
        let own = try #require(DiffSplitCoreTextRowView.ownMetrics(of: line(0), font: font))
        #expect(own.lineHeight == DiffPaneTextDocumentBuilder.expandableContextRowHeight(font: font))
        #expect(own.indent == DiffPaneTextDocumentBuilder.expandableContextHeadIndent(font: font))
        let glyphBounds = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(line(0)), .useGlyphPathBounds)
        #expect(abs(own.baselineOffset - glyphBounds.midY - own.lineHeight / 2) < 0.5)
        #expect(DiffSplitCoreTextRowView.ownMetrics(of: line(1), font: font) == nil)
    }

    @Test func wrappingBreaksBetweenWordsWithinTheWidth() {
        let text = (0..<30).map { "word\($0)" }.joined(separator: " ")
        let lines = DiffSplitCoreTextRowView.wrapped(NSAttributedString(string: text, attributes: [.font: font]), width: 200)
        #expect(lines.count > 1)
        let parts = lines.map { line -> String in
            let range = CTLineGetStringRange(line)
            return (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
        }
        #expect(parts.joined() == text)
        #expect(parts.dropLast().allSatisfy { $0.hasSuffix(" ") })
        #expect(lines.allSatisfy { CTLineGetTypographicBounds($0, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth($0) <= 200 })
    }

    typealias Position = DiffSplitCoreTextRowView.TextSelection.Position

    @Test(arguments: [
        // Within a line, in either drag direction.
        (Position(row: 0, index: 4), Position(row: 0, index: 9), "alpha"),
        (Position(row: 0, index: 9), Position(row: 0, index: 4), "alpha"),
        // Across lines: the tail of the first, the head of the last, joined by a newline.
        (Position(row: 0, index: 10), Position(row: 1, index: 3), "= 1\nlet"),
        // Offsets past a line's end clamp to it.
        (Position(row: 1, index: 8), Position(row: 1, index: 99), " = 2"),
        (Position(row: 0, index: 2), Position(row: 0, index: 2), ""),
    ])
    func selectionsCopyTheTextBetweenTheirEnds(anchor: Position, focus: Position, expected: String) {
        let selection = DiffSplitCoreTextRowView.TextSelection(side: .new, anchor: anchor, focus: focus)
        #expect(selection.text(in: ["let alpha = 1", "let beta = 2"]) == expected)
    }

    private func click(_ view: NSView, _ type: NSEvent.EventType, at point: NSPoint, count: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: count, pressure: 1
        ))
    }

    @Test(arguments: [(1, "let alpha = 1\nlet beta = 2"), (3, "let beta = 2")])
    func draggingOrTripleClickingCodeCopiesIt(clickCount: Int, expected: String) throws {
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.configure(result: result(old: [], new: ["let alpha = 1", "let beta = 2"]), font: font, theme: theme)
        let code = DiffSplitCoreTextRowView.codeColumn(.new, containerWidth: 800, stacked: false, gutter: 42)
        let rowY = { (row: Int) in DiffSplitCoreTextRowView.verticalInset + (CGFloat(row) + 0.5) * view.lineHeight }
        if clickCount == 1 {
            view.mouseDown(with: try click(view, .leftMouseDown, at: NSPoint(x: code.minX + DiffSplitCoreTextRowView.textInset, y: rowY(0))))
            view.mouseDragged(with: try click(view, .leftMouseDragged, at: NSPoint(x: code.minX + code.width - 5, y: rowY(1))))
        } else {
            view.mouseDown(with: try click(view, .leftMouseDown, at: NSPoint(x: code.minX + 30, y: rowY(1)), count: clickCount))
        }
        view.mouseUp(with: try click(view, .leftMouseUp, at: NSPoint(x: code.minX + 30, y: rowY(1)), count: clickCount))
        let pasteboard = NSPasteboard(name: .init("diff-coretext-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(view.copySelection(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == expected)
    }

    /// The new side's code column and line `row`'s vertical middle, in a row 800pt wide.
    private func newCodePoint(_ view: DiffSplitCoreTextRowView, x: (NSRect) -> CGFloat, row: Int) -> NSPoint {
        let code = DiffSplitCoreTextRowView.codeColumn(.new, containerWidth: 800, stacked: false, gutter: 42)
        let rect = NSRect(x: code.minX + DiffSplitCoreTextRowView.textInset, y: 0, width: code.width, height: 0)
        return NSPoint(x: x(rect), y: DiffSplitCoreTextRowView.verticalInset + (CGFloat(row) + 0.5) * view.lineHeight)
    }

    @Test(arguments: [(0, CGFloat(0), "alpha"), (1, 0, ""), (0, 200, "")])
    func doubleClickingSelectsTheWordUnderThePointer(row: Int, past: CGFloat, expected: String) throws {
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.configure(result: result(old: [], new: ["let alpha = 1", ""]), font: font, theme: theme)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "let alpha = 1", attributes: [.font: font]))
        // The right half of alpha's last character: the nearest caret falls after the word.
        let x = CTLineGetOffsetForStringIndex(line, 9, nil) - 1 + past
        let point = newCodePoint(view, x: { $0.minX + x }, row: row)
        view.mouseDown(with: try click(view, .leftMouseDown, at: point, count: 2))
        view.mouseUp(with: try click(view, .leftMouseUp, at: point, count: 2))
        #expect(view.selectedText() == expected)
    }

    @Test func escapeClearsTheSelection() throws {
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.configure(result: result(old: [], new: ["let alpha = 1"]), font: font, theme: theme)
        let point = newCodePoint(view, x: { $0.minX + 20 }, row: 0)
        view.mouseDown(with: try click(view, .leftMouseDown, at: point, count: 3))
        view.mouseUp(with: try click(view, .leftMouseUp, at: point, count: 3))
        #expect(!view.selectedText().isEmpty)
        view.cancelOperation(nil)
        #expect(view.selectedText().isEmpty)
    }

    @Test func pointerOverNewSideCodeResolvesTheSymbolForLSP() throws {
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.configure(result: result(old: ["let gamma = 0"], new: ["let alpha = 1"]), font: font, theme: theme)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "let alpha = 1", attributes: [.font: font]))
        let y = DiffSplitCoreTextRowView.verticalInset + view.lineHeight / 2
        let textX = { (side: DiffSplitCoreTextRowView.Side, index: Int) in
            DiffSplitCoreTextRowView.codeColumn(side, containerWidth: 800, stacked: false, gutter: 42).minX
                + DiffSplitCoreTextRowView.textInset + CTLineGetOffsetForStringIndex(line, index, nil) + 2
        }
        let start = try #require(view.lineMetadata.first).range.location
        #expect(view.characterIndex(at: NSPoint(x: textX(.new, 6), y: y)) == start + 6)
        #expect(view.symbolRange(at: NSPoint(x: textX(.new, 6), y: y)) == NSRange(location: start + 4, length: 5))
        #expect(view.characterIndex(at: NSPoint(x: textX(.new, 13) + 40, y: y)) == nil)
        #expect(view.characterIndex(at: NSPoint(x: textX(.old, 6), y: y)) == nil)
    }

    @Test func pointerBelowAShorterWrappedSideHitsNothing() throws {
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        let long = Array(repeating: "alpha", count: 40).joined(separator: " ")
        view.configure(result: result(old: [long], new: ["let alpha = 1"]), font: font, theme: theme, wraps: true)
        // The old side wraps, so the row is taller than the new side's one line.
        let below = newCodePoint(view, x: { $0.minX + 20 }, row: 1)
        #expect(view.characterIndex(at: below) == nil)
        #expect(view.textHit(at: below) == nil)
        #expect(view.characterIndex(at: newCodePoint(view, x: { $0.minX + 20 }, row: 0)) != nil)
    }

    @Test(arguments: [#selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveLeft(_:))])
    func horizontalArrowsScrollTheFocusedSide(selector: Selector) throws {
        let (view, window) = mountedRow(newLine: String(repeating: "w", count: 300))
        defer { window.close() }
        let point = NSPoint(x: 900, y: DiffSplitCoreTextRowView.verticalInset + view.lineHeight / 2)
        view.mouseDown(with: try click(view, .leftMouseDown, at: point))
        view.mouseUp(with: try click(view, .leftMouseUp, at: point))
        if selector == #selector(NSResponder.moveLeft(_:)) {
            _ = view.scroll(deltaX: -200, deltaY: 0, isPrecise: true, at: point)
        }
        let before = view.horizontalScroll.offset(.new)
        view.doCommand(by: selector)
        let after = view.horizontalScroll.offset(.new)
        #expect(selector == #selector(NSResponder.moveRight(_:)) ? after > before : after < before)
        #expect(view.horizontalScroll.offset(.old) == 0)
    }

    @Test func selectionSurvivesLosingFocus() throws {
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.configure(result: result(old: [], new: ["let alpha = 1"]), font: font, theme: theme)
        let point = newCodePoint(view, x: { $0.minX + 20 }, row: 0)
        view.mouseDown(with: try click(view, .leftMouseDown, at: point, count: 3))
        view.mouseUp(with: try click(view, .leftMouseUp, at: point, count: 3))
        _ = view.resignFirstResponder()
        #expect(view.selectedText() == "let alpha = 1")
    }

    @Test func accessibilityReportsOnlyTheLinesInTheViewport() throws {
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.configure(result: result(old: [], new: (0..<20).map { "let v\($0) = \($0)" }), font: font, theme: theme)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: DiffSplitCoreTextRowView.verticalInset + 3 * view.lineHeight))
        scrollView.documentView = view
        let new = try #require(view.codeAccessibilityElements().last)
        let visible = new.accessibilityVisibleCharacterRange()
        #expect(visible.location == 0)
        #expect(new.accessibilityLine(for: NSMaxRange(visible) - 1) <= 3)
    }

    @Test func reassigningTheRowClearsItsSelection() throws {
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.representedRowID = "first"
        view.configure(result: result(old: [], new: ["let alpha = 1"]), font: font, theme: theme)
        let point = newCodePoint(view, x: { $0.minX + 20 }, row: 0)
        view.mouseDown(with: try click(view, .leftMouseDown, at: point, count: 3))
        view.mouseUp(with: try click(view, .leftMouseUp, at: point, count: 3))
        view.representedRowID = "second"
        #expect(view.selectedText().isEmpty)
    }

    @Test func draggingASelectionPastTheColumnScrollsThatSide() throws {
        let (view, window) = mountedRow(newLine: String(repeating: "w", count: 300))
        defer { window.close() }
        let code = DiffSplitCoreTextRowView.codeColumn(.new, containerWidth: 1_000, stacked: false, gutter: 42)
        let y = DiffSplitCoreTextRowView.verticalInset + view.lineHeight / 2
        view.mouseDown(with: try click(view, .leftMouseDown, at: NSPoint(x: code.minX + 40, y: y)))
        view.mouseDragged(with: try click(view, .leftMouseDragged, at: NSPoint(x: code.minX + code.width + 30, y: y)))
        #expect(view.horizontalScroll.offset(.new) > 0)
        view.mouseUp(with: try click(view, .leftMouseUp, at: NSPoint(x: code.minX + code.width + 30, y: y)))
    }

    @Test func accessibilityVisibleRangeStopsAtTheVisibleWrappedFragments() throws {
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let long = Array(repeating: "alpha", count: 200).joined(separator: " ")
        view.configure(result: result(old: [], new: [long]), font: font, theme: theme, wraps: true)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: DiffSplitCoreTextRowView.verticalInset + 2 * view.lineHeight))
        scrollView.documentView = view
        let new = try #require(view.codeAccessibilityElements().last)
        let visible = new.accessibilityVisibleCharacterRange()
        #expect(visible.location == 0)
        #expect(visible.length > 0 && visible.length < (long as NSString).length)
    }

    @Test func pointerOnASurrogatePairsTrailingHalfResolvesItsStart() throws {
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.configure(result: result(old: [], new: ["a\u{1D465}b"]), font: font, theme: theme)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "a\u{1D465}b", attributes: [.font: font]))
        // Just left of the caret after the pair: the glyph's trailing half.
        let x = CTLineGetOffsetForStringIndex(line, 3, nil) - 1
        let start = try #require(view.lineMetadata.first).range.location
        #expect(view.characterIndex(at: newCodePoint(view, x: { $0.minX + x }, row: 0)) == start + 1)
    }

    @Test func pointerOverAVisibleScrollerSendsNoHover() throws {
        let (view, window) = mountedRow(newLine: String(repeating: "w", count: 300))
        defer { window.close() }
        var hovered: [NSPoint] = []
        view.hoverHandler = { hovered.append($0) }
        let scroller = view.scrollerForTesting(.new)
        let location = view.convert(NSPoint(x: scroller.frame.midX, y: scroller.frame.midY), to: nil)
        view.mouseMoved(with: try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        )))
        #expect(hovered.isEmpty)
    }

    @Test func eachSideReadsItsCodeToAccessibility() throws {
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.configure(result: result(old: ["let a = 0"], new: ["let a = 1", "let b = 2"]), font: font, theme: theme)
        let elements = view.codeAccessibilityElements()
        let values = elements.map { "\($0.accessibilityLabel() ?? ""): \($0.accessibilityValue() as? String ?? "")" }
        #expect(values == ["Old code: let a = 0\n ", "New code: let a = 1\nlet b = 2"])
        // Stable identity, so VoiceOver keeps its place, and navigable by line.
        #expect(zip(elements, view.codeAccessibilityElements()).allSatisfy { $0 === $1 })
        let new = try #require(elements.last)
        #expect(new.accessibilityString(for: new.accessibilityRange(forLine: 1)) == "let b = 2")
        #expect(new.accessibilityLine(for: 11) == 1)
    }

    @Test func accessibilityFramesFollowTheRequestedLine() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        window.contentView?.addSubview(view)
        view.configure(result: result(old: [], new: ["a", "let middle = 2", "c"]), font: font, theme: theme)
        let new = try #require(view.codeAccessibilityElements().last)
        let first = new.accessibilityFrame(for: new.accessibilityRange(forLine: 0))
        let second = new.accessibilityFrame(for: new.accessibilityRange(forLine: 1))
        #expect(abs(first.height - view.lineHeight) < 1)
        // Screen space runs upward, so the later line sits one line lower.
        #expect(abs(first.minY - second.minY - view.lineHeight) < 1)
        #expect(second.width < new.accessibilityFrame().width)
        // A range over three lines covers the middle one too.
        let all = new.accessibilityFrame(for: NSRange(location: 0, length: new.accessibilityNumberOfCharacters()))
        #expect(all.contains(second.insetBy(dx: 0.5, dy: 0.5)))
    }

    @Test func accessibilitySelectionIsTheRowsSelection() throws {
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.configure(result: result(old: [], new: ["let a = 1", "let b = 2"]), font: font, theme: theme)
        let new = try #require(view.codeAccessibilityElements().last)
        new.setAccessibilitySelectedTextRange(NSRange(location: 4, length: 11))
        #expect(view.selectedText() == "a = 1\nlet b")
        #expect(new.accessibilitySelectedTextRange() == NSRange(location: 4, length: 11))
        #expect(new.accessibilitySelectedText() == "a = 1\nlet b")
    }

    @Test func accessibilityHitTestingReachesTheVisibleScroller() throws {
        let (view, window) = mountedRow(newLine: String(repeating: "w", count: 300))
        defer { window.close() }
        let scroller = view.scrollerForTesting(.new)
        #expect(!scroller.isHidden)
        let center = NSPoint(x: scroller.frame.midX, y: scroller.frame.midY)
        let screen = window.convertPoint(toScreen: view.convert(center, to: nil))
        #expect(!(view.accessibilityHitTest(screen) is CodeAccessibilityElement))
    }

    @Test(arguments: [DiffReviewInlineFeedbackSide.old, .new])
    func lineJumpsLandOnTheLineInsideTheHunk(side: DiffReviewInlineFeedbackSide) throws {
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.configure(result: result(old: ["a", "b", "c"], new: ["x", "y", "z"]), font: font, theme: theme)
        let center = try #require(view.scrollTargetCenterY(for: .init(side: side, line: 3)))
        #expect(center == DiffSplitCoreTextRowView.verticalInset + 2.5 * view.lineHeight)
    }

    @Test(arguments: [(CGFloat(0), 0), (19.5, 0), (20, 1), (49, 1), (90, 1), (-5, 0)])
    func offsetsMapToTheirRow(offset: CGFloat, row: Int) {
        #expect(DiffSplitCoreTextRowView.row(containing: offset, rowTops: [0, 20, 50]) == row)
    }

    private let expansionKey = DiffContextExpansionKey(groupID: "hunk-0", boundary: .above)

    /// A one-line change below a "20 unchanged lines above" expansion row.
    private func expandableSplit(font: NSFont? = nil, boundary: DiffContextBoundary = .above) -> DiffPaneTextDocumentBuilder.SplitResult {
        let diff = DiffParser.parse("@@ -21,1 +21,1 @@\n-a\n+b\n")
        var rows = DiffDisplayModelBuilder.build(diff: diff, filePath: "Sources/Example.swift").groups.flatMap(\.rows)
        rows.insert(DiffDisplayRow(
            id: "expand", kind: .expandableContext, old: nil, new: nil, collapsedLineCount: 20,
            contextExpansion: DiffContextExpansionRow(
                key: DiffContextExpansionKey(groupID: "hunk-0", boundary: boundary), boundary: boundary, remainingLineCount: 20
            )
        ), at: 0)
        return DiffPaneTextDocumentBuilder.buildSplit(rows: rows, fileExtension: "swift", font: font ?? self.font, showWhitespace: false, theme: theme)
    }

    @Test func scrollableWidthCoversAnExpansionRowsIndentAndPill() throws {
        let split = expandableSplit()
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.configure(result: split, font: font, theme: theme)
        let row = try #require(split.newCode.lines.first { !$0.contextExpansionActions.isEmpty })
        let text = split.newCode.attributedString.attributedSubstring(from: row.range)
        let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let indent = style?.firstLineHeadIndent ?? 0
        let glyphs = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil))
        #expect(view.widestLineWidth(side: .new) >= glyphs + indent + 12)
    }

    @Test func draggingDownTheGutterSelectsThoseLinesOnThatSide() throws {
        var selected: [DiffReviewLineAnchor] = []
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.configure(
            result: result(old: ["a", "b", "c"], new: ["x", "y", "z"]), font: font, theme: theme,
            review: .init(onSelect: { selected.append($0) })
        )
        let gutterX = DiffPaneSplitGeometry.frames(containerWidth: 800).newPane.minX + 5
        let rowY = { (row: Int) in DiffSplitCoreTextRowView.verticalInset + (CGFloat(row) + 0.5) * view.lineHeight }
        #expect(view.beginGutterSelection(at: NSPoint(x: gutterX, y: rowY(0))))
        view.extendGutterSelection(to: NSPoint(x: 10, y: rowY(2)))
        view.endGutterSelection()
        let anchor = try #require(selected.first)
        #expect(anchor.side == .new)
        #expect(anchor.line == 1)
        #expect(anchor.endLine == 3)
        #expect(view.gutterSelection == nil)
    }

    @Test func gutterSelectionNeedsTheGutterAndPermission() {
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        let lines = result(old: [], new: ["x", "y"])
        let y = DiffSplitCoreTextRowView.verticalInset + view.lineHeight / 2
        let newPane = DiffPaneSplitGeometry.frames(containerWidth: 800).newPane
        view.configure(result: lines, font: font, theme: theme)
        #expect(!view.beginGutterSelection(at: NSPoint(x: newPane.midX, y: y)))
        view.configure(result: lines, font: font, theme: theme, review: .init(allowsSelection: false))
        #expect(!view.beginGutterSelection(at: NSPoint(x: newPane.minX + 5, y: y)))
    }

    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
    func clickingAnExpansionRowExpandsIt(inGutter: Bool, optionKey: Bool) throws {
        var expanded: [(DiffContextExpansionKey, DiffContextExpansionMode)] = []
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 120))
        view.configure(result: expandableSplit(), font: font, theme: theme, onContextExpansion: { key, mode, _ in
            expanded.append((key, mode))
        })
        // Split rows put the expansion label in the old column.
        let oldPane = DiffPaneSplitGeometry.frames(containerWidth: 800).oldPane
        let rowY = DiffSplitCoreTextRowView.verticalInset + DiffPaneTextDocumentBuilder.expandableContextRowHeight(font: font) / 2
        let point = inGutter
            ? NSPoint(x: oldPane.minX + 5, y: rowY)
            : try #require((Int(oldPane.minX)..<Int(oldPane.maxX)).lazy.map { NSPoint(x: CGFloat($0), y: rowY) }.first { view.expansionTarget(at: $0) != nil })
        let flags: NSEvent.ModifierFlags = optionKey ? .option : []
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event)
        }
        #expect(expanded.count == 1)
        #expect(expanded.first?.0 == expansionKey)
        #expect(expanded.first?.1 == (optionKey ? .all : .chunk(size: 10)))
    }
}
