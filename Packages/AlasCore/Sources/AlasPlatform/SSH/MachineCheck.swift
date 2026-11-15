import Foundation
import AlasFoundation
import AlasModel

public enum MachineCheckResult: Equatable, Sendable {
    case ok
    case connectionFailed(String)
    case folderUnusable(String)
}

/// One batch SSH round trip that checks a machine is reachable and that its
/// projects folder exists, or can be created, and is writable.
public enum MachineCheck {
    /// `~` and `~/…` expand on the machine; everything else is quoted as is.
    public static func folderCommand(_ projectsFolder: String) -> String {
        let path: String
        if projectsFolder == "~" {
            path = #""$HOME""#
        } else if projectsFolder.hasPrefix("~/") {
            path = #""$HOME"/"# + SSHCommand.shellQuote(String(projectsFolder.dropFirst(2)))
        } else {
            path = SSHCommand.shellQuote(projectsFolder)
        }
        return "mkdir -p \(path) && test -w \(path) && echo true"
    }

    public static func run(
        host: String,
        projectsFolder: String,
        runner: @escaping RemoteRepoValidator.Runner = { executable, args, timeout in
            try await Process.run(executable, args: args, timeout: timeout)
        }
    ) async -> MachineCheckResult {
        let argv = SSHCommand(host: host, mode: .batch)
            .argv(remoteScript: SSHCommand.remoteScript(command: folderCommand(projectsFolder)))
        let result: ProcessResult
        do {
            result = try await runner(SSHCommand.executable, argv, 30)
        } catch {
            return .connectionFailed(error.localizedDescription)
        }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode == 255 { return .connectionFailed(stderr) }
        if result.exitCode == 0, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
            return .ok
        }
        return .folderUnusable(stderr.isEmpty ? "Can't create or write to \(projectsFolder) on \(host)." : stderr)
    }
}
