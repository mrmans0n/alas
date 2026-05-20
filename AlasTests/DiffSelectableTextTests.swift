import Testing
import SwiftUI
import AppKit
@testable import Alas

/// Smoke tests for the shared diff hunk renderer used by working-tree and
/// commit diff panes. Text selection is exercised at runtime via
/// `.textSelection(.enabled)` and is not inspectable in an `NSHostingController`;
/// these tests guard rendering crashes with varied hunk shapes.
@Suite(.serialized)
@MainActor
struct DiffSelectableTextTests {
    private func currentTheme() -> Theme {
        try! ThemeStore().current
    }

    private func sampleHunk() -> ParsedDiff.Hunk {
        ParsedDiff.Hunk(
            header: "@@ -10,3 +10,4 @@",
            oldStart: 10,
            newStart: 10,
            lines: [
                .init(kind: .context, text: "struct Foo {", oldNumber: 10, newNumber: 10),
                .init(kind: .delete, text: "    let bar: Int", oldNumber: 11, newNumber: nil),
                .init(kind: .add, text: "    let bar: String", oldNumber: nil, newNumber: 11),
                .init(kind: .context, text: "}", oldNumber: 12, newNumber: 12),
            ]
        )
    }

    // MARK: HunkView standalone

    @Test func hunkViewRendersWithoutCrashing() {
        let view = HunkView(hunk: sampleHunk(), fileExtension: "swift")
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func hunkViewWithActionsRendersWithoutCrashing() {
        let view = HunkView(
            hunk: sampleHunk(),
            fileExtension: "swift",
            onStage: {},
            onDiscard: {}
        )
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func hunkViewWithEmptyLinesRendersWithoutCrashing() {
        let emptyHunk = ParsedDiff.Hunk(
            header: "@@ -1,0 +1,0 @@",
            oldStart: 1,
            newStart: 1,
            lines: []
        )
        let view = HunkView(hunk: emptyHunk, fileExtension: "md")
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    // MARK: CommitDiffView integration

    @Test func commitDiffViewWithHunksRendersWithoutCrashing() {
        let diff = ParsedDiff(hunks: [sampleHunk()])
        let view = CommitDiffView(
            path: "Sources/App.swift",
            diff: diff,
            loading: false,
            error: nil,
            onOpenFile: nil
        )
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func commitDiffViewEmptyHunksRendersWithoutCrashing() {
        let view = CommitDiffView(
            path: "a.txt",
            diff: ParsedDiff(hunks: []),
            loading: false,
            error: nil,
            onOpenFile: nil
        )
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func hunkViewWithPlainTextExtensionRendersWithoutCrashing() {
        let hunk = ParsedDiff.Hunk(
            header: "@@ -1,3 +1,3 @@",
            oldStart: 1,
            newStart: 1,
            lines: [
                .init(kind: .context, text: "hello", oldNumber: 1, newNumber: 1),
                .init(kind: .delete, text: "world", oldNumber: 2, newNumber: nil),
                .init(kind: .add, text: "there", oldNumber: nil, newNumber: 2),
            ]
        )
        let view = HunkView(hunk: hunk, fileExtension: "txt")
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }
}
