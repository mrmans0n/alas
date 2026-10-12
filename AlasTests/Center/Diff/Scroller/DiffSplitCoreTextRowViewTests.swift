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

    @Test func heightIsOneLinePerRowPlusInsets() {
        let view = DiffSplitCoreTextRowView(frame: .zero)
        view.configure(result: result(old: ["a", "b", "c"], new: ["x", "y", "z"]), font: font, theme: theme)
        #expect(view.measuredHeight(forWidth: 800) == 3 * view.lineHeight + 2 * DiffSplitCoreTextRowView.verticalInset)
    }

    @Test func visibleRangeIncludesPartiallyCoveredLines() {
        let view = DiffSplitCoreTextRowView(frame: .zero)
        view.configure(result: result(old: [], new: (0..<10).map { "let v\($0) = \($0)" }), font: font, theme: theme)
        let top = DiffSplitCoreTextRowView.verticalInset
        let rect = NSRect(x: 0, y: top + view.lineHeight * 2.5, width: 800, height: view.lineHeight)
        #expect(view.visibleLineRange(in: rect) == 2..<4)
    }

    @Test(arguments: ["\t😀漢", String(repeating: "w", count: 400)])
    func widestLineUsesTypographicWidth(line: String) {
        let view = DiffSplitCoreTextRowView(frame: .zero)
        view.configure(result: result(old: [], new: [line]), font: font, theme: theme)
        let measured = CTLineGetTypographicBounds(
            CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font])), nil, nil, nil
        )
        #expect(view.widestLineWidth(side: .new) >= measured - 1)
        #expect(view.cachedLineStringForTesting(side: .new, line: 0)?.contains(line.suffix(3)) == true)
    }

    @Test func pureAdditionLeavesTheOldSideBlankButMeasurable() {
        let view = DiffSplitCoreTextRowView(frame: .zero)
        view.configure(result: result(old: [], new: ["let a = 1", "let b = 2"]), font: font, theme: theme)
        #expect(view.cachedLineStringForTesting(side: .old, line: 0)?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        #expect(view.measuredHeight(forWidth: 800) > 0)
    }

    @Test func reconfiguringReplacesCachedLines() {
        let view = DiffSplitCoreTextRowView(frame: .zero)
        view.configure(result: result(old: [], new: ["before"]), font: font, theme: theme)
        view.configure(result: result(old: [], new: ["after"]), font: font, theme: theme)
        #expect(view.cachedLineStringForTesting(side: .new, line: 0) == "after")
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

    @Test(arguments: [(CGFloat(3), true, CGFloat(3)), (3, false, 48)])
    func wheelDeltasBecomePoints(delta: CGFloat, precise: Bool, expected: CGFloat) {
        #expect(DiffSplitHorizontalScroll.pointDelta(scrollingDeltaX: delta, isPrecise: precise, lineHeight: 16) == expected)
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

    @Test func diagonalMostlyVerticalScrollIsNotHandled() {
        let (view, window) = mountedRow(newLine: String(repeating: "w", count: 300))
        defer { window.close() }
        let handled = view.scroll(deltaX: -10, deltaY: -40, isPrecise: true, at: NSPoint(x: 900, y: 20))
        #expect(!handled)
        #expect(view.horizontalScroll.offset(.new) == 0)
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

    @Test func newContentResetsBothSidesToTheLeadingEdge() {
        let (view, window) = mountedRow(newLine: String(repeating: "w", count: 300))
        defer { window.close() }
        _ = view.scroll(deltaX: -40, deltaY: 0, isPrecise: true, at: NSPoint(x: 900, y: 20))
        view.configure(result: result(old: [], new: [String(repeating: "v", count: 300)]), font: font, theme: theme)
        #expect(view.horizontalScroll.offset(.new) == 0)
        #expect(view.horizontalScroll.offset(.old) == 0)
    }

    @Test func pointsLeftOfTheDividerBelongToTheOldSide() {
        let (view, window) = mountedRow(newLine: "x")
        defer { window.close() }
        #expect(view.side(at: NSPoint(x: 100, y: 10)) == .old)
        #expect(view.side(at: NSPoint(x: 900, y: 10)) == .new)
    }

    @Test func scrollerTracksTheOffsetAndHidesWhenContentFits() {
        let (view, window) = mountedRow(newLine: String(repeating: "w", count: 300))
        defer { window.close() }
        #expect(view.scrollerForTesting(.old).isHidden)
        #expect(!view.scrollerForTesting(.new).isHidden)
        _ = view.scroll(deltaX: -40, deltaY: 0, isPrecise: true, at: NSPoint(x: 900, y: 20))
        let expected = Double(40 / view.horizontalScroll.maxOffset(.new))
        #expect(abs(view.scrollerForTesting(.new).doubleValue - expected) < 0.001)
    }

    @Test func draggingTheScrollerMovesTheOffset() {
        let (view, window) = mountedRow(newLine: String(repeating: "w", count: 300))
        defer { window.close() }
        let scroller = view.scrollerForTesting(.new)
        scroller.doubleValue = 0.5
        _ = scroller.sendAction(scroller.action, to: scroller.target)
        #expect(abs(view.horizontalScroll.offset(.new) - view.horizontalScroll.maxOffset(.new) / 2) < 1)
    }

    @Test func lineHeightMatchesTheTextKitPanes() {
        let storage = NSTextStorage(string: "a\nb", attributes: [.font: font, .paragraphStyle: CenterTypography.paragraphStyle()])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 500, height: 1_000))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        let pitch = layoutManager.lineFragmentRect(forGlyphAt: 2, effectiveRange: nil).minY
            - layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY

        let view = DiffSplitCoreTextRowView(frame: .zero)
        view.configure(result: result(old: [], new: ["x"]), font: font, theme: theme)
        #expect(view.lineHeight == pitch)
    }

    @Test func headerAddsItsHeightAndPushesTheCodeDown() {
        let plain = DiffSplitCoreTextRowView(frame: .zero)
        plain.configure(result: result(old: [], new: ["a", "b"]), font: font, theme: theme)
        let headed = DiffSplitCoreTextRowView(frame: .zero)
        headed.configure(
            result: result(old: [], new: ["a", "b"]), font: font, theme: theme,
            chrome: .init(header: "@@ -0,0 +1,2 @@", headerFont: font, fusion: .none)
        )
        #expect(headed.headerHeight > 0)
        #expect(headed.measuredHeight(forWidth: 800) == plain.measuredHeight(forWidth: 800) + headed.headerHeight + DiffPaneHunkFusionState.none.bottomPadding)
        let firstLineTop = headed.headerHeight + DiffSplitCoreTextRowView.verticalInset
        #expect(headed.visibleLineRange(in: NSRect(x: 0, y: 0, width: 800, height: firstLineTop)).isEmpty)
    }

    @Test func gutterWidensWithLineNumbersLikeTheRuler() {
        let diff = DiffParser.parse("@@ -100000,1 +100000,1 @@\n-a\n+b\n")
        let rows = DiffDisplayModelBuilder.build(diff: diff, filePath: "Sources/Example.swift").groups.flatMap(\.rows)
        let split = DiffPaneTextDocumentBuilder.buildSplit(rows: rows, fileExtension: "swift", font: font, showWhitespace: false, theme: theme)
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        view.configure(result: split, font: font, theme: theme)
        view.layout()
        let gutter = DiffPaneLineNumberGutterGeometry.thickness(labels: split.newGutter.string.components(separatedBy: "\n"))
        #expect(gutter > DiffPaneLineNumberGutterGeometry.minimumThickness)
        let pane = DiffPaneSplitGeometry.frames(containerWidth: 800).newPane
        #expect(view.horizontalScroll.newViewportWidth == pane.width - gutter)
    }

    @Test func stackedHunksUseOneFullWidthPane() {
        let diff = DiffParser.parse("@@ -1,1 +1,1 @@\n-" + String(repeating: "w", count: 400) + "\n+b\n")
        let rows = DiffDisplayModelBuilder.build(diff: diff, filePath: "Sources/Example.swift").groups.flatMap(\.rows)
        let stacked = DiffPaneTextDocumentBuilder.buildStacked(rows: rows, fileExtension: "swift", font: font, showWhitespace: false, theme: theme)
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        view.configure(stacked: stacked, font: font, theme: theme)
        view.layout()
        let gutter = DiffPaneLineNumberGutterGeometry.thickness(labels: stacked.gutter.string.components(separatedBy: "\n"))
        #expect(view.measuredHeight(forWidth: 800) == 2 * view.lineHeight + 2 * DiffSplitCoreTextRowView.verticalInset)
        #expect(view.horizontalScroll.newViewportWidth == 800 - gutter)
        #expect(view.side(at: NSPoint(x: 10, y: 20)) == .new)
        #expect(view.scrollerForTesting(.old).isHidden)
        #expect(!view.scrollerForTesting(.new).isHidden)
    }

    @Test(arguments: [
        ([10, 30], [20, 10], [0, 20, 50]),
        ([], [10, 20], [0, 10, 30]),
        ([0], [0], [0, 10]),
    ] as [([CGFloat], [CGFloat], [CGFloat])])
    func rowsAreAsTallAsTheirTallerSide(old: [CGFloat], new: [CGFloat], expected: [CGFloat]) {
        #expect(DiffSplitCoreTextRowView.rowTops(oldHeights: old, newHeights: new, minimum: 10) == expected)
    }

    @Test(arguments: [(CGFloat(0), 0), (19.5, 0), (20, 1), (49, 1), (90, 1), (-5, 0)])
    func offsetsMapToTheirRow(offset: CGFloat, row: Int) {
        #expect(DiffSplitCoreTextRowView.row(containing: offset, rowTops: [0, 20, 50]) == row)
    }

    @Test func expansionRowsAreAsTallAsTheirTextKitRow() {
        let diff = DiffParser.parse("@@ -1,1 +1,1 @@\n-a\n+b\n")
        var rows = DiffDisplayModelBuilder.build(diff: diff, filePath: "Sources/Example.swift").groups.flatMap(\.rows)
        let key = DiffContextExpansionKey(groupID: "hunk-0", boundary: .above)
        rows.insert(DiffDisplayRow(
            id: "expand", kind: .expandableContext, old: nil, new: nil, collapsedLineCount: 20,
            contextExpansion: DiffContextExpansionRow(key: key, boundary: .above, remainingLineCount: 20)
        ), at: 0)
        let split = DiffPaneTextDocumentBuilder.buildSplit(rows: rows, fileExtension: "swift", font: font, showWhitespace: false, theme: theme)
        let view = DiffSplitCoreTextRowView(frame: .zero)
        view.configure(result: split, font: font, theme: theme)
        let expansion = DiffPaneTextDocumentBuilder.expandableContextRowHeight(font: font)
        #expect(expansion > view.lineHeight)
        #expect(view.measuredHeight(forWidth: 800) == expansion + view.lineHeight + 2 * DiffSplitCoreTextRowView.verticalInset)
    }

    @Test func wrappingGrowsTheRowInsteadOfScrollingSideways() {
        let long = (0..<60).map { "word\($0)" }.joined(separator: " ")
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        view.configure(result: result(old: ["short"], new: [long]), font: font, theme: theme, wraps: true)
        view.layout()
        #expect(view.measuredHeight(forWidth: 600) >= 3 * view.lineHeight + 2 * DiffSplitCoreTextRowView.verticalInset)
        #expect(view.measuredHeight(forWidth: 600) > view.measuredHeight(forWidth: 1_800))
        #expect(view.scrollerForTesting(.new).isHidden)
        let wholeRow = NSRect(x: 0, y: 0, width: 600, height: view.measuredHeight(forWidth: 600))
        #expect(view.visibleLineRange(in: wholeRow) == 0..<1)
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

    @Test func headerButtonsRunTheirActions() {
        var pressed: [String] = []
        let view = DiffSplitCoreTextRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.configure(
            result: result(old: [], new: ["a"]), font: font, theme: theme,
            chrome: .init(header: "@@", headerFont: font, fusion: .none, actions: [
                .init(symbol: "plus.square", tooltip: "Stage hunk") { pressed.append("stage") },
                .init(symbol: "trash", tooltip: "Discard hunk") { pressed.append("discard") },
            ])
        )
        let buttons = view.headerButtonsForTesting()
        #expect(buttons.map(\.toolTip) == ["Stage hunk", "Discard hunk"])
        buttons[1].performClick(nil)
        #expect(pressed == ["discard"])
    }
}
