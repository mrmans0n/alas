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

/// User-driven repository validation for the add-project flow.
struct RemoteRepoValidator {
    typealias Runner = (String, [String], TimeInterval) async throws -> ProcessResult

    static func validate(
        host: String,
        path: String,
        runner: @escaping Runner = { executable, args, timeout in
            try await Process.run(executable, args: args, timeout: timeout)
        }
    ) async throws {
        let interactiveSSH = SSHCommand(host: host, mode: .interactive)
        let preflight = try await runner(
            SSHCommand.executable,
            interactiveSSH.argv(remoteScript: SSHCommand.remoteScript(command: "true")),
            30
        )
        guard preflight.exitCode == 0 else {
            throw RemoteRepoValidationError.unreachable(firstContactFailureMessage(host: host, detail: preflight.stderr))
        }

        let batchSSH = SSHCommand(host: host, mode: .batch)
        let command = "git -C \(SSHCommand.shellQuote(path)) rev-parse --is-inside-work-tree"
        let result = try await runner(
            SSHCommand.executable,
            batchSSH.argv(remoteScript: SSHCommand.remoteScript(command: command)),
            30
        )
        if result.exitCode == 255 {
            throw RemoteRepoValidationError.unreachable(firstContactFailureMessage(host: host, detail: result.stderr))
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, output == "true" else {
            throw RemoteRepoValidationError.notARepository(path)
        }
    }

    static func firstContactFailureMessage(host: String, detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let setupCommand = ([SSHCommand.executable] + SSHCommand(host: host, mode: .interactive).argv(
            remoteScript: SSHCommand.remoteScript(command: "true")
        ))
        .map(localShellQuote)
        .joined(separator: " ")
        let guidance = "SSH access to \(host) needs interactive setup before adding this remote project. Run `\(setupCommand)` from a terminal to accept host keys or complete authentication, then try again."
        return trimmed.isEmpty ? guidance : "\(guidance)\n\(trimmed)"
    }

    private static func localShellQuote(_ value: String) -> String {
        if value.range(of: "[^A-Za-z0-9_/.@%+=,:~-]", options: .regularExpression) == nil {
            return value
        }
        return SSHCommand.shellQuote(value)
    }
}
