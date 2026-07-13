import Foundation

/// Builds `ssh` invocations for remote-project support.
///
/// Every invocation shares one multiplexed master connection per host
/// (`ControlMaster=auto` + `ControlPersist`), so background git probes pay
/// one round trip instead of a TCP+auth handshake, and the user
/// authenticates (password / 2FA / FIDO touch) at most once per idle window.
struct SSHCommand: Equatable {
    enum ControlCommand: String {
        case check
    }

    /// Background probes must never hang on an interactive prompt; they
    /// fail fast instead (`BatchMode=yes`, short connect timeout).
    /// Interactive invocations (terminal surfaces, first-time connects
    /// driven by the user) omit BatchMode so host-key and 2FA prompts can
    /// render.
    enum Mode: Equatable {
        case batch
        case interactive
    }

    enum PathPolicy: Equatable, Sendable {
        case augmented
        case inherited
    }

    static let executable = "/usr/bin/ssh"
    static let scpExecutable = "/usr/bin/scp"
    private static let controlPath = "~/.ssh/alas-%C"

    let host: String
    let mode: Mode

    /// POSIX single-quote escaping: wraps in '...' with embedded single
    /// quotes escaped as '\''. Safe for any content except NUL bytes.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Remote-side script that runs `command` in `cwd`.
    ///
    /// The top-level string is parsed by the account's login shell before
    /// it reaches our script. Keep that layer to a simple `/bin/sh` launch
    /// so users with fish/csh login shells can still run the POSIX snippets
    /// generated throughout the remote stack.
    static func remoteScript(
        cwd: String,
        command: String,
        pathPolicy: PathPolicy = .augmented
    ) -> String {
        remoteScript(
            command: "cd \(shellQuote(cwd)) && \(command)",
            pathPolicy: pathPolicy
        )
    }

    /// Remote-side script without a working-directory change (probes that
    /// must not assume `cwd` exists, e.g. repo validation via `git -C`).
    static func remoteScript(
        command: String,
        pathPolicy: PathPolicy = .augmented
    ) -> String {
        let prelude = pathPolicy == .augmented ? remotePathPrelude : ""
        return "/bin/sh -c \(shellQuote(prelude + command))"
    }

    private static let remotePathPrelude =
        "PATH=\"$HOME/.alas/bin:$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH\"; export PATH; "

    /// Argv after `SSHCommand.executable`. The script rides as the final
    /// argument; sshd hands it to the remote shell as a single string.
    func argv(remoteScript: String) -> [String] {
        optionArgs + [host, remoteScript]
    }

    /// Address an existing multiplexed master without opening a new SSH
    /// connection. Used to tell whether an interactive first-contact flow
    /// actually established the connection needed by background commands.
    func controlArgv(_ command: ControlCommand) -> [String] {
        ["-o", "ControlPath=\(Self.controlPath)", "-O", command.rawValue, host]
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
            "-o", "ControlPath=\(Self.controlPath)",
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
