import Foundation

/// The concrete process configuration for one local or remote git invocation.
struct GitInvocation: Equatable {
    let executable: String
    let args: [String]
    let env: [String: String]?
    let cwd: URL?

    static func build(gitArgs: [String], cwd: URL?, host: String?) -> GitInvocation {
        guard let host else {
            // Keep Foundation's launch cwd unset: a worktree can disappear after
            // preflight, while `git -C` reports that race as a normal exit.
            let localArgs = cwd.map { ["git", "-C", $0.path] + gitArgs }
                ?? ["git"] + gitArgs
            return GitInvocation(
                executable: "/usr/bin/env",
                args: localArgs,
                env: Process.gitEnv(),
                cwd: nil
            )
        }

        let command = ["env", "GIT_OPTIONAL_LOCKS=0", "LC_ALL=C", "git"]
            .joined(separator: " ")
            + " "
            + gitArgs.map(SSHCommand.shellQuote).joined(separator: " ")
        let script = cwd.map { SSHCommand.remoteScript(cwd: $0.path, command: command) }
            ?? SSHCommand.remoteScript(command: command)
        let ssh = SSHCommand(host: host, mode: .batch)
        return GitInvocation(
            executable: SSHCommand.executable,
            args: ssh.argv(remoteScript: script),
            env: nil,
            cwd: nil
        )
    }
}
