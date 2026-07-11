import Foundation

enum RemoteRepoValidationError: LocalizedError {
    case unreachable(String)
    case notARepository(String)

    var errorDescription: String? {
        switch self {
        case let .unreachable(detail):
            let message = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "Could not reach the host over SSH." : message
        case let .notARepository(path):
            return "Not a git repository on the remote host: \(path)"
        }
    }
}

/// Batch-mode repository validation for the add-project flow.
struct RemoteRepoValidator {
    static func validate(host: String, path: String) async throws {
        let command = "git -C \(SSHCommand.shellQuote(path)) rev-parse --is-inside-work-tree"
        let ssh = SSHCommand(host: host, mode: .batch)
        let result = try await Process.run(
            SSHCommand.executable,
            args: ssh.argv(remoteScript: SSHCommand.remoteScript(command: command)),
            timeout: 20
        )
        if result.exitCode == 255 {
            throw RemoteRepoValidationError.unreachable(result.stderr)
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, output == "true" else {
            throw RemoteRepoValidationError.notARepository(path)
        }
    }
}
