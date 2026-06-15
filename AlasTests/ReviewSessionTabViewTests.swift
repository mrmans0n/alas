import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Alas

@MainActor
struct ReviewSessionTabViewTests {
    @Test func rendersLoadedSessionTitleAndSummaryRail() throws {
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 1)
        )
        let summary = DiffReviewFileSummary(
            path: "A.swift",
            namespace: "unstaged",
            groupID: "unstaged",
            groupTitle: "Unstaged",
            status: .modified,
            additions: 1,
            deletions: 0,
            isRenderable: false
        )
        let loaded = ReviewSessionLoadedContext(
            session: DiffReviewLoadedSession(
                files: [
                    DiffReviewFileSectionModel(
                        summary: summary,
                        parsedDiff: nil,
                        displayModel: nil,
                        placeholderMessage: "No diff",
                        openFile: nil
                    ),
                ],
                summary: DiffReviewSessionModel(files: [summary], groupsEnabled: true)
            ),
            feedbackTarget: ReviewFeedbackTarget(
                title: target.title,
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: target.sourceDescription
            )
        )
        let view = ReviewSessionTabView.preview(record: record, loaded: loaded)
            .environment(\.theme, try ThemeStore().current)

        let host = NSHostingView(rootView: view.frame(width: 900, height: 700))
        host.layoutSubtreeIfNeeded()

        #expect(recursiveDescription(host).contains("Review all changes"))
        #expect(subview(withAccessibilityIdentifier: "review-draft-summary-rail", in: host) != nil)
    }

    private func recursiveDescription(_ view: NSView) -> String {
        ([view.accessibilityLabel(), view.accessibilityIdentifier()] + view.subviews.map(recursiveDescription))
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private func subview(withAccessibilityIdentifier identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap { subview(withAccessibilityIdentifier: identifier, in: $0) }.first
    }
}
