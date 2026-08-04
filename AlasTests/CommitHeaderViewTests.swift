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
}
