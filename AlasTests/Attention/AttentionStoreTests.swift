import Foundation
import Testing
@testable import Alas

@Suite("Attention store", .serialized)
@MainActor
struct AttentionStoreTests {
    @Test func acknowledgingAnAlreadyAddressedEventPreservesItsOriginalTimestamp() throws {
        let fixture = try Fixture()
        fixture.store.observe(.active(fixture.signal(fingerprint: "failure")), at: fixture.now)
        let event = try #require(fixture.store.events.first)
        let first = fixture.now.addingTimeInterval(10)
        fixture.store.acknowledge(eventID: event.id, at: first)
        fixture.store.acknowledge(eventID: event.id, at: fixture.now.addingTimeInterval(20))
        #expect(fixture.store.acknowledgments[event.id]?.acknowledgedAt == first)
    }

    @Test func distinctSourcesAndAliasesRemainBoundedAfterEventsExpire() throws {
        let fixture = try Fixture(maxEvents: 3)
        for index in 0..<30 {
            let signal = AttentionSignal(sourceKey: .init(rawValue: "script:\(index):failure"), fingerprint: "failure",
                owner: fixture.lineageOwner, kind: .runScriptFailure, title: "Tests failed", body: nil,
                jumpTarget: .runScriptFailure(failureID: "\(index)"), display: fixture.signal(fingerprint: "").display)
            fixture.store.observe(.active(signal), at: fixture.now.addingTimeInterval(Double(index)))
            fixture.store.registerAlias(from: .init(projectID: "project", location: .local, lineageID: nil, legacyPath: "/old/\(index)"), to: fixture.lineageOwner)
        }
        #expect(fixture.store.events.count == 3)
        #expect(fixture.store.document.observations.count <= 6)
        #expect(fixture.store.document.aliases.count <= 3)
        let latest = try #require(fixture.store.events.last)
        fixture.store.acknowledge(eventID: latest.id, at: fixture.now.addingTimeInterval(40))
        let reloaded = AttentionStore(url: fixture.url, now: { fixture.now }, maxEvents: 3)
        let signal = AttentionSignal(sourceKey: latest.sourceKey, fingerprint: latest.fingerprint,
            owner: latest.owner, kind: latest.kind, title: latest.title, body: latest.body,
            jumpTarget: latest.jumpTarget, display: latest.display)
        reloaded.observe(.active(signal), at: fixture.now.addingTimeInterval(50))
        #expect(reloaded.events.count == 3)
        #expect(reloaded.acknowledgments[latest.id] != nil)
    }

    @Test func repeatedActiveObservationCreatesOneEventAndRecurrenceCreatesAnother() throws {
        let fixture = try Fixture()
        let signal = fixture.signal(fingerprint: "request-1")

        fixture.store.observe(.active(signal), at: fixture.now)
        fixture.store.observe(.active(signal), at: fixture.now.addingTimeInterval(1))
        fixture.store.observe(.inactive(sourceKey: signal.sourceKey), at: fixture.now.addingTimeInterval(2))
        fixture.store.observe(.active(fixture.signal(fingerprint: "request-2")), at: fixture.now.addingTimeInterval(3))

        #expect(fixture.store.document.events.map(\.fingerprint) == ["request-1", "request-2"])
    }

