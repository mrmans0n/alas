import Testing
import Foundation
@testable import Alas

struct MergedReviewRequestTests {
    private static let remote = CodeHostRemote(
        kind: .github,
        host: "github.com",
        owner: "mrmans0n",
        repository: "alas",
        remoteName: "origin",
        webURL: URL(string: "https://github.com/mrmans0n/alas")!
    )

    @Test func parsesGitHubMergedPullRequestPages() throws {
        let json = """
        {"data": {"repository": {
          "b0": {"pageInfo": {"hasNextPage": true, "endCursor": "p2"},
                 "nodes": [{"number": 42, "headRefName": "feature/a", "url": "https://github.com/mrmans0n/alas/pull/42", "headRefOid": "abc123"}]},
          "b1": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": []}
        }}}
        """
        let pages = try GitHubCLIProvider.parseMergedPullRequests(json)
        #expect(pages == [
            "b0": .init(
                refs: [MergedReviewRequestRef(
                    number: 42,
                    headRefName: "feature/a",
                    url: URL(string: "https://github.com/mrmans0n/alas/pull/42")!,
                    headSHA: "abc123"
                )],
                nextCursor: "p2"
            ),
            "b1": .init(refs: [], nextCursor: nil),
        ])
    }

    /// A missing repository (renamed, no access) must fail, not read as
    /// "nothing merged".
    @Test(arguments: ["not json", #"{"data": {"repository": null}}"#])
    func rejectsMalformedGitHubOutput(json: String) {
        #expect(throws: CodeHostProviderError.self) {
            _ = try GitHubCLIProvider.parseMergedPullRequests(json)
        }
    }

    @Test func parsesGitLabMergedMergeRequestsPage() throws {
        let json = """
        {"data": {"project": {"mergeRequests": {
          "pageInfo": {"hasNextPage": true, "endCursor": "c1"},
          "nodes": [
            {"iid": "7", "webUrl": "https://gitlab.com/o/r/-/merge_requests/7", "sourceBranch": "feature/a", "diffHeadSha": "abc123"},
            {"iid": "8", "webUrl": "https://gitlab.com/o/r/-/merge_requests/8", "sourceBranch": "feature/b", "diffHeadSha": null}
          ]
        }}}}
        """
        let page = try GitLabCLIProvider.parseMergedMergeRequests(json)
        // A merge request without a head SHA can never pass the scanner's
        // SHA check, so it is dropped rather than carried with a fake one.
        #expect(page.refs == [MergedReviewRequestRef(
            number: 7,
            headRefName: "feature/a",
            url: URL(string: "https://gitlab.com/o/r/-/merge_requests/7")!,
            headSHA: "abc123"
        )])
        #expect(page.nextCursor == "c1")
    }

    @Test func parsesGitHubForkParent() throws {
        let json = """
        {"isFork": true, "parent": {"name": "alas", "owner": {"login": "mrmans0n"}}}
        """
        let parent = try GitHubCLIProvider.parseRepoParent(json, remote: Self.remote)
        #expect(parent?.owner == "mrmans0n")
        #expect(parent?.repository == "alas")
        #expect(parent?.host == "github.com")
        #expect(parent?.kind == .github)
        #expect(parent?.remoteName == "origin")
        #expect(parent?.webURL == URL(string: "https://github.com/mrmans0n/alas")!)
    }

    @Test func gitHubNonForkHasNoParent() throws {
        let json = """
        {"isFork": false, "parent": null}
        """
        let parent = try GitHubCLIProvider.parseRepoParent(json, remote: Self.remote)
        #expect(parent == nil)
    }

    @Test func rejectsMalformedGitHubRepoViewOutput() {
        #expect(throws: CodeHostProviderError.self) {
            _ = try GitHubCLIProvider.parseRepoParent("not json", remote: Self.remote)
        }
    }

    @Test func parsesGitLabForkParent() throws {
        let json = """
        {"forked_from_project": {"path_with_namespace": "upstream-group/upstream-project"}}
        """
        let parent = try GitLabCLIProvider.parseRepoParent(json, remote: Self.remote)
        #expect(parent?.owner == "upstream-group")
        #expect(parent?.repository == "upstream-project")
        #expect(parent?.webURL == URL(string: "https://github.com/upstream-group/upstream-project")!)
    }

    @Test func gitLabNonForkHasNoParent() throws {
        let json = """
        {"forked_from_project": null}
        """
        let parent = try GitLabCLIProvider.parseRepoParent(json, remote: Self.remote)
        #expect(parent == nil)
    }

    @Test func gitHubProviderRepositoryParentIssuesOneQuery() async throws {
        let runner = RecordingRunner(stdout: """
        {"isFork": true, "parent": {"name": "alas", "owner": {"login": "mrmans0n"}}}
        """)
        let provider = GitHubCLIProvider(runner: runner)
        let parent = try await provider.repositoryParent(
            remote: Self.remote,
            cwd: URL(fileURLWithPath: "/tmp")
        )
        #expect(parent?.repository == "alas")
        let invocations = await runner.invocations
        #expect(invocations.count == 1)
        #expect(invocations[0].args.contains("view"))
        #expect(invocations[0].args.contains { $0.contains("parent") })
    }

    /// A provider that can't determine fork status degrades to "not a fork"
    /// rather than throwing — the caller falls back to the original remote
    /// either way, and failing loudly here would only risk breaking the scan
    /// over what is purely an enhancement to it.
    @Test func protocolDefaultRepositoryParentReturnsNil() async throws {
        let provider = MergeQueryUnsupportedProvider()
        let parent = try await provider.repositoryParent(
            remote: Self.remote,
            cwd: URL(fileURLWithPath: "/tmp")
        )
        #expect(parent == nil)
    }

    /// Branch names travel as GraphQL variables, never in the query text, and
    /// a long list is split so no single request grows unbounded.
    @Test func gitHubProviderBatchesBranchesAsVariables() async throws {
        let runner = GitHubGraphQLRunner { body in
            Self.pullRequestsResponse(body.variables.keys.filter { $0.hasPrefix("b") }.map { ($0, [], nil) })
        }
        let provider = GitHubCLIProvider(runner: runner)
        let branches = (0...GitHubCLIProvider.mergedPullRequestsBranchBatchSize).map { "feature/\"\($0)" }
        _ = try await provider.mergedReviewRequests(
            remote: Self.remote,
            headBranches: branches + [branches[0]],
            cwd: URL(fileURLWithPath: "/tmp")
        )
        let requests = await runner.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { !$0.query.contains("feature/") })
        let sent = requests.flatMap { $0.variables.filter { $0.key.hasPrefix("b") }.values }
        #expect(Set(sent) == Set(branches))
        #expect(sent.count == branches.count)
    }

    /// A branch name reused across more merged pull requests than one page
    /// holds is followed to its last page; the matching head can be older.
    @Test func gitHubProviderFollowsEachBranchToItsLastPage() async throws {
        let runner = GitHubGraphQLRunner { body in
            let aliases = body.variables.keys.filter { $0.hasPrefix("b") }
            return Self.pullRequestsResponse(aliases.map { alias in
                let cursor = body.variables["c" + alias.dropFirst()]
                switch (body.variables[alias], cursor) {
                case ("feature/a", nil): return (alias, [1], "p2")
                case ("feature/a", "p2"): return (alias, [2], nil)
                default: return (alias, [], nil)
                }
            })
        }
        let refs = try await GitHubCLIProvider(runner: runner).mergedReviewRequests(
            remote: Self.remote,
            headBranches: ["feature/a", "feature/b"],
            cwd: URL(fileURLWithPath: "/tmp")
        )
        #expect(refs.map(\.number).sorted() == [1, 2])
        let requests = await runner.requests
        #expect(requests.count == 2)
        // Only the branch with more pages is asked again, from its cursor.
        #expect(requests.last?.variables == ["owner": "mrmans0n", "repo": "alas", "b0": "feature/a", "c0": "p2"])
    }

    private static func pullRequestsResponse(_ connections: [(alias: String, numbers: [Int], nextCursor: String?)]) -> String {
        let body = connections.map { alias, numbers, nextCursor in
            let nodes = numbers.map {
                #"{"number": \#($0), "headRefName": "feature/a", "url": "https://github.com/o/r/pull/\#($0)", "headRefOid": "sha\#($0)"}"#
            }.joined(separator: ",")
            let pageInfo = nextCursor.map { #"{"hasNextPage": true, "endCursor": "\#($0)"}"# }
                ?? #"{"hasNextPage": false, "endCursor": null}"#
            return #""\#(alias)": {"pageInfo": \#(pageInfo), "nodes": [\#(nodes)]}"#
        }.joined(separator: ",")
        return #"{"data": {"repository": {\#(body)}}}"#
    }

    @Test func gitHubProviderThrowsOnNonZeroExit() async {
        let runner = RecordingRunner(stdout: "", stderr: "gh: not authenticated", exitCode: 1)
        let provider = GitHubCLIProvider(runner: runner)
        await #expect(throws: CodeHostProviderError.self) {
            _ = try await provider.mergedReviewRequests(
                remote: Self.remote,
                headBranches: ["feature/a"],
                cwd: URL(fileURLWithPath: "/tmp")
            )
        }
    }

    /// The protocol default must fail loudly, not return an empty list — an
    /// empty list would read as "nothing is merged", which is exactly the
    /// silent degradation this feature must avoid.
    @Test func protocolDefaultThrowsUnsupported() async {
        let provider = MergeQueryUnsupportedProvider()
        await #expect(throws: CodeHostProviderError.self) {
            _ = try await provider.mergedReviewRequests(
                remote: Self.remote,
                headBranches: ["feature/a"],
                cwd: URL(fileURLWithPath: "/tmp")
            )
        }
    }

    private static let gitlabRemote = CodeHostRemote(
        kind: .gitlab,
        host: "gitlab.com",
        owner: "o",
        repository: "r",
        remoteName: "origin",
        webURL: URL(string: "https://gitlab.com/o/r")!
    )

    private static func mergeRequestsPageJSON(number: Int, nextCursor: String?) -> String {
        let pageInfo = nextCursor.map { #"{"hasNextPage": true, "endCursor": "\#($0)"}"# }
            ?? #"{"hasNextPage": false, "endCursor": null}"#
        return """
        {"data": {"project": {"mergeRequests": {"pageInfo": \(pageInfo), "nodes": [
          {"iid": "\(number)", "webUrl": "https://gitlab.com/o/r/-/merge_requests/\(number)", "sourceBranch": "feature/\(number)", "diffHeadSha": "sha\(number)"}
        ]}}}}
        """
    }

    @Test func gitLabProviderFollowsCursorUntilLastPage() async throws {
        let runner = CursorRunner { cursor in
            switch cursor {
            case nil: return Self.mergeRequestsPageJSON(number: 1, nextCursor: "c1")
            case "c1": return Self.mergeRequestsPageJSON(number: 2, nextCursor: nil)
            default: return Self.mergeRequestsPageJSON(number: 99, nextCursor: nil)
            }
        }
        let provider = GitLabCLIProvider(runner: runner)
        let refs = try await provider.mergedReviewRequests(
            remote: Self.gitlabRemote,
            headBranches: ["feature/1", "feature/2"],
            cwd: URL(fileURLWithPath: "/tmp")
        )
        #expect(refs.map(\.number) == [1, 2])
        #expect(await runner.cursors == [nil, "c1"])
    }
}

