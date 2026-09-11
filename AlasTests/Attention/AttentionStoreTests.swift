import Foundation
import Testing
@testable import Alas

@Suite("Attention store", .serialized)
@MainActor
struct AttentionStoreTests {
    @Test func repeatedActiveObservationCreatesOneEventAndRecurrenceCreatesAnother() throws {
        let fixture = try Fixture()
        let signal = fixture.signal(fingerprint: "request-1")

        fixture.store.observe(.active(signal), at: fixture.now)
        fixture.store.observe(.active(signal), at: fixture.now.addingTimeInterval(1))
        fixture.store.observe(.inactive(sourceKey: signal.sourceKey), at: fixture.now.addingTimeInterval(2))
        fixture.store.observe(.active(fixture.signal(fingerprint: "request-2")), at: fixture.now.addingTimeInterval(3))

        #expect(fixture.store.document.events.map(\.fingerprint) == ["request-1", "request-2"])
    }

    @Test func acknowledgmentAndAliasSurviveRelaunch() throws {
        let fixture = try Fixture()
        fixture.store.observe(.active(fixture.signal(fingerprint: "request-1")), at: fixture.now)
        let event = try #require(fixture.store.document.events.first)
        fixture.store.acknowledge(eventID: event.id, at: fixture.now.addingTimeInterval(5))
        fixture.store.registerAlias(from: fixture.legacyOwner, to: fixture.lineageOwner)

        let reloaded = AttentionStore(url: fixture.url, persistence: PersistenceStore(), now: { fixture.now })
        #expect(reloaded.document.acknowledgments[event.id]?.acknowledgedAt == fixture.now.addingTimeInterval(5))
        #expect(reloaded.document.aliases[fixture.legacyOwner] == fixture.lineageOwner)
    }

    @Test func retentionPrunesOldAddressedEventsBeforeEnforcingHardCap() throws {
        let fixture = try Fixture(maxEvents: 3, resolvedRetention: 30 * 86_400)
        for index in 0..<4 {
            let date = fixture.now.addingTimeInterval(TimeInterval(index))
            let signal = fixture.signal(fingerprint: "request-\(index)")
            fixture.store.observe(.active(signal), at: date)
            let event = try #require(fixture.store.document.events.last)
            if index < 2 { fixture.store.acknowledge(eventID: event.id, at: date) }
            fixture.store.observe(.inactive(sourceKey: signal.sourceKey), at: date)
        }
        #expect(fixture.store.document.events.count == 3)
        #expect(fixture.store.document.events.contains { $0.fingerprint == "request-0" } == false)
    }

    private struct Fixture {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let url: URL
        let legacyOwner = AttentionWorktreeIdentity(
            projectID: "project",
            location: .local,
            lineageID: nil,
            legacyPath: "/repo"
        )
        let lineageOwner = AttentionWorktreeIdentity(
            projectID: "project",
            location: .local,
            lineageID: "lineage",
            legacyPath: nil
        )
        let store: AttentionStore

        init(maxEvents: Int = 2_000, resolvedRetention: TimeInterval = 30 * 86_400) throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("attention-events.json")
            store = AttentionStore(
                url: url,
                persistence: PersistenceStore(),
                now: { Date(timeIntervalSince1970: 1_000_000) },
                maxEvents: maxEvents,
                resolvedRetention: resolvedRetention
            )
        }

        func signal(fingerprint: String) -> AttentionSignal {
            AttentionSignal(
                sourceKey: AttentionSourceKey(rawValue: "session:1"),
                fingerprint: fingerprint,
                owner: lineageOwner,
                kind: .agentAwaiting,
                title: "Agent is waiting for input",
                body: nil,
                jumpTarget: .session(sessionID: "session-1"),
                display: AttentionWorktreeDisplaySnapshot(
                    projectName: "Project",
                    branch: "main",
                    path: "/repo",
                    host: nil
                )
            )
        }
    }
}
