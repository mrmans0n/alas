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

    @Test func parsesGitHubMergedPRList() throws {
        let json = """
        [
          {"number": 42, "headRefName": "feature/a", "url": "https://github.com/mrmans0n/alas/pull/42", "headRefOid": "abc123"},
          {"number": 43, "headRefName": "feature/b", "url": "https://github.com/mrmans0n/alas/pull/43", "headRefOid": "def456"}
        ]
        """
        let refs = try GitHubCLIProvider.parseMergedPRList(json)
        #expect(refs.count == 2)
        #expect(refs[0] == MergedReviewRequestRef(
            number: 42,
            headRefName: "feature/a",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/42")!,
            headSHA: "abc123"
        ))
        #expect(refs[1].headRefName == "feature/b")
        #expect(refs[1].headSHA == "def456")
    }

    @Test func parsesEmptyGitHubList() throws {
        #expect(try GitHubCLIProvider.parseMergedPRList("[]").isEmpty)
    }

    @Test func rejectsMalformedGitHubOutput() {
        #expect(throws: CodeHostProviderError.self) {
            _ = try GitHubCLIProvider.parseMergedPRList("not json")
        }
    }

    @Test func parsesGitLabMergedMRList() throws {
        let json = """
        [
          {"iid": 7, "source_branch": "feature/a", "web_url": "https://gitlab.com/o/r/-/merge_requests/7", "sha": "abc123"}
        ]
        """
        let refs = try GitLabCLIProvider.parseMergedMRList(json)
        #expect(refs.count == 1)
        #expect(refs[0].number == 7)
        #expect(refs[0].headRefName == "feature/a")
        #expect(refs[0].url == URL(string: "https://gitlab.com/o/r/-/merge_requests/7")!)
        #expect(refs[0].headSHA == "abc123")
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

    @Test func gitHubProviderIssuesOneBatchedQuery() async throws {
        let runner = RecordingRunner(stdout: """
        [{"number": 42, "headRefName": "feature/a", "url": "https://github.com/mrmans0n/alas/pull/42", "headRefOid": "abc123"}]
        """)
        let provider = GitHubCLIProvider(runner: runner)
        let refs = try await provider.mergedReviewRequests(
            remote: Self.remote,
            limit: 200,
            cwd: URL(fileURLWithPath: "/tmp")
        )
        #expect(refs.count == 1)
        #expect(refs[0].headSHA == "abc123")
        let invocations = await runner.invocations
        #expect(invocations.count == 1)
        #expect(invocations[0].args.contains("--state"))
        #expect(invocations[0].args.contains("merged"))
        #expect(invocations[0].args.contains("200"))
        #expect(invocations[0].args.contains { $0.contains("headRefOid") })
    }

    @Test func gitHubProviderThrowsOnNonZeroExit() async {
        let runner = RecordingRunner(stdout: "", stderr: "gh: not authenticated", exitCode: 1)
        let provider = GitHubCLIProvider(runner: runner)
        await #expect(throws: CodeHostProviderError.self) {
            _ = try await provider.mergedReviewRequests(
                remote: Self.remote,
                limit: 200,
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
                limit: 10,
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

    private static func mrPageJSON(count: Int, startingAt: Int) -> String {
        let items = (0..<count).map { offset -> String in
            let number = startingAt + offset
            return """
            {"iid": \(number), "source_branch": "feature/\(number)", "web_url": "https://gitlab.com/o/r/-/merge_requests/\(number)", "sha": "sha\(number)"}
            """
        }
        return "[\(items.joined(separator: ","))]"
    }

    /// `glab mr list` fetches exactly one page per invocation — unlike `gh
    /// pr list --limit`, it has no built-in concept of "keep fetching until
    /// N items." A repository with more merged MRs than one page (100, the
    /// API's own cap) must be paginated manually.
    @Test func gitLabProviderPaginatesBeyondOnePage() async throws {
        let runner = PagedRunner { page in
            switch page {
            case 1: return Self.mrPageJSON(count: 100, startingAt: 1)
            case 2: return Self.mrPageJSON(count: 5, startingAt: 101)
            default: return "[]"
            }
        }
        let provider = GitLabCLIProvider(runner: runner)
        let refs = try await provider.mergedReviewRequests(
            remote: Self.gitlabRemote,
            limit: 1000,
            cwd: URL(fileURLWithPath: "/tmp")
        )
        #expect(refs.count == 105)
        #expect(refs.last?.number == 105)
        let invocations = await runner.invocations
        #expect(invocations.count == 2)   // stops at the short second page
    }

    @Test func gitLabProviderStopsAtTheRequestedLimitAcrossPages() async throws {
        let runner = PagedRunner { page in
            Self.mrPageJSON(count: 100, startingAt: (page - 1) * 100 + 1)
        }
        let provider = GitLabCLIProvider(runner: runner)
        let refs = try await provider.mergedReviewRequests(
            remote: Self.gitlabRemote,
            limit: 150,
            cwd: URL(fileURLWithPath: "/tmp")
        )
        #expect(refs.count == 150)
        let invocations = await runner.invocations
        #expect(invocations.count == 2)   // two full pages reach 200 >= 150
    }
}

/// Returns a page of canned JSON keyed off the `--page` argument, so tests
/// can exercise `GitLabCLIProvider`'s own pagination loop without a network.
private actor PagedRunner: CodeHostCommandRunning {
    struct Invocation: Sendable {
        let executable: String
        let args: [String]
    }

    private(set) var invocations: [Invocation] = []
    private let responseForPage: @Sendable (Int) -> String

    init(responseForPage: @escaping @Sendable (Int) -> String) {
        self.responseForPage = responseForPage
    }

    func run(
        _ executable: String,
        args: [String],
        cwd: URL?,
        stdin: String?
    ) async throws -> ProcessResult {
        invocations.append(Invocation(executable: executable, args: args))
        let page: Int
        if let pageIndex = args.firstIndex(of: "--page"), args.indices.contains(pageIndex + 1) {
            page = Int(args[pageIndex + 1]) ?? 1
        } else {
            page = 1
        }
        return ProcessResult(exitCode: 0, stdout: responseForPage(page), stderr: "")
    }

    func runData(_ executable: String, args: [String], cwd: URL?) async throws -> ProcessResultData {
        invocations.append(Invocation(executable: executable, args: args))
        return ProcessResultData(exitCode: 0, stdout: Data(), stderr: "")
    }
}

private actor RecordingRunner: CodeHostCommandRunning {
    struct Invocation: Sendable {
        let executable: String
        let args: [String]
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
        invocations.append(Invocation(executable: executable, args: args))
        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    func runData(_ executable: String, args: [String], cwd: URL?) async throws -> ProcessResultData {
        invocations.append(Invocation(executable: executable, args: args))
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
