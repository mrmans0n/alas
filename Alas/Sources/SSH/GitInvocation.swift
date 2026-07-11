import Foundation

/// The concrete process configuration for one local or remote git invocation.
struct GitInvocation: Equatable {
    let executable: String
    let args: [String]
    let env: [String: String]?
    let cwd: URL?

    static func build(gitArgs: [String], cwd: URL?, host: String?) -> GitInvocation {
        guard let host else {
            return GitInvocation(
                executable: "/usr/bin/env",
                args: ["git"] + gitArgs,
                env: Process.gitEnv(),
                cwd: cwd
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
