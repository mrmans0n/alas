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

    @Test func diffSelectableTextBuilderPlainStringExcludesGutters() {
        let text = DiffSelectableTextBuilder.plainString(for: sampleHunk())
        #expect(text == """
struct Foo {
    let bar: Int
    let bar: String
}
""")
        #expect(!text.contains("+11"))
        #expect(!text.contains("−11"))
        #expect(!text.contains("@@"))
    }

    @Test func diffSelectableTextBuilderPreservesEmptyLines() {
        let hunk = ParsedDiff.Hunk(
            header: "@@ -1,3 +1,3 @@",
            oldStart: 1,
            newStart: 1,
            lines: [
                .init(kind: .context, text: "alpha", oldNumber: 1, newNumber: 1),
                .init(kind: .delete, text: "", oldNumber: 2, newNumber: nil),
                .init(kind: .add, text: "omega", oldNumber: nil, newNumber: 2),
            ]
        )

        #expect(DiffSelectableTextBuilder.plainString(for: hunk) == "alpha\n\nomega")
    }

    @Test func diffSelectableTextBuilderReturnsLineMetadataForEveryLine() {
        let result = DiffSelectableTextBuilder.build(
            hunk: sampleHunk(),
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            theme: currentTheme()
        )

        #expect(result.attributedString.string == DiffSelectableTextBuilder.plainString(for: sampleHunk()))
        #expect(result.lines.map(\.kind) == [.context, .delete, .add, .context])
        #expect(result.lines.map(\.marker) == [" 10", "−11", "+11", " 12"])
        #expect(result.lines.first?.range == NSRange(location: 0, length: 12))
        #expect(result.lines.last?.range.location == (result.attributedString.string as NSString).length - 1)
    }

    @Test func diffSelectableTextViewHostsCodeOnlyNativeTextView() {
        let view = DiffSelectableTextView(
            hunk: sampleHunk(),
            fileExtension: "swift",
            codeFontFamily: "",
            codeFontSize: 13,
            theme: currentTheme()
        )
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        controller.view.layoutSubtreeIfNeeded()

        let textViews = allSubviews(of: controller.view).compactMap { $0 as? NSTextView }
        #expect(textViews.contains(where: { textView in
            textView.isSelectable &&
            !textView.isEditable &&
            textView.string == DiffSelectableTextBuilder.plainString(for: sampleHunk())
        }))
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
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

    private func sampleFile(path: String = "Sources/App.swift") -> CommitChangedFile {
        CommitChangedFile(path: path, originalPath: nil, status: "M", add: 1, del: 0)
    }

    @Test func commitDiffViewWithHunksRendersWithoutCrashing() {
        let diff = ParsedDiff(hunks: [sampleHunk()])
        let view = CommitDiffView(
            worktreePath: URL(fileURLWithPath: "/tmp"),
            sha: "abc1234",
            file: sampleFile(),
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
            worktreePath: URL(fileURLWithPath: "/tmp"),
            sha: "abc1234",
            file: sampleFile(path: "a.txt"),
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

    // MARK: Code font configuration

    @Test func codeFontResolutionReturnsMonospacedForEmptyFamily() {
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        #expect(font.isFixedPitch)
        #expect(font.pointSize == 13)
    }

    @Test func codeFontResolutionMatchesEditorForNamedFamily() {
        let diffFont = CenterTypography.resolveCodeFont(family: "SF Mono", size: 14)
        let editorFont = CodeEditorCoordinator.resolveFont(family: "SF Mono", size: 14)
        #expect(diffFont.fontName == editorFont.fontName)
        #expect(diffFont.pointSize == editorFont.pointSize)
    }

    @Test func codeFontRendersForConfiguredFamilyName() {
        let font = CenterTypography.codeFont(family: "SF Mono", size: 14)
        #expect(font != Font.system(size: 14))
    }

    @Test func hunkViewRendersWithCustomFontSize() {
        for size: CGFloat in [8, 13, 24, 64] {
            let view = HunkView(hunk: sampleHunk(), fileExtension: "swift", codeFontFamily: "", codeFontSize: size)
                .environment(\.theme, currentTheme())
            let controller = NSHostingController(rootView: view)
            controller.view.layoutSubtreeIfNeeded()
            #expect(controller.view != nil)
        }
    }

    @Test func hunkViewRendersWithCustomFontFamily() {
        let view = HunkView(hunk: sampleHunk(), fileExtension: "swift", codeFontFamily: "Menlo", codeFontSize: 15)
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func commitDiffViewRendersWithCustomFont() {
        let diff = ParsedDiff(hunks: [sampleHunk()])
        let view = CommitDiffView(
            worktreePath: URL(fileURLWithPath: "/tmp"),
            sha: "abc1234",
            file: sampleFile(),
            path: "Sources/App.swift",
            diff: diff,
            loading: false,
            error: nil,
            codeFontFamily: "Menlo",
            codeFontSize: 18,
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
