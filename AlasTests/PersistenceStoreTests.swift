import Testing
import Foundation
@testable import Alas

struct PersistenceStoreTests {
    struct Sample: Codable, Equatable { let name: String
    let count: Int }

    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-store-\(UUID().uuidString).json")
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
