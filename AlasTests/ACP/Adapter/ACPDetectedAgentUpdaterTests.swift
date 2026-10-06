import Foundation
import Synchronization
import Testing
@testable import Alas

@Suite("ACPDetectedAgentUpdater")
struct ACPDetectedAgentUpdaterTests {
    @Test("classifies the package manager from the resolved binary path", arguments: [
        ("/Users/me/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js",
         ACPDetectedAgentOwner?.some(.bun(package: "@oh-my-pi/pi-coding-agent", root: "/Users/me/.bun/install/global"))),
        ("/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js",
         .npm(package: "@earendil-works/pi-coding-agent", prefix: "/opt/homebrew")),
        // The outermost node_modules names the global package, not a nested dependency.
        ("/Users/me/.nvm/versions/node/v22.1.0/lib/node_modules/opencode-ai/node_modules/opencode-darwin-arm64/bin/opencode",
         .npm(package: "opencode-ai", prefix: "/Users/me/.nvm/versions/node/v22.1.0")),
        ("/opt/homebrew/Cellar/opencode/1.18.34/bin/opencode", .homebrewFormula(name: "opencode")),
        ("/opt/homebrew/Caskroom/copilot-cli/1.0.85/copilot", .homebrewCask(name: "copilot-cli")),
        ("/Users/me/Library/pnpm/global/5/node_modules/omp/cli.js", nil),
        ("/Users/me/.local/share/cursor-agent/versions/2026.10.01/cursor-agent", nil),
    ])
    func classify(path: String, expected: ACPDetectedAgentOwner?) {
        #expect(ACPDetectedAgentOwner.classify(resolvedPath: path) == expected)
    }

    @Test("upgrade commands target the owning install")
    func upgradeCommands() {
        #expect(ACPDetectedAgentOwner.bun(package: "@oh-my-pi/pi-coding-agent", root: "/b").upgradeCommand
                == ["bun", "add", "-g", "@oh-my-pi/pi-coding-agent@latest"])
        #expect(ACPDetectedAgentOwner.npm(package: "pi", prefix: "/opt/homebrew").upgradeCommand
                == ["npm", "install", "-g", "--prefix", "/opt/homebrew", "pi@latest"])
        #expect(ACPDetectedAgentOwner.homebrewCask(name: "copilot-cli").upgradeCommand
                == ["brew", "upgrade", "--cask", "copilot-cli"])
    }

    @Test("registry latest is compared with the installed version", arguments: [
        ("18.2.11", "18.6.3\n", AdapterUpdateState.available(current: "18.2.11", latest: "18.6.3")),
        ("0.85.1", "\"1.0.4\"\n", .available(current: "0.85.1", latest: "1.0.4")),
        ("1.0.4", "\"1.0.4\"", .upToDate),
        ("1.10.0", "1.9.9", .upToDate),
        ("1.0.0", "2.0.0-beta.1", .upToDate),
        ("1.0.0", "", .unknown),
        ("1.0.0", "error: not found", .unknown),
    ])
    func registryComparison(current: String, output: String, expected: AdapterUpdateState) {
        #expect(ACPDetectedAgentUpdater.state(current: current, latestOutput: output) == expected)
    }

    @Test("brew outdated JSON maps to update state", arguments: [
        (Int32(1), """
        {"formulae": [], "casks": [{"name": "copilot-cli", "installed_versions": ["1.0.80"],
          "current_version": "1.0.85", "pinned": false, "pinned_version": null}]}
        """, AdapterUpdateState.available(current: "1.0.80", latest: "1.0.85")),
        (0, #"{"formulae": [], "casks": []}"#, .upToDate),
        (1, """
        {"formulae": [{"name": "copilot-cli", "installed_versions": ["1.0.80"],
          "current_version": "1.0.85", "pinned": true}], "casks": []}
        """, .upToDate),
        (1, "Error: No available formula", .unknown),
    ])
    func brewOutdated(status: Int32, stdout: String, expected: AdapterUpdateState) {
        #expect(ACPDetectedAgentUpdater.parseBrewOutdated(
            name: "copilot-cli", status: status, stdout: stdout) == expected)
    }

    @Test("bun checks read package.json and query the registry from Bun's global root")
    func bunCheckRunsFromGlobalRoot() async {
        let calls = Mutex<[([String], String?)]>([])
        let updater = ACPDetectedAgentUpdater(
            runner: { arguments, cwd, _ in
                calls.withLock { $0.append((arguments, cwd)) }
                return ProcessResult(exitCode: 0, stdout: "18.6.3\n", stderr: "")
            },
            readFile: { path in
                path == "/b/node_modules/@oh-my-pi/pi-coding-agent/package.json"
                    ? Data(#"{"version": "18.2.11"}"#.utf8) : nil
            })

        let state = await updater.check(owner: .bun(package: "@oh-my-pi/pi-coding-agent", root: "/b"))

        #expect(state == .available(current: "18.2.11", latest: "18.6.3"))
        let recorded = calls.withLock { $0 }
        #expect(recorded.map(\.0) == [["bun", "info", "@oh-my-pi/pi-coding-agent", "version"]])
        #expect(recorded.map(\.1) == ["/b"])
    }

    @Test("only binary-only built-ins and the pi CLI are checked")
    func binaryNames() {
        #expect(ACPDetectedAgentUpdater.binaryName(agentID: "omp", binaryOverride: nil) == "omp")
        #expect(ACPDetectedAgentUpdater.binaryName(agentID: "omp", binaryOverride: " /opt/omp ") == "/opt/omp")
        #expect(ACPDetectedAgentUpdater.binaryName(agentID: "pi", binaryOverride: nil) == "pi")
        #expect(ACPDetectedAgentUpdater.binaryName(agentID: "claude", binaryOverride: nil) == nil)
        #expect(ACPDetectedAgentUpdater.binaryName(agentID: "registry-goose", binaryOverride: nil) == nil)
    }
}
