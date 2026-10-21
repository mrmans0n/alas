import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures

public struct GitHubCLIProvider: CodeHostProvider, CodeHostIssueProviding, Sendable {
    public let kind: CodeHostKind = .github
    public let capabilities: CodeHostProviderCapabilities = .githubCLI
    public let executable = "gh"
    public static let pullRequestNodeQuery = """
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          id
        }
      }
    }
    """

    public static let publishReviewMutation = """
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

    public static let replyReviewThreadMutation = """
    mutation($input: AddPullRequestReviewThreadReplyInput!) {
      addPullRequestReviewThreadReply(input: $input) {
        comment {
          id
          url
        }
      }
    }
    """

    public static let resolveReviewThreadMutation = """
    mutation($input: ResolveReviewThreadInput!) {
      resolveReviewThread(input: $input) {
        thread {
          id
          isResolved
        }
      }
    }
    """

    public static let unresolveReviewThreadMutation = """
    mutation($input: UnresolveReviewThreadInput!) {
      unresolveReviewThread(input: $input) {
        thread {
          id
          isResolved
        }
      }
    }
    """

    public static let reviewThreadsQuery = """
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
                    __typename
                    login
                  }
                  authorAssociation
                  viewerDidAuthor
                }
                pageInfo {
                  hasNextPage
                  endCursor
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

    /// Fetches the comments after the first page of one review thread, for
    /// threads whose `comments` connection in `reviewThreadsQuery` has more.
    public static let reviewThreadCommentsQuery = """
    query($threadID: ID!, $cursor: String) {
      node(id: $threadID) {
        ... on PullRequestReviewThread {
          comments(first: 100, after: $cursor) {
            nodes {
              id
              body
              url
              createdAt
              diffHunk
              author {
                __typename
                login
              }
              authorAssociation
              viewerDidAuthor
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

    /// Extra comment pages fetched per review thread before the thread list is
    /// reported incomplete.
    public static let reviewThreadCommentsMaxExtraPages = 10

    /// Every connection is fetched on the first page. Later pages walk each
    /// connection backwards with its `before` cursor and skip the commit and
    /// any connection that has run out.
    public static let reviewersOnHeadQuery = """
    query(
      $owner: String!, $repo: String!, $number: Int!,
      $reviewsBefore: String, $commentsBefore: String, $reactionsBefore: String,
      $withCommits: Boolean = true, $withReviews: Boolean = true,
      $withComments: Boolean = true, $withReactions: Boolean = true
    ) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          commits(last: 1) @include(if: $withCommits) {
            nodes {
              commit {
                oid
                committedDate
              }
            }
          }
          reviews(
            last: 100, before: $reviewsBefore, states: [APPROVED, CHANGES_REQUESTED, COMMENTED]
          ) @include(if: $withReviews) {
            nodes {
              author {
                login
              }
              commit {
                oid
              }
            }
            pageInfo {
              hasPreviousPage
              startCursor
            }
          }
          comments(last: 100, before: $commentsBefore) @include(if: $withComments) {
            nodes {
              author {
                login
              }
              createdAt
            }
            pageInfo {
              hasPreviousPage
              startCursor
            }
          }
          reactions(last: 100, before: $reactionsBefore) @include(if: $withReactions) {
            nodes {
              content
              createdAt
              user {
                login
              }
            }
            pageInfo {
              hasPreviousPage
              startCursor
            }
          }
        }
      }
    }
    """

    /// Pages fetched per connection before `reviewersOnHead` stops and
    /// judges what it has; evidence it never reads only means "not reviewed".
    public static let reviewersOnHeadMaxPages = 10

    public static let mergeQueueMetadataQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          isMergeQueueEnabled
          isInMergeQueue
        }
      }
    }
    """

    public static let addPullRequestReviewThreadReplyMutation = """
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

    public static let resolvePullRequestReviewThreadMutation = """
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

    public static let unresolvePullRequestReviewThreadMutation = """
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

    public static let updatePullRequestReviewCommentMutation = """
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

    public static let deletePullRequestReviewCommentMutation = """
    mutation($commentId: ID!) {
      deletePullRequestReviewComment(input: {id: $commentId}) {
        clientMutationId
      }
    }
    """

    public static let deletePullRequestReviewMutation = """
    mutation($reviewId: ID!) {
      deletePullRequestReview(input: {pullRequestReviewId: $reviewId}) {
        clientMutationId
      }
    }
    """

    public static let prNodeIDQuery = """
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          id
        }
      }
    }
    """

    public static let addPullRequestReviewMutation = """
    mutation($prId: ID!, $commitOID: GitObjectID!) {
      addPullRequestReview(input: {pullRequestId: $prId, commitOID: $commitOID}) {
        pullRequestReview {
          id
        }
      }
    }
    """

    public static let addPullRequestReviewCommentMutation = """
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

    public static let submitPullRequestReviewMutation = """
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

    public init(runner: any CodeHostCommandRunning = ProcessCodeHostCommandRunner()) {
        self.runner = runner
    }

    /// Branches per GraphQL request. Each is an aliased connection of at most
    /// `mergedPullRequestsPerBranch` nodes, far below GitHub's node limit.
    public static let mergedPullRequestsBranchBatchSize = 50
    /// A branch name reused across this many merged pull requests is rare;
    /// the scanner only needs the one whose head matches the local `HEAD`.
    static let mergedPullRequestsPerBranch = 20

    public func mergedReviewRequests(
        remote: CodeHostRemote,
        headBranches: [String],
        cwd: URL
    ) async throws -> [MergedReviewRequestRef] {
        let branches = Array(Set(headBranches)).sorted()
        var refs: [MergedReviewRequestRef] = []
        for start in stride(from: 0, to: branches.count, by: Self.mergedPullRequestsBranchBatchSize) {
            let batch = Array(branches[start..<min(start + Self.mergedPullRequestsBranchBatchSize, branches.count)])
            var variables = ["owner": remote.owner, "repo": remote.repository]
            for (index, branch) in batch.enumerated() {
                variables["b\(index)"] = branch
            }
            let result = try await runner.run(
                "gh",
                args: ["api", "graphql", "--hostname", remote.host, "--input", "-"],
                cwd: cwd,
                stdin: try Self.graphQLInput(
                    query: Self.mergedPullRequestsQuery(branchCount: batch.count),
                    variables: variables
                )
            )
            guard result.exitCode == 0 else {
                throw CodeHostProviderError.commandFailed(
                    command: "gh api graphql",
                    stderr: result.stderr
                )
            }
            refs.append(contentsOf: try Self.parseMergedPullRequests(result.stdout))
        }
        return refs
    }

    /// One aliased `pullRequests` connection per branch (`b0`, `b1`, …), each
    /// bound to a `$bN` variable so branch names never reach the query text.
    static func mergedPullRequestsQuery(branchCount: Int) -> String {
        let parameters = (0..<branchCount).map { ", $b\($0): String!" }.joined()
        let connections = (0..<branchCount).map {
            "b\($0): pullRequests(headRefName: $b\($0), states: MERGED, first: \(mergedPullRequestsPerBranch), "
                + "orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number url headRefName headRefOid } }"
        }.joined(separator: " ")
        return "query($owner: String!, $repo: String!\(parameters)) { repository(owner: $owner, name: $repo) { \(connections) } }"
    }

    public static func parseMergedPullRequests(_ json: String) throws -> [MergedReviewRequestRef] {
        struct Response: Decodable {
            struct Body: Decodable { let repository: [String: Connection]? }
            struct Connection: Decodable { let nodes: [Node] }
            struct Node: Decodable {
                let number: Int
                let url: URL
                let headRefName: String
                let headRefOid: String
            }
            let data: Body?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(json.utf8)),
              let connections = response.data?.repository
        else {
            throw CodeHostProviderError.malformedOutput("Unable to parse merged pull requests")
        }
        return connections.values.flatMap { connection in
            connection.nodes.map {
                MergedReviewRequestRef(
                    number: $0.number,
                    headRefName: $0.headRefName,
                    url: $0.url,
                    headSHA: $0.headRefOid
                )
            }
        }
    }

    public func repositoryParent(remote: CodeHostRemote, cwd: URL) async throws -> CodeHostRemote? {
        let result = try await runner.run(
            "gh",
            args: [
                "repo", "view",
                Self.highLevelRepositorySelector(remote: remote),
                "--json", "isFork,parent",
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(
                command: "gh repo view",
                stderr: result.stderr
            )
        }
        return try Self.parseRepoParent(result.stdout, remote: remote)
    }

    public static func parseRepoParent(_ json: String, remote: CodeHostRemote) throws -> CodeHostRemote? {
        struct ParentOwner: Decodable {
            let login: String
        }
        struct Parent: Decodable {
            let name: String
            let owner: ParentOwner
        }
        struct Item: Decodable {
            let isFork: Bool
            let parent: Parent?
        }
        let item: Item
        do {
            item = try JSONDecoder().decode(Item.self, from: Data(json.utf8))
        } catch {
            throw CodeHostProviderError.malformedOutput(
                "Unable to parse gh repo view output"
            )
        }
        guard item.isFork, let parent = item.parent else { return nil }
        guard let webURL = URL(string: "https://\(remote.host)/\(parent.owner.login)/\(parent.name)") else {
            return nil
        }
        return CodeHostRemote(
            kind: remote.kind,
            host: remote.host,
            owner: parent.owner.login,
            repository: parent.name,
            remoteName: remote.remoteName,
            webURL: webURL
        )
    }

    public func isAvailable(cwd: URL) async -> Bool {
        do {
            let result = try await runner.run("gh", args: ["--version"], cwd: cwd)
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    public func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool {
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

    public func issue(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> CodeHostIssueSnapshot {
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

    public func openIssues(remote: CodeHostRemote, limit: Int, cwd: URL) async throws -> [CodeHostIssueSuggestion] {
        guard limit > 0 else { return [] }
        let result = try await runner.run(
            executable,
            args: [
                "api", "--hostname", remote.host, "--method", "GET", "--paginate", "--slurp",
                "repos/\(remote.repositorySlug)/issues",
                "-f", "state=open", "-f", "sort=created", "-f", "direction=desc",
                "-f", "per_page=100",
            ],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            throw CodeHostProviderError.commandFailed(command: "gh api issues", stderr: result.stderr)
        }
        return try Self.parseOpenIssues(result.stdout, remote: remote, limit: limit)
    }

    public func currentReviewRequest(
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

    private func reviewRequest(
        remote: CodeHostRemote,
        branch: String,
        headOwner: String?,
        baseBranch: String,
        headSHA: String? = nil,
        state: String,
        normalizeBaseBranch: Bool = true,
        cwd: URL
    ) async throws -> ReviewRequest? {
        let base = normalizeBaseBranch
            ? Self.normalizedBaseBranch(baseBranch, remoteName: remote.remoteName)
            : baseBranch
        // An empty base finds the branch's request whatever it targets.
        var args = ["pr", "list", "--head", branch]
        if !base.isEmpty { args += ["--base", base] }
        args += [
            "--state", state,
            "--limit", "20",
            "--json", "number,title,url,state,isDraft,headRefName,headRefOid,headRepositoryOwner,headRepository,baseRefName,baseRefOid,reviewDecision,mergeStateStatus",
            "-R", Self.highLevelRepositorySelector(remote: remote),
        ]
        let result = try await runner.run("gh", args: args, cwd: cwd)
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
    /// fail closed instead of treating missing threads as "no feedback". A
    /// thread whose later comment pages could not be read keeps the comments
    /// that were read, and the result is flagged incomplete the same way.
    private func threadsWithCompleteness(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async -> (threads: [ReviewThread], complete: Bool) {
        do {
            return try await reviewThreads(remote: remote, request: request, cwd: cwd)
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

    public func reviewRequest(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> ReviewRequest {
        try await refreshedReviewRequest(remote: remote, request: ReviewRequest.placeholder(remote: remote, number: number), cwd: cwd)
    }

    public func createReviewRequest(
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

    public static func qualifiedHead(branch: String, headOwner: String?, baseOwner: String) -> String {
        guard let headOwner,
              !headOwner.isEmpty,
              headOwner != baseOwner
        else { return branch }
        return "\(headOwner):\(branch)"
    }

    public static func normalizedBaseBranch(_ baseBranch: String, remoteName: String) -> String {
        let prefix = "\(remoteName)/"
        guard baseBranch.hasPrefix(prefix) else { return baseBranch }
        return String(baseBranch.dropFirst(prefix.count))
    }

    public func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] {
        let result = try await runner.run(
            "gh",
            args: [
                "pr", "checks", "\(request.number)",
                "--json", "bucket,completedAt,description,event,link,name,startedAt,state,workflow",
                "-R", Self.highLevelRepositorySelector(remote: remote),
            ],
            cwd: cwd
        )
        let checks: [ReviewCheck]
        if result.exitCode == 1, Self.isNoChecksReported(result) {
            checks = []
        } else {
            guard result.exitCode == 0 || result.exitCode == 1 || result.exitCode == 8 else {
                throw CodeHostProviderError.commandFailed(command: "gh pr checks", stderr: result.stderr)
            }
            checks = try Self.parseChecks(result.stdout)
        }

        guard let headSHA = Self.normalizedOptionalString(request.headSHA) else { return checks }
        return try await addingPendingWorkflowRuns(to: checks, remote: remote, headSHA: headSHA, cwd: cwd)
    }

    /// A workflow run that is queued, or has not created its jobs yet, has no
    /// check runs, so `gh pr checks` does not report it. Each such run becomes
    /// a pending check. Runs are read page by page, up to
    /// `workflowRunsPageLimit` pages. When a page cannot be read, or runs
    /// remain past the last page read, one pending check stands in for the
    /// unread runs, so a caller never reads the gap as "no checks".
    private func addingPendingWorkflowRuns(
        to checks: [ReviewCheck],
        remote: CodeHostRemote,
        headSHA: String,
        cwd: URL
    ) async throws -> [ReviewCheck] {
        var merged = checks
        var runsRead = 0
        for page in 1...Self.workflowRunsPageLimit {
            let result: ProcessResult
            do {
                result = try await runner.run(
                    "gh",
                    args: [
                        "api",
                        "--hostname", remote.host,
                        "repos/\(remote.repositorySlug)/actions/runs?head_sha=\(headSHA)"
                            + "&per_page=\(Self.workflowRunsPageSize)&page=\(page)",
                    ],
                    cwd: cwd
                )
            } catch let error as CancellationError {
                throw error
            } catch {
                return merged + [Self.workflowRunsUnavailableCheck]
            }
            guard result.exitCode == 0,
                  let response = try? Self.decodeWorkflowRuns(result.stdout)
            else { return merged + [Self.workflowRunsUnavailableCheck] }

            merged = Self.mergingPendingWorkflowRuns(response.workflowRuns, into: merged)
            runsRead += response.workflowRuns.count
            if Self.isLastWorkflowRunsPage(response, runsRead: runsRead) { return merged }
        }
        return merged + [Self.workflowRunsUnavailableCheck]
    }

    private static let workflowRunsPageSize = 100
    private static let workflowRunsPageLimit = 5

    static let workflowRunsUnavailableCheck = ReviewCheck(
        id: "workflow-runs-unavailable",
        name: "Workflow runs unavailable",
        workflow: nil,
        bucket: .pending,
        detailURL: nil,
        completedAt: nil
    )

    /// Appends a pending check for each unfinished run in a
    /// `GET /repos/{owner}/{repo}/actions/runs` response whose workflow has no
    /// pending check yet.
    public static func mergingPendingWorkflowRuns(_ json: String, into checks: [ReviewCheck]) throws -> [ReviewCheck] {
        mergingPendingWorkflowRuns(try decodeWorkflowRuns(json).workflowRuns, into: checks)
    }

    private static func decodeWorkflowRuns(_ json: String) throws -> WorkflowRunsResponse {
        do {
            return try JSONDecoder().decode(WorkflowRunsResponse.self, from: Data(json.utf8))
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh api actions/runs output")
        }
    }

    /// A page shorter than the page size is the last one; so is any page that
    /// brings the runs read up to the reported `total_count`.
    private static func isLastWorkflowRunsPage(_ response: WorkflowRunsResponse, runsRead: Int) -> Bool {
        if response.workflowRuns.count < workflowRunsPageSize { return true }
        guard let totalCount = response.totalCount else { return false }
        return runsRead >= totalCount
    }

    private static func mergingPendingWorkflowRuns(
        _ runs: [WorkflowRunsResponse.WorkflowRun],
        into checks: [ReviewCheck]
    ) -> [ReviewCheck] {
        var merged = checks
        for run in runs where run.status != "completed" {
            let workflow = run.name ?? "Workflow run \(run.id)"
            guard !merged.contains(where: { $0.bucket == .pending && $0.workflow == workflow }) else { continue }
            let detailURL = run.htmlURL.flatMap(URL.init(string:)).flatMap { $0.isHTTPOrHTTPS ? $0 : nil }
            merged.append(ReviewCheck(
                id: "run-\(run.id)",
                name: "\(workflow) (\(run.status == "in_progress" ? "running" : "queued"))",
                workflow: workflow,
                bucket: .pending,
                detailURL: detailURL,
                completedAt: nil
            ))
        }
        return merged
    }

    public func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String {
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

    public func reviewImageRevisions(
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

    public func reviewFileData(
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

    public func failedCheckEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] {
        ReviewEvidenceCIActivityMapper.items(for: request.checks)
    }

    public func checkEvidenceDetail(
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

    public func feedbackEvidenceDetail(
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
    ) async throws -> (threads: [ReviewThread], complete: Bool) {
        var nodes: [ReviewThreadNode] = []
        var cursor: String?

        repeat {
            let page = try await reviewThreadsPage(remote: remote, request: request, cursor: cursor, cwd: cwd)
            nodes.append(contentsOf: page.nodes)
            if page.pageInfo.hasNextPage {
                guard let endCursor = page.pageInfo.endCursor, !endCursor.isEmpty else {
                    throw CodeHostProviderError.malformedOutput("gh review threads output is missing a pagination cursor")
                }
                cursor = endCursor
            } else {
                cursor = nil
            }
        } while cursor != nil

        var complete = true
        var threads: [ReviewThread] = []
        for node in nodes {
            var comments = node.comments.nodes
            if let pageInfo = node.comments.pageInfo, pageInfo.hasNextPage {
                do {
                    comments += try await remainingReviewThreadComments(
                        remote: remote,
                        threadID: node.id,
                        after: pageInfo.endCursor,
                        cwd: cwd
                    )
                } catch {
                    complete = false
                }
            }
            if let thread = try Self.reviewThread(from: node, commentNodes: comments) {
                threads.append(thread)
            }
        }
        return (threads, complete)
    }

    /// Reads the comments after `cursor` in one review thread. Throws when a
    /// page can't be read or the thread runs past
    /// `reviewThreadCommentsMaxExtraPages`, so the caller never treats a
    /// truncated comment chain as complete.
    private func remainingReviewThreadComments(
        remote: CodeHostRemote,
        threadID: String,
        after cursor: String?,
        cwd: URL
    ) async throws -> [ReviewThreadCommentNode] {
        var comments: [ReviewThreadCommentNode] = []
        var cursor = cursor
        for _ in 0..<Self.reviewThreadCommentsMaxExtraPages {
            guard let current = cursor, !current.isEmpty else {
                throw CodeHostProviderError.malformedOutput("gh review thread comments output is missing a pagination cursor")
            }
            let result = try await runner.run(
                "gh",
                args: [
                    "api", "graphql",
                    "--hostname", remote.host,
                    "-f", "query=\(Self.reviewThreadCommentsQuery)",
                    "-f", "threadID=\(threadID)",
                    "-f", "cursor=\(current)",
                ],
                cwd: cwd
            )
            guard result.exitCode == 0 else {
                throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
            }
            let page = try Self.parseReviewThreadCommentsPage(result.stdout)
            comments += page.nodes
            guard page.pageInfo.hasNextPage else { return comments }
            cursor = page.pageInfo.endCursor
        }
        throw CodeHostProviderError.malformedOutput(
            "GitHub review thread \(threadID) has more than \(Self.reviewThreadCommentsMaxExtraPages) extra comment pages"
        )
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

    public func reviewersOnHead(
        remote: CodeHostRemote,
        request: ReviewRequest,
        notBefore: Date?,
        cwd: URL
    ) async throws -> Set<String> {
        guard let headSHA = request.headSHA, !headSHA.isEmpty else {
            throw CodeHostProviderError.malformedOutput("GitHub reviewers on head require the pull request head SHA.")
        }
        var pages: [ReviewersOnHeadPage] = []
        var cursors = ReviewersOnHeadCursors()
        for _ in 0..<Self.reviewersOnHeadMaxPages {
            let result = try await runner.run(
                "gh",
                args: [
                    "api", "graphql",
                    "--hostname", remote.host,
                    "-f", "query=\(Self.reviewersOnHeadQuery)",
                    "-F", "owner=\(remote.owner)",
                    "-F", "repo=\(remote.repository)",
                    "-F", "number=\(request.number)",
                ] + cursors.arguments,
                cwd: cwd
            )
            guard result.exitCode == 0 else {
                throw CodeHostProviderError.commandFailed(command: "gh api graphql", stderr: result.stderr)
            }
            let page = try Self.parseReviewersOnHeadPage(result.stdout)
            pages.append(page)
            cursors = try page.cursorsForPreviousPage()
            if cursors.isExhausted { break }
        }
        return Self.reviewersOnHead(in: pages, headSHA: headSHA, notBefore: notBefore)
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

    public func publishReview(_ request: ProviderReviewPublishRequest) async throws -> ProviderReviewPublishResult {
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

    public func mutateReviewThread(_ mutation: ProviderThreadMutation) async throws -> ProviderThreadMutationResult {
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

    public func rerunFailedChecks(
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

    public func mergeReviewRequest(
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

    public func replyToThread(
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

    public func resolveThread(
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

    public func unresolveThread(
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

    public func editComment(
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

    public func deleteComment(
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

    public func startReview(
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

    public func addReviewComment(
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

    public func cancelReview(
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

    public func checkAnnotations(remote: CodeHostRemote, check: ReviewCheck, cwd: URL) async throws -> [CheckAnnotation] {
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

    public func submitReview(
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

    public static func parseCheckAnnotations(_ json: String, check: ReviewCheck) throws -> [CheckAnnotation] {
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

    public static func parsePRList(
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

    public static func parsePRView(_ json: String, remote: CodeHostRemote) throws -> ReviewRequest {
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

    public static func parseChecks(_ json: String) throws -> [ReviewCheck] {
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

    public static func parseCreateOutput(_ stdout: String) throws -> URL {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.isHTTPOrHTTPS else {
            throw CodeHostProviderError.malformedOutput("gh pr create returned an invalid URL")
        }
        return url
    }

    /// Parses one page of `reviewThreadsQuery` output using each thread's
    /// first comment page only.
    public static func parseReviewThreads(_ json: String) throws -> [ReviewThread] {
        try parseReviewThreadsPage(json).nodes.compactMap { node in
            try reviewThread(from: node, commentNodes: node.comments.nodes)
        }
    }

    public static func parsePullRequestNodeID(_ json: String) throws -> String {
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

    public static func parsePublishReviewResult(
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

    public static func parseThreadReplyResult(_ json: String) throws -> URL? {
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

    public static func parseThreadStateResult(_ json: String, mutationName: String) throws {
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

    public static func githubRunID(from url: URL?) -> String? {
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

    public static func githubJobID(from url: URL?) -> String? {
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
        return ReviewThreadsPage(nodes: connection.nodes, pageInfo: connection.pageInfo)
    }

    private static func parseReviewThreadCommentsPage(_ json: String) throws -> ReviewThreadCommentsPage {
        let response: ReviewThreadCommentsResponse
        do {
            response = try JSONDecoder().decode(ReviewThreadCommentsResponse.self, from: Data(json.utf8))
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh review thread comments output")
        }
        let connection = response.data.node.comments
        guard let pageInfo = connection.pageInfo else {
            throw CodeHostProviderError.malformedOutput("gh review thread comments output is missing page info")
        }
        return ReviewThreadCommentsPage(nodes: connection.nodes, pageInfo: pageInfo)
    }

    /// Builds a thread from its node and every comment read for it. Threads
    /// whose comments all have empty bodies are dropped.
    private static func reviewThread(
        from node: ReviewThreadNode,
        commentNodes: [ReviewThreadCommentNode]
    ) throws -> ReviewThread? {
        let allComments: [ReviewComment] = try commentNodes.enumerated().map { index, c in
            ReviewComment(
                id: c.id ?? "\(node.id)-\(index)",
                author: c.author?.login,
                body: c.body,
                url: try parseOptionalHTTPURL(c.url, context: "gh review threads returned an invalid URL"),
                createdAt: try? parseOptionalDate(c.createdAt),
                viewerCanUpdate: c.viewerDidAuthor ?? false,
                viewerCanDelete: c.viewerDidAuthor ?? false,
                isPending: false,
                authorTrust: authorTrust(
                    viewerDidAuthor: c.viewerDidAuthor,
                    authorAssociation: c.authorAssociation,
                    authorTypename: c.author?.typename
                ),
                viewerDidAuthor: c.viewerDidAuthor ?? false
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
            diffHunk: commentNodes.first?.diffHunk,
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

    /// Repository owners, organization members, collaborators and GitHub Apps
    /// (`Bot`) are trusted. The viewer's own comments never are: the shepherd
    /// must not act on its own replies. Without the viewer flag or the
    /// association (for a non-bot) the author can't be classified.
    private static func authorTrust(
        viewerDidAuthor: Bool?,
        authorAssociation: String?,
        authorTypename: String?
    ) -> ReviewAuthorTrust {
        if viewerDidAuthor == true { return .untrusted }
        if authorTypename == "Bot" { return .trusted }
        guard viewerDidAuthor == false,
              let association = authorAssociation?.uppercased(),
              !association.isEmpty
        else { return .unknown }
        switch association {
        case "OWNER", "MEMBER", "COLLABORATOR":
            return .trusted
        default:
            return .untrusted
        }
    }

    /// Across all `pages`: logins with a submitted review on `headSHA`, plus
    /// authors of top-level comments and thumbs-up reactions created after
    /// both the head commit and `notBefore`. Codex reacts with a thumbs-up
    /// instead of reviewing when it finds nothing; its in-progress eyes
    /// reaction doesn't count.
    /// `committedDate` is authored locally, so `notBefore` (when Alas first
    /// saw this head) keeps a comment that predates the push from counting;
    /// the cost is that a thumbs-up posted between the push and Alas's first
    /// poll of the head doesn't count either. A nil `notBefore`, or a head
    /// that moved since the request was fetched, leaves comments and
    /// reactions counting for nobody. Logins are normalized by
    /// `normalizedReviewerLogin`.
    public static func reviewersOnHead(
        in pages: [ReviewersOnHeadPage],
        headSHA: String,
        notBefore: Date?
    ) -> Set<String> {
        let evidence = mergeReviewersOnHeadPages(pages)
        let head = headSHA.lowercased()

        var reviewers = Set<String>()
        for review in evidence.reviews {
            guard review.commit?.oid.lowercased() == head, let login = review.author?.login else { continue }
            reviewers.insert(normalizedReviewerLogin(login))
        }
        guard let notBefore,
              let lastCommit = evidence.lastCommit,
              lastCommit.oid.lowercased() == head,
              let headCommittedAt = try? parseOptionalDate(lastCommit.committedDate)
        else { return reviewers }
        let cutoff = max(headCommittedAt, notBefore)
        for comment in evidence.comments {
            guard let login = comment.author?.login,
                  let createdAt = try? parseOptionalDate(comment.createdAt),
                  createdAt > cutoff
            else { continue }
            reviewers.insert(normalizedReviewerLogin(login))
        }
        for reaction in evidence.reactions where reaction.content == "THUMBS_UP" {
            guard let login = reaction.user?.login,
                  let createdAt = try? parseOptionalDate(reaction.createdAt),
                  createdAt > cutoff
            else { continue }
            reviewers.insert(normalizedReviewerLogin(login))
        }
        return reviewers
    }

    public static func parseReviewersOnHeadPage(_ json: String) throws -> ReviewersOnHeadPage {
        do {
            let response = try JSONDecoder().decode(ReviewersOnHeadResponse.self, from: Data(json.utf8))
            return ReviewersOnHeadPage(pullRequest: response.data.repository.pullRequest)
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse gh reviewers output")
        }
    }

    /// The head commit comes from the first page, the only one that asks for it.
    private static func mergeReviewersOnHeadPages(_ pages: [ReviewersOnHeadPage]) -> ReviewersOnHeadEvidence {
        var evidence = ReviewersOnHeadEvidence(
            lastCommit: pages.first?.pullRequest.commits?.nodes.last?.commit
        )
        for page in pages {
            evidence.reviews += page.pullRequest.reviews?.nodes ?? []
            evidence.comments += page.pullRequest.comments?.nodes ?? []
            evidence.reactions += page.pullRequest.reactions?.nodes ?? []
        }
        return evidence
    }

    /// Lowercased, without the `[bot]` suffix GitHub adds to app logins, so a
    /// rule naming `chatgpt-codex-connector` matches `chatgpt-codex-connector[bot]`.
    private static func normalizedReviewerLogin(_ login: String) -> String {
        let lowered = login.lowercased()
        let botSuffix = "[bot]"
        guard lowered.hasSuffix(botSuffix) else { return lowered }
        return String(lowered.dropLast(botSuffix.count))
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
            isPending: false,
            viewerDidAuthor: comment.viewerDidAuthor ?? false
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

    public static func parseLatestRunID(_ json: String) throws -> Int? {
        try parseRunIDs(json).first
    }

    public static func parseRunIDs(_ json: String) throws -> [Int] {
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

    public static func parseIssue(_ json: String, remote: CodeHostRemote, requestedNumber: Int) throws -> CodeHostIssueSnapshot {
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
        guard case .url(let kind, let host, let repositorySlug, let number) = try CodeHostIssueInput.parse(url.absoluteString),
              kind == .github,
              host.caseInsensitiveCompare(remote.host) == .orderedSame,
              number == response.number
        else {
            throw CodeHostProviderError.malformedOutput("GitHub issue output has an unexpected canonical URL.")
        }
        return CodeHostIssueSnapshot(
            identity: CodeHostIssueIdentity(
                provider: kind,
                host: host,
                repositorySlug: repositorySlug.lowercased(),
                number: number
            ),
            canonicalURL: url,
            title: response.title,
            body: response.body ?? "",
            state: CodeHostIssueState(rawValue: response.state.lowercased()) ?? .unknown,
            labels: response.labels.compactMap { normalizedOptionalString($0.name) },
            assignees: response.assignees.compactMap { normalizedOptionalString($0.login) },
            providerUpdatedAt: try parseOptionalDate(response.updatedAt),
            capturedAt: Date(),
            refreshError: nil,
            nativeType: normalizedOptionalString(response.issueType)
        )
    }

    public static func parseOpenIssues(_ json: String, remote: CodeHostRemote, limit: Int) throws -> [CodeHostIssueSuggestion] {
        let responses: [GitHubOpenIssueResponse]
        do {
            let data = Data(json.utf8)
            if let pages = try? JSONDecoder().decode([[GitHubOpenIssueResponse]].self, from: data) {
                responses = pages.flatMap { $0 }
            } else {
                responses = try JSONDecoder().decode([GitHubOpenIssueResponse].self, from: data)
            }
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse GitHub issue list output.")
        }

        let suggestions = try responses.compactMap { response -> CodeHostIssueSuggestion? in
            guard response.pullRequest == nil else { return nil }
            guard response.number > 0,
                  !response.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let url = try parseOptionalHTTPURL(response.htmlURL, context: "GitHub issue output is missing a valid URL."),
                  let createdAt = parseDate(response.createdAt, formatOptions: [.withInternetDateTime]) ?? parseDate(response.createdAt, formatOptions: [.withInternetDateTime, .withFractionalSeconds]),
                  case .url(let kind, let host, _, let number) = try CodeHostIssueInput.parse(url.absoluteString),
                  kind == .github,
                  host.caseInsensitiveCompare(remote.host) == .orderedSame,
                  number == response.number
            else {
                throw CodeHostProviderError.malformedOutput("GitHub issue output is missing required fields.")
            }
            return CodeHostIssueSuggestion(provider: .github, number: response.number, title: response.title, canonicalURL: url, createdAt: createdAt)
        }
        return suggestions.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.number > $1.number
        }.prefix(limit).map { $0 }
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

    public static func githubReviewEvent(for decision: ProviderReviewDecision) -> String {
        switch decision {
        case .comment: "COMMENT"
        case .approve: "APPROVE"
        case .requestChanges: "REQUEST_CHANGES"
        }
    }

    public static func graphQLAPIStdinArgs(remote: CodeHostRemote) -> [String] {
        ["api", "graphql", "--hostname", remote.host, "--input", "-"]
    }

    public static func highLevelRepositorySelector(remote: CodeHostRemote) -> String {
        remote.host == "github.com" ? remote.repositorySlug : "\(remote.host)/\(remote.repositorySlug)"
    }

    private static func encodedFilePath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    public static func githubReviewThreadPayload(for draft: ProviderReviewDraftComment) -> GitHubReviewDraftThreadPayload {
        GitHubReviewDraftThreadPayload(
            path: draft.path,
            body: draft.bodyMarkdown,
            line: draft.lineRange.upperBound,
            side: draft.side == .old ? "LEFT" : "RIGHT",
            startLine: draft.lineRange.lowerBound == draft.lineRange.upperBound ? nil : draft.lineRange.lowerBound,
            startSide: draft.lineRange.lowerBound == draft.lineRange.upperBound ? nil : (draft.side == .old ? "LEFT" : "RIGHT")
        )
    }

    public static func graphQLInput<Variables: Encodable>(query: String, variables: Variables) throws -> String {
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

    public init(number: Int, title: String, url: String, state: String, isDraft: Bool, headRefName: String, headRefOid: String?, headRepositoryOwner: HeadRepositoryOwner?, headRepository: HeadRepository?, baseRefName: String, baseRefOid: String?, reviewDecision: String?, mergeStateStatus: String?) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.headRepositoryOwner = headRepositoryOwner
        self.headRepository = headRepository
        self.baseRefName = baseRefName
        self.baseRefOid = baseRefOid
        self.reviewDecision = reviewDecision
        self.mergeStateStatus = mergeStateStatus
    }
}

private struct GitHubCompareResponse: Decodable {
    let mergeBaseCommit: GitHubCompareCommit

    private enum CodingKeys: String, CodingKey {
        case mergeBaseCommit = "merge_base_commit"
    }

    public init(mergeBaseCommit: GitHubCompareCommit) {
        self.mergeBaseCommit = mergeBaseCommit
    }
}

private struct GitHubCompareCommit: Decodable {
    let sha: String?

    public init(sha: String?) {
        self.sha = sha
    }
}

private struct HeadRepository: Decodable {
    let name: String

    public init(name: String) {
        self.name = name
    }
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

    public init(isMergeQueueEnabled: Bool, isInMergeQueue: Bool) {
        self.isMergeQueueEnabled = isMergeQueueEnabled
        self.isInMergeQueue = isInMergeQueue
    }
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

    public init(data: DataPayload) {
        self.data = data
    }
}

private struct WorkflowRunsResponse: Decodable {
    let totalCount: Int?
    let workflowRuns: [WorkflowRun]

    struct WorkflowRun: Decodable {
        let id: Int
        let name: String?
        let status: String?
        let htmlURL: String?

        enum CodingKeys: String, CodingKey {
            case id, name, status
            case htmlURL = "html_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case workflowRuns = "workflow_runs"
    }
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

    public init(bucket: String, completedAt: String?, description: String?, event: String?, link: String?, name: String, startedAt: String?, state: String?, workflow: String?) {
        self.bucket = bucket
        self.completedAt = completedAt
        self.description = description
        self.event = event
        self.link = link
        self.name = name
        self.startedAt = startedAt
        self.state = state
        self.workflow = workflow
    }
}

private struct RunItem: Decodable {
    let databaseId: Int

    public init(databaseId: Int) {
        self.databaseId = databaseId
    }
}

private struct GraphQLRequest<Variables: Encodable>: Encodable {
    let query: String
    let variables: Variables

    public init(query: String, variables: Variables) {
        self.query = query
        self.variables = variables
    }
}

private struct PullRequestNodeVariables: Encodable {
    let owner: String
    let repo: String
    let number: Int

    public init(owner: String, repo: String, number: Int) {
        self.owner = owner
        self.repo = repo
        self.number = number
    }
}

private struct PullRequestNodeResponse: Decodable {
    let data: PullRequestNodeData

    public init(data: PullRequestNodeData) {
        self.data = data
    }
}

private struct PullRequestNodeData: Decodable {
    let repository: PullRequestNodeRepository

    public init(repository: PullRequestNodeRepository) {
        self.repository = repository
    }
}

private struct PullRequestNodeRepository: Decodable {
    let pullRequest: PullRequestNodePullRequest

    public init(pullRequest: PullRequestNodePullRequest) {
        self.pullRequest = pullRequest
    }
}

private struct PullRequestNodePullRequest: Decodable {
    let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct GitHubReviewDraftThreadPayload: Encodable, Equatable, Sendable {
    public let path: String
    public let body: String
    public let line: Int
    public let side: String
    public let startLine: Int?
    public let startSide: String?

    public init(path: String, body: String, line: Int, side: String, startLine: Int?, startSide: String?) {
        self.path = path
        self.body = body
        self.line = line
        self.side = side
        self.startLine = startLine
        self.startSide = startSide
    }
}

private struct PublishReviewVariables: Encodable {
    let input: PublishReviewInput

    public init(input: PublishReviewInput) {
        self.input = input
    }
}

private struct PublishReviewInput: Encodable {
    let pullRequestId: String
    let commitOID: String?
    let event: String
    let body: String
    let threads: [GitHubReviewDraftThreadPayload]

    public init(pullRequestId: String, commitOID: String?, event: String, body: String, threads: [GitHubReviewDraftThreadPayload]) {
        self.pullRequestId = pullRequestId
        self.commitOID = commitOID
        self.event = event
        self.body = body
        self.threads = threads
    }
}

private struct PublishReviewResponse: Decodable {
    let data: PublishReviewData

    public init(data: PublishReviewData) {
        self.data = data
    }
}

private struct PublishReviewData: Decodable {
    let addPullRequestReview: AddPullRequestReviewPayload

    public init(addPullRequestReview: AddPullRequestReviewPayload) {
        self.addPullRequestReview = addPullRequestReview
    }
}

private struct AddPullRequestReviewPayload: Decodable {
    let pullRequestReview: PublishedPullRequestReview

    public init(pullRequestReview: PublishedPullRequestReview) {
        self.pullRequestReview = pullRequestReview
    }
}

private struct PublishedPullRequestReview: Decodable {
    let comments: PublishedReviewCommentsConnection

    public init(comments: PublishedReviewCommentsConnection) {
        self.comments = comments
    }
}

private struct PublishedReviewCommentsConnection: Decodable {
    let nodes: [PublishedReviewCommentNode]

    public init(nodes: [PublishedReviewCommentNode]) {
        self.nodes = nodes
    }
}

private struct PublishedReviewCommentNode: Decodable {
    let id: String?
    let url: String?
    let pullRequestReviewThread: PublishedReviewThreadNode?

    public init(id: String?, url: String?, pullRequestReviewThread: PublishedReviewThreadNode?) {
        self.id = id
        self.url = url
        self.pullRequestReviewThread = pullRequestReviewThread
    }
}

private struct PublishedReviewThreadNode: Decodable {
    let id: String?

    public init(id: String?) {
        self.id = id
    }
}

private struct ThreadReplyVariables: Encodable {
    let input: ThreadReplyInput

    public init(input: ThreadReplyInput) {
        self.input = input
    }
}

private struct ThreadReplyInput: Encodable {
    let pullRequestReviewThreadId: String
    let body: String

    public init(pullRequestReviewThreadId: String, body: String) {
        self.pullRequestReviewThreadId = pullRequestReviewThreadId
        self.body = body
    }
}

private struct ThreadReplyResponse: Decodable {
    let data: ThreadReplyData

    public init(data: ThreadReplyData) {
        self.data = data
    }
}

private struct ThreadReplyData: Decodable {
    let addPullRequestReviewThreadReply: AddPullRequestReviewThreadReplyPayload

    public init(addPullRequestReviewThreadReply: AddPullRequestReviewThreadReplyPayload) {
        self.addPullRequestReviewThreadReply = addPullRequestReviewThreadReply
    }
}

private struct AddPullRequestReviewThreadReplyPayload: Decodable {
    let comment: ThreadReplyComment

    public init(comment: ThreadReplyComment) {
        self.comment = comment
    }
}

private struct ThreadReplyComment: Decodable {
    let id: String?
    let url: String?

    public init(id: String?, url: String?) {
        self.id = id
        self.url = url
    }
}

private struct ThreadStateVariables: Encodable {
    let input: ThreadStateInput

    public init(input: ThreadStateInput) {
        self.input = input
    }
}

private struct ThreadStateInput: Encodable {
    let threadId: String

    public init(threadId: String) {
        self.threadId = threadId
    }
}

private struct ResolveThreadStateResponse: Decodable {
    let data: ResolveThreadStateData

    public init(data: ResolveThreadStateData) {
        self.data = data
    }
}

private struct ResolveThreadStateData: Decodable {
    let resolveReviewThread: ThreadStatePayload

    public init(resolveReviewThread: ThreadStatePayload) {
        self.resolveReviewThread = resolveReviewThread
    }
}

private struct UnresolveThreadStateResponse: Decodable {
    let data: UnresolveThreadStateData

    public init(data: UnresolveThreadStateData) {
        self.data = data
    }
}

private struct UnresolveThreadStateData: Decodable {
    let unresolveReviewThread: ThreadStatePayload

    public init(unresolveReviewThread: ThreadStatePayload) {
        self.unresolveReviewThread = unresolveReviewThread
    }
}

private struct ThreadStatePayload: Decodable {
    let thread: ThreadStateThread

    public init(thread: ThreadStateThread) {
        self.thread = thread
    }
}

private struct ThreadStateThread: Decodable {
    let id: String
    let isResolved: Bool

    public init(id: String, isResolved: Bool) {
        self.id = id
        self.isResolved = isResolved
    }
}

private struct ReviewThreadsResponse: Decodable {
    let data: ReviewThreadsData

    public init(data: ReviewThreadsData) {
        self.data = data
    }
}

private struct ReviewThreadsData: Decodable {
    let repository: ReviewThreadsRepository

    public init(repository: ReviewThreadsRepository) {
        self.repository = repository
    }
}

private struct ReviewThreadsRepository: Decodable {
    let pullRequest: ReviewThreadsPullRequest

    public init(pullRequest: ReviewThreadsPullRequest) {
        self.pullRequest = pullRequest
    }
}

private struct ReviewThreadsPullRequest: Decodable {
    let reviewThreads: ReviewThreadsConnection

    public init(reviewThreads: ReviewThreadsConnection) {
        self.reviewThreads = reviewThreads
    }
}

private struct ReviewThreadsConnection: Decodable {
    let nodes: [ReviewThreadNode]
    let pageInfo: ReviewThreadsPageInfo

    public init(nodes: [ReviewThreadNode], pageInfo: ReviewThreadsPageInfo) {
        self.nodes = nodes
        self.pageInfo = pageInfo
    }
}

private struct ReviewThreadsPage {
    let nodes: [ReviewThreadNode]
    let pageInfo: ReviewThreadsPageInfo

    public init(nodes: [ReviewThreadNode], pageInfo: ReviewThreadsPageInfo) {
        self.nodes = nodes
        self.pageInfo = pageInfo
    }
}

private struct ReviewThreadsPageInfo: Decodable, Equatable {
    let hasNextPage: Bool
    let endCursor: String?

    public init(hasNextPage: Bool, endCursor: String?) {
        self.hasNextPage = hasNextPage
        self.endCursor = endCursor
    }
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

/// `pageInfo` is absent from fixtures and older payloads; absent means the
/// connection holds every comment.
private struct ReviewThreadCommentsConnection: Decodable {
    let nodes: [ReviewThreadCommentNode]
    let pageInfo: ReviewThreadsPageInfo?

    public init(nodes: [ReviewThreadCommentNode], pageInfo: ReviewThreadsPageInfo? = nil) {
        self.nodes = nodes
        self.pageInfo = pageInfo
    }
}

private struct ReviewThreadCommentsResponse: Decodable {
    let data: ReviewThreadCommentsData

    public init(data: ReviewThreadCommentsData) {
        self.data = data
    }
}

private struct ReviewThreadCommentsData: Decodable {
    let node: ReviewThreadCommentsNode

    public init(node: ReviewThreadCommentsNode) {
        self.node = node
    }
}

private struct ReviewThreadCommentsNode: Decodable {
    let comments: ReviewThreadCommentsConnection

    public init(comments: ReviewThreadCommentsConnection) {
        self.comments = comments
    }
}

private struct ReviewThreadCommentsPage {
    let nodes: [ReviewThreadCommentNode]
    let pageInfo: ReviewThreadsPageInfo

    public init(nodes: [ReviewThreadCommentNode], pageInfo: ReviewThreadsPageInfo) {
        self.nodes = nodes
        self.pageInfo = pageInfo
    }
}

private struct ReviewThreadCommentNode: Decodable {
    let id: String?
    let body: String
    let url: String?
    let createdAt: String?
    let diffHunk: String?
    let author: ReviewThreadAuthor?
    let authorAssociation: String?
    let viewerDidAuthor: Bool?

    public init(
        id: String?,
        body: String,
        url: String?,
        createdAt: String?,
        diffHunk: String?,
        author: ReviewThreadAuthor?,
        authorAssociation: String? = nil,
        viewerDidAuthor: Bool?
    ) {
        self.id = id
        self.body = body
        self.url = url
        self.createdAt = createdAt
        self.diffHunk = diffHunk
        self.author = author
        self.authorAssociation = authorAssociation
        self.viewerDidAuthor = viewerDidAuthor
    }
}

private struct GitHubOpenIssueResponse: Decodable {
    let number: Int
    let title: String
    let htmlURL: String
    let createdAt: String
    let pullRequest: GitHubPullRequestMarker?

    enum CodingKeys: String, CodingKey {
        case number
        case title
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case pullRequest = "pull_request"
    }

    public init(number: Int, title: String, htmlURL: String, createdAt: String, pullRequest: GitHubPullRequestMarker?) {
        self.number = number
        self.title = title
        self.htmlURL = htmlURL
        self.createdAt = createdAt
        self.pullRequest = pullRequest
    }
}

private struct GitHubPullRequestMarker: Decodable {
    public init() {
    }}

private struct ReviewThreadAuthor: Decodable {
    let login: String
    /// GraphQL `Actor` concrete type: `User`, `Bot`, `Mannequin`, ...
    let typename: String?

    private enum CodingKeys: String, CodingKey {
        case login
        case typename = "__typename"
    }

    public init(login: String, typename: String? = nil) {
        self.login = login
        self.typename = typename
    }
}

/// One page of `GitHubCLIProvider.reviewersOnHeadQuery`.
public struct ReviewersOnHeadPage {
    fileprivate let pullRequest: ReviewersOnHeadResponse.PullRequest

    /// Where the next page reads each connection from; a connection that
    /// this page skipped or that has no older entries is exhausted.
    fileprivate func cursorsForPreviousPage() throws -> ReviewersOnHeadCursors {
        func position<Node>(_ connection: ReviewersOnHeadResponse.Nodes<Node>?) throws -> ReviewersOnHeadCursors.Position {
            guard let pageInfo = connection?.pageInfo, pageInfo.hasPreviousPage else { return .exhausted }
            guard let startCursor = pageInfo.startCursor, !startCursor.isEmpty else {
                throw CodeHostProviderError.malformedOutput("gh reviewers output is missing a pagination cursor")
            }
            return .before(startCursor)
        }
        return try ReviewersOnHeadCursors(
            includesCommits: false,
            reviews: position(pullRequest.reviews),
            comments: position(pullRequest.comments),
            reactions: position(pullRequest.reactions)
        )
    }
}

private struct ReviewersOnHeadCursors {
    enum Position: Equatable {
        case latest
        case before(String)
        case exhausted
    }

    var includesCommits = true
    var reviews = Position.latest
    var comments = Position.latest
    var reactions = Position.latest

    var isExhausted: Bool {
        [reviews, comments, reactions].allSatisfy { $0 == .exhausted }
    }

    /// `gh api graphql` fields for `reviewersOnHeadQuery`; omitted ones keep
    /// the query's defaults, which read the latest page of everything.
    var arguments: [String] {
        var arguments: [String] = []
        if !includesCommits {
            arguments += ["-F", "withCommits=false"]
        }
        let connections = [
            (cursor: "reviewsBefore", include: "withReviews", position: reviews),
            (cursor: "commentsBefore", include: "withComments", position: comments),
            (cursor: "reactionsBefore", include: "withReactions", position: reactions),
        ]
        for connection in connections {
            switch connection.position {
            case .latest:
                break
            case let .before(cursor):
                arguments += ["-F", "\(connection.cursor)=\(cursor)"]
            case .exhausted:
                arguments += ["-F", "\(connection.include)=false"]
            }
        }
        return arguments
    }
}

private struct ReviewersOnHeadEvidence {
    let lastCommit: ReviewersOnHeadResponse.HeadCommit?
    var reviews: [ReviewersOnHeadResponse.Review] = []
    var comments: [ReviewersOnHeadResponse.Comment] = []
    var reactions: [ReviewersOnHeadResponse.Reaction] = []
}

private struct ReviewersOnHeadResponse: Decodable {
    struct Nodes<Node: Decodable>: Decodable {
        let nodes: [Node]
        let pageInfo: PageInfo?
    }

    struct PageInfo: Decodable {
        let hasPreviousPage: Bool
        let startCursor: String?
    }

    struct Login: Decodable {
        let login: String
    }

    struct CommitOID: Decodable {
        let oid: String
    }

    struct HeadCommit: Decodable {
        let oid: String
        let committedDate: String?
    }

    struct CommitNode: Decodable {
        let commit: HeadCommit
    }

    struct Review: Decodable {
        let author: Login?
        let commit: CommitOID?
    }

    struct Comment: Decodable {
        let author: Login?
        let createdAt: String?
    }

    struct Reaction: Decodable {
        let content: String
        let createdAt: String?
        let user: Login?
    }

    /// A connection is absent when the page skipped it with `@include`.
    struct PullRequest: Decodable {
        let commits: Nodes<CommitNode>?
        let reviews: Nodes<Review>?
        let comments: Nodes<Comment>?
        let reactions: Nodes<Reaction>?
    }

    struct Repository: Decodable {
        let pullRequest: PullRequest
    }

    struct ResponseData: Decodable {
        let repository: Repository
    }

    let data: ResponseData
}

private struct AddPullRequestReviewThreadReplyResponse: Decodable {
    let data: AddPullRequestReviewThreadReplyData

    public init(data: AddPullRequestReviewThreadReplyData) {
        self.data = data
    }
}

private struct AddPullRequestReviewThreadReplyData: Decodable {
    let addPullRequestReviewThreadReply: MutateThreadReplyPayload

    public init(addPullRequestReviewThreadReply: MutateThreadReplyPayload) {
        self.addPullRequestReviewThreadReply = addPullRequestReviewThreadReply
    }
}

private struct MutateThreadReplyPayload: Decodable {
    let comment: ReviewThreadCommentNode

    public init(comment: ReviewThreadCommentNode) {
        self.comment = comment
    }
}

private struct ResolvePullRequestReviewThreadResponse: Decodable {
    let data: ResolvePullRequestReviewThreadData

    public init(data: ResolvePullRequestReviewThreadData) {
        self.data = data
    }
}

private struct ResolvePullRequestReviewThreadData: Decodable {
    let resolveReviewThread: ThreadMutationPayload

    public init(resolveReviewThread: ThreadMutationPayload) {
        self.resolveReviewThread = resolveReviewThread
    }
}

private struct UnresolvePullRequestReviewThreadResponse: Decodable {
    let data: UnresolvePullRequestReviewThreadData

    public init(data: UnresolvePullRequestReviewThreadData) {
        self.data = data
    }
}

private struct UnresolvePullRequestReviewThreadData: Decodable {
    let unresolveReviewThread: ThreadMutationPayload

    public init(unresolveReviewThread: ThreadMutationPayload) {
        self.unresolveReviewThread = unresolveReviewThread
    }
}

private struct ThreadMutationPayload: Decodable {
    let thread: ThreadMutationNode

    public init(thread: ThreadMutationNode) {
        self.thread = thread
    }
}

private struct ThreadMutationNode: Decodable {
    let id: String
    let isResolved: Bool
    let isOutdated: Bool

    public init(id: String, isResolved: Bool, isOutdated: Bool) {
        self.id = id
        self.isResolved = isResolved
        self.isOutdated = isOutdated
    }
}

private struct UpdatePullRequestReviewCommentResponse: Decodable {
    let data: UpdatePullRequestReviewCommentData

    public init(data: UpdatePullRequestReviewCommentData) {
        self.data = data
    }
}

private struct UpdatePullRequestReviewCommentData: Decodable {
    let updatePullRequestReviewComment: UpdatePullRequestReviewCommentPayload

    public init(updatePullRequestReviewComment: UpdatePullRequestReviewCommentPayload) {
        self.updatePullRequestReviewComment = updatePullRequestReviewComment
    }
}

private struct UpdatePullRequestReviewCommentPayload: Decodable {
    let pullRequestReviewComment: ReviewThreadCommentNode

    public init(pullRequestReviewComment: ReviewThreadCommentNode) {
        self.pullRequestReviewComment = pullRequestReviewComment
    }
}

private struct PRNodeIDResponse: Decodable {
    let data: PRNodeIDData

    public init(data: PRNodeIDData) {
        self.data = data
    }
}
private struct PRNodeIDData: Decodable {
    let repository: PRNodeIDRepository

    public init(repository: PRNodeIDRepository) {
        self.repository = repository
    }
}
private struct PRNodeIDRepository: Decodable {
    let pullRequest: PRNodeIDPR

    public init(pullRequest: PRNodeIDPR) {
        self.pullRequest = pullRequest
    }
}
private struct PRNodeIDPR: Decodable {
    let id: String

    public init(id: String) {
        self.id = id
    }
}

private struct AddPullRequestReviewResponse: Decodable {
    let data: AddPullRequestReviewData

    public init(data: AddPullRequestReviewData) {
        self.data = data
    }
}
private struct AddPullRequestReviewData: Decodable {
    let addPullRequestReview: StartReviewPayload

    public init(addPullRequestReview: StartReviewPayload) {
        self.addPullRequestReview = addPullRequestReview
    }
}
private struct StartReviewPayload: Decodable {
    let pullRequestReview: ReviewNodeID

    public init(pullRequestReview: ReviewNodeID) {
        self.pullRequestReview = pullRequestReview
    }
}
private struct ReviewNodeID: Decodable {
    let id: String

    public init(id: String) {
        self.id = id
    }
}

private struct GitHubAnnotationResponse: Decodable {
    let path: String
    let start_line: Int
    let end_line: Int
    let annotation_level: String
    let message: String
    let raw_details: String?

    public init(path: String, start_line: Int, end_line: Int, annotation_level: String, message: String, raw_details: String?) {
        self.path = path
        self.start_line = start_line
        self.end_line = end_line
        self.annotation_level = annotation_level
        self.message = message
        self.raw_details = raw_details
    }
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
    let issueType: String?

    private enum CodingKeys: String, CodingKey {
        case number, title, body, state, labels, assignees
        case issueType = "type"
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
        // Issue types are org-level and optional; an unexpected shape must
        // not make the whole issue unreadable.
        issueType = (try? container.decodeIfPresent(IssueTypeField.self, forKey: .issueType))?.name
    }

    struct Label: Decodable { let name: String? }
    struct IssueTypeField: Decodable { let name: String? }
    struct Assignee: Decodable { let login: String? }
    struct PullRequestMarker: Decodable {}
}

private extension URL {
    var isHTTPOrHTTPS: Bool {
        (scheme == "http" || scheme == "https") && !(host ?? "").isEmpty
    }
}

// MARK: - Reference chip lookup

extension GitHubCLIProvider {
    /// The issues endpoint answers for both issues and pull requests. A PR
    /// carries a `pull_request` object with `merged_at` and a top-level
    /// `draft` flag, so one call is enough.
    public func referenceSummary(
        remote: CodeHostRemote,
        reference: CodeHostReference,
        cwd: URL
    ) async throws -> CodeHostReferenceSummary {
        let result = try await runner.run(
            executable,
            args: ["api", "--hostname", remote.host, "repos/\(remote.repositorySlug)/issues/\(reference.number)"],
            cwd: cwd
        )
        guard result.exitCode == 0 else {
            if let error = CodeHostIssueProviderError.classification(
                provider: kind, remote: remote, number: reference.number, result: result
            ) {
                throw error
            }
            throw CodeHostProviderError.commandFailed(command: "gh api issue", stderr: result.stderr)
        }
        return try Self.parseReferenceSummary(result.stdout, requestedNumber: reference.number)
    }

    public static func parseReferenceSummary(_ json: String, requestedNumber: Int) throws -> CodeHostReferenceSummary {
        struct Response: Decodable {
            struct User: Decodable { let login: String? }
            struct PullRequest: Decodable {
                let mergedAt: String?
                enum CodingKeys: String, CodingKey { case mergedAt = "merged_at" }
            }
            let number: Int
            let title: String
            let state: String
            let draft: Bool?
            let user: User?
            let createdAt: String?
            let updatedAt: String?
            let closedAt: String?
            let htmlURL: String?
            let pullRequest: PullRequest?
            enum CodingKeys: String, CodingKey {
                case number, title, state, draft, user
                case createdAt = "created_at"
                case updatedAt = "updated_at"
                case closedAt = "closed_at"
                case htmlURL = "html_url"
                case pullRequest = "pull_request"
            }
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        } catch {
            throw CodeHostProviderError.malformedOutput("Unable to parse GitHub reference output.")
        }
        guard response.number == requestedNumber,
              let url = try parseOptionalHTTPURL(response.htmlURL, context: "GitHub reference output is missing a valid URL.")
        else {
            throw CodeHostProviderError.malformedOutput("GitHub reference output is missing required fields.")
        }
        let mergedAt = try parseOptionalDate(response.pullRequest?.mergedAt)
        let state: CodeHostReferenceSummary.State
        if mergedAt != nil {
            state = .merged
        } else if response.state.lowercased() == "closed" {
            state = .closed
        } else if response.draft == true {
            state = .draft
        } else {
            state = .open
        }
        return CodeHostReferenceSummary(
            kind: response.pullRequest == nil ? .issue : .reviewRequest,
            number: response.number,
            title: response.title,
            state: state,
            author: response.user?.login,
            createdAt: try parseOptionalDate(response.createdAt),
            updatedAt: try parseOptionalDate(response.updatedAt),
            closedAt: try parseOptionalDate(response.closedAt),
            mergedAt: mergedAt,
            url: url
        )
    }
}
