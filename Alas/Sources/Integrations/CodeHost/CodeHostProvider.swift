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

struct CodeHostReviewImageRevisions: Equatable, Sendable {
    let beforeSHA: String
    let afterSHA: String
}

protocol CodeHostCommandRunning: Sendable {
    func run(_ executable: String, args: [String], cwd: URL?, stdin: String?) async throws -> ProcessResult
}

extension CodeHostCommandRunning {
    func run(_ executable: String, args: [String], cwd: URL?) async throws -> ProcessResult {
        try await run(executable, args: args, cwd: cwd, stdin: nil)
    }
}

struct ProcessCodeHostCommandRunner: CodeHostCommandRunning {
    func run(_ executable: String, args: [String], cwd: URL?, stdin: String?) async throws -> ProcessResult {
        let invocation = CodeHostCommandInvocation.build(
            executable: executable,
            args: args,
            cwd: cwd
        )
        return try await Process.run(
            invocation.executable,
            args: invocation.args,
            cwd: invocation.cwd,
            env: invocation.env,
            stdin: stdin
        )
    }
}

struct CodeHostCommandInvocation: Equatable {
    let executable: String
    let args: [String]
    let cwd: URL?
    let env: [String: String]?

    static func build(executable: String, args: [String], cwd: URL?) -> Self {
        guard let cwd,
              let host = RemoteHostRegistry.shared.host(forPath: cwd.path)
        else {
            return Self(
                executable: "/usr/bin/env",
                args: [executable] + args,
                cwd: cwd,
                env: Process.gitEnv()
            )
        }

        let command = (["env", "GIT_OPTIONAL_LOCKS=0", "LC_ALL=C", executable] + args)
            .map(SSHCommand.shellQuote)
            .joined(separator: " ")
        let remote = RemoteExec.invocation(host: host, cwd: cwd.path, command: command)
        return Self(executable: remote.executable, args: remote.args, cwd: nil, env: nil)
    }
}

protocol CodeHostProvider: Sendable {
    var kind: CodeHostKind { get }
    var capabilities: CodeHostProviderCapabilities { get }

