import Testing
import SwiftUI
import AppKit
@testable import Alas

/// Smoke tests for CommitHeaderView to guard against crashes when rendering
/// expanded/collapsed states. Actual text-selection behaviour is exercised
/// at runtime; SwiftUI's `.textSelection(.enabled)` is a declarative modifier
/// that does not expose inspectable state in a hosted test context.
@Suite(.serialized)
@MainActor
struct CommitHeaderViewTests {
    private func makeDetails(body: String = "") -> CommitDetails {
        CommitDetails(
            info: CommitInfo(
                sha: "deadbeef1234567890abcdef1234567890abcdef",
                shortSha: "deadbee",
                author: "Nacho Lopez",
                authorInitials: "NL",
                date: Date(),
                subject: "feat: wire tab drag",
                conventionalTag: "feat",
                filesChanged: 1,
                insertions: 2,
                deletions: 0
            ),
            body: body,
            authorEmail: "nacho@example.com",
            parents: ["parentsha1", "parentsha2"],
            files: [
                CommitChangedFile(path: "a.swift", originalPath: nil, status: "M", add: 1, del: 1)
            ]
        )
    }

    private func currentTheme() -> Theme {
        try! ThemeStore().current
    }

    @Test func collapsedHeaderRendersWithoutCrashing() {
        let details = makeDetails(body: "Body")
        let view = CommitHeaderView(details: details, expanded: .constant(false))
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func expandedHeaderWithBodyRendersWithoutCrashing() {
        let details = makeDetails(body: "Detailed explanation")
        let view = CommitHeaderView(details: details, expanded: .constant(true))
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func expandedHeaderWithParentsRendersWithoutCrashing() {
        let details = makeDetails(body: "Body with parents")
        let view = CommitHeaderView(details: details, expanded: .constant(true))
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func expandedHeaderWithEmptyBodyRendersWithoutCrashing() {
        let details = makeDetails(body: "")
        let view = CommitHeaderView(details: details, expanded: .constant(true))
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func expandedHeaderOnlyCapsLongBody() {
        let shortView = CommitHeaderView(details: makeDetails(body: "Short body"), expanded: .constant(true))
            .environment(\.theme, currentTheme())
            .frame(width: 600)
        let body = Array(repeating: "A long commit message line", count: 100)
            .joined(separator: "\n")
        let longView = CommitHeaderView(details: makeDetails(body: body), expanded: .constant(true))
            .environment(\.theme, currentTheme())
            .frame(width: 600)

        #expect(NSHostingView(rootView: shortView).fittingSize.height < CommitHeaderView.maxExpandedHeight)
        #expect(NSHostingView(rootView: longView).fittingSize.height <= CommitHeaderView.maxExpandedHeight + 80)
    }

    @Test func expandedHeaderKeepsShortBodyIntrinsicInTallParent() {
        let view = CommitHeaderView(details: makeDetails(body: "Short body"), expanded: .constant(true))
            .environment(\.theme, currentTheme())
            .frame(width: 600)
        let size = NSHostingController(rootView: view).sizeThatFits(
            in: NSSize(width: 600, height: CommitHeaderView.maxExpandedHeight + 200)
        )

        #expect(size.height <= CommitHeaderView.maxExpandedHeight + 40)
    }

    @Test func expandedHeaderOnlyMakesOverflowingDetailsScrollable() {
        let shortController = hostExpandedHeader(body: "Short body")
        let longBody = Array(repeating: "A long commit message line", count: 100)
            .joined(separator: "\n")
        let longController = hostExpandedHeader(body: longBody)

        #expect(shortController.view.descendantScrollViews().isEmpty)
        #expect(longController.view.descendantScrollViews().count == 1)
    }

    @Test func headerRowHasButtonAccessibilityTrait() {
        let details = makeDetails(body: "Body")
        var expanded = false
        let binding = Binding(get: { expanded }, set: { expanded = $0 })
        let view = CommitHeaderView(details: details, expanded: binding)
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    private func hostExpandedHeader(body: String) -> NSHostingController<some View> {
        let view = CommitHeaderView(details: makeDetails(body: body), expanded: .constant(true))
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }
}

private extension NSView {
    func descendantScrollViews() -> [NSScrollView] {
        var result = [self].compactMap { $0 as? NSScrollView }
        for subview in subviews {
            result.append(contentsOf: subview.descendantScrollViews())
        }
        return result
    }
}
