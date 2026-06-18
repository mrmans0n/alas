import Foundation
import Testing
@testable import Alas

@Suite("CodexACPInstaller")
struct CodexACPInstallerTests {
    @Test("install runs `npm install -g @agentclientprotocol/codex-acp`")
    func install() async {
        var capturedCommand: [String] = []
        let installer = CodexACPInstaller(runner: { cmd, args in
            capturedCommand = [cmd] + args
            return (status: 0, stderr: "")
        })
        try? await installer.install()
        #expect(capturedCommand.contains("npm"))
        #expect(capturedCommand.contains("install"))
        #expect(capturedCommand.contains("-g"))
        #expect(capturedCommand.contains("@agentclientprotocol/codex-acp"))
    }
}
