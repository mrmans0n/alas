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
    func currentReviewRequest(
        remote: CodeHostRemote,
        branch: String,
        headOwner: String?,
        baseBranch: String,
        cwd: URL
    ) async throws -> ReviewRequest?
    func createReviewRequest(
        remote: CodeHostRemote,
        branch: String,
        headOwner: String?,
        baseBranch: String,
        title: String,
        body: String,
        isDraft: Bool,
        cwd: URL
    ) async throws -> URL
    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck]
    func failedCheckEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem]
    func checkEvidenceDetail(
        remote: CodeHostRemote,
        request: ReviewRequest,
        item: ReviewEvidenceItem,
        cwd: URL
    ) async throws -> ReviewEvidenceDetail
    func feedbackEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem]
    func feedbackEvidenceDetail(
        remote: CodeHostRemote,
        request: ReviewRequest,
        item: ReviewEvidenceItem,
        cwd: URL
    ) async throws -> ReviewEvidenceDetail
    func rerunFailedChecks(
        remote: CodeHostRemote,
        branch: String,
        headSHA: String,
        request: ReviewRequest?,
        cwd: URL
    ) async throws
}

extension CodeHostProvider {
    var capabilities: CodeHostProviderCapabilities { .readOnly }

    func failedCheckEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] {
        request.checks
            .filter { $0.bucket == .fail }
            .map {
                ReviewEvidenceItem(
                    id: $0.id,
                    section: .ci,
                    title: $0.name,
                    subtitle: $0.workflow,
                    status: .failed,
                    providerURL: $0.detailURL
                )
            }
    }

    func checkEvidenceDetail(
        remote: CodeHostRemote,
        request: ReviewRequest,
        item: ReviewEvidenceItem,
        cwd: URL
    ) async throws -> ReviewEvidenceDetail {
        ReviewEvidenceDetail(
            item: item,
            body: "Open this check in the provider to inspect full logs.",
            filePath: nil,
            line: nil,
            isTruncated: false
        )
    }

    func feedbackEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] {
        request.threads
            .filter { !$0.isResolved && $0.isActionable }
            .map {
                ReviewEvidenceItem(
                    id: $0.id,
                    section: .feedback,
                    title: $0.author ?? "reviewer",
                    subtitle: String($0.body.prefix(120)),
                    status: .actionable,
                    providerURL: $0.url
                )
            }
    }

    func feedbackEvidenceDetail(
        remote: CodeHostRemote,
        request: ReviewRequest,
        item: ReviewEvidenceItem,
        cwd: URL
    ) async throws -> ReviewEvidenceDetail {
        let thread = request.threads.first { $0.id == item.id }
        return ReviewEvidenceDetail(
            item: item,
            body: thread?.body ?? "Open this feedback in the provider to inspect full context.",
            filePath: nil,
            line: nil,
            isTruncated: false
        )
    }
}

struct CodeHostProviderRegistry: Sendable {
    let providers: [CodeHostKind: any CodeHostProvider]

    var supportedKinds: Set<CodeHostKind> {
        Set(providers.keys)
    }

    static func live() -> CodeHostProviderRegistry {
        CodeHostProviderRegistry(providers: [
            .github: GitHubCLIProvider(),
            .gitlab: GitLabCLIProvider(),
        ])
    }

    func provider(for kind: CodeHostKind) -> (any CodeHostProvider)? {
        providers[kind]
    }
}
