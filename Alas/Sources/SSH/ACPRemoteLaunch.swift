import Foundation

/// Builders for running ACP agents and their terminal requests on a
/// remote host. The agent channel is a long-lived ssh child whose
/// stdin/stdout carry newline-framed JSON-RPC; its exit is the agent's
/// death signal, so the existing transport `.exited` handling works.
enum ACPRemoteLaunch {
    /// Claude-aware CLIs refuse to start when these leak into their env
    /// (mirrors ACPProcessEnvironment.agentSessionMarkerKeys). Local
    /// sanitization cannot cross ssh because the remote login shell might
    /// set its own values, so scrub remote-side with `env -u`.
    static let markerScrub = [
        "CLAUDECODE", "CLAUDE_CODE", "CLAUDE_PROJECT_DIR",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_SESSION_ID",
    ]

    static func agentCommand(command: String, arguments: [String]) -> String {
        let scrub = markerScrub.map { "-u \($0)" }.joined(separator: " ")
        let argv = ([command] + arguments).map(SSHCommand.shellQuote).joined(separator: " ")
        return "env \(scrub) \(argv)"
    }

    static func channelInvocation(
        host: String,
        worktreePath: String,
        command: String,
        arguments: [String]
    ) -> RemoteExecInvocation {
        RemoteExec.invocation(
            host: host,
            cwd: worktreePath,
            command: agentCommand(command: command, arguments: arguments)
        )
    }

    /// Availability probe for the remote login shell's PATH. Uses the
    /// first word so multi-word catalog commands probe the binary, not flags.
    static func setupProbeCommand(command: String) -> String {
        let binary = command.split(separator: " ").first.map(String.init) ?? command
        return "command -v \(SSHCommand.shellQuote(binary))"
    }

    static func setupProbeCommand(check: ACPSetupCheck) -> String {
        switch check {
        case .binaryOnPath(let name):
            return "command -v \(SSHCommand.shellQuote(name))"
        case .npxPackage(let name):
            return npmPackageProbeCommand(package: name)
        case .binaryOnPathOrNpmPackage(let binary, let package):
            return "command -v \(SSHCommand.shellQuote(binary)) >/dev/null 2>&1 || (\(npmPackageProbeCommand(package: package)))"
        }
    }

    static func launchPathProbeCommand(for spec: ACPLaunchSpec) -> String? {
        let binary = SSHCommand.shellQuote(spec.command)
        switch spec.setupCheck {
        case .binaryOnPath:
            return nil
        case .npxPackage:
            return "\(npmGlobalBinaryProbeCommand(binary: spec.command)) || command -v \(binary)"
        case .binaryOnPathOrNpmPackage:
            return "command -v \(binary) || \(npmGlobalBinaryProbeCommand(binary: spec.command))"
        }
    }

    private static func npmPackageProbeCommand(package: String) -> String {
        "pkg=\(SSHCommand.shellQuote(package)); root=$(npm root -g 2>/dev/null) && [ -n \"$root\" ] && [ -d \"$root/$pkg\" ]"
    }

    private static func npmGlobalBinaryProbeCommand(binary: String) -> String {
        "bin=\(SSHCommand.shellQuote(binary)); prefix=$(npm prefix -g 2>/dev/null) && [ -n \"$prefix\" ] && p=\"$prefix/bin/$bin\" && [ -x \"$p\" ] && printf '%s\\n' \"$p\""
    }

    /// Remote script for an agent `terminal/create`. Only agent-requested
    /// env pairs cross the connection; sorting keeps the result deterministic.
    static func terminalCommand(
        command: String,
        args: [String],
        env: [String: String],
        cwd: String
    ) -> String {
        let pairs = env.sorted { $0.key < $1.key }
            .map { SSHCommand.shellQuote("\($0.key)=\($0.value)") }
        let scrub = markerScrub.map { "-u \($0)" }
        let argv = ([command] + args).map(SSHCommand.shellQuote)
        let envCommand = (["env"] + scrub + pairs + argv).joined(separator: " ")
        return "cd \(SSHCommand.shellQuote(cwd)) && \(envCommand)"
    }
}
