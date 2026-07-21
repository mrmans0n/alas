import Foundation
import Testing
@testable import Alas

struct GGUndoMarkerStoreTests {
    @Test func storesMarkersPerWorktreeAndClearsIndependently() throws {
        let suite = "GGUndoMarkerStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GGUndoMarkerStore(defaults: defaults)

        store.set(GGUndoMarker(operationID: "op_1"), worktreeId: "wt-1")
        store.set(
            GGUndoMarker(operationID: "op_2", removedFinalStackCommit: true),
            worktreeId: "wt-2"
        )
        #expect(store.marker(worktreeId: "wt-1") == GGUndoMarker(operationID: "op_1"))
        #expect(store.marker(worktreeId: "wt-2") == GGUndoMarker(
            operationID: "op_2", removedFinalStackCommit: true
        ))

        store.clear(worktreeId: "wt-1")
        #expect(store.marker(worktreeId: "wt-1") == nil)
        #expect(store.marker(worktreeId: "wt-2")?.operationID == "op_2")
    }

    @Test func aNewStoreReadsThePersistedMarker() throws {
        let suite = "GGUndoMarkerStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        GGUndoMarkerStore(defaults: defaults).set(
            GGUndoMarker(operationID: "op_1", removedFinalStackCommit: true),
            worktreeId: "wt"
        )

        #expect(GGUndoMarkerStore(defaults: defaults).marker(worktreeId: "wt") == GGUndoMarker(
            operationID: "op_1", removedFinalStackCommit: true
        ))
    }
}
