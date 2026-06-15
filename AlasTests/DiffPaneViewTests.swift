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

    private func reviewAnchorModel() -> DiffDisplayModel {
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
            filePath: "Sources/App.swift"
        )
    }

    private func collapsedContextModel() -> DiffDisplayModel {
        DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,15 +1,15 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: (1...15).map {
                        .init(kind: .context, text: "let value\($0) = \($0)", oldNumber: $0, newNumber: $0)
                    }
                )
            ]),
            filePath: "a.swift"
        )
    }

    private func expandableContextGroup(
        boundary: DiffContextBoundary,
        collapsedLineCount: Int
    ) -> DiffDisplayGroup {
        let groupID = "hunk-0"
        return DiffDisplayGroup(
            id: groupID,
            header: "@@ -2,1 +2,1 @@",
            sourceHunk: ParsedDiff.Hunk(
                header: "@@ -2,1 +2,1 @@",
                oldStart: 2,
                newStart: 2,
                lines: []
            ),
            rows: [
                DiffDisplayRow(
                    id: "expand-\(boundary.rawValue)",
                    kind: .expandableContext,
                    old: nil,
                    new: nil,
                    collapsedLineCount: collapsedLineCount,
                    contextExpansion: DiffContextExpansionRow(
                        key: DiffContextExpansionKey(groupID: groupID, boundary: boundary),
                        boundary: boundary,
                        remainingLineCount: collapsedLineCount
                    )
                ),
            ]
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

    @Test func defaultModeShowsDiffToolbar() {
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

        #expect(subview(withAccessibilityIdentifier: "diff-pane-toolbar", in: controller.view) != nil)
    }

    @Test func embeddedModeHidesDiffToolbar() {
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
            showsToolbar: false,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "diff-pane-toolbar", in: controller.view) == nil)
    }

    @Test func embeddedStaticModeDoesNotCreateOuterVerticalScrollView() {
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
            showsToolbar: false,
            verticalScrollMode: .staticHeight,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let outerScrollViews = allSubviews(of: controller.view)
            .compactMap { $0 as? NSScrollView }
            .filter { !($0 is DiffPaneTextScrollView) }
        #expect(outerScrollViews.isEmpty)
        #expect(allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })
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
            .filter(isEffectivelyVisible)
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

    @Test @MainActor func splitTextDocumentExposesSourceLineMetadataForBothSides() throws {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: reviewAnchorModel(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsToolbar: false,
            verticalScrollMode: .staticHeight,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let codeViews = visibleCodeTextViews(in: controller.view)
        #expect(codeViews.count == 2)
        let oldCodeView = try #require(codeViews.first)
        let newCodeView = try #require(codeViews.last)

        #expect(oldCodeView.reviewLineAnchor(atRow: 0)?.side == .old)
        #expect(newCodeView.reviewLineAnchor(atRow: 0)?.side == .new)

        let changedAnchor = try #require(newCodeView.reviewLineAnchor(atRow: 1))
        #expect(changedAnchor.path == "Sources/App.swift")
        #expect(changedAnchor.side == .new)
        #expect(changedAnchor.line == 2)
        #expect(changedAnchor.rowIndex == 1)
        #expect(changedAnchor.selectedText == "let b = 3")
    }

    @Test @MainActor func stackedTextDocumentExposesSourceLineMetadataForAddedAndDeletedLines() throws {
        let view = DiffPaneTextDocumentView(
            group: try #require(reviewAnchorModel().groups.first),
            expandedCollapsedRowIDs: [],
            layoutMode: .stacked,
            wrapLines: false,
            showWhitespace: false,
            fileExtension: "swift",
            codeFontFamily: "",
            codeFontSize: 13,
            theme: theme(),
            lspContext: nil
        )

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let codeView = try #require(visibleCodeTextViews(in: controller.view).first)
        let deletedAnchor = try #require(codeView.reviewLineAnchor(atRow: 1))
        let addedAnchor = try #require(codeView.reviewLineAnchor(atRow: 2))

        #expect(deletedAnchor.path == "Sources/App.swift")
        #expect(deletedAnchor.side == .old)
        #expect(deletedAnchor.line == 2)
        #expect(deletedAnchor.rowIndex == 1)
        #expect(deletedAnchor.selectedText == "let b = 2")

        #expect(addedAnchor.path == "Sources/App.swift")
        #expect(addedAnchor.side == .new)
        #expect(addedAnchor.line == 2)
        #expect(addedAnchor.rowIndex == 2)
        #expect(addedAnchor.selectedText == "let b = 3")
    }

    @Test @MainActor func rowHitTestingReturnsLocalReviewAnchorForCodePoint() throws {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: reviewAnchorModel(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsToolbar: false,
            verticalScrollMode: .staticHeight,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let newCodeView = try #require(visibleCodeTextViews(in: controller.view).last)
        let changedRowRect = try #require(newCodeView.diffRowRects().dropFirst().first)
        let point = NSPoint(x: changedRowRect.minX + 8, y: changedRowRect.midY)

        let anchor = try #require(newCodeView.reviewLineAnchor(at: point))
        #expect(anchor.path == "Sources/App.swift")
        #expect(anchor.line == 2)
        #expect(anchor.side == .new)
        #expect(anchor.rowIndex == 1)
        #expect(anchor.selectedText == "let b = 3")
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
            .filter(isEffectivelyVisible)
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
            .filter(isEffectivelyVisible)

        for scrollView in splitScrollViews {
            let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
            let ruler = try #require(scrollView.verticalRulerView as? DiffPaneLineNumberRulerView)
            let codeRows = codeView.diffRowRects()
            let rulerRows = ruler.diffRowRects()
            let codeFirstLineRects = codeView.diffFirstLineFragmentRects()
            let rulerLabelRects = ruler.labelDrawRects()

            #expect(codeRows.count == rulerRows.count)
            for index in 0..<min(codeRows.count, rulerRows.count) {
                #expect(abs(codeRows[index].minY - rulerRows[index].minY) < 0.5)
                #expect(abs(codeRows[index].height - rulerRows[index].height) < 0.5)
            }
            #expect(codeFirstLineRects.count == rulerLabelRects.count)
            for index in 0..<min(codeFirstLineRects.count, rulerLabelRects.count) {
                let codeCenter = codeFirstLineRects[index].midY
                let labelCenter = rulerLabelRects[index].midY
                #expect(abs(codeCenter - labelCenter) < 0.75)
            }
        }
    }

    @Test func diffTextScrollPanesUseLeadingClipViewsAndStartScrolledLeft() throws {
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
        controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let scrollViews = allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextScrollView }
            .filter(isEffectivelyVisible)
        #expect(scrollViews.isEmpty == false)
        for scrollView in scrollViews {
            #expect(scrollView.contentView is DiffPaneLeadingClipView)
            #expect(abs(scrollView.contentView.bounds.origin.x) < 0.5)
        }
    }

    @Test func diffTextScrollPaneResetsHorizontalOriginWhenLaidOutForInitialDisplay() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let text = "let value = \"This line is intentionally long enough to make the inner pane horizontally scrollable.\""
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: text,
                attributes: [.font: font]
            ),
            lines: [.init(kind: .context, range: NSRange(location: 0, length: (text as NSString).length))]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))

        scrollView.update(
            document: document,
            lineLabels: [" 1"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 120, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(scrollView.contentView.bounds.origin.x > 0)

        scrollView.resetHorizontalOriginToLeading()

        #expect(scrollView.contentView.bounds.origin.x == 0)

        scrollView.contentView.scroll(to: NSPoint(x: 120, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(scrollView.contentView.bounds.origin.x > 0)

        scrollView.update(
            document: document,
            lineLabels: [" 1"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )

        #expect(scrollView.contentView.bounds.origin.x == 0)

        scrollView.contentView.scroll(to: NSPoint(x: 120, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(scrollView.contentView.bounds.origin.x > 0)

        scrollView.layoutSubtreeIfNeeded()

        #expect(scrollView.contentView.bounds.origin.x == 0)
    }

    @Test func lineNumberRulerKeepsRowsVisibleAfterHorizontalScroll() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let text = "let value = \"This line is intentionally long enough to make the inner pane horizontally scrollable.\""
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: text,
                attributes: [.font: font]
            ),
            lines: [.init(kind: .add, range: NSRange(location: 0, length: (text as NSString).length))]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))

        scrollView.update(
            document: document,
            lineLabels: ["56"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        scrollView.contentView.scroll(to: NSPoint(x: 120, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let ruler = try #require(scrollView.verticalRulerView as? DiffPaneLineNumberRulerView)
        #expect(scrollView.contentView.bounds.origin.x > 0)
        #expect(ruler.visibleRowIndices(in: scrollView.contentView.bounds) == [0])
    }

    @Test func wrappedDiffTextScrollPaneDoesNotAllowHorizontalOffset() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let text = "let value = \"This line is intentionally long enough to wrap instead of creating an inner horizontal scroll range.\""
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: text,
                attributes: [.font: font]
            ),
            lines: [.init(kind: .context, range: NSRange(location: 0, length: (text as NSString).length))]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))

        scrollView.update(
            document: document,
            lineLabels: [" 1"],
            wraps: true,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        scrollView.contentView.scroll(to: NSPoint(x: 120, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        #expect(scrollView.hasHorizontalScroller == false)
        #expect(abs(scrollView.contentView.bounds.origin.x) < 0.5)
        #expect(abs(scrollView.documentView!.frame.width - scrollView.contentView.bounds.width) < 0.5)
    }

    @Test func wrappedDiffTextKeepsContinuationGlyphsVisible() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let text = "        guard currentConfigOptions.first(where: { $0.id == configId })?.currentValue == selectedValue else {"
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: text,
                attributes: [.font: font]
            ),
            lines: [.init(kind: .add, range: NSRange(location: 0, length: (text as NSString).length))]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: 120))

        scrollView.update(
            document: document,
            lineLabels: ["+56"],
            wraps: true,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        let layoutManager = try #require(codeView.layoutManager)
        let textContainer = try #require(codeView.textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let configRange = (text as NSString).range(of: "configId")
        let glyphRange = layoutManager.glyphRange(forCharacterRange: configRange, actualCharacterRange: nil)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            .offsetBy(dx: codeView.textContainerOrigin.x, dy: codeView.textContainerOrigin.y)
        let visibleCodeRect = codeView.visibleRect.insetBy(dx: codeView.textContainerInset.width, dy: 0)

        #expect(glyphRect.minX >= visibleCodeRect.minX - 0.5)
        #expect(glyphRect.maxX <= visibleCodeRect.maxX + 0.5)
    }

    @Test func wrappedDiffTextPaneKeepsCodeViewportAfterLineRuler() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let text = "struct ACPConfigOptionItem: Codable, Equatable, Identifiable {"
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: text,
                attributes: [.font: font]
            ),
            lines: [.init(kind: .context, range: NSRange(location: 0, length: (text as NSString).length))]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: 120))

        scrollView.update(
            document: document,
            lineLabels: ["73"],
            wraps: true,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        let rulerWidth = try #require(scrollView.verticalRulerView?.ruleThickness)
        #expect(scrollView.contentView.frame.minX >= rulerWidth - 0.5)
    }

    @Test func diffPreferenceBindingsPersistChanges() {
        let appState = AppState()
        appState.config.changes.diffLayoutMode = .split
        appState.config.changes.diffWrapLines = false
        appState.config.changes.diffShowWhitespace = false

        let bindings = DiffPreferenceBindings(appState: appState)
        bindings.layoutMode.wrappedValue = .stacked
        bindings.wrapLines.wrappedValue = true
        bindings.showWhitespace.wrappedValue = true

        #expect(appState.config.changes.diffLayoutMode == .stacked)
        #expect(appState.config.changes.diffWrapLines == true)
        #expect(appState.config.changes.diffShowWhitespace == true)
    }

    @Test func collapsedContextControllerTogglesHiddenRows() throws {
        let group = try #require(collapsedContextModel().groups.first)
        let collapsedIDs = DiffCollapsedContextController.collapsedRowIDs(in: group)
        #expect(collapsedIDs.isEmpty == false)

        let expandedIDs = DiffCollapsedContextController.toggled(group, expandedIDs: [])
        #expect(collapsedIDs.isSubset(of: expandedIDs))
        #expect(DiffCollapsedContextController.isExpanded(group, expandedIDs: expandedIDs))
        #expect(DiffPaneRowProjection.visibleRows(in: group, expandedCollapsedRowIDs: expandedIDs).count > group.rows.count)

        let collapsedAgain = DiffCollapsedContextController.toggled(group, expandedIDs: expandedIDs)
        #expect(collapsedAgain.intersection(collapsedIDs).isEmpty)
    }

    @Test func collapsedContextControlRendersInPaneHeader() {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: collapsedContextModel(),
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

        let buttons = allSubviews(of: controller.view).compactMap { $0 as? NSButton }
        let helpTexts = buttons.compactMap { $0.toolTip }
        #expect(helpTexts.contains("Expand context"))
    }

    @Test func leadingEmptyCounterpartRowsAlignWithCodeRowsInSplitPane() throws {
        let model = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,1 +1,2 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        .init(kind: .add, text: "let inserted = true", oldNumber: nil, newNumber: 1),
                        .init(kind: .context, text: "let c = 3", oldNumber: 1, newNumber: 2),
                    ]
                )
            ]),
            filePath: "a.swift"
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: model,
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
            .filter(isEffectivelyVisible)
            .sorted { $0.frame.minX < $1.frame.minX }
        #expect(splitScrollViews.count == 2)

        let oldCodeView = try #require(splitScrollViews.first?.documentView as? DiffPaneCodeTextView)
        let newCodeView = try #require(splitScrollViews.last?.documentView as? DiffPaneCodeTextView)
        let oldRows = oldCodeView.diffRowRects()
        let newRows = newCodeView.diffRowRects()
        #expect(oldRows.count == newRows.count)
        #expect(oldRows.count >= 2)
        #expect(abs(oldRows[0].minY - oldCodeView.textContainerInset.height) < 0.5)
        #expect(abs(newRows[0].minY - newCodeView.textContainerInset.height) < 0.5)
        #expect(abs(oldRows[0].minY - newRows[0].minY) < 0.5)
        #expect(abs(oldRows[0].height - newRows[0].height) < 0.5)
        #expect(abs(oldRows[1].minY - newRows[1].minY) < 0.5)
    }

    @Test func wrappedEmptyCounterpartRowsReserveCounterpartHeightInSplitPane() throws {
        let model = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,1 +1,4 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        .init(
                            kind: .add,
                            text: "let inserted = \"This is intentionally long enough to wrap inside the split pane so the empty old-side counterpart has to reserve more than one visual line of height.\"",
                            oldNumber: nil,
                            newNumber: 1
                        ),
                        .init(kind: .add, text: "let second = true", oldNumber: nil, newNumber: 2),
                        .init(kind: .add, text: "let third = true", oldNumber: nil, newNumber: 3),
                        .init(kind: .context, text: "let c = 3", oldNumber: 1, newNumber: 4),
                    ]
                )
            ]),
            filePath: "a.swift"
        )
        var layout = DiffLayoutMode.split
        var wrap = true
        var whitespace = false
        let view = DiffPaneView(
            model: model,
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
        controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let splitScrollViews = allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextScrollView }
            .filter(isEffectivelyVisible)
            .sorted { $0.frame.minX < $1.frame.minX }
        #expect(splitScrollViews.count == 2)

        let oldCodeView = try #require(splitScrollViews.first?.documentView as? DiffPaneCodeTextView)
        let newCodeView = try #require(splitScrollViews.last?.documentView as? DiffPaneCodeTextView)
        let oldRows = oldCodeView.diffRowRects()
        let newRows = newCodeView.diffRowRects()

        #expect(oldRows.count == newRows.count)
        #expect(oldRows.count >= 4)
        #expect(abs(oldRows[0].minY - oldCodeView.textContainerInset.height) < 0.5)
        #expect(abs(newRows[0].minY - newCodeView.textContainerInset.height) < 0.5)
        for index in oldRows.indices {
            #expect(abs(oldRows[index].minY - newRows[index].minY) < 0.5)
            #expect(abs(oldRows[index].height - newRows[index].height) < 0.5)
            if index > 0 {
                #expect(oldRows[index].minY >= oldRows[index - 1].maxY - 0.5)
                #expect(newRows[index].minY >= newRows[index - 1].maxY - 0.5)
            }
        }
    }

    @Test func diffLineToneClassifiesRailsAndEmptyCounterparts() {
        #expect(DiffPaneLineTone(label: "12", rowKind: .delete) == .delete)
        #expect(DiffPaneLineTone(label: "13", rowKind: .add) == .add)
        #expect(DiffPaneLineTone(label: "", rowKind: .add) == .placeholder)
        #expect(DiffPaneLineTone(label: "", rowKind: .collapsed) == .collapsed)
        #expect(DiffPaneLineTone(label: "8", rowKind: .context) == .context)
    }

    @Test func placeholderHatchIsInsetInsideRowRect() {
        let rowRect = NSRect(x: 0, y: 8, width: 240, height: 22)
        let hatchRect = DiffPaneCodeTextView.placeholderHatchRect(in: rowRect)

        #expect(hatchRect.minY > rowRect.minY)
        #expect(hatchRect.maxY < rowRect.maxY)
        #expect(hatchRect.minX == rowRect.minX)
        #expect(hatchRect.maxX == rowRect.maxX)
    }

    @Test func changeRailsRenderOnlyInLineNumberRuler() {
        let rowRect = NSRect(x: 0, y: 10, width: 120, height: 24)

        #expect(DiffPaneLineNumberRulerView.changeRailRect(in: rowRect, tone: .add) == NSRect(x: 0, y: 10, width: 3, height: 24))
        #expect(DiffPaneLineNumberRulerView.changeRailRect(in: rowRect, tone: .delete) == NSRect(x: 0, y: 10, width: 3, height: 24))
        #expect(DiffPaneLineNumberRulerView.changeRailRect(in: rowRect, tone: .context) == nil)

        #expect(DiffPaneCodeTextView.changeRailRect(in: rowRect, tone: .add) == nil)
        #expect(DiffPaneCodeTextView.changeRailRect(in: rowRect, tone: .delete) == nil)
    }

    @Test func lineNumberRulerColorsExpandableContextPlusAsBoundaryControl() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: "9 unchanged lines above",
                attributes: [.font: font]
            ),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(
                    kind: .expandableContext,
                    range: NSRange(location: 0, length: 23),
                    expansionKey: DiffContextExpansionKey(groupID: "hunk-0", boundary: .above),
                    expansionBoundary: .above
                ),
            ]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        scrollView.update(
            document: document,
            lineLabels: ["+"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .old
        )

        let ruler = try #require(scrollView.verticalRulerView as? DiffPaneLineNumberRulerView)
        let color = try #require(ruler.labelAttributesForTesting(row: 0)[.foregroundColor] as? NSColor)

        #expect(color == NSColor(theme.color("fg-faint")))
        #expect(color != NSColor(theme.color("add")))
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
        #expect(result.oldGutter.string.components(separatedBy: "\n") == ["1", "2"])
        #expect(result.newGutter.string.components(separatedBy: "\n") == ["1", "2"])
        #expect(!result.oldCode.attributedString.string.contains("|"))
        #expect(!result.newCode.attributedString.string.contains("|"))
        #expect(result.oldCode.lines.contains { $0.kind == .replacement })
        #expect(result.newCode.lines.contains { $0.kind == .replacement })
    }

    @Test func splitDocumentRendersExpandableContextBoundaryRows() throws {
        let result = DiffPaneTextDocumentBuilder.buildSplit(
            group: expandableContextGroup(boundary: .above, collapsedLineCount: 9),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )
        let key = DiffContextExpansionKey(groupID: "hunk-0", boundary: .above)

        #expect(result.oldGutter.string.components(separatedBy: "\n") == ["+"])
        #expect(result.newGutter.string.components(separatedBy: "\n") == [""])
        #expect(result.oldCode.attributedString.string.components(separatedBy: "\n") == ["9 unchanged lines above"])
        #expect(result.newCode.attributedString.string.components(separatedBy: "\n") == [" "])
        #expect(result.oldCode.lines.count == result.oldGutter.string.components(separatedBy: "\n").count)
        #expect(result.newCode.lines.count == result.newGutter.string.components(separatedBy: "\n").count)
        #expect(result.oldCode.lines.first?.expansionKey == key)
        #expect(result.oldCode.lines.first?.expansionBoundary == .above)
        #expect(result.newCode.lines.first?.expansionKey == key)
        #expect(result.newCode.lines.first?.expansionBoundary == .above)
    }

    @Test func stackedDocumentRendersExpandableContextBoundaryRows() throws {
        let result = DiffPaneTextDocumentBuilder.buildStacked(
            group: expandableContextGroup(boundary: .below, collapsedLineCount: 7),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )

        #expect(result.gutter.string.components(separatedBy: "\n") == ["+"])
        #expect(result.code.attributedString.string.components(separatedBy: "\n") == ["7 unchanged lines below"])
        #expect(result.code.lines.count == result.gutter.string.components(separatedBy: "\n").count)
        #expect(result.code.lines.first?.expansionKey == DiffContextExpansionKey(groupID: "hunk-0", boundary: .below))
        #expect(result.code.lines.first?.expansionBoundary == .below)
    }

    @Test func singleDocumentPreservesExpandableContextMetadata() throws {
        let result = DiffPaneTextDocumentBuilder.build(
            group: expandableContextGroup(boundary: .above, collapsedLineCount: 0),
            expandedCollapsedRowIDs: [],
            layoutMode: .split,
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )

        #expect(result.attributedString.string.contains("Expand context above"))
        #expect(result.lines.first?.expansionKey == DiffContextExpansionKey(groupID: "hunk-0", boundary: .above))
        #expect(result.lines.first?.expansionBoundary == .above)
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
        #expect(result.gutter.string.components(separatedBy: "\n") == ["1", "2", "2"])
        #expect(!result.code.attributedString.string.contains("|"))
        #expect(result.code.lines.contains { $0.kind == .replacement })
    }

    @Test func stackedDocumentGroupsConsecutiveReplacementBlocksBySide() throws {
        let model = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,4 +1,4 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        .init(kind: .context, text: "before", oldNumber: 1, newNumber: 1),
                        .init(kind: .delete, text: "old one", oldNumber: 2, newNumber: nil),
                        .init(kind: .delete, text: "old two", oldNumber: 3, newNumber: nil),
                        .init(kind: .add, text: "new one", oldNumber: nil, newNumber: 2),
                        .init(kind: .add, text: "new two", oldNumber: nil, newNumber: 3),
                        .init(kind: .context, text: "after", oldNumber: 4, newNumber: 4),
                    ]
                )
            ]),
            filePath: "a.swift"
        )
        let result = DiffPaneTextDocumentBuilder.buildStacked(
            group: try #require(model.groups.first),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )

        #expect(result.code.attributedString.string.components(separatedBy: "\n") == [
            "before",
            "old one",
            "old two",
            "new one",
            "new two",
            "after",
        ])
        #expect(result.gutter.string.components(separatedBy: "\n") == ["1", "2", "3", "2", "3", "4"])
    }

    @Test func stackedDocumentKeepsExtraDeletedLinesWithDeleteBlock() throws {
        let model = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,4 +1,3 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        .init(kind: .context, text: "before", oldNumber: 1, newNumber: 1),
                        .init(kind: .delete, text: "old one", oldNumber: 2, newNumber: nil),
                        .init(kind: .delete, text: "old two", oldNumber: 3, newNumber: nil),
                        .init(kind: .add, text: "new one", oldNumber: nil, newNumber: 2),
                        .init(kind: .context, text: "after", oldNumber: 4, newNumber: 3),
                    ]
                )
            ]),
            filePath: "a.swift"
        )
        let result = DiffPaneTextDocumentBuilder.buildStacked(
            group: try #require(model.groups.first),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )

        #expect(result.code.attributedString.string.components(separatedBy: "\n") == [
            "before",
            "old one",
            "old two",
            "new one",
            "after",
        ])
        #expect(result.gutter.string.components(separatedBy: "\n") == ["1", "2", "3", "2", "3"])
    }

    @Test func stackedDocumentKeepsExtraAddedLinesWithAddBlock() throws {
        let model = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,3 +1,4 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        .init(kind: .context, text: "before", oldNumber: 1, newNumber: 1),
                        .init(kind: .delete, text: "old one", oldNumber: 2, newNumber: nil),
                        .init(kind: .add, text: "new one", oldNumber: nil, newNumber: 2),
                        .init(kind: .add, text: "new two", oldNumber: nil, newNumber: 3),
                        .init(kind: .context, text: "after", oldNumber: 3, newNumber: 4),
                    ]
                )
            ]),
            filePath: "a.swift"
        )
        let result = DiffPaneTextDocumentBuilder.buildStacked(
            group: try #require(model.groups.first),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )

        #expect(result.code.attributedString.string.components(separatedBy: "\n") == [
            "before",
            "old one",
            "new one",
            "new two",
            "after",
        ])
        #expect(result.gutter.string.components(separatedBy: "\n") == ["1", "2", "2", "3", "4"])
    }

    @Test func splitDocumentUsesInvisibleLayoutGlyphsForEmptyCounterparts() throws {
        let model = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,1 +1,2 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        .init(kind: .add, text: "let inserted = true", oldNumber: nil, newNumber: 1),
                        .init(kind: .context, text: "let c = 3", oldNumber: 1, newNumber: 2),
                    ]
                )
            ]),
            filePath: "a.swift"
        )
        let result = DiffPaneTextDocumentBuilder.buildSplit(
            group: try #require(model.groups.first),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )
        let firstLine = try #require(result.oldCode.lines.first)

        #expect(firstLine.kind == .add)
        #expect(firstLine.range.length > 0)
        #expect(result.oldCode.attributedString.string.hasPrefix(" "))
        #expect(result.oldCode.attributedString.attribute(.foregroundColor, at: firstLine.range.location, effectiveRange: nil) as? NSColor == .clear)
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

    @Test func diffPaneCodeTextViewStoresLineMetadata() throws {
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(string: "let value = 1"),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(
                    kind: .add,
                    range: NSRange(location: 0, length: 13),
                    tone: .add,
                    sourceLine: DiffDisplayLine(
                        id: "a.swift:new:0:0",
                        anchor: DiffLineAnchor(filePath: "a.swift", hunkIndex: 0, rowIndex: 0, side: .new, oldLine: nil, newLine: 3),
                        text: "let value = 1",
                        lineNumber: 3,
                        kind: .add,
                        inlineSpans: [],
                        noTrailingNewline: false
                    )
                )
            ]
        )
        let scrollView = DiffPaneTextScrollView()
        let theme = try Theme.loadBundled(id: "cool-slate")

        scrollView.update(
            document: document,
            lineLabels: ["+3"],
            wraps: false,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )

        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        #expect(codeView.lineMetadata.count == 1)
        #expect(codeView.lineMetadata.first?.sourceLine?.anchor.newLine == 3)
    }

    @Test func diffPaneCodeTextViewCachesMeasuredRowGeometry() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let text = """
        let first = 1
        let second = 2
        """
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(string: text, attributes: [.font: font]),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(kind: .context, range: NSRange(location: 0, length: 13)),
                DiffPaneTextDocumentBuilder.LineMetadata(kind: .context, range: NSRange(location: 14, length: 14)),
            ]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        let theme = try Theme.loadBundled(id: "cool-slate")

        scrollView.update(
            document: document,
            lineLabels: [" 1", " 2"],
            wraps: true,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)

        _ = codeView.diffRowRects()
        _ = codeView.diffRowRects()
        _ = codeView.diffFirstLineFragmentRects()
        _ = codeView.diffFirstLineFragmentRects()

        #expect(codeView.rowGeometryComputationCountForTesting == 1)

        codeView.setFrameSize(NSSize(width: 260, height: codeView.frame.height))
        _ = codeView.diffRowRects()

        #expect(codeView.rowGeometryComputationCountForTesting == 2)
    }

    @Test func diffPaneCodeTextViewResolvesSymbolsFromPoints() throws {
        let textView = DiffPaneCodeTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80), textContainer: NSTextContainer())
        textView.textStorage?.setAttributedString(NSAttributedString(string: "let value = service.fetch()"))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        let expectedRange = NSRange(location: 4, length: 5)
        let anchorRect = try #require(textView.symbolAnchorRect(for: expectedRange))
        let point = NSPoint(x: anchorRect.midX, y: anchorRect.midY)

        let characterIndex = try #require(textView.characterIndex(at: point))
        let symbolRange = try #require(textView.symbolRange(at: point))

        #expect(expectedRange.contains(characterIndex))
        #expect(symbolRange == expectedRange)
        #expect(anchorRect.width > 0)
        #expect(anchorRect.height > 0)
    }

    @Test func diffPaneCodeTextViewHitTestingIgnoresPointsLeftOfText() throws {
        let textView = makeDiffPaneCodeTextView(string: "let value = 1")
        let textRect = try firstGlyphRect(in: textView, range: NSRange(location: 0, length: 3))
        let point = NSPoint(x: textView.textContainerInset.width - 2, y: textRect.midY)

        #expect(textView.characterIndex(at: point) == nil)
    }

    @Test func diffPaneCodeTextViewHitTestingIgnoresPointsRightOfLineText() throws {
        let textView = makeDiffPaneCodeTextView(string: "short\nlet muchLongerValue = 1")
        let firstLineRect = try firstGlyphRect(in: textView, range: NSRange(location: 0, length: 5))
        let point = NSPoint(x: firstLineRect.maxX + 20, y: firstLineRect.midY)

        #expect(textView.characterIndex(at: point) == nil)
    }

    @Test func diffPaneCodeTextViewHitTestingIgnoresPointsBelowText() throws {
        let textView = makeDiffPaneCodeTextView(string: "let value = 1")
        let textRect = try firstGlyphRect(in: textView, range: NSRange(location: 0, length: 3))
        let point = NSPoint(x: textRect.midX, y: textRect.maxY + 30)

        #expect(textView.characterIndex(at: point) == nil)
    }

    @Test func diffPaneCodeTextViewUpdateTrackingAreasPreservesExternalTrackingAreas() {
        let textView = DiffPaneCodeTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80), textContainer: NSTextContainer())
        let owner = NSObject()
        let externalArea = NSTrackingArea(
            rect: textView.bounds,
            options: [.mouseMoved, .activeInActiveApp],
            owner: owner,
            userInfo: nil
        )
        textView.addTrackingArea(externalArea)

        textView.updateTrackingAreas()

        #expect(textView.trackingAreas.contains { $0 === externalArea })
    }

    @Test func diffPaneCodeTextViewRoutesCommandClickToHandler() throws {
        let textView = DiffPaneCodeTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80), textContainer: NSTextContainer())
        let window = NSWindow(contentRect: textView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView?.addSubview(textView)
        textView.textStorage?.setAttributedString(NSAttributedString(string: "let value = service.fetch()"))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        var clickedPoint: NSPoint?
        textView.commandClickHandler = { clickedPoint = $0 }

        let anchorRect = try #require(textView.symbolAnchorRect(for: NSRange(location: 4, length: 5)))
        let windowPoint = textView.convert(NSPoint(x: anchorRect.midX, y: anchorRect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        textView.mouseDown(with: event)

        let point = try #require(clickedPoint)
        #expect(abs(point.x - anchorRect.midX) < 0.5)
        #expect(abs(point.y - anchorRect.midY) < 0.5)
    }

    private func makeDiffPaneCodeTextView(string: String) -> DiffPaneCodeTextView {
        let textView = DiffPaneCodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120), textContainer: NSTextContainer())
        textView.textContainerInset = NSSize(width: 10, height: 8)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textStorage?.setAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return textView
    }

    private func firstGlyphRect(in textView: DiffPaneCodeTextView, range: NSRange) throws -> NSRect {
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        return rect.offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func subview(withAccessibilityIdentifier identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap { subview(withAccessibilityIdentifier: identifier, in: $0) }.first
    }

    private func visibleCodeTextViews(in view: NSView) -> [DiffPaneCodeTextView] {
        allSubviews(of: view)
            .compactMap { $0 as? DiffPaneTextScrollView }
            .filter(isEffectivelyVisible)
            .sorted { $0.frame.minX < $1.frame.minX }
            .compactMap { $0.documentView as? DiffPaneCodeTextView }
    }

    private func isEffectivelyVisible(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate.isHidden {
                return false
            }
            current = candidate.superview
        }
        return true
    }
}
