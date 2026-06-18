import Foundation
import Testing
@testable import Alas

@Suite("AgentPath.resolveExecutable")
struct AgentPathResolveTests {
    private func makeExecutable(named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-agentpath-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return exe
    }

    @Test("finds an executable on the base PATH")
    func findsOnPath() throws {
        let exe = try makeExecutable(named: "fake-tool")
        defer { try? FileManager.default.removeItem(at: exe.deletingLastPathComponent()) }
        let dir = exe.deletingLastPathComponent().path
        let resolved = AgentPath.resolveExecutable(named: "fake-tool", base: dir, wellKnown: [])
        #expect(resolved == exe.path)
    }

    @Test("returns nil when not found")
    func missing() {
        let resolved = AgentPath.resolveExecutable(named: "definitely-absent-xyz", base: "/var/empty", wellKnown: [])
        #expect(resolved == nil)
    }
}
