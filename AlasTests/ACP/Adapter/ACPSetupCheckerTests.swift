import Foundation
import Testing
@testable import Alas

@Suite("ACPSetupChecker")
struct ACPSetupCheckerTests {
    private func makeExecutable(named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-acp-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let executable = dir.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    @Test("binaryOnPath returns ready when /bin/ls is on PATH")
    func binaryPresent() async {
        let checker = ACPSetupChecker(env: ProcessInfo.processInfo.environment)
        let r = await checker.evaluate(.binaryOnPath(name: "ls"))
        #expect(r == .ready)
    }

    @Test("binaryOnPath returns missing when binary absent")
    func binaryAbsent() async {
        let checker = ACPSetupChecker(env: ["PATH": "/var/empty"])
        let r = await checker.evaluate(.binaryOnPath(name: "ls"))
        if case .missing = r {} else { Issue.record("expected .missing") }
    }

    @Test("binaryOnPath checks additional GUI-missing tool directories")
    func binaryInAdditionalDirectory() async throws {
        let executable = try makeExecutable(named: "codex-acp")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let checker = ACPSetupChecker(
            env: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            additionalPathDirectories: [executable.deletingLastPathComponent().path])
        let r = await checker.evaluate(.binaryOnPath(name: "codex-acp"))
        #expect(r == .ready)
    }
}
