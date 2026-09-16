import Foundation
import Testing
@testable import Alas

@Suite("AppState attention", .serialized)
@MainActor
struct AppStateAttentionTests {
    @Test func recoveredHistorySuppressesOnlyInitialRightPaneSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("broken history".utf8).write(to: fixture.url)
        let state = fixture.makeStateWithWorktree()
        let conflicts = RightPaneAttentionSnapshot(mergeOperation: nil, conflictedPaths: ["file.swift"], review: nil)
        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: conflicts)
        #expect(state.attentionStore.events.isEmpty)
        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: .init(mergeOperation: nil, conflictedPaths: [], review: nil))
        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: conflicts)
        #expect(state.attentionStore.events.count == 1)
        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: conflicts)
        #expect(state.attentionStore.events.count == 1)
    }

    @Test func recoveredHistoryKeepsShrinkingStartupConflictsSuppressed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("broken history".utf8).write(to: fixture.url)
        let state = fixture.makeStateWithWorktree()
        let first = RightPaneAttentionSnapshot(mergeOperation: nil, conflictedPaths: ["a.swift", "b.swift"], review: nil)
        let shrunk = RightPaneAttentionSnapshot(mergeOperation: nil, conflictedPaths: ["b.swift"], review: nil)
        let expanded = RightPaneAttentionSnapshot(mergeOperation: nil, conflictedPaths: ["b.swift", "c.swift"], review: nil)

        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: first)
        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: shrunk)
        #expect(state.attentionStore.events.isEmpty)

        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: expanded)

        #expect(state.attentionStore.events.count == 1)
        #expect(state.attentionStore.events.first?.fingerprint == "7:b.swift7:c.swift")
    }

    @Test func successfulReviewSnapshotClosesPrunedActiveObservation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(maxEvents: 0)
        let clean = RightPaneAttentionSnapshot(mergeOperation: nil, conflictedPaths: [], review: fixture.review(hasRequest: false))
        let failed = RightPaneAttentionSnapshot(mergeOperation: nil, conflictedPaths: [], review: fixture.review())

        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: clean)
        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: failed)
        #expect(state.attentionStore.events.isEmpty)
        #expect(state.attentionStore.document.observations.values.contains { $0.isActive })

        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: clean)

        #expect(state.attentionStore.events.isEmpty)
        #expect(state.attentionStore.document.observations.values.allSatisfy { !$0.isActive })
    }

    @Test func successfulReviewSnapshotClosesAliasMigratedObservationAfterEventPrune() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(lineageID: "lineage", maxEvents: 0)
        let project = try #require(state.projects.first)
        let worktree = try #require(state.attentionWorktrees.first?.worktree)
        let legacyOwner = AttentionWorktreeIdentity(projectID: project.id, location: .local, lineageID: nil, legacyPath: worktree.path.path)
        let currentOwner = AttentionWorktreeIdentity.make(worktree: worktree, project: project)
        let display = AttentionWorktree(worktree: worktree, project: project).resolved.display
        let signal = try #require(AttentionProducer.review(snapshot: fixture.review(), owner: legacyOwner, display: display).compactMap(\.activeSignal).first)
        state.attentionStore.observe(.active(signal), at: fixture.now)

        _ = state.attentionAggregation
        let migratedKey = AttentionSourceKey(rawValue: signal.sourceKey.rawValue.replacingOccurrences(of: legacyOwner.storageKey, with: currentOwner.storageKey))
        #expect(state.attentionStore.events.isEmpty)
        #expect(state.attentionStore.document.observations[migratedKey]?.isActive == true)

        state.observeRightPaneAttention(
            worktreeID: "worktree",
            snapshot: RightPaneAttentionSnapshot(mergeOperation: nil, conflictedPaths: [], review: fixture.review(hasRequest: false))
        )

        // With maxEvents: 0 the tombstone budget is also zero, so the
        // deactivated observation is pruned outright rather than retained as
        // an explicit `false` entry. No caller distinguishes "absent" from
        // "stored inactive" (attentionObservationMatchesStored treats both
        // as already-matching), so `!= true` is the behaviorally meaningful
        // assertion here.
        #expect(state.attentionStore.document.observations[migratedKey]?.isActive != true)
    }

    @Test func incompleteReviewThreadSnapshotDoesNotCloseMissingFeedbackObservation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree()
        let active = RightPaneAttentionSnapshot(
            mergeOperation: nil,
            conflictedPaths: [],
            review: fixture.review(decision: .approved, threads: [fixture.thread(id: "thread-a")])
        )
        let incomplete = RightPaneAttentionSnapshot(
            mergeOperation: nil,
            conflictedPaths: [],
            review: fixture.review(decision: .approved, threads: [], areThreadsComplete: false)
        )
        let complete = RightPaneAttentionSnapshot(
            mergeOperation: nil,
            conflictedPaths: [],
            review: fixture.review(decision: .approved, threads: [], areThreadsComplete: true)
        )

        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: active, at: fixture.now)
        let feedbackKey = try #require(state.attentionStore.events.first { $0.kind == .actionableFeedback }?.sourceKey)

        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: incomplete, at: fixture.now.addingTimeInterval(1))

        #expect(state.attentionStore.document.observations[feedbackKey]?.isActive == true)
        #expect(state.attentionStore.events.filter { $0.kind == .actionableFeedback }.count == 1)
        #expect(state.attentionAggregation.items.isEmpty)
        #expect(state.attentionAggregation.history.first { $0.sourceKey == feedbackKey }?.presentation == .unverified)

        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: complete, at: fixture.now.addingTimeInterval(2))

        #expect(state.attentionStore.document.observations[feedbackKey]?.isActive == false)
        #expect(state.attentionAggregation.history.first { $0.sourceKey == feedbackKey }?.presentation == .historical)
    }

    @Test func incompleteReviewThreadSnapshotClosesOtherRequestFeedbackObservation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree()
        let oldRequest = RightPaneAttentionSnapshot(
            mergeOperation: nil,
            conflictedPaths: [],
            review: fixture.review(number: 41, decision: .approved, threads: [fixture.thread(id: "thread-a")])
        )
        let currentIncompleteRequest = RightPaneAttentionSnapshot(
            mergeOperation: nil,
            conflictedPaths: [],
            review: fixture.review(number: 42, decision: .changesRequested, threads: [], areThreadsComplete: false)
        )

        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: oldRequest, at: fixture.now)
        let feedbackKey = try #require(state.attentionStore.events.first { $0.kind == .actionableFeedback }?.sourceKey)

        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: currentIncompleteRequest, at: fixture.now.addingTimeInterval(1))

        #expect(state.attentionStore.document.observations[feedbackKey]?.isActive == false)
    }

    @Test func recoveredHistoryKeepsFeedbackUninitializedUntilThreadsAreComplete() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("broken history".utf8).write(to: fixture.url)
        let state = fixture.makeStateWithWorktree()
        let incomplete = RightPaneAttentionSnapshot(
            mergeOperation: nil,
            conflictedPaths: [],
            review: fixture.review(decision: .changesRequested, threads: [], areThreadsComplete: false)
        )
        let completeWithFeedback = RightPaneAttentionSnapshot(
            mergeOperation: nil,
            conflictedPaths: [],
            review: fixture.review(decision: .approved, threads: [fixture.thread(id: "thread-a")], areThreadsComplete: true)
        )

        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: incomplete, at: fixture.now)
        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: completeWithFeedback, at: fixture.now.addingTimeInterval(1))

        #expect(state.attentionStore.events.isEmpty)
        #expect(state.attentionSuppressedStartupSignals.values.contains { $0.contains("thread-a") })
    }

    @Test func acpCompletionRecordsFinishedHistoryButRemovalDoesNot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree()
        let bridge = ACPHarnessBridge(harness: state.harness)
        let session = ACPSession(id: "acp", agentId: "claude", worktreeId: "worktree", title: "Agent")
        session.agentState = .ready
        _ = state.tabs.appendACP(owner: .worktree("worktree"), sessionId: session.id, title: "Agent")
        bridge.observe(session: session)
        #expect(state.attentionStore.events.isEmpty)

        session.transcript.streamingState = .streaming
        session.transcript.streamingState = .idle
        session.transcript.streamingState = .idle
        #expect(state.attentionStore.events.map(\.kind) == [.agentFinished])
        #expect(state.harness.activityBySession[session.id] == nil)

        session.transcript.streamingState = .streaming
        session.agentState = .idle
        session.transcript.streamingState = .idle
        #expect(state.attentionStore.events.map(\.kind) == [.agentFinished])

        session.agentState = .ready
        session.transcript.streamingState = .streaming
        bridge.forget(sessionId: session.id)
        #expect(state.attentionStore.events.map(\.kind) == [.agentFinished])
        #expect(state.harness.activityBySession[session.id] == nil)
    }

    @Test func dismissAttentionItemAcknowledgesAndClearsNavigationError() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree()
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, requiresUserInput: true)
        let item = try #require(state.attentionAggregation.items.first)
        state.attentionNavigationErrors[item.eventID] = "The session is no longer available."

        state.dismissAttentionItem(item)

        #expect(state.attentionStore.acknowledgments[item.eventID] != nil)
        #expect(state.attentionNavigationErrors[item.eventID] == nil)
        #expect(state.attentionAggregation.unresolvedCount == 0)
        #expect(state.attentionAggregation.history.contains { $0.eventID == item.eventID })
    }

    @Test func dismissAllAttentionItemsAcknowledgesEveryActiveItem() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree()
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent 2", sessionId: "other")
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, requiresUserInput: true)
        state.harness.setExternalActivity(sessionId: "other", agent: .codex, state: .permissionRequest)
        let before = state.attentionAggregation.items
        #expect(before.count == 2)

        state.dismissAllAttentionItems()

        #expect(before.allSatisfy { state.attentionStore.acknowledgments[$0.eventID] != nil })
        #expect(state.attentionAggregation.unresolvedCount == 0)
    }

    @Test(arguments: [ACPSession.StreamingState.awaitingInput, .awaitingPermission])
    func acpResponseInteractionClearsCurrentSessionAttention(streamingState: ACPSession.StreamingState) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree()
        let session = ACPSession(id: "session", agentId: "claude", worktreeId: "worktree", title: "Agent")
        let bridge = ACPHarnessBridge(harness: state.harness) { owner, sessionID in
            state.acknowledgeACPResponseInteraction(owner: owner, sessionID: sessionID)
        }
        bridge.observe(session: session)
        _ = state.tabs.appendACP(owner: .worktree("worktree"), sessionId: "session", title: "Agent")
        state.selectedWorktreeId = "worktree"
        session.transcript.streamingState = streamingState

        let item = try #require(state.attentionAggregation.items.first)
        session.transcript.streamingState = .sending

        #expect(state.attentionStore.acknowledgments[item.eventID] != nil)
        #expect(state.attentionAggregation.unresolvedCount == 0)
        #expect(state.attentionStore.document.observations[item.sourceKey]?.isActive == false)
        #expect(state.attentionAggregation.history.first { $0.eventID == item.eventID }?.presentation == .historical)
    }

    @Test(arguments: [ActivityState.awaitingInput, .permissionRequest])
    func hookResponseInteractionClearsCurrentSessionAttention(activity: ActivityState) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree()
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: activity, requiresUserInput: true)

        let item = try #require(state.attentionAggregation.items.first)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .busy)

        #expect(state.attentionStore.acknowledgments[item.eventID] != nil)
        #expect(state.attentionStore.document.observations[item.sourceKey]?.isActive == false)
        #expect(state.attentionAggregation.unresolvedCount == 0)
        #expect(state.attentionAggregation.history.first { $0.eventID == item.eventID }?.presentation == .historical)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: activity, requiresUserInput: true)
        let next = try #require(state.attentionAggregation.items.first)
        #expect(next.eventID != item.eventID)
        #expect(state.attentionAggregation.unresolvedCount == 1)
    }

    @Test func corruptHistoryDoesNotSuppressFirstAttentionFromNewSessionAfterStartup() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("broken history".utf8).write(to: fixture.url)
        let state = fixture.makeStateWithWorktree()
        state.reconcileAttention(liveSignals: [])
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "New agent", sessionId: "new-session")
        state.harness.handleSocketEvent(
            AgentHookEvent(version: 1, event: .awaitingInput, agent: .claude,
                           sessionId: "new-session", pid: nil, timestamp: nil, body: "New question"),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )

        #expect(state.attentionStore.loadError != nil)
        #expect(state.attentionStore.events.map(\.kind) == [.agentReady])
        #expect(state.attentionAggregation.unresolvedCount == 0)
        #expect(state.attentionStore.events.first?.jumpTarget == .session(sessionID: "new-session"))
    }

    @Test func harnessChangesRecordHistoryAndUseLiveStateForPresentation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeState()
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: fixture.now)
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        _ = state.tabs.appendTerminal(worktreeId: worktree.id, title: "Agent", sessionId: "session")

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "First question", requiresUserInput: true)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Second question", requiresUserInput: true)
        #expect(state.attentionStore.events.count == 2)
        let current = try #require(state.attentionStore.events.last)
        #expect(state.attentionAggregation.items.map(\.eventID) == [current.id])
        #expect(state.attentionAggregation.unresolvedCountByProject == ["project": 1])
        #expect(state.attentionAggregation.history.map(\.eventID) == [state.attentionStore.events[0].id])
        #expect(state.attentionAggregation.history.first?.presentation == .historical)
        #expect(state.attentionStore.events.last?.body == "Second question")
        #expect(state.attentionAggregation.items.first?.presentation == .live)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .permissionRequest)
        #expect(state.attentionAggregation.items.map(\.kind) == [.agentPermission])
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .idle)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .idle)

        #expect(state.attentionStore.events.map(\.kind) == [.agentAwaiting, .agentAwaiting, .agentPermission, .agentFinished])
        #expect(state.attentionAggregation.items.isEmpty)
        #expect(state.attentionAggregation.history.allSatisfy { $0.presentation == .historical })
        #expect(state.attentionStore.document.observations[.init(rawValue: "session:session:awaiting")]?.isActive == false)
        #expect(state.attentionStore.document.observations[.init(rawValue: "session:session:permission")]?.isActive == false)
    }

    @Test func acknowledgedActiveOccurrenceDoesNotReturnAfterAppStateRelaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.observe(.active(fixture.signal), at: fixture.now)
        let event = try #require(fixture.store.events.first)
        fixture.store.acknowledge(eventID: event.id, at: fixture.now)

        let state = fixture.makeState()
        state.reconcileAttention(liveSignals: [fixture.signal])

        #expect(state.attentionStore.events.count == 1)
        #expect(state.attentionAggregation.unresolvedCount == 0)
        #expect(state.attentionAggregation.history.first?.eventID == event.id)
    }

    @Test func unreadableHistorySuppressesStartupUntilSourceChanges() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("broken history".utf8).write(to: fixture.url)
        let state = fixture.makeState()
        state.reconcileAttention(liveSignals: [fixture.signal])
        state.observeAttention(.active(fixture.signal))

        #expect(state.attentionStore.loadError != nil)
        #expect(state.attentionAggregation.unresolvedCount == 0)

        state.observeAttention(.inactive(sourceKey: fixture.signal.sourceKey))
        state.observeAttention(.active(fixture.signal))
        #expect(state.attentionAggregation.unresolvedCount == 1)
    }

    @Test func corruptHistorySuppressesFirstRestoredHarnessStateButAcceptsLaterTransition() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("broken history".utf8).write(to: fixture.url)
        let state = fixture.makeState()
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: fixture.now)
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        let session = ACPSession(id: "session", agentId: "claude", worktreeId: worktree.id, title: "Agent")
        _ = state.tabs.appendACP(owner: .worktree(worktree.id), sessionId: session.id, title: "Agent")
        session.transcript.streamingState = .awaitingInput
        let bridge = ACPHarnessBridge(harness: state.harness)
        bridge.observe(session: session)
        #expect(state.attentionAggregation.unresolvedCount == 0)
        session.transcript.streamingState = .streaming
        session.transcript.streamingState = .awaitingInput
        #expect(state.attentionAggregation.unresolvedCount == 1)
    }

    @Test func corruptHistorySuppressionMigratesWhenLineageAppears() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("broken history".utf8).write(to: fixture.url)
        let state = fixture.makeState()
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: fixture.now)
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now, lineageID: "lineage")
        let legacyOwner = AttentionWorktreeIdentity(projectID: project.id, location: .local, lineageID: nil, legacyPath: worktree.path.path)
        let lineageOwner = AttentionWorktreeIdentity.make(worktree: worktree, project: project)
        let display = AttentionWorktreeDisplaySnapshot(projectName: project.name, branch: worktree.branch, path: worktree.path.path, host: nil)
        let legacySignal = AttentionSignal(
            sourceKey: .init(rawValue: "git:\(legacyOwner.storageKey):conflicts"),
            fingerprint: "file.swift",
            owner: legacyOwner,
            kind: .conflicts,
            title: "1 unresolved conflict",
            body: nil,
            jumpTarget: .conflicts(path: "file.swift"),
            display: display
        )
        let lineageSignal = AttentionSignal(
            sourceKey: .init(rawValue: "git:\(lineageOwner.storageKey):conflicts"),
            fingerprint: legacySignal.fingerprint,
            owner: lineageOwner,
            kind: legacySignal.kind,
            title: legacySignal.title,
            body: legacySignal.body,
            jumpTarget: legacySignal.jumpTarget,
            display: display
        )

        state.reconcileAttention(liveSignals: [legacySignal])
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        _ = state.attentionAggregation
        state.reconcileAttention(liveSignals: [lineageSignal])

        #expect(state.attentionStore.events.isEmpty)
    }

    @Test func corruptHistoryInitializedSnapshotMigratesWhenLineageAppears() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("broken history".utf8).write(to: fixture.url)
        let state = fixture.makeStateWithWorktree()
        let project = try #require(state.projects.first)
        let legacyWorktree = try #require(state.attentionWorktrees.first?.worktree)
        let lineageWorktree = Worktree(
            id: legacyWorktree.id,
            projectId: legacyWorktree.projectId,
            name: legacyWorktree.name,
            branch: legacyWorktree.branch,
            path: legacyWorktree.path,
            status: legacyWorktree.status,
            lastActivity: legacyWorktree.lastActivity,
            lineageID: "lineage"
        )
        let conflicts = RightPaneAttentionSnapshot(mergeOperation: nil, conflictedPaths: ["file.swift"], review: nil)
        let clean = RightPaneAttentionSnapshot(mergeOperation: nil, conflictedPaths: [], review: nil)

        state.observeRightPaneAttention(worktreeID: legacyWorktree.id, snapshot: conflicts, at: fixture.now)
        state.observeRightPaneAttention(worktreeID: legacyWorktree.id, snapshot: clean, at: fixture.now.addingTimeInterval(1))
        #expect(state.attentionStore.events.isEmpty)

        state.projectsManager.insertOptimisticWorktree(lineageWorktree)
        #expect(state.projectsManager.worktrees(projectId: project.id).first?.lineageID == "lineage")
        state.observeRightPaneAttention(worktreeID: lineageWorktree.id, snapshot: conflicts, at: fixture.now.addingTimeInterval(2))

        #expect(state.attentionStore.events.count == 1)
        #expect(state.attentionStore.events.first?.kind == .conflicts)
    }

    @Test func corruptHistoryReviewFeedbackInitializationMigratesWhenLineageAppears() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("broken history".utf8).write(to: fixture.url)
        let state = fixture.makeStateWithWorktree()
        let project = try #require(state.projects.first)
        let legacyWorktree = try #require(state.attentionWorktrees.first?.worktree)
        let lineageWorktree = Worktree(
            id: legacyWorktree.id,
            projectId: legacyWorktree.projectId,
            name: legacyWorktree.name,
            branch: legacyWorktree.branch,
            path: legacyWorktree.path,
            status: legacyWorktree.status,
            lastActivity: legacyWorktree.lastActivity,
            lineageID: "lineage"
        )
        let clean = RightPaneAttentionSnapshot(
            mergeOperation: nil,
            conflictedPaths: [],
            review: fixture.review(decision: .approved, threads: [], areThreadsComplete: true)
        )
        let feedback = RightPaneAttentionSnapshot(
            mergeOperation: nil,
            conflictedPaths: [],
            review: fixture.review(decision: .approved, threads: [fixture.thread(id: "thread-a")], areThreadsComplete: true)
        )

        state.observeRightPaneAttention(worktreeID: legacyWorktree.id, snapshot: clean, at: fixture.now)
        #expect(state.attentionStore.events.isEmpty)

        state.projectsManager.insertOptimisticWorktree(lineageWorktree)
        #expect(state.projectsManager.worktrees(projectId: project.id).first?.lineageID == "lineage")
        state.observeRightPaneAttention(worktreeID: lineageWorktree.id, snapshot: feedback, at: fixture.now.addingTimeInterval(1))

        #expect(state.attentionStore.events.count == 1)
        #expect(state.attentionStore.events.first?.kind == .actionableFeedback)
    }

    @Test func corruptHistorySuppressionTreatsFinalFeedbackThreadAsShrink() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("broken history".utf8).write(to: fixture.url)
        let state = fixture.makeState()
        let sourceKey = AttentionSourceKey(rawValue: "review:project:local:lineage:https://github.com/owner/repo:42:feedback")
        let initial = AttentionSignal(
            sourceKey: sourceKey,
            fingerprint: "head|decision|CHANGES_REQUESTED|threads|thread-a",
            owner: .init(projectID: "project", location: .local, lineageID: "lineage", legacyPath: nil),
            kind: .actionableFeedback,
            title: "Review feedback needs action",
            body: nil,
            jumpTarget: .reviewRequest(number: 42),
            display: .init(projectName: "Project", branch: "main", path: "/repo", host: nil)
        )
        let shrunk = AttentionSignal(
            sourceKey: sourceKey,
            fingerprint: "head|decision|CHANGES_REQUESTED",
            owner: initial.owner,
            kind: initial.kind,
            title: initial.title,
            body: initial.body,
            jumpTarget: initial.jumpTarget,
            display: initial.display
        )

        state.reconcileAttention(liveSignals: [initial])
        state.observeAttention(.active(shrunk), at: fixture.now.addingTimeInterval(1))

        #expect(state.attentionStore.events.isEmpty)
    }

    @Test func restoredHarnessSnapshotAppliesInactiveObservations() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree()
        _ = state.tabs.appendACP(owner: .worktree("worktree"), sessionId: "session", title: "Agent")
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, requiresUserInput: true)
        #expect(state.attentionStore.document.observations[.init(rawValue: "session:session:awaiting")]?.isActive == true)

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .busy, isSnapshot: true)

        #expect(state.attentionStore.document.observations[.init(rawValue: "session:session:awaiting")]?.isActive == false)
        #expect(state.attentionStore.document.observations[.init(rawValue: "session:session:permission")] == nil)
    }

    @Test func startupReconciliationClearsRestoredSessionWithNoHarnessState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.observe(.active(fixture.signal), at: fixture.now)
        let oldEvent = try #require(fixture.store.events.first)
        fixture.store.acknowledge(eventID: oldEvent.id, at: fixture.now)
        let state = fixture.makeStateWithWorktree()
        _ = state.tabs.appendACP(owner: .worktree("worktree"), sessionId: "session", title: "Agent")

        state.reconcileAttention(observations: state.currentAttentionObservations)

        #expect(state.attentionStore.document.observations[fixture.signal.sourceKey]?.isActive == false)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, requiresUserInput: true)

        let newEvent = try #require(state.attentionStore.events.last)
        #expect(newEvent.id != oldEvent.id)
        #expect(state.attentionStore.acknowledgments[newEvent.id] == nil)
        #expect(state.attentionAggregation.unresolvedCount == 1)
    }

    @Test func workspaceCheckoutTabRestoreReconcilesStoredSessionAttention() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let tabsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tabsDirectory) }
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        let workspacesManager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore))
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: fixture.now)
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        let checkout = WorkspaceCheckout(
            workspaceID: UUID(),
            fallbackWorkspaceName: "Shared",
            executionLocation: .local,
            branch: "topic",
            rootPath: "/repo",
            members: [
                WorkspaceCheckoutMember(
                    workspaceMemberID: UUID(),
                    projectID: project.id,
                    fallbackProjectName: project.name,
                    fallbackRepositoryRoot: project.path,
                    worktreePath: worktree.path.path,
                    availability: .available
                )
            ]
        )
        try await workspaceStore.checkpoint(WorkspaceStateFile(checkouts: [checkout]))
        _ = await workspacesManager.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "main", spaces: []))
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let seedingTabs = TabsManager(store: PersistenceStore(), tabsDirectory: tabsDirectory)
        _ = seedingTabs.appendACP(owner: owner, sessionId: "shared-acp", title: "Shared agent")
        let sourceKey = AttentionSourceKey(rawValue: "session:shared-acp:awaiting")
        let signal = AttentionSignal(
            sourceKey: .init(rawValue: "session:shared-acp:awaiting"),
            fingerprint: "awaitingInput",
            owner: AttentionWorktreeIdentity.make(worktree: worktree, project: project),
            kind: .agentAwaiting,
            title: "Claude Code is waiting for input",
            body: nil,
            jumpTarget: .session(sessionID: "shared-acp"),
            display: AttentionWorktreeDisplaySnapshot(projectName: project.name, branch: worktree.branch, path: worktree.path.path, host: nil)
        )
        fixture.store.observe(.active(signal), at: fixture.now)
        let oldEvent = try #require(fixture.store.events.first)
        fixture.store.acknowledge(eventID: oldEvent.id, at: fixture.now)
        let tabs = TabsManager(store: PersistenceStore(), tabsDirectory: tabsDirectory)
        let state = AppState(
            store: MemoryStore(),
            tabsManager: tabs,
            workspacesManager: workspacesManager,
            workspaceStore: workspaceStore,
            attentionStore: AttentionStore(url: fixture.url)
        )
        state.config.workspacesEnabled = true
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)

        state.reconcileAttention(observations: state.currentAttentionObservations)
        #expect(state.attentionStore.document.observations[sourceKey]?.isActive == true)

        await state.restoreWorkspaceCheckoutSessionTabsAfterReload(restoringActiveTabs: true)

        #expect(!state.tabs.tabs(for: owner).isEmpty)
        #expect(state.attentionStore.document.observations[sourceKey]?.isActive == false)
    }

    @Test func reviewCommentActionAcknowledgesOnlyMatchingCommentAttention() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree()
        state.selectedWorktreeId = "worktree"
        let first = AttentionSignal(
            sourceKey: .init(rawValue: "review-comment:review:first"),
            fingerprint: "reply-1",
            owner: fixture.signal.owner,
            kind: .reviewReply,
            title: "Codex replied to review feedback",
            body: nil,
            jumpTarget: .reviewComment(sessionID: "review", commentID: "first"),
            display: fixture.signal.display
        )
        let second = AttentionSignal(
            sourceKey: .init(rawValue: "review-comment:review:second"),
            fingerprint: "reply-2",
            owner: fixture.signal.owner,
            kind: .reviewReply,
            title: "Codex replied to review feedback",
            body: nil,
            jumpTarget: .reviewComment(sessionID: "review", commentID: "second"),
            display: fixture.signal.display
        )
        state.attentionStore.observe(.active(first), at: fixture.now)
        state.attentionStore.observe(.active(second), at: fixture.now.addingTimeInterval(1))
        let firstEvent = try #require(state.attentionStore.events.first { $0.sourceKey == first.sourceKey })
        let secondEvent = try #require(state.attentionStore.events.first { $0.sourceKey == second.sourceKey })

        state.acknowledgeReviewCommentAttention(worktreeID: "worktree", commentID: "second")

        #expect(state.attentionStore.acknowledgments[firstEvent.id] == nil)
        #expect(state.attentionStore.acknowledgments[secondEvent.id] != nil)
    }

    @Test func historyOnlyLegacyOwnerResolvesAfterLineageAppears() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeState()
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: fixture.now)
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now, lineageID: "lineage")
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        let legacyOwner = AttentionWorktreeIdentity(projectID: project.id, location: .local, lineageID: nil, legacyPath: "/repo")
        let signal = AttentionSignal(
            sourceKey: .init(rawValue: "session:old:awaiting"),
            fingerprint: "question",
            owner: legacyOwner,
            kind: .agentAwaiting,
            title: "Agent is waiting for input",
            body: nil,
            jumpTarget: .session(sessionID: "old"),
            display: .init(projectName: project.name, branch: "main", path: "/repo", host: nil)
        )
        state.attentionStore.observe(.active(signal), at: fixture.now)
        state.attentionStore.observe(.inactive(sourceKey: signal.sourceKey), at: fixture.now.addingTimeInterval(1))

        let item = try #require(state.attentionAggregation.history.first)
        #expect(state.attentionAggregation.items.isEmpty)
        #expect(item.presentation == .historical)

        #expect(item.worktree?.id == worktree.id)
        #expect(state.attentionStore.document.aliases[legacyOwner]?.lineageID == "lineage")
    }

    @Test func stoppedRightPaneStatesDoNotContributeLiveAttentionSignals() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeState()
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: fixture.now)
        let first = Worktree(id: "first", projectId: project.id, name: "first", branch: "main",
                             path: URL(fileURLWithPath: "/repo/first"), status: .clean, lastActivity: fixture.now)
        let second = Worktree(id: "second", projectId: project.id, name: "second", branch: "main",
                              path: URL(fileURLWithPath: "/repo/second"), status: .clean, lastActivity: fixture.now)
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(first)
        state.projectsManager.insertOptimisticWorktree(second)

        _ = state.rightPaneStore.state(for: first, baseBranch: "", comparisonMode: state.config.changes.comparisonMode)
        #expect(state.rightPaneStore.isActiveState(worktreeId: first.id))
        _ = state.rightPaneStore.state(for: second, baseBranch: "", comparisonMode: state.config.changes.comparisonMode)

        #expect(!state.rightPaneStore.isActiveState(worktreeId: first.id))
        #expect(state.rightPaneStore.isActiveState(worktreeId: second.id))
        state.rightPaneStore.deactivate()
        #expect(!state.rightPaneStore.isActiveState(worktreeId: second.id))
    }

    @Test func checkoutOwnedACPAttentionOpensSharedTabAndClears() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        let workspacesManager = WorkspacesManager(
            bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore),
            observer: FixtureCheckoutObserver()
        )
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: fixture.now)
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        let checkout = WorkspaceCheckout(
            workspaceID: UUID(),
            fallbackWorkspaceName: "Shared",
            executionLocation: .local,
            branch: "topic",
            rootPath: "/repo",
            members: [
                WorkspaceCheckoutMember(
                    workspaceMemberID: UUID(),
                    projectID: project.id,
                    fallbackProjectName: project.name,
                    fallbackRepositoryRoot: project.path,
                    worktreePath: worktree.path.path,
                    availability: .available
                )
            ]
        )
        try await workspaceStore.checkpoint(WorkspaceStateFile(checkouts: [checkout]))
        _ = await workspacesManager.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "main", spaces: []))
        let state = AppState(
            store: MemoryStore(),
            workspacesManager: workspacesManager,
            workspaceStore: workspaceStore,
            attentionStore: AttentionStore(url: fixture.url),
            harnessAttentionSettleInterval: 0
        )
        state.config.workspacesEnabled = true
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        state.selectedWorktreeId = worktree.id
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let tab = state.tabs.appendACP(owner: owner, sessionId: "shared-acp", title: "Shared agent")

        state.harness.setExternalActivity(sessionId: "shared-acp", owner: owner, agent: AgentKind.claude, state: ActivityState.awaitingInput, requiresUserInput: true)
        let item = try #require(state.attentionAggregation.items.first)

        let result = await state.openAttentionItem(item)

        #expect(result == .opened)
        #expect(state.selectedWorkspaceCheckout?.id == checkout.id)
        #expect(state.workspaceNavigationState.repositoryFocusWorktreeID == worktree.id)
        #expect(state.tabs.activeTabId(for: owner) == tab.id)
        #expect(state.tabs.activeTabId(forWorktree: worktree.id) == nil)
        #expect(state.attentionAggregation.unresolvedCount == 0)
    }

    @Test func checkoutOwnedUnverifiedSessionClearsFromFocusedDifferentMember() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        let workspacesManager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore))
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: fixture.now)
        let first = Worktree(id: "first", projectId: project.id, name: "first", branch: "first",
                             path: URL(fileURLWithPath: "/repo/first"), status: .clean, lastActivity: fixture.now)
        let second = Worktree(id: "second", projectId: project.id, name: "second", branch: "second",
                              path: URL(fileURLWithPath: "/repo/second"), status: .clean, lastActivity: fixture.now)
        let checkout = WorkspaceCheckout(
            workspaceID: UUID(),
            fallbackWorkspaceName: "Shared",
            executionLocation: .local,
            branch: "topic",
            rootPath: "/repo",
            members: [
                WorkspaceCheckoutMember(
                    workspaceMemberID: UUID(),
                    projectID: project.id,
                    fallbackProjectName: project.name,
                    fallbackRepositoryRoot: project.path,
                    worktreePath: first.path.path,
                    availability: .available
                ),
                WorkspaceCheckoutMember(
                    workspaceMemberID: UUID(),
                    projectID: project.id,
                    fallbackProjectName: project.name,
                    fallbackRepositoryRoot: project.path,
                    worktreePath: second.path.path,
                    availability: .available
                )
            ]
        )
        try await workspaceStore.checkpoint(WorkspaceStateFile(checkouts: [checkout]))
        _ = await workspacesManager.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "main", spaces: []))
        let state = AppState(
            store: MemoryStore(),
            workspacesManager: workspacesManager,
            workspaceStore: workspaceStore,
            attentionStore: AttentionStore(url: fixture.url)
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(first)
        state.projectsManager.insertOptimisticWorktree(second)
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let tab = state.tabs.appendACP(owner: owner, sessionId: "shared-acp", title: "Shared agent")
        let firstOwner = AttentionWorktreeIdentity.make(worktree: first, project: project)
        let signal = AttentionSignal(
            sourceKey: .init(rawValue: "session:shared-acp:awaiting"),
            fingerprint: "awaitingInput",
            owner: firstOwner,
            kind: .agentAwaiting,
            title: "Claude Code is waiting for input",
            body: nil,
            jumpTarget: .session(sessionID: "shared-acp"),
            display: AttentionWorktreeDisplaySnapshot(projectName: project.name, branch: first.branch, path: first.path.path, host: nil)
        )
        state.attentionStore.observe(.active(signal), at: fixture.now)
        let event = try #require(state.attentionStore.events.first)
        state.selectedWorktreeId = second.id
        state.tabs.activate(owner: owner, tabId: tab.id)
        #expect(state.attentionAggregation.unresolvedCount == 1)
        #expect(state.attentionAggregation.items.first?.presentation == .unverified)

        state.acknowledgeFocusedSessionAttention(worktreeID: second.id, owner: owner, tabID: tab.id)

        #expect(state.attentionAggregation.unresolvedCount == 0)
        #expect(state.attentionStore.acknowledgments[event.id] != nil)
    }

    @Test func checkoutOwnedHistoricalSessionOpensThroughSurvivingMemberWhenOriginalMemberIsGone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        let workspacesManager = WorkspacesManager(
            bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore),
            observer: FixtureCheckoutObserver()
        )
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: fixture.now)
        let first = Worktree(id: "first", projectId: project.id, name: "first", branch: "first",
                             path: URL(fileURLWithPath: "/repo/first"), status: .clean, lastActivity: fixture.now)
        let second = Worktree(id: "second", projectId: project.id, name: "second", branch: "second",
                              path: URL(fileURLWithPath: "/repo/second"), status: .clean, lastActivity: fixture.now)
        let checkout = WorkspaceCheckout(
            workspaceID: UUID(),
            fallbackWorkspaceName: "Shared",
            executionLocation: .local,
            branch: "topic",
            rootPath: "/repo",
            members: [
                WorkspaceCheckoutMember(
                    workspaceMemberID: UUID(),
                    projectID: project.id,
                    fallbackProjectName: project.name,
                    fallbackRepositoryRoot: project.path,
                    worktreePath: first.path.path,
                    availability: .available
                ),
                WorkspaceCheckoutMember(
                    workspaceMemberID: UUID(),
                    projectID: project.id,
                    fallbackProjectName: project.name,
                    fallbackRepositoryRoot: project.path,
                    worktreePath: second.path.path,
                    availability: .available
                )
            ]
        )
        try await workspaceStore.checkpoint(WorkspaceStateFile(checkouts: [checkout]))
        _ = await workspacesManager.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "main", spaces: []))
        let state = AppState(
            store: MemoryStore(),
            workspacesManager: workspacesManager,
            workspaceStore: workspaceStore,
            attentionStore: AttentionStore(url: fixture.url)
        )
        state.config.workspacesEnabled = true
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(first)
        state.projectsManager.insertOptimisticWorktree(second)
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let tab = state.tabs.appendACP(owner: owner, sessionId: "shared-acp", title: "Shared agent")
        let firstOwner = AttentionWorktreeIdentity.make(worktree: first, project: project)
        let signal = AttentionSignal(
            sourceKey: .init(rawValue: "session:shared-acp:awaiting"),
            fingerprint: "awaitingInput",
            owner: firstOwner,
            kind: .agentAwaiting,
            title: "Claude Code is waiting for input",
            body: nil,
            jumpTarget: .session(sessionID: "shared-acp"),
            display: AttentionWorktreeDisplaySnapshot(projectName: project.name, branch: first.branch, path: first.path.path, host: nil)
        )
        state.attentionStore.observe(.active(signal), at: fixture.now)
        state.attentionStore.observe(.inactive(sourceKey: signal.sourceKey), at: fixture.now.addingTimeInterval(1))
        state.projectsManager.removeOptimisticWorktree(id: first.id, projectId: project.id)
        state.selectedWorktreeId = second.id
        let item = try #require(state.attentionAggregation.history.first)
        #expect(state.attentionAggregation.items.isEmpty)

        let result = await state.openAttentionItem(item)

        #expect(result == .opened)
        #expect(state.selectedWorkspaceCheckout?.id == checkout.id)
        #expect(state.workspaceNavigationState.repositoryFocusWorktreeID == second.id)
        #expect(state.tabs.activeTabId(for: owner) == tab.id)
        #expect(state.attentionStore.acknowledgments[item.eventID] != nil)
    }

    @Test func openingAndClosingInboxTogglesStateAndCancelsPendingReviewReveal() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree()

        state.openAttentionInbox()
        #expect(state.isAttentionInboxOpen)
        state.openAttentionInbox()
        #expect(state.isAttentionInboxOpen)
        state.closeAttentionInbox()
        #expect(!state.isAttentionInboxOpen)
        state.closeAttentionInbox()
        #expect(!state.isAttentionInboxOpen)
    }

    @Test func offlineHostEventOpensWorktreeAndClearsWhileStillOffline() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeState()
        RemoteHostStatusStore.shared.reportSuccess(host: "buildbox")
        RemoteHostStatusStore.shared.reportConnectionFailure(host: "buildbox")
        RemoteHostStatusStore.shared.reportConnectionFailure(host: "buildbox")
        defer { RemoteHostStatusStore.shared.reportSuccess(host: "buildbox") }
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue",
                                    addedAt: fixture.now, host: "buildbox")
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        let owner = AttentionWorktreeIdentity.make(worktree: worktree, project: project)
        let signal = try #require(AttentionProducer.host(
            host: "buildbox",
            isDisconnected: true,
            owner: owner,
            display: AttentionWorktree(worktree: worktree, project: project).resolved.display
        ).compactMap(\.activeSignal).first)
        state.attentionStore.observe(.active(signal), at: fixture.now)
        let item = try #require(state.attentionAggregation.items.first)

        let result = await state.openAttentionItem(item)

        #expect(result == .opened)
        #expect(state.selectedWorktreeId == worktree.id)
        #expect(state.attentionAggregation.unresolvedCount == 0)
    }

    @Test func sidebarSelectionClearsOfflineHostAttentionWhileStillOffline() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeState()
        RemoteHostStatusStore.shared.reportSuccess(host: "buildbox")
        RemoteHostStatusStore.shared.reportConnectionFailure(host: "buildbox")
        RemoteHostStatusStore.shared.reportConnectionFailure(host: "buildbox")
        defer { RemoteHostStatusStore.shared.reportSuccess(host: "buildbox") }
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue",
                                    addedAt: fixture.now, host: "buildbox")
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)

        #expect(state.attentionAggregation.unresolvedCount == 1)

        state.selectWorktreeFromSidebar(id: worktree.id)

        #expect(state.selectedWorktreeId == worktree.id)
        #expect(state.attentionAggregation.unresolvedCount == 0)
    }

    @Test func recoveredHostEventDoesNotClearWhenOpenedAfterReconnect() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeState()
        RemoteHostStatusStore.shared.reportSuccess(host: "buildbox")
        RemoteHostStatusStore.shared.reportConnectionFailure(host: "buildbox")
        RemoteHostStatusStore.shared.reportConnectionFailure(host: "buildbox")
        defer { RemoteHostStatusStore.shared.reportSuccess(host: "buildbox") }
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue",
                                    addedAt: fixture.now, host: "buildbox")
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        let owner = AttentionWorktreeIdentity.make(worktree: worktree, project: project)
        let signal = try #require(AttentionProducer.host(
            host: "buildbox",
            isDisconnected: true,
            owner: owner,
            display: AttentionWorktree(worktree: worktree, project: project).resolved.display
        ).compactMap(\.activeSignal).first)
        state.attentionStore.observe(.active(signal), at: fixture.now)
        let item = try #require(state.attentionAggregation.items.first)
        RemoteHostStatusStore.shared.reportSuccess(host: "buildbox")

        let result = await state.openAttentionItem(item)

        #expect(result == .unavailable("The host is no longer disconnected."))
        #expect(state.attentionStore.acknowledgments[item.eventID] == nil)
    }

    @Test func offlineHostObservationIsRecordedWhenWorktreeAppearsAfterDisconnect() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeState()
        RemoteHostStatusStore.shared.reportSuccess(host: "buildbox")
        RemoteHostStatusStore.shared.reportConnectionFailure(host: "buildbox")
        RemoteHostStatusStore.shared.reportConnectionFailure(host: "buildbox")
        defer { RemoteHostStatusStore.shared.reportSuccess(host: "buildbox") }
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue",
                                    addedAt: fixture.now, host: "buildbox")
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)

        #expect(state.attentionStore.events.isEmpty)
        #expect(state.attentionAggregation.unresolvedCount == 1)
        #expect(state.attentionStore.events.first?.kind == .hostDisconnected)
    }

    @Test func archivedHostWorktreeDoesNotRecordNewOutageAttention() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeState()
        let host = "archived-\(UUID().uuidString)"
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue",
                                    addedAt: fixture.now, host: host)
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        state.projectsManager.setWorktreeHidden(projectId: project.id, path: worktree.path, hidden: true)

        state.observeHostAttention(host: host, isDisconnected: true, at: fixture.now)
        #expect(state.attentionStore.events.isEmpty)

        RemoteHostStatusStore.shared.reportConnectionFailure(host: host)
        RemoteHostStatusStore.shared.reportConnectionFailure(host: host)
        defer { RemoteHostStatusStore.shared.reportSuccess(host: host) }
        state.reconcileAttention(observations: state.currentAttentionObservations)
        #expect(state.attentionStore.events.isEmpty)

        _ = state.attentionAggregation

        #expect(state.attentionStore.events.isEmpty)
        #expect(state.attentionAggregation.unresolvedCount == 0)
    }

    @Test func archivedHostWorktreeRecoveryClosesOldOutageBeforeLaterRestore() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeState()
        let host = "archived-\(UUID().uuidString)"
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue",
                                    addedAt: fixture.now, host: host)
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        state.observeHostAttention(host: host, isDisconnected: true, at: fixture.now)
        let oldEventID = try #require(state.attentionStore.events.first?.id)
        state.attentionStore.acknowledge(eventID: oldEventID, at: fixture.now)

        state.projectsManager.setWorktreeHidden(projectId: project.id, path: worktree.path, hidden: true)
        state.observeHostAttention(host: host, isDisconnected: false, at: fixture.now.addingTimeInterval(1))
        #expect(state.attentionStore.document.observations.values.allSatisfy { !$0.isActive })

        state.observeHostAttention(host: host, isDisconnected: true, at: fixture.now.addingTimeInterval(2))
        #expect(state.attentionStore.document.observations.values.allSatisfy { !$0.isActive })

        state.projectsManager.setWorktreeHidden(projectId: project.id, path: worktree.path, hidden: false)
        state.observeHostAttention(host: host, isDisconnected: true, at: fixture.now.addingTimeInterval(3))

        let newEventID = try #require(state.attentionStore.events.last?.id)
        #expect(newEventID != oldEventID)
        #expect(state.attentionStore.acknowledgments[newEventID] == nil)
        #expect(state.attentionAggregation.unresolvedCount == 1)
    }

    @Test func onlineHostObservationIsClearedWhenWorktreeAppearsAfterReconnect() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeState()
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue",
                                    addedAt: fixture.now, host: "buildbox")
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        let owner = AttentionWorktreeIdentity.make(worktree: worktree, project: project)
        let signal = try #require(AttentionProducer.host(
            host: "buildbox",
            isDisconnected: true,
            owner: owner,
            display: AttentionWorktreeDisplaySnapshot(projectName: project.name, branch: worktree.branch, path: worktree.path.path, host: project.host)
        ).compactMap(\.activeSignal).first)
        state.attentionStore.observe(.active(signal), at: fixture.now)
        RemoteHostStatusStore.shared.reportSuccess(host: "buildbox")

        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        #expect(state.attentionStore.document.observations[signal.sourceKey]?.isActive == true)
        _ = state.attentionAggregation

        #expect(state.attentionStore.document.observations[signal.sourceKey]?.isActive == false)
    }

    @Test func onlineHostWithNoStoredObservationDoesNotRetryFailedPersistenceFromAggregation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let persistence = AlwaysFailingPersistenceStore()
        let store = AttentionStore(url: fixture.url, persistence: persistence)
        let state = AppState(store: MemoryStore(), attentionStore: store)
        state.attentionStore.appendHistory(fixture.history(fingerprint: "finished"), at: fixture.now)
        #expect(state.attentionStore.writeError != nil)
        let host = "online-\(UUID().uuidString)"
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue",
                                    addedAt: fixture.now, host: host)
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        // The live status-transition callback (unlike aggregation's own
        // reconciliation) legitimately retries the failed write once, since
        // a genuine reconnect is a meaningful moment to flush pending state.
        // The baseline must be taken after that settles so the assertion
        // below measures only what `attentionAggregation` itself adds.
        RemoteHostStatusStore.shared.reportSuccess(host: host)
        let writeCountAfterReconnect = persistence.writeCount

        _ = state.attentionAggregation

        #expect(persistence.writeCount == writeCountAfterReconnect)
    }

    @Test func unknownHostObservationIsPreservedWhenWorktreeAppearsBeforeProbe() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeState()
        let host = "unknown-\(UUID().uuidString)"
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue",
                                    addedAt: fixture.now, host: host)
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        let owner = AttentionWorktreeIdentity.make(worktree: worktree, project: project)
        let signal = try #require(AttentionProducer.host(
            host: host,
            isDisconnected: true,
            owner: owner,
            display: AttentionWorktreeDisplaySnapshot(projectName: project.name, branch: worktree.branch, path: worktree.path.path, host: project.host)
        ).compactMap(\.activeSignal).first)
        state.attentionStore.observe(.active(signal), at: fixture.now)

        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        _ = state.attentionAggregation

        #expect(state.attentionStore.document.observations[signal.sourceKey]?.isActive == true)
    }

    @Test func attentionAggregationSchedulesAliasRetryOutsideRender() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let persistence = FailingThenSucceedingPersistenceStore()
        let store = AttentionStore(url: fixture.url, persistence: persistence)
        let state = AppState(store: MemoryStore(), attentionStore: store)
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: fixture.now)
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now, lineageID: "lineage")
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)

        _ = state.attentionAggregation
        #expect(state.attentionStore.writeError != nil)

        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(state.attentionStore.writeError == nil)
        #expect(persistence.writeCount >= 2)
    }

    @Test func attentionAliasRetryRebuildsAliasesFromCurrentTopology() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let persistence = FailingThenSucceedingPersistenceStore(failures: 2)
        let store = AttentionStore(url: fixture.url, persistence: persistence)
        let state = AppState(store: MemoryStore(), attentionStore: store)
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: fixture.now)
        let deletedWorktree = Worktree(id: "deleted", projectId: project.id, name: "main", branch: "main",
                                       path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now, lineageID: "deleted-lineage")
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(deletedWorktree)

        _ = state.attentionAggregation
        #expect(state.attentionStore.writeError != nil)

        let replacementWorktree = Worktree(id: "replacement", projectId: project.id, name: "main", branch: "main",
                                           path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now, lineageID: "replacement-lineage")
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(replacementWorktree)
        let replacementOwner = AttentionWorktreeIdentity.make(worktree: replacementWorktree, project: project)
        let legacySignal = fixture.signal
        state.attentionStore.observe(.active(legacySignal), at: fixture.now)
        #expect(state.attentionStore.writeError != nil)

        try await Task.sleep(nanoseconds: 300_000_000)

        let event = try #require(state.attentionStore.events.first { $0.sourceKey == legacySignal.sourceKey })
        #expect(state.attentionStore.writeError == nil)
        #expect(event.owner == replacementOwner)
        #expect(state.attentionStore.document.observations[legacySignal.sourceKey]?.isActive == true)
    }

    @Test func attentionAliasRetryBacksOffWhenPersistenceKeepsFailing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let persistence = AlwaysFailingPersistenceStore()
        let store = AttentionStore(url: fixture.url, persistence: persistence)
        let state = AppState(store: MemoryStore(), attentionStore: store)
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: fixture.now)
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now, lineageID: "lineage")
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)

        _ = state.attentionAggregation
        #expect(persistence.writeCount == 1)

        try await Task.sleep(nanoseconds: 300_000_000)
        let writeCountAfterRetry = persistence.writeCount
        #expect(writeCountAfterRetry == 2)
        #expect(state.attentionAliasRetryTask != nil)

        _ = state.attentionAggregation
        _ = state.attentionAggregation

        #expect(persistence.writeCount == writeCountAfterRetry)
        #expect(state.attentionAliasRetryNotBefore != nil)
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    private final class FailingThenSucceedingPersistenceStore: PersistenceStoreProtocol {
        private var remainingFailures: Int
        private(set) var writeCount = 0

        init(failures: Int = 1) {
            remainingFailures = failures
        }

        func write<T: Encodable>(_: T, to _: URL) throws {
            writeCount += 1
            if remainingFailures > 0 {
                remainingFailures -= 1
                throw TestError.writeFailed
            }
        }

        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }

        private enum TestError: Error {
            case writeFailed
        }
    }

    private final class AlwaysFailingPersistenceStore: PersistenceStoreProtocol {
        private(set) var writeCount = 0

        func write<T: Encodable>(_: T, to _: URL) throws {
            writeCount += 1
            throw TestError.writeFailed
        }

        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }

        private enum TestError: Error {
            case writeFailed
        }
    }

    @MainActor
    // MARK: - Harness attention settle debounce

    @Test func genericAwaitingReadinessStaysQuietUntilSameStateExplicitRequest() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree()
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput)
        let ready = try #require(state.attentionAggregation.history.first)
        #expect(ready.kind == .agentReady)
        #expect(ready.presentation == .live)
        #expect(state.attentionAggregation.unresolvedCount == 0)
        state.dismissAttentionItem(ready)

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, requiresUserInput: true)
        let request = try #require(state.attentionAggregation.items.first)
        #expect(request.kind == .agentAwaiting)
        #expect(request.presentation == .live)
        #expect(request.eventID != ready.eventID)
        #expect(state.attentionAggregation.unresolvedCount == 1)
        #expect(state.attentionAggregation.history.first { $0.eventID == ready.eventID }?.presentation == .historical)

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput)
        #expect(state.attentionAggregation.items.isEmpty)
        #expect(state.attentionAggregation.history.first { $0.eventID == request.eventID }?.presentation == .historical)
        #expect(state.attentionAggregation.history.first { $0.presentation == .live }?.kind == .agentReady)
    }

    @Test func explicitRequestDuringReadinessSettleDoesNotInheritPreAcknowledgment() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        let tab = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")
        state.selectedWorktreeId = "worktree"

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput)
        state.acknowledgeFocusedSessionAttention(worktreeID: "worktree", tabID: tab.id)
        #expect(state.attentionStore.events.isEmpty)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, requiresUserInput: true)

        try await Task.sleep(nanoseconds: 400_000_000)
        let request = try #require(state.attentionAggregation.items.first)
        #expect(request.kind == .agentAwaiting)
        #expect(request.presentation == .live)
        #expect(state.attentionStore.events.map(\.id) == [request.eventID])
        #expect(state.attentionStore.acknowledgments[request.eventID] == nil)
        #expect(state.attentionAggregation.unresolvedCount == 1)
    }

    @Test func harnessAwaitingAttentionIsDebouncedUntilSettled() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Question", requiresUserInput: true)
        #expect(state.attentionStore.events.isEmpty)
        #expect(state.attentionAggregation.unresolvedCount == 0)

        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(state.attentionStore.events.count == 1)
        #expect(state.attentionStore.events.first?.kind == .agentAwaiting)
        #expect(state.attentionStore.events.first?.body == "Question")
        #expect(state.attentionAggregation.unresolvedCount == 1)
    }

    @Test func harnessAwaitingAttentionIsCancelledByBusyWithinWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Question", requiresUserInput: true)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .busy)

        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(state.attentionStore.events.isEmpty)
        #expect(state.attentionAggregation.unresolvedCount == 0)
        #expect(state.attentionStore.document.observations[.init(rawValue: "session:session:awaiting")] == nil)
    }

    @Test func harnessAwaitingAttentionRefreshesBodyWhenPoked() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "First", requiresUserInput: true)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Second", requiresUserInput: true)

        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(state.attentionStore.events.count == 1)
        #expect(state.attentionStore.events.first?.body == "Second")
    }

    @Test func harnessPermissionAttentionIsAlsoDebounced() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .permissionRequest, body: "Allow?")
        #expect(state.attentionStore.events.isEmpty)

        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(state.attentionStore.events.count == 1)
        #expect(state.attentionStore.events.first?.kind == .agentPermission)
    }

    @Test func harnessPermissionAttentionSwitchingToAwaitingReplacesPendingSignal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .permissionRequest, body: "Allow?")
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Question?", requiresUserInput: true)

        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(state.attentionStore.events.count == 1)
        #expect(state.attentionStore.events.first?.kind == .agentAwaiting)
        #expect(state.attentionStore.events.first?.body == "Question?")
        #expect(state.attentionStore.document.observations[.init(rawValue: "session:session:permission")] == nil)
    }

    @Test func settledHarnessAwaitingAttentionStillLands() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Question", requiresUserInput: true)
        try await Task.sleep(nanoseconds: 400_000_000)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .busy)

        #expect(state.attentionStore.events.count == 1)
        #expect(state.attentionStore.document.observations[.init(rawValue: "session:session:awaiting")]?.isActive == false)
    }

    @Test func forgetSessionCancelsPendingHarnessAttention() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Question", requiresUserInput: true)
        state.harness.forgetSession("session")

        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(state.attentionStore.events.isEmpty)
        #expect(state.attentionAggregation.unresolvedCount == 0)
    }

    @Test func acknowledgeDuringSettleWindowKeepsLandedEventAcknowledged() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")
        state.selectedWorktreeId = "worktree"

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Question", requiresUserInput: true)
        let tabId = state.tabs.activeTabId(forWorktree: "worktree")
        state.acknowledgeFocusedSessionAttention(worktreeID: "worktree", tabID: tabId!)

        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(state.attentionStore.events.count == 1)
        let event = try #require(state.attentionStore.events.first)
        #expect(state.attentionStore.acknowledgments[event.id] != nil)
        #expect(state.attentionAggregation.unresolvedCount == 0)
    }

    @Test func acknowledgeAfterTransitionLandsStillAcknowledges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")
        state.selectedWorktreeId = "worktree"

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Question", requiresUserInput: true)
        try await Task.sleep(nanoseconds: 400_000_000)
        let eventID = try #require(state.attentionStore.events.first?.id)
        #expect(state.attentionStore.acknowledgments[eventID] == nil)

        let tabId = state.tabs.activeTabId(forWorktree: "worktree")
        state.acknowledgeFocusedSessionAttention(worktreeID: "worktree", tabID: tabId!)
        #expect(state.attentionStore.acknowledgments[eventID] != nil)
    }

    @Test func preAcknowledgementDoesNotSurviveAFlappedTransition() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")
        state.selectedWorktreeId = "worktree"
        let tabId = state.tabs.activeTabId(forWorktree: "worktree")!

        // Focus while pending, then the agent resumes before the window
        // closes. The parked transition is rejected and the marker with it.
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Question", requiresUserInput: true)
        state.acknowledgeFocusedSessionAttention(worktreeID: "worktree", tabID: tabId)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .busy)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(state.attentionStore.events.isEmpty)

        // A fresh awaiting must badge normally.
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Again", requiresUserInput: true)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(state.attentionStore.events.count == 1)
        let event = try #require(state.attentionStore.events.first)
        #expect(state.attentionStore.acknowledgments[event.id] == nil)
        #expect(state.attentionAggregation.unresolvedCount == 1)
    }

    @Test func preAcknowledgementDoesNotLeakAcrossAwaitingFlurries() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")
        state.selectedWorktreeId = "worktree"
        let tabId = state.tabs.activeTabId(forWorktree: "worktree")!

        // Focus while pending, then the agent resumes and waits again, all
        // inside the settle window. The second waiting spell is genuinely
        // new and must badge normally.
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Question", requiresUserInput: true)
        state.acknowledgeFocusedSessionAttention(worktreeID: "worktree", tabID: tabId)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .busy)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Again", requiresUserInput: true)

        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(state.attentionStore.events.count == 1)
        let event = try #require(state.attentionStore.events.first)
        #expect(state.attentionStore.acknowledgments[event.id] == nil)
        #expect(state.attentionAggregation.unresolvedCount == 1)
    }

    @Test func preAcknowledgementDoesNotSurvivePendingKindSwitch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")
        state.selectedWorktreeId = "worktree"
        let tabId = state.tabs.activeTabId(forWorktree: "worktree")!

        // Focus while an awaiting is pending, then the pending kind flips to
        // permission. This signal has not been seen and must badge for itself.
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Question", requiresUserInput: true)
        state.acknowledgeFocusedSessionAttention(worktreeID: "worktree", tabID: tabId)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .permissionRequest, body: "Allow?")

        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(state.attentionStore.events.count == 1)
        let event = try #require(state.attentionStore.events.first)
        #expect(event.kind == .agentPermission)
        #expect(state.attentionStore.acknowledgments[event.id] == nil)
        #expect(state.attentionAggregation.unresolvedCount == 1)
    }

    @Test func preAcknowledgementDoesNotSuppressNewUnseenQuestion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")
        state.selectedWorktreeId = "worktree"
        let tabId = state.tabs.activeTabId(forWorktree: "worktree")!

        // Focus while pending, then the agent asks a different question
        // before the user returns. The new question must badge for itself.
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "First question", requiresUserInput: true)
        state.acknowledgeFocusedSessionAttention(worktreeID: "worktree", tabID: tabId)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Second question", requiresUserInput: true)

        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(state.attentionStore.events.count == 1)
        let event = try #require(state.attentionStore.events.first)
        #expect(event.body == "Second question")
        #expect(state.attentionStore.acknowledgments[event.id] == nil)
        #expect(state.attentionAggregation.unresolvedCount == 1)
    }

    @Test func whitespaceOnlyReemitKeepsPreAcknowledgment() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")
        state.selectedWorktreeId = "worktree"
        let tabId = state.tabs.activeTabId(forWorktree: "worktree")!

        // The same question re-emitted with whitespace differences is the
        // same attention occurrence, so the pre-acknowledgment must survive.
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Question", requiresUserInput: true)
        state.acknowledgeFocusedSessionAttention(worktreeID: "worktree", tabID: tabId)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "  Question  ", requiresUserInput: true)

        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(state.attentionStore.events.count == 1)
        let event = try #require(state.attentionStore.events.first)
        #expect(state.attentionStore.acknowledgments[event.id] != nil)
        #expect(state.attentionAggregation.unresolvedCount == 0)
    }

    @Test func bodyReplacingStateNameFingerprintIsANewOccurrence() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")
        state.selectedWorktreeId = "worktree"
        let tabId = state.tabs.activeTabId(forWorktree: "worktree")!

        // A bodyless awaiting has the state-name fingerprint; a follow-up
        // whose literal body equals the state name must still be a distinct
        // occurrence, per the producer's hashing.
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: nil, requiresUserInput: true)
        state.acknowledgeFocusedSessionAttention(worktreeID: "worktree", tabID: tabId)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "awaitingInput", requiresUserInput: true)

        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(state.attentionStore.events.count == 1)
        let event = try #require(state.attentionStore.events.first)
        #expect(state.attentionStore.acknowledgments[event.id] == nil)
        #expect(state.attentionAggregation.unresolvedCount == 1)
    }

    @Test func acknowledgementSuppressedWhileInboxOpenDoesNotPreAcknowledge() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")
        state.selectedWorktreeId = "worktree"
        let tabId = state.tabs.activeTabId(forWorktree: "worktree")!

        state.openAttentionInbox()
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Question", requiresUserInput: true)
        state.acknowledgeFocusedSessionAttention(worktreeID: "worktree", tabID: tabId)
        state.closeAttentionInbox()

        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(state.attentionStore.events.count == 1)
        let event = try #require(state.attentionStore.events.first)
        #expect(state.attentionStore.acknowledgments[event.id] == nil)
        #expect(state.attentionAggregation.unresolvedCount == 1)
    }

    @Test func repeatedBodyUpdatesCannotStarveTheBadge() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree(attentionSettleInterval: 0.05)
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")

        // Body updates arriving faster than the settle window keep poking
        // the timer, but the max-wait ceiling forces the badge through.
        for index in 0..<12 {
            state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Update \(index)", requiresUserInput: true)
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(state.attentionStore.events.isEmpty == false)
        let event = try #require(state.attentionStore.events.first)
        #expect(event.body?.hasPrefix("Update ") == true)
        #expect(state.attentionAggregation.unresolvedCount == 1)
    }

    @MainActor private struct Fixture {
        let now = Date()
        let url: URL
        let store: AttentionStore
        let signal = AttentionSignal(
            sourceKey: .init(rawValue: "session:session:awaiting"), fingerprint: "awaitingInput",
            owner: .init(projectID: "project", location: .local, lineageID: nil, legacyPath: "/repo"),
            kind: .agentAwaiting, title: "Claude Code is waiting for input", body: nil,
            jumpTarget: .session(sessionID: "session"),
            display: .init(projectName: "Project", branch: "main", path: "/repo", host: nil)
        )

        init() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("attention-events.json")
            store = AttentionStore(url: url)
        }

        func makeState(attentionSettleInterval: TimeInterval = 0) -> AppState {
            AppState(
                store: MemoryStore(),
                attentionStore: AttentionStore(url: url),
                harnessAttentionSettleInterval: attentionSettleInterval
            )
        }

        func makeStateWithWorktree(
            lineageID: String? = nil, maxEvents: Int = 2_000,
            attentionSettleInterval: TimeInterval = 0
        ) -> AppState {
            let state = AppState(
                store: MemoryStore(),
                attentionStore: AttentionStore(url: url, maxEvents: maxEvents),
                harnessAttentionSettleInterval: attentionSettleInterval
            )
            let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: now)
            let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                    path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: now, lineageID: lineageID)
            state.projectsManager = ProjectsManager(persistedProjects: [project])
            state.projectsManager.insertOptimisticWorktree(worktree)
            return state
        }

        fileprivate func review(
            hasRequest: Bool = true,
            number: Int = 42,
            decision: ReviewDecision = .approved,
            threads: [ReviewThread] = [],
            areThreadsComplete: Bool = true
        ) -> ReviewLoopSnapshot {
            let remote = CodeHostRemote(
                kind: .github,
                host: "github.com",
                owner: "owner",
                repository: "repo",
                remoteName: "origin",
                webURL: URL(string: "https://github.com/owner/repo")!
            )
            let reviewRequest = hasRequest ? ReviewRequest(
                    remote: remote,
                    number: number,
                    title: "Review",
                    url: remote.webURL,
                    state: .open,
                    isDraft: false,
                    headRefName: "feature",
                    baseRefName: "main",
                    headSHA: "head",
                    reviewDecision: decision,
                    mergeState: .clean,
                    checks: [ReviewCheck(id: "ci", name: "CI", workflow: nil, bucket: .fail, detailURL: nil, completedAt: nil)],
                    threads: threads,
                    areThreadsComplete: areThreadsComplete
                )
                : nil
            return ReviewLoopSnapshot(
                local: ReviewLoopLocalState(
                    branchName: "feature",
                    headSHA: "head",
                    baseBranch: "main",
                    hasWorkingTreeChanges: false,
                    hasStagedChanges: false,
                    aheadCommitCount: 0,
                    hasUpstream: true,
                    upstreamAheadCommitCount: 0,
                    needsPush: false
                ),
                remote: remote,
                reviewRequest: reviewRequest,
                providerAvailable: true,
                providerAuthenticated: true,
                providerCapabilities: .githubCLI,
                errorMessage: nil
            )
        }

        fileprivate func thread(id: String) -> ReviewThread {
            ReviewThread(
                id: id,
                path: "a.swift",
                line: 1,
                startLine: nil,
                originalLine: nil,
                diffHunk: nil,
                isResolved: false,
                isOutdated: false,
                isFileLevel: false,
                comments: [],
                viewerCanResolve: true,
                viewerCanReply: true,
                url: nil
            )
        }

        func history(fingerprint: String) -> AttentionHistoryEvent {
            AttentionHistoryEvent(
                sourceKey: .init(rawValue: "session:session:finished"),
                fingerprint: fingerprint,
                owner: signal.owner,
                kind: .agentFinished,
                title: "Claude Code finished",
                body: nil,
                jumpTarget: .none,
                display: signal.display
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }
}

/// Reconciliation normally inspects each member's frozen `plan` and, for
/// local checkouts, the real Git lineage marker on disk. These fixtures
/// build members directly (no `plan`, no on-disk worktree), so the real
/// `WorkspaceCheckoutObserver` would downgrade every member's availability to
/// `.identityConflict` regardless of the `.available` the test constructed.
/// Stub the observer to confirm exactly what the test set up.
private struct FixtureCheckoutObserver: WorkspaceCheckoutObserving {
    func observe(_ member: WorkspaceCheckoutMember, in checkout: WorkspaceCheckout) async -> WorkspaceCheckoutMemberObservation {
        .exactLineage(member.gitLineageID ?? "fixture-lineage")
    }
}
