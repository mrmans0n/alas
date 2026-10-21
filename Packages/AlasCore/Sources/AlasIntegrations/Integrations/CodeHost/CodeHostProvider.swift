import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures

public enum CodeHostProviderError: LocalizedError, Equatable, Sendable {
    case cliMissing(String)
    case unauthenticated(String)
    case commandFailed(command: String, stderr: String)
    case unsupportedProvider(CodeHostKind)
    case malformedOutput(String)

    public var errorDescription: String? {
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

public struct CodeHostReviewImageRevisions: Equatable, Sendable {
    public let beforeSHA: String
    public let afterSHA: String

    public init(beforeSHA: String, afterSHA: String) {
        self.beforeSHA = beforeSHA
        self.afterSHA = afterSHA
    }
}

public protocol CodeHostCommandRunning: Sendable {
    func run(_ executable: String, args: [String], cwd: URL?, stdin: String?) async throws -> ProcessResult
    func runData(_ executable: String, args: [String], cwd: URL?) async throws -> ProcessResultData
}

extension CodeHostCommandRunning {
    public func run(_ executable: String, args: [String], cwd: URL?) async throws -> ProcessResult {
        try await run(executable, args: args, cwd: cwd, stdin: nil)
    }

    public func runData(_ executable: String, args: [String], cwd: URL?) async throws -> ProcessResultData {
        let result = try await run(executable, args: args, cwd: cwd, stdin: nil)
        return ProcessResultData(
            exitCode: result.exitCode,
            stdout: Data(result.stdout.utf8),
            stderr: result.stderr
        )
    }
}

public struct ProcessCodeHostCommandRunner: CodeHostCommandRunning, Sendable {
    public func run(_ executable: String, args: [String], cwd: URL?, stdin: String?) async throws -> ProcessResult {
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

    public func runData(_ executable: String, args: [String], cwd: URL?) async throws -> ProcessResultData {
        let invocation = CodeHostCommandInvocation.build(
            executable: executable,
            args: args,
            cwd: cwd
        )
        return try await Process.runData(
            invocation.executable,
            args: invocation.args,
            cwd: invocation.cwd,
            env: invocation.env
        )
    }

    public init() {
    }
}

public struct CodeHostCommandInvocation: Equatable, Sendable {
    public let executable: String
    public let args: [String]
    public let cwd: URL?
    public let env: [String: String]?

    public static func build(executable: String, args: [String], cwd: URL?) -> Self {
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

    public init(executable: String, args: [String], cwd: URL?, env: [String: String]?) {
        self.executable = executable
        self.args = args
        self.cwd = cwd
        self.env = env
    }
}

public protocol CodeHostProvider: Sendable {
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
    /// One lightweight lookup for a reference chip's hover card.
    func referenceSummary(
        remote: CodeHostRemote,
        reference: CodeHostReference,
        cwd: URL
    ) async throws -> CodeHostReferenceSummary
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
        repository: String,
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

    /// Merged review requests whose head branch is one of `headBranches`, in
    /// as few round-trips as the provider allows. Asking only for the branches
    /// being scanned keeps the cost proportional to the worktrees rather than
    /// to the repository's merge history.
    func mergedReviewRequests(
        remote: CodeHostRemote,
        headBranches: [String],
        cwd: URL
    ) async throws -> [MergedReviewRequestRef]

    /// The repository `remote` was forked from, if any. A fork's own pull/
    /// merge requests are almost never opened against itself — the classic
    /// contribution workflow opens them against the parent, and that is
    /// where a merge actually lands — so worktree cleanup queries the parent
    /// for merged review requests instead of the fork when one exists.
    /// Returns `nil` for a repository that is not a fork.
    func repositoryParent(remote: CodeHostRemote, cwd: URL) async throws -> CodeHostRemote?

    /// Lowercased logins that reviewed the request's current head: a review
    /// or approval on `request.headSHA`, or timestamped evidence (a top-level
    /// comment, a reaction, a dated approval) created after both the head
    /// commit and `notBefore`. The commit date is authored locally, so a
    /// commit made before a reviewer's comment but pushed after it would
    /// otherwise count that stale comment; `notBefore` is when Alas first saw
    /// this head, a time the pusher can't backdate. With a nil `notBefore`
    /// timestamped evidence counts for nobody. Throws when the provider can't
    /// tell, so callers fail closed instead of reading an empty set as
    /// "nobody reviewed".
    func reviewersOnHead(remote: CodeHostRemote, request: ReviewRequest, notBefore: Date?, cwd: URL) async throws -> Set<String>
}

extension CodeHostProvider {
    public var capabilities: CodeHostProviderCapabilities { .readOnly }

    public func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String {
        throw CodeHostProviderError.unsupportedProvider(remote.kind)
    }

    public func reviewImageRevisions(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async throws -> CodeHostReviewImageRevisions {
        throw CodeHostProviderError.unsupportedProvider(remote.kind)
    }

    public func reviewFileData(
        remote: CodeHostRemote,
        repository: String,
        revision: String,
        path: String,
        cwd: URL
    ) async throws -> Data {
        throw CodeHostProviderError.unsupportedProvider(remote.kind)
    }

    public func reviewRequest(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> ReviewRequest {
        throw CodeHostProviderError.unsupportedProvider(remote.kind)
    }

    public func referenceSummary(
        remote: CodeHostRemote,
        reference: CodeHostReference,
        cwd: URL
    ) async throws -> CodeHostReferenceSummary {
        throw CodeHostProviderError.unsupportedProvider(remote.kind)
    }

    public func failedCheckEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] {
        ReviewEvidenceCIActivityMapper.items(for: request.checks)
    }

    public func checkEvidenceDetail(
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

    public func feedbackEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] {
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

    public func feedbackEvidenceDetail(
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

    public func replyToThread(
        remote: CodeHostRemote,
        request: ReviewRequest,
        thread: ReviewThread,
        body: String,
        cwd: URL
    ) async throws -> ReviewComment {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    public func resolveThread(
        remote: CodeHostRemote,
        request: ReviewRequest,
        thread: ReviewThread,
        cwd: URL
    ) async throws -> ReviewThread {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    public func unresolveThread(
        remote: CodeHostRemote,
        request: ReviewRequest,
        thread: ReviewThread,
        cwd: URL
    ) async throws -> ReviewThread {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    public func editComment(
        remote: CodeHostRemote,
        request: ReviewRequest,
        comment: ReviewComment,
        newBody: String,
        cwd: URL
    ) async throws -> ReviewComment {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    public func deleteComment(
        remote: CodeHostRemote,
        request: ReviewRequest,
        comment: ReviewComment,
        cwd: URL
    ) async throws {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    public func mergeReviewRequest(
        _ request: ReviewRequest,
        method: ReviewMergeMethod,
        deleteBranch: Bool,
        cwd: URL
    ) async throws {
        throw CodeHostProviderError.unsupportedProvider(request.remote.kind)
    }

    public func startReview(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async throws -> String {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    public func cancelReview(
        remote: CodeHostRemote,
        request: ReviewRequest,
        reviewID: String,
        cwd: URL
    ) async throws {}

    public func addReviewComment(
        remote: CodeHostRemote,
        request: ReviewRequest,
        reviewID: String,
        comment: StagedComment,
        cwd: URL
    ) async throws {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    public func submitReview(
        remote: CodeHostRemote,
        request: ReviewRequest,
        reviewID: String,
        verdict: ReviewVerdict,
        body: String,
        cwd: URL
    ) async throws {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    public func checkAnnotations(remote: CodeHostRemote, check: ReviewCheck, cwd: URL) async throws -> [CheckAnnotation] {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    public func publishReview(_ request: ProviderReviewPublishRequest) async throws -> ProviderReviewPublishResult {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    public func mutateReviewThread(_ mutation: ProviderThreadMutation) async throws -> ProviderThreadMutationResult {
        throw CodeHostProviderError.unsupportedProvider(kind)
    }

    // Throwing rather than returning `[]` is deliberate: an empty list is
    // indistinguishable from "nothing is merged", and the scanner must be able
    // to tell those apart so it can report `unknown`.
    public func mergedReviewRequests(
        remote: CodeHostRemote,
        headBranches: [String],
        cwd: URL
    ) async throws -> [MergedReviewRequestRef] {
        throw CodeHostProviderError.unsupportedProvider(remote.kind)
    }

    /// Unlike `mergedReviewRequests`, a provider that can't determine fork
    /// status degrades to "not a fork" rather than throwing: the caller
    /// falls back to the original remote either way, so failing loudly here
    /// would gain nothing and would risk failing the whole scan over what is
    /// only ever used as an enhancement to it.
    public func repositoryParent(remote: CodeHostRemote, cwd: URL) async throws -> CodeHostRemote? {
        nil
    }

    // Throwing for the same reason as `mergedReviewRequests`: an empty set
    // would read as "nobody reviewed" rather than "can't tell".
    public func reviewersOnHead(
        remote: CodeHostRemote,
        request: ReviewRequest,
        notBefore: Date?,
        cwd: URL
    ) async throws -> Set<String> {
        throw CodeHostProviderError.unsupportedProvider(remote.kind)
    }
}

public struct CodeHostProviderRegistry: Sendable {
    public let providers: [CodeHostKind: any CodeHostProvider]

    public var supportedKinds: Set<CodeHostKind> {
        Set(providers.keys)
    }

    public static func live() -> CodeHostProviderRegistry {
        CodeHostProviderRegistry(providers: [
            .github: GitHubCLIProvider(),
            .gitlab: GitLabCLIProvider(),
        ])
    }

    public func provider(for kind: CodeHostKind) -> (any CodeHostProvider)? {
        providers[kind]
    }

    public init(providers: [CodeHostKind: any CodeHostProvider]) {
        self.providers = providers
    }
}
