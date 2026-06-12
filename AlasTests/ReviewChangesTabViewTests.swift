import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct ReviewChangesTabViewTests {
    private func theme() -> Theme { try! ThemeStore().current }

    @Test func loadTokenOnlyAcceptsCurrentLoad() {
        let key = "/repo\u{0}review"
        let first = ReviewChangesLoadToken.next(key: key)
        var activeKey: String? = first.key
        var activeID = first.id

        #expect(first.isActive(activeKey: activeKey, activeID: activeID))

        let second = ReviewChangesLoadToken.next(key: key)
        activeKey = second.key
        activeID = second.id

        #expect(!first.isActive(activeKey: activeKey, activeID: activeID))
        #expect(second.isActive(activeKey: activeKey, activeID: activeID))
        #expect(!second.isActive(activeKey: "other", activeID: activeID))
    }

    @Test func loadKeyFingerprintTracksIndexAndChangeMetadata() {
        let changes = [
            ChangedFile(path: "b.swift", status: "M", stage: .unstaged, add: 1, del: 0, renameFrom: nil),
            ChangedFile(path: "a.swift", status: "R", stage: .staged, add: 2, del: 1, renameFrom: "old.swift"),
        ]

        let baseline = ReviewChangesLoadKey.fingerprint(changes: changes, indexFingerprint: "index-a")
        let sameDifferentOrder = ReviewChangesLoadKey.fingerprint(changes: changes.reversed(), indexFingerprint: "index-a")
        let changedIndex = ReviewChangesLoadKey.fingerprint(changes: changes, indexFingerprint: "index-b")
        let changedMetadata = ReviewChangesLoadKey.fingerprint(
            changes: [
                ChangedFile(path: "b.swift", status: "M", stage: .unstaged, add: 2, del: 0, renameFrom: nil),
                ChangedFile(path: "a.swift", status: "R", stage: .staged, add: 2, del: 1, renameFrom: "old.swift"),
            ],
            indexFingerprint: "index-a"
        )

        #expect(baseline == sameDifferentOrder)
        #expect(baseline != changedIndex)
        #expect(baseline != changedMetadata)
    }

    @Test func railRendersFilesAndCollapsedStateKeepsMarkers() {
        let files = [
            ReviewChangesFileSummary(
                path: "Sources/App/AlphaView.swift",
                source: .unstaged,
                status: .modified,
                additions: 4,
                deletions: 1,
                isRenderable: true
            ),
            ReviewChangesFileSummary(
                path: "Tests/BetaTests.swift",
                source: .staged,
                status: .added,
                additions: 12,
                deletions: 0,
                isRenderable: true
            ),
        ]
        let session = ReviewChangesSessionModel(files: files)
        var selected = files[0].id
        var collapsed = false

        let expanded = ReviewChangesRail(
            session: session,
            selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            onSelectFile: { selected = $0 }
        )
        .environment(\.theme, theme())

        let expandedController = NSHostingController(rootView: expanded)
        expandedController.view.frame = NSRect(x: 0, y: 0, width: 280, height: 500)
        expandedController.view.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "review-rail-row-\(files[0].id.rawValue)", in: expandedController.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "review-rail-row-scroll-id-\(files[0].id.rawValue)", in: expandedController.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "review-rail-row-selected-\(files[0].id.rawValue)", in: expandedController.view) != nil)
        #expect(accessibilityLabel(in: expandedController.view, containing: "AlphaView.swift") != nil)
        #expect(accessibilityLabel(in: expandedController.view, containing: "BetaTests.swift") != nil)

        collapsed = true
        selected = files[1].id
        let collapsedView = ReviewChangesRail(
            session: session,
            selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            onSelectFile: { selected = $0 }
        )
        .environment(\.theme, theme())

        let collapsedController = NSHostingController(rootView: collapsedView)
        collapsedController.view.frame = NSRect(x: 0, y: 0, width: 60, height: 500)
        collapsedController.view.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "review-rail-marker-\(files[0].id.rawValue)", in: collapsedController.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "review-rail-marker-\(files[1].id.rawValue)", in: collapsedController.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "review-rail-marker-scroll-id-\(files[1].id.rawValue)", in: collapsedController.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "review-rail-marker-selected-\(files[1].id.rawValue)", in: collapsedController.view) != nil)
    }

    @Test func railRowsFlattenSourceTreesIntoDirectLazyItems() {
        let files = [
            ReviewChangesFileSummary(
                path: "Sources/App/AlphaView.swift",
                source: .unstaged,
                status: .modified,
                additions: 4,
                deletions: 1,
                isRenderable: true
            ),
            ReviewChangesFileSummary(
                path: "Sources/App/BetaView.swift",
                source: .unstaged,
                status: .modified,
                additions: 2,
                deletions: 0,
                isRenderable: true
            ),
            ReviewChangesFileSummary(
                path: "Tests/GammaTests.swift",
                source: .staged,
                status: .added,
                additions: 12,
                deletions: 0,
                isRenderable: true
            ),
        ]
        let rows = ReviewChangesRailRows.rows(for: ReviewChangesSessionModel(files: files))

        #expect(rows.map(\.kind) == [
            .sourceHeader(.unstaged),
            .directory("Sources/App", depth: 0),
            .file(files[0], depth: 1, name: "AlphaView.swift"),
            .file(files[1], depth: 1, name: "BetaView.swift"),
            .divider,
            .sourceHeader(.staged),
            .directory("Tests", depth: 0),
            .file(files[2], depth: 1, name: "GammaTests.swift"),
        ])
        #expect(rows.map(\.id).contains("file:\(files[2].id.rawValue)"))
    }

    @Test func fileSectionEmbedsDiffPaneWithoutPerFileToolbar() {
        let file = ReviewChangesFileSectionModel(
            summary: ReviewChangesFileSummary(
                path: "Sources/App/AlphaView.swift",
                source: .unstaged,
                status: .modified,
                additions: 1,
                deletions: 1,
                isRenderable: true
            ),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = ReviewChangesFileSection(
            file: file,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        controller.view.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "review-file-section-\(file.id.rawValue)", in: controller.view) != nil)
        #expect(allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })
        #expect(subview(withAccessibilityIdentifier: "diff-pane-toolbar", in: controller.view) == nil)
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
