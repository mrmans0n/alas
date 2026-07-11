import Foundation

/// Builds `ssh` invocations for remote-project support.
///
/// Every invocation shares one multiplexed master connection per host
/// (`ControlMaster=auto` + `ControlPersist`), so background git probes pay
/// one round trip instead of a TCP+auth handshake, and the user
/// authenticates (password / 2FA / FIDO touch) at most once per idle window.
struct SSHCommand: Equatable {
    /// Background probes must never hang on an interactive prompt; they
    /// fail fast instead (`BatchMode=yes`, short connect timeout).
    /// Interactive invocations (terminal surfaces, first-time connects
    /// driven by the user) omit BatchMode so host-key and 2FA prompts can
    /// render.
    enum Mode: Equatable {
        case batch
        case interactive
    }

    static let executable = "/usr/bin/ssh"
    static let scpExecutable = "/usr/bin/scp"

    let host: String
    let mode: Mode

    /// POSIX single-quote escaping: wraps in '...' with embedded single
    /// quotes escaped as '\''. Safe for any content except NUL bytes.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Remote-side script that runs `command` in `cwd`.
    ///
    /// `exec "$SHELL" -l -c` forces a login shell: sshd runs remote
    /// commands through a non-login shell whose PATH misses Homebrew
    /// (macOS remotes) and per-user additions (Linux), so `git`/`rg`
    /// would otherwise be "command not found".
    static func remoteScript(cwd: String, command: String) -> String {
        "cd -- \(shellQuote(cwd)) && \(remoteScript(command: command))"
    }

    /// Remote-side script without a working-directory change (probes that
    /// must not assume `cwd` exists, e.g. repo validation via `git -C`).
    static func remoteScript(command: String) -> String {
        "exec \"$SHELL\" -l -c \(shellQuote(command))"
    }

    /// Argv after `SSHCommand.executable`. The script rides as the final
    /// argument; sshd hands it to the remote shell as a single string.
    func argv(remoteScript: String) -> [String] {
        optionArgs + [host, remoteScript]
    }

    /// scp rides the same multiplexed batch connection as remote commands.
    /// The destination is home-relative because scp does not reliably expand
    /// a quoted `~` on every server implementation.
    static func scpArgv(localPath: String, host: String, remotePath: String) -> [String] {
        SSHCommand(host: host, mode: .batch).optionArgs
            + ["-q", localPath, "\(host):\(remotePath)"]
    }

    private var optionArgs: [String] {
        var options: [String] = [
            "-o", "ControlMaster=auto",
            // %C is a short hash of (host, port, user); keeps the socket
            // path well under the ~104-byte unix-socket limit.
            "-o", "ControlPath=~/.ssh/alas-%C",
            "-o", "ControlPersist=10m",
            // Dead-peer detection on every invocation that might become
            // the master: ~15s (3 missed 5s keepalives).
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
        ]
        switch mode {
        case .batch:
            options += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        case .interactive:
            options += ["-o", "ConnectTimeout=30"]
        }
        return options
    }
}
