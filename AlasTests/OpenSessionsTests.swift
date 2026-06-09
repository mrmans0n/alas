import Foundation
import Testing
@testable import Alas

@Suite
struct OpenSessionsTests {
    // MARK: - relativeAge

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func relativeAgeNilWhenNoTimestamp() {
        #expect(relativeAge(createdEpoch: nil, now: now) == nil)
    }

    @Test func relativeAgeNilWhenInFuture() {
        #expect(relativeAge(createdEpoch: 1_000_100, now: now) == nil)
    }

    @Test func relativeAgeJustNowUnderAMinute() {
        #expect(relativeAge(createdEpoch: 1_000_000 - 30, now: now) == "just now")
    }

    @Test func relativeAgeMinutes() {
        #expect(relativeAge(createdEpoch: 1_000_000 - 5 * 60, now: now) == "5m ago")
    }

    @Test func relativeAgeHours() {
        #expect(relativeAge(createdEpoch: 1_000_000 - 3 * 3600, now: now) == "3h ago")
    }

    @Test func relativeAgeDays() {
        #expect(relativeAge(createdEpoch: 1_000_000 - 2 * 86_400, now: now) == "2d ago")
    }

    @Test func relativeAgeExactlyAtMinuteBoundary() {
        #expect(relativeAge(createdEpoch: 1_000_000 - 60, now: now) == "1m ago")
    }

    @Test func relativeAgeExactlyAtHourBoundary() {
        #expect(relativeAge(createdEpoch: 1_000_000 - 3600, now: now) == "1h ago")
    }

    @Test func relativeAgeExactlyAtDayBoundary() {
        #expect(relativeAge(createdEpoch: 1_000_000 - 86_400, now: now) == "1d ago")
    }

    // MARK: - classifier

    private func info(
        _ name: String, clients: Int? = nil, dir: String? = nil,
        cmd: String? = nil, created: Int? = nil
    ) -> ZmxSessionInfo {
        ZmxSessionInfo(name: name, startDir: dir, pid: nil, clients: clients, created: created, cmd: cmd)
    }

    @Test func classifySplitsActiveFromOrphaned() {
        let tracked = [
            TrackedSessionRef(leafId: "leaf-1", worktreeId: "wt-1", zmxSessionName: "alas-aaaa-1111"),
        ]
        let infos = [
            info("alas-aaaa-1111", clients: 1, dir: "/work/one"),  // active (tracked)
            info("alas-bbbb-2222", clients: 0, dir: "/work/two"),  // orphan idle
            info("alas-cccc-3333", clients: 2, dir: "/work/three"), // orphan in-use
        ]

        let snap = OpenSessionsClassifier.classify(infos: infos, tracked: tracked, sessionPrefix: "")

        #expect(snap.active.map(\.name) == ["alas-aaaa-1111"])
        #expect(snap.active.first?.kind == .active(leafId: "leaf-1", worktreeId: "wt-1"))
        #expect(snap.orphaned.map(\.name) == ["alas-bbbb-2222", "alas-cccc-3333"])
        #expect(snap.orphaned[0].kind == .orphanIdle)
        #expect(snap.orphaned[1].kind == .orphanInUse)
    }

    @Test func classifyTrackedSessionWithZeroClientsStaysActiveNotOrphan() {
        // A tracked tab whose daemon reports clients=0 must NOT leak into the
        // orphaned/idle bucket — otherwise killIdleOrphans could reap a live tab.
        let tracked = [
            TrackedSessionRef(leafId: "leaf-1", worktreeId: "wt-1", zmxSessionName: "alas-aaaa-1111"),
        ]
        let infos = [info("alas-aaaa-1111", clients: 0)]
        let snap = OpenSessionsClassifier.classify(infos: infos, tracked: tracked, sessionPrefix: "")
        #expect(snap.active.map(\.name) == ["alas-aaaa-1111"])
        #expect(snap.orphaned.isEmpty)
    }

    @Test func classifyTreatsUnknownClientCountAsInUse() {
        let infos = [info("alas-bbbb-2222", clients: nil, dir: "/x")]
        let snap = OpenSessionsClassifier.classify(infos: infos, tracked: [], sessionPrefix: "")
        #expect(snap.orphaned.first?.kind == .orphanInUse)
    }

    @Test func classifyIgnoresNonAlasSessions() {
        let infos = [info("tmux-default", clients: 0), info("zellij-x", clients: 1)]
        let snap = OpenSessionsClassifier.classify(infos: infos, tracked: [], sessionPrefix: "")
        #expect(snap.isEmpty)
    }

    @Test func classifyShowsLegacyUnscopedAsOrphan() {
        // Legacy `alas-<uuid>` names are still ours and should appear.
        let infos = [info("alas-DEADBEEF-1234-5678", clients: 0, dir: "/legacy")]
        let snap = OpenSessionsClassifier.classify(infos: infos, tracked: [], sessionPrefix: "")
        #expect(snap.orphaned.map(\.name) == ["alas-DEADBEEF-1234-5678"])
        #expect(snap.orphaned.first?.kind == .orphanIdle)
    }

    @Test func classifyKeepsTrackedTabWhenDaemonDied() {
        // Tracked session has no matching `zmx ls` row (daemon gone) — still
        // shown as active so the user can close it cleanly.
        let tracked = [
            TrackedSessionRef(leafId: "leaf-9", worktreeId: "wt-9", zmxSessionName: "alas-dead-beef"),
        ]
        let snap = OpenSessionsClassifier.classify(infos: [], tracked: tracked, sessionPrefix: "")
        #expect(snap.active.map(\.name) == ["alas-dead-beef"])
        #expect(snap.active.first?.startDir == nil)
    }

    @Test func classifySkipsTrackedRefsWithoutZmxName() {
        let tracked = [TrackedSessionRef(leafId: "leaf-x", worktreeId: "wt-x", zmxSessionName: nil)]
        let snap = OpenSessionsClassifier.classify(infos: [], tracked: tracked, sessionPrefix: "")
        #expect(snap.isEmpty)
    }

    @Test func classifyStripsSessionPrefixBeforeMatching() {
        let tracked = [
            TrackedSessionRef(leafId: "leaf-1", worktreeId: "wt-1", zmxSessionName: "alas-aaaa-1111"),
        ]
        let infos = [
            info("dev_alas-aaaa-1111", clients: 1),  // prefixed match -> active
            info("dev_alas-bbbb-2222", clients: 0),  // prefixed orphan
            info("other_alas-cccc-3333", clients: 0), // wrong prefix -> ignored
        ]
        let snap = OpenSessionsClassifier.classify(infos: infos, tracked: tracked, sessionPrefix: "dev_")
        #expect(snap.active.map(\.name) == ["alas-aaaa-1111"])
        #expect(snap.orphaned.map(\.name) == ["alas-bbbb-2222"])
        #expect(snap.active.first?.clients == 1)
    }
}
