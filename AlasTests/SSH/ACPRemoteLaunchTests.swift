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
        #expect(script.hasPrefix("cd -- '/srv/repo' && "))
        #expect(script.contains("'codex-acp'"))
    }

    @Test func setupProbeUsesFirstWordOfCommand() {
        #expect(ACPRemoteLaunch.setupProbeCommand(command: "gemini --experimental-acp")
            == "command -v 'gemini'")
        #expect(ACPRemoteLaunch.setupProbeCommand(command: "codex-acp")
            == "command -v 'codex-acp'")
    }

    @Test func terminalCommandForwardsAgentEnvPairs() {
        let command = ACPRemoteLaunch.terminalCommand(
            command: "npm", args: ["test"],
            env: ["CI": "1"], cwd: "/srv/repo/sub"
        )

        #expect(command.contains("'CI=1'"))
        #expect(command.contains("'npm' 'test'"))
        #expect(command.hasPrefix("cd -- '/srv/repo/sub' && env "))
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
