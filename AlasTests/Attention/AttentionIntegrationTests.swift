import Foundation
import Testing
@testable import Alas

@Suite("Attention integration", .serialized)
@MainActor
struct AttentionIntegrationTests {
    @Test func repeatedSnapshotsPreserveAcknowledgmentsAndChangedConflictsCreateNewOccurrence() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.state
        let snapshot = RightPaneAttentionSnapshot(mergeOperation: nil, conflictedPaths: ["a.swift"], review: review())
        state.observeRightPaneAttention(worktreeID: "one", snapshot: snapshot)
        state.observeRightPaneAttention(worktreeID: "one", snapshot: snapshot)
        #expect(state.attentionStore.events.filter { $0.kind == .conflicts }.count == 1)
        #expect(state.attentionStore.events.filter { $0.kind == .failedChecks }.count == 1)
        for event in state.attentionStore.events { state.attentionStore.acknowledge(eventID: event.id, at: Date()) }
        state.observeRightPaneAttention(worktreeID: "one", snapshot: snapshot)
        #expect(state.attentionAggregation.unresolvedCount == 0)
        state.observeRightPaneAttention(worktreeID: "one", snapshot: .init(mergeOperation: nil, conflictedPaths: ["b.swift"], review: review()))
        #expect(state.attentionAggregation.unresolvedCount == 1)
        #expect(state.attentionStore.events.filter { $0.kind == .conflicts }.count == 2)
    }

    @Test func hostTransitionsAreDeduplicatedAndAttributedToEveryWorktree() throws {
        let fixture = try Fixture(host: "mini")
        defer { fixture.cleanup() }
        let time = Date(timeIntervalSince1970: 123)
        let hosts = RemoteHostStatusStore(now: { time })
        var transitions: [Bool] = []
        hosts.onStatusTransition = { host, offline, date in
            transitions.append(offline)
            fixture.state.observeHostAttention(host: host, isDisconnected: offline, at: date)
        }
        hosts.reportConnectionFailure(host: "mini")
        #expect(fixture.state.attentionStore.events.isEmpty)
        hosts.reportConnectionFailure(host: "mini")
        hosts.reportConnectionFailure(host: "mini")
        #expect(transitions == [true])
        #expect(fixture.state.attentionStore.events.count == 2)
        #expect(Set(fixture.state.attentionStore.events.map(\.owner.legacyPath)) == ["/repo/one", "/repo/two"])
        #expect(fixture.state.attentionStore.events.allSatisfy { $0.occurredAt == time })
        hosts.reportSuccess(host: "mini")
        hosts.reportSuccess(host: "mini")
        #expect(transitions == [true, false])
        #expect(fixture.state.attentionStore.document.observations.values.allSatisfy { !$0.isActive })
        hosts.reportConnectionFailure(host: "mini")
        hosts.reportConnectionFailure(host: "mini")
        #expect(fixture.state.attentionStore.events.count == 4)
    }

    @Test func sameReviewRequestOnTwoWorktreesHasIndependentAttention() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for id in ["one", "two"] {
            fixture.state.observeRightPaneAttention(worktreeID: id, snapshot: .init(mergeOperation: nil, conflictedPaths: [], review: review()))
        }
        #expect(fixture.state.attentionStore.events.count == 2)
    }

    @Test func unavailableProviderDoesNotResurrectAcknowledgedReviewFailure() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let failed = review()
        fixture.state.observeRightPaneAttention(worktreeID: "one", snapshot: .init(mergeOperation: nil, conflictedPaths: [], review: failed))
        let event = try #require(fixture.state.attentionStore.events.first)
        fixture.state.attentionStore.acknowledge(eventID: event.id, at: Date())
        let unavailable = ReviewLoopSnapshot(local: failed.local, remote: failed.remote, reviewRequest: nil, providerAvailable: false, providerAuthenticated: false, providerCapabilities: .githubCLI, errorMessage: "Provider unavailable")
        fixture.state.observeRightPaneAttention(worktreeID: "one", snapshot: .init(mergeOperation: nil, conflictedPaths: [], review: unavailable))
        fixture.state.observeRightPaneAttention(worktreeID: "one", snapshot: .init(mergeOperation: nil, conflictedPaths: [], review: nil))
        fixture.state.observeRightPaneAttention(worktreeID: "one", snapshot: .init(mergeOperation: nil, conflictedPaths: [], review: failed))
        #expect(fixture.state.attentionStore.events.count == 1)
        #expect(fixture.state.attentionAggregation.unresolvedCount == 0)
    }

    @Test func firstSuccessAfterRelaunchEndsPersistedDisconnection() throws {
        let fixture = try Fixture(host: "mini")
        defer { fixture.cleanup() }
        fixture.state.observeHostAttention(host: "mini", isDisconnected: true)
        for event in fixture.state.attentionStore.events {
            fixture.state.attentionStore.acknowledge(eventID: event.id, at: Date())
        }
        let relaunched = AppState(store: MemoryStore(), attentionStore: AttentionStore(url: fixture.directory.appendingPathComponent("events.json")))
        relaunched.projectsManager = fixture.state.projectsManager
        let hosts = RemoteHostStatusStore()
        hosts.onStatusTransition = { host, offline, date in
            relaunched.observeHostAttention(host: host, isDisconnected: offline, at: date)
        }
        hosts.reportSuccess(host: "mini")
        hosts.reportSuccess(host: "mini")
        #expect(relaunched.attentionStore.document.observations.values.allSatisfy { !$0.isActive })
        hosts.reportConnectionFailure(host: "mini")
        hosts.reportConnectionFailure(host: "mini")
        #expect(relaunched.attentionStore.events.count == 4)
        #expect(relaunched.attentionAggregation.unresolvedCount == 2)
    }

    @Test func feedbackAndRemoteDivergenceAreIndependentAndNoRequestEndsLiveOccurrence() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let snapshot = RightPaneAttentionSnapshot(mergeOperation: nil, conflictedPaths: [], review: review(decision: .changesRequested, upstreamAhead: 2, needsPush: true))
        fixture.state.observeRightPaneAttention(worktreeID: "one", snapshot: snapshot)
        #expect(Set(fixture.state.attentionStore.events.map(\.kind)) == [.failedChecks, .actionableFeedback, .reviewSyncBlocked])
        let prior = try #require(snapshot.review)
        let removed = ReviewLoopSnapshot(local: prior.local, remote: prior.remote, reviewRequest: nil, providerAvailable: true, providerAuthenticated: true, providerCapabilities: .githubCLI, errorMessage: nil)
        fixture.state.observeRightPaneAttention(worktreeID: "one", snapshot: .init(mergeOperation: nil, conflictedPaths: [], review: removed))
        #expect(fixture.state.attentionStore.document.observations.values.allSatisfy { !$0.isActive })
        #expect(fixture.state.attentionAggregation.unresolvedCount == 3)
    }

    @Test func persistedAgentReplyUsesCommentOwnerAndAcknowledgmentSurvivesRepeat() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let worktrees = fixture.state.attentionWorktrees.map(\.worktree)
        let origin = try #require(worktrees.first { $0.id == "one" })
        let target = try #require(worktrees.first { $0.id == "two" })
        let store = ReviewDraftCommentStore(url: fixture.directory.appendingPathComponent("comments.json"))
        let comment = ReviewDraftComment(id: "comment", sessionID: .localChanges(worktreeID: target.id, worktreePath: target.path, scope: .all), fileID: DiffReviewFileID(namespace: "review", path: "a.swift"), path: "a.swift", originalPath: nil, side: .new, startLine: 1, endLine: nil, selectedText: nil, bodyMarkdown: "Fix", state: .active, createdAt: .distantPast, updatedAt: .distantPast)
        try store.save(comment)
        var callbacks = 0
        let service = AlasActionService(visibleWorktrees: { worktrees }, openRelativeFile: { _, _ in }, openExternalFile: { _, _ in }, draftCommentStore: { store }, reviewSessionStore: { ReviewSessionStore(url: fixture.directory.appendingPathComponent("sessions.json")) }, notifyReviewCommentsChanged: {}, notifyReviewReplyAdded: { worktree, updated, reply in
            callbacks += 1
            #expect(worktree.id == "two")
            #expect((try? store.find(commentID: "comment"))?.allReplies.last?.id == reply.id)
            fixture.state.observeReviewReplyAttention(worktree: worktree, comment: updated, reply: reply)
        }, activateApp: {})
        _ = service.reviewReply(origin: origin, commentID: comment.id, body: "Done", projectWorktrees: worktrees)
        #expect(callbacks == 1)
        let event = try #require(fixture.state.attentionStore.events.first)
        #expect(event.owner.legacyPath == "/repo/two")
        fixture.state.attentionStore.acknowledge(eventID: event.id, at: Date())
        let updated = try #require(store.find(commentID: comment.id))
        fixture.state.observeReviewReplyAttention(worktree: target, comment: updated, reply: try #require(updated.allReplies.last))
        #expect(fixture.state.attentionAggregation.unresolvedCount == 0)
        var answered = updated
        let userReply = ReviewCommentReply(id: "user-reply", author: .user, bodyMarkdown: "Thanks", createdAt: Date().addingTimeInterval(1))
        answered.replies = updated.allReplies + [userReply]
        fixture.state.observeReviewReplyAttention(worktree: target, comment: answered, reply: userReply)
        #expect(fixture.state.attentionStore.document.observations[event.sourceKey]?.isActive == false)
        fixture.state.observeReviewReplyAttention(worktree: target, comment: updated, reply: try #require(updated.allReplies.last))
        #expect(fixture.state.attentionAggregation.unresolvedCount == 0)
        _ = service.reviewResolve(origin: origin, commentID: comment.id, reply: "Resolved", reopen: false, projectWorktrees: worktrees)
        #expect(callbacks == 2)
        #expect(fixture.state.attentionStore.events.count == 1)
        _ = service.reviewReply(origin: origin, commentID: "missing", body: "No", projectWorktrees: worktrees)
        #expect(callbacks == 2)
    }

    private func review(decision: ReviewDecision = .approved, upstreamAhead: Int = 0, needsPush: Bool = false) -> ReviewLoopSnapshot {
        let remote = CodeHostRemote(kind: .github, host: "github.com", owner: "owner", repository: "repo", remoteName: "origin", webURL: URL(string: "https://github.com/owner/repo")!)
        let request = ReviewRequest(remote: remote, number: 42, title: "Review", url: remote.webURL, state: .open, isDraft: false, headRefName: "feature", baseRefName: "main", headSHA: "head", reviewDecision: decision, mergeState: .clean, checks: [ReviewCheck(id: "ci", name: "CI", workflow: nil, bucket: .fail, detailURL: nil, completedAt: nil)], threads: [])
        return ReviewLoopSnapshot(local: ReviewLoopLocalState(branchName: "feature", headSHA: "head", baseBranch: "main", hasWorkingTreeChanges: false, hasStagedChanges: false, aheadCommitCount: 0, hasUpstream: true, upstreamAheadCommitCount: upstreamAhead, needsPush: needsPush), remote: remote, reviewRequest: request, providerAvailable: true, providerAuthenticated: true, providerCapabilities: .githubCLI, errorMessage: nil)
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    @MainActor
    private struct Fixture {
        let state: AppState
        let directory: URL
        init(host: String? = nil) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            state = AppState(store: MemoryStore(), attentionStore: AttentionStore(url: directory.appendingPathComponent("events.json")))
            var project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: Date())
            project.host = host
            state.projectsManager = ProjectsManager(persistedProjects: [project])
            for id in ["one", "two"] {
                state.projectsManager.insertOptimisticWorktree(Worktree(id: id, projectId: project.id, name: id, branch: id, path: URL(fileURLWithPath: "/repo/\(id)"), status: .clean, lastActivity: Date()))
            }
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }
}
