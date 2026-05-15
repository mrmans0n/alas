import Testing
import Foundation
@testable import Alas

struct CommitAIDetectorTests {
    private func makeShim(in dir: URL, named: String) throws {
        let url = dir.appendingPathComponent(named)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    @Test func detectsOnlyShimmedBinaries() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-det-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeShim(in: dir, named: "claude")
        try makeShim(in: dir, named: "pi")

        let found = await CommitAIDetector.scan(path: dir.path)
        #expect(Set(found) == Set([.claude, .pi]))
    }

    @Test func emptyPathYieldsNothing() async throws {
        let found = await CommitAIDetector.scan(path: "")
        #expect(found.isEmpty)
    }

    @Test func returnsStableOrderMatchingAllCases() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-det-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeShim(in: dir, named: "pi")
        try makeShim(in: dir, named: "claude")
        try makeShim(in: dir, named: "codex")
        try makeShim(in: dir, named: "cursor-agent")

        let found = await CommitAIDetector.scan(path: dir.path)
        #expect(found == [.claude, .codex, .cursorAgent, .pi])
    }
}
