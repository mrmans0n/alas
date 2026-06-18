import Foundation
import Testing
@testable import Alas

@Suite("ACPLaunchSpec")
struct ACPLaunchSpecTests {
    @Test("a spec captures the launch command and the setup-check policy")
    func basic() {
        let spec = ACPLaunchSpec(
            agentID: "gemini",
            command: "gemini",
            arguments: ["--experimental-acp"],
            extraEnv: [:],
            setupCheck: .binaryOnPath(name: "gemini"),
            supportsModelSelection: true,
            supportsModeSelection: false)
        #expect(spec.command == "gemini")
        #expect(spec.arguments.first == "--experimental-acp")
        if case .binaryOnPath(let name) = spec.setupCheck { #expect(name == "gemini") }
        else { Issue.record("expected .binaryOnPath") }
    }

    @Test("overridingCommand swaps only the command")
    func overridingCommand() {
        let original = ACPLaunchSpec(
            agentID: "codex",
            command: "codex-acp",
            arguments: ["--flag"],
            extraEnv: ["K": "V"],
            setupCheck: .npxPackage(name: "@agentclientprotocol/codex-acp"),
            supportsModelSelection: false,
            supportsModeSelection: true)
        let overridden = original.overridingCommand("/abs/bin/codex-acp")
        #expect(overridden.command == "/abs/bin/codex-acp")
        #expect(overridden.agentID == "codex")
        #expect(overridden.arguments == ["--flag"])
        #expect(overridden.extraEnv == ["K": "V"])
        #expect(overridden.supportsModelSelection == false)
        #expect(overridden.supportsModeSelection == true)
        #expect(overridden.npmPackageName == "@agentclientprotocol/codex-acp")
    }
}
