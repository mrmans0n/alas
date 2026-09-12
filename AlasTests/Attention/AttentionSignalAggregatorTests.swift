import Foundation
import Testing
@testable import Alas

@Suite("Attention signal aggregation")
struct AttentionSignalAggregatorTests {
    @Test(arguments: [
        (AttentionKind.agentAwaiting, "Codex is waiting for input", "Codex waited for input"),
        (AttentionKind.conflicts, "2 unresolved conflicts", "2 conflicts required resolution"),
        (AttentionKind.actionableFeedback, "Review feedback needs action", "Review feedback required action")
    ])
    func historicalTitlesUsePastTenseWithoutClaimingLiveState(
        kind: AttentionKind, title: String, expected: String
    ) {
        #expect(kind.historicalTitle(from: title) == expected)
    }

    @Test func aggregationCountsItemsAndUsesHistoricalCopyAfterLiveStateDisappears() throws {
        let fixture = Fixture()
        let event = fixture.awaitingEvent(title: "Codex is waiting for input")
        let document = fixture.document(events: [event])
        let live = AttentionLiveSignal(
            eventID: event.id,
            signal: fixture.awaitingSignal(),
            isCurrentlyActive: true
        )

        let active = AttentionSignalAggregator.aggregate(
            liveSignals: [live],
            document: document,
            worktrees: fixture.worktrees
        )
        #expect(active.unresolvedCount == 1)
        #expect(active.unresolvedCountByProject == ["project": 1])
        #expect(active.items[0].presentation == .live)
        #expect(active.items[0].worktree?.display.path == "/repo/current")

        let historical = AttentionSignalAggregator.aggregate(
            liveSignals: [],
            document: document,
            worktrees: fixture.worktrees
        )
        #expect(historical.items[0].presentation == .historical)
        #expect(historical.items[0].title == "Codex waited for input")
    }

    @Test func acknowledgedAndInformationalEventsAppearOnlyInHistory() {
        let fixture = Fixture()
        let acknowledged = fixture.awaitingEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let informational = fixture.finishedEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let document = AttentionDocument(
            events: [acknowledged, informational],
            acknowledgments: [
                acknowledged.id: AttentionAcknowledgment(eventID: acknowledged.id, acknowledgedAt: fixture.now)
            ]
        )

        let aggregation = AttentionSignalAggregator.aggregate(
            liveSignals: [],
            document: document,
            worktrees: fixture.worktrees
        )

        #expect(aggregation.items.isEmpty)
        #expect(aggregation.history.map(\.eventID) == [informational.id, acknowledged.id])
    }

    @Test func projectBadgesCountUnresolvedItemsAcrossWorktreesAndProjects() {
        let fixture = Fixture()
        let first = fixture.awaitingEvent()
        let second = fixture.awaitingEvent()
        let acknowledged = fixture.awaitingEvent()
        let otherProject = AttentionEvent(
            signal: AttentionSignal(
                sourceKey: .init(rawValue: "other-project:session"), fingerprint: "request",
                owner: .init(projectID: "other-project", location: .local, lineageID: nil, legacyPath: "/other"),
                kind: .agentAwaiting, title: "Codex is waiting for input", body: nil,
                jumpTarget: .session(sessionID: "other-session"),
                display: .init(projectName: "Other", branch: "main", path: "/other", host: nil)
            ),
            occurredAt: fixture.now
        )
        let document = AttentionDocument(
            events: [first, second, acknowledged, otherProject, fixture.finishedEvent(id: UUID())],
            acknowledgments: [acknowledged.id: .init(eventID: acknowledged.id, acknowledgedAt: fixture.now)]
        )

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

        func awaitingSignal() -> AttentionSignal {
            AttentionSignal(
                sourceKey: AttentionSourceKey(rawValue: "session:1"),
                fingerprint: "request-1",
                owner: AttentionWorktreeIdentity.make(worktree: worktrees[0].worktree, project: localProject),
                kind: .agentAwaiting,
                title: "Codex is waiting for input",
                body: nil,
                jumpTarget: .session(sessionID: "session-1"),
                display: AttentionWorktreeDisplaySnapshot(projectName: "Project", branch: "feature", path: "/repo/old", host: nil)
            )
        }

        func awaitingEvent(id: UUID = UUID(), title: String = "Codex is waiting for input") -> AttentionEvent {
            var signal = awaitingSignal()
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
            AttentionDocument(events: events)
        }
    }
}
