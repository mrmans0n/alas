import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct ReviewChangesTabViewTests {
    private func theme() -> Theme { try! ThemeStore().current }

    @Test func reviewChangesDraftSessionIDUsesWorktreeAndLocalChangesScope() {
        let worktree = Worktree(
            id: "wt-1",
            projectId: "project-1",
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/repo"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )

        let sessionID = ReviewChangesTabView.reviewDraftSessionID(worktree: worktree)

        #expect(sessionID == ReviewDraftSessionID.localChanges(
            worktreeID: "wt-1",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        ))
        #expect(sessionID.sourceKind == .localChanges)
    }

    @Test func reviewChangesLauncherBuildsLocalChangesTarget() {
        let target = ReviewChangesTabView.reviewSessionTarget(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )

        #expect(target.kind == .localChanges)
        #expect(target.draftSessionID == .localChanges(
            worktreeID: "wt-1",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        ))
        #expect(target.title == "Review all changes")
    }

    @Test func reviewChangesLauncherUsesDistinctActionLabel() {
        #expect(ReviewChangesTabView.reviewSessionLauncherLabel == "Open review session")
    }

    @Test func reviewSessionLauncherOpensExistingRecordWithoutSaving() {
        let target = ReviewChangesTabView.reviewSessionTarget(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let existing = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        var savedRecords: [ReviewSessionRecord] = []
        var openedRecords: [ReviewSessionRecord] = []

        let opened = ReviewSessionLauncher.openOrFocus(
            target: target,
            now: { Date(timeIntervalSince1970: 10) },
            findActive: { _ in existing },
            save: { savedRecords.append($0) },
            open: { openedRecords.append($0) }
        )

        #expect(opened)
        #expect(savedRecords.isEmpty)
        #expect(openedRecords == [existing])
    }

    @Test func reviewSessionLauncherDoesNotOpenNewRecordWhenSaveFails() {
        let target = ReviewChangesTabView.reviewSessionTarget(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        var openedRecords: [ReviewSessionRecord] = []
        var reportedError: Error?

        let opened = ReviewSessionLauncher.openOrFocus(
            target: target,
            now: { Date(timeIntervalSince1970: 10) },
            findActive: { _ in nil },
            save: { _ in throw LauncherTestError.saveFailed },
            open: { openedRecords.append($0) },
            onFailure: { reportedError = $0 }
        )

        #expect(!opened)
        #expect(openedRecords.isEmpty)
        #expect((reportedError as? LauncherTestError) == .saveFailed)
    }

    @Test func copyReviewPromptUsesPromptMarkdown() {
        var copiedPrompt: String?
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Working tree",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Review Changes"
            ),
            comments: [
                draftComment(id: "draft-1", body: "Extract this helper."),
            ]
        )

        ReviewFeedbackPromptActions.copyPrompt(bundle, pasteboard: { copiedPrompt = $0 })

        #expect(copiedPrompt == bundle.promptMarkdown())
    }

    @Test func sendReviewPromptUsesSamePromptMarkdownAndTarget() {
        let target = ReviewFeedbackAgentTarget.newChat(agentID: "codex", title: "New chat")
        let sender = ReviewFeedbackAgentSender(
            availableTargets: { [target] },
            send: { prompt, selectedTarget, completion in
                #expect(prompt.contains("Please address each review comment below."))
                #expect(prompt.contains("Extract this helper."))
                #expect(selectedTarget == target)
                completion(.success(()))
            }
        )
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Working tree",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Review Changes"
            ),
            comments: [
                draftComment(id: "draft-1", body: "Extract this helper."),
            ]
        )

        ReviewFeedbackPromptActions.sendToAgent(bundle, target: target, sender: sender)
    }

    @Test func sendToAgentRecordsSessionHandoff() {
        var sentPrompt: String?
        var recorded: ReviewFeedbackHandoff?
        let target = ReviewFeedbackAgentTarget.existingSession(worktreeID: "wt-1", sessionID: "acp-1", title: "Codex")
        let sender = ReviewFeedbackAgentSender(
            availableTargets: { [target] },
            send: { prompt, _, completion in
                sentPrompt = prompt
                completion(.success(()))
            }
        )
        let sessionID = ReviewSessionID(rawValue: "session-1")
        let activeComment = draftComment(id: "c1", body: "Fix it")
        let dismissedComment = ReviewDraftComment(
            id: "c2",
            sessionID: activeComment.sessionID,
            fileID: activeComment.fileID,
            path: activeComment.path,
            originalPath: activeComment.originalPath,
            side: activeComment.side,
            startLine: activeComment.startLine,
            endLine: activeComment.endLine,
            selectedText: activeComment.selectedText,
            bodyMarkdown: "Ignore it",
            state: .dismissed,
            createdAt: activeComment.createdAt,
            updatedAt: activeComment.updatedAt
        )
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Local changes"
            ),
            comments: [dismissedComment, activeComment]
        )

        ReviewFeedbackPromptActions.sendToAgent(
            bundle,
            target: target,
            sender: sender,
            sessionID: sessionID,
            recordHandoff: { recorded = $0 },
            now: { Date(timeIntervalSince1970: 30) },
            makeID: { "handoff-1" }
        )

        #expect(sentPrompt?.contains("Fix it") == true)
        #expect(recorded?.id == "handoff-1")
        #expect(recorded?.sessionID == sessionID)
        #expect(recorded?.commentIDs == ["c1"])
        #expect(recorded?.target == target)
        #expect(recorded?.createdAt == Date(timeIntervalSince1970: 30))
        #expect(recorded?.promptRevision == ReviewFeedbackHandoff.revisionKey(commentIDs: ["c1"], prompt: sentPrompt ?? ""))
        #expect(recorded?.status == .sent)
    }

    @Test func failedSendDoesNotRecordSessionHandoffAndReportsError() {
        var sentPrompt: String?
        var recorded: ReviewFeedbackHandoff?
        var sendError: Error?
        let target = ReviewFeedbackAgentTarget.existingSession(worktreeID: "wt-1", sessionID: "acp-1", title: "Codex")
        let sender = ReviewFeedbackAgentSender(
            availableTargets: { [target] },
            send: { prompt, _, completion in
                sentPrompt = prompt
                completion(.failure(ReviewFeedbackAgentSendError.rejected))
            }
        )
        let sessionID = ReviewSessionID(rawValue: "session-1")
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Local changes"
            ),
            comments: [draftComment(id: "c1", body: "Fix it")]
        )

        ReviewFeedbackPromptActions.sendToAgent(
            bundle,
            target: target,
            sender: sender,
            sessionID: sessionID,
            recordHandoff: { recorded = $0 },
            recordSendFailure: { sendError = $0 },
            now: { Date(timeIntervalSince1970: 30) },
            makeID: { "handoff-1" }
        )

        #expect(sentPrompt?.contains("Fix it") == true)
        #expect(recorded == nil)
        #expect((sendError as? ReviewFeedbackAgentSendError) == .rejected)
    }

    @Test func draftWorkspaceActionsEditCommentThroughController() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ReviewDraftCommentStore(
            store: PersistenceStore(),
            url: directory.appendingPathComponent("review-draft-comments.json")
        )
        let session = ReviewDraftSessionID.localChanges(
            worktreeID: "wt-1",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let controller = ReviewDraftCommentController(
            sessionID: session,
            store: store,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let sender = ReviewFeedbackAgentSender(
            availableTargets: { [] },
            send: { _, _, _ in Issue.record("send should not be called") }
        )
        let anchor = DiffReviewLineAnchor(
            path: "Sources/App.swift",
            side: .new,
            line: 4,
            rowIndex: 0,
            selectedText: ""
        )
        let fileID = DiffReviewFileID(namespace: "unstaged", path: "Sources/App.swift")

        try controller.load()
        try controller.add(anchor: anchor, fileID: fileID, bodyMarkdown: "Original")
        let comment = try #require(controller.comments.first)
        let actions = ReviewDraftWorkspaceActions.make(controller: controller, sender: sender)

        #expect(actions.availability(comment).canEdit)
        actions.edit(comment, "Updated body")

        #expect(controller.comments.count == 1)
        #expect(controller.comments.first?.bodyMarkdown == "Updated body")
        let savedComments = try store.load(sessionID: session)
        #expect(savedComments.count == 1)
        #expect(savedComments.first?.bodyMarkdown == "Updated body")
    }

    @Test func draftWorkspaceActionsSendToExplicitTargetOnly() {
        let codex = ReviewFeedbackAgentTarget.newChat(agentID: "codex", title: "Codex")
        let claude = ReviewFeedbackAgentTarget.newChat(agentID: "claude", title: "Claude")
        var selectedTarget: ReviewFeedbackAgentTarget?
        let sender = ReviewFeedbackAgentSender(
            availableTargets: { [codex, claude] },
            send: { _, target, completion in
                selectedTarget = target
                completion(.success(()))
            }
        )
        let comment = draftComment(id: "draft-1", body: "Extract this helper.")
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Working tree",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Review Changes"
            ),
            comments: [comment]
        )
        let actions = ReviewDraftWorkspaceActions.make(controller: nil, sender: sender)

        #expect(actions.agentTargets() == [codex, claude])
        #expect(actions.availability(comment).canShowSendToAgent)
        actions.sendToAgent(bundle, claude)

        #expect(selectedTarget == claude)
    }

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

        let baseline = ReviewChangesLoadKey.fingerprint(changes: changes, indexFingerprint: "index-a", changesGeneration: 1)
        let sameDifferentOrder = ReviewChangesLoadKey.fingerprint(changes: changes.reversed(), indexFingerprint: "index-a", changesGeneration: 1)
        let changedIndex = ReviewChangesLoadKey.fingerprint(changes: changes, indexFingerprint: "index-b", changesGeneration: 1)
        let changedGeneration = ReviewChangesLoadKey.fingerprint(changes: changes, indexFingerprint: "index-a", changesGeneration: 2)
        let changedMetadata = ReviewChangesLoadKey.fingerprint(
            changes: [
                ChangedFile(path: "b.swift", status: "M", stage: .unstaged, add: 2, del: 0, renameFrom: nil),
                ChangedFile(path: "a.swift", status: "R", stage: .staged, add: 2, del: 1, renameFrom: "old.swift"),
            ],
            indexFingerprint: "index-a",
            changesGeneration: 1
        )

        #expect(baseline == sameDifferentOrder)
        #expect(baseline != changedIndex)
        #expect(baseline != changedGeneration)
        #expect(baseline != changedMetadata)
    }

    @Test func railRendersFilesAndCollapsedStateKeepsMarkers() {
        let files = [
            reviewSummary(
                path: "Sources/App/AlphaView.swift",
                source: .unstaged,
                status: .modified,
                additions: 4,
                deletions: 1,
                isRenderable: true
            ),
            reviewSummary(
                path: "Tests/BetaTests.swift",
                source: .staged,
                status: .added,
                additions: 12,
                deletions: 0,
                isRenderable: true
            ),
        ]
        let session = ReviewChangesSessionModel(files: files, groupsEnabled: true)
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

        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-\(files[0].id.rawValue)", in: expandedController.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-scroll-id-\(files[0].id.rawValue)", in: expandedController.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-selected-\(files[0].id.rawValue)", in: expandedController.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-icon-\(files[0].id.rawValue)", in: expandedController.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-icon-\(files[1].id.rawValue)", in: expandedController.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-source-unstaged", in: expandedController.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-source-staged", in: expandedController.view) != nil)
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

        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-marker-\(files[0].id.rawValue)", in: collapsedController.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-marker-\(files[1].id.rawValue)", in: collapsedController.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-marker-scroll-id-\(files[1].id.rawValue)", in: collapsedController.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-marker-selected-\(files[1].id.rawValue)", in: collapsedController.view) != nil)
    }

    @Test func railRowsFlattenDirectorySectionsIntoDirectLazyItems() {
        let files = [
            reviewSummary(
                path: "Sources/App/AlphaView.swift",
                source: .unstaged,
                status: .modified,
                additions: 4,
                deletions: 1,
                isRenderable: true
            ),
            reviewSummary(
                path: "Sources/App/BetaView.swift",
                source: .unstaged,
                status: .modified,
                additions: 2,
                deletions: 0,
                isRenderable: true
            ),
            reviewSummary(
                path: "Tests/GammaTests.swift",
                source: .staged,
                status: .added,
                additions: 12,
                deletions: 0,
                isRenderable: true
            ),
        ]
        let rows = ReviewChangesRailRows.rows(for: ReviewChangesSessionModel(files: files, groupsEnabled: true))

        #expect(rows.map(\.kind) == [
            .sourceHeader(id: "unstaged", title: "Unstaged", fileCount: 2),
            .directory("Sources/App", depth: 0),
            .file(files[0], depth: 1, name: "AlphaView.swift"),
            .file(files[1], depth: 1, name: "BetaView.swift"),
            .divider,
            .sourceHeader(id: "staged", title: "Staged", fileCount: 1),
            .directory("Tests", depth: 0),
            .file(files[2], depth: 1, name: "GammaTests.swift"),
        ])
        #expect(rows.map(\.id).contains("file:staged:\(files[2].id.rawValue)"))
    }

    @Test func fileSectionEmbedsDiffPaneWithoutPerFileToolbar() {
        let file = ReviewChangesFileSectionModel(
            summary: reviewSummary(
                path: "Sources/App/AlphaView.swift",
                source: .unstaged,
                status: .modified,
                additions: 1,
                deletions: 1,
                isRenderable: true
            ),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
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

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        controller.view.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "diff-review-file-section-\(file.id.rawValue)", in: controller.view) != nil)
        #expect(allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })
        #expect(subview(withAccessibilityIdentifier: "diff-pane-toolbar", in: controller.view) == nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-open-file-\(file.id.rawValue)", in: controller.view) == nil)
        #expect(accessibilityLabel(in: controller.view, containing: "UNSTAGED") != nil)
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

    private func reviewSummary(
        path: String,
        source: ReviewChangesSource,
        status: ReviewChangesFileStatus,
        additions: Int,
        deletions: Int,
        isRenderable: Bool,
        originalPath: String? = nil
    ) -> ReviewChangesFileSummary {
        ReviewChangesFileSummary(
            path: path,
            namespace: source.rawValue,
            groupID: source.rawValue,
            groupTitle: source.title,
            status: status,
            additions: additions,
            deletions: deletions,
            isRenderable: isRenderable,
            originalPath: originalPath
        )
    }

    private func draftComment(id: String, body: String) -> ReviewDraftComment {
        ReviewDraftComment(
            id: id,
            sessionID: .localChanges(
                worktreeID: "wt-1",
                worktreePath: URL(fileURLWithPath: "/repo"),
                scope: .all
            ),
            fileID: DiffReviewFileID(namespace: "unstaged", path: "Sources/App.swift"),
            path: "Sources/App.swift",
            originalPath: nil,
            side: .new,
            startLine: 4,
            endLine: nil,
            selectedText: nil,
            bodyMarkdown: body,
            state: .active,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private enum LauncherTestError: Error, Equatable {
        case saveFailed
    }
}
