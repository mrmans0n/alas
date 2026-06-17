import Testing
import Foundation
@testable import Alas

struct StagedDiffSelectionBridgingTests {
    @Test func restoredPathMapsToStagedFileID() {
        let fileID = DiffReviewFileID(namespace: "staged", path: "foo.swift")
        #expect(fileID.rawValue == "staged:foo.swift")
    }

    @Test func selectionFallsToFirstFileWhenRemovedFromSession() {
        let first = DiffReviewFileID(namespace: "staged", path: "Sources/First.swift")
        let second = DiffReviewFileID(namespace: "staged", path: "Sources/Second.swift")
        let removedID = DiffReviewFileID(namespace: "staged", path: "Sources/Removed.swift")

        let result = DiffReviewSurfaceSelectionSync.synchronizedSelection(
            current: removedID,
            fileIDs: [first, second]
        )

        #expect(result == first)
    }

    @Test func selectionClearsWhenNoFilesRemain() {
        let staleID = DiffReviewFileID(namespace: "staged", path: "Sources/Stale.swift")

        let result = DiffReviewSurfaceSelectionSync.synchronizedSelection(
            current: staleID,
            fileIDs: []
        )

        #expect(result == nil)
    }
}
