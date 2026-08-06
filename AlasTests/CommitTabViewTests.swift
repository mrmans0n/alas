import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct CommitTabViewTests {
    @Test func commitReviewDraftSessionIDUsesCommitSHA() {
        let sessionID = CommitReviewBody.reviewDraftSessionID(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abc"
        )

        #expect(sessionID == ReviewDraftSessionID.commit(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abc"
        ))
        #expect(sessionID.sourceKind == .commit)
    }

    @Test func commitLauncherBuildsCommitTarget() {
        let target = CommitTabView.reviewSessionTarget(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abcdef1234567890",
            title: "Add review sessions"
        )

        #expect(target.kind == .commit)
        #expect(target.draftSessionID == .commit(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abcdef1234567890"
        ))
        #expect(target.title == "Review Add review sessions")
        #expect(target.revisionDescription == "abcdef1234567890")
    }

    @Test func commitReviewContextMenuBuildsCommitReviewTarget() {
        let worktree = Worktree(
            id: "wt-1",
            projectId: "project-1",
            name: "feature",
            branch: "feature",
            path: URL(fileURLWithPath: "/repo"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let commit = CommitInfo(
            sha: "abcdef1234567890",
            shortSha: "abcdef1",
            author: "Nacho Lopez",
            authorInitials: "NL",
            date: Date(timeIntervalSince1970: 1),
            subject: "Add review sessions",
            conventionalTag: nil,
            filesChanged: 1,
            insertions: 2,
            deletions: 0
        )

        let target = RootView.commitReviewSessionTarget(worktree: worktree, commit: commit)

        #expect(target.kind == .commit)
        #expect(target.worktreeID == "wt-1")
        #expect(target.repositoryPath == URL(fileURLWithPath: "/repo"))
        #expect(target.title == "Review Add review sessions")
        #expect(target.revisionDescription == "abcdef1234567890")
        #expect(target.draftSessionID == .commit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abcdef1234567890"
        ))
    }

    @Test func commitReviewFeedbackTargetIncludesCommitSHA() {
        let sha = "abcdef1234567890abcdef1234567890abcdef12"
        let target = CommitReviewBody.reviewFeedbackTarget(
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: sha
        )

        #expect(target.title == "Commit Review abcdef1234")
        #expect(target.repositoryPath == "/repo")
        #expect(target.sourceDescription == "Commit \(sha)")
    }

    @Test func commitReviewBodyHostsReviewSurfaceWithoutSourceBadges() {
        let file = summary(path: "Sources/App.swift")
        let session = DiffReviewLoadedSession(
            files: [
                DiffReviewFileSectionModel(
                    summary: file,
                    parsedDiff: nil,
                    displayModel: nil,
                    placeholderMessage: "No diff.",
                    openFile: nil,
                    contextProvider: nil
                ),
            ],
            summary: DiffReviewSessionModel(files: [file], groupsEnabled: false)
        )
        var selectedFileID: DiffReviewFileID?
        var railCollapsed = false
        var layoutMode = DiffLayoutMode.split
        var wrapLines = false
        var showWhitespace = false

        let view = CommitReviewBody(
            session: session,
            selectedFileID: Binding(get: { selectedFileID }, set: { selectedFileID = $0 }),
            railCollapsed: Binding(get: { railCollapsed }, set: { railCollapsed = $0 }),
            layoutMode: Binding(get: { layoutMode }, set: { layoutMode = $0 }),
            wrapLines: Binding(get: { wrapLines }, set: { wrapLines = $0 }),
            showWhitespace: Binding(get: { showWhitespace }, set: { showWhitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 1000, height: 700)

        #expect(subview(withAccessibilityIdentifier: "commit-review-body", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-commit:Sources/App.swift", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-file-section-commit:Sources/App.swift", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-source-badge-commit:Sources/App.swift", in: controller.view) == nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-display-controls", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-layout-split", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-layout-stacked", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-wrap-toggle", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-whitespace-toggle", in: controller.view) != nil)
    }

    @Test func commitReviewBodyCanDisableDraftReviewControls() {
        let file = summary(path: "Sources/App.swift")
        let session = DiffReviewLoadedSession(
            files: [
                DiffReviewFileSectionModel(
                    summary: file,
                    parsedDiff: nil,
                    displayModel: nil,
                    placeholderMessage: "No diff.",
                    openFile: nil,
                    contextProvider: nil
                ),
            ],
            summary: DiffReviewSessionModel(files: [file], groupsEnabled: false)
        )
        var selectedFileID: DiffReviewFileID?
        var railCollapsed = false
        var layoutMode = DiffLayoutMode.split
        var wrapLines = false
        var showWhitespace = false

        let view = CommitReviewBody(
            session: session,
            selectedFileID: Binding(get: { selectedFileID }, set: { selectedFileID = $0 }),
            railCollapsed: Binding(get: { railCollapsed }, set: { railCollapsed = $0 }),
            layoutMode: Binding(get: { layoutMode }, set: { layoutMode = $0 }),
            wrapLines: Binding(get: { wrapLines }, set: { wrapLines = $0 }),
            showWhitespace: Binding(get: { showWhitespace }, set: { showWhitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            reviewDraftSessionID: .commit(
                worktreeID: "wt",
                repositoryPath: URL(fileURLWithPath: "/repo"),
                sha: "abc"
            ),
            allowsReviewing: false
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 1000, height: 700)

        #expect(subview(withAccessibilityIdentifier: "commit-review-body", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "review-draft-summary-rail", in: controller.view) == nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-draft-composer", in: controller.view) == nil)
    }

    @Test func commitReviewLoadIdentityRejectsStaleDetails() {
        let current = details(sha: "current-sha")
        let stale = details(sha: "stale-sha")

        #expect(CommitReviewLoadIdentity.isCurrent(
            details: current,
            currentDetails: current,
            sha: "current-sha"
        ))
        #expect(!CommitReviewLoadIdentity.isCurrent(
            details: stale,
            currentDetails: current,
            sha: "current-sha"
        ))
        #expect(!CommitReviewLoadIdentity.isCurrent(
            details: current,
            currentDetails: stale,
            sha: "current-sha"
        ))
        #expect(!CommitReviewLoadIdentity.isCurrent(
            details: current,
            currentDetails: current,
            sha: "other-sha"
        ))
        #expect(!CommitReviewLoadIdentity.isCurrent(
            details: current,
            currentDetails: nil,
            sha: "current-sha"
        ))
    }

    @Test func commitReviewLoadTokenRejectsOlderSameKeyLoadAfterNewerTokenIsActive() {
        let older = CommitReviewLoadToken.next(key: "same-key")
        let newer = CommitReviewLoadToken.next(key: "same-key")

        #expect(older.key == newer.key)
        #expect(!older.isActive(activeKey: newer.key, activeID: newer.id))
        #expect(newer.isActive(activeKey: newer.key, activeID: newer.id))
    }

    @Test func commitReviewLoadIdentityPreservesPublishedSessionForSameSHA() {
        let current = details(sha: "current-sha")

        #expect(CommitReviewLoadIdentity.preservesPublishedSession(
            details: current,
            sha: "current-sha",
            hasReviewSession: true
        ))
        #expect(!CommitReviewLoadIdentity.preservesPublishedSession(
            details: current,
            sha: "other-sha",
            hasReviewSession: true
        ))
        #expect(!CommitReviewLoadIdentity.preservesPublishedSession(
            details: current,
            sha: "current-sha",
            hasReviewSession: false
        ))
        #expect(!CommitReviewLoadIdentity.preservesPublishedSession(
            details: nil,
            sha: "current-sha",
            hasReviewSession: true
        ))
    }

    @Test func commitReviewContentStateShowsLoadingForNonEmptyCommitWithoutSession() {
        #expect(CommitReviewContentState.resolve(
            detailsFileCount: 1,
            loadingReviewSession: false,
            reviewSessionFileCount: nil,
            reviewSessionError: nil
        ) == .loading)
    }

    private func summary(path: String) -> DiffReviewFileSummary {
        DiffReviewFileSummary(
            path: path,
            namespace: "commit",
            groupID: nil,
            groupTitle: nil,
            status: .modified,
            additions: 1,
            deletions: 0,
            isRenderable: false
        )
    }

    private func details(sha: String) -> CommitDetails {
        CommitDetails(
            info: CommitInfo(
                sha: sha,
                shortSha: String(sha.prefix(7)),
                author: "Author",
                authorInitials: "A",
                date: Date(timeIntervalSince1970: 0),
                subject: "Subject",
                conventionalTag: nil,
                filesChanged: 1,
                insertions: 1,
                deletions: 0
            ),
            body: "",
            authorEmail: "author@example.com",
            parents: [],
            files: [
                CommitChangedFile(path: "Sources/App.swift", originalPath: nil, status: "M", add: 1, del: 0),
            ]
        )
    }

    private func theme() -> Theme {
        try! ThemeStore().current
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

    private func subview(withAccessibilityIdentifier identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap { subview(withAccessibilityIdentifier: identifier, in: $0) }.first
    }
}
