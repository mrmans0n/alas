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
}
