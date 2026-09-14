import Foundation
import Testing
@testable import Alas

@Suite("Attention signal aggregation")
struct AttentionSignalAggregatorTests {
    @Test func missingLiveDataPreservesCurrentRequestAsUnverified() throws {
        let fixture = Fixture()
        let event = fixture.awaitingEvent()
        let document = fixture.document(events: [event])
        let live = AttentionLiveSignal(eventID: event.id, signal: fixture.awaitingSignal(), isCurrentlyActive: true)

        let active = AttentionSignalAggregator.aggregate(
            liveSignals: [live], document: document, worktrees: fixture.worktrees
        )
        #expect(active.unresolvedCount == 1)
        #expect(active.items.first?.presentation == .live)

        let unverified = AttentionSignalAggregator.aggregate(
            liveSignals: [], document: document, worktrees: fixture.worktrees
        )
        #expect(unverified.unresolvedCount == 1)
        #expect(unverified.items.first?.eventID == event.id)
        #expect(unverified.items.first?.presentation == .unverified)
        #expect(unverified.history.isEmpty)
    }

    @Test func supersededAndResolvedRequestsRemainOnlyInHistory() throws {
        let fixture = Fixture()
        let events = (0..<5).map { _ in fixture.awaitingEvent() }
        let latest = try #require(events.last)
        var document = fixture.document(events: events)
        let active = AttentionSignalAggregator.aggregate(
            liveSignals: [], document: document, worktrees: fixture.worktrees
        )
        #expect(active.items.map(\.eventID) == [latest.id])
        #expect(active.unresolvedCount == 1)
        #expect(Set(active.history.map(\.eventID)) == Set(events.dropLast().map(\.id)))

        document.observations[latest.sourceKey] = .init(isActive: false, fingerprint: nil, eventID: latest.id)
        let resolved = AttentionSignalAggregator.aggregate(
            liveSignals: [], document: document, worktrees: fixture.worktrees
        )
        #expect(resolved.items.isEmpty)
        #expect(resolved.unresolvedCount == 0)
        #expect(Set(resolved.history.map(\.eventID)) == Set(events.map(\.id)))
        #expect(resolved.history.allSatisfy { $0.presentation == .historical })
    }

    @Test(arguments: [
        AttentionKind.agentReady, .gitOperation, .reviewReply, .failedChecks,
        .actionableFeedback, .reviewSyncBlocked, .agentFinished
    ])
    func informationalEventsStayQuietEvenWithLegacyActionFlag(kind: AttentionKind) {
        let fixture = Fixture()
        let signal = fixture.awaitingSignal()
        let event = AttentionEvent(
            id: UUID(), sourceKey: signal.sourceKey, fingerprint: signal.fingerprint,
            owner: signal.owner, kind: kind, title: "Activity", body: nil,
            jumpTarget: signal.jumpTarget, display: signal.display,
            occurredAt: fixture.now, requiresAction: true
        )
        let result = AttentionSignalAggregator.aggregate(
            liveSignals: [], document: fixture.document(events: [event]), worktrees: fixture.worktrees
        )
        #expect(result.unresolvedCount == 0)
        #expect(result.unresolvedCountByProject.isEmpty)
        #expect(result.items.isEmpty)
        #expect(result.history.map(\.eventID) == [event.id])
    }

    @Test func acknowledgmentSilencesCurrentRequestWithoutClaimingResolution() {
        let fixture = Fixture()
        let event = fixture.awaitingEvent()
        var document = fixture.document(events: [event])
        document.acknowledgments[event.id] = .init(eventID: event.id, acknowledgedAt: fixture.now)
        let live = AttentionLiveSignal(eventID: event.id, signal: fixture.awaitingSignal(), isCurrentlyActive: true)
        let result = AttentionSignalAggregator.aggregate(
            liveSignals: [live], document: document, worktrees: fixture.worktrees
        )
        #expect(result.unresolvedCount == 0)
        #expect(result.items.isEmpty)
        #expect(result.history.first?.eventID == event.id)
        #expect(result.history.first?.presentation == .live)
        #expect(result.history.first?.acknowledgedAt == fixture.now)
    }

    @Test func projectBadgesCountCurrentUnacknowledgedRequests() {
        let fixture = Fixture()
        let first = fixture.awaitingEvent(sourceKey: .init(rawValue: "session:first"))
        let second = fixture.awaitingEvent(sourceKey: .init(rawValue: "session:second"))
        let acknowledged = fixture.awaitingEvent(sourceKey: .init(rawValue: "session:acknowledged"))
        let otherProject = AttentionEvent(
            signal: AttentionSignal(
                sourceKey: .init(rawValue: "other-project:session"), fingerprint: "request",
                owner: .init(projectID: "other-project", location: .local, lineageID: nil, legacyPath: "/other"),
                kind: .agentPermission, title: "Permission requested", body: nil,
                jumpTarget: .session(sessionID: "other-session"),
                display: .init(projectName: "Other", branch: "main", path: "/other", host: nil)
            ),
            occurredAt: fixture.now
        )
        var document = fixture.document(events: [first, second, acknowledged, otherProject, fixture.finishedEvent(id: UUID())])
        document.acknowledgments[acknowledged.id] = .init(eventID: acknowledged.id, acknowledgedAt: fixture.now)

        let result = AttentionSignalAggregator.aggregate(liveSignals: [], document: document, worktrees: fixture.worktrees)
        #expect(result.unresolvedCount == 3)
        #expect(result.unresolvedCountByProject == ["project": 2, "other-project": 1])
        #expect(Set(result.items.map(\.eventID)) == [first.id, second.id, otherProject.id])
        #expect(result.history.count == 2)
    }

