import Foundation
import Testing
@testable import Alas

@Suite("ClaudeCodeACPInstaller")
struct ClaudeCodeACPInstallerTests {
    @Test("install runs `npm install -g @agentclientprotocol/claude-agent-acp`")
    func install() async {
        var capturedCommand: [String] = []
        let installer = ClaudeCodeACPInstaller(runner: { cmd, args in
            capturedCommand = [cmd] + args
            return (status: 0, stderr: "")
        })
        try? await installer.install()
        #expect(capturedCommand == [
            "npm", "install", "-g", "@agentclientprotocol/claude-agent-acp",
        ])
    }
}
