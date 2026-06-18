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

    // Regression: the codex setup check must NOT be satisfied by a stale
    // `codex-acp` binary alone. Both the old `@zed-industries/codex-acp` and
    // the active `@agentclientprotocol/codex-acp` fork ship that binary name,
    // so gating on the binary would skip migrating users off the package that
    // lacks `usage_update`. The catalog uses `.npxPackage` to force migration.
    @Test("codex setup check requires the package, not just a codex-acp binary on PATH")
    func codexSetupCheckIsPackageSpecific() async throws {
        let executable = try makeExecutable(named: "codex-acp")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let codexCheck = try #require(ACPLaunchCatalog.spec(for: "codex")?.setupCheck)
        // PATH carries the fake `codex-acp` but no `npm`, so global-package
        // resolution deterministically fails — isolating binary-vs-package.
        let checker = ACPSetupChecker(
            env: ["PATH": executable.deletingLastPathComponent().path],
            additionalPathDirectories: [])
        let r = await checker.evaluate(codexCheck)
        if case .missing = r {} else {
            Issue.record("expected .missing — a codex-acp binary alone must not satisfy the codex check")
        }
    }
}
