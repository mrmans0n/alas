import Foundation
import Testing
@testable import Alas

@Suite("Attention navigation", .serialized)
@MainActor
struct AttentionNavigationTests {
    @Test func unrelatedPreparationNavigationDoesNotAcknowledgeReviewAttention() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.state.selectedWorktreeId = "worktree"
        let item = try fixture.record(.reviewRequest(number: 42))
        let draft = fixture.state.tabs.openOrFocusDraftCommit(worktreeId: "worktree", preferredAction: .commit)
        fixture.state.activateWorktreeCenterTab(worktreeId: "worktree", tabId: draft.id)
        #expect(fixture.state.attentionStore.acknowledgments[item.eventID] == nil)
        let changes = fixture.state.tabs.openOrFocusReviewChanges(worktreeId: "worktree")
        fixture.state.activateWorktreeCenterTab(worktreeId: "worktree", tabId: changes.id)
        #expect(fixture.state.attentionStore.acknowledgments[item.eventID] == nil)
    }

    @Test func ordinarySessionFocusAcknowledgesOnlyTheExactSession() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.state.selectedWorktreeId = "worktree"
        let first = fixture.state.tabs.appendACP(owner: .worktree("worktree"), sessionId: "s1", title: "First")
        _ = fixture.state.tabs.appendACP(owner: .worktree("worktree"), sessionId: "s2", title: "Second")
        let item = try fixture.record(.session(sessionID: "s1"))
        let other = try fixture.record(.session(sessionID: "s2"))
        fixture.state.activateWorktreeCenterTab(worktreeId: "worktree", tabId: first.id)
        #expect(fixture.state.attentionStore.acknowledgments[item.eventID] != nil)
        #expect(fixture.state.attentionStore.acknowledgments[other.eventID] == nil)
    }

    @Test func ordinaryFailureDetailsAcknowledgeMatchingFailure() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let failure = RunScriptFailure(id: "failure", runID: "run", scriptKey: "test", scriptName: "Tests", worktreeID: "worktree", branch: "main", exitCode: 1, completedAt: Date(), capturedOutput: .unavailable)
        fixture.state.runScriptFailureQueue.append(failure)
        let item = try fixture.record(.runScriptFailure(failureID: failure.id))
        fixture.state.presentRunScriptFailure(failure)
        #expect(fixture.state.attentionStore.acknowledgments[item.eventID] != nil)
    }

    @Test func ordinaryConflictFocusAcknowledgesOnlyAfterOpeningAnExistingConflict() throws {
        let fixture = try Fixture()
        defer { fixture.state.rightPaneStore.deactivate()
        fixture.cleanup() }
        fixture.state.selectedWorktreeId = "worktree"
        let pane = fixture.state.rightPaneStore.state(for: fixture.worktree, baseBranch: "", comparisonMode: fixture.state.config.changes.comparisonMode)
        let item = try fixture.record(.conflicts(path: "file.swift"))
        pane.openConflict?("missing.swift")
        #expect(fixture.state.attentionStore.acknowledgments[item.eventID] == nil)
        pane.changes = [ChangedFile(path: "file.swift", status: "U", stage: .unstaged, add: 0, del: 0, renameFrom: nil, conflict: .bothModified)]
        pane.openConflict?("file.swift")
        #expect(fixture.state.attentionStore.acknowledgments[item.eventID] != nil)
    }

    @Test func staleSyncBlockageDoesNotClaimTheRemoteIsStillAhead() {
        #expect(AttentionKind.reviewSyncBlocked.historicalTitle(from: "Remote branch is ahead") == "Remote branch was ahead")
    }

    @Test func refreshingLoadedReviewDoesNotReplayConsumedCommentJump() {
        var consumer = ReviewSessionCommentJumpConsumer()
        let file = DiffReviewFileID(namespace: "unstaged", path: "file.swift")
        let session = ReviewSessionID(rawValue: "review")
        let request = DiffReviewDraftCommentScrollCommand(commentID: "comment", fileID: file, generation: 1)
        #expect(consumer.consume(request, sessionID: session, isLoaded: false) == nil)
        #expect(consumer.consume(request, sessionID: session, isLoaded: true) == request)
        // A refresh must not emit another scroll command after the user moves elsewhere.
        #expect(consumer.consume(request, sessionID: session, isLoaded: false) == nil)
        #expect(consumer.consume(request, sessionID: session, isLoaded: true) == nil)
        let repeated = DiffReviewDraftCommentScrollCommand(commentID: "comment", fileID: file, generation: 2)
        #expect(consumer.consume(repeated, sessionID: session, isLoaded: true) == repeated)
        #expect(consumer.consume(repeated, sessionID: session, isLoaded: true) == nil)
        #expect(consumer.consume(request, sessionID: .init(rawValue: "another-review"), isLoaded: true) == request)
    }

    @Test(arguments: ["selection", "close", "delete", "overlap"])
    func suspendedNavigationDoesNotAcknowledgeAnAbandonedDestination(change: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let item = try fixture.record(.conflicts(path: nil))
        let other = try fixture.record(.session(sessionID: "s2"))
        var environment = AttentionNavigationEnvironment.live(appState: fixture.state)
        environment.focusSession = { _, _ in true }
        environment.revealRightPane = { _, _ in
            await Task.yield()
            switch change {
            case "selection": fixture.state.selectedWorktreeId = "elsewhere"
            case "close": fixture.state.closeAttentionInbox()
            case "delete": fixture.state.projectsManager = ProjectsManager(persistedProjects: [])
            default: _ = await fixture.state.openAttentionItem(other)
            }
            return true
        }
        fixture.state.attentionNavigationEnvironment = environment
        fixture.state.openAttentionInbox()
        let result = await fixture.state.openAttentionItem(item)
        #expect(result != .opened)
        #expect(fixture.state.attentionStore.acknowledgments[item.eventID] == nil)
        if change == "selection" {
            #expect(fixture.state.selectedWorktreeId == "elsewhere")
            #expect(fixture.state.isAttentionInboxOpen)
        }
        if change == "overlap" { #expect(fixture.state.attentionStore.acknowledgments[other.eventID] != nil) }
    }

    @Test func attentionRevealResetsOnTabChangeAndExplicitReturn() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let pane = RightPaneState(worktree: fixture.worktree, baseBranch: "main")
        pane.changes = [ChangedFile(path: "file.swift", status: "U", stage: .unstaged, add: 0, del: 0, renameFrom: nil, conflict: .bothModified)]
        #expect(pane.revealAttentionTarget(.conflicts(path: nil)))
        pane.activeTab = .files
        #expect(pane.attentionRevealedTarget == nil)
        #expect(pane.attentionScrollRequest == nil)
        #expect(pane.revealAttentionTarget(.conflicts(path: nil)))
        pane.endAttentionReveal()
        #expect(pane.attentionRevealedTarget == nil)
        #expect(pane.attentionScrollRequest == nil)
    }

    @Test func attentionRevealDoesNotSurviveLeavingItsWorktree() throws {
        let fixture = try Fixture()
        defer { fixture.state.rightPaneStore.deactivate()
        fixture.cleanup() }
        fixture.state.selectedWorktreeId = fixture.worktree.id
        let pane = fixture.state.rightPaneStore.state(for: fixture.worktree, baseBranch: "", comparisonMode: fixture.state.config.changes.comparisonMode)
        pane.changes = [ChangedFile(path: "file.swift", status: "U", stage: .unstaged, add: 0, del: 0, renameFrom: nil, conflict: .bothModified)]
        #expect(pane.revealAttentionTarget(.conflicts(path: nil)))
        fixture.state.selectedWorktreeId = "elsewhere"
        #expect(pane.attentionRevealedTarget == nil)
        #expect(pane.attentionScrollRequest == nil)
    }

    @Test func initialAndRepeatedReviewCommentJumpsHaveFreshScrollCommands() {
        let target = ReviewSessionTarget.localChanges(worktreeID: "worktree", repositoryPath: URL(fileURLWithPath: "/repo"), scope: .all)
        let fileID = DiffReviewFileID(namespace: "unstaged", path: "file.swift")
        let record = ReviewSessionRecord(id: .init(rawValue: "review-record"), target: target, selectedFileID: fileID, focusedCommentID: "comment2", createdAt: Date(), updatedAt: Date())
        let tabs = TabsManager(store: MemoryStore())
        let first = tabs.openOrFocusReviewSession(worktreeId: "worktree", record: record)
        let second = tabs.openOrFocusReviewSession(worktreeId: "worktree", record: record)
        guard case .reviewSession(let initial) = first, case .reviewSession(let repeated) = second else {
            Issue.record("Expected review session tabs")
            return
        }
        #expect(initial.commentScrollRequest?.commentID == "comment2")
        #expect(initial.commentScrollRequest?.fileID == fileID)
        #expect(repeated.commentScrollRequest?.commentID == "comment2")
        #expect(initial.commentScrollRequest != repeated.commentScrollRequest)
        var refreshed = repeated
        refreshed.retarget(to: record)
        #expect(refreshed.commentScrollRequest == nil)
        refreshed.requestCommentScroll()
        #expect(refreshed.commentScrollRequest != repeated.commentScrollRequest)
    }

    @Test(arguments: [true, false])
    func exactTargetsAcknowledgeOnlyAfterSuccessfulNavigation(succeeds: Bool) async throws {
        let targets: [AttentionJumpTarget] = [
            .session(sessionID: "s2"), .runScriptFailure(failureID: "failure2"),
            .conflicts(path: "file.swift"), .gitOperation, .reviewRequest(number: 42),
            .reviewComment(sessionID: "review2", commentID: "comment2"), .remoteWorktree,
        ]
        for target in targets {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            var routed: AttentionJumpTarget?
            fixture.state.attentionNavigationEnvironment = .init(
                focusSession: { _, id in routed = .session(sessionID: id)
                return succeeds },
                presentScriptFailure: { _, id in routed = .runScriptFailure(failureID: id)
                return succeeds },
                revealRightPane: { _, target in routed = target
                return succeeds },
                focusReviewComment: { _, session, comment in
                    routed = .reviewComment(sessionID: session, commentID: comment)
                    return succeeds
                },
                focusRemoteWorktree: { _ in routed = .remoteWorktree
                return succeeds }
            )
            let item = try fixture.record(target)
            let other = try fixture.record(.session(sessionID: "s1"))
            fixture.state.openAttentionInbox()
            #expect(fixture.state.attentionStore.acknowledgments.isEmpty)
            let result = await fixture.state.openAttentionItem(item)
            #expect(routed == target)
            #expect((result == .opened) == succeeds)
            #expect((fixture.state.attentionStore.acknowledgments[item.eventID] != nil) == succeeds)
            #expect(fixture.state.attentionStore.acknowledgments[other.eventID] == nil)
            #expect(fixture.state.isAttentionInboxOpen == !succeeds)
            #expect((fixture.state.attentionNavigationErrors[item.eventID] != nil) == !succeeds)
        }
    }

    @Test func deletedWorktreeDoesNotNavigateOrAcknowledge() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let item = try fixture.record(.session(sessionID: "missing"))
        fixture.state.projectsManager = ProjectsManager(persistedProjects: [])
        let result = await fixture.state.openAttentionItem(item)
        #expect(result == .unavailable("The worktree is no longer available."))
        #expect(fixture.state.attentionStore.acknowledgments[item.eventID] == nil)
    }

    @Test func resolvesCurrentOwnerInsteadOfUsingStaleRowWorktree() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let item = try fixture.record(.session(sessionID: "s2"))
        let moved = Worktree(id: "renamed", projectId: "project", name: "new", branch: "new", path: URL(fileURLWithPath: "/renamed"), status: .clean, lastActivity: Date(), lineageID: "lineage")
        let project = try #require(fixture.state.projects.first)
        fixture.state.attentionStore.registerAlias(from: item.owner, to: .make(worktree: moved, project: project))
        fixture.state.projectsManager = ProjectsManager(persistedProjects: [project])
        fixture.state.projectsManager.insertOptimisticWorktree(moved)
        var routedID: String?
        var environment = AttentionNavigationEnvironment.live(appState: fixture.state)
        environment.focusSession = { item, _ in routedID = item.worktree?.id
        return true }
        fixture.state.attentionNavigationEnvironment = environment
        #expect(await fixture.state.openAttentionItem(item) == .opened)
        #expect(routedID == "renamed")
        #expect(fixture.state.selectedWorktreeId == "renamed")
    }

    @Test func liveSessionRouteSelectsExactTabAndMissingSessionDoesNotClear() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = fixture.state.tabs.appendACP(owner: .worktree("worktree"), sessionId: "s1", title: "First")
        let second = fixture.state.tabs.appendACP(owner: .worktree("worktree"), sessionId: "s2", title: "Second")
        let item = try fixture.record(.session(sessionID: "s2"))
        let result = await fixture.state.openAttentionItem(item)
        #expect(result == .opened)
        #expect(fixture.state.tabs.activeTabId(forWorktree: "worktree") == second.id)
        let missing = try fixture.record(.session(sessionID: "missing"))
        let unavailable = await fixture.state.openAttentionItem(missing)
        #expect(unavailable == .unavailable("The session is no longer available."))
        #expect(fixture.state.attentionStore.acknowledgments[missing.eventID] == nil)
    }

    @Test func conflictsRequireExistingPathAndRequestVisibleSection() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let pane = RightPaneState(worktree: fixture.worktree, baseBranch: "main")
        pane.activeTab = .files
        #expect(!pane.revealAttentionTarget(.conflicts(path: nil)))
        pane.changes = [ChangedFile(path: "file.swift", status: "U", stage: .unstaged, add: 0, del: 0, renameFrom: nil, conflict: .bothModified)]
        #expect(!pane.revealAttentionTarget(.conflicts(path: "gone.swift")))
        #expect(pane.revealAttentionTarget(.conflicts(path: "file.swift")))
        #expect(pane.activeTab == .changes)
        #expect(pane.attentionScrollRequest?.targetID == "changes-conflicts")
        #expect(!pane.revealAttentionTarget(.gitOperation))
        #expect(!pane.revealAttentionTarget(.reviewRequest(number: 42)))
    }

    @Test func liveScriptRouteRequiresTheMatchingQueuedFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let failure = RunScriptFailure(id: "failure2", runID: "run2", scriptKey: "test", scriptName: "Tests", worktreeID: "worktree", branch: "main", exitCode: 1, completedAt: Date(), capturedOutput: .unavailable)
        fixture.state.runScriptFailureQueue.append(failure)
        let item = try fixture.record(.runScriptFailure(failureID: "failure2"))
        #expect(await fixture.state.openAttentionItem(item) == .opened)
        #expect(fixture.state.selectedRunScriptFailure?.id == "failure2")
        let missing = try fixture.record(.runScriptFailure(failureID: "missing"))
        #expect(await fixture.state.openAttentionItem(missing) == .unavailable("The script failure is no longer available."))
        #expect(fixture.state.attentionStore.acknowledgments[missing.eventID] == nil)
    }

    @Test(arguments: [true, false])
    func liveReviewRouteWaitsForConfirmedCommentReveal(succeeds: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sessions = ReviewSessionStore(url: fixture.directory.appendingPathComponent("reviews.json"))
        let comments = ReviewDraftCommentStore(url: fixture.directory.appendingPathComponent("comments.json"))
        let target = ReviewSessionTarget.localChanges(worktreeID: "worktree", repositoryPath: fixture.worktree.path, scope: .all)
        let record = ReviewSessionRecord(id: .init(rawValue: "review-record"), target: target, createdAt: Date(), updatedAt: Date())
        try sessions.save(record)
        let fileID = DiffReviewFileID(namespace: "unstaged", path: "file.swift")
        let comment = ReviewDraftComment(id: "comment2", sessionID: target.draftSessionID, fileID: fileID, path: "file.swift", anchor: .file, bodyMarkdown: "Feedback", state: .active, createdAt: Date(), updatedAt: Date())
        try comments.save(comment)
        fixture.state.attentionNavigationEnvironment = .live(appState: fixture.state, reviewSessionStore: sessions, reviewCommentStore: comments)
        let item = try fixture.record(.reviewComment(sessionID: target.draftSessionID.rawValue, commentID: "comment2"))
        #expect(await fixture.state.openAttentionItem(item) != .opened)
        #expect(fixture.state.attentionStore.acknowledgments[item.eventID] == nil)
        let tab = try #require(fixture.state.tabs.tabs(forWorktree: "worktree").first)
        guard case .reviewSession(let session) = tab else { Issue.record("Expected review tab")
        return }
        #expect(session.sessionID.rawValue == "review-record")
        #expect(session.focusedCommentID == "comment2")
        #expect(session.selectedFileID == fileID)
        let command = try #require(session.commentScrollRequest)
        fixture.state.completeReviewAttentionReveal(worktreeID: "worktree", tabID: tab.id,
            sessionID: target.draftSessionID.rawValue, command: command, succeeded: succeeds)
        #expect((fixture.state.attentionStore.acknowledgments[item.eventID] != nil) == succeeds)
        #expect((fixture.state.attentionNavigationErrors[item.eventID] != nil) == !succeeds)
        let missing = try fixture.record(.reviewComment(sessionID: target.draftSessionID.rawValue, commentID: "missing"))
        #expect(await fixture.state.openAttentionItem(missing) == .unavailable("The review comment is no longer available."))
        #expect(fixture.state.attentionStore.acknowledgments[missing.eventID] == nil)
    }

    @Test func reviewRevealDoesNotAcknowledgeReplyArrivingDuringScroll() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.state.selectedWorktreeId = "worktree"
        let tab = fixture.state.tabs.appendACP(owner: .worktree("worktree"), sessionId: "placeholder", title: "Review")
        let target = AttentionJumpTarget.reviewComment(sessionID: "review", commentID: "comment")
        let first = try fixture.record(target)
        let command = DiffReviewDraftCommentScrollCommand(commentID: "comment", fileID: .init(namespace: "unstaged", path: "file.swift"), generation: 1)
        fixture.state.beginReviewAttentionInteraction(worktreeID: "worktree", tabID: tab.id, sessionID: "review", command: command)
        let newer = try fixture.record(target)
        fixture.state.completeReviewAttentionReveal(worktreeID: "worktree", tabID: tab.id, sessionID: "review", command: command, succeeded: true)
        #expect(fixture.state.attentionStore.acknowledgments[first.eventID] != nil)
        #expect(fixture.state.attentionStore.acknowledgments[newer.eventID] == nil)
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    @MainActor private struct Fixture {
        let state: AppState
        let worktree: Worktree
        let directory: URL
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            state = AppState(store: MemoryStore(), tabsManager: TabsManager(store: MemoryStore()), attentionStore: AttentionStore(url: directory.appendingPathComponent("attention.json")))
            let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: Date())
            worktree = Worktree(id: "worktree", projectId: "project", name: "main", branch: "main", path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: Date())
            state.projectsManager = ProjectsManager(persistedProjects: [project])
            state.projectsManager.insertOptimisticWorktree(worktree)
        }
        func record(_ target: AttentionJumpTarget) throws -> AttentionItem {
            let context = try #require(state.attentionContext(for: worktree))
            state.observeAttention(.active(.init(sourceKey: .init(rawValue: UUID().uuidString), fingerprint: "active", owner: context.owner, kind: .agentAwaiting, title: "Needs attention", body: nil, jumpTarget: target, display: context.display)))
            let id = try #require(state.attentionStore.events.last?.id)
            return try #require(state.attentionAggregation.items.first { $0.eventID == id })
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }
}
