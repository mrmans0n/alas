import Foundation
import Testing
@testable import Alas

@Suite("CodexACPInstaller")
struct CodexACPInstallerTests {
    @Test("install removes the stale package, then installs the active fork")
    func install() async {
        var calls: [[String]] = []
        let installer = CodexACPInstaller(runner: { cmd, args in
            calls.append([cmd] + args)
            return (status: 0, stderr: "")
        })
        try? await installer.install()
        // Uninstall the old package first (avoids npm EEXIST on the shared
        // `codex-acp` bin), then install the active fork.
        #expect(calls.count == 2)
        #expect(calls.first == ["npm", "uninstall", "-g", "@zed-industries/codex-acp"])
        #expect(calls.last == ["npm", "install", "-g", "@agentclientprotocol/codex-acp"])
    }
}
