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
        let status = structuredStatus(in: result.stdout)
            ?? structuredStatus(in: result.stderr)
            ?? httpStatus(in: "\(result.stdout)\n\(result.stderr)")
        switch status {
        case 404:
            return .notFound(provider: provider, repositorySlug: remote.repositorySlug, number: number)
        case 403:
            return .permissionDenied(host: remote.host)
        default:
            return nil
        }
    }

    private static func structuredStatus(in output: String) -> Int? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            return nil
        }
        for key in ["status", "code"] {
            if let status = dictionary[key] as? Int { return status }
            if let status = dictionary[key] as? String, let value = Int(status) { return value }
        }
        guard let message = dictionary["message"] as? String else { return nil }
        return leadingStatus(in: message)
    }

    private static func httpStatus(in output: String) -> Int? {
        for status in [403, 404] where output.range(
            of: "\\b(?:HTTP(?:\\s+status)?|status(?:\\s+code)?)\\s*[:=]?\\s*\(status)\\b",
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return status
        }
        return nil
    }

    private static func leadingStatus(in value: String) -> Int? {
        for status in [403, 404] where value.range(
            of: "^\\s*\(status)\\b",
            options: .regularExpression
        ) != nil {
            return status
        }
        return nil
    }
}

extension CodeHostRemote {
    func missionIssueIdentity(number: Int) -> MissionIssueIdentity {
        let host = host.lowercased()
        let repositorySlug: String
        switch kind {
        case .github:
            repositorySlug = self.repositorySlug.lowercased()
        case .gitlab:
            repositorySlug = self.repositorySlug.lowercased()
        }
        return MissionIssueIdentity(provider: kind, host: host, repositorySlug: repositorySlug, number: number)
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
