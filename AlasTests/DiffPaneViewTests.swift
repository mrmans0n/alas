import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct DiffPaneViewTests {
    private func theme() -> Theme { try! ThemeStore().current }

    private func model() -> DiffDisplayModel {
        DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,2 +1,2 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        .init(kind: .context, text: "let a = 1", oldNumber: 1, newNumber: 1),
                        .init(kind: .delete, text: "let b = 2", oldNumber: 2, newNumber: nil),
                        .init(kind: .add, text: "let b = 3", oldNumber: nil, newNumber: 2),
                    ]
                )
            ]),
            filePath: "a.swift"
        )
    }

    @Test func splitModeHostsRendererWithoutCrashing() {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view.subviews.isEmpty == false)
    }

    @Test func stackedModeHostsRendererWithoutCrashing() {
        var layout = DiffLayoutMode.stacked
        var wrap = true
        var whitespace = true
        let view = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view.subviews.isEmpty == false)
    }

    @Test func splitPaneUsesMergeStyleScrollPanesWithLineRulers() throws {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let splitScrollViews = allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextScrollView }
            .filter { !$0.isHidden }
        let allHaveRulers = splitScrollViews.allSatisfy { scrollView in
            scrollView.verticalRulerView is DiffPaneLineNumberRulerView
        }
        let allRulersVisible = splitScrollViews.allSatisfy { scrollView in
            scrollView.rulersVisible
        }
        let allHorizontallyScrollable = splitScrollViews.allSatisfy { scrollView in
            scrollView.hasHorizontalScroller
        }
        #expect(splitScrollViews.count == 2)
        #expect(allHaveRulers)
        #expect(allRulersVisible)
        #expect(allHorizontallyScrollable)

        let textViews = splitScrollViews.compactMap { $0.documentView as? NSTextView }
        let selectableTextViews = textViews.filter(\.isSelectable)

        #expect(selectableTextViews.count == 2)
        #expect(selectableTextViews.allSatisfy { !$0.isEditable })

        let selectableText = selectableTextViews.map(\.string).joined(separator: "\n")
        #expect(selectableText.contains("let b = 2"))
        #expect(selectableText.contains("let b = 3"))
        #expect(!selectableText.contains("|"))
        #expect(!selectableText.contains("+2"))
        #expect(!selectableText.contains("-2"))
    }

    @Test func splitPaneExposesDiffLineTonesForRailsAndPlaceholders() throws {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let codeViews = allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextScrollView }
            .filter { !$0.isHidden }
            .compactMap { $0.documentView as? DiffPaneCodeTextView }
        #expect(codeViews.count == 2)
        let tones = codeViews.flatMap(\.lineTones)
        #expect(tones.contains(.delete))
        #expect(tones.contains(.add))
        #expect(tones.contains(.context))
    }

    @Test func gutterRowsAlignWithCodeRowsInSplitPane() throws {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let splitScrollViews = allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextScrollView }
            .filter { !$0.isHidden }

        for scrollView in splitScrollViews {
            let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
            let ruler = try #require(scrollView.verticalRulerView as? DiffPaneLineNumberRulerView)
            let codeRows = codeView.diffRowRects()
            let rulerRows = ruler.diffRowRects()

            #expect(codeRows.count == rulerRows.count)
            for index in 0..<min(codeRows.count, rulerRows.count) {
                #expect(abs(codeRows[index].minY - rulerRows[index].minY) < 0.5)
                #expect(abs(codeRows[index].height - rulerRows[index].height) < 0.5)
            }
        }
    }

    @Test func diffLineToneClassifiesRailsAndEmptyCounterparts() {
        #expect(DiffPaneLineTone(label: "-12", rowKind: .delete) == .delete)
        #expect(DiffPaneLineTone(label: "+13", rowKind: .add) == .add)
        #expect(DiffPaneLineTone(label: "", rowKind: .add) == .placeholder)
        #expect(DiffPaneLineTone(label: "", rowKind: .collapsed) == .collapsed)
        #expect(DiffPaneLineTone(label: " 8", rowKind: .context) == .context)
    }

    @Test func splitDocumentBuildsSeparateCodeAndGutterColumns() throws {
        let result = DiffPaneTextDocumentBuilder.buildSplit(
            group: try #require(model().groups.first),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )

        #expect(result.oldCode.attributedString.string.components(separatedBy: "\n") == [
            "let a = 1",
            "let b = 2",
        ])
        #expect(result.newCode.attributedString.string.components(separatedBy: "\n") == [
            "let a = 1",
            "let b = 3",
        ])
        #expect(result.oldGutter.string.components(separatedBy: "\n") == [" 1", "-2"])
        #expect(result.newGutter.string.components(separatedBy: "\n") == [" 1", "+2"])
        #expect(!result.oldCode.attributedString.string.contains("|"))
        #expect(!result.newCode.attributedString.string.contains("|"))
        #expect(result.oldCode.lines.contains { $0.kind == .replacement })
        #expect(result.newCode.lines.contains { $0.kind == .replacement })
    }

    @Test func stackedDocumentBuildsCodeOnlyTextAndSeparateGutter() throws {
        let result = DiffPaneTextDocumentBuilder.buildStacked(
            group: try #require(model().groups.first),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )

        let rows = result.code.attributedString.string.components(separatedBy: "\n")
        #expect(rows == ["let a = 1", "let b = 2", "let b = 3"])
        #expect(result.gutter.string.components(separatedBy: "\n") == [" 1", "-2", "+2"])
        #expect(!result.code.attributedString.string.contains("|"))
        #expect(result.code.lines.contains { $0.kind == .replacement })
    }

    @Test func hunkActionsRenderInPaneHeader() {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in
                DiffPaneHunkActions(stage: {}, discard: {}, dropFromCommit: nil)
            }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        let buttons = allSubviews(of: controller.view).compactMap { $0 as? NSButton }
        let helpTexts = buttons.compactMap { $0.toolTip }
        #expect(helpTexts.contains("Stage hunk"))
        #expect(helpTexts.contains("Discard hunk"))
    }

    @Test func visibleWhitespacePreservesInlineBackgrounds() {
        let rendered = DiffCodeText.attributedString(
            text: "\tlet b = 3",
            fileExtension: "swift",
            codeFontFamily: "",
            codeFontSize: 13,
            showWhitespace: true,
            inlineSpans: [DiffInlineSpan(start: 9, length: 1)],
            inlineTone: .add,
            theme: theme()
        )

        #expect(rendered.string == "→let·b·=·3")
        #expect((rendered.string as NSString).length == ("\tlet b = 3" as NSString).length)
        #expect(rendered.attribute(.backgroundColor, at: 9, effectiveRange: nil) != nil)
    }

    @Test func stackedProjectionRendersContextRowsOnce() throws {
        let row = try #require(model().groups[0].rows.first)
        #expect(row.kind == .context)
        #expect(row.old?.text == row.new?.text)

        let lines = DiffPaneRowProjection.stackedLines(for: row)

        #expect(lines.map(\.text) == ["let a = 1"])
        #expect(lines.map(\.anchor.side) == [.paired])
    }

    @Test func contextSelectionSurvivesStackedProjection() throws {
        let row = try #require(model().groups[0].rows.first)
        let splitOldContextAnchor = try #require(row.old?.anchor)
        let stackedContextAnchor = try #require(DiffPaneRowProjection.stackedLines(for: row).first?.anchor)

        let selection = DiffSelectionRange(first: splitOldContextAnchor, last: splitOldContextAnchor)

        #expect(selection.contains(stackedContextAnchor))
    }

    @Test func selectionReducerExtendsRangeOnShiftClick() throws {
        let rows = model().groups[0].rows
        let firstAnchor = try #require(rows[0].new?.anchor)
        let lastAnchor = try #require(rows[1].new?.anchor)

        let firstSelection = DiffSelectionController.selection(
            current: nil,
            clicked: firstAnchor,
            extend: false
        )
        #expect(firstSelection.first == firstAnchor)
        #expect(firstSelection.last == firstAnchor)

        let extended = DiffSelectionController.selection(
            current: firstSelection,
            clicked: lastAnchor,
            extend: true
        )
        #expect(extended.first == firstAnchor)
        #expect(extended.last == lastAnchor)
        #expect(extended.normalized.contains(firstAnchor))
        #expect(extended.normalized.contains(lastAnchor))
    }

    @Test func diffLoadTokenInvalidatesOlderLoadForSameKey() {
        let key = "/repo\u{0}Sources/File.swift\u{0}false"
        let first = DiffLoadToken.next(key: key)
        var activeKey: String? = first.key
        var activeID = first.id

        #expect(first.isActive(activeKey: activeKey, activeID: activeID))

        let second = DiffLoadToken.next(key: key)
        activeKey = second.key
        activeID = second.id

        #expect(!first.isActive(activeKey: activeKey, activeID: activeID))
        #expect(second.isActive(activeKey: activeKey, activeID: activeID))
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }
}
