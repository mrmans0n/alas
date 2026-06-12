import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct DiffReviewSurfaceTests {
    private func theme() -> Theme { try! ThemeStore().current }

    @Test func railRendersUngroupedCommitSessionWithFileRowsAndNoSourceHeader() {
        let files = [
            summary(path: "Sources/App/AlphaView.swift", additions: 4, deletions: 1),
            summary(path: "Tests/BetaTests.swift", status: .added, additions: 12, deletions: 0),
        ]
        let session = DiffReviewSessionModel(files: files, groupsEnabled: false)
        var selected = files[0].id
        var collapsed = false

        let view = DiffReviewRail(
            session: session,
            selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            onSelectFile: { selected = $0 }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-\(files[0].id.rawValue)", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-\(files[1].id.rawValue)", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-source-commit", in: controller.view) == nil)
        #expect(accessibilityLabel(in: controller.view, containing: "AlphaView.swift") != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "BetaTests.swift") != nil)
    }

    @Test func railRendersGroupedSessionsWithSourceHeaders() {
        let files = [
            summary(path: "Sources/App/AlphaView.swift", namespace: "unstaged", groupID: "unstaged", groupTitle: "Unstaged"),
            summary(path: "Sources/App/BetaView.swift", namespace: "staged", groupID: "staged", groupTitle: "Staged", status: .added),
        ]
        let session = DiffReviewSessionModel(files: files, groupsEnabled: true)
        var selected = files[0].id
        var collapsed = false

        let view = DiffReviewRail(
            session: session,
            selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            onSelectFile: { selected = $0 }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-source-unstaged", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-source-staged", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-\(files[0].id.rawValue)", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-\(files[1].id.rawValue)", in: controller.view) != nil)
    }

    @Test func collapsedRailKeepsSelectableMarkers() {
        let files = [
            summary(path: "Sources/App/AlphaView.swift", additions: 4, deletions: 1),
            summary(path: "Tests/BetaTests.swift", status: .added, additions: 12, deletions: 0),
        ]
        let session = DiffReviewSessionModel(files: files, groupsEnabled: false)
        var selected = files[1].id
        var collapsed = true

        let view = DiffReviewRail(
            session: session,
            selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            onSelectFile: { selected = $0 }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 60, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-marker-\(files[0].id.rawValue)", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-marker-\(files[1].id.rawValue)", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-marker-selected-\(files[1].id.rawValue)", in: controller.view) != nil)
    }

    @Test func railSelectedFileRowsUseSidebarSelectionTreatment() {
        #expect(DiffReviewRailSelectedRowStyle.backgroundToken == "bg-4")
        #expect(DiffReviewRailSelectedRowStyle.fileDepthIndent == 6)
        #expect(DiffReviewRailSelectedRowStyle.accentRailWidth == 3)
        #expect(DiffReviewRailSelectedRowStyle.accentRailHeight == 14)
        #expect(DiffReviewRailSelectedRowStyle.accentRailXOffset == 2)
        #expect(DiffReviewRailSelectedRowStyle.cornerRadius == 6)
        #expect(DiffReviewRailSelectedRowStyle.contentLeadingPadding == 6)
    }

    @Test func fileSectionEmbedsDiffPaneWithoutToolbarAndShowsOpenFile() {
        let file = DiffReviewFileSectionModel(
            summary: summary(
                path: "Sources/App/AlphaView.swift",
                namespace: "unstaged",
                groupID: "unstaged",
                groupTitle: "Unstaged",
                additions: 1,
                deletions: 1
            ),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: {}
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: true
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-file-section-\(file.id.rawValue)", in: controller.view) != nil)
        #expect(allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })
        #expect(subview(withAccessibilityIdentifier: "diff-pane-toolbar", in: controller.view) == nil)
        #expect(DiffReviewFileSectionActions.openFileButtonTitle(for: file) == "Open File")
        #expect(accessibilityLabel(in: controller.view, containing: "UNSTAGED") != nil)
    }

    @Test func placeholderSectionsRenderMessageWithoutDiffPane() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Assets/logo.png", status: .modified, isRenderable: false),
            parsedDiff: nil,
            displayModel: nil,
            placeholderMessage: "Binary files are not shown.",
            openFile: nil
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: true
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 260)

        #expect(subview(withAccessibilityIdentifier: "diff-review-file-section-\(file.id.rawValue)", in: controller.view) != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "Binary files are not shown.") != nil)
        #expect(!allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })
    }

    @Test func surfaceRepairsInvalidSelectedIDToFirstSessionFile() {
        let first = summary(path: "Sources/App/AlphaView.swift")
        let second = summary(path: "Tests/BetaTests.swift")
        let loaded = loadedSession(summaries: [first, second])
        var selected: DiffReviewFileID? = DiffReviewFileID(namespace: "commit", path: "Missing.swift")
        var collapsed = false
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewSurface(
            session: loaded,
            selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
            railCollapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13
        )
        .environment(\.theme, theme())

        _ = host(view, width: 1000, height: 700)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        #expect(selected == first.id)
    }

    @Test func selectionSynchronizationClearsEmptySessions() {
        let selected = DiffReviewFileID(namespace: "commit", path: "Stale.swift")

        let result = DiffReviewSurfaceSelectionSync.synchronizedSelection(
            current: selected,
            fileIDs: []
        )

        #expect(result == nil)
    }

    @Test func selectionSynchronizationRepairsMissingSelection() {
        let first = DiffReviewFileID(namespace: "commit", path: "First.swift")
        let second = DiffReviewFileID(namespace: "commit", path: "Second.swift")
        let missing = DiffReviewFileID(namespace: "commit", path: "Missing.swift")

        let result = DiffReviewSurfaceSelectionSync.synchronizedSelection(
            current: missing,
            fileIDs: [first, second]
        )

        #expect(result == first)
    }

    @Test func sessionFileSetChangesResetProgrammaticScrollSuppression() {
        let first = DiffReviewFileID(namespace: "commit", path: "First.swift")
        let second = DiffReviewFileID(namespace: "commit", path: "Second.swift")
        var controller = DiffReviewProgrammaticScrollController()

        _ = controller.beginProgrammaticScroll(to: first)
        let result = DiffReviewSurfaceSelectionSync.synchronize(
            current: first,
            previousFileSetKey: "commit:First.swift",
            fileIDs: [second],
            programmaticScroll: controller
        )

        #expect(result.selectedFileID == second)
        #expect(result.fileSetKey == DiffReviewSurfaceSelectionSync.fileSetKey(for: [second]))
        #expect(!result.programmaticScroll.isSuppressing)
    }

    private func parsedDiff() -> ParsedDiff {
        ParsedDiff(hunks: [
            ParsedDiff.Hunk(
                header: "@@ -1,2 +1,2 @@",
                oldStart: 1,
                newStart: 1,
                lines: [
                    .init(kind: .context, text: "let a = 1", oldNumber: 1, newNumber: 1),
                    .init(kind: .delete, text: "let b = 2", oldNumber: 2, newNumber: nil),
                    .init(kind: .add, text: "let b = 3", oldNumber: nil, newNumber: 2),
                ]
            ),
        ])
    }

    private func displayModel() -> DiffDisplayModel {
        DiffDisplayModelBuilder.build(diff: parsedDiff(), filePath: "Sources/App/AlphaView.swift")
    }

    private func loadedSession(summaries: [DiffReviewFileSummary]) -> DiffReviewLoadedSession {
        DiffReviewLoadedSession(
            files: summaries.map { summary in
                DiffReviewFileSectionModel(
                    summary: summary,
                    parsedDiff: nil,
                    displayModel: nil,
                    placeholderMessage: "No diff.",
                    openFile: nil
                )
            },
            summary: DiffReviewSessionModel(files: summaries, groupsEnabled: false)
        )
    }

    private func summary(
        path: String,
        namespace: String = "commit",
        groupID: String? = nil,
        groupTitle: String? = nil,
        status: DiffReviewFileStatus = .modified,
        additions: Int = 1,
        deletions: Int = 0,
        isRenderable: Bool = true,
        originalPath: String? = nil
    ) -> DiffReviewFileSummary {
        DiffReviewFileSummary(
            path: path,
            namespace: namespace,
            groupID: groupID,
            groupTitle: groupTitle,
            status: status,
            additions: additions,
            deletions: deletions,
            isRenderable: isRenderable,
            originalPath: originalPath
        )
    }

    private func host<Content: View>(
        _ view: Content,
        width: CGFloat,
        height: CGFloat
    ) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        controller.view.layoutSubtreeIfNeeded()
        return controller
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

    private func accessibilityLabel(in view: NSView, containing text: String) -> String? {
        if let label = view.accessibilityLabel(), label.contains(text) {
            return label
        }
        return view.subviews.lazy.compactMap { accessibilityLabel(in: $0, containing: text) }.first
    }
}
