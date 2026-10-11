import Foundation

public enum RemoteRepoValidationError: LocalizedError, Sendable {
    case connectionFailed(String)
    case notARepository(String)
    case notADirectory(String)

    public var errorDescription: String? {
        switch self {
        case let .connectionFailed(detail):
            let message = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "Could not reach the host over SSH." : message
        case let .notARepository(path):
            return "Not a git repository on the remote host: \(path)"
        case let .notADirectory(path):
            return "Not a directory on the remote host: \(path)"
        }
    }
}

/// User-driven repository validation for the add-project flow.
public struct RemoteRepoValidator: Sendable {
    public typealias Runner = (String, [String], TimeInterval) async throws -> ProcessResult

    public static func validate(
        host: String,
        path: String,
        kind: ProjectKind = .git,
        runner: @escaping Runner = { executable, args, timeout in
            try await Process.run(executable, args: args, timeout: timeout)
        }
    ) async throws {
        let batchSSH = SSHCommand(host: host, mode: .batch)
        let quoted = SSHCommand.shellQuote(path)
        let command = switch kind {
        case .git: "git -C \(quoted) rev-parse --is-inside-work-tree"
        case .folder: "test -d \(quoted) && echo true"
        }
        let result = try await runner(
            SSHCommand.executable,
            batchSSH.argv(remoteScript: SSHCommand.remoteScript(command: command)),
            30
        )
        if result.exitCode == 255 {
            throw RemoteRepoValidationError.connectionFailed(result.stderr)
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, output == "true" else {
            throw kind == .git
                ? RemoteRepoValidationError.notARepository(path)
                : RemoteRepoValidationError.notADirectory(path)
        }
    }

    public static func interactiveSetupInvocation(host: String) -> RemoteExecInvocation {
        RemoteTerminalScript.surfaceInvocation(host: host, script: "true")
    }

    public static func waitForActiveControlMaster(
        host: String,
        attempts: Int = 10,
        retryDelay: Duration = .milliseconds(200),
        runner: @escaping Runner = { executable, args, timeout in
            try await Process.run(executable, args: args, timeout: timeout)
        }
    ) async -> Bool {
        let argv = SSHCommand(host: host, mode: .batch).controlArgv(.check)
        for attempt in 0..<max(1, attempts) {
            if let result = try? await runner(SSHCommand.executable, argv, 5),
               result.exitCode == 0 {
                return true
            }
            if attempt + 1 < attempts {
                try? await Task.sleep(for: retryDelay)
            }
        }
        return false
    }

    public init() {
    }
}