    @Test func inactiveObservationWithoutPriorActiveStateIsANoop() throws {
        let fixture = try Fixture()

        fixture.store.observe(.inactive(sourceKey: .init(rawValue: "git:project:conflicts")), at: fixture.now)

        #expect(fixture.store.document.observations.isEmpty)
        #expect(fixture.store.document.events.isEmpty)
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

    @Test func malformedDocumentReportsLoadErrorAfterPersistenceRecoversFile() throws {
        let fixture = try Fixture()
        try Data("not json".utf8).write(to: fixture.url)

        let store = AttentionStore(url: fixture.url, persistence: PersistenceStore(), now: { fixture.now })

        #expect(store.loadError != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.url.path) == false)
        let contents = try FileManager.default.contentsOfDirectory(atPath: fixture.url.deletingLastPathComponent().path)
        #expect(contents.contains { $0.hasPrefix("attention-events.json.broken-") })
    }

    @Test func appendHistoryPersistsInformationalEvent() throws {
        let fixture = try Fixture()
        fixture.store.appendHistory(fixture.history(fingerprint: "finished"), at: fixture.now)

        #expect(fixture.store.document.events.count == 1)
        let event = try #require(fixture.store.document.events.first)
        #expect(event.kind == .agentFinished)
        #expect(event.requiresAction == false)
        #expect(event.occurredAt == fixture.now)
    }

    @Test func documentDecodingDefaultsMissingCollections() throws {
        let fixture = try Fixture()
        try Data("{\"schemaVersion\":1}".utf8).write(to: fixture.url)

        let store = AttentionStore(url: fixture.url, persistence: PersistenceStore(), now: { fixture.now })

        #expect(store.document.events.isEmpty)
        #expect(store.document.acknowledgments.isEmpty)
        #expect(store.document.observations.isEmpty)
        #expect(store.document.aliases.isEmpty)
    }

    @Test func laterSuccessfulWriteClearsWriteError() throws {
        let persistence = FailingThenSucceedingPersistenceStore()
        let fixture = try Fixture(persistence: persistence)

        fixture.store.observe(.active(fixture.signal(fingerprint: "first")), at: fixture.now)
        #expect(fixture.store.writeError != nil)

        fixture.store.observe(.active(fixture.signal(fingerprint: "second")), at: fixture.now)
        #expect(fixture.store.writeError == nil)
    }

    @Test func retentionExpiresAddressedEventsOlderThanThirtyDays() throws {
        let fixture = try Fixture()
        let eventDate = fixture.now.addingTimeInterval(-31 * 86_400)
        fixture.store.observe(.active(fixture.signal(fingerprint: "old")), at: eventDate)
        #expect(fixture.store.document.events.count == 1)
        let event = try #require(fixture.store.document.events.first)

        fixture.store.acknowledge(eventID: event.id, at: fixture.now)

        #expect(fixture.store.document.events.isEmpty)
    }

    @Test func hardCapPrunesOldestAddressedEventByOccurrenceDate() throws {
        let fixture = try Fixture(maxEvents: 2)
        fixture.store.observe(.active(fixture.signal(fingerprint: "newest")), at: fixture.now.addingTimeInterval(100))
        let newest = try #require(fixture.store.document.events.last)
        fixture.store.acknowledge(eventID: newest.id, at: fixture.now.addingTimeInterval(100))

        fixture.store.observe(.active(fixture.signal(fingerprint: "oldest")), at: fixture.now)
        let oldest = try #require(fixture.store.document.events.last)
        fixture.store.acknowledge(eventID: oldest.id, at: fixture.now.addingTimeInterval(100))

        fixture.store.observe(.active(fixture.signal(fingerprint: "unresolved")), at: fixture.now.addingTimeInterval(200))

        #expect(fixture.store.document.events.map(\.fingerprint) == ["newest", "unresolved"])
    }

    @MainActor
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

        init(
            persistence: any PersistenceStoreProtocol = PersistenceStore(),
            maxEvents: Int = 2_000,
            resolvedRetention: TimeInterval = 30 * 86_400
        ) throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("attention-events.json")
            store = AttentionStore(
                url: url,
                persistence: persistence,
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

        func history(fingerprint: String) -> AttentionHistoryEvent {
            AttentionHistoryEvent(
                sourceKey: AttentionSourceKey(rawValue: "session:1"),
                fingerprint: fingerprint,
                owner: lineageOwner,
                kind: .agentFinished,
                title: "Agent finished",
                body: nil,
                jumpTarget: .none,
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

private final class FailingThenSucceedingPersistenceStore: PersistenceStoreProtocol {
    private var shouldFail = true

    func write<T: Encodable>(_ value: T, to url: URL) throws {
        if shouldFail {
            shouldFail = false
            throw TestError.writeFailed
        }
    }

    func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        nil
    }

    private enum TestError: Error {
        case writeFailed
    }
}