private struct GraphQLBody: Decodable {
    let query: String
    let variables: [String: String]
}

/// Answers GitLab GraphQL requests by the `after` cursor in the request body,
/// so tests exercise `GitLabCLIProvider`'s own paging loop without a network.
private actor CursorRunner: CodeHostCommandRunning {
    private struct Body: Decodable {
        struct Variables: Decodable { let after: String? }
        let variables: Variables
    }

    private(set) var cursors: [String?] = []
    private let responseForCursor: @Sendable (String?) -> String

    init(responseForCursor: @escaping @Sendable (String?) -> String) {
        self.responseForCursor = responseForCursor
    }

    func run(
        _ executable: String,
        args: [String],
        cwd: URL?,
        stdin: String?
    ) async throws -> ProcessResult {
        let cursor = try JSONDecoder().decode(Body.self, from: Data((stdin ?? "").utf8)).variables.after
        cursors.append(cursor)
        return ProcessResult(exitCode: 0, stdout: responseForCursor(cursor), stderr: "")
    }

    func runData(_ executable: String, args: [String], cwd: URL?) async throws -> ProcessResultData {
        ProcessResultData(exitCode: 0, stdout: Data(), stderr: "")
    }
}

/// Answers GitHub GraphQL requests from their decoded body, so tests can
/// respond per alias and per page cursor.
private actor GitHubGraphQLRunner: CodeHostCommandRunning {
    private(set) var requests: [GraphQLBody] = []
    private let respond: @Sendable (GraphQLBody) -> String

    init(respond: @escaping @Sendable (GraphQLBody) -> String) {
        self.respond = respond
    }

    func run(
        _ executable: String,
        args: [String],
        cwd: URL?,
        stdin: String?
    ) async throws -> ProcessResult {
        let body = try JSONDecoder().decode(GraphQLBody.self, from: Data((stdin ?? "").utf8))
        requests.append(body)
        return ProcessResult(exitCode: 0, stdout: respond(body), stderr: "")
    }

    func runData(_ executable: String, args: [String], cwd: URL?) async throws -> ProcessResultData {
        ProcessResultData(exitCode: 0, stdout: Data(), stderr: "")
    }
}

