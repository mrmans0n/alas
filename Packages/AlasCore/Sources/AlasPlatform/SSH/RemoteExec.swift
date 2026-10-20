import Foundation
import AlasFoundation
import AlasModel

public struct RemoteExecInvocation: Equatable, Sendable {
    public let executable: String
    public let args: [String]

    public init(executable: String, args: [String]) {
        self.executable = executable
        self.args = args
    }
}

/// Runs a non-git command on a remote host in batch mode. Git commands go
/// through `Process.git` (host-aware via `RemoteHostRegistry`); this is for
/// everything else a remote project needs: capability probes, `ls`, `wc`.
public enum RemoteExec: Sendable {
    public static func invocation(
        host: String,
        cwd: String?,
        command: String,
        pathPolicy: SSHCommand.PathPolicy = .augmented
    ) -> RemoteExecInvocation {
        let script = cwd.map {
            SSHCommand.remoteScript(cwd: $0, command: command, pathPolicy: pathPolicy)
        } ?? SSHCommand.remoteScript(command: command, pathPolicy: pathPolicy)
        let ssh = SSHCommand(host: host, mode: .batch)
        return RemoteExecInvocation(
            executable: SSHCommand.executable,
            args: ssh.argv(remoteScript: script)
        )
    }

    public static func run(
        host: String,
        cwd: String?,
        command: String,
        timeout: TimeInterval = Process.defaultTimeout,
        pathPolicy: SSHCommand.PathPolicy = .augmented
    ) async throws -> ProcessResult {
        let invocation = invocation(
            host: host,
            cwd: cwd,
            command: command,
            pathPolicy: pathPolicy
        )
        return try await Process.run(invocation.executable, args: invocation.args, timeout: timeout)
    }

    /// Binary-safe variant of `run` (stdout as raw `Data`).
    public static func runData(
        host: String,
        cwd: String?,
        command: String,
        timeout: TimeInterval? = Process.defaultTimeout,
        pathPolicy: SSHCommand.PathPolicy = .augmented
    ) async throws -> ProcessResultData {
        let invocation = invocation(
            host: host,
            cwd: cwd,
            command: command,
            pathPolicy: pathPolicy
        )
        return try await Process.runData(
            invocation.executable,
            args: invocation.args,
            timeout: timeout
        )
    }

    /// ssh reserves exit code 255 for its own failures (connect, auth,
    /// host key); any other code is the remote command's exit status.
    public static func isConnectionFailure(exitCode: Int32) -> Bool {
        exitCode == 255
    }
}
