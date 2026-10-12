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
}
