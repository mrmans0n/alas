import Testing
import Foundation
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
