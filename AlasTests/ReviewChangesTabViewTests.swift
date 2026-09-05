import AppKit
import Combine
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

    @Test func loadingPresentationOnlyBlocksInitialLoad() {
        #expect(ReviewChangesLoadingPresentation.showsBlockingLoader(isLoading: true, hasSession: false))
        #expect(!ReviewChangesLoadingPresentation.showsBlockingLoader(isLoading: true, hasSession: true))
        #expect(!ReviewChangesLoadingPresentation.showsBlockingLoader(isLoading: false, hasSession: false))
    }

    @Test func loadingPresentationSurfacesRefreshErrorsWithStaleSession() {
        #expect(ReviewChangesLoadingPresentation.showsRefreshError(loadError: "git failed", hasSession: true))
        #expect(!ReviewChangesLoadingPresentation.showsRefreshError(loadError: "git failed", hasSession: false))
        #expect(!ReviewChangesLoadingPresentation.showsRefreshError(loadError: nil, hasSession: true))
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

    @Test func draftWorkspaceActionsResolveRecomputesHandoffProgress() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let draftStore = ReviewDraftCommentStore(
            store: PersistenceStore(),
            url: directory.appendingPathComponent("review-draft-comments.json")
        )
        let sessionStore = ReviewSessionStore(
            store: PersistenceStore(),
            url: directory.appendingPathComponent("review-sessions.json")
        )
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let controller = ReviewDraftCommentController(
            sessionID: target.draftSessionID,
            store: draftStore,
            now: { Date(timeIntervalSince1970: 100) }
        )
        try controller.load()
        try controller.add(
            anchor: DiffReviewLineAnchor(path: "Sources/App.swift", side: .new, line: 4, rowIndex: 0, selectedText: ""),
            fileID: DiffReviewFileID(namespace: "unstaged", path: "Sources/App.swift"),
            bodyMarkdown: "Please fix this."
        )
        let comment = try #require(controller.comments.first)
        try sessionStore.save(ReviewSessionRecord(
            id: target.id,
            target: target,
            status: .sent,
            handoffs: [ReviewFeedbackHandoff(
                id: "h1",
                sessionID: target.id,
                commentIDs: [comment.id],
                target: .newChat(agentID: "claude", title: "New chat"),
                createdAt: Date(timeIntervalSince1970: 1),
                promptRevision: "rev",
                status: .sent
            )],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        ))
        let sender = ReviewFeedbackAgentSender(
            availableTargets: { [] },
            send: { _, _, _ in Issue.record("send should not be called") }
        )
        let actions = ReviewDraftWorkspaceActions.make(
            controller: controller,
            sender: sender,
            worktreeID: "wt-1",
            now: { Date(timeIntervalSince1970: 200) },
            sessionStore: { sessionStore }
        )

        actions.resolve(comment)

        #expect(controller.comments.first?.state == .resolved)
        let record = try #require(try sessionStore.load(id: target.id))
        #expect(record.status == .addressed)
        #expect(record.handoffs.map(\.status) == [.addressed])
        #expect(record.updatedAt == Date(timeIntervalSince1970: 200))
    }

    @Test func draftWorkspaceActionsResolveNotifiesOpenPanesAfterRecompute() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let draftStore = ReviewDraftCommentStore(
            store: PersistenceStore(),
            url: directory.appendingPathComponent("review-draft-comments.json")
        )
        let sessionStore = ReviewSessionStore(
            store: PersistenceStore(),
            url: directory.appendingPathComponent("review-sessions.json")
        )
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let controller = ReviewDraftCommentController(
            sessionID: target.draftSessionID,
            store: draftStore,
            now: { Date(timeIntervalSince1970: 100) }
        )
        try controller.load()
        try controller.add(
            anchor: DiffReviewLineAnchor(path: "Sources/App.swift", side: .new, line: 4, rowIndex: 0, selectedText: ""),
            fileID: DiffReviewFileID(namespace: "unstaged", path: "Sources/App.swift"),
            bodyMarkdown: "Please fix this."
        )
        let comment = try #require(controller.comments.first)
        let sender = ReviewFeedbackAgentSender(
            availableTargets: { [] },
            send: { _, _, _ in Issue.record("send should not be called") }
        )
        var notifyCount = 0
        let actions = ReviewDraftWorkspaceActions.make(
            controller: controller,
            sender: sender,
            worktreeID: "wt-1",
            now: { Date(timeIntervalSince1970: 200) },
            sessionStore: { sessionStore },
            notifyExternalChange: { notifyCount += 1 }
        )

        actions.resolve(comment)

        // Open review panes must be told to reload after the UI recompute, so a
        // stale in-memory record can't later clobber the persisted addressed
        // status — the same signal the CLI/MCP resolve path emits.
        #expect(notifyCount == 1)
    }

    @Test func draftWorkspaceActionsResolveWithoutWorktreeDoesNotNotify() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let draftStore = ReviewDraftCommentStore(
            store: PersistenceStore(),
            url: directory.appendingPathComponent("review-draft-comments.json")
        )
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let controller = ReviewDraftCommentController(
            sessionID: target.draftSessionID,
            store: draftStore,
            now: { Date(timeIntervalSince1970: 100) }
        )
        try controller.load()
        try controller.add(
            anchor: DiffReviewLineAnchor(path: "Sources/App.swift", side: .new, line: 4, rowIndex: 0, selectedText: ""),
            fileID: DiffReviewFileID(namespace: "unstaged", path: "Sources/App.swift"),
            bodyMarkdown: "Please fix this."
        )
        let comment = try #require(controller.comments.first)
        let sender = ReviewFeedbackAgentSender(
            availableTargets: { [] },
            send: { _, _, _ in Issue.record("send should not be called") }
        )
        var notifyCount = 0
        let actions = ReviewDraftWorkspaceActions.make(
            controller: controller,
            sender: sender,
            now: { Date(timeIntervalSince1970: 200) },
            notifyExternalChange: { notifyCount += 1 }
        )

        actions.resolve(comment)

        // No worktree means no recompute ran, so there is nothing to reload and
        // no notification should be emitted.
        #expect(controller.comments.first?.state == .resolved)
        #expect(notifyCount == 0)
    }

    @Test func draftWorkspaceActionsResolveDoesNotDemoteAnotherSessionInTheSameWorktree() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let draftStore = ReviewDraftCommentStore(
            store: PersistenceStore(),
            url: directory.appendingPathComponent("review-draft-comments.json")
        )
        let sessionStore = ReviewSessionStore(
            store: PersistenceStore(),
            url: directory.appendingPathComponent("review-sessions.json")
        )

        // Session A: a commit review, already addressed on disk, whose
        // referenced comment is resolved in the shared draft store.
        let targetA = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abc123",
            title: "Review abc123"
        )
        let controllerA = ReviewDraftCommentController(
            sessionID: targetA.draftSessionID,
            store: draftStore,
            now: { Date(timeIntervalSince1970: 100) }
        )
        try controllerA.load()
        try controllerA.add(
            anchor: DiffReviewLineAnchor(path: "Sources/A.swift", side: .new, line: 1, rowIndex: 0, selectedText: ""),
            fileID: DiffReviewFileID(namespace: "commit", path: "Sources/A.swift"),
            bodyMarkdown: "Fix A."
        )
        let commentA = try #require(controllerA.comments.first)
        try controllerA.resolve(commentID: commentA.id)
        try sessionStore.save(ReviewSessionRecord(
            id: targetA.id,
            target: targetA,
            status: .addressed,
            handoffs: [ReviewFeedbackHandoff(
                id: "hA",
                sessionID: targetA.id,
                commentIDs: [commentA.id],
                target: .newChat(agentID: "claude", title: "New chat"),
                createdAt: Date(timeIntervalSince1970: 1),
                promptRevision: "rev",
                status: .addressed
            )],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        ))

        // Session B: local changes in the same worktree, sharing the draft
        // store. The user resolves one of its comments through the UI.
        let targetB = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let controllerB = ReviewDraftCommentController(
            sessionID: targetB.draftSessionID,
            store: draftStore,
            now: { Date(timeIntervalSince1970: 100) }
        )
        try controllerB.load()
        try controllerB.add(
            anchor: DiffReviewLineAnchor(path: "Sources/B.swift", side: .new, line: 1, rowIndex: 0, selectedText: ""),
            fileID: DiffReviewFileID(namespace: "unstaged", path: "Sources/B.swift"),
            bodyMarkdown: "Fix B."
        )
        let commentB = try #require(controllerB.comments.first)
        let sender = ReviewFeedbackAgentSender(
            availableTargets: { [] },
            send: { _, _, _ in Issue.record("send should not be called") }
        )
        let actions = ReviewDraftWorkspaceActions.make(
            controller: controllerB,
            sender: sender,
            worktreeID: "wt-1",
            now: { Date(timeIntervalSince1970: 200) },
            sessionStore: { sessionStore }
        )

        actions.resolve(commentB)

        // Session A stays addressed — its resolved comment lives in the same
        // draft store and must be seen as resolved even though it isn't in
        // session B's controller.
        let recordA = try #require(try sessionStore.load(id: targetA.id))
        #expect(recordA.status == .addressed)
        #expect(recordA.handoffs.map(\.status) == [.addressed])
    }

    @Test func draftWorkspaceActionsDismissDoesNotRecomputeHandoffProgress() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let draftStore = ReviewDraftCommentStore(
            store: PersistenceStore(),
            url: directory.appendingPathComponent("review-draft-comments.json")
        )
        let sessionStore = ReviewSessionStore(
            store: PersistenceStore(),
            url: directory.appendingPathComponent("review-sessions.json")
        )
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let controller = ReviewDraftCommentController(
            sessionID: target.draftSessionID,
            store: draftStore,
            now: { Date(timeIntervalSince1970: 100) }
        )
        try controller.load()
        try controller.add(
            anchor: DiffReviewLineAnchor(path: "Sources/App.swift", side: .new, line: 4, rowIndex: 0, selectedText: ""),
            fileID: DiffReviewFileID(namespace: "unstaged", path: "Sources/App.swift"),
            bodyMarkdown: "Please fix this."
        )
        let comment = try #require(controller.comments.first)
        let originalRecord = ReviewSessionRecord(
            id: target.id,
            target: target,
            status: .sent,
            handoffs: [ReviewFeedbackHandoff(
                id: "h1",
                sessionID: target.id,
                commentIDs: [comment.id],
                target: .newChat(agentID: "claude", title: "New chat"),
                createdAt: Date(timeIntervalSince1970: 1),
                promptRevision: "rev",
                status: .sent
            )],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try sessionStore.save(originalRecord)
        let sender = ReviewFeedbackAgentSender(
            availableTargets: { [] },
            send: { _, _, _ in Issue.record("send should not be called") }
        )
        let actions = ReviewDraftWorkspaceActions.make(
            controller: controller,
            sender: sender,
            worktreeID: "wt-1",
            now: { Date(timeIntervalSince1970: 200) },
            sessionStore: { sessionStore }
        )

        actions.dismiss(comment)

        #expect(controller.comments.first?.state == .dismissed)
        let record = try #require(try sessionStore.load(id: target.id))
        #expect(record == originalRecord)
    }

    @Test func draftWorkspaceActionsResolveSkipsRecomputeWhenWorktreeIDIsNil() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let draftStore = ReviewDraftCommentStore(
            store: PersistenceStore(),
            url: directory.appendingPathComponent("review-draft-comments.json")
        )
        let session = ReviewDraftSessionID.localChanges(
            worktreeID: "wt-1",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let controller = ReviewDraftCommentController(sessionID: session, store: draftStore)
        try controller.load()
        try controller.add(
            anchor: DiffReviewLineAnchor(path: "Sources/App.swift", side: .new, line: 4, rowIndex: 0, selectedText: ""),
            fileID: DiffReviewFileID(namespace: "unstaged", path: "Sources/App.swift"),
            bodyMarkdown: "Please fix this."
        )
        let comment = try #require(controller.comments.first)
        let sender = ReviewFeedbackAgentSender(
            availableTargets: { [] },
            send: { _, _, _ in Issue.record("send should not be called") }
        )
        let actions = ReviewDraftWorkspaceActions.make(controller: controller, sender: sender)

        actions.resolve(comment)

        #expect(controller.comments.first?.state == .resolved)
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

        let controller = NSHostingController(
            rootView: AppKitReviewChangesFileHarness(
                input: AppKitDiffReviewRowInput(
                    file: file,
                    state: AppKitDiffReviewFileState(),
                    theme: theme(),
                    codeFontFamily: "",
                    showsSourceBadge: true
                )
            )
            .environment(\.theme, theme())
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        controller.view.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "diff-review-file-section-\(file.id.rawValue)", in: controller.view) != nil)
        #expect(allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })
        #expect(subview(withAccessibilityIdentifier: "diff-pane-toolbar", in: controller.view) == nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-open-file-\(file.id.rawValue)", in: controller.view) == nil)
        #expect(accessibilityLabel(in: controller.view, containing: "UNSTAGED") != nil)
    }

    @Test func diffReviewFileSectionShowsLazyExpandableContextControlsForProvider() throws {
        let controller = renderFileSection(file: providerBackedFile())

        let text = renderedText(in: controller.view)

        #expect(text.contains("Expand context above"))
        #expect(text.contains("Expand context below"))
    }

    @Test func diffReviewFileSectionLoadsProviderAndRevealsExpandedContextRows() async throws {
        let probe = ContextProviderProbe(snapshot: DiffReviewFileContextSnapshot(
            old: .available((1...8).map { "old \($0)" }),
            new: .available((1...8).map { "new \($0)" })
        ))
        let controller = renderFileSection(file: providerBackedFile(provider: DiffReviewContextProvider {
            try await probe.snapshot()
        }))
        let ruler = try #require(allSubviews(of: controller.view).compactMap { $0 as? DiffPaneLineNumberRulerView }.first)

        ruler.invokeExpansionForTesting(row: 0, optionKey: false)

        let text = try await waitForRenderedText(in: controller.view, containing: "old 1")
        #expect(text.contains("old 2"))
        #expect(text.contains("old 3"))
        #expect(await probe.loadCount == 1)
    }

    @Test func diffReviewFileSectionQueuesExpansionClicksWhileProviderLoads() async throws {
        let probe = SuspendedContextProviderProbe()
        let controller = renderFileSection(file: providerBackedFile(provider: DiffReviewContextProvider {
            try await probe.snapshot()
        }))
        let ruler = try #require(allSubviews(of: controller.view).compactMap { $0 as? DiffPaneLineNumberRulerView }.first)

        ruler.invokeExpansionForTesting(row: 0, optionKey: false)
        try await waitForLoadCount(1, probe: probe)
        ruler.invokeExpansionForTesting(row: 2, optionKey: false)
        await probe.resolve(DiffReviewFileContextSnapshot(
            old: .available((1...8).map { "old \($0)" }),
            new: .available((1...8).map { "new \($0)" })
        ))

        let text = try await waitForRenderedText(in: controller.view, containing: "old 5")
        #expect(text.contains("old 1"))
        #expect(text.contains("old 2"))
        #expect(text.contains("old 3"))
        #expect(text.contains("old 5"))
        #expect(text.contains("old 8"))
        #expect(await probe.loadCount == 1)
    }

    @Test func diffReviewFileSectionIgnoresStaleContextLoadAfterResetForSameFile() async throws {
        let staleProbe = SuspendedContextProviderProbe()
        let freshProbe = SuspendedContextProviderProbe()
        let controller = renderAnyFileSection(file: providerBackedFile(provider: DiffReviewContextProvider {
            try await staleProbe.snapshot()
        }))
        let staleRuler = try #require(allSubviews(of: controller.view).compactMap { $0 as? DiffPaneLineNumberRulerView }.first)
        staleRuler.invokeExpansionForTesting(row: 0, optionKey: false)
        try await waitForLoadCount(1, probe: staleProbe)

        // A different path here (not the same file re-rendered) is deliberate:
        // the AppKit scroller pools row content by row ID and reuses it
        // whenever a row's equality token is unchanged, but that token has no
        // notion of "this is a different AppKitDiffReviewFileState instance" —
        // only DiffReviewFileID drives fresh row content. In production,
        // reusing a file ID reuses AppKitDiffReviewPresentationStore's cached
        // state for it (by design, so context stays loaded across re-renders);
        // a genuinely fresh session is always a new file ID. Reassigning
        // rootView with the *same* path here would silently keep serving the
        // stale row content built around staleProbe, not exercise a reset.
        controller.rootView = fileSectionView(file: providerBackedFile(
            path: "Sources/App/BetaView.swift",
            provider: DiffReviewContextProvider {
                try await freshProbe.snapshot()
            }
        ))
        controller.view.layoutSubtreeIfNeeded()

        let freshRuler = try #require(allSubviews(of: controller.view).compactMap { $0 as? DiffPaneLineNumberRulerView }.first)
        freshRuler.invokeExpansionForTesting(row: 2, optionKey: false)
        try await waitForLoadCount(1, probe: freshProbe)

        await staleProbe.resolve(DiffReviewFileContextSnapshot(
            old: .available((1...8).map { "stale \($0)" }),
            new: .available((1...8).map { "stale \($0)" })
        ))
        try await Task.sleep(nanoseconds: 25_000_000)
        await freshProbe.resolve(DiffReviewFileContextSnapshot(
            old: .available((1...8).map { "fresh \($0)" }),
            new: .available((1...8).map { "fresh \($0)" })
        ))

        // Not asserting on "fresh 8": the AppKit scroller virtualizes rows, so
        // the tail of an 8-line expansion isn't guaranteed to be materialized
        // in this viewport — the same reason the simpler
        // diffReviewFileSectionLoadsProviderAndRevealsExpandedContextRows only
        // checks up to "old 3", not "old 8".
        let text = try await waitForRenderedText(in: controller.view, containing: "fresh 5")
        #expect(!text.contains("stale"))
        #expect(await staleProbe.loadCount == 1)
        #expect(await freshProbe.loadCount == 1)
    }

    @Test func diffReviewFileSectionShowsContextProviderFailure() async throws {
        let controller = renderFileSection(file: providerBackedFile(provider: DiffReviewContextProvider {
            throw ContextProviderTestError.failed
        }))
        let ruler = try #require(allSubviews(of: controller.view).compactMap { $0 as? DiffPaneLineNumberRulerView }.first)

        ruler.invokeExpansionForTesting(row: 0, optionKey: false)

        let label = try await waitForAccessibilityLabel(
            in: controller.view,
            containing: "Could not load surrounding context: provider failed"
        )
        #expect(label?.contains("Could not load surrounding context: provider failed") == true)
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

    private func providerBackedFile(
        path: String = "Sources/App/AlphaView.swift",
        provider: DiffReviewContextProvider = DiffReviewContextProvider {
            DiffReviewFileContextSnapshot(
                old: .available((1...8).map { "old \($0)" }),
                new: .available((1...8).map { "new \($0)" })
            )
        }
    ) -> ReviewChangesFileSectionModel {
        let hunk = ParsedDiff.Hunk(
            header: "@@ -4,1 +4,1 @@",
            oldStart: 4,
            newStart: 4,
            lines: [
                .init(kind: .context, text: "line 4", oldNumber: 4, newNumber: 4),
            ]
        )
        let diff = ParsedDiff(hunks: [hunk])
        return ReviewChangesFileSectionModel(
            summary: reviewSummary(
                path: path,
                source: .unstaged,
                status: .modified,
                additions: 0,
                deletions: 0,
                isRenderable: true
            ),
            parsedDiff: diff,
            displayModel: DiffDisplayModelBuilder.build(diff: diff, filePath: path),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: provider
        )
    }

    private func renderFileSection(file: ReviewChangesFileSectionModel) -> NSHostingController<some View> {
        let controller = NSHostingController(rootView: fileSectionView(file: file))
        controller.view.frame = NSRect(x: 0, y: 0, width: 760, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func renderAnyFileSection(file: ReviewChangesFileSectionModel) -> NSHostingController<AnyView> {
        let controller = NSHostingController(rootView: fileSectionView(file: file))
        controller.view.frame = NSRect(x: 0, y: 0, width: 760, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func fileSectionView(file: ReviewChangesFileSectionModel) -> AnyView {
        AnyView(
            AppKitReviewChangesFileHarness(
                input: AppKitDiffReviewRowInput(
                    file: file,
                    state: AppKitDiffReviewFileState(),
                    theme: theme(),
                    codeFontFamily: ""
                )
            )
            .environment(\.theme, theme())
        )
    }

    private func renderedText(in view: NSView) -> String {
        allSubviews(of: view)
            .compactMap { ($0 as? NSTextView)?.string }
            .joined(separator: "\n")
    }

    private func waitForRenderedText(in view: NSView, containing needle: String) async throws -> String {
        var latest = renderedText(in: view)
        for _ in 0..<20 {
            if latest.contains(needle) {
                return latest
            }
            try await Task.sleep(nanoseconds: 25_000_000)
            view.layoutSubtreeIfNeeded()
            latest = renderedText(in: view)
        }
        return latest
    }

    private func waitForAccessibilityLabel(in view: NSView, containing needle: String) async throws -> String? {
        var latest = accessibilityLabel(in: view, containing: needle)
        for _ in 0..<20 {
            if latest != nil {
                return latest
            }
            try await Task.sleep(nanoseconds: 25_000_000)
            view.layoutSubtreeIfNeeded()
            latest = accessibilityLabel(in: view, containing: needle)
        }
        return latest
    }

    private func waitForLoadCount(_ expected: Int, probe: SuspendedContextProviderProbe) async throws {
        for _ in 0..<20 {
            if await probe.loadCount == expected {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(await probe.loadCount == expected)
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

    private actor ContextProviderProbe {
        private let snapshotValue: DiffReviewFileContextSnapshot
        private(set) var loadCount = 0

        init(snapshot: DiffReviewFileContextSnapshot) {
            self.snapshotValue = snapshot
        }

        func snapshot() async throws -> DiffReviewFileContextSnapshot {
            loadCount += 1
            return snapshotValue
        }
    }

    private actor SuspendedContextProviderProbe {
        private var continuation: CheckedContinuation<DiffReviewFileContextSnapshot, Error>?
        private(set) var loadCount = 0

        func snapshot() async throws -> DiffReviewFileContextSnapshot {
            loadCount += 1
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resolve(_ snapshot: DiffReviewFileContextSnapshot) {
            continuation?.resume(returning: snapshot)
            continuation = nil
        }
    }

    private enum ContextProviderTestError: LocalizedError {
        case failed

        var errorDescription: String? {
            "provider failed"
        }
    }
}

/// Mounts a single review file through the production AppKit stream, mirroring
/// the harness in DiffReviewSurfaceTests. The context-expansion tests here only
/// swap the plan's row IDs (new context rows appear), which forces the
/// reconciler through its full-rebuild path regardless of this bridge, but
/// keeping it makes the harness consistent with any future interaction-driven
/// assertions.
@MainActor
private final class ReviewChangesFileHarnessBridge: ObservableObject {
    private var cancellable: AnyCancellable?

    init(state: AppKitDiffReviewFileState) {
        cancellable = state.structuralDidChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

@MainActor
private struct AppKitReviewChangesFileHarness: View {
    let input: AppKitDiffReviewRowInput
    @StateObject private var bridge: ReviewChangesFileHarnessBridge

    init(input: AppKitDiffReviewRowInput) {
        self.input = input
        _bridge = StateObject(wrappedValue: ReviewChangesFileHarnessBridge(state: input.state))
    }

    var body: some View {
        AppKitDiffReviewScroller(
            inputs: [input],
            fileCommand: nil,
            inlineFeedbackCommand: nil,
            draftCommentCommand: nil,
            onNavigationFile: { _, _ in },
            onActiveFileChange: { _ in },
            onProgrammaticScrollCompletion: { _ in }
        )
    }
}
