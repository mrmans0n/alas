import Foundation
import Testing
@testable import Alas

@Suite("PiACPInstaller")
struct PiACPInstallerTests {
    @Test("install runs `npm install -g pi-acp`")
    func install() async {
        var capturedCommand: [String] = []
        let installer = PiACPInstaller(runner: { cmd, args in
            capturedCommand = [cmd] + args
            return (status: 0, stderr: "")
        })
        try? await installer.install()
        #expect(capturedCommand.contains("npm"))
        #expect(capturedCommand.contains("install"))
        #expect(capturedCommand.contains("-g"))
        #expect(capturedCommand.contains("pi-acp"))
    }
}
