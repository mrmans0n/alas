import Foundation

struct GitHubCLIProvider: CodeHostProvider, CodeHostIssueProviding {
    let kind: CodeHostKind = .github
    let capabilities: CodeHostProviderCapabilities = .githubCLI
    let executable = "gh"
    static let pullRequestNodeQuery = """
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          id
        }
      }
    }
    """

    static let publishReviewMutation = """
    mutation($input: AddPullRequestReviewInput!) {
      addPullRequestReview(input: $input) {
        pullRequestReview {
          comments(first: 100) {
            nodes {
              id
              url
              pullRequestReviewThread {
                id
              }
            }
          }
        }
      }
    }
    """

    static let replyReviewThreadMutation = """
    mutation($input: AddPullRequestReviewThreadReplyInput!) {
      addPullRequestReviewThreadReply(input: $input) {
        comment {
          id
          url
        }
      }
    }
    """

    static let resolveReviewThreadMutation = """
    mutation($input: ResolveReviewThreadInput!) {
      resolveReviewThread(input: $input) {
        thread {
          id
          isResolved
        }
      }
    }
    """

    static let unresolveReviewThreadMutation = """
    mutation($input: UnresolveReviewThreadInput!) {
      unresolveReviewThread(input: $input) {
        thread {
          id
          isResolved
        }
      }
    }
    """

    static let reviewThreadsQuery = """
    query($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          reviewThreads(first: 50, after: $cursor) {
            nodes {
              id
              isResolved
              isOutdated
              path
              line
              startLine
              originalLine
              originalStartLine
              subjectType
              diffSide
              viewerCanResolve
              viewerCanUnresolve
              viewerCanReply
              comments(first: 50) {
                nodes {
                  id
                  body
                  url
                  createdAt
                  diffHunk
                  author {
                    login
                  }
                  viewerDidAuthor
                }
              }
            }
            pageInfo {
              hasNextPage
              endCursor
            }
          }
        }
      }
    }
    """

