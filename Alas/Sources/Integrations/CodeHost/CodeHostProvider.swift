import Foundation

enum CodeHostProviderError: LocalizedError, Equatable {
    case cliMissing(String)
    case unauthenticated(String)
    case commandFailed(command: String, stderr: String)
    case unsupportedProvider(CodeHostKind)
    case malformedOutput(String)

    var errorDescription: String? {
        switch self {
        case .cliMissing(let executable):
            return "\(executable) is not installed or is not available on PATH."
        case .unauthenticated(let host):
            return "Authentication is required for \(host)."
        case .commandFailed(let command, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "\(command) failed."
            } else {
                return "\(command) failed: \(trimmed)"
            }
        case .unsupportedProvider(let kind):
            return "\(kind.displayName) is not supported yet."
        case .malformedOutput(let message):
            return message
        }
    }
}

protocol CodeHostCommandRunning: Sendable {
    func run(_ executable: String, args: [String], cwd: URL?) async throws -> ProcessResult
}

struct ProcessCodeHostCommandRunner: CodeHostCommandRunning {
    func run(_ executable: String, args: [String], cwd: URL?) async throws -> ProcessResult {
        try await Process.run("/usr/bin/env", args: [executable] + args, cwd: cwd, env: Process.gitEnv())
    }
}

protocol CodeHostProvider: Sendable {
    var kind: CodeHostKind { get }
    var capabilities: CodeHostProviderCapabilities { get }

    func isAvailable() async -> Bool
    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool
    func currentReviewRequest(remote: CodeHostRemote, branch: String, cwd: URL) async throws -> ReviewRequest?
    func createReviewRequest(
        remote: CodeHostRemote,
        branch: String,
        baseBranch: String,
        title: String,
        body: String,
        cwd: URL
    ) async throws -> URL
    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck]
    func rerunFailedChecks(remote: CodeHostRemote, branch: String, cwd: URL) async throws
}

extension CodeHostProvider {
    var capabilities: CodeHostProviderCapabilities { .readOnly }
}

struct CodeHostProviderRegistry: Sendable {
    let providers: [CodeHostKind: any CodeHostProvider]

    var supportedKinds: Set<CodeHostKind> {
        Set(providers.keys)
    }

    static func live() -> CodeHostProviderRegistry {
        CodeHostProviderRegistry(providers: [.github: GitHubCLIProvider()])
    }

    func provider(for kind: CodeHostKind) -> (any CodeHostProvider)? {
        providers[kind]
    }
}
