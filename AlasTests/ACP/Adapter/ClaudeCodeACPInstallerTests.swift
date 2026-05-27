import Foundation
import Testing
@testable import Alas

@Suite("ClaudeCodeACPInstaller")
struct ClaudeCodeACPInstallerTests {
    @Test("install runs `npm install -g @zed-industries/claude-code-acp`")
    func install() async {
        var capturedCommand: [String] = []
        let installer = ClaudeCodeACPInstaller(runner: { cmd, args in
            capturedCommand = [cmd] + args
            return (status: 0, stderr: "")
        })
        try? await installer.install()
        #expect(capturedCommand.contains("npm"))
        #expect(capturedCommand.contains("install"))
        #expect(capturedCommand.contains("-g"))
        #expect(capturedCommand.contains("@zed-industries/claude-code-acp"))
    }
}
