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
        #expect(state.attentionStore.events.first?.fingerprint == "b.swift|c.swift")
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

        #expect(state.attentionStore.document.observations[migratedKey]?.isActive == false)
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

        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: complete, at: fixture.now.addingTimeInterval(2))

        #expect(state.attentionStore.document.observations[feedbackKey]?.isActive == false)
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

    @Test func acpResponseInteractionAcknowledgesSessionAttention() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree()
        _ = state.tabs.appendACP(owner: .worktree("worktree"), sessionId: "session", title: "Agent")
        state.selectedWorktreeId = "worktree"
        state.harness.setExternalActivity(sessionId: "session", owner: .worktree("worktree"), agent: .claude, state: .awaitingInput)

        let item = try #require(state.attentionAggregation.items.first)
        state.acknowledgeACPResponseInteraction(owner: .worktree("worktree"), sessionID: "session")

        #expect(state.attentionStore.acknowledgments[item.eventID] != nil)
        #expect(state.attentionAggregation.unresolvedCount == 0)
    }

    @Test func hookResponseInteractionAcknowledgesSessionAttention() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree()
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Agent", sessionId: "session")
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput)

        let item = try #require(state.attentionAggregation.items.first)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .busy)

        #expect(state.attentionStore.acknowledgments[item.eventID] != nil)
        #expect(state.attentionAggregation.unresolvedCount == 0)
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
        #expect(state.attentionAggregation.unresolvedCount == 1)
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

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "First question")
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Second question")
        #expect(state.attentionStore.events.count == 2)
        #expect(state.attentionStore.events.last?.body == "Second question")
        #expect(state.attentionAggregation.items.first?.presentation == .live)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .permissionRequest)
        #expect(state.attentionAggregation.unresolvedCount == 2)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .idle)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .idle)

        #expect(state.attentionStore.events.map(\.kind) == [.agentAwaiting, .agentAwaiting, .agentPermission, .agentFinished])
        #expect(state.attentionAggregation.items.allSatisfy { $0.presentation == .historical })
        #expect(state.attentionAggregation.items.contains { $0.title == "Claude Code waited for input" })
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
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput)
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
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput)

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

        let item = try #require(state.attentionAggregation.items.first)

        #expect(item.worktree?.id == worktree.id)
        #expect(state.attentionStore.document.aliases[legacyOwner]?.lineageID == "lineage")
    }

    @Test func inboxRestoresOriginalTabAfterRepeatedOpen() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeState()
        let first = state.tabs.appendTerminal(worktreeId: "worktree", title: "First", sessionId: "first")
        state.selectedWorktreeId = "worktree"
        state.openAttentionInbox()
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Second", sessionId: "second")
        state.openAttentionInbox()
        state.closeAttentionInbox()

        #expect(!state.isAttentionInboxOpen)
        #expect(state.selectedWorktreeId == "worktree")
        #expect(state.tabs.activeTabId(forWorktree: "worktree") == first.id)
    }

    @Test func closingInboxKeepsFallbackWhenSavedWorktreeDisappears() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree()
        state.selectedWorktreeId = "worktree"

        state.openAttentionInbox()
        state.projectsManager = ProjectsManager(persistedProjects: [])
        state.selectedWorktreeId = nil
        state.closeAttentionInbox()

        #expect(!state.isAttentionInboxOpen)
        #expect(state.selectedWorktreeId == nil)
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
        let state = AppState(
            store: MemoryStore(),
            workspacesManager: workspacesManager,
            workspaceStore: workspaceStore,
            attentionStore: AttentionStore(url: fixture.url)
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        state.selectedWorktreeId = worktree.id
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let tab = state.tabs.appendACP(owner: owner, sessionId: "shared-acp", title: "Shared agent")

        state.harness.setExternalActivity(sessionId: "shared-acp", owner: owner, agent: AgentKind.claude, state: ActivityState.awaitingInput)
        let item = try #require(state.attentionAggregation.items.first)

        let result = await state.openAttentionItem(item)

        #expect(result == .opened)
        #expect(state.selectedWorkspaceCheckout?.id == checkout.id)
        #expect(state.workspaceNavigationState.repositoryFocusWorktreeID == worktree.id)
        #expect(state.tabs.activeTabId(for: owner) == tab.id)
        #expect(state.tabs.activeTabId(forWorktree: worktree.id) == nil)
        #expect(state.attentionAggregation.unresolvedCount == 0)
    }

    @Test func checkoutOwnedHistoricalSessionClearsFromFocusedDifferentMember() async throws {
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
        state.attentionStore.observe(.inactive(sourceKey: signal.sourceKey), at: fixture.now.addingTimeInterval(1))
        state.selectedWorktreeId = second.id
        state.tabs.activate(owner: owner, tabId: tab.id)

        state.acknowledgeFocusedSessionAttention(worktreeID: second.id, owner: owner, tabID: tab.id)

        #expect(state.attentionAggregation.unresolvedCount == 0)
    }

    @Test func checkoutOwnedHistoricalSessionOpensThroughSurvivingMemberWhenOriginalMemberIsGone() async throws {
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
        state.attentionStore.observe(.inactive(sourceKey: signal.sourceKey), at: fixture.now.addingTimeInterval(1))
        state.projectsManager.removeOptimisticWorktree(id: first.id, projectId: project.id)
        state.selectedWorktreeId = second.id
        let item = try #require(state.attentionAggregation.items.first)

        let result = await state.openAttentionItem(item)

        #expect(result == .opened)
        #expect(state.selectedWorkspaceCheckout?.id == checkout.id)
        #expect(state.workspaceNavigationState.repositoryFocusWorktreeID == second.id)
        #expect(state.tabs.activeTabId(for: owner) == tab.id)
        #expect(state.attentionStore.acknowledgments[item.eventID] != nil)
    }

    @Test func closingInboxRestoresWorkspaceCheckoutNavigation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        let workspacesManager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore))
        let workspaceID = UUID()
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: fixture.now)
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        let memberID = UUID()
        let checkout = WorkspaceCheckout(
            workspaceID: workspaceID,
            fallbackWorkspaceName: "Shared",
            executionLocation: .local,
            branch: "topic",
            rootPath: "/repo",
            members: [
                WorkspaceCheckoutMember(
                    workspaceMemberID: memberID,
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
            attentionStore: AttentionStore(url: fixture.url)
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        state.selectWorkspaceCheckout(id: checkout.id)
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let sharedTab = state.tabs.appendACP(owner: owner, sessionId: "shared-acp", title: "Shared agent")
        state.tabs.activate(owner: owner, tabId: sharedTab.id)

        state.openAttentionInbox()
        state.selectWorktree(id: Optional<String>.none)
        state.closeAttentionInbox()

        #expect(state.selectedWorkspaceCheckout?.id == checkout.id)
        #expect(state.workspaceNavigationState.focusedCheckoutMemberID == memberID)
        #expect(state.workspaceNavigationState.repositoryFocusWorktreeID == worktree.id)
        #expect(state.selectedWorktreeId == worktree.id)
        #expect(state.tabs.activeTabId(for: owner) == sharedTab.id)
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
        let writeCountAfterFailure = persistence.writeCount
        let host = "online-\(UUID().uuidString)"
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue",
                                    addedAt: fixture.now, host: host)
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        RemoteHostStatusStore.shared.reportSuccess(host: host)

        _ = state.attentionAggregation

        #expect(persistence.writeCount == writeCountAfterFailure)
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
    private struct Fixture {
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

        func makeState() -> AppState {
            AppState(store: MemoryStore(), attentionStore: AttentionStore(url: url))
        }

        func makeStateWithWorktree(lineageID: String? = nil, maxEvents: Int = 2_000) -> AppState {
            let state = AppState(store: MemoryStore(), attentionStore: AttentionStore(url: url, maxEvents: maxEvents))
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
