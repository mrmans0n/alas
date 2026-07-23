import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Alas

struct ReviewRequestDraftTests {
    @Test func draftReviewRequestDraftSessionIDUsesBaseAndHeadBranches() {
        let sessionID = DraftReviewRequestTabView.reviewDraftSessionID(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            base: "main",
            head: "feature"
        )

        #expect(sessionID == ReviewDraftSessionID.draftReviewRequest(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            base: "main",
            head: "feature"
        ))
        #expect(sessionID.sourceKind == .draftReviewRequest)
    }

    @Test func draftReviewRequestLauncherBuildsBranchDiffTarget() {
        let tabState = DraftReviewRequestTabState(
            worktreeId: "wt",
            snapshot: Self.snapshot(needsPush: false, aheadCommitCount: 2)
        )

        let target = DraftReviewRequestTabView.reviewSessionTarget(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            tabState: tabState
        )

        #expect(target.kind == .draftReviewRequest)
        #expect(target.draftSessionID == .draftReviewRequest(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            base: "origin/main",
            head: "feature/pr-drafts"
        ))
        #expect(target.title == "Review draft PR")
        #expect(target.revisionDescription == "abc123")
    }

    @Test func draftReviewRequestLauncherIncludesHeadSHAInTargetIdentity() {
        var firstState = DraftReviewRequestTabState(
            worktreeId: "wt",
            snapshot: Self.snapshot(needsPush: false, aheadCommitCount: 2)
        )
        var secondState = firstState
        firstState.headSHA = "abc123"
        secondState.headSHA = "def456"

        let first = DraftReviewRequestTabView.reviewSessionTarget(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            tabState: firstState
        )
        let second = DraftReviewRequestTabView.reviewSessionTarget(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            tabState: secondState
        )

        #expect(first.id != second.id)
        #expect(first.id.rawValue.contains("abc123"))
        #expect(second.id.rawValue.contains("def456"))
    }

    @Test func draftReviewRequestLauncherIsDisabledForStaleTargets() {
        #expect(DraftReviewRequestTabView.canLaunchReviewSession(targetMismatchMessage: nil))
        #expect(!DraftReviewRequestTabView.canLaunchReviewSession(
            targetMismatchMessage: "Switch back to the original branch state."
        ))
    }

    @Test @MainActor func selectingDraftSummaryCommentFocusesAndSelectsFile() async throws {
        let path = "Sources/A.swift"
        let context = ReviewRequestDraftContext(
            commitSubjects: [],
            commits: [],
            changedFiles: [
                CommitChangedFile(path: path, originalPath: nil, status: "M", add: 1, del: 1),
            ],
            diff: Self.modifiedSwiftDiff(path: path),
            fileDiffsByPath: [path: Self.modifiedSwiftDiff(path: path)],
            hasUncommittedChanges: false
        )
        let session = try await DraftReviewRequestDiffSessionBuilder.build(
            context: context,
            worktreePath: URL(fileURLWithPath: "/tmp/alas-tests"),
            openFileForPath: { _ -> (() -> Void)? in nil }
        )
        let fileID = DiffReviewFileID(namespace: "draft-review-request", path: path)
        let comment = ReviewDraftComment(
            id: "draft-1",
            sessionID: .draftReviewRequest(
                worktreeID: "wt",
                repositoryPath: URL(fileURLWithPath: "/repo"),
                base: "main",
                head: "feature"
            ),
            fileID: fileID,
            path: path,
            originalPath: nil,
            side: .new,
            startLine: 1,
            endLine: nil,
            selectedText: "let value = 2",
            bodyMarkdown: "Prefer a named constant.",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        var selectedFileID: DiffReviewFileID?
        var focusedDraftCommentID: String?
        var draftScrollCommand: DiffReviewDraftCommentScrollCommand?
        var railCollapsed = false
        var summaryCollapsed = false
        var layoutMode = DiffLayoutMode.split
        var wrapLines = false
        var showWhitespace = false
        var scrollController = DiffReviewDraftCommentScrollController()

        func makeView() -> some View {
            DiffReviewSurface(
                session: session,
                selectedFileID: Binding(get: { selectedFileID }, set: { selectedFileID = $0 }),
                railCollapsed: Binding(get: { railCollapsed }, set: { railCollapsed = $0 }),
                reviewSummaryCollapsed: Binding(get: { summaryCollapsed }, set: { summaryCollapsed = $0 }),
                layoutMode: Binding(get: { layoutMode }, set: { layoutMode = $0 }),
                wrapLines: Binding(get: { wrapLines }, set: { wrapLines = $0 }),
                showWhitespace: Binding(get: { showWhitespace }, set: { showWhitespace = $0 }),
                codeFontFamily: "",
                codeFontSize: 13,
                showsDraftSummaryRail: true,
                draftCommentsByFileID: [fileID: [comment]],
                focusedDraftCommentID: focusedDraftCommentID,
                draftCommentScrollCommand: draftScrollCommand,
                onSelectDraftComment: { selected in
                    focusedDraftCommentID = selected.id
                    selectedFileID = selected.fileID
                    draftScrollCommand = scrollController.command(commentID: selected.id, fileID: selected.fileID)
                }
            )
            .environment(\.theme, theme())
        }

        let controller = host(makeView(), width: 1100, height: 720)
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()
        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-comment-draft-1", in: controller.view))
        controller.rootView = makeView()
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()

        #expect(selectedFileID == fileID)
        #expect(focusedDraftCommentID == "draft-1")
        #expect(draftScrollCommand?.fileID == fileID)
        #expect(draftScrollCommand?.commentID == "draft-1")
        #expect(subview(withAccessibilityIdentifier: "diff-review-draft-comment-focused-draft-1", in: controller.view) != nil)
    }

    @Test func draftReviewRequestDiffSessionBuilderCreatesRenderableFileSection() async throws {
        let path = "Sources/A.swift"
        let context = ReviewRequestDraftContext(
            commitSubjects: [],
            commits: [],
            changedFiles: [
                CommitChangedFile(path: path, originalPath: nil, status: "M", add: 1, del: 1),
            ],
            diff: Self.modifiedSwiftDiff(path: path),
            fileDiffsByPath: [path: Self.modifiedSwiftDiff(path: path)],
            hasUncommittedChanges: false
        )
        var openedPaths: [String] = []

        let session = try await DraftReviewRequestDiffSessionBuilder.build(
            context: context,
            worktreePath: URL(fileURLWithPath: "/tmp/alas-tests"),
            openFileForPath: { path in
                { openedPaths.append(path) }
            }
        )

        let section = try #require(session.files.first)
        #expect(session.files.count == 1)
        #expect(session.summary.groupsEnabled == false)
        #expect(session.summary.groups.isEmpty)
        #expect(session.summary.fileCount == 1)
        #expect(session.summary.totalAdditions == 1)
        #expect(session.summary.totalDeletions == 1)
        #expect(section.summary.id == DiffReviewFileID(namespace: "draft-review-request", path: path))
        #expect(section.summary.namespace == "draft-review-request")
        #expect(section.summary.groupID == nil)
        #expect(section.summary.groupTitle == nil)
        #expect(section.summary.status == .modified)
        #expect(section.summary.additions == 1)
        #expect(section.summary.deletions == 1)
        #expect(section.summary.isRenderable)
        #expect(section.summary.originalPath == nil)
        #expect(section.parsedDiff?.hunks.count == 1)
        #expect(section.displayModel?.filePath == path)
        #expect(section.displayModel?.groups.count == 1)
        #expect(section.placeholderMessage == nil)

        section.openFile?()
        #expect(openedPaths == [path])
        #expect(DraftReviewRequestDiffSessionBuilder.selectedFileID(for: path) == section.summary.id)
        #expect(DraftReviewRequestDiffSessionBuilder.selectedPath(for: section.summary.id) == path)
        #expect(DraftReviewRequestDiffSessionBuilder.synchronizedSelection(selectedPath: path, session: session) == section.summary.id)
        #expect(DraftReviewRequestDiffSessionBuilder.synchronizedSelection(selectedPath: "Sources/Missing.swift", session: session) == section.summary.id)
    }

    @Test func draftReviewRequestSessionAttachesContextProvider() async throws {
        let path = "Sources/App.swift"
        let originalPath = "Sources/OldApp.swift"
        let snapshot = DiffReviewFileContextSnapshot(
            old: .available(["old"]),
            new: .available(["new"])
        )
        let context = ReviewRequestDraftContext(
            commitSubjects: [],
            commits: [],
            changedFiles: [
                CommitChangedFile(path: path, originalPath: originalPath, status: "R", add: 1, del: 1),
            ],
            diff: Self.modifiedSwiftDiff(path: path),
            fileDiffsByPath: [path: Self.modifiedSwiftDiff(path: path)],
            hasUncommittedChanges: false
        )
        let provider = DiffReviewContextProvider {
            snapshot
        }
        var providerRequests: [(path: String, originalPath: String?)] = []

        let session = try await DraftReviewRequestDiffSessionBuilder.build(
            context: context,
            worktreePath: URL(fileURLWithPath: "/tmp/alas-tests"),
            openFileForPath: { _ -> (() -> Void)? in nil },
            contextProviderForPath: { path, originalPath in
                providerRequests.append((path: path, originalPath: originalPath))
                return provider
            }
        )

        #expect(try await session.files.first?.contextProvider?.snapshot() == snapshot)
        #expect(providerRequests.map(\.path) == [path])
        #expect(providerRequests.map(\.originalPath) == [originalPath])
    }

    @Test @MainActor func draftReviewRequestDiffParsingRunsOffMainThread() async throws {
        let box = ThreadObservationBox()

        _ = try await DraftReviewRequestDiffSessionBuilder.parseDraftDiff("diff --git a/A.swift b/A.swift") { _ in
            box.record(isMainThread: Thread.isMainThread)
            return ParsedDiff(hunks: [])
        }

        #expect(box.isMainThread == false)
    }

    @Test @MainActor func draftReviewRequestSessionRendersWithSharedDiffReviewSurface() async throws {
        let path = "Sources/A.swift"
        let context = ReviewRequestDraftContext(
            commitSubjects: [],
            commits: [],
            changedFiles: [
                CommitChangedFile(path: path, originalPath: nil, status: "M", add: 1, del: 1),
            ],
            diff: Self.modifiedSwiftDiff(path: path),
            fileDiffsByPath: [path: Self.modifiedSwiftDiff(path: path)],
            hasUncommittedChanges: false
        )
        let session = try await DraftReviewRequestDiffSessionBuilder.build(
            context: context,
            worktreePath: URL(fileURLWithPath: "/tmp/alas-tests"),
            openFileForPath: { _ -> (() -> Void)? in nil }
        )
        var selectedFileID = DraftReviewRequestDiffSessionBuilder.selectedFileID(for: path)
        var railCollapsed = false
        var layoutMode = DiffLayoutMode.split
        var wrapLines = false
        var showWhitespace = false

        let view = DiffReviewSurface(
            session: session,
            selectedFileID: Binding(get: { selectedFileID }, set: { selectedFileID = $0 }),
            railCollapsed: Binding(get: { railCollapsed }, set: { railCollapsed = $0 }),
            layoutMode: Binding(get: { layoutMode }, set: { layoutMode = $0 }),
            wrapLines: Binding(get: { wrapLines }, set: { wrapLines = $0 }),
            showWhitespace: Binding(get: { showWhitespace }, set: { showWhitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadges: false,
            showsRailDisplayControls: true
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 1000, height: 700)
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()

        let visibleTextScrollViews = allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextScrollView }
            .filter(isEffectivelyVisible)
        let visibleText = visibleTextScrollViews
            .compactMap { ($0.documentView as? NSTextView)?.string }
            .joined(separator: "\n")

        #expect(visibleTextScrollViews.count == 2)
        #expect(visibleText.contains("let value = 1"))
        #expect(visibleText.contains("let value = 2"))
    }

    @Test func draftReviewRequestDiffOpenFileActionUsesNormalAvailability() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("alas-draft-open-\(UUID().uuidString)")
        let fileURL = root.appendingPathComponent("Sources/A.swift")
        let dirURL = root.appendingPathComponent("Assets")
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        try "let value = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }

        var opened: [String] = []
        let action = DraftReviewRequestTabView.draftDiffOpenFileAction(
            worktreePath: root,
            relativePath: "Sources/A.swift"
        ) { path in
            opened.append(path)
        }

        action?()
        #expect(opened == ["Sources/A.swift"])
        #expect(
            DraftReviewRequestTabView.draftDiffOpenFileAction(
                worktreePath: root,
                relativePath: "Assets",
                openFile: { opened.append($0) }
            ) == nil
        )
        #expect(
            DraftReviewRequestTabView.draftDiffOpenFileAction(
                worktreePath: root,
                relativePath: "Missing.swift",
                openFile: { opened.append($0) }
            ) == nil
        )
    }

    @Test func draftReviewRequestDiffSessionSelectionKeepsExistingPath() async throws {
        let context = ReviewRequestDraftContext(
            commitSubjects: [],
            commits: [],
            changedFiles: [
                CommitChangedFile(path: "A.swift", originalPath: nil, status: "M", add: 1, del: 1),
                CommitChangedFile(path: "B.swift", originalPath: nil, status: "M", add: 1, del: 1),
            ],
            diff: Self.modifiedSwiftDiff(path: "A.swift") + "\n" + Self.modifiedSwiftDiff(path: "B.swift"),
            fileDiffsByPath: [
                "A.swift": Self.modifiedSwiftDiff(path: "A.swift"),
                "B.swift": Self.modifiedSwiftDiff(path: "B.swift"),
            ],
            hasUncommittedChanges: false
        )
        let session = try await DraftReviewRequestDiffSessionBuilder.build(
            context: context,
            worktreePath: URL(fileURLWithPath: "/tmp/alas-tests"),
            openFileForPath: { _ -> (() -> Void)? in nil }
        )

        let selected = DraftReviewRequestDiffSessionBuilder.synchronizedSelection(
            selectedPath: "B.swift",
            session: session
        )

        #expect(selected == DiffReviewFileID(namespace: "draft-review-request", path: "B.swift"))
        #expect(DraftReviewRequestDiffSessionBuilder.selectedPath(for: selected) == "B.swift")
    }

    @Test func draftReviewRequestDiffSessionSelectionFallsBackToFirstFile() async throws {
        let context = ReviewRequestDraftContext(
            commitSubjects: [],
            commits: [],
            changedFiles: [
                CommitChangedFile(path: "A.swift", originalPath: nil, status: "M", add: 1, del: 1),
            ],
            diff: Self.modifiedSwiftDiff(path: "A.swift"),
            fileDiffsByPath: ["A.swift": Self.modifiedSwiftDiff(path: "A.swift")],
            hasUncommittedChanges: false
        )
        let session = try await DraftReviewRequestDiffSessionBuilder.build(
            context: context,
            worktreePath: URL(fileURLWithPath: "/tmp/alas-tests"),
            openFileForPath: { _ -> (() -> Void)? in nil }
        )

        let selected = DraftReviewRequestDiffSessionBuilder.synchronizedSelection(
            selectedPath: "Missing.swift",
            session: session
        )

        #expect(selected == DiffReviewFileID(namespace: "draft-review-request", path: "A.swift"))
        #expect(DraftReviewRequestDiffSessionBuilder.selectedPath(for: selected) == "A.swift")
    }

    @Test @MainActor func draftReviewRequestDiffSessionBuilderRendersImagesWhenItReceivesAProvider() async throws {
        let imagePath = "Assets/logo.png"
        let textPath = "Docs/README.md"
        let context = ReviewRequestDraftContext(
            commitSubjects: [],
            commits: [],
            changedFiles: [
                CommitChangedFile(path: imagePath, originalPath: nil, status: "M", add: 12, del: 4),
                CommitChangedFile(path: textPath, originalPath: nil, status: "A", add: 3, del: 0),
            ],
            diff: "",
            fileDiffsByPath: [
                imagePath: """
                diff --git a/Assets/logo.png b/Assets/logo.png
                index 1111111..2222222 100644
                Binary files a/Assets/logo.png and b/Assets/logo.png differ
                """,
            ],
            hasUncommittedChanges: false
        )

        var recordedPaths: [String] = []
        let session = try await DraftReviewRequestDiffSessionBuilder.build(
            context: context,
            worktreePath: URL(fileURLWithPath: "/tmp/alas-tests"),
            openFileForPath: { _ -> (() -> Void)? in nil },
            imageProviderForFile: { file in
                recordedPaths.append(file.path)
                return file.path == imagePath
                    ? imageProvider(path: file.path, before: "merge-base", after: "head")
                    : nil
            }
        )

        #expect(session.files.map(\.summary.path) == [imagePath, textPath])
        #expect(session.summary.totalAdditions == 15)
        #expect(session.summary.totalDeletions == 4)

        let imageSection = try #require(session.files.first)
        #expect(imageSection.summary.additions == 12)
        #expect(imageSection.summary.deletions == 4)
        #expect(imageSection.summary.isRenderable)
        #expect(imageSection.displayModel == nil)
        #expect(imageSection.parsedDiff?.hunks.isEmpty == true)
        #expect(imageSection.placeholderMessage == nil)
        #expect(imageSection.imageProvider != nil)
        #expect(recordedPaths == [imagePath])

        let textSection = try #require(session.files.last)
        #expect(textSection.summary.additions == 3)
        #expect(textSection.summary.deletions == 0)
        #expect(textSection.summary.isRenderable == false)
        #expect(textSection.displayModel == nil)
        #expect(textSection.parsedDiff?.hunks.isEmpty == true)
        #expect(textSection.placeholderMessage == "No text diff is available for this file.")
    }

    @Test func parsesGeneratedTitleAndBody() throws {
        let parsed = try ReviewRequestDraft.parseGeneratedMessage("""
        Add review request drafts

        ## Summary
        - Adds a draft PR tab.

        ## Testing
        - xcodebuild test
        """)

        #expect(parsed.title == "Add review request drafts")
        #expect(parsed.body.contains("## Summary"))
        #expect(parsed.body.contains("## Testing"))
    }

    @Test func validationRequiresTitleBodyAndReadySnapshot() {
        let ready = ReviewRequestDraft.ValidationInput(
            title: "Add review request drafts",
            body: "## Summary\n- Adds a tab\n\n## Testing\n- Not run",
            snapshot: Self.snapshot(needsPush: false, aheadCommitCount: 2)
        )
        #expect(ReviewRequestDraft.validationMessage(for: ready) == nil)

        let missingTitle = ReviewRequestDraft.ValidationInput(title: "", body: ready.body, snapshot: ready.snapshot)
        #expect(ReviewRequestDraft.validationMessage(for: missingTitle) == "Title is required.")

        let needsPush = ReviewRequestDraft.ValidationInput(
            title: ready.title,
            body: ready.body,
            snapshot: Self.snapshot(needsPush: true, aheadCommitCount: 2)
        )
        #expect(ReviewRequestDraft.validationMessage(for: needsPush) == "Push this branch before creating a PR.")

        let stale = ReviewRequestDraft.ValidationInput(
            title: ready.title,
            body: ready.body,
            snapshot: Self.snapshot(needsPush: false, aheadCommitCount: 2, upstreamAheadCommitCount: 1)
        )
        #expect(ReviewRequestDraft.validationMessage(for: stale) == "Remote has commits not in this branch. Pull or rebase before creating a PR.")

        let diverged = ReviewRequestDraft.ValidationInput(
            title: ready.title,
            body: ready.body,
            snapshot: Self.snapshot(needsPush: true, aheadCommitCount: 2, upstreamAheadCommitCount: 1)
        )
        #expect(ReviewRequestDraft.validationMessage(for: diverged) == "Remote has commits not in this branch. Pull, rebase, or force push before creating a PR.")
    }

    @Test func validationBlocksExistingReviewRequest() {
        let snapshot = Self.snapshot(
            needsPush: false,
            aheadCommitCount: 2,
            reviewRequest: Self.reviewRequest()
        )
        let input = ReviewRequestDraft.ValidationInput(
            title: "Add review request drafts",
            body: "## Summary\n- Adds a tab",
            snapshot: snapshot
        )

        #expect(ReviewRequestDraft.validationMessage(for: input) == "A PR already exists for this branch.")
    }

    @Test func validationBlocksLocalBranchMatchingSelectedBase() {
        let snapshot = Self.snapshot(
            branchName: "main",
            baseBranch: "origin/main",
            needsPush: false,
            aheadCommitCount: 2
        )
        let input = ReviewRequestDraft.ValidationInput(
            title: "Add review request drafts",
            body: "## Summary\n- Adds a tab",
            snapshot: snapshot
        )

        #expect(ReviewRequestDraft.validationMessage(for: input) == "Switch to a feature branch before creating a PR.")
    }

    private static func snapshot(
        needsPush: Bool,
        aheadCommitCount: Int,
        upstreamAheadCommitCount: Int = 0
    ) -> ReviewLoopSnapshot {
        snapshot(
            branchName: "feature/pr-drafts",
            baseBranch: "origin/main",
            needsPush: needsPush,
            aheadCommitCount: aheadCommitCount,
            upstreamAheadCommitCount: upstreamAheadCommitCount
        )
    }

    private static func snapshot(
        branchName: String = "feature/pr-drafts",
        baseBranch: String = "origin/main",
        needsPush: Bool,
        aheadCommitCount: Int,
        upstreamAheadCommitCount: Int = 0,
        reviewRequest: ReviewRequest? = nil
    ) -> ReviewLoopSnapshot {
        ReviewLoopSnapshot(
            local: ReviewLoopLocalState(
                branchName: branchName,
                headSHA: "abc123",
                baseBranch: baseBranch,
                hasWorkingTreeChanges: false,
                hasStagedChanges: false,
                aheadCommitCount: aheadCommitCount,
                hasUpstream: true,
                upstreamRemoteName: "origin",
                upstreamBranchName: "feature/pr-drafts",
                upstreamAheadCommitCount: upstreamAheadCommitCount,
                needsPush: needsPush
            ),
            remote: CodeHostRemote(
                kind: .github,
                host: "github.com",
                owner: "mrmans0n",
                repository: "alas",
                remoteName: "origin",
                webURL: URL(string: "https://github.com/mrmans0n/alas")!
            ),
            reviewRequest: reviewRequest,
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .githubCLI,
            errorMessage: nil
        )
    }

    private static func reviewRequest() -> ReviewRequest {
        ReviewRequest(
            remote: CodeHostRemote(
                kind: .github,
                host: "github.com",
                owner: "mrmans0n",
                repository: "alas",
                remoteName: "origin",
                webURL: URL(string: "https://github.com/mrmans0n/alas")!
            ),
            number: 42,
            title: "Add review request drafts",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/42")!,
            state: .open,
            isDraft: true,
            headRefName: "feature/pr-drafts",
            baseRefName: "main",
            reviewDecision: .reviewRequired,
            mergeState: .unknown,
            checks: [],
            threads: []
        )
    }

    private static func modifiedSwiftDiff(path: String) -> String {
        """
        diff --git a/\(path) b/\(path)
        index 1111111..2222222 100644
        --- a/\(path)
        +++ b/\(path)
        @@ -1,1 +1,1 @@
        -let value = 1
        +let value = 2
        """
    }

    @MainActor
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

    private func subviews(withAccessibilityIdentifier identifier: String, in view: NSView) -> [NSView] {
        var matches: [NSView] = []
        if view.accessibilityIdentifier() == identifier {
            matches.append(view)
        }
        matches.append(contentsOf: view.subviews.flatMap { subviews(withAccessibilityIdentifier: identifier, in: $0) })
        return matches
    }

    private func pressAccessibilityElement(withAccessibilityIdentifier identifier: String, in view: NSView) -> Bool {
        for match in subviews(withAccessibilityIdentifier: identifier, in: view) {
            if match.accessibilityPerformPress() {
                return true
            }
        }
        return false
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

    private func theme() -> Theme {
        try! ThemeStore().current
    }
}

@MainActor
private func imageProvider(
    path: String,
    before: String,
    after: String
) -> DiffReviewImageProvider {
    DiffReviewImageProvider(
        id: DiffReviewImageProviderID(
            source: .range,
            repository: "/tmp/repo",
            beforeRevision: before,
            afterRevision: after,
            beforePath: path,
            afterPath: path
        ),
        load: {
            ImageDiffPair(
                before: .missing,
                after: .missing,
                oldPath: nil,
                kind: .modified
            )
        }
    )
}

private final class ThreadObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var observed: Bool?

    var isMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    func record(isMainThread: Bool) {
        lock.lock()
        observed = isMainThread
        lock.unlock()
    }
}
