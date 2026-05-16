import Foundation
import Testing
@testable import Alas

@Suite("MasonSnapshot")
struct MasonSnapshotTests {
    @Test("snapshot loads from bundle and is non-empty")
    func loadsFromBundle() throws {
        let snap = MasonSnapshot.shared
        #expect(snap.packages.count > 0)
    }

    @Test("search by masonId prefix")
    func searchById() {
        let snap = MasonSnapshot.shared
        let results = snap.search("typescript")
        #expect(results.contains(where: { $0.masonId.contains("typescript") }))
    }

    @Test("search by language matches packages claiming that language")
    func searchByLanguage() {
        let snap = MasonSnapshot.shared
        let results = snap.search("rust")
        #expect(results.contains(where: { $0.languages.contains("Rust") }))
    }

    @Test("empty query returns no results")
    func emptyQuery() {
        #expect(MasonSnapshot.shared.search("").isEmpty)
    }

    @Test("search caps result count")
    func resultCap() {
        // Worst case "e" matches a lot of things — should still be capped.
        let results = MasonSnapshot.shared.search("e")
        #expect(results.count <= MasonSnapshot.maxResults)
    }
}
