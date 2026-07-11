import Foundation

struct RemoteExecInvocation: Equatable {
    let executable: String
    let args: [String]
}

/// Runs a non-git command on a remote host in batch mode. Git commands go
/// through `Process.git` (host-aware via `RemoteHostRegistry`); this is for
/// everything else a remote project needs: capability probes, `ls`, `wc`.
enum RemoteExec {
    static func invocation(host: String, cwd: String?, command: String) -> RemoteExecInvocation {
        let script = cwd.map { SSHCommand.remoteScript(cwd: $0, command: command) }
            ?? SSHCommand.remoteScript(command: command)
        let ssh = SSHCommand(host: host, mode: .batch)
        return RemoteExecInvocation(
            executable: SSHCommand.executable,
            args: ssh.argv(remoteScript: script)
        )
    }

    static func run(
        host: String,
        cwd: String?,
        command: String,
        timeout: TimeInterval = Process.defaultTimeout
    ) async throws -> ProcessResult {
        let invocation = invocation(host: host, cwd: cwd, command: command)
        return try await Process.run(invocation.executable, args: invocation.args, timeout: timeout)
    }

    /// ssh reserves exit code 255 for its own failures (connect, auth,
    /// host key); any other code is the remote command's exit status.
    static func isConnectionFailure(exitCode: Int32) -> Bool {
        exitCode == 255
    }
}
