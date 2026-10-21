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

    /// A host started by launchd inherits launchd's minimal PATH; adapters
    /// installed through nvm, fnm, asdf or mise live only on the login
    /// shell's, and Node-based ones need its `node` to run.
    @Test(arguments: [
        ("/opt/nvm/bin:/usr/bin", "/usr/bin:/bin", "/opt/nvm/bin:/usr/bin:/bin"),
        (nil, "/usr/bin:/bin", "/usr/bin:/bin"),
        ("/opt/nvm/bin", nil, "/opt/nvm/bin"),
    ] as [(String?, String?, String)])
    func adapterEnvironmentStartsFromTheLoginShellPath(shellPath: String?, processPath: String?, expected: String) {
        var environment = ["HOME": "/Users/me"]
        environment["PATH"] = processPath
        let base = ACPProcessEnvironment.baseEnvironment(environment, shellPath: shellPath)
        #expect(base["PATH"] == expected)
        #expect(base["HOME"] == "/Users/me")
    }

    @Test("remote ACP env preserves the remote shell environment")
    func remoteOverridesForACP() {
        let overrides = ACPProcessEnvironment.remoteOverridesForACP(extra: [
            "PATH": "/remote/tool/bin",
            "HOME": "/remote/home",
            "CLAUDECODE": "1",
            "CUSTOM": "value",
        ])

        #expect(overrides == [
            "PATH": "/remote/tool/bin",
            "HOME": "/remote/home",
            "CUSTOM": "value",
        ])
    }
}
