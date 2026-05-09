import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
struct DefinitionSnippetCacheTests {

    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snippet-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func returnsRequestedLine() throws {
        let url = try tempFile("first\nsecond line\nthird\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = DefinitionSnippetCache()
        #expect(cache.line(at: url, line: 1) == "second line")
    }

    @Test func returnsEmptyForOutOfRange() throws {
        let url = try tempFile("only\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = DefinitionSnippetCache()
        #expect(cache.line(at: url, line: 99) == "")
    }

    @Test func cachesRepeatedReads() throws {
        let url = try tempFile("x\ny\nz\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = DefinitionSnippetCache()
        _ = cache.line(at: url, line: 1)
        // Mutate the file; cache should still return the original.
        try "DIFFERENT\nDATA\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(cache.line(at: url, line: 1) == "y")
    }
}
