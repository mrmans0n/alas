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
}
