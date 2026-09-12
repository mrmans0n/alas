import Foundation
import Testing
@testable import Alas

@Suite("Checkpoint writer lease store")
struct CheckpointWriterLeaseStoreTests {
    @Test func activeCountIncludesOtherLiveInstancesAndExcludesThisInstance() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CheckpointWriterLeaseStore(root: root, activePersistentSessionNames: { [] })
        let lineageID = UUID().uuidString.lowercased()

        store.acquire(lineageIDs: [lineageID], sessionID: "local", instanceID: "this-instance", zmxSessionName: nil, remoteHost: nil)
        store.acquire(lineageIDs: [lineageID], sessionID: "other", instanceID: "other-instance", zmxSessionName: nil, remoteHost: nil)

        #expect(store.activeLeaseCount(lineageID: lineageID, excludingInstanceID: "this-instance") == 1)
        #expect(store.activeLeaseCount(lineageID: lineageID, excludingInstanceID: "other-instance") == 1)
    }

    @Test func liveReusedPidDoesNotKeepStaleLeaseActive() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lineageID = UUID().uuidString.lowercased()
        let directory = root.appendingPathComponent(lineageID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = CheckpointWriterLeaseRecord(
            schemaVersion: CheckpointWriterLeaseRecord.schemaVersion,
            instanceID: "stale-instance",
            sessionID: "stale-session",
            pid: Int64(getpid()),
            zmxSessionName: nil,
            remoteHost: nil,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: directory.appendingPathComponent("stale.json"))
        let store = CheckpointWriterLeaseStore(root: root, activePersistentSessionNames: { [] })

        #expect(store.activeLeaseCount(lineageID: lineageID, excludingInstanceID: "current-instance") == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("stale.json").path))
    }

    @Test func releaseRemovesSessionFromAllLineages() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CheckpointWriterLeaseStore(root: root, activePersistentSessionNames: { [] })
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()

        store.acquire(lineageIDs: [first, second], sessionID: "shared", instanceID: "other-instance", zmxSessionName: nil, remoteHost: nil)
        store.release(sessionID: "shared", instanceID: "other-instance")

        #expect(store.activeLeaseCount(lineageID: first, excludingInstanceID: "this-instance") == 0)
        #expect(store.activeLeaseCount(lineageID: second, excludingInstanceID: "this-instance") == 0)
    }

    @Test func releaseRemovesOnlyTheOwningInstanceRecord() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CheckpointWriterLeaseStore(root: root, activePersistentSessionNames: { [] })
        let lineageID = UUID().uuidString.lowercased()

        store.acquire(lineageIDs: [lineageID], sessionID: "shared-leaf", instanceID: "first-instance", zmxSessionName: nil, remoteHost: nil)
        store.acquire(lineageIDs: [lineageID], sessionID: "shared-leaf", instanceID: "second-instance", zmxSessionName: nil, remoteHost: nil)
        store.release(sessionID: "shared-leaf", instanceID: "first-instance")

        #expect(store.activeLeaseCount(lineageID: lineageID, excludingInstanceID: "third-instance") == 1)
        #expect(store.activeLeaseCount(lineageID: lineageID, excludingInstanceID: "second-instance") == 0)
    }

    @Test func detachedPersistentTerminalLeaseStaysActiveWhileZmxSessionExists() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let activeZmxSessions = ActiveZmxSessions(["alas-persistent"])
        let store = CheckpointWriterLeaseStore(root: root, activePersistentSessionNames: { activeZmxSessions.value })
        let lineageID = UUID().uuidString.lowercased()

        store.acquire(
            lineageIDs: [lineageID],
            sessionID: "detached",
            instanceID: "former-instance",
            zmxSessionName: "alas-persistent",
            remoteHost: nil,
            pid: -1
        )

        #expect(store.activeLeaseCount(lineageID: lineageID, excludingInstanceID: "new-instance") == 1)

        activeZmxSessions.value = []

        #expect(store.activeLeaseCount(lineageID: lineageID, excludingInstanceID: "new-instance") == 0)
    }

    private func temporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("checkpoint-writer-leases-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private final class ActiveZmxSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Set<String>

    init(_ value: Set<String>) {
        self.storedValue = value
    }

    var value: Set<String> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}
