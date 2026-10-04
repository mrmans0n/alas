import Foundation
import Testing
@testable import Alas

@Suite("ClaudeCodeACPInstaller")
struct ClaudeCodeACPInstallerTests {
    @Test("install uninstalls all legacy packages before installing the Alas package")
    func installMigratesLegacyPackages() async {
        var calls: [[String]] = []
        let installer = ClaudeCodeACPInstaller(runner: { cmd, args in
            calls.append([cmd] + args)
            return (status: 0, stderr: "")
        })
        try? await installer.install()
        #expect(calls == [
            ["npm", "uninstall", "-g", "@agentclientprotocol/claude-agent-acp"],
            ["npm", "uninstall", "-g", "@zed-industries/claude-code-acp"],
            ["npm", "install", "-g", "@alas-ide/claude-agent-acp"],
        ])
    }

    @Test("install continues after a legacy uninstall fails")
    func installContinuesWhenLegacyUninstallFails() async throws {
        var calls: [[String]] = []
        let installer = ClaudeCodeACPInstaller(runner: { cmd, args in
            calls.append([cmd] + args)
            return calls.count == 1 ? (status: 1, stderr: "missing") : (status: 0, stderr: "")
        })

        try await installer.install()

        #expect(calls.last == ["npm", "install", "-g", "@alas-ide/claude-agent-acp"])
    }

    @Test("install continues when a legacy uninstall throws")
    func installContinuesWhenLegacyUninstallThrows() async throws {
        var calls: [[String]] = []
        let installer = ClaudeCodeACPInstaller(runner: { cmd, args in
            calls.append([cmd] + args)
            if calls.count == 1 { throw CocoaError(.fileNoSuchFile) }
            return (status: 0, stderr: "")
        })

        try await installer.install()

        #expect(calls.last == ["npm", "install", "-g", "@alas-ide/claude-agent-acp"])
    }

    @Test("install reports a failed package installation")
    func installSurfacesFinalFailure() async {
        let installer = ClaudeCodeACPInstaller(runner: { _, _ in (status: 1, stderr: "install failed") })

        do {
            try await installer.install()
            Issue.record("expected package installation to fail")
        } catch ACPInstallError.nonZeroExit(let status, let stderr) {
            #expect(status == 1)
            #expect(stderr == "install failed")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
