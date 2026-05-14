import Testing
import Foundation
@testable import Alas

struct HeadReaderTests {
    private func writeTemp(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-head-\(UUID().uuidString)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func parsesSymbolicRef() throws {
        let url = try writeTemp("ref: refs/heads/feat/foo\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(HeadReader.read(headFile: url) == .branch("feat/foo"))
    }

    @Test func parsesSymbolicRefWithoutTrailingNewline() throws {
        let url = try writeTemp("ref: refs/heads/main")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(HeadReader.read(headFile: url) == .branch("main"))
    }

    @Test func parsesDetachedSHA() throws {
        let url = try writeTemp("0123456789abcdef0123456789abcdef01234567\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(HeadReader.read(headFile: url) == .detached)
    }

    @Test func returnsNilForMalformedContent() throws {
        let url = try writeTemp("not a ref nor a sha\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(HeadReader.read(headFile: url) == nil)
    }

    @Test func returnsNilForMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-head-missing-\(UUID().uuidString)")
        #expect(HeadReader.read(headFile: url) == nil)
    }
}
