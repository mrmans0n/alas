import Foundation

protocol CodeHostIssueProviding: Sendable {
    var kind: CodeHostKind { get }
    var executable: String { get }

    func isAvailable(cwd: URL) async -> Bool
    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool
    func issue(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> MissionIssueSnapshot
}

enum CodeHostIssueProviderError: LocalizedError, Equatable, Sendable {
    case notFound(provider: CodeHostKind, repositorySlug: String, number: Int)
    case permissionDenied(host: String)

    var errorDescription: String? {
        switch self {
        case .notFound(let provider, let repositorySlug, let number):
            return "\(provider.displayName) issue #\(number) was not found in \(repositorySlug)."
        case .permissionDenied(let host):
            return "Permission to read issues on \(host) was denied."
        }
    }

    static func classification(
        provider: CodeHostKind,
        remote: CodeHostRemote,
        number: Int,
        result: ProcessResult
    ) -> Self? {
        let output = "\(result.stdout)\n\(result.stderr)".lowercased()
        if output.contains("404") || output.contains("not found") {
            return .notFound(provider: provider, repositorySlug: remote.repositorySlug, number: number)
        }
        if output.contains("403") || output.contains("forbidden") || output.contains("permission denied") || output.contains("not authorized") {
            return .permissionDenied(host: remote.host)
        }
        return nil
    }
}

struct CodeHostIssueProviderRegistry: Sendable {
    private let providersByKind: [String: any CodeHostIssueProviding]

    init(_ providers: [any CodeHostIssueProviding]) {
        providersByKind = Dictionary(uniqueKeysWithValues: providers.map { ($0.kind.rawValue, $0) })
    }

    func provider(for kind: CodeHostKind) -> (any CodeHostIssueProviding)? {
        providersByKind[kind.rawValue]
    }

    static func live() -> Self {
        .init([GitHubCLIProvider(), GitLabCLIProvider()])
    }
}