    static let mergeQueueMetadataQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          isMergeQueueEnabled
          isInMergeQueue
        }
      }
    }
    """

    static let addPullRequestReviewThreadReplyMutation = """
    mutation($threadId: ID!, $body: String!) {
      addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) {
        comment {
          id
          body
          url
          createdAt
          author {
            login
          }
          viewerDidAuthor
        }
      }
    }
    """

    static let resolvePullRequestReviewThreadMutation = """
    mutation($threadId: ID!) {
      resolveReviewThread(input: {threadId: $threadId}) {
        thread {
          id
          isResolved
          isOutdated
        }
      }
    }
    """

    static let unresolvePullRequestReviewThreadMutation = """
    mutation($threadId: ID!) {
      unresolveReviewThread(input: {threadId: $threadId}) {
        thread {
          id
          isResolved
          isOutdated
        }
      }
    }
    """

    static let updatePullRequestReviewCommentMutation = """
    mutation($commentId: ID!, $body: String!) {
      updatePullRequestReviewComment(input: {pullRequestReviewCommentId: $commentId, body: $body}) {
        pullRequestReviewComment {
          id
          body
          url
          createdAt
          author {
            login
          }
          viewerDidAuthor
        }
      }
    }
    """

    static let deletePullRequestReviewCommentMutation = """
    mutation($commentId: ID!) {
      deletePullRequestReviewComment(input: {id: $commentId}) {
        clientMutationId
      }
    }
    """

    static let deletePullRequestReviewMutation = """
    mutation($reviewId: ID!) {
      deletePullRequestReview(input: {pullRequestReviewId: $reviewId}) {
        clientMutationId
      }
    }
    """

    static let prNodeIDQuery = """
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          id
        }
      }
    }
    """

    static let addPullRequestReviewMutation = """
    mutation($prId: ID!, $commitOID: GitObjectID!) {
      addPullRequestReview(input: {pullRequestId: $prId, commitOID: $commitOID}) {
        pullRequestReview {
          id
        }
      }
    }
    """

    static let addPullRequestReviewCommentMutation = """
    mutation($prId: ID!, $reviewId: ID!, $path: String!, $line: Int!, $startLine: Int, $side: DiffSide!, $startSide: DiffSide, $body: String!) {
      addPullRequestReviewThread(input: {
        pullRequestId: $prId,
        pullRequestReviewId: $reviewId,
        path: $path,
        line: $line,
        startLine: $startLine,
        side: $side,
        startSide: $startSide,
        body: $body
      }) {
        thread {
          id
        }
      }
    }
    """

    static let submitPullRequestReviewMutation = """
    mutation($reviewId: ID!, $event: PullRequestReviewEvent!, $body: String!) {
      submitPullRequestReview(input: {
        pullRequestReviewId: $reviewId,
        event: $event,
        body: $body
      }) {
        pullRequestReview {
          id
        }
      }
    }
    """

    private let runner: any CodeHostCommandRunning

    init(runner: any CodeHostCommandRunning = ProcessCodeHostCommandRunner()) {
        self.runner = runner
    }

    func isAvailable(cwd: URL) async -> Bool {
        do {
            let result = try await runner.run("gh", args: ["--version"], cwd: cwd)
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool {
        do {
            let result = try await runner.run(
                "gh",
                args: ["auth", "status", "--hostname", remote.host],
                cwd: cwd
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    func issue(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> MissionIssueSnapshot {
        let result = try await runner.run(
            executable,
            args: ["api", "--hostname", remote.host, "repos/\(remote.repositorySlug)/issues/\(number)"],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            if let error = CodeHostIssueProviderError.classification(provider: kind, remote: remote, number: number, result: result) {
                throw error
            }
            throw CodeHostProviderError.commandFailed(command: "gh api issue", stderr: result.stderr)
        }
        return try Self.parseIssue(result.stdout, remote: remote, requestedNumber: number)
    }

    func currentReviewRequest(
        remote: CodeHostRemote,
        branch: String,
        headOwner: String?,
        baseBranch: String,
        cwd: URL
    ) async throws -> ReviewRequest? {
        try await reviewRequest(
            remote: remote,
            branch: branch,
            headOwner: headOwner,
            baseBranch: baseBranch,
            state: "open",
            cwd: cwd
        )
    }

    func missionReviewRequest(
        remote: CodeHostRemote,
        branch: String,
        headOwner: String?,
        baseBranch: String,
        headSHA: String? = nil,
        cwd: URL
    ) async throws -> ReviewRequest? {
        try await reviewRequest(
            remote: remote,
            branch: branch,
            headOwner: headOwner,
            baseBranch: baseBranch,
            headSHA: headSHA,
            state: "all",
            cwd: cwd
        )
    }

    private func reviewRequest(
        remote: CodeHostRemote,
        branch: String,
        headOwner: String?,
        baseBranch: String,
        headSHA: String? = nil,
        state: String,
        cwd: URL
    ) async throws -> ReviewRequest? {
        let base = Self.normalizedBaseBranch(baseBranch, remoteName: remote.remoteName)
        let result = try await runner.run(
            "gh",
            args: [
                "pr", "list",
                "--head", branch,
                "--base", base,
                "--state", state,
                "--limit", "20",
                "--json", "number,title,url,state,isDraft,headRefName,headRefOid,headRepositoryOwner,headRepository,baseRefName,baseRefOid,reviewDecision,mergeStateStatus",
                "-R", Self.highLevelRepositorySelector(remote: remote),
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh pr list", stderr: result.stderr)
        }

        guard let request = try Self.parsePRList(
            result.stdout,
            remote: remote,
            headOwner: headOwner,
            headSHA: headSHA,
            preferMerged: state == "all"
        ) else {
            return nil
        }
        let queueMetadata = await mergeQueueMetadata(remote: remote, number: request.number, cwd: cwd)
        let enrichedRequest = request.withMergeQueue(
            isEnabled: queueMetadata.isMergeQueueEnabled,
            isInQueue: queueMetadata.isInMergeQueue
        )
        let loadedThreads = await threadsWithCompleteness(remote: remote, request: enrichedRequest, cwd: cwd)
        return enrichedRequest.withThreads(loadedThreads.threads, complete: loadedThreads.complete)
    }

    /// Loads review threads, reporting whether the fetch succeeded. A failure
    /// yields no threads but flags the result incomplete so the merge gate can
    /// fail closed instead of treating missing threads as "no feedback".
    private func threadsWithCompleteness(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async -> (threads: [ReviewThread], complete: Bool) {
        do {
            return (try await reviewThreads(remote: remote, request: request, cwd: cwd), true)
        } catch {
            return ([], false)
        }
    }

    private func mergeQueueMetadata(remote: CodeHostRemote, number: Int, cwd: URL) async -> PullRequestQueueMetadata {
        do {
            let result = try await runner.run(
                "gh",
                args: [
                    "api", "graphql",
                    "--hostname", remote.host,
                    "-f", "owner=\(remote.owner)",
                    "-f", "name=\(remote.repository)",
                    "-F", "number=\(number)",
                    "-f", "query=\(Self.mergeQueueMetadataQuery)",
                ],
                cwd: cwd
            )
            guard result.exitCode == 0 else { return .unavailable }
            let response = try JSONDecoder().decode(
                GitHubQueueMetadataResponse.self,
                from: Data(result.stdout.utf8)
            )
            return PullRequestQueueMetadata(
                isMergeQueueEnabled: response.data.repository.pullRequest.isMergeQueueEnabled,
                isInMergeQueue: response.data.repository.pullRequest.isInMergeQueue
            )
        } catch {
            return .unavailable
        }
    }

    func reviewRequest(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> ReviewRequest {
        try await refreshedReviewRequest(remote: remote, request: ReviewRequest.placeholder(remote: remote, number: number), cwd: cwd)
    }

    func createReviewRequest(
        remote: CodeHostRemote,
        branch: String,
        headOwner: String?,
        baseBranch: String,
        title: String,
        body: String,
        isDraft: Bool,
        cwd: URL
    ) async throws -> URL {
        let head = Self.qualifiedHead(branch: branch, headOwner: headOwner, baseOwner: remote.owner)
        let base = Self.normalizedBaseBranch(baseBranch, remoteName: remote.remoteName)
        var args = [
            "pr", "create",
            "--base", base,
            "--head", head,
            "--title", title,
            "--body", body,
            "-R", Self.highLevelRepositorySelector(remote: remote),
        ]
        if isDraft {
            args.append("--draft")
        }

        let result = try await runner.run("gh", args: args, cwd: cwd)
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh pr create", stderr: result.stderr)
        }

        return try Self.parseCreateOutput(result.stdout)
    }

    static func qualifiedHead(branch: String, headOwner: String?, baseOwner: String) -> String {
        guard let headOwner,
              !headOwner.isEmpty,
              headOwner != baseOwner
        else { return branch }
        return "\(headOwner):\(branch)"
    }

    static func normalizedBaseBranch(_ baseBranch: String, remoteName: String) -> String {
        let prefix = "\(remoteName)/"
        guard baseBranch.hasPrefix(prefix) else { return baseBranch }
        return String(baseBranch.dropFirst(prefix.count))
    }

    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] {
        let result = try await runner.run(
            "gh",
            args: [
                "pr", "checks", "\(request.number)",
                "--json", "bucket,completedAt,description,event,link,name,startedAt,state,workflow",
                "-R", Self.highLevelRepositorySelector(remote: remote),
            ],
            cwd: cwd
        )
        if result.exitCode == 1, Self.isNoChecksReported(result) {
            return []
        }
        guard result.exitCode == 0 || result.exitCode == 1 || result.exitCode == 8 else {
            throw CodeHostProviderError.commandFailed(command: "gh pr checks", stderr: result.stderr)
        }

        return try Self.parseChecks(result.stdout)
    }

    func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String {
        let result = try await runner.run(
            "gh",
            args: ["pr", "diff", "\(request.number)", "-R", Self.highLevelRepositorySelector(remote: remote)],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh pr diff", stderr: result.stderr)
        }
        return result.stdout
    }

    func reviewImageRevisions(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async throws -> CodeHostReviewImageRevisions {
        guard let baseSHA = Self.normalizedOptionalString(request.baseSHA),
              let headSHA = Self.normalizedOptionalString(request.headSHA)
        else {
            throw CodeHostProviderError.malformedOutput("GitHub image revisions require base and head SHAs.")
        }

        let result = try await runner.run(
            "gh",
            args: [
                "api",
                "--hostname", remote.host,
                "repos/\(remote.repositorySlug)/compare/\(baseSHA)...\(headSHA)",
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api compare", stderr: result.stderr)
        }

        let response: GitHubCompareResponse
        do {
            response = try JSONDecoder().decode(GitHubCompareResponse.self, from: Data(result.stdout.utf8))
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh api compare output")
        }
        guard let mergeBaseSHA = Self.normalizedOptionalString(response.mergeBaseCommit.sha) else {
            throw CodeHostProviderError.malformedOutput("gh api compare output is missing merge base SHA")
        }
        return CodeHostReviewImageRevisions(beforeSHA: mergeBaseSHA, afterSHA: headSHA)
    }

    func reviewFileData(
        remote: CodeHostRemote,
        repository: String,
        revision: String,
        path: String,
        cwd: URL
    ) async throws -> Data {
        let result = try await runner.runData(
            "gh",
            args: [
                "api",
                "--hostname", remote.host,
                "--method", "GET",
                "--header", "Accept: application/vnd.github.raw+json",
                "repos/\(repository)/contents/\(Self.encodedFilePath(path))?ref=\(revision)",
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api contents", stderr: result.stderr)
        }

        return result.stdout
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
        _ = request
        guard item.status == .failed else {
            return ReviewEvidenceDetail(
                item: item,
                body: "Open this check in GitHub to inspect current status.",
                filePath: nil,
                line: nil,
                isTruncated: false
            )
        }
        guard let runID = Self.githubRunID(from: item.providerURL) else {
            return ReviewEvidenceDetail(
                item: item,
                body: "Open this check in GitHub to inspect full logs.",
                filePath: nil,
                line: nil,
                isTruncated: false
            )
        }

        var args = ["run", "view", runID, "--log-failed", "-R", Self.highLevelRepositorySelector(remote: remote)]
        if let jobID = Self.githubJobID(from: item.providerURL) {
            args.append(contentsOf: ["--job", jobID])
        }

        let result = try await runner.run(
            "gh",
            args: args,
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh run view", stderr: result.stderr)
        }

        return ReviewEvidenceDetail.truncated(item: item, body: result.stdout, filePath: nil, line: nil)
    }

    func feedbackEvidenceDetail(
        remote: CodeHostRemote,
        request: ReviewRequest,
        item: ReviewEvidenceItem,
        cwd: URL
    ) async throws -> ReviewEvidenceDetail {
        _ = remote
        _ = cwd
        if item.id == ReviewEvidenceFallbacks.changesRequestedID {
            return ReviewEvidenceFallbacks.changesRequestedDetail(item: item, request: request)
        }
        let thread = request.threads.first { $0.id == item.id }
        return ReviewEvidenceDetail(
            item: item,
            body: thread?.body ?? "Open this thread in GitHub to inspect full context.",
            filePath: nil,
            line: nil,
            isTruncated: false
        )
    }

    private func reviewThreads(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async throws -> [ReviewThread] {
        var threads: [ReviewThread] = []
        var cursor: String?

        repeat {
            let page = try await reviewThreadsPage(remote: remote, request: request, cursor: cursor, cwd: cwd)
            threads.append(contentsOf: page.threads)
            if page.pageInfo.hasNextPage {
                guard let endCursor = page.pageInfo.endCursor, !endCursor.isEmpty else {
                    throw CodeHostProviderError.malformedOutput("gh review threads output is missing a pagination cursor")
                }
                cursor = endCursor
            } else {
                cursor = nil
            }
        } while cursor != nil

        return threads
    }

    private func reviewThreadsPage(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cursor: String?,
        cwd: URL
    ) async throws -> ReviewThreadsPage {
        var args = [
            "api", "graphql",
            "--hostname", remote.host,
            "-f", "query=\(Self.reviewThreadsQuery)",
            "-F", "owner=\(remote.owner)",
            "-F", "repo=\(remote.repository)",
            "-F", "number=\(request.number)",
        ]
        if let cursor {
            args.append(contentsOf: ["-F", "cursor=\(cursor)"])
        }

        let result = try await runner.run(
            "gh",
            args: args,
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
        }

        return try Self.parseReviewThreadsPage(result.stdout)
    }

    private func fetchPRNodeID(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async throws -> String {
        let result = try await runner.run(
            "gh",
            args: [
                "api", "graphql",
                "--hostname", remote.host,
                "-f", "query=\(Self.prNodeIDQuery)",
                "-F", "owner=\(remote.owner)",
                "-F", "repo=\(remote.repository)",
                "-F", "number=\(request.number)",
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
        }
        return try Self.parsePRNodeIDResponse(result.stdout)
    }

    func publishReview(_ request: ProviderReviewPublishRequest) async throws -> ProviderReviewPublishResult {
        let publishableComments = request.comments.filter { $0.side != .unknown }
        let preflightFailures = request.comments
            .filter { $0.side == .unknown }
            .map {
                ProviderReviewFailedComment(
                    localDraftID: $0.localDraftID,
                    message: "GitHub review comments require an old or new side."
                )
            }
        guard !publishableComments.isEmpty || request.comments.isEmpty else {
            return ProviderReviewPublishResult(
                published: [],
                failed: preflightFailures,
                refreshedRequest: request.reviewRequest,
                warnings: Self.skippedDecisionWarnings(decision: request.decision, provider: "GitHub")
            )
        }
        let pullRequestID = try await pullRequestNodeID(
            remote: request.remote,
            request: request.reviewRequest,
            cwd: request.cwd
        )
        let published = try await publishReviewWithFallback(
            pullRequestID: pullRequestID,
            request: request,
            publishableComments: publishableComments
        )
        var warnings = published.warnings
        let refreshedRequest: ReviewRequest
        do {
            refreshedRequest = try await refreshedReviewRequest(
                remote: request.remote,
                request: request.reviewRequest,
                cwd: request.cwd
            )
        } catch {
            refreshedRequest = request.reviewRequest
            warnings.append("GitHub review was published, but Alas could not refresh the PR: \(error.localizedDescription)")
        }
        return ProviderReviewPublishResult(
            published: published.published,
            failed: preflightFailures + published.failed,
            refreshedRequest: refreshedRequest,
            warnings: warnings
        )
    }

    private func publishReviewWithFallback(
        pullRequestID: String,
        request: ProviderReviewPublishRequest,
        publishableComments: [ProviderReviewDraftComment]
    ) async throws -> (published: [ProviderReviewPublishedComment], failed: [ProviderReviewFailedComment], warnings: [String]) {
        do {
            let published = try await submitReviewWithComments(
                remote: request.remote,
                pullRequestID: pullRequestID,
                commitOID: request.reviewRequest.headSHA,
                comments: publishableComments,
                decision: request.decision,
                summaryBody: request.summaryBody,
                cwd: request.cwd
            )
            return (published.published, published.failed, published.warnings)
        } catch {
            guard !publishableComments.isEmpty else {
                throw error
            }
            guard Self.shouldRetryPublishIndividually(after: error), publishableComments.count > 1 else {
                return (
                    [],
                    publishableComments.map {
                        ProviderReviewFailedComment(localDraftID: $0.localDraftID, message: error.localizedDescription)
                    },
                    Self.skippedDecisionWarnings(decision: request.decision, provider: "GitHub")
                )
            }
            var published: [ProviderReviewPublishedComment] = []
            var failed: [ProviderReviewFailedComment] = []
            var warnings: [String] = []
            for comment in publishableComments {
                do {
                    let result = try await submitReviewWithComments(
                        remote: request.remote,
                        pullRequestID: pullRequestID,
                        commitOID: request.reviewRequest.headSHA,
                        comments: [comment],
                        decision: .comment,
                        summaryBody: "",
                        cwd: request.cwd
                    )
                    published.append(contentsOf: result.published)
                    failed.append(contentsOf: result.failed)
                    warnings.append(contentsOf: result.warnings)
                } catch {
                    failed.append(ProviderReviewFailedComment(localDraftID: comment.localDraftID, message: error.localizedDescription))
                }
            }
            return (
                published,
                failed,
                warnings + [
                    "GitHub rejected the batch review; Alas retried publishable comments individually without submitting the review decision.",
                ]
            )
        }
    }

    private static func shouldRetryPublishIndividually(after error: Error) -> Bool {
        guard case CodeHostProviderError.commandFailed = error else {
            return false
        }
        return true
    }

    private static func skippedDecisionWarnings(decision: ProviderReviewDecision, provider: String) -> [String] {
        switch decision {
        case .comment:
            []
        case .approve:
            ["\(provider) approval review was not submitted because review comments failed to publish."]
        case .requestChanges:
            ["\(provider) request changes review was not submitted because review comments failed to publish."]
        }
    }

    private func submitReviewWithComments(
        remote: CodeHostRemote,
        pullRequestID: String,
        commitOID: String?,
        comments: [ProviderReviewDraftComment],
        decision: ProviderReviewDecision,
        summaryBody: String,
        cwd: URL
    ) async throws -> (
        published: [ProviderReviewPublishedComment],
        failed: [ProviderReviewFailedComment],
        warnings: [String]
    ) {
        let input = PublishReviewInput(
            pullRequestId: pullRequestID,
            commitOID: Self.normalizedOptionalString(commitOID),
            event: Self.githubReviewEvent(for: decision),
            body: summaryBody,
            threads: comments.map(Self.githubReviewThreadPayload(for:))
        )
        let stdin = try Self.graphQLInput(
            query: Self.publishReviewMutation,
            variables: PublishReviewVariables(input: input)
        )
        let result = try await runner.run(
            "gh",
            args: Self.graphQLAPIStdinArgs(remote: remote),
            cwd: cwd,
            stdin: stdin
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
        }
        return try Self.parsePublishReviewResult(result.stdout, drafts: comments)
    }

    private func refreshedReviewRequest(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> ReviewRequest {
        let result = try await runner.run(
            "gh",
            args: [
                "pr", "view", "\(request.number)",
                "--json", "number,title,url,state,isDraft,headRefName,headRefOid,headRepositoryOwner,headRepository,baseRefName,baseRefOid,reviewDecision,mergeStateStatus",
                "-R", Self.highLevelRepositorySelector(remote: remote),
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh pr view", stderr: result.stderr)
        }
        let request = try Self.parsePRView(result.stdout, remote: remote)
        let queueMetadata = await mergeQueueMetadata(remote: remote, number: request.number, cwd: cwd)
        let enrichedRequest = request.withMergeQueue(
            isEnabled: queueMetadata.isMergeQueueEnabled,
            isInQueue: queueMetadata.isInMergeQueue
        )
        let loadedThreads = await threadsWithCompleteness(remote: remote, request: enrichedRequest, cwd: cwd)
        return enrichedRequest.withThreads(loadedThreads.threads, complete: loadedThreads.complete)
    }

    func mutateReviewThread(_ mutation: ProviderThreadMutation) async throws -> ProviderThreadMutationResult {
        guard let threadID = Self.normalizedOptionalString(mutation.thread.providerThreadID) else {
            throw CodeHostProviderError.malformedOutput("GitHub review thread mutation is missing a provider thread ID")
        }
        let providerURL: URL?
        switch mutation.kind {
        case .reply:
            guard let body = Self.normalizedOptionalString(mutation.bodyMarkdown) else {
                throw CodeHostProviderError.malformedOutput("GitHub review thread reply requires a non-empty body")
            }
            let stdin = try Self.graphQLInput(
                query: Self.replyReviewThreadMutation,
                variables: ThreadReplyVariables(input: ThreadReplyInput(
                    pullRequestReviewThreadId: threadID,
                    body: body
                ))
            )
            let result = try await runner.run(
                "gh",
                args: Self.graphQLAPIStdinArgs(remote: mutation.remote),
                cwd: mutation.cwd,
                stdin: stdin
            )
            guard result.exitCode == 0 else {
                throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
            }
            providerURL = try Self.parseThreadReplyResult(result.stdout)
        case .resolve:
            let stdin = try Self.graphQLInput(
                query: Self.resolveReviewThreadMutation,
                variables: ThreadStateVariables(input: ThreadStateInput(threadId: threadID))
            )
            let result = try await runner.run(
                "gh",
                args: Self.graphQLAPIStdinArgs(remote: mutation.remote),
                cwd: mutation.cwd,
                stdin: stdin
            )
            guard result.exitCode == 0 else {
                throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
            }
            try Self.parseThreadStateResult(result.stdout, mutationName: "resolveReviewThread")
            providerURL = nil
        case .unresolve:
            let stdin = try Self.graphQLInput(
                query: Self.unresolveReviewThreadMutation,
                variables: ThreadStateVariables(input: ThreadStateInput(threadId: threadID))
            )
            let result = try await runner.run(
                "gh",
                args: Self.graphQLAPIStdinArgs(remote: mutation.remote),
                cwd: mutation.cwd,
                stdin: stdin
            )
            guard result.exitCode == 0 else {
                throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
            }
            try Self.parseThreadStateResult(result.stdout, mutationName: "unresolveReviewThread")
            providerURL = nil
        }
        let refreshedRequest: ReviewRequest
        let warnings: [String]
        do {
            refreshedRequest = try await refreshedReviewRequest(
                remote: mutation.remote,
                request: mutation.reviewRequest,
                cwd: mutation.cwd
            )
            warnings = []
        } catch {
            refreshedRequest = mutation.reviewRequest
            warnings = ["GitHub thread was updated, but Alas could not refresh the PR: \(error.localizedDescription)"]
        }
        return ProviderThreadMutationResult(
            refreshedRequest: refreshedRequest,
            providerURL: providerURL,
            warnings: warnings
        )
    }

    private static func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func rerunFailedChecks(
        remote: CodeHostRemote,
        branch: String,
        headSHA: String,
        request: ReviewRequest?,
        cwd: URL
    ) async throws {
        _ = request
        let listResult = try await runner.run(
            "gh",
            args: [
                "run", "list",
                "--branch", branch,
                "--commit", headSHA,
                "--status", "failure",
                "--limit", "20",
                "--json", "databaseId,status,conclusion,url",
                "-R", Self.highLevelRepositorySelector(remote: remote),
            ],
            cwd: cwd
        )
        guard listResult.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh run list", stderr: listResult.stderr)
        }

        for runID in try Self.parseRunIDs(listResult.stdout) {
            let rerunResult = try await runner.run(
                "gh",
                args: ["run", "rerun", "\(runID)", "--failed", "-R", Self.highLevelRepositorySelector(remote: remote)],
                cwd: cwd
            )
            guard rerunResult.exitCode == 0 else {
                throw CodeHostProviderError.commandFailed(command: "gh run rerun", stderr: rerunResult.stderr)
            }
        }
    }

    func mergeReviewRequest(
        _ request: ReviewRequest,
        method: ReviewMergeMethod,
        deleteBranch: Bool,
        cwd: URL
    ) async throws {
        var args = ["pr", "merge", "\(request.number)"]
        if !request.isMergeQueueEnabled {
            switch method {
            case .squash: args.append("--squash")
            case .merge: args.append("--merge")
            case .rebase: args.append("--rebase")
            }
        }
        // Pin the merge to the reviewed head so a push that lands between the
        // snapshot load and the confirmation can't merge an unreviewed commit.
        if let headSHA = request.headSHA {
            args.append(contentsOf: ["--match-head-commit", headSHA])
        }
        args.append(contentsOf: ["-R", Self.highLevelRepositorySelector(remote: request.remote)])

        let result = try await runner.run("gh", args: args, cwd: cwd)
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh pr merge", stderr: result.stderr)
        }

        // Delete the remote branch only. `gh pr merge --delete-branch` also
        // deletes the *local* branch, which fails in Alas' linked-worktree
        // workflow when that branch is checked out — surfacing a false merge
        // failure even though the PR already merged. Best-effort: the merge
        // has succeeded, so ignore cleanup errors (e.g. a repo configured to
        // auto-delete head branches will already have removed the ref).
        //
        // Only delete when the head lives in the base repo. For forked PRs the
        // head branch is in a different repo (`headRepositoryOwner != remote.owner`);
        // the DELETE ref endpoint is scoped by `{owner}/{repo}`, so targeting
        // the base repo there would either miss the fork branch or delete an
        // unrelated same-named base-repo branch. Both owner AND name must match
        // — a same-owner fork (e.g. `owner/repo-fork`) shares the owner but not
        // the repository. Leave fork branches alone.
        //
        // A zero exit does not guarantee the PR merged: with a required merge
        // queue, `gh pr merge` enqueues the PR (still open) and the queue needs
        // the head branch to complete. Confirm the PR is actually merged before
        // deleting; for a queued PR, leave cleanup to the queue / auto-delete.
        if deleteBranch,
           let headOwner = request.headRepositoryOwner,
           let headName = request.headRepositoryName,
           headOwner == request.remote.owner,
           headName == request.remote.repository,
           await isReviewRequestMerged(request, cwd: cwd) {
            _ = try? await runner.run(
                "gh",
                args: [
                    "api",
                    "--hostname", request.remote.host,
                    "--method", "DELETE",
                    "repos/\(request.remote.repositorySlug)/git/refs/heads/\(request.headRefName)",
                ],
                cwd: cwd
            )
        }
    }

    private func isReviewRequestMerged(_ request: ReviewRequest, cwd: URL) async -> Bool {
        guard let result = try? await runner.run(
            "gh",
            args: [
                "pr", "view", "\(request.number)",
                "--json", "state",
                "-R", Self.highLevelRepositorySelector(remote: request.remote),
            ],
            cwd: cwd
        ), result.exitCode == 0 else {
            return false
        }
        struct PRStateOnly: Decodable { let state: String }
        guard let decoded = try? JSONDecoder().decode(PRStateOnly.self, from: Data(result.stdout.utf8)) else {
            return false
        }
        return Self.mapState(decoded.state) == .merged
    }

    func replyToThread(
        remote: CodeHostRemote,
        request: ReviewRequest,
        thread: ReviewThread,
        body: String,
        cwd: URL
    ) async throws -> ReviewComment {
        _ = request
        let stdin = try Self.graphQLInput(
            query: Self.addPullRequestReviewThreadReplyMutation,
            variables: [
                "threadId": thread.id,
                "body": body,
            ]
        )
        let result = try await runner.run(
            "gh",
            args: [
                "api", "graphql",
                "--hostname", remote.host,
                "--input", "-",
            ],
            cwd: cwd,
            stdin: stdin
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
        }

        return try Self.parseAddThreadReplyResponse(result.stdout)
    }

    func resolveThread(
        remote: CodeHostRemote,
        request: ReviewRequest,
        thread: ReviewThread,
        cwd: URL
    ) async throws -> ReviewThread {
        _ = request
        let result = try await runner.run(
            "gh",
            args: [
                "api", "graphql",
                "--hostname", remote.host,
                "-f", "query=\(Self.resolvePullRequestReviewThreadMutation)",
                "-F", "threadId=\(thread.id)",
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
        }

        return try Self.parseResolveThreadResponse(result.stdout, from: thread)
    }

    func unresolveThread(
        remote: CodeHostRemote,
        request: ReviewRequest,
        thread: ReviewThread,
        cwd: URL
    ) async throws -> ReviewThread {
        _ = request
        let result = try await runner.run(
            "gh",
            args: [
                "api", "graphql",
                "--hostname", remote.host,
                "-f", "query=\(Self.unresolvePullRequestReviewThreadMutation)",
                "-F", "threadId=\(thread.id)",
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
        }

        return try Self.parseUnresolveThreadResponse(result.stdout, from: thread)
    }

    func editComment(
        remote: CodeHostRemote,
        request: ReviewRequest,
        comment: ReviewComment,
        newBody: String,
        cwd: URL
    ) async throws -> ReviewComment {
        _ = request
        let result = try await runner.run(
            "gh",
            args: [
                "api", "graphql",
                "--hostname", remote.host,
                "-f", "query=\(Self.updatePullRequestReviewCommentMutation)",
                "-f", "commentId=\(comment.id)",
                "-f", "body=\(newBody)",
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
        }

        return try Self.parseUpdateCommentResponse(result.stdout)
    }

    func deleteComment(
        remote: CodeHostRemote,
        request: ReviewRequest,
        comment: ReviewComment,
        cwd: URL
    ) async throws {
        _ = request
        let result = try await runner.run(
            "gh",
            args: [
                "api", "graphql",
                "--hostname", remote.host,
                "-f", "query=\(Self.deletePullRequestReviewCommentMutation)",
                "-F", "commentId=\(comment.id)",
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
        }
    }

    func startReview(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async throws -> String {
        guard let headSHA = request.headSHA else {
            throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: "headSHA unavailable")
        }
        let prNodeID = try await fetchPRNodeID(remote: remote, request: request, cwd: cwd)
        let result = try await runner.run(
            "gh",
            args: [
                "api", "graphql",
                "--hostname", remote.host,
                "-f", "query=\(Self.addPullRequestReviewMutation)",
                "-F", "prId=\(prNodeID)",
                "-f", "commitOID=\(headSHA)",
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
        }
        return try Self.parseStartReviewResponse(result.stdout)
    }

    func addReviewComment(
        remote: CodeHostRemote,
        request: ReviewRequest,
        reviewID: String,
        comment: StagedComment,
        cwd: URL
    ) async throws {
        guard let line = comment.line else { return }
        let prNodeID = try await fetchPRNodeID(remote: remote, request: request, cwd: cwd)
        let body: String
        if let suggestion = comment.suggestion {
            body = "```suggestion\n\(suggestion)\n```"
        } else {
            body = comment.body
        }
        let side = comment.side == .old ? "LEFT" : "RIGHT"
        // GitHub: line = ending line of selection; startLine = starting line for multi-line ranges.
        let endingLine = comment.endLine ?? line
        var args: [String] = [
            "api", "graphql",
            "--hostname", remote.host,
            "-f", "query=\(Self.addPullRequestReviewCommentMutation)",
            "-f", "prId=\(prNodeID)",
            "-f", "reviewId=\(reviewID)",
            "-f", "path=\(comment.filePath)",
            "-F", "line=\(endingLine)",
            "-f", "side=\(side)",
            "-f", "body=\(body)",
        ]
        if comment.endLine != nil {
            args += ["-F", "startLine=\(line)", "-f", "startSide=\(side)"]
        }
        let result = try await runner.run("gh", args: args, cwd: cwd)
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
        }
    }

    func cancelReview(
        remote: CodeHostRemote,
        request: ReviewRequest,
        reviewID: String,
        cwd: URL
    ) async throws {
        _ = request
        let result = try await runner.run(
            "gh",
            args: [
                "api", "graphql",
                "--hostname", remote.host,
                "-f", "query=\(Self.deletePullRequestReviewMutation)",
                "-F", "reviewId=\(reviewID)",
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
        }
    }

    func checkAnnotations(remote: CodeHostRemote, check: ReviewCheck, cwd: URL) async throws -> [CheckAnnotation] {
        let result = try await runner.run(
            "gh",
            args: [
                "api",
                "--hostname", remote.host,
                "/repos/\(remote.owner)/\(remote.repository)/check-runs/\(check.id)/annotations",
                "--paginate",
                "--slurp",
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api check-runs annotations", stderr: result.stderr)
        }
        return try Self.parseCheckAnnotations(result.stdout, check: check)
    }

    func submitReview(
        remote: CodeHostRemote,
        request: ReviewRequest,
        reviewID: String,
        verdict: ReviewVerdict,
        body: String,
        cwd: URL
    ) async throws {
        _ = request
        let event: String
        switch verdict {
        case .approve: event = "APPROVE"
        case .requestChanges: event = "REQUEST_CHANGES"
        case .comment: event = "COMMENT"
        }
        let result = try await runner.run(
            "gh",
            args: [
                "api", "graphql",
                "--hostname", remote.host,
                "-f", "query=\(Self.submitPullRequestReviewMutation)",
                "-F", "reviewId=\(reviewID)",
                "-f", "event=\(event)",
                "-f", "body=\(body)",
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
        }
    }

    static func parseCheckAnnotations(_ json: String, check: ReviewCheck) throws -> [CheckAnnotation] {
        let data = Data(json.utf8)
        // --paginate --slurp wraps pages into a JSON array of arrays: [[item, ...], [item, ...]]
        let items: [GitHubAnnotationResponse]
        do {
            let pages = try JSONDecoder().decode([[GitHubAnnotationResponse]].self, from: data)
            items = pages.flatMap { $0 }
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh check-run annotations output")
        }

        return items.compactMap { item in
            guard let level = CheckAnnotation.AnnotationLevel(rawValue: item.annotation_level.lowercased()) else {
                return nil
            }
            return CheckAnnotation(
                checkRunID: check.id,
                checkName: check.name,
                path: item.path,
                startLine: item.start_line,
                endLine: item.end_line,
                level: level,
                message: item.message,
                rawDetails: item.raw_details
            )
        }
    }

    static func parsePRList(
        _ json: String,
        remote: CodeHostRemote,
        headOwner: String? = nil,
        headSHA: String? = nil,
        preferMerged: Bool = false
    ) throws -> ReviewRequest? {
        let data = Data(json.utf8)
        let items: [PRListItem]
        do {
            items = try JSONDecoder().decode([PRListItem].self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh pr list output")
        }

        let normalizedHeadSHA = normalizedOptionalString(headSHA)
        let matchingItems = items.filter { item in
            let ownerMatches = headOwner?.isEmpty != false
                || item.headRepositoryOwner?.login.caseInsensitiveCompare(headOwner ?? "") == .orderedSame
            let shaMatches = normalizedHeadSHA == nil
                || normalizedOptionalString(item.headRefOid) == normalizedHeadSHA
            return ownerMatches && shaMatches
        }
        let item = preferMerged
            ? matchingItems.first(where: { $0.state.caseInsensitiveCompare("merged") == .orderedSame })
                ?? matchingItems.first
            : matchingItems.first
        guard let item else {
            return nil
        }
        guard let url = URL(string: item.url), url.isHTTPOrHTTPS else {
            throw CodeHostProviderError.malformedOutput("gh pr list returned an invalid URL")
        }

        return ReviewRequest(
            remote: remote,
            number: item.number,
            title: item.title,
            url: url,
            state: mapState(item.state),
            isDraft: item.isDraft,
            headRefName: item.headRefName,
            baseRefName: item.baseRefName,
            baseSHA: normalizedOptionalString(item.baseRefOid),
            headSHA: normalizedOptionalString(item.headRefOid),
            headRepositoryOwner: item.headRepositoryOwner?.login,
            headRepositoryName: item.headRepository?.name,
            reviewDecision: mapReviewDecision(item.reviewDecision),
            mergeState: mapMergeState(item.mergeStateStatus),
            checks: [],
            threads: []
        )
    }

    static func parsePRView(_ json: String, remote: CodeHostRemote) throws -> ReviewRequest {
        let data = Data(json.utf8)
        let item: PRListItem
        do {
            item = try JSONDecoder().decode(PRListItem.self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh pr view output")
        }

        guard let request = try reviewRequest(from: item, remote: remote) else {
            throw CodeHostProviderError.malformedOutput("gh pr view returned an invalid PR")
        }
        return request
    }

    private static func reviewRequest(from item: PRListItem, remote: CodeHostRemote) throws -> ReviewRequest? {
        guard let url = URL(string: item.url), url.isHTTPOrHTTPS else {
            throw CodeHostProviderError.malformedOutput("gh pr list returned an invalid URL")
        }

        return ReviewRequest(
            remote: remote,
            number: item.number,
            title: item.title,
            url: url,
            state: mapState(item.state),
            isDraft: item.isDraft,
            headRefName: item.headRefName,
            baseRefName: item.baseRefName,
            baseSHA: normalizedOptionalString(item.baseRefOid),
            headSHA: normalizedOptionalString(item.headRefOid),
            headRepositoryOwner: item.headRepositoryOwner?.login,
            headRepositoryName: item.headRepository?.name,
            reviewDecision: mapReviewDecision(item.reviewDecision),
            mergeState: mapMergeState(item.mergeStateStatus),
            checks: [],
            threads: []
        )
    }

    static func parseChecks(_ json: String) throws -> [ReviewCheck] {
        let data = Data(json.utf8)
        let items: [CheckItem]
        do {
            items = try JSONDecoder().decode([CheckItem].self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh pr checks output")
        }

        return try items.map { item in
            let detailURL = item.link.flatMap(URL.init(string:))
            if let detailURL, !detailURL.isHTTPOrHTTPS {
                throw CodeHostProviderError.malformedOutput("gh pr checks returned an invalid URL")
            }

            let completedAt = try parseOptionalDate(item.completedAt)
            _ = try parseOptionalDate(item.startedAt)

            return ReviewCheck(
                id: checkID(for: item),
                name: item.name,
                workflow: item.workflow,
                bucket: mapBucket(item.bucket),
                detailURL: detailURL,
                completedAt: completedAt
            )
        }
    }

    static func parseCreateOutput(_ stdout: String) throws -> URL {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.isHTTPOrHTTPS else {
            throw CodeHostProviderError.malformedOutput("gh pr create returned an invalid URL")
        }
        return url
    }

    static func parseReviewThreads(_ json: String) throws -> [ReviewThread] {
        try parseReviewThreadsPage(json).threads
    }

    static func parsePullRequestNodeID(_ json: String) throws -> String {
        let data = Data(json.utf8)
        do {
            let response = try JSONDecoder().decode(PullRequestNodeResponse.self, from: data)
            let id = response.data.repository.pullRequest.id
            guard !id.isEmpty else {
                throw CodeHostProviderError.malformedOutput("gh pull request node output is missing a pull request ID")
            }
            return id
        } catch let error as CodeHostProviderError {
            throw error
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh pull request node output")
        }
    }

    static func parsePublishReviewResult(
        _ json: String,
        drafts: [ProviderReviewDraftComment]
    ) throws -> (
        published: [ProviderReviewPublishedComment],
        failed: [ProviderReviewFailedComment],
        warnings: [String]
    ) {
        let data = Data(json.utf8)
        let response: PublishReviewResponse
        do {
            response = try JSONDecoder().decode(PublishReviewResponse.self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh publish review output")
        }

        let comments = response.data.addPullRequestReview.pullRequestReview.comments.nodes
        var published = zip(drafts, comments).map { draft, comment in
            ProviderReviewPublishedComment(
                localDraftID: draft.localDraftID,
                providerThreadID: normalizedOptionalString(comment.pullRequestReviewThread?.id),
                providerCommentID: normalizedOptionalString(comment.id),
                providerURL: try? parseOptionalHTTPURL(comment.url, context: "gh publish review returned an invalid URL")
            )
        }
        var warnings: [String] = []
        let missingDrafts = drafts.dropFirst(published.count)
        let failed: [ProviderReviewFailedComment]
        if !missingDrafts.isEmpty, comments.count == 100 {
            published.append(contentsOf: missingDrafts.map {
                ProviderReviewPublishedComment(
                    localDraftID: $0.localDraftID,
                    providerThreadID: nil,
                    providerCommentID: nil,
                    providerURL: nil
                )
            })
            warnings.append("GitHub returned only the first 100 review comments; remaining drafts were marked published without provider comment IDs.")
            failed = []
        } else {
            failed = missingDrafts.map {
                ProviderReviewFailedComment(
                    localDraftID: $0.localDraftID,
                    message: "GitHub did not return a published comment for this draft."
                )
            }
        }
        return (Array(published), failed, warnings)
    }

    static func parseThreadReplyResult(_ json: String) throws -> URL? {
        let data = Data(json.utf8)
        do {
            let response = try JSONDecoder().decode(ThreadReplyResponse.self, from: data)
            return try parseOptionalHTTPURL(
                response.data.addPullRequestReviewThreadReply.comment.url,
                context: "gh review thread reply returned an invalid URL"
            )
        } catch let error as CodeHostProviderError {
            throw error
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh review thread reply output")
        }
    }

    static func parseThreadStateResult(_ json: String, mutationName: String) throws {
        let data = Data(json.utf8)
        do {
            switch mutationName {
            case "resolveReviewThread":
                _ = try JSONDecoder().decode(ResolveThreadStateResponse.self, from: data)
            case "unresolveReviewThread":
                _ = try JSONDecoder().decode(UnresolveThreadStateResponse.self, from: data)
            default:
                throw CodeHostProviderError.malformedOutput("Unsupported GitHub review thread mutation output")
            }
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh \(mutationName) output")
        }
    }

    static func githubRunID(from url: URL?) -> String? {
        guard let url else { return nil }
        let components = url.pathComponents
        guard let runsIndex = components.firstIndex(of: "runs") else {
            return nil
        }
        let runIDIndex = components.index(after: runsIndex)
        guard runIDIndex < components.endIndex else {
            return nil
        }
        let runID = components[runIDIndex]
        return runID.isEmpty ? nil : runID
    }

    static func githubJobID(from url: URL?) -> String? {
        guard let url else { return nil }
        let components = url.pathComponents
        guard let jobIndex = components.firstIndex(of: "job") else {
            return nil
        }
        let jobIDIndex = components.index(after: jobIndex)
        guard jobIDIndex < components.endIndex else {
            return nil
        }
        let jobID = components[jobIDIndex]
        return jobID.isEmpty ? nil : jobID
    }

    private static func parseReviewThreadsPage(_ json: String) throws -> ReviewThreadsPage {
        let data = Data(json.utf8)
        let response: ReviewThreadsResponse
        do {
            response = try JSONDecoder().decode(ReviewThreadsResponse.self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh review threads output")
        }

        let connection = response.data.repository.pullRequest.reviewThreads
        let threads: [ReviewThread] = try connection.nodes.compactMap { node in
            let allComments: [ReviewComment] = try node.comments.nodes.enumerated().map { index, c in
                ReviewComment(
                    id: c.id ?? "\(node.id)-\(index)",
                    author: c.author?.login,
                    body: c.body,
                    url: try parseOptionalHTTPURL(c.url, context: "gh review threads returned an invalid URL"),
                    createdAt: try? parseOptionalDate(c.createdAt),
                    viewerCanUpdate: c.viewerDidAuthor ?? false,
                    viewerCanDelete: c.viewerDidAuthor ?? false,
                    isPending: false
                )
            }
            let comments = allComments.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !comments.isEmpty else {
                return nil
            }
            return ReviewThread(
                id: node.id,
                path: node.path,
                line: node.line,
                startLine: node.startLine,
                originalLine: node.originalLine,
                originalStartLine: node.originalStartLine,
                diffHunk: node.comments.nodes.first?.diffHunk,
                diffSide: node.diffSide,
                isResolved: node.isResolved,
                isOutdated: node.isOutdated,
                isFileLevel: (node.subjectType ?? "").uppercased() == "FILE",
                comments: comments,
                viewerCanResolve: node.viewerCanResolve ?? false,
                viewerCanUnresolve: node.viewerCanUnresolve ?? false,
                viewerCanReply: node.viewerCanReply ?? false,
                url: comments.first?.url
            )
        }
        return ReviewThreadsPage(threads: threads, pageInfo: connection.pageInfo)
    }

    private static func parseAddThreadReplyResponse(_ json: String) throws -> ReviewComment {
        let data = Data(json.utf8)
        let response: AddPullRequestReviewThreadReplyResponse
        do {
            response = try JSONDecoder().decode(AddPullRequestReviewThreadReplyResponse.self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh addPullRequestReviewThreadReply output")
        }

        let comment = response.data.addPullRequestReviewThreadReply.comment
        return commentNodeToReviewComment(comment)
    }

    private static func parseResolveThreadResponse(_ json: String, from thread: ReviewThread) throws -> ReviewThread {
        let data = Data(json.utf8)
        let response: ResolvePullRequestReviewThreadResponse
        do {
            response = try JSONDecoder().decode(ResolvePullRequestReviewThreadResponse.self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh resolvePullRequestReviewThread output")
        }
        return threadMutationNodeToReviewThread(response.data.resolveReviewThread.thread, from: thread)
    }

    private static func parseUnresolveThreadResponse(_ json: String, from thread: ReviewThread) throws -> ReviewThread {
        let data = Data(json.utf8)
        let response: UnresolvePullRequestReviewThreadResponse
        do {
            response = try JSONDecoder().decode(UnresolvePullRequestReviewThreadResponse.self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh unresolveReviewThread output")
        }
        return threadMutationNodeToReviewThread(response.data.unresolveReviewThread.thread, from: thread)
    }

    private static func threadMutationNodeToReviewThread(_ mutated: ThreadMutationNode, from thread: ReviewThread) -> ReviewThread {
        ReviewThread(
            id: mutated.id,
            path: thread.path,
            line: thread.line,
            startLine: thread.startLine,
            originalLine: thread.originalLine,
            originalStartLine: thread.originalStartLine,
            diffHunk: thread.diffHunk,
            diffSide: thread.diffSide,
            isResolved: mutated.isResolved,
            isOutdated: mutated.isOutdated,
            isFileLevel: thread.isFileLevel,
            comments: thread.comments,
            viewerCanResolve: thread.viewerCanResolve,
            viewerCanUnresolve: thread.viewerCanUnresolve,
            viewerCanReply: thread.viewerCanReply,
            url: thread.url
        )
    }

    private static func parseUpdateCommentResponse(_ json: String) throws -> ReviewComment {
        let data = Data(json.utf8)
        let response: UpdatePullRequestReviewCommentResponse
        do {
            response = try JSONDecoder().decode(UpdatePullRequestReviewCommentResponse.self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh updatePullRequestReviewComment output")
        }

        return commentNodeToReviewComment(response.data.updatePullRequestReviewComment.pullRequestReviewComment)
    }

    private static func commentNodeToReviewComment(_ comment: ReviewThreadCommentNode) -> ReviewComment {
        ReviewComment(
            id: comment.id ?? "",
            author: comment.author?.login,
            body: comment.body,
            url: (try? parseOptionalHTTPURL(comment.url, context: "gh returned an invalid URL")) ?? nil,
            createdAt: (try? parseOptionalDate(comment.createdAt)) ?? nil,
            viewerCanUpdate: comment.viewerDidAuthor ?? false,
            viewerCanDelete: comment.viewerDidAuthor ?? false,
            isPending: false
        )
    }

    private static func parsePRNodeIDResponse(_ json: String) throws -> String {
        let data = Data(json.utf8)
        let response: PRNodeIDResponse
        do {
            response = try JSONDecoder().decode(PRNodeIDResponse.self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh pullRequest node id output")
        }
        return response.data.repository.pullRequest.id
    }

    private static func parseStartReviewResponse(_ json: String) throws -> String {
        let data = Data(json.utf8)
        let response: AddPullRequestReviewResponse
        do {
            response = try JSONDecoder().decode(AddPullRequestReviewResponse.self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh addPullRequestReview output")
        }
        return response.data.addPullRequestReview.pullRequestReview.id
    }

    private static func isNoChecksReported(_ result: ProcessResult) -> Bool {
        let output = "\(result.stdout)\n\(result.stderr)".lowercased()
        return output.contains("no checks reported")
    }

    static func parseLatestRunID(_ json: String) throws -> Int? {
        try parseRunIDs(json).first
    }

    static func parseRunIDs(_ json: String) throws -> [Int] {
        let data = Data(json.utf8)
        let items: [RunItem]
        do {
            items = try JSONDecoder().decode([RunItem].self, from: data)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh run list output")
        }
        return items.map(\.databaseId)
    }

    private static func mapState(_ value: String) -> ReviewRequestState {
        switch value.uppercased() {
        case "OPEN": .open
        case "MERGED": .merged
        case "CLOSED": .closed
        default: .open
        }
    }

    private static func mapReviewDecision(_ value: String?) -> ReviewDecision {
        switch value?.uppercased() {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .reviewRequired
        default: .unknown
        }
    }

    private static func mapMergeState(_ value: String?) -> ReviewMergeState {
        switch value?.uppercased() {
        case "CLEAN": .clean
        // GitHub Enterprise reports HAS_HOOKS for a PR that is mergeable with
        // passing status and pre-receive hooks. It's mergeable like CLEAN, so
        // treat it as such rather than falling through to `.unknown` (which
        // would hide the Merge action).
        case "HAS_HOOKS": .clean
        case "BLOCKED": .blocked
        case "DIRTY": .dirty
        case "UNSTABLE": .unstable
        default: .unknown
        }
    }

    private static func mapBucket(_ value: String) -> ReviewCheckBucket {
        ReviewCheckBucket(rawValue: value.lowercased()) ?? .unknown
    }

    private static func parseOptionalDate(_ value: String?) throws -> Date? {
        guard let value else {
            return nil
        }
        if let date = parseDate(value, formatOptions: [.withInternetDateTime]) {
            return date
        }
        if let date = parseDate(value, formatOptions: [.withInternetDateTime, .withFractionalSeconds]) {
            return date
        }
        throw CodeHostProviderError.malformedOutput("Unable to parse GitHub date")
    }

    static func parseIssue(_ json: String, remote: CodeHostRemote, requestedNumber: Int) throws -> MissionIssueSnapshot {
        let response: GitHubIssueResponse
        do {
            response = try JSONDecoder().decode(GitHubIssueResponse.self, from: Data(json.utf8))
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse GitHub issue output.")
        }
        guard response.number == requestedNumber,
              !response.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = try parseOptionalHTTPURL(response.htmlURL, context: "GitHub issue output is missing a valid URL.")
        else {
            throw CodeHostProviderError.malformedOutput("GitHub issue output is missing required fields.")
        }
        guard response.pullRequest == nil else {
            throw CodeHostProviderError.malformedOutput("GitHub issue output describes a pull request, not an issue.")
        }
        guard case .url(let kind, let host, let repositorySlug, let number) = try MissionIssueInput.parse(url.absoluteString),
              kind == .github,
              host.caseInsensitiveCompare(remote.host) == .orderedSame,
              number == response.number
        else {
            throw CodeHostProviderError.malformedOutput("GitHub issue output has an unexpected canonical URL.")
        }
        return MissionIssueSnapshot(
            identity: MissionIssueIdentity(
                provider: kind,
                host: host,
                repositorySlug: repositorySlug.lowercased(),
                number: number
            ),
            canonicalURL: url,
            title: response.title,
            body: response.body ?? "",
            state: MissionIssueState(rawValue: response.state.lowercased()) ?? .unknown,
            labels: response.labels.compactMap { normalizedOptionalString($0.name) },
            assignees: response.assignees.compactMap { normalizedOptionalString($0.login) },
            providerUpdatedAt: try parseOptionalDate(response.updatedAt),
            capturedAt: Date(),
            refreshError: nil
        )
    }

    private static func parseOptionalHTTPURL(_ value: String?, context: String) throws -> URL? {
        guard let value,
              !value.isEmpty
        else { return nil }
        guard let url = URL(string: value),
              url.isHTTPOrHTTPS
        else {
            throw CodeHostProviderError.malformedOutput(context)
        }
        return url
    }

    private static func parseDate(_ value: String, formatOptions: ISO8601DateFormatter.Options) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = formatOptions
        return formatter.date(from: value)
    }

    private static func checkID(for item: CheckItem) -> String {
        // Extract the numeric check-run (job) ID from the GitHub Actions URL:
        // https://github.com/{owner}/{repo}/actions/runs/{run_id}/job/{job_id}
        if let link = item.link,
           let url = URL(string: link),
           let jobID = url.pathComponents.dropFirst().drop(while: { $0 != "job" }).dropFirst().first,
           !jobID.isEmpty {
            return jobID
        }
        let fields = [
            "github-check",
            item.workflow ?? "",
            item.name,
            item.bucket,
            item.description ?? "",
            item.event ?? "",
            item.link ?? "",
            item.state ?? "",
            item.startedAt ?? "",
            item.completedAt ?? "",
        ]
        return fields
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }

    private func pullRequestNodeID(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String {
        let stdin = try Self.graphQLInput(
            query: Self.pullRequestNodeQuery,
            variables: PullRequestNodeVariables(
                owner: remote.owner,
                repo: remote.repository,
                number: request.number
            )
        )
        let result = try await runner.run(
            "gh",
            args: Self.graphQLAPIStdinArgs(remote: remote),
            cwd: cwd,
            stdin: stdin
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
        }
        return try Self.parsePullRequestNodeID(result.stdout)
    }

    static func githubReviewEvent(for decision: ProviderReviewDecision) -> String {
        switch decision {
        case .comment: "COMMENT"
        case .approve: "APPROVE"
        case .requestChanges: "REQUEST_CHANGES"
        }
    }

    static func graphQLAPIStdinArgs(remote: CodeHostRemote) -> [String] {
        ["api", "graphql", "--hostname", remote.host, "--input", "-"]
    }

    static func highLevelRepositorySelector(remote: CodeHostRemote) -> String {
        remote.host == "github.com" ? remote.repositorySlug : "\(remote.host)/\(remote.repositorySlug)"
    }

    private static func encodedFilePath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    static func githubReviewThreadPayload(for draft: ProviderReviewDraftComment) -> GitHubReviewDraftThreadPayload {
        GitHubReviewDraftThreadPayload(
            path: draft.path,
            body: draft.bodyMarkdown,
            line: draft.lineRange.upperBound,
            side: draft.side == .old ? "LEFT" : "RIGHT",
            startLine: draft.lineRange.lowerBound == draft.lineRange.upperBound ? nil : draft.lineRange.lowerBound,
            startSide: draft.lineRange.lowerBound == draft.lineRange.upperBound ? nil : (draft.side == .old ? "LEFT" : "RIGHT")
        )
    }

    static func graphQLInput<Variables: Encodable>(query: String, variables: Variables) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(GraphQLRequest(query: query, variables: variables))
            guard let string = String(data: data, encoding: .utf8) else {
                throw CodeHostProviderError.malformedOutput("Unable to encode gh graphql input")
            }
            return string
        } catch let error as CodeHostProviderError {
            throw error
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to encode gh graphql input")
        }
    }
}

private struct PRListItem: Decodable {
    let number: Int
    let title: String
    let url: String
    let state: String
    let isDraft: Bool
    let headRefName: String
    let headRefOid: String?
    let headRepositoryOwner: HeadRepositoryOwner?
    let headRepository: HeadRepository?
    let baseRefName: String
    let baseRefOid: String?
    let reviewDecision: String?
    let mergeStateStatus: String?
}

private struct GitHubCompareResponse: Decodable {
    let mergeBaseCommit: GitHubCompareCommit

    private enum CodingKeys: String, CodingKey {
        case mergeBaseCommit = "merge_base_commit"
    }
}

private struct GitHubCompareCommit: Decodable {
    let sha: String?
}

private struct HeadRepository: Decodable {
    let name: String
}

private struct HeadRepositoryOwner: Decodable {
    let login: String

    init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let login = try? singleValue.decode(String.self) {
            self.login = login
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.login = try container.decode(String.self, forKey: .login)
    }

    private enum CodingKeys: String, CodingKey {
        case login
    }
}

private struct PullRequestQueueMetadata: Equatable, Sendable {
    let isMergeQueueEnabled: Bool
    let isInMergeQueue: Bool

    static let unavailable = PullRequestQueueMetadata(
        isMergeQueueEnabled: false,
        isInMergeQueue: false
    )
}

private struct GitHubQueueMetadataResponse: Decodable {
    struct DataPayload: Decodable {
        struct Repository: Decodable {
            struct PullRequest: Decodable {
                let isMergeQueueEnabled: Bool
                let isInMergeQueue: Bool
            }

            let pullRequest: PullRequest
        }

        let repository: Repository
    }

    let data: DataPayload
}

private struct CheckItem: Decodable {
    let bucket: String
    let completedAt: String?
    let description: String?
    let event: String?
    let link: String?
    let name: String
    let startedAt: String?
    let state: String?
    let workflow: String?
}

private struct RunItem: Decodable {
    let databaseId: Int
}

private struct GraphQLRequest<Variables: Encodable>: Encodable {
    let query: String
    let variables: Variables
}

private struct PullRequestNodeVariables: Encodable {
    let owner: String
    let repo: String
    let number: Int
}

private struct PullRequestNodeResponse: Decodable {
    let data: PullRequestNodeData
}

private struct PullRequestNodeData: Decodable {
    let repository: PullRequestNodeRepository
}

private struct PullRequestNodeRepository: Decodable {
    let pullRequest: PullRequestNodePullRequest
}

private struct PullRequestNodePullRequest: Decodable {
    let id: String
}

struct GitHubReviewDraftThreadPayload: Encodable, Equatable {
    let path: String
    let body: String
    let line: Int
    let side: String
    let startLine: Int?
    let startSide: String?
}

private struct PublishReviewVariables: Encodable {
    let input: PublishReviewInput
}

private struct PublishReviewInput: Encodable {
    let pullRequestId: String
    let commitOID: String?
    let event: String
    let body: String
    let threads: [GitHubReviewDraftThreadPayload]
}

private struct PublishReviewResponse: Decodable {
    let data: PublishReviewData
}

private struct PublishReviewData: Decodable {
    let addPullRequestReview: AddPullRequestReviewPayload
}

private struct AddPullRequestReviewPayload: Decodable {
    let pullRequestReview: PublishedPullRequestReview
}

private struct PublishedPullRequestReview: Decodable {
    let comments: PublishedReviewCommentsConnection
}

private struct PublishedReviewCommentsConnection: Decodable {
    let nodes: [PublishedReviewCommentNode]
}

private struct PublishedReviewCommentNode: Decodable {
    let id: String?
    let url: String?
    let pullRequestReviewThread: PublishedReviewThreadNode?
}

private struct PublishedReviewThreadNode: Decodable {
    let id: String?
}

private struct ThreadReplyVariables: Encodable {
    let input: ThreadReplyInput
}

private struct ThreadReplyInput: Encodable {
    let pullRequestReviewThreadId: String
    let body: String
}

private struct ThreadReplyResponse: Decodable {
    let data: ThreadReplyData
}

private struct ThreadReplyData: Decodable {
    let addPullRequestReviewThreadReply: AddPullRequestReviewThreadReplyPayload
}

private struct AddPullRequestReviewThreadReplyPayload: Decodable {
    let comment: ThreadReplyComment
}

private struct ThreadReplyComment: Decodable {
    let id: String?
    let url: String?
}

private struct ThreadStateVariables: Encodable {
    let input: ThreadStateInput
}

private struct ThreadStateInput: Encodable {
    let threadId: String
}

private struct ResolveThreadStateResponse: Decodable {
    let data: ResolveThreadStateData
}

private struct ResolveThreadStateData: Decodable {
    let resolveReviewThread: ThreadStatePayload
}

private struct UnresolveThreadStateResponse: Decodable {
    let data: UnresolveThreadStateData
}

private struct UnresolveThreadStateData: Decodable {
    let unresolveReviewThread: ThreadStatePayload
}

private struct ThreadStatePayload: Decodable {
    let thread: ThreadStateThread
}

private struct ThreadStateThread: Decodable {
    let id: String
    let isResolved: Bool
}

private struct ReviewThreadsResponse: Decodable {
    let data: ReviewThreadsData
}

private struct ReviewThreadsData: Decodable {
    let repository: ReviewThreadsRepository
}

private struct ReviewThreadsRepository: Decodable {
    let pullRequest: ReviewThreadsPullRequest
}

private struct ReviewThreadsPullRequest: Decodable {
    let reviewThreads: ReviewThreadsConnection
}

private struct ReviewThreadsConnection: Decodable {
    let nodes: [ReviewThreadNode]
    let pageInfo: ReviewThreadsPageInfo
}

private struct ReviewThreadsPage: Equatable {
    let threads: [ReviewThread]
    let pageInfo: ReviewThreadsPageInfo
}

private struct ReviewThreadsPageInfo: Decodable, Equatable {
    let hasNextPage: Bool
    let endCursor: String?
}

private struct ReviewThreadNode: Decodable {
    let id: String
    let isResolved: Bool
    let isOutdated: Bool
    let path: String?
    let line: Int?
    let startLine: Int?
    let originalLine: Int?
    let originalStartLine: Int?
    let subjectType: String?
    let diffSide: String?
    let viewerCanResolve: Bool?
    let viewerCanUnresolve: Bool?
    let viewerCanReply: Bool?
    let comments: ReviewThreadCommentsConnection

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.isResolved = try container.decode(Bool.self, forKey: .isResolved)
        self.isOutdated = try container.decode(Bool.self, forKey: .isOutdated)
        self.path = try? container.decode(String.self, forKey: .path)
        self.line = try? container.decode(Int.self, forKey: .line)
        self.startLine = try? container.decode(Int.self, forKey: .startLine)
        self.originalLine = try? container.decode(Int.self, forKey: .originalLine)
        self.originalStartLine = try? container.decode(Int.self, forKey: .originalStartLine)
        self.subjectType = try? container.decode(String.self, forKey: .subjectType)
        self.diffSide = try? container.decode(String.self, forKey: .diffSide)
        self.viewerCanResolve = try? container.decode(Bool.self, forKey: .viewerCanResolve)
        self.viewerCanUnresolve = try? container.decode(Bool.self, forKey: .viewerCanUnresolve)
        self.viewerCanReply = try? container.decode(Bool.self, forKey: .viewerCanReply)
        self.comments = try container.decode(ReviewThreadCommentsConnection.self, forKey: .comments)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case isResolved
        case isOutdated
        case path
        case line
        case startLine
        case originalLine
        case originalStartLine
        case subjectType
        case diffSide
        case viewerCanResolve
        case viewerCanUnresolve
        case viewerCanReply
        case comments
    }
}

private struct ReviewThreadCommentsConnection: Decodable {
    let nodes: [ReviewThreadCommentNode]
}

private struct ReviewThreadCommentNode: Decodable {
    let id: String?
    let body: String
    let url: String?
    let createdAt: String?
    let diffHunk: String?
    let author: ReviewThreadAuthor?
    let viewerDidAuthor: Bool?
}

private struct ReviewThreadAuthor: Decodable {
    let login: String
}

private struct AddPullRequestReviewThreadReplyResponse: Decodable {
    let data: AddPullRequestReviewThreadReplyData
}

private struct AddPullRequestReviewThreadReplyData: Decodable {
    let addPullRequestReviewThreadReply: MutateThreadReplyPayload
}

private struct MutateThreadReplyPayload: Decodable {
    let comment: ReviewThreadCommentNode
}

private struct ResolvePullRequestReviewThreadResponse: Decodable {
    let data: ResolvePullRequestReviewThreadData
}

private struct ResolvePullRequestReviewThreadData: Decodable {
    let resolveReviewThread: ThreadMutationPayload
}

private struct UnresolvePullRequestReviewThreadResponse: Decodable {
    let data: UnresolvePullRequestReviewThreadData
}

private struct UnresolvePullRequestReviewThreadData: Decodable {
    let unresolveReviewThread: ThreadMutationPayload
}

private struct ThreadMutationPayload: Decodable {
    let thread: ThreadMutationNode
}

private struct ThreadMutationNode: Decodable {
    let id: String
    let isResolved: Bool
    let isOutdated: Bool
}

private struct UpdatePullRequestReviewCommentResponse: Decodable {
    let data: UpdatePullRequestReviewCommentData
}

private struct UpdatePullRequestReviewCommentData: Decodable {
    let updatePullRequestReviewComment: UpdatePullRequestReviewCommentPayload
}

private struct UpdatePullRequestReviewCommentPayload: Decodable {
    let pullRequestReviewComment: ReviewThreadCommentNode
}

private struct PRNodeIDResponse: Decodable {
    let data: PRNodeIDData
}
private struct PRNodeIDData: Decodable {
    let repository: PRNodeIDRepository
}
private struct PRNodeIDRepository: Decodable {
    let pullRequest: PRNodeIDPR
}
private struct PRNodeIDPR: Decodable {
    let id: String
}

private struct AddPullRequestReviewResponse: Decodable {
    let data: AddPullRequestReviewData
}
private struct AddPullRequestReviewData: Decodable {
    let addPullRequestReview: StartReviewPayload
}
private struct StartReviewPayload: Decodable {
    let pullRequestReview: ReviewNodeID
}
private struct ReviewNodeID: Decodable {
    let id: String
}

private struct GitHubAnnotationResponse: Decodable {
    let path: String
    let start_line: Int
    let end_line: Int
    let annotation_level: String
    let message: String
    let raw_details: String?
}

private struct GitHubIssueResponse: Decodable {
    let number: Int
    let title: String
    let body: String?
    let state: String
    let htmlURL: String?
    let updatedAt: String?
    let labels: [Label]
    let assignees: [Assignee]
    let pullRequest: PullRequestMarker?

    private enum CodingKeys: String, CodingKey {
        case number, title, body, state, labels, assignees
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
        case pullRequest = "pull_request"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        state = try container.decode(String.self, forKey: .state)
        htmlURL = try container.decodeIfPresent(String.self, forKey: .htmlURL)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        labels = try container.decodeIfPresent([Label].self, forKey: .labels) ?? []
        assignees = try container.decodeIfPresent([Assignee].self, forKey: .assignees) ?? []
        pullRequest = try container.decodeIfPresent(PullRequestMarker.self, forKey: .pullRequest)
    }

    struct Label: Decodable { let name: String? }
    struct Assignee: Decodable { let login: String? }
    struct PullRequestMarker: Decodable {}
}

private extension URL {
    var isHTTPOrHTTPS: Bool {
        (scheme == "http" || scheme == "https") && !(host ?? "").isEmpty
    }
}