private actor RecordingRunner: CodeHostCommandRunning {
    struct Invocation: Sendable {
        let executable: String
        let args: [String]
        let stdin: String?
    }

    private(set) var invocations: [Invocation] = []
    private let stdout: String
    private let stderr: String
    private let exitCode: Int32

    init(stdout: String, stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    func run(
        _ executable: String,
        args: [String],
        cwd: URL?,
        stdin: String?
    ) async throws -> ProcessResult {
        invocations.append(Invocation(executable: executable, args: args, stdin: stdin))
        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    func runData(_ executable: String, args: [String], cwd: URL?) async throws -> ProcessResultData {
        invocations.append(Invocation(executable: executable, args: args, stdin: nil))
        return ProcessResultData(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: stderr)
    }
}

/// Models a bare-bones `CodeHostProvider` that does not implement
/// `mergedReviewRequests`, to exercise the protocol's default implementation.
/// Mirrors the stub-method shape of `CodeHostProviderTests.FakeCodeHostProvider`.
private struct MergeQueryUnsupportedProvider: CodeHostProvider {
    let kind: CodeHostKind = .github
    let capabilities: CodeHostProviderCapabilities = .readOnly

    func isAvailable(cwd: URL) async -> Bool {
        true
    }

    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool {
        true
    }

    func currentReviewRequest(
        remote: CodeHostRemote,
        branch: String,
        headOwner: String?,
        baseBranch: String,
        cwd: URL
    ) async throws -> ReviewRequest? {
        nil
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
        remote.webURL
    }

    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] {
        []
    }

    func rerunFailedChecks(
        remote: CodeHostRemote,
        branch: String,
        headSHA: String,
        request: ReviewRequest?,
        cwd: URL
    ) async throws {}
}