    func isAvailable(cwd: URL) async -> Bool
    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool
    func currentReviewRequest(
        remote: CodeHostRemote,
        branch: String,
        headOwner: String?,
        baseBranch: String,
        cwd: URL
    ) async throws -> ReviewRequest?
    func reviewRequest(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> ReviewRequest
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
    func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String
    func reviewImageRevisions(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async throws -> CodeHostReviewImageRevisions
    func reviewFileData(
        remote: CodeHostRemote,
        revision: String,
        path: String,
        cwd: URL
    ) async throws -> Data
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
    func replyToThread(
        remote: CodeHostRemote,
        request: ReviewRequest,
        thread: ReviewThread,
        body: String,
        cwd: URL
    ) async throws -> ReviewComment
    func resolveThread(
        remote: CodeHostRemote,
        request: ReviewRequest,
        thread: ReviewThread,
        cwd: URL
    ) async throws -> ReviewThread
    func unresolveThread(
        remote: CodeHostRemote,
        request: ReviewRequest,
        thread: ReviewThread,
        cwd: URL
    ) async throws -> ReviewThread
    func editComment(
        remote: CodeHostRemote,
        request: ReviewRequest,
        comment: ReviewComment,
        newBody: String,
        cwd: URL
    ) async throws -> ReviewComment
    func deleteComment(
        remote: CodeHostRemote,
        request: ReviewRequest,
        comment: ReviewComment,
        cwd: URL
    ) async throws

    func mergeReviewRequest(
        _ request: ReviewRequest,
        method: ReviewMergeMethod,
        deleteBranch: Bool,
        cwd: URL
    ) async throws

    func startReview(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async throws -> String

    func cancelReview(
        remote: CodeHostRemote,
        request: ReviewRequest,
        reviewID: String,
        cwd: URL
    ) async throws

    func addReviewComment(
        remote: CodeHostRemote,
        request: ReviewRequest,
        reviewID: String,
        comment: StagedComment,
        cwd: URL
    ) async throws

    func submitReview(
        remote: CodeHostRemote,
        request: ReviewRequest,
        reviewID: String,
        verdict: ReviewVerdict,
        body: String,
        cwd: URL
    ) async throws

    func checkAnnotations(remote: CodeHostRemote, check: ReviewCheck, cwd: URL) async throws -> [CheckAnnotation]

    func publishReview(_ request: ProviderReviewPublishRequest) async throws -> ProviderReviewPublishResult
    func mutateReviewThread(_ mutation: ProviderThreadMutation) async throws -> ProviderThreadMutationResult
}

extension CodeHostProvider {
    var capabilities: CodeHostProviderCapabilities { .readOnly }

    func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String {
        throw CodeHostProviderError.unsupportedProvider(remote.kind)
    }

    func reviewImageRevisions(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async throws -> CodeHostReviewImageRevisions {
        throw CodeHostProviderError.unsupportedProvider(remote.kind)
    }

    func reviewFileData(
        remote: CodeHostRemote,
        revision: String,
        path: String,
        cwd: URL
    ) async throws -> Data {
        throw CodeHostProviderError.unsupportedProvider(remote.kind)
    }

    func reviewRequest(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> ReviewRequest {
        throw CodeHostProviderError.unsupportedProvider(remote.kind)
    }

    func failedCheckEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] {
        ReviewEvidenceCIActivityMapper.items(for: request.checks)
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
        let items = request.threads
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
        if items.isEmpty, request.reviewDecision == .changesRequested {
            return [ReviewEvidenceFallbacks.changesRequestedItem(request: request)]
        }
        return items
    }

    func feedbackEvidenceDetail(
        remote: CodeHostRemote,
        request: ReviewRequest,
        item: ReviewEvidenceItem,
        cwd: URL
    ) async throws -> ReviewEvidenceDetail {
        if item.id == ReviewEvidenceFallbacks.changesRequestedID {
            return ReviewEvidenceFallbacks.changesRequestedDetail(item: item, request: request)
        }
        let thread = request.threads.first { $0.id == item.id }
        return ReviewEvidenceDetail(
            item: item,
            body: thread?.body ?? "Open this feedback in the provider to inspect full context.",
            filePath: nil,
            line: nil,
            isTruncated: false
        )
    }

    func replyToThread(
        remote: CodeHostRemote,
        request: ReviewRequest,
        thread: ReviewThread,
        body: String,
        cwd: URL
    ) async throws -> ReviewComment {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    func resolveThread(
        remote: CodeHostRemote,
        request: ReviewRequest,
        thread: ReviewThread,
        cwd: URL
    ) async throws -> ReviewThread {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    func unresolveThread(
        remote: CodeHostRemote,
        request: ReviewRequest,
        thread: ReviewThread,
        cwd: URL
    ) async throws -> ReviewThread {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    func editComment(
        remote: CodeHostRemote,
        request: ReviewRequest,
        comment: ReviewComment,
        newBody: String,
        cwd: URL
    ) async throws -> ReviewComment {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    func deleteComment(
        remote: CodeHostRemote,
        request: ReviewRequest,
        comment: ReviewComment,
        cwd: URL
    ) async throws {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    func mergeReviewRequest(
        _ request: ReviewRequest,
        method: ReviewMergeMethod,
        deleteBranch: Bool,
        cwd: URL
    ) async throws {
        throw CodeHostProviderError.unsupportedProvider(request.remote.kind)
    }

    func startReview(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async throws -> String {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    func cancelReview(
        remote: CodeHostRemote,
        request: ReviewRequest,
        reviewID: String,
        cwd: URL
    ) async throws {}

    func addReviewComment(
        remote: CodeHostRemote,
        request: ReviewRequest,
        reviewID: String,
        comment: StagedComment,
        cwd: URL
    ) async throws {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    func submitReview(
        remote: CodeHostRemote,
        request: ReviewRequest,
        reviewID: String,
        verdict: ReviewVerdict,
        body: String,
        cwd: URL
    ) async throws {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    func checkAnnotations(remote: CodeHostRemote, check: ReviewCheck, cwd: URL) async throws -> [CheckAnnotation] {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    func publishReview(_ request: ProviderReviewPublishRequest) async throws -> ProviderReviewPublishResult {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    func mutateReviewThread(_ mutation: ProviderThreadMutation) async throws -> ProviderThreadMutationResult {
        throw CodeHostProviderError.unsupportedProvider(kind)
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
