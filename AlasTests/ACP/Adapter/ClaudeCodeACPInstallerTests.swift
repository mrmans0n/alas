import Foundation
import Testing
@testable import Alas

@Suite("ClaudeCodeACPInstaller")
struct ClaudeCodeACPInstallerTests {
    @Test("install preserves the working adapter until the Alas package is installed")
    func installMigratesLegacyPackages() async {
        var calls: [[String]] = []
        let installer = ClaudeCodeACPInstaller(runner: { cmd, args in
            calls.append([cmd] + args)
            return (status: 0, stderr: "")
        })
        try? await installer.install()
        #expect(calls == [
            ["npm", "install", "-g", "--force", "@alas-ide/claude-agent-acp"],
            ["npm", "uninstall", "-g", "@agentclientprotocol/claude-agent-acp"],
            ["npm", "uninstall", "-g", "@zed-industries/claude-code-acp"],
            ["npm", "rebuild", "-g", "@alas-ide/claude-agent-acp"],
        ])
    }

    @Test("install continues after a legacy uninstall fails")
    func installContinuesWhenLegacyUninstallFails() async throws {
        var calls: [[String]] = []
        let installer = ClaudeCodeACPInstaller(runner: { cmd, args in
            calls.append([cmd] + args)
            return args == ["uninstall", "-g", "@agentclientprotocol/claude-agent-acp"]
                ? (status: 1, stderr: "missing")
                : (status: 0, stderr: "")
        })

        try await installer.install()

        #expect(calls.last == ["npm", "rebuild", "-g", "@alas-ide/claude-agent-acp"])
    }

    @Test("install continues when a legacy uninstall throws")
    func installContinuesWhenLegacyUninstallThrows() async throws {
        var calls: [[String]] = []
        let installer = ClaudeCodeACPInstaller(runner: { cmd, args in
            calls.append([cmd] + args)
            if args == ["uninstall", "-g", "@agentclientprotocol/claude-agent-acp"] {
                throw CocoaError(.fileNoSuchFile)
            }
            return (status: 0, stderr: "")
        })

        try await installer.install()

        #expect(calls.last == ["npm", "rebuild", "-g", "@alas-ide/claude-agent-acp"])
    }

    @Test("install reports a failed package installation")
    func installSurfacesFinalFailure() async {
        var calls: [[String]] = []
        let installer = ClaudeCodeACPInstaller(runner: { cmd, args in
            calls.append([cmd] + args)
            return (status: 1, stderr: "install failed")
        })

        do {
            try await installer.install()
            Issue.record("expected package installation to fail")
        } catch ACPInstallError.nonZeroExit(let status, let stderr) {
            #expect(status == 1)
            #expect(stderr == "install failed")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(calls == [["npm", "install", "-g", "--force", "@alas-ide/claude-agent-acp"]])
    }
}
