import Testing
@testable import Alas

struct ACPRemoteLaunchTests {
    @Test func agentCommandScrubsClaudeMarkersAndQuotes() {
        let command = ACPRemoteLaunch.agentCommand(
            command: "claude-agent-acp", arguments: ["--flag", "va l"]
        )

        for marker in [
            "CLAUDECODE", "CLAUDE_CODE", "CLAUDE_PROJECT_DIR",
            "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_SESSION_ID",
        ] {
            #expect(command.contains("-u \(marker)"))
        }
        #expect(command.hasPrefix("env -u "))
        #expect(command.hasSuffix("'claude-agent-acp' '--flag' 'va l'"))
    }

    @Test func channelInvocationRunsBatchSSHInWorktree() {
        let invocation = ACPRemoteLaunch.channelInvocation(
            host: "devbox", worktreePath: "/srv/repo",
            command: "codex-acp", arguments: []
        )

        #expect(invocation.executable == "/usr/bin/ssh")
        #expect(invocation.args.contains("BatchMode=yes"))
        let script = invocation.args.last ?? ""
        #expect(script.contains("cd '\\''/srv/repo'\\'' && "))
        #expect(script.contains("'codex-acp'"))
    }

    @Test func resolvedAdapterPrependsExactNodeBinAndStillScrubsMarkers() {
        let command = ACPRemoteLaunch.agentCommand(
            command: "/home/dev/.alas/acp/codex/bin/codex-acp",
            arguments: [],
            nodeBinDirectory: "/home/dev/node versions/v22/bin"
        )

        #expect(command.hasPrefix("PATH='/home/dev/node versions/v22/bin':\"$PATH\" && export PATH && env "))
        #expect(command.contains("-u CLAUDECODE"))
        #expect(command.hasSuffix("'/home/dev/.alas/acp/codex/bin/codex-acp'"))
    }

    @Test func resolvedAdapterKeepsNodePathInCwdAndList() {
        let invocation = ACPRemoteLaunch.channelInvocation(
            host: "devbox",
            worktreePath: "/srv/repo",
            command: "codex-acp",
            arguments: [],
            nodeBinDirectory: "/managed/node/bin"
        )

        let script = invocation.args.last ?? ""
        #expect(script.contains(
            "cd '\\''/srv/repo'\\'' && PATH='\\''/managed/node/bin'\\'':\"$PATH\" && export PATH && env "
        ))
        #expect(!script.contains("cd '\\''/srv/repo'\\'' && PATH='\\''/managed/node/bin'\\'':\"$PATH\";"))
    }

    @Test func setupProbeUsesFirstWordOfCommand() {
        #expect(ACPRemoteLaunch.setupProbeCommand(command: "gemini --experimental-acp")
            == "command -v 'gemini'")
        #expect(ACPRemoteLaunch.setupProbeCommand(command: "codex-acp")
            == "command -v 'codex-acp'")
    }

    @Test func setupProbePreservesPackageChecks() {
        #expect(ACPRemoteLaunch.setupProbeCommand(check: .binaryOnPath(name: "gemini"))
            == "command -v 'gemini'")

        let codexProbe = ACPRemoteLaunch.setupProbeCommand(check: .npxPackage(name: "@agentclientprotocol/codex-acp"))
        #expect(codexProbe.contains("npm root -g"))
        #expect(codexProbe.contains("'@agentclientprotocol/codex-acp'"))
        #expect(!codexProbe.contains("command -v 'codex-acp'"))

        let mixedProbe = ACPRemoteLaunch.setupProbeCommand(
            check: .binaryOnPathOrNpmPackage(binary: "claude-agent-acp", npmPackage: "@zed-industries/claude-code-acp")
        )
        #expect(mixedProbe.contains("command -v 'claude-agent-acp'"))
        #expect(mixedProbe.contains("'@zed-industries/claude-code-acp'"))
    }

    @Test func launchPathProbePreservesNpmPackagePrecedence() throws {
        let codex = ACPLaunchSpec(
            agentID: "codex",
            command: "codex-acp",
            arguments: [],
            extraEnv: [:],
            setupCheck: .npxPackage(name: "@agentclientprotocol/codex-acp"),
            supportsModelSelection: false,
            supportsModeSelection: false
        )

        let command = try #require(ACPRemoteLaunch.launchPathProbeCommand(for: codex))
        #expect(command.contains("npm prefix -g"))
        #expect(command.contains("command -v 'codex-acp'"))
        let npm = try #require(command.range(of: "npm prefix -g")?.lowerBound)
        let path = try #require(command.range(of: "command -v 'codex-acp'")?.lowerBound)
        #expect(npm < path)
    }

    @Test func launchPathProbePreservesBinaryOrPackagePrecedence() {
        let claude = ACPLaunchSpec(
            agentID: "claude",
            command: "claude-agent-acp",
            arguments: [],
            extraEnv: [:],
            setupCheck: .binaryOnPathOrNpmPackage(
                binary: "claude-agent-acp",
                npmPackage: "@zed-industries/claude-code-acp"
            ),
            supportsModelSelection: false,
            supportsModeSelection: false
        )

        let command = ACPRemoteLaunch.launchPathProbeCommand(for: claude)
        #expect(command?.hasPrefix("command -v 'claude-agent-acp'") == true)
        #expect(command?.contains("npm prefix -g") == true)
    }

    @Test func terminalCommandForwardsAgentEnvPairs() {
        let command = ACPRemoteLaunch.terminalCommand(
            command: "npm", args: ["test"],
            env: ["CI": "1"], cwd: "/srv/repo/sub"
        )

        #expect(command.contains("'CI=1'"))
        #expect(command.contains("'npm' 'test'"))
        #expect(command.hasPrefix("cd '/srv/repo/sub' && env "))
    }

    @Test func terminalCommandSortsEnvForDeterminism() {
        let first = ACPRemoteLaunch.terminalCommand(
            command: "x", args: [], env: ["B": "2", "A": "1"], cwd: "/w"
        )
        let second = ACPRemoteLaunch.terminalCommand(
            command: "x", args: [], env: ["A": "1", "B": "2"], cwd: "/w"
        )

        #expect(first == second)
        #expect(first.range(of: "'A=1'")!.lowerBound < first.range(of: "'B=2'")!.lowerBound)
    }
}
