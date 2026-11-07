import Testing
import Foundation
import Synchronization
@testable import AlasCore
@testable import AlasHostCore

struct PersistenceStoreTests {
    struct Sample: Codable, Equatable { let name: String
    let count: Int }

    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-store-\(UUID().uuidString).json")
    }

    @Test func newPreviewKindSurvivesReopenBeforeBrokerBinding() throws {
        let store = try ACPSessionStore(path: tmpURL().path)
        defer { try? FileManager.default.removeItem(atPath: store.path) }
        let fence = try store.createV2PreviewSession(row: previewRow(), ownerInstance: "A", pid: 1, now: 1, leaseToken: "owner")
        let reopened = try ACPSessionStore(path: store.path)
        let row = try #require(try reopened.loadSession(id: "preview"))
        #expect(row.runtimeKind == .v2FreshPreview)
        #expect(row.acpBrokerId == nil)
        #expect(try reopened.loadLease(sessionId: "preview")?.token == fence.token)
        // Readers predating runtime_kind already refuse the reserved raw context.
        #expect(throws: (any Error).self) { try ACPBrokerRestorePolicy.resolve(row: row, supportedVersions: [.v1]) }
        #expect(try reopened.bindV2FreshBroker(state: .init(brokerId: .init(rawValue: "fresh"),
            generation: .init(rawValue: 1), acknowledgedCursor: .init(rawValue: 0), wireContext: .rawV2), fence: fence))
        #expect(try reopened.loadSession(id: "preview")?.runtimeKind == .v2FreshPreview)
    }

    @Test(arguments: ["v1", "v2FreshPreview", "futureRuntime"])
    func runtimeKindCannotBeChangedByBroadUpsert(stored: String) throws {
        let store = try ACPSessionStore(path: tmpURL().path)
        defer { try? FileManager.default.removeItem(atPath: store.path) }
        var row = previewRow()
        row.runtimeKind = .init(rawValue: stored)
        try store.upsertSession(row)
        row.runtimeKind = stored == "v1" ? .v2FreshPreview : .v1
        row.title = "Updated"
        try store.upsertSession(row)
        let loaded = try #require(try store.loadSession(id: row.id))
        #expect(loaded.runtimeKind.rawValue == stored)
        #expect(loaded.title == "Updated")
    }

    @Test(arguments: ["empty", "history", "lease", "lease-failure"])
    func previewCreationDoesNotUpgradeAnExistingRow(state: String) throws {
        let store = try ACPSessionStore(path: tmpURL().path)
        defer { try? FileManager.default.removeItem(atPath: store.path) }
        if state != "lease-failure" { try store.upsertSession(previewRow()) }
        if state == "history" { try store.db.exec("INSERT INTO messages VALUES ('m','preview','user',0,?,1)", bindings: [Data("saved".utf8)]) }
        if state == "lease" {
            try store.seizeLease(sessionId: "preview", instanceId: "Other", pid: 2, now: 2, leaseToken: "other")
        }
        if state == "lease-failure" {
            try store.db.exec("CREATE TRIGGER fail_preview_lease BEFORE INSERT ON session_leases BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        }
        let before = try store.loadSession(id: "preview")
        let lease = try store.loadLease(sessionId: "preview")
        #expect(throws: (any Error).self) {
            try store.createV2PreviewSession(row: previewRow(), ownerInstance: "A", pid: 1, now: 1, leaseToken: "owner")
        }
        #expect(try store.loadSession(id: "preview") == before)
        #expect(try store.loadLease(sessionId: "preview") == lease)
    }

    @Test func legacyRowsMigrateAsV1() throws {
        let store = try ACPSessionStore(path: tmpURL().path)
        defer { try? FileManager.default.removeItem(atPath: store.path) }
        try store.upsertSession(previewRow())
        try store.db.exec("ALTER TABLE sessions DROP COLUMN runtime_kind")
        try store.db.exec("UPDATE schema_version SET version = 36")
        let reopened = try ACPSessionStore(path: store.path)
        #expect(try reopened.loadSession(id: "preview")?.runtimeKind == .v1)
    }

    @Test(arguments: ["sequence", "installation", "lease", "withdraw-entry", "withdraw-commit"])
    func displaySnapshotCannotBeOverwrittenByAnOlderOrWithdrawnWriter(reason: String) throws {
        let store = try ACPSessionStore(path: tmpURL().path)
        defer { try? FileManager.default.removeItem(atPath: store.path) }
        let fence = try store.createV2PreviewSession(row: previewRow(), ownerInstance: "A", pid: 1, now: 1, leaseToken: "owner")
        let initial = ACPV2PreviewDisplaySnapshot(sessionId: "preview", installationID: UUID(), sequence: 1, status: .observing, rows: [])
        #expect(try store.persistV2PreviewDisplay(initial, fence: fence, authorize: { true }))
        let next = ACPV2PreviewDisplaySnapshot(sessionId: "preview", installationID: reason == "installation" ? UUID() : initial.installationID,
            sequence: reason == "sequence" ? 1 : 2, status: .ended, rows: [])
        let checks = Mutex(reason == "withdraw-entry" ? 0 : reason == "withdraw-commit" ? 2 : 100)
        let attemptedFence = reason == "lease" ? ACPSessionLeaseFence(sessionId: "preview", ownerInstance: "A", token: "old") : fence
        #expect(try store.persistV2PreviewDisplay(next, fence: attemptedFence, authorize: {
            checks.withLock { count in defer { count -= 1 }
            return count > 0 }
        }) == false)
        #expect(try store.loadV2PreviewDisplay(sessionId: "preview") == initial)
        #expect(try store.persistV2PreviewDisplay(.init(sessionId: "preview", installationID: initial.installationID,
            sequence: 3, status: .interrupted, rows: []), fence: fence, authorize: { true }))
    }

    @Test func previewDisplayDoesNotGrantReplayAuthority() throws {
        let store = try ACPSessionStore(path: tmpURL().path)
        defer { try? FileManager.default.removeItem(atPath: store.path) }
        let fence = try store.createV2PreviewSession(row: previewRow(), ownerInstance: "A", pid: 1, now: 1, leaseToken: "owner")
        let savedRow = try store.loadSession(id: "preview")
        let display = ACPV2PreviewDisplaySnapshot(sessionId: "preview", installationID: UUID(), sequence: 1, status: .observing, rows: [])
        #expect(try store.persistV2PreviewDisplay(display, fence: fence, authorize: { true }))
        for _ in 0..<2 { #expect(try store.loadV2PreviewDisplay(sessionId: "preview")?.reopenedStatus == .interrupted) }
        #expect(try store.loadSession(id: "preview") == savedRow)
        #expect(try store.loadV2UpdateJournalStream(sessionId: "preview") == nil)
        #expect(try store.loadV2InboundLedgerStream(sessionId: "preview") == nil)
        #expect(try store.db.query("SELECT id FROM acp_v2_response_intents").isEmpty)
    }

    private func previewRow() -> ACPSessionRow {
        .init(id: "preview", agentId: "fixture", title: "Preview", autoRun: false,
            createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false)
    }

    @Test func writeThenReadRoundTrips() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PersistenceStore()
        try store.write(Sample(name: "wing", count: 7), to: url)
        let read: Sample = try store.read(Sample.self, from: url)
        #expect(read == Sample(name: "wing", count: 7))
    }

    @Test func readMissingFileReturnsNil() throws {
        let store = PersistenceStore()
        let read: Sample? = try store.readIfExists(Sample.self, from: tmpURL())
        #expect(read == nil)
    }

    @Test func readBrokenFileMovesItAndReturnsNil() throws {
        let url = tmpURL()
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        let store = PersistenceStore()
        let read: Sample? = try store.readIfExists(Sample.self, from: url)
        #expect(read == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let parent = url.deletingLastPathComponent()
        let entries = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        #expect(entries.contains { $0.contains(url.lastPathComponent) && $0.contains(".broken-") })
        for e in entries where e.contains(".broken-") {
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(e))
        }
    }

    @Test func writeIsAtomic() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PersistenceStore()
        try store.write(Sample(name: "a", count: 1), to: url)
        try store.write(Sample(name: "b", count: 2), to: url)
        let read: Sample = try store.read(Sample.self, from: url)
        #expect(read == Sample(name: "b", count: 2))
        let tmp = url.appendingPathExtension("tmp")
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
    }
}
