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
}
