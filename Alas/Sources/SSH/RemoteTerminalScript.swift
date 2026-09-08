import Foundation

/// Remote-side scripts for user-facing terminal surfaces and background zmx
/// operations. All zmx state lives under `$HOME/.alas/zmx` so Alas never
/// lists or kills a user's own zmx sessions.
enum RemoteTerminalScript {
    static let remoteZmxDirExport =
        "export ZMX_DIR=\"$HOME/.alas/zmx\"; mkdir -p \"$ZMX_DIR\""

    /// Prefer a host-installed zmx, then the Alas-pushed copy. An empty value
    /// lets terminal surfaces fall back to a plain login shell.
    private static let resolveZmx =
        "Z=\"$(command -v zmx 2>/dev/null || true)\"; "
        + "[ -z \"$Z\" ] && [ -x \"$HOME/.alas/bin/zmx\" ] && Z=\"$HOME/.alas/bin/zmx\""

    /// The command handed to zmx, or run directly without persistence.
    private static func shellCommand(startupSuffix: String?) -> String {
        guard let suffix = startupSuffix, !suffix.isEmpty else {
            return "\"$SHELL\" -l"
        }
        let command = SSHCommand.shellQuote("\(suffix); exec \"$SHELL\" -l")
        if suffix.contains("__alas_run_script_capture()") {
            return "\"$SHELL\" -l -c \(SSHCommand.shellQuote("exec /bin/sh -lc \(command)"))"
        }
        return "\"$SHELL\" -l -c \(command)"
    }

    static func attachScript(
        worktreePath: String,
        sessionName: String,
        useZmx: Bool,
        startupSuffix: String?,
        environment: [String: String] = [:]
    ) -> String {
        let shell = shellCommand(startupSuffix: startupSuffix)
        let body: String
        if useZmx {
            body = "\(remoteZmxDirExport); \(resolveZmx); "
                + "if [ -n \"$Z\" ]; then exec \"$Z\" attach \(SSHCommand.shellQuote(sessionName)) \(shell); "
                + "else exec \(shell); fi"
        } else {
            body = "exec \(shell)"
        }
        let exports = environment
            .filter { $0.key.hasPrefix("ALAS_WORKSPACE_") }
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(SSHCommand.shellQuote($0.value))" }
            .joined(separator: "; ")
        let prefix = exports.isEmpty ? "" : "\(exports); "
        return "\(prefix)cd \(SSHCommand.shellQuote(worktreePath)) || exit; \(body)"
    }

    /// `-tt` forces remote pty allocation. Interactive SSH permits first-use
    /// host-key and authentication prompts to appear in the terminal surface.
    static func surfaceInvocation(host: String, script: String) -> RemoteExecInvocation {
        let ssh = SSHCommand(host: host, mode: .interactive)
        return RemoteExecInvocation(
            executable: SSHCommand.executable,
            args: ["-tt"] + ssh.argv(remoteScript: SSHCommand.remoteScript(command: script))
        )
    }

    /// Background zmx operation sharing the surface sessions' state directory
    /// and binary-resolution ladder. A missing zmx reports no sessions.
    static func zmxBatchCommand(_ args: [String]) -> String {
        let argv = args.map(SSHCommand.shellQuote).joined(separator: " ")
        return "\(remoteZmxDirExport); \(resolveZmx); "
            + "[ -n \"$Z\" ] || exit 0; \"$Z\" \(argv)"
    }
}
