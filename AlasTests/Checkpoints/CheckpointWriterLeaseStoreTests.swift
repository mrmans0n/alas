import Foundation
import Testing
@testable import Alas

@Suite("Checkpoint writer lease store")
struct CheckpointWriterLeaseStoreTests {
    @Test func activeCountIncludesOtherLiveInstancesAndExcludesThisInstance() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CheckpointWriterLeaseStore(root: root)
        let lineageID = UUID().uuidString.lowercased()

        store.acquire(lineageIDs: [lineageID], sessionID: "local", instanceID: "this-instance")
        store.acquire(lineageIDs: [lineageID], sessionID: "other", instanceID: "other-instance")

        #expect(store.activeLeaseCount(lineageID: lineageID, excludingInstanceID: "this-instance") == 1)
        #expect(store.activeLeaseCount(lineageID: lineageID, excludingInstanceID: "other-instance") == 1)
    }

    @Test func releaseRemovesSessionFromAllLineages() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CheckpointWriterLeaseStore(root: root)
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()

        store.acquire(lineageIDs: [first, second], sessionID: "shared", instanceID: "other-instance")
        store.release(sessionID: "shared")

        #expect(store.activeLeaseCount(lineageID: first, excludingInstanceID: "this-instance") == 0)
        #expect(store.activeLeaseCount(lineageID: second, excludingInstanceID: "this-instance") == 0)
    }

    private func temporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("checkpoint-writer-leases-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