    @Test func resolverUsesAliasToFindRenamedLineageWorktree() {
        let fixture = Fixture()
        let legacy = AttentionWorktreeIdentity(
            projectID: "project",
            location: .local,
            lineageID: nil,
            legacyPath: "/repo/old"
        )
        let current = AttentionWorktreeIdentity.make(
            worktree: fixture.worktrees[0].worktree,
            project: fixture.localProject
        )
        let resolver = AttentionWorktreeResolver(
            worktrees: fixture.worktrees,
            aliases: [legacy: current]
        )

        #expect(resolver.resolve(legacy)?.display.path == "/repo/current")
    }

    @Test func lineageIdentitySurvivesPathRenameAndBranchSwitch() {
        let fixture = Fixture()
        let before = fixture.worktree(path: "/tmp/old", branch: "feature", lineageID: "lineage-1")
        let after = fixture.worktree(path: "/tmp/new", branch: "main", lineageID: "lineage-1")

        #expect(
            AttentionWorktreeIdentity.make(worktree: before, project: fixture.localProject)
                == AttentionWorktreeIdentity.make(worktree: after, project: fixture.localProject)
        )

        let event = fixture.awaitingEvent()
        let result = AttentionSignalAggregator.aggregate(
            liveSignals: [], document: fixture.document(events: [event]),
            worktrees: [AttentionWorktree(worktree: after, project: fixture.localProject)]
        )
        #expect(result.items.first?.worktree?.id == "/tmp/new")
        #expect(result.items.first?.display.path == "/tmp/new")
        #expect(result.items.first?.display.branch == "main")
        #expect(result.items.first?.occurredAt == fixture.now)
        #expect(result.items.first?.jumpTarget == .session(sessionID: "session-1"))
    }

    @Test func equalRemotePathsOnDifferentHostsDoNotCollide() {
        let fixture = Fixture()
        let left = AttentionWorktreeIdentity.make(
            worktree: fixture.remoteWorktree,
            project: fixture.project(host: "dev-a")
        )
        let right = AttentionWorktreeIdentity.make(
            worktree: fixture.remoteWorktree,
            project: fixture.project(host: "dev-b")
        )

        #expect(left != right)
    }

    @Test func missingWorktreeKeepsSnapshotAttribution() {
        let fixture = Fixture()
        let event = fixture.awaitingEvent()

        let aggregation = AttentionSignalAggregator.aggregate(
            liveSignals: [],
            document: fixture.document(events: [event]),
            worktrees: []
        )

        #expect(aggregation.items[0].worktree == nil)
        #expect(aggregation.items[0].display.path == "/repo/old")
    }

    private struct Fixture {
        let now = Date(timeIntervalSince1970: 1_000)
        let localProject = ProjectConfig(
            id: "project", name: "Project", path: "/repo", color: "blue", addedAt: .distantPast
        )

        var worktrees: [AttentionWorktree] {
            [AttentionWorktree(worktree: worktree(path: "/repo/current", branch: "main", lineageID: "lineage-1"), project: localProject)]
        }

        var remoteWorktree: Worktree {
            worktree(path: "/repo/current", branch: "main", lineageID: "lineage-1")
        }

        func project(host: String) -> ProjectConfig {
            ProjectConfig(
                id: "project", name: "Project", path: "/repo", color: "blue", addedAt: .distantPast, host: host
            )
        }

        func worktree(path: String, branch: String, lineageID: String?) -> Worktree {
            Worktree(
                id: path,
                projectId: "project",
                name: branch,
                branch: branch,
                path: URL(fileURLWithPath: path),
                status: .clean,
                lastActivity: now,
                lineageID: lineageID
            )
        }

        func awaitingSignal(sourceKey: AttentionSourceKey = .init(rawValue: "session:1")) -> AttentionSignal {
            AttentionSignal(
                sourceKey: sourceKey,
                fingerprint: "request-1",
                owner: AttentionWorktreeIdentity.make(worktree: worktrees[0].worktree, project: localProject),
                kind: .agentAwaiting,
                title: "Codex is waiting for input",
                body: nil,
                jumpTarget: .session(sessionID: "session-1"),
                display: AttentionWorktreeDisplaySnapshot(projectName: "Project", branch: "feature", path: "/repo/old", host: nil)
            )
        }

        func awaitingEvent(id: UUID = UUID(), title: String = "Codex is waiting for input",
                           sourceKey: AttentionSourceKey = .init(rawValue: "session:1")) -> AttentionEvent {
            var signal = awaitingSignal(sourceKey: sourceKey)
            signal = AttentionSignal(
                sourceKey: signal.sourceKey,
                fingerprint: signal.fingerprint,
                owner: signal.owner,
                kind: signal.kind,
                title: title,
                body: signal.body,
                jumpTarget: signal.jumpTarget,
                display: signal.display
            )
            return AttentionEvent(id: id, signal: signal, occurredAt: now)
        }

        func finishedEvent(id: UUID) -> AttentionEvent {
            AttentionEvent(
                id: id,
                history: AttentionHistoryEvent(
                    sourceKey: AttentionSourceKey(rawValue: "finished:1"),
                    fingerprint: "finished-1",
                    owner: awaitingSignal().owner,
                    kind: .agentFinished,
                    title: "Codex finished",
                    body: nil,
                    jumpTarget: .none,
                    display: awaitingSignal().display
                ),
                occurredAt: now.addingTimeInterval(1)
            )
        }

        func document(events: [AttentionEvent]) -> AttentionDocument {
            var observations: [AttentionSourceKey: AttentionStoredObservation] = [:]
            for event in events {
                observations[event.sourceKey] = .init(isActive: true, fingerprint: event.fingerprint, eventID: event.id)
            }
            return AttentionDocument(events: events, observations: observations)
        }
    }
}
