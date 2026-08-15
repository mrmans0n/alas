import Foundation
import Testing
@testable import Alas

struct GitHubCLIProviderTests {
    @Test func openIssuesRequestsNewestOpenIssuesAndExcludesPullRequests() async throws {
        let runner = FakeRunner(results: [ProcessResult(
            exitCode: 0,
            stdout: """
            [
              {"number":40,"title":"Older issue","html_url":"https://github.example.com/mrmans0n/alas/issues/40","created_at":"2026-08-10T08:00:00Z"},
              {"number":41,"title":"Pull request","html_url":"https://github.example.com/mrmans0n/alas/pull/41","created_at":"2026-08-12T08:00:00Z","pull_request":{"url":"https://api.github.example.com/repos/mrmans0n/alas/pulls/41","merged_at":null}},
              {"number":42,"title":"Newest issue","html_url":"https://github.example.com/mrmans0n/alas/issues/42","created_at":"2026-08-15T08:00:00Z"}
            ]
            """,
            stderr: ""
        )])

        let issues = try await GitHubCLIProvider(runner: runner).openIssues(
            remote: Self.enterpriseRemote,
            limit: 2,
            cwd: Self.cwd
        )

        #expect(issues.map(\.number) == [42, 40])
        #expect(issues.map(\.title) == ["Newest issue", "Older issue"])
        #expect(await runner.commands.first?.args == [
            "api", "--hostname", "github.example.com", "--method", "GET", "--paginate", "--slurp",
            "repos/mrmans0n/alas/issues",
            "-f", "state=open", "-f", "sort=created", "-f", "direction=desc",
            "-f", "per_page=100",
        ])
    }

    @Test func openIssuesRejectsMalformedCanonicalURL() async {
        let runner = FakeRunner(results: [ProcessResult(
            exitCode: 0,
            stdout: "[{\"number\":42,\"title\":\"Broken\",\"html_url\":\"https:///missing-host\",\"created_at\":\"2026-08-15T08:00:00Z\"}]",
            stderr: ""
        )])

        await #expect(throws: CodeHostProviderError.self) {
            try await GitHubCLIProvider(runner: runner).openIssues(
                remote: Self.enterpriseRemote,
                limit: 50,
                cwd: Self.cwd
            )
        }
    }

    @Test func issueUsesHostAwareAPIAndMapsSnapshot() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.issueOutput, stderr: ""),
        ])

        let issue = try await GitHubCLIProvider(runner: runner).issue(
            remote: Self.enterpriseRemote,
            number: 1842,
            cwd: Self.cwd
        )

        #expect(issue.identity == CodeHostIssueIdentity(
            provider: .github,
            host: "github.example.com",
            repositorySlug: "mrmans0n/alas",
            number: 1842
        ))
        #expect(issue.labels == ["bug", "remote"])
        #expect(issue.assignees == ["nacho"])
        #expect(issue.state == .open)
        #expect(issue.canonicalURL == URL(string: "https://github.example.com/mrmans0n/alas/issues/1842"))
        #expect(await runner.commands.first?.args == [
            "api", "--hostname", "github.example.com", "repos/mrmans0n/alas/issues/1842",
        ])
    }

    @Test func issueClassifiesNotFoundAndPermissionDenied() async {
        let notFoundRunner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "{\"message\":\"Not Found\",\"status\":404}", stderr: "gh: Not Found (HTTP 404)"),
        ])
        let permissionRunner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "gh: Resource not accessible by integration (HTTP 403)"),
        ])

        await #expect(throws: CodeHostIssueProviderError.notFound(
            provider: .github, repositorySlug: "mrmans0n/alas", number: 1842
        )) {
            try await GitHubCLIProvider(runner: notFoundRunner).issue(remote: Self.enterpriseRemote, number: 1842, cwd: Self.cwd)
        }
        await #expect(throws: CodeHostIssueProviderError.permissionDenied(host: "github.example.com")) {
            try await GitHubCLIProvider(runner: permissionRunner).issue(remote: Self.enterpriseRemote, number: 1842, cwd: Self.cwd)
        }
    }

    @Test func issueRejectsURLWithoutHost() async {
        let output = Self.issueOutput.replacingOccurrences(
            of: "https://github.example.com/mrmans0n/alas/issues/1842",
            with: "https:///no-host"
        )
        let runner = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: output, stderr: "")])

        await #expect(throws: CodeHostProviderError.malformedOutput("GitHub issue output is missing a valid URL.")) {
            try await GitHubCLIProvider(runner: runner).issue(remote: Self.enterpriseRemote, number: 1842, cwd: Self.cwd)
        }
    }

    @Test func issueNormalizesIdentityComponents() async throws {
        let remote = CodeHostRemote(
            kind: .github,
            host: "GITHUB.EXAMPLE.COM",
            owner: "MrMans0n",
            repository: "Alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.example.com/MrMans0n/Alas")!
        )
        let runner = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: Self.issueOutput, stderr: "")])

        let issue = try await GitHubCLIProvider(runner: runner).issue(remote: remote, number: 1842, cwd: Self.cwd)

        #expect(issue.identity.host == "github.example.com")
        #expect(issue.identity.repositorySlug == "mrmans0n/alas")
    }

    @Test func issueUsesCanonicalURLIdentityAfterRepositoryRename() async throws {
        let output = Self.issueOutput.replacingOccurrences(
            of: "https://github.example.com/mrmans0n/alas/issues/1842",
            with: "https://github.example.com/openai/renamed-alas/issues/1842"
        )
        let runner = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: output, stderr: "")])

        let issue = try await GitHubCLIProvider(runner: runner).issue(
            remote: Self.enterpriseRemote,
            number: 1842,
            cwd: Self.cwd
        )

        #expect(issue.identity.repositorySlug == "openai/renamed-alas")
    }

    @Test func issuePreservesGenericCommandFailureForUnstructuredNotFoundText() async {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "local cache entry not found"),
        ])

        await #expect(throws: CodeHostProviderError.commandFailed(
            command: "gh api issue", stderr: "local cache entry not found"
        )) {
            try await GitHubCLIProvider(runner: runner).issue(remote: Self.enterpriseRemote, number: 1842, cwd: Self.cwd)
        }
    }

    @Test func prListJSONParsesReviewRequest() throws {
        let request = try #require(try GitHubCLIProvider.parsePRList(
            """
            [
              {
                "number": 42,
                "title": "Add GitHub provider",
                "url": "https://github.com/mrmans0n/alas/pull/42",
                "state": "OPEN",
                "isDraft": false,
                "headRefName": "feature/github-provider",
                "headRefOid": "head-sha-42",
                "baseRefName": "main",
                "baseRefOid": "base-sha-42",
                "reviewDecision": "CHANGES_REQUESTED",
                "mergeStateStatus": "BLOCKED"
              }
            ]
            """,
            remote: Self.remote
        ))

        #expect(request.number == 42)
        #expect(request.title == "Add GitHub provider")
        #expect(request.state == .open)
        #expect(request.reviewDecision == .changesRequested)
        #expect(request.mergeState == .blocked)
        #expect(request.provider == .github)
        #expect(request.baseSHA == "base-sha-42")
        #expect(request.headSHA == "head-sha-42")
        #expect(request.checks.isEmpty)
        #expect(request.threads.isEmpty)
    }

    @Test func prViewJSONParsesHeadSHA() throws {
        let request = try GitHubCLIProvider.parsePRView(Self.prViewOutput, remote: Self.remote)

        #expect(request.number == 42)
        #expect(request.headSHA == "head-sha-42")
    }

    @Test func checksJSONParsesBucketsURLsDatesAndDistinctIDs() throws {
        let checks = try GitHubCLIProvider.parseChecks(
            """
            [
              {
                "bucket": "pass",
                "completedAt": "2026-06-01T12:34:56Z",
                "description": "Unit tests passed",
                "event": "push",
                "link": "https://github.com/mrmans0n/alas/actions/runs/1/job/2",
                "name": "test",
                "startedAt": "2026-06-01T12:30:00Z",
                "state": "SUCCESS",
                "workflow": "CI"
              },
              {
                "bucket": "fail",
                "completedAt": "2026-06-01T12:35:56Z",
                "description": "Unit tests failed",
                "event": "push",
                "link": "https://github.com/mrmans0n/alas/actions/runs/1/job/3",
                "name": "test",
                "startedAt": "2026-06-01T12:31:00Z",
                "state": "FAILURE",
                "workflow": "CI"
              }
            ]
            """
        )

        #expect(checks.map(\.bucket) == [.pass, .fail])
        #expect(checks[0].detailURL == URL(string: "https://github.com/mrmans0n/alas/actions/runs/1/job/2"))
        #expect(checks[0].completedAt == ISO8601DateFormatter().date(from: "2026-06-01T12:34:56Z"))
        #expect(checks[0].name == checks[1].name)
        #expect(checks[0].workflow == checks[1].workflow)
        #expect(checks[0].id != checks[1].id)
    }

    @Test func checkIDsUseUnambiguousEncodingForAllAvailableFields() throws {
        let checks = try GitHubCLIProvider.parseChecks(
            """
            [
              {
                "bucket": "pass",
                "completedAt": "2026-06-01T12:34:56Z",
                "description": "a|b",
                "event": "c",
                "link": "https://github.com/mrmans0n/alas/actions/runs/1/job/2",
                "name": "test",
                "startedAt": "2026-06-01T12:30:00Z",
                "state": "SUCCESS",
                "workflow": "CI"
              },
              {
                "bucket": "pass",
                "completedAt": "2026-06-01T12:34:56Z",
                "description": "a",
                "event": "b|c",
                "link": "https://github.com/mrmans0n/alas/actions/runs/1/job/3",
                "name": "test",
                "startedAt": "2026-06-01T12:30:00Z",
                "state": "SUCCESS",
                "workflow": "CI"
              }
            ]
            """
        )

        #expect(checks[0].id != checks[1].id)
    }

    @Test func createOutputParsesHTTPURL() throws {
        let url = try GitHubCLIProvider.parseCreateOutput("https://github.com/mrmans0n/alas/pull/43\n")

        #expect(url == URL(string: "https://github.com/mrmans0n/alas/pull/43"))
    }

    @Test func qualifiedHeadUsesOwnerOnlyForForkHeads() {
        #expect(GitHubCLIProvider.qualifiedHead(
            branch: "feature/github-provider",
            headOwner: "nacho",
            baseOwner: "mrmans0n"
        ) == "nacho:feature/github-provider")
        #expect(GitHubCLIProvider.qualifiedHead(
            branch: "feature/github-provider",
            headOwner: "mrmans0n",
            baseOwner: "mrmans0n"
        ) == "feature/github-provider")
        #expect(GitHubCLIProvider.qualifiedHead(
            branch: "feature/github-provider",
            headOwner: nil,
            baseOwner: "mrmans0n"
        ) == "feature/github-provider")
    }

    @Test func normalizedBaseBranchStripsDetectedRemotePrefixOnly() {
        #expect(GitHubCLIProvider.normalizedBaseBranch("origin/main", remoteName: "origin") == "main")
        #expect(GitHubCLIProvider.normalizedBaseBranch("upstream/main", remoteName: "origin") == "upstream/main")
        #expect(GitHubCLIProvider.normalizedBaseBranch("release/1.0", remoteName: "origin") == "release/1.0")
    }

    @Test func latestRunIDParsesFirstAndEmptyList() throws {
        let id = try GitHubCLIProvider.parseLatestRunID(
            """
            [
              { "databaseId": 111, "status": "completed", "conclusion": "failure", "url": "https://github.com/runs/111" },
              { "databaseId": 222, "status": "completed", "conclusion": "success", "url": "https://github.com/runs/222" }
            ]
            """
        )

        #expect(id == 111)
        #expect(try GitHubCLIProvider.parseLatestRunID("[]") == nil)
    }

    @Test func runIDsParseAllRuns() throws {
        let ids = try GitHubCLIProvider.parseRunIDs(
            """
            [
              { "databaseId": 111 },
              { "databaseId": 222 }
            ]
            """
        )

        #expect(ids == [111, 222])
    }

    @Test func isAvailableReturnsTrueOnlyForVersionExitZero() async {
        let successRunner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "gh version 2.0.0", stderr: ""),
        ])
        let failureRunner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "missing"),
        ])

        #expect(await GitHubCLIProvider(runner: successRunner).isAvailable(cwd: Self.cwd))
        #expect(await GitHubCLIProvider(runner: failureRunner).isAvailable(cwd: Self.cwd) == false)
        #expect(await successRunner.commands == [
            FakeRunner.Command(executable: "gh", args: ["--version"], cwd: Self.cwd),
        ])
    }

    @Test func currentReviewRequestUsesExpectedCommandArgs() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.prListOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mergeQueueDisabledOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.reviewThreadsOutput, stderr: ""),
        ])

        let request = try await GitHubCLIProvider(runner: runner).currentReviewRequest(
            remote: Self.remote,
            branch: "feature/github-provider",
            headOwner: nil,
            baseBranch: "origin/main",
            cwd: Self.cwd
        )

        #expect(request?.number == 42)
        #expect(request?.threads.count == 2)
        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "pr", "list",
                    "--head", "feature/github-provider",
                    "--base", "main",
                    "--state", "open",
                    "--limit", "20",
                    "--json", "number,title,url,state,isDraft,headRefName,headRefOid,headRepositoryOwner,headRepository,baseRefName,baseRefOid,reviewDecision,mergeStateStatus",
                    "-R", "mrmans0n/alas",
                ],
                cwd: Self.cwd
            ),
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "api", "graphql",
                    "--hostname", "github.com",
                    "-f", "owner=mrmans0n",
                    "-f", "name=alas",
                    "-F", "number=42",
                    "-f", "query=\(Self.mergeQueueMetadataQuery)",
                ],
                cwd: Self.cwd
            ),
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "api", "graphql",
                    "--hostname", "github.com",
                    "-f", "query=\(GitHubCLIProvider.reviewThreadsQuery)",
                    "-F", "owner=mrmans0n",
                    "-F", "repo=alas",
                    "-F", "number=42",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func missionReviewRequestIncludesCompletedPullRequests() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.prListOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mergeQueueDisabledOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.reviewThreadsOutput, stderr: ""),
        ])

        let request = try await GitHubCLIProvider(runner: runner).missionReviewRequest(
            remote: Self.remote,
            branch: "feature/github-provider",
            headOwner: nil,
            baseBranch: "origin/main",
            cwd: Self.cwd
        )

        #expect(request?.number == 42)
        #expect(await runner.commands.first?.args.contains("all") == true)
        #expect(await runner.commands.first?.args.contains("open") == false)
    }

    @Test func missionReviewRequestPreservesAnUnqualifiedSlashBaseMatchingTheRemoteName() async throws {
        let remote = CodeHostRemote(
            kind: .github,
            host: Self.remote.host,
            owner: Self.remote.owner,
            repository: Self.remote.repository,
            remoteName: "release",
            webURL: Self.remote.webURL
        )
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "[]", stderr: ""),
        ])

        _ = try await GitHubCLIProvider(runner: runner).missionReviewRequest(
            remote: remote,
            branch: "feature/github-provider",
            headOwner: nil,
            baseBranch: "release/1.0",
            cwd: Self.cwd
        )

        let args = try #require(await runner.commands.first?.args)
        let baseIndex = try #require(args.firstIndex(of: "--base"))
        #expect(args[baseIndex + 1] == "release/1.0")
    }

    @Test func missionReviewRequestPrefersMergedPullRequestOverClosedMatch() async throws {
        let listOutput = """
        [
          {
            "number": 43,
            "title": "Closed replacement",
            "url": "https://github.com/mrmans0n/alas/pull/43",
            "state": "CLOSED",
            "isDraft": false,
            "headRefName": "feature/github-provider",
            "headRefOid": "head-sha-42",
            "baseRefName": "main",
            "baseRefOid": "base-sha-42",
            "reviewDecision": "",
            "mergeStateStatus": "UNKNOWN"
          },
          {
            "number": 42,
            "title": "Merged change",
            "url": "https://github.com/mrmans0n/alas/pull/42",
            "state": "MERGED",
            "isDraft": false,
            "headRefName": "feature/github-provider",
            "headRefOid": "head-sha-42",
            "baseRefName": "main",
            "baseRefOid": "base-sha-42",
            "reviewDecision": "APPROVED",
            "mergeStateStatus": "UNKNOWN"
          }
        ]
        """
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: listOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mergeQueueDisabledOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.reviewThreadsOutput, stderr: ""),
        ])

        let request = try await GitHubCLIProvider(runner: runner).missionReviewRequest(
            remote: Self.remote,
            branch: "feature/github-provider",
            headOwner: nil,
            baseBranch: "origin/main",
            headSHA: "head-sha-42",
            cwd: Self.cwd
        )

        #expect(request?.number == 42)
        #expect(request?.state == .merged)
    }

    @Test func currentReviewRequestEnrichesMergeQueueMetadata() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.prListOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mergeQueueEnabledOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.reviewThreadsOutput, stderr: ""),
        ])

        let request = try await GitHubCLIProvider(runner: runner).currentReviewRequest(
            remote: Self.remote,
            branch: "feature/github-provider",
            headOwner: nil,
            baseBranch: "main",
            cwd: Self.cwd
        )

        #expect(request?.isMergeQueueEnabled == true)
        #expect(request?.isInMergeQueue == true)
        #expect(request?.threads.count == 2)
        #expect(await runner.commands.map(\.args) == [
            [
                "pr", "list",
                "--head", "feature/github-provider",
                "--base", "main",
                "--state", "open",
                "--limit", "20",
                "--json", "number,title,url,state,isDraft,headRefName,headRefOid,headRepositoryOwner,headRepository,baseRefName,baseRefOid,reviewDecision,mergeStateStatus",
                "-R", "mrmans0n/alas",
            ],
            [
                "api", "graphql",
                "--hostname", "github.com",
                "-f", "owner=mrmans0n",
                "-f", "name=alas",
                "-F", "number=42",
                "-f", "query=\(Self.mergeQueueMetadataQuery)",
            ],
            [
                "api", "graphql",
                "--hostname", "github.com",
                "-f", "query=\(GitHubCLIProvider.reviewThreadsQuery)",
                "-F", "owner=mrmans0n",
                "-F", "repo=alas",
                "-F", "number=42",
            ],
        ])
    }

    @Test func reviewDiffUsesPRDiffCommand() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "diff --git a/A.swift b/A.swift\n", stderr: ""),
        ])
        let request = try #require(try GitHubCLIProvider.parsePRList(Self.prListOutput, remote: Self.remote))

        let diff = try await GitHubCLIProvider(runner: runner).reviewDiff(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )

        #expect(diff == "diff --git a/A.swift b/A.swift\n")
        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "gh",
                args: ["pr", "diff", "42", "-R", "mrmans0n/alas"],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func reviewImageRevisionsAndRawFileDataUseExactForkRevisionBeyondOneMegabyte() async throws {
        let rawImage = String(repeating: "a", count: 1_048_577)
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: #"{"merge_base_commit":{"sha":"base-sha"}}"#, stderr: ""),
            ProcessResult(exitCode: 0, stdout: rawImage, stderr: ""),
        ])
        let request = Self.makeRequest(
            baseSHA: "base-sha",
            headSHA: "head-sha",
            headRepositoryOwner: "fork-owner",
            headRepositoryName: "alas-fork"
        )
        let provider = GitHubCLIProvider(runner: runner)

        let revisions = try await provider.reviewImageRevisions(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )
        let data = try await provider.reviewFileData(
            remote: Self.remote,
            repository: "fork-owner/alas-fork",
            revision: revisions.afterSHA,
            path: "Assets/Diff image.png",
            cwd: Self.cwd
        )

        #expect(revisions == CodeHostReviewImageRevisions(
            beforeSHA: "base-sha",
            afterSHA: "head-sha"
        ))
        #expect(data == Data(rawImage.utf8))
        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "api",
                    "--hostname", "github.com",
                    "repos/mrmans0n/alas/compare/base-sha...head-sha",
                ],
                cwd: Self.cwd
            ),
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "api",
                    "--hostname", "github.com",
                    "--method", "GET",
                    "--header", "Accept: application/vnd.github.raw+json",
                    "repos/fork-owner/alas-fork/contents/Assets%2FDiff%20image.png?ref=head-sha",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func reviewFileDataSurfacesRawRouteFailure() async {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "request failed"),
        ])

        await #expect(throws: CodeHostProviderError.commandFailed(command: "gh api contents", stderr: "request failed")) {
            _ = try await GitHubCLIProvider(runner: runner).reviewFileData(
                remote: Self.remote,
                repository: "mrmans0n/alas",
                revision: "head-sha",
                path: "Assets/Diff image.png",
                cwd: Self.cwd
            )
        }
    }

    @Test func reviewDiffSurfacesGitHubCommandFailure() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "not found"),
        ])
        let request = try #require(try GitHubCLIProvider.parsePRList(Self.prListOutput, remote: Self.remote))

        await #expect(throws: CodeHostProviderError.commandFailed(command: "gh pr diff", stderr: "not found")) {
            _ = try await GitHubCLIProvider(runner: runner).reviewDiff(
                remote: Self.remote,
                request: request,
                cwd: Self.cwd
            )
        }
    }

    @Test func currentReviewRequestKeepsRequestWhenReviewThreadFetchFails() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.prListOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mergeQueueDisabledOutput, stderr: ""),
            ProcessResult(exitCode: 1, stdout: "", stderr: "GraphQL field unavailable"),
        ])

        let request = try await GitHubCLIProvider(runner: runner).currentReviewRequest(
            remote: Self.remote,
            branch: "feature/github-provider",
            headOwner: nil,
            baseBranch: "main",
            cwd: Self.cwd
        )

        #expect(request?.number == 42)
        #expect(request?.threads == [])
        #expect(await runner.commands.count == 3)
    }

    @Test func currentReviewRequestPagesReviewThreads() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.prListOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mergeQueueDisabledOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.reviewThreadsFirstPageOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.reviewThreadsSecondPageOutput, stderr: ""),
        ])

        let request = try await GitHubCLIProvider(runner: runner).currentReviewRequest(
            remote: Self.remote,
            branch: "feature/github-provider",
            headOwner: nil,
            baseBranch: "main",
            cwd: Self.cwd
        )

        #expect(request?.threads.map(\.id) == ["thread-page-1", "thread-page-2"])
        let commands = await runner.commands
        #expect(commands.count == 4)
        #expect(!commands[2].args.contains("-F cursor=cursor-1"))
        #expect(commands[3].args.contains("-F"))
        #expect(commands[3].args.contains("cursor=cursor-1"))
    }

    @Test func reviewThreadsJSONParsesActionableSummaries() throws {
        let threads = try GitHubCLIProvider.parseReviewThreads(Self.reviewThreadsOutput)

        #expect(threads.count == 2)
        #expect(threads[0].id == "thread-1")
        #expect(threads[0].author == "reviewer")
        #expect(threads[0].body == "Please tighten this branch lookup.")
        #expect(threads[0].url == URL(string: "https://github.com/mrmans0n/alas/pull/42#discussion_r1"))
        #expect(threads[0].isResolved == false)
        #expect(threads[0].isActionable == true)
        #expect(threads[0].comments.first?.id == "comment-1")
        #expect(threads[1].isResolved == false)
        #expect(threads[1].isActionable == false)
    }

    @Test func githubPublishReviewUsesGraphQLPayloadAndRefreshesPR() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.pullRequestNodeOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.publishReviewMutationOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.prViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mergeQueueDisabledOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.reviewThreadsOutput, stderr: ""),
        ])
        let provider = GitHubCLIProvider(runner: runner)

        let result = try await provider.publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            comments: [
                Self.makeProviderDraftComment(
                    id: "draft-1",
                    path: "Sources/App.swift",
                    side: .new,
                    startLine: 12,
                    endLine: 14,
                    body: "Please simplify this."
                ),
                Self.makeProviderDraftComment(
                    id: "draft-unknown",
                    path: "Sources/App.swift",
                    side: .unknown,
                    startLine: 20,
                    endLine: nil,
                    body: "This should not be posted to the wrong side."
                ),
            ],
            decision: .requestChanges,
            summaryBody: "Please update this before merge.",
            cwd: Self.cwd
        ))

        let commands = await runner.commands
        #expect(commands.count == 5)
        #expect(commands[0].args == ["api", "graphql", "--hostname", "github.com", "--input", "-"])
        #expect(commands[1].args == ["api", "graphql", "--hostname", "github.com", "--input", "-"])
        #expect(commands[0].stdin?.contains("pullRequest(number: $number)") == true)
        let publishVariables = try Self.graphQLVariables(from: commands[1].stdin)
        let publishInput = try #require(publishVariables["input"] as? [String: Any])
        let publishThreads = try #require(publishInput["threads"] as? [[String: Any]])
        #expect(publishInput["comments"] == nil)
        #expect(publishThreads.count == 1)
        #expect(publishInput["pullRequestId"] as? String == "PR_node_42")
        #expect(publishInput["commitOID"] as? String == "head-sha-42")
        #expect(publishInput["event"] as? String == "REQUEST_CHANGES")
        #expect(publishThreads.first?["path"] as? String == "Sources/App.swift")
        #expect(publishThreads.first?["line"] as? Int == 14)
        #expect(publishThreads.first?["side"] as? String == "RIGHT")
        #expect(publishThreads.first?["startLine"] as? Int == 12)
        #expect(publishThreads.first?["startSide"] as? String == "RIGHT")
        #expect(commands[2].args == [
            "pr", "view", "42",
            "--json", "number,title,url,state,isDraft,headRefName,headRefOid,headRepositoryOwner,headRepository,baseRefName,baseRefOid,reviewDecision,mergeStateStatus",
            "-R", "mrmans0n/alas",
        ])
        #expect(commands[3].args == [
            "api", "graphql",
            "--hostname", "github.com",
            "-f", "owner=mrmans0n",
            "-f", "name=alas",
            "-F", "number=42",
            "-f", "query=\(Self.mergeQueueMetadataQuery)",
        ])
        #expect(result.published == [
            ProviderReviewPublishedComment(
                localDraftID: "draft-1",
                providerThreadID: "PRRT_thread_1",
                providerCommentID: "PRRC_comment_1",
                providerURL: URL(string: "https://github.com/mrmans0n/alas/pull/42#discussion_r1")
            ),
        ])
        #expect(result.failed == [
            ProviderReviewFailedComment(
                localDraftID: "draft-unknown",
                message: "GitHub review comments require an old or new side."
            ),
        ])
        #expect(result.refreshedRequest.number == 42)
        #expect(result.refreshedRequest.threads.count == 2)
    }

    @Test func githubPublishReviewRetriesIndividuallyAfterBatchRejection() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.pullRequestNodeOutput, stderr: ""),
            ProcessResult(exitCode: 1, stdout: "", stderr: "line is not commentable"),
            ProcessResult(exitCode: 0, stdout: Self.publishReviewMutationOutput, stderr: ""),
            ProcessResult(exitCode: 1, stdout: "", stderr: "line is not commentable"),
            ProcessResult(exitCode: 0, stdout: Self.prViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mergeQueueDisabledOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.reviewThreadsOutput, stderr: ""),
        ])
        let provider = GitHubCLIProvider(runner: runner)

        let result = try await provider.publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            comments: [
                Self.makeProviderDraftComment(
                    id: "draft-good",
                    path: "Sources/App.swift",
                    side: .new,
                    startLine: 12,
                    endLine: nil,
                    body: "Please simplify this."
                ),
                Self.makeProviderDraftComment(
                    id: "draft-bad",
                    path: "Sources/Other.swift",
                    side: .new,
                    startLine: 99,
                    endLine: nil,
                    body: "This anchor is stale."
                ),
            ],
            decision: .requestChanges,
            summaryBody: "Please update this before merge.",
            cwd: Self.cwd
        ))

        let commands = await runner.commands
        #expect(commands.count == 7)
        let batchVariables = try Self.graphQLVariables(from: commands[1].stdin)
        let batchInput = try #require(batchVariables["input"] as? [String: Any])
        let batchThreads = try #require(batchInput["threads"] as? [[String: Any]])
        #expect(batchInput["event"] as? String == "REQUEST_CHANGES")
        #expect(batchThreads.count == 2)

        let retryVariables = try Self.graphQLVariables(from: commands[2].stdin)
        let retryInput = try #require(retryVariables["input"] as? [String: Any])
        let retryThreads = try #require(retryInput["threads"] as? [[String: Any]])
        #expect(retryInput["event"] as? String == "COMMENT")
        #expect(retryInput["body"] as? String == "")
        #expect(retryThreads.count == 1)
        #expect(result.published.map(\.localDraftID) == ["draft-good"])
        #expect(result.failed.map(\.localDraftID) == ["draft-bad"])
        #expect(result.failed.first?.message.contains("line is not commentable") == true)
        #expect(result.warnings.contains {
            $0.contains("retried publishable comments individually")
        })
    }

    @Test func githubPublishReviewDoesNotFailDraftsPastReturnedCommentWindow() async throws {
        let drafts = try (1...101).map { index in
            try Self.makeProviderDraftComment(
                id: "draft-\(index)",
                path: "Sources/App.swift",
                side: .new,
                startLine: index,
                endLine: nil,
                body: "Comment \(index)"
            )
        }
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.pullRequestNodeOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.publishReviewMutationOutput(commentCount: 100), stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.prViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mergeQueueDisabledOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.reviewThreadsOutput, stderr: ""),
        ])
        let provider = GitHubCLIProvider(runner: runner)

        let result = try await provider.publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            comments: drafts,
            decision: .comment,
            summaryBody: "Review notes.",
            cwd: Self.cwd
        ))

        #expect(result.failed.isEmpty)
        #expect(result.published.map(\.localDraftID) == drafts.map(\.localDraftID))
        #expect(result.published[99].providerCommentID == "PRRC_comment_100")
        #expect(result.published[100].providerCommentID == nil)
        #expect(result.warnings.contains {
            $0.contains("GitHub returned only the first 100 review comments")
        })
    }

    @Test func githubPublishReviewDoesNotRetryAfterMalformedSuccessfulBatchResponse() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.pullRequestNodeOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: #"{"data":{}}"#, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.prViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mergeQueueDisabledOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.reviewThreadsOutput, stderr: ""),
        ])
        let provider = GitHubCLIProvider(runner: runner)

        let result = try await provider.publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            comments: [
                Self.makeProviderDraftComment(
                    id: "draft-1",
                    path: "Sources/App.swift",
                    side: .new,
                    startLine: 12,
                    endLine: nil,
                    body: "Please simplify this."
                ),
                Self.makeProviderDraftComment(
                    id: "draft-2",
                    path: "Sources/Other.swift",
                    side: .new,
                    startLine: 99,
                    endLine: nil,
                    body: "This anchor is stale."
                ),
            ],
            decision: .requestChanges,
            summaryBody: "Please update this before merge.",
            cwd: Self.cwd
        ))

        let commands = await runner.commands
        #expect(commands.count == 5)
        let publishVariables = try Self.graphQLVariables(from: commands[1].stdin)
        let publishInput = try #require(publishVariables["input"] as? [String: Any])
        let publishThreads = try #require(publishInput["threads"] as? [[String: Any]])
        #expect(publishInput["event"] as? String == "REQUEST_CHANGES")
        #expect(publishThreads.count == 2)
        #expect(commands[2].args.first == "pr")
        #expect(result.published.isEmpty)
        #expect(result.failed.map(\.localDraftID) == ["draft-1", "draft-2"])
        #expect(result.failed.allSatisfy {
            $0.message.contains("Unable to parse gh publish review output")
        })
        #expect(result.warnings.contains {
            $0.contains("GitHub request changes review was not submitted")
        })
        #expect(result.refreshedRequest.number == 42)
    }

    @Test func githubPublishReviewDoesNotSubmitDecisionWhenNoDraftsArePublishable() async throws {
        let runner = FakeRunner(results: [])
        let provider = GitHubCLIProvider(runner: runner)

        let result = try await provider.publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            comments: [
                Self.makeProviderDraftComment(
                    id: "draft-unknown",
                    path: "Sources/App.swift",
                    side: .unknown,
                    startLine: 20,
                    endLine: nil,
                    body: "This should not submit a review decision."
                ),
            ],
            decision: .requestChanges,
            summaryBody: "Please update this before merge.",
            cwd: Self.cwd
        ))

        let commands = await runner.commands
        #expect(commands.isEmpty)
        #expect(result.published.isEmpty)
        #expect(result.failed == [
            ProviderReviewFailedComment(
                localDraftID: "draft-unknown",
                message: "GitHub review comments require an old or new side."
            ),
        ])
        #expect(result.refreshedRequest.number == 42)
    }

    @Test func githubPublishReviewSubmitsDecisionWhenNoDraftCommentsExist() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.pullRequestNodeOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.publishReviewMutationWithoutCommentsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.prViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mergeQueueDisabledOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.reviewThreadsOutput, stderr: ""),
        ])
        let provider = GitHubCLIProvider(runner: runner)

        let result = try await provider.publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            comments: [],
            decision: .approve,
            summaryBody: "Looks good.",
            cwd: Self.cwd
        ))

        let commands = await runner.commands
        #expect(commands.count == 5)
        let publishVariables = try Self.graphQLVariables(from: commands[1].stdin)
        let publishInput = try #require(publishVariables["input"] as? [String: Any])
        let publishThreads = try #require(publishInput["threads"] as? [[String: Any]])
        #expect(publishInput["event"] as? String == "APPROVE")
        #expect(publishInput["body"] as? String == "Looks good.")
        #expect(publishThreads.isEmpty)
        #expect(result.published.isEmpty)
        #expect(result.failed.isEmpty)
        #expect(result.refreshedRequest.number == 42)
    }

    @Test func githubPublishReviewThrowsDecisionOnlyReviewFailure() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.pullRequestNodeOutput, stderr: ""),
            ProcessResult(exitCode: 1, stdout: "", stderr: "GraphQL: Resource not accessible by integration"),
        ])
        let provider = GitHubCLIProvider(runner: runner)

        await #expect(throws: CodeHostProviderError.commandFailed(
            command: "gh api graphql",
            stderr: "GraphQL: Resource not accessible by integration"
        )) {
            _ = try await provider.publishReview(ProviderReviewPublishRequest(
                remote: Self.remote,
                reviewRequest: Self.makeRequest(),
                comments: [],
                decision: .approve,
                summaryBody: "Looks good.",
                cwd: Self.cwd
            ))
        }

        let commands = await runner.commands
        #expect(commands.count == 2)
    }

    @Test func githubPublishReviewPreservesMappingsWhenRefreshFails() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.pullRequestNodeOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.publishReviewMutationOutput, stderr: ""),
            ProcessResult(exitCode: 1, stdout: "", stderr: "temporary API failure"),
        ])
        let provider = GitHubCLIProvider(runner: runner)

        let result = try await provider.publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            comments: [
                Self.makeProviderDraftComment(
                    id: "draft-1",
                    path: "Sources/App.swift",
                    side: .new,
                    startLine: 12,
                    endLine: nil,
                    body: "Please simplify this."
                ),
            ],
            decision: .comment,
            summaryBody: "Review notes.",
            cwd: Self.cwd
        ))

        #expect(result.published.map(\.localDraftID) == ["draft-1"])
        #expect(result.failed.isEmpty)
        #expect(result.refreshedRequest == Self.makeRequest())
        #expect(result.warnings.contains {
            $0.contains("could not refresh the PR")
        })
    }

    @Test func githubThreadMutationsUseGraphQLAndRefreshPR() async throws {
        let thread = ReviewThreadSummary(
            id: "thread-1",
            author: "reviewer",
            body: "Please tighten this branch lookup.",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/42#discussion_r1"),
            isResolved: false,
            isActionable: true,
            providerThreadID: "PRRT_thread_1",
            providerCommentID: "PRRC_comment_1"
        )
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.replyMutationOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.prViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mergeQueueDisabledOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.reviewThreadsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.resolveThreadMutationOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.prViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mergeQueueDisabledOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.reviewThreadsOutput, stderr: ""),
        ])
        let provider = GitHubCLIProvider(runner: runner)

        let replyResult = try await provider.mutateReviewThread(ProviderThreadMutation(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            thread: thread,
            kind: .reply,
            bodyMarkdown: "Thanks, fixed.",
            cwd: Self.cwd
        ))
        let resolveResult = try await provider.mutateReviewThread(ProviderThreadMutation(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            thread: thread,
            kind: .resolve,
            bodyMarkdown: nil,
            cwd: Self.cwd
        ))

        let commands = await runner.commands
        #expect(commands[0].args == ["api", "graphql", "--hostname", "github.com", "--input", "-"])
        #expect(commands[1].args == [
            "pr", "view", "42",
            "--json", "number,title,url,state,isDraft,headRefName,headRefOid,headRepositoryOwner,headRepository,baseRefName,baseRefOid,reviewDecision,mergeStateStatus",
            "-R", "mrmans0n/alas",
        ])
        #expect(commands[4].args == ["api", "graphql", "--hostname", "github.com", "--input", "-"])
        #expect(commands[5].args == [
            "pr", "view", "42",
            "--json", "number,title,url,state,isDraft,headRefName,headRefOid,headRepositoryOwner,headRepository,baseRefName,baseRefOid,reviewDecision,mergeStateStatus",
            "-R", "mrmans0n/alas",
        ])
        #expect(commands[0].stdin?.contains("addPullRequestReviewThreadReply") == true)
        #expect(commands[0].stdin?.contains("\"pullRequestReviewThreadId\":\"PRRT_thread_1\"") == true)
        #expect(commands[4].stdin?.contains("resolveReviewThread") == true)
        #expect(commands[4].stdin?.contains("\"threadId\":\"PRRT_thread_1\"") == true)
        #expect(replyResult.providerURL == URL(string: "https://github.com/mrmans0n/alas/pull/42#discussion_r2"))
        #expect(replyResult.refreshedRequest.number == 42)
        #expect(resolveResult.refreshedRequest.number == 42)
    }

    @Test func githubGraphQLAPIArgsIncludeSelectedRemoteHost() {
        let enterpriseRemote = CodeHostRemote(
            kind: .github,
            host: "github.enterprise.example.com",
            owner: "platform",
            repository: "alas",
            remoteName: "enterprise",
            webURL: URL(string: "https://github.enterprise.example.com/platform/alas")!
        )

        #expect(GitHubCLIProvider.graphQLAPIStdinArgs(remote: enterpriseRemote) == [
            "api", "graphql", "--hostname", "github.enterprise.example.com", "--input", "-",
        ])
    }

    @Test func githubRefreshUsesHostQualifiedRepositoryForEnterpriseRemote() async throws {
        let enterpriseRemote = CodeHostRemote(
            kind: .github,
            host: "github.enterprise.example.com",
            owner: "platform",
            repository: "alas",
            remoteName: "enterprise",
            webURL: URL(string: "https://github.enterprise.example.com/platform/alas")!
        )
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.prViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mergeQueueDisabledOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.reviewThreadsOutput, stderr: ""),
        ])
        let provider = GitHubCLIProvider(runner: runner)

        _ = try await provider.reviewRequest(remote: enterpriseRemote, number: 42, cwd: Self.cwd)

        let commands = await runner.commands
        #expect(commands.count == 3)
        #expect(commands[0].args == [
            "pr", "view", "42",
            "--json", "number,title,url,state,isDraft,headRefName,headRefOid,headRepositoryOwner,headRepository,baseRefName,baseRefOid,reviewDecision,mergeStateStatus",
            "-R", "github.enterprise.example.com/platform/alas",
        ])
        #expect(commands[1].args == [
            "api", "graphql",
            "--hostname", "github.enterprise.example.com",
            "-f", "owner=platform",
            "-f", "name=alas",
            "-F", "number=42",
            "-f", "query=\(Self.mergeQueueMetadataQuery)",
        ])
        #expect(commands[2].args.prefix(3) == ["api", "graphql", "--hostname"])
        #expect(commands[2].args.contains("github.enterprise.example.com"))
        #expect(commands[2].args.contains("owner=platform"))
        #expect(commands[2].args.contains("repo=alas"))
    }

    @Test func githubThreadMutationPreservesSuccessfulReplyWhenRefreshFails() async throws {
        let thread = ReviewThreadSummary(
            id: "thread-1",
            author: "reviewer",
            body: "Please tighten this branch lookup.",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/42#discussion_r1"),
            isResolved: false,
            isActionable: true,
            providerThreadID: "PRRT_thread_1",
            providerCommentID: "PRRC_comment_1"
        )
        let originalRequest = Self.makeRequest()
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.replyMutationOutput, stderr: ""),
            ProcessResult(exitCode: 1, stdout: "", stderr: "temporary API failure"),
        ])
        let provider = GitHubCLIProvider(runner: runner)

        let replyResult = try await provider.mutateReviewThread(ProviderThreadMutation(
            remote: Self.remote,
            reviewRequest: originalRequest,
            thread: thread,
            kind: .reply,
            bodyMarkdown: "Thanks, fixed.",
            cwd: Self.cwd
        ))

        let commands = await runner.commands
        #expect(commands.count == 2)
        #expect(commands[0].stdin?.contains("addPullRequestReviewThreadReply") == true)
        #expect(commands[1].args.first == "pr")
        #expect(replyResult.providerURL == URL(string: "https://github.com/mrmans0n/alas/pull/42#discussion_r2"))
        #expect(replyResult.refreshedRequest == originalRequest)
        #expect(replyResult.warnings.contains {
            $0.contains("GitHub thread was updated, but Alas could not refresh the PR")
        })
    }

    @Test func reviewThreadsJSONPreservesLocationMetadata() throws {
        let threads = try GitHubCLIProvider.parseReviewThreads(
            """
            {
              "data": {
                "repository": {
                  "pullRequest": {
                    "reviewThreads": {
                      "nodes": [
                        {
                          "id": "PRRT_kwDO",
                          "isResolved": false,
                          "isOutdated": false,
                          "path": "Sources/App.swift",
                          "line": 56,
                          "originalLine": null,
                          "diffSide": "RIGHT",
                          "comments": {
                            "nodes": [
                              {
                                "id": "PRRC_kwDO",
                                "body": "Please simplify this.",
                                "url": "https://github.com/mrmans0n/alas/pull/1#discussion_r1",
                                "author": { "login": "reviewer" }
                              }
                            ]
                          }
                        }
                      ],
                      "pageInfo": { "hasNextPage": false, "endCursor": null }
                    }
                  }
                }
              }
            }
            """
        )

        #expect(threads.first?.path == "Sources/App.swift")
        #expect(threads.first?.line == 56)
        #expect(threads.first?.id == "PRRT_kwDO")
    }

    @Test func reviewThreadsJSONIgnoresMalformedLocationMetadata() throws {
        let threads = try GitHubCLIProvider.parseReviewThreads(
            """
            {
              "data": {
                "repository": {
                  "pullRequest": {
                    "reviewThreads": {
                      "nodes": [
                        {
                          "id": "PRRT_malformed",
                          "isResolved": false,
                          "isOutdated": false,
                          "path": 123,
                          "line": "56",
                          "originalLine": "55",
                          "diffSide": true,
                          "comments": {
                            "nodes": [
                              {
                                "id": "PRRC_malformed",
                                "body": "Keep this feedback.",
                                "url": "https://github.com/mrmans0n/alas/pull/1#discussion_r2",
                                "author": { "login": "reviewer" }
                              }
                            ]
                          }
                        }
                      ],
                      "pageInfo": { "hasNextPage": false, "endCursor": null }
                    }
                  }
                }
              }
            }
            """
        )

        #expect(threads.map(\.id) == ["PRRT_malformed"])
        #expect(threads.first?.body == "Keep this feedback.")
        #expect(threads.first?.path == nil)
        #expect(threads.first?.line == nil)
    }

    @Test func hasHooksMergeStateMapsToClean() throws {
        // GitHub Enterprise reports HAS_HOOKS for a mergeable PR with pre-receive
        // hooks; it must not fall through to `.unknown` (which would hide Merge).
        let request = try #require(try GitHubCLIProvider.parsePRList(
            """
            [
              {
                "number": 42,
                "title": "GHE PR",
                "url": "https://github.com/mrmans0n/alas/pull/42",
                "state": "OPEN",
                "isDraft": false,
                "headRefName": "feature/x",
                "headRepositoryOwner": { "login": "mrmans0n" },
                "baseRefName": "main",
                "reviewDecision": "APPROVED",
                "mergeStateStatus": "HAS_HOOKS"
              }
            ]
            """,
            remote: Self.remote
        ))
        #expect(request.mergeState == .clean)
    }

    @Test func prListFiltersByHeadOwnerWhenProvided() throws {
        let request = try #require(try GitHubCLIProvider.parsePRList(
            """
            [
              {
                "number": 41,
                "title": "Other fork",
                "url": "https://github.com/mrmans0n/alas/pull/41",
                "state": "OPEN",
                "isDraft": false,
                "headRefName": "fix-ci",
                "headRepositoryOwner": { "login": "someone-else" },
                "baseRefName": "main",
                "reviewDecision": "REVIEW_REQUIRED",
                "mergeStateStatus": "CLEAN"
              },
              {
                "number": 42,
                "title": "My fork",
                "url": "https://github.com/mrmans0n/alas/pull/42",
                "state": "OPEN",
                "isDraft": false,
                "headRefName": "fix-ci",
                "headRepositoryOwner": { "login": "nacho" },
                "baseRefName": "main",
                "reviewDecision": "APPROVED",
                "mergeStateStatus": "CLEAN"
              }
            ]
            """,
            remote: Self.remote,
            headOwner: "nacho"
        ))

        #expect(request.number == 42)
        #expect(request.title == "My fork")
    }

    @Test func prListMatchesHeadOwnerIgnoringCase() throws {
        let request = try #require(try GitHubCLIProvider.parsePRList(
            """
            [
              {
                "number": 42,
                "title": "My fork",
                "url": "https://github.com/mrmans0n/alas/pull/42",
                "state": "OPEN",
                "isDraft": false,
                "headRefName": "fix-ci",
                "headRepositoryOwner": { "login": "myorg" },
                "baseRefName": "main",
                "reviewDecision": "APPROVED",
                "mergeStateStatus": "CLEAN"
              }
            ]
            """,
            remote: Self.remote,
            headOwner: "MyOrg"
        ))

        #expect(request.number == 42)
    }

    @Test func prListFiltersByHeadSHAAmongMatchingOwners() throws {
        let request = try #require(try GitHubCLIProvider.parsePRList(
            """
            [
              {
                "number": 41,
                "title": "Newer stale review",
                "url": "https://github.com/mrmans0n/alas/pull/41",
                "state": "OPEN",
                "isDraft": false,
                "headRefName": "fix-ci",
                "headRefOid": "stale-sha",
                "headRepositoryOwner": { "login": "nacho" },
                "baseRefName": "main",
                "reviewDecision": "REVIEW_REQUIRED",
                "mergeStateStatus": "CLEAN"
              },
              {
                "number": 42,
                "title": "Matching merged review",
                "url": "https://github.com/mrmans0n/alas/pull/42",
                "state": "MERGED",
                "isDraft": false,
                "headRefName": "fix-ci",
                "headRefOid": "matching-sha",
                "headRepositoryOwner": { "login": "nacho" },
                "baseRefName": "main",
                "reviewDecision": "APPROVED",
                "mergeStateStatus": "CLEAN"
              }
            ]
            """,
            remote: Self.remote,
            headOwner: "nacho",
            headSHA: "matching-sha"
        ))

        #expect(request.number == 42)
        #expect(request.headSHA == "matching-sha")
    }

    @Test func prListReturnsNilWhenHeadOwnerDoesNotMatch() throws {
        let request = try GitHubCLIProvider.parsePRList(
            Self.prListOutput,
            remote: Self.remote,
            headOwner: "nacho"
        )

        #expect(request == nil)
    }

    @Test func checksAcceptsExitCodeEight() async throws {
        let request = try #require(try GitHubCLIProvider.parsePRList(Self.prListOutput, remote: Self.remote))
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 8, stdout: Self.checksOutput, stderr: "checks pending"),
        ])

        let checks = try await GitHubCLIProvider(runner: runner).checks(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )

        #expect(checks.count == 1)
        #expect(checks[0].bucket == .pending)
    }

    @Test func checksAcceptsExitCodeOneWhenJSONContainsFailedChecks() async throws {
        let request = try #require(try GitHubCLIProvider.parsePRList(Self.prListOutput, remote: Self.remote))
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: Self.failedChecksOutput, stderr: "checks failed"),
        ])

        let checks = try await GitHubCLIProvider(runner: runner).checks(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )

        #expect(checks.count == 1)
        #expect(checks[0].bucket == .fail)
    }

    @Test func failedCheckEvidenceUsesCIActivityChecks() async throws {
        let checks = try GitHubCLIProvider.parseChecks(Self.ciActivityChecksOutput)
        let request = Self.makeRequest(checks: checks)

        let evidence = try await GitHubCLIProvider().failedCheckEvidence(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )

        #expect(evidence.map(\.id) == checks.map(\.id))
        #expect(evidence.map(\.title) == ["build", "test", "lint", "docs", "deploy"])
        #expect(evidence.map(\.subtitle) == ["CI", "CI", "CI", "Docs", "Deploy"])
        #expect(evidence.map(\.status) == [.passed, .failed, .pending, .unknown, .cancelled])
        #expect(evidence.map(\.providerURL) == checks.map(\.detailURL))
    }

    @Test func checkEvidenceDetailLoadsRunLogForWorkflowCheck() async throws {
        let checks = try GitHubCLIProvider.parseChecks(Self.failedChecksOutput)
        let request = Self.makeRequest(checks: checks)
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "failure details", stderr: ""),
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let item = try #require(try await provider.failedCheckEvidence(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        ).first)

        let detail = try await provider.checkEvidenceDetail(
            remote: Self.remote,
            request: request,
            item: item,
            cwd: Self.cwd
        )

        #expect(detail.body.contains("failure details"))
        #expect(detail.isTruncated == false)
        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "gh",
                args: ["run", "view", "1", "--log-failed", "-R", "mrmans0n/alas", "--job", "3"],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func checkEvidenceDetailFallsBackToRunLogWhenJobIDIsUnavailable() async throws {
        let request = Self.makeRequest(checks: [])
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "failure details", stderr: ""),
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let item = ReviewEvidenceItem(
            id: "ci:test",
            section: .ci,
            title: "test",
            subtitle: "CI",
            status: .failed,
            providerURL: URL(string: "https://github.com/mrmans0n/alas/actions/runs/1")
        )

        _ = try await provider.checkEvidenceDetail(
            remote: Self.remote,
            request: request,
            item: item,
            cwd: Self.cwd
        )

        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "gh",
                args: ["run", "view", "1", "--log-failed", "-R", "mrmans0n/alas"],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func checkEvidenceDetailDoesNotLoadFailedLogsForNonFailedCheck() async throws {
        let request = Self.makeRequest(checks: [])
        let runner = FakeRunner(results: [])
        let provider = GitHubCLIProvider(runner: runner)
        let item = ReviewEvidenceItem(
            id: "ci:lint",
            section: .ci,
            title: "lint",
            subtitle: "CI",
            status: .pending,
            providerURL: URL(string: "https://github.com/mrmans0n/alas/actions/runs/1")
        )

        let detail = try await provider.checkEvidenceDetail(
            remote: Self.remote,
            request: request,
            item: item,
            cwd: Self.cwd
        )

        #expect(detail.body == "Open this check in GitHub to inspect current status.")
        #expect(detail.isTruncated == false)
        #expect(await runner.commands.isEmpty)
    }

    @Test func feedbackEvidenceDetailUsesThreadBody() async throws {
        let threads = try GitHubCLIProvider.parseReviewThreads(Self.reviewThreadsOutput)
        let request = Self.makeRequest(threads: threads)
        let provider = GitHubCLIProvider()
        let item = try #require(try await provider.feedbackEvidence(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        ).first)

        let detail = try await provider.feedbackEvidenceDetail(
            remote: Self.remote,
            request: request,
            item: item,
            cwd: Self.cwd
        )

        #expect(detail.body == "Please tighten this branch lookup.")
        #expect(detail.item.providerURL == URL(string: "https://github.com/mrmans0n/alas/pull/42#discussion_r1"))
    }

    @Test func feedbackEvidenceDetailUsesChangesRequestedFallback() async throws {
        let request = Self.makeRequest(reviewDecision: .changesRequested)
        let provider = GitHubCLIProvider()
        let item = try #require(try await provider.feedbackEvidence(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        ).first)

        let detail = try await provider.feedbackEvidenceDetail(
            remote: Self.remote,
            request: request,
            item: item,
            cwd: Self.cwd
        )

        #expect(item.id == ReviewEvidenceFallbacks.changesRequestedID)
        #expect(detail.body.contains("review decision is changes requested"))
        #expect(detail.item.providerURL == request.url)
    }

    @Test func checksTreatNoChecksReportedAsEmptyChecks() async throws {
        let request = try #require(try GitHubCLIProvider.parsePRList(Self.prListOutput, remote: Self.remote))
        let runner = FakeRunner(results: [
            ProcessResult(
                exitCode: 1,
                stdout: "",
                stderr: "no checks reported on the 'feature/github-provider' branch"
            ),
        ])

        let checks = try await GitHubCLIProvider(runner: runner).checks(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )

        #expect(checks.isEmpty)
    }

    @Test func createReviewRequestQualifiesForkHeadOwner() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "https://github.com/mrmans0n/alas/pull/43\n", stderr: ""),
        ])

        _ = try await GitHubCLIProvider(runner: runner).createReviewRequest(
            remote: Self.remote,
            branch: "feature/github-provider",
            headOwner: "nacho",
            baseBranch: "main",
            title: "feature/github-provider",
            body: "Created from Alas.",
            isDraft: false,
            cwd: Self.cwd
        )

        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "pr", "create",
                    "--base", "main",
                    "--head", "nacho:feature/github-provider",
                    "--title", "feature/github-provider",
                    "--body", "Created from Alas.",
                    "-R", "mrmans0n/alas",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func createReviewRequestOmitsDraftFlagForNormalPR() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "https://github.com/mrmans0n/alas/pull/44\n", stderr: ""),
        ])

        _ = try await GitHubCLIProvider(runner: runner).createReviewRequest(
            remote: Self.remote,
            branch: "feature/review-draft",
            headOwner: nil,
            baseBranch: "origin/main",
            title: "Add draft tab",
            body: "## Summary\n- Adds a draft tab",
            isDraft: false,
            cwd: Self.cwd
        )

        #expect(await runner.commands.first?.args.contains("--draft") == false)
    }

    @Test func createReviewRequestAddsDraftFlagForDraftPR() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "https://github.com/mrmans0n/alas/pull/45\n", stderr: ""),
        ])

        _ = try await GitHubCLIProvider(runner: runner).createReviewRequest(
            remote: Self.remote,
            branch: "feature/review-draft",
            headOwner: "nacho",
            baseBranch: "origin/main",
            title: "Add draft tab",
            body: "## Summary\n- Adds a draft tab",
            isDraft: true,
            cwd: Self.cwd
        )

        let args = try #require(await runner.commands.first?.args)
        #expect(args.contains("--draft"))
        #expect(args.contains("nacho:feature/review-draft"))
    }

    @Test func createReviewRequestNormalizesRemoteQualifiedBaseBranch() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "https://github.com/mrmans0n/alas/pull/43\n", stderr: ""),
        ])

        _ = try await GitHubCLIProvider(runner: runner).createReviewRequest(
            remote: Self.remote,
            branch: "feature/github-provider",
            headOwner: nil,
            baseBranch: "origin/main",
            title: "feature/github-provider",
            body: "Created from Alas.",
            isDraft: false,
            cwd: Self.cwd
        )

        let commands = await runner.commands
        #expect(commands.first?.args.contains("origin/main") == false)
        #expect(commands.first?.args == [
            "pr", "create",
            "--base", "main",
            "--head", "feature/github-provider",
            "--title", "feature/github-provider",
            "--body", "Created from Alas.",
            "-R", "mrmans0n/alas",
        ])
    }

    @Test func rerunFailedChecksIssuesRerunForFailedRuns() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: #"[{ "databaseId": 111 }, { "databaseId": 222 }]"#, stderr: ""),
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
        ])

        try await GitHubCLIProvider(runner: runner).rerunFailedChecks(
            remote: Self.remote,
            branch: "feature/github-provider",
            headSHA: "abc123",
            request: nil,
            cwd: Self.cwd
        )

        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "run", "list",
                    "--branch", "feature/github-provider",
                    "--commit", "abc123",
                    "--status", "failure",
                    "--limit", "20",
                    "--json", "databaseId,status,conclusion,url",
                    "-R", "mrmans0n/alas",
                ],
                cwd: Self.cwd
            ),
            FakeRunner.Command(
                executable: "gh",
                args: ["run", "rerun", "111", "--failed", "-R", "mrmans0n/alas"],
                cwd: Self.cwd
            ),
            FakeRunner.Command(
                executable: "gh",
                args: ["run", "rerun", "222", "--failed", "-R", "mrmans0n/alas"],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func commandFailuresThrowCommandFailed() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "not found"),
        ])

        do {
            _ = try await GitHubCLIProvider(runner: runner).currentReviewRequest(
                remote: Self.remote,
                branch: "feature/github-provider",
                headOwner: nil,
                baseBranch: "main",
                cwd: Self.cwd
            )
            Issue.record("Expected commandFailed")
        } catch CodeHostProviderError.commandFailed(let command, let stderr) {
            #expect(command == "gh pr list")
            #expect(stderr == "not found")
        }
    }

    @Test func replyToThreadReturnsNewComment() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.replyToThreadOutput, stderr: ""),
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let comment = try await provider.replyToThread(
            remote: Self.remote,
            request: Self.makeRequest(),
            thread: Self.unresolvedThread,
            body: "Reply body.",
            cwd: Self.cwd
        )

        #expect(comment.body == "Reply body.")
        #expect(comment.author == "author")
        #expect(comment.viewerCanUpdate == true)
        #expect(comment.viewerCanDelete == true)

        let command = try #require(await runner.commands.first)
        #expect(command.executable == "gh")
        #expect(command.args == ["api", "graphql", "--hostname", "github.com", "--input", "-"])
        #expect(command.stdin?.contains("addPullRequestReviewThreadReply") == true)
        #expect(command.stdin?.contains("\"threadId\":\"thread-1\"") == true)
        #expect(command.stdin?.contains("\"body\":\"Reply body.\"") == true)
    }

    @Test func resolveThreadUpdatesResolvedFlag() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.resolveThreadOutput, stderr: ""),
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let thread = try await provider.resolveThread(
            remote: Self.remote,
            request: Self.makeRequest(),
            thread: Self.unresolvedThread,
            cwd: Self.cwd
        )

        #expect(thread.isResolved == true)
        #expect(thread.isOutdated == Self.unresolvedThread.isOutdated)
        #expect(thread.id == Self.unresolvedThread.id)
        #expect(thread.comments == Self.unresolvedThread.comments)
    }

    @Test func unresolveThreadUpdatesResolvedFlag() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.unresolveThreadOutput, stderr: ""),
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let resolvedThread = ReviewThread(
            id: "thread-1",
            path: "Sources/Foo.swift",
            line: 10,
            startLine: nil,
            originalLine: 8,
            diffHunk: "@@ -8,3 +8,3 @@",
            isResolved: true,
            isOutdated: false,
            isFileLevel: false,
            comments: [],
            viewerCanResolve: true,
            viewerCanReply: true,
            url: nil
        )
        let thread = try await provider.unresolveThread(
            remote: Self.remote,
            request: Self.makeRequest(),
            thread: resolvedThread,
            cwd: Self.cwd
        )

        #expect(thread.isResolved == false)
        #expect(thread.id == resolvedThread.id)
        #expect(thread.path == resolvedThread.path)
    }

    @Test func editCommentReturnsUpdatedComment() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.editCommentOutput, stderr: ""),
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let comment = ReviewComment(
            id: "comment-1",
            author: "author",
            body: "Original body.",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/42#discussion_r1"),
            createdAt: nil,
            viewerCanUpdate: true,
            viewerCanDelete: true,
            isPending: false
        )
        let updated = try await provider.editComment(
            remote: Self.remote,
            request: Self.makeRequest(),
            comment: comment,
            newBody: "Updated body.",
            cwd: Self.cwd
        )

        #expect(updated.body == "Updated body.")
        #expect(updated.author == "author")
        #expect(updated.viewerCanUpdate == true)
        #expect(updated.viewerCanDelete == true)
    }

    @Test func deleteCommentSucceedsOnZeroExit() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.deleteCommentOutput, stderr: ""),
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let comment = ReviewComment(
            id: "comment-1",
            author: "author",
            body: "Body.",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/42#discussion_r1"),
            createdAt: nil,
            viewerCanUpdate: true,
            viewerCanDelete: true,
            isPending: false
        )

        try await provider.deleteComment(
            remote: Self.remote,
            request: Self.makeRequest(),
            comment: comment,
            cwd: Self.cwd
        )

        let command = try #require(await runner.commands.first)
        let queryArg = try #require(command.args.first { $0.hasPrefix("query=") })
        #expect(queryArg.contains("deletePullRequestReviewComment"))
    }

    @Test func writeFailureThrowsCommandFailed() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "permission denied"),
        ])
        let provider = GitHubCLIProvider(runner: runner)

        do {
            _ = try await provider.replyToThread(
                remote: Self.remote,
                request: Self.makeRequest(),
                thread: Self.unresolvedThread,
                body: "Reply body.",
                cwd: Self.cwd
            )
            Issue.record("Expected commandFailed")
        } catch CodeHostProviderError.commandFailed(let command, let stderr) {
            #expect(command == "gh api graphql")
            #expect(stderr == "permission denied")
        }
    }

    @Test func parsesRichReviewThreadFields() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.prListOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mergeQueueDisabledOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.richReviewThreadsOutput, stderr: ""),
        ])
        let request = try await GitHubCLIProvider(runner: runner).currentReviewRequest(
            remote: Self.remote, branch: "feature/github-provider",
            headOwner: nil, baseBranch: "main", cwd: Self.cwd)
        let thread = try #require(request?.threads.first)
        #expect(thread.path == "Sources/Foo.swift")
        #expect(thread.line == 42)
        #expect(thread.originalLine == 40)
        #expect(thread.originalStartLine == 38)
        #expect(thread.diffHunk == "@@ -40,3 +40,3 @@")
        #expect(thread.viewerCanResolve == true)
        #expect(thread.comments.first?.id == "c1")
        #expect(thread.comments.first?.viewerCanUpdate == false)
        #expect(thread.isFileLevel == false)
    }

    @Test func parsesFileLevelReviewThread() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.prListOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mergeQueueDisabledOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.fileLevelReviewThreadOutput, stderr: ""),
        ])
        let request = try await GitHubCLIProvider(runner: runner).currentReviewRequest(
            remote: Self.remote, branch: "feature/github-provider",
            headOwner: nil, baseBranch: "main", cwd: Self.cwd)
        let thread = try #require(request?.threads.first)
        #expect(thread.isFileLevel == true)
        #expect(thread.line == nil)
    }

    @Test func reviewThreadsFilterEmptyBodiedCommentsAndDropEmptyThreads() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.prListOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mergeQueueDisabledOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.emptyCommentReviewThreadsOutput, stderr: ""),
        ])
        let request = try await GitHubCLIProvider(runner: runner).currentReviewRequest(
            remote: Self.remote, branch: "feature/github-provider",
            headOwner: nil, baseBranch: "main", cwd: Self.cwd)
        let threads = try #require(request?.threads)
        #expect(threads.count == 1)
        #expect(threads[0].id == "thread-kept")
        #expect(threads[0].comments.map(\.body) == ["keep me"])
    }

    @Test func commandFailureDescriptionIncludesStderr() {
        let error = CodeHostProviderError.commandFailed(
            command: "gh pr create",
            stderr: "GraphQL: Head sha can't be blank"
        )

        #expect(error.errorDescription == "gh pr create failed: GraphQL: Head sha can't be blank")
    }

    @Test func parsesCheckAnnotations() async throws {
        let check = ReviewCheck(
            id: "run-99",
            name: "SwiftLint",
            workflow: "CI",
            bucket: .fail,
            detailURL: nil,
            completedAt: nil
        )
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.checkAnnotationsOutput, stderr: ""),
        ])

        let annotations = try await GitHubCLIProvider(runner: runner).checkAnnotations(
            remote: Self.remote,
            check: check,
            cwd: Self.cwd
        )

        #expect(annotations.count == 2)
        #expect(annotations[0].level == .failure)
        #expect(annotations[0].checkRunID == "run-99")
        #expect(annotations[0].checkName == "SwiftLint")
        #expect(annotations[0].path == "Sources/App.swift")
        #expect(annotations[0].startLine == 10)
        #expect(annotations[0].endLine == 10)
        #expect(annotations[0].message == "Line length violation")
        #expect(annotations[0].rawDetails == "Line is 120 characters long")
        #expect(annotations[1].level == .warning)
        #expect(annotations[1].path == "Sources/Model.swift")
        #expect(annotations[1].rawDetails == nil)

        let command = try #require(await runner.commands.first)
        #expect(command.executable == "gh")
        #expect(command.args == [
            "api",
            "--hostname", "github.com",
            "/repos/mrmans0n/alas/check-runs/run-99/annotations",
            "--paginate",
            "--slurp",
        ])
    }

    @Test func mergeReviewRequestSquashesPinsHeadAndDeletesRemoteBranch() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
            ProcessResult(exitCode: 0, stdout: #"{"state":"MERGED"}"#, stderr: ""),
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let request = Self.makeRequest()

        try await provider.mergeReviewRequest(request, method: .squash, deleteBranch: true, cwd: Self.cwd)

        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "pr", "merge", "42",
                    "--squash",
                    "--match-head-commit", "head-sha-42",
                    "-R", "mrmans0n/alas",
                ],
                cwd: Self.cwd
            ),
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "pr", "view", "42",
                    "--json", "state",
                    "-R", "mrmans0n/alas",
                ],
                cwd: Self.cwd
            ),
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "api",
                    "--hostname", "github.com",
                    "--method", "DELETE",
                    "repos/mrmans0n/alas/git/refs/heads/feature/github-provider",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func mergeReviewRequestWithMergeQueueOmitsStrategyAndSkipsBranchDeleteWhenStillOpen() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
            ProcessResult(exitCode: 0, stdout: #"{"state":"OPEN"}"#, stderr: ""),
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let request = Self.makeRequest(isMergeQueueEnabled: true)

        try await provider.mergeReviewRequest(request, method: .squash, deleteBranch: true, cwd: Self.cwd)

        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "pr", "merge", "42",
                    "--match-head-commit", "head-sha-42",
                    "-R", "mrmans0n/alas",
                ],
                cwd: Self.cwd
            ),
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "pr", "view", "42",
                    "--json", "state",
                    "-R", "mrmans0n/alas",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func mergeReviewRequestSkipsBranchDeleteWhenPRIsQueuedNotMerged() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
            ProcessResult(exitCode: 0, stdout: #"{"state":"OPEN"}"#, stderr: ""),
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let request = Self.makeRequest()

        try await provider.mergeReviewRequest(request, method: .squash, deleteBranch: true, cwd: Self.cwd)

        // `gh pr merge` enqueued the PR (still OPEN), so the head branch must be
        // left in place for the queue — no DELETE command is issued.
        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "pr", "merge", "42",
                    "--squash",
                    "--match-head-commit", "head-sha-42",
                    "-R", "mrmans0n/alas",
                ],
                cwd: Self.cwd
            ),
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "pr", "view", "42",
                    "--json", "state",
                    "-R", "mrmans0n/alas",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func mergeReviewRequestForSameOwnerForkSkipsRemoteDelete() async throws {
        let runner = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: "", stderr: "")])
        let provider = GitHubCLIProvider(runner: runner)
        // Head lives in a fork under the SAME owner but a different repo name
        // (`mrmans0n/alas-fork`). Owner matches the base repo, but the branch is
        // not in it — deleting `mrmans0n/alas`'s same-named branch would be wrong.
        let request = Self.makeRequest(headRepositoryName: "alas-fork")

        try await provider.mergeReviewRequest(request, method: .squash, deleteBranch: true, cwd: Self.cwd)

        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "pr", "merge", "42",
                    "--squash",
                    "--match-head-commit", "head-sha-42",
                    "-R", "mrmans0n/alas",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func mergeReviewRequestForForkedHeadSkipsRemoteDelete() async throws {
        let runner = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: "", stderr: "")])
        let provider = GitHubCLIProvider(runner: runner)
        // Head lives in a fork (owner != base repo owner) — deleting a base-repo
        // ref by name here could remove an unrelated branch, so cleanup is skipped.
        let request = Self.makeRequest(headRepositoryOwner: "fork-owner")

        try await provider.mergeReviewRequest(request, method: .squash, deleteBranch: true, cwd: Self.cwd)

        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "pr", "merge", "42",
                    "--squash",
                    "--match-head-commit", "head-sha-42",
                    "-R", "mrmans0n/alas",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func mergeReviewRequestWithoutHeadSHAOmitsPinAndSkipsRemoteDelete() async throws {
        let runner = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: "", stderr: "")])
        let provider = GitHubCLIProvider(runner: runner)
        let request = Self.makeRequest(headSHA: nil)

        try await provider.mergeReviewRequest(request, method: .squash, deleteBranch: false, cwd: Self.cwd)

        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "pr", "merge", "42",
                    "--squash",
                    "-R", "mrmans0n/alas",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    private static let checkAnnotationsOutput = """
    [
      [
        {
          "path": "Sources/App.swift",
          "start_line": 10,
          "end_line": 10,
          "annotation_level": "failure",
          "message": "Line length violation",
          "raw_details": "Line is 120 characters long"
        },
        {
          "path": "Sources/Model.swift",
          "start_line": 25,
          "end_line": 30,
          "annotation_level": "warning",
          "message": "Cyclomatic complexity violation",
          "raw_details": null
        }
      ]
    ]
    """

    private static let remote = CodeHostRemote(
        kind: .github,
        host: "github.com",
        owner: "mrmans0n",
        repository: "alas",
        remoteName: "origin",
        webURL: URL(string: "https://github.com/mrmans0n/alas")!
    )

    private static let cwd = URL(fileURLWithPath: "/tmp/alas")

    private static func makeRequest(
        checks: [ReviewCheck] = [],
        threads: [ReviewThread] = [],
        reviewDecision: ReviewDecision = .approved,
        baseSHA: String? = "base-sha-42",
        headSHA: String? = "head-sha-42",
        headRepositoryOwner: String? = "mrmans0n",
        headRepositoryName: String? = "alas",
        isMergeQueueEnabled: Bool = false,
        isInMergeQueue: Bool = false
    ) -> ReviewRequest {
        ReviewRequest(
            remote: Self.remote,
            number: 42,
            title: "Add GitHub provider",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/42")!,
            state: .open,
            isDraft: false,
            headRefName: "feature/github-provider",
            baseRefName: "main",
            baseSHA: baseSHA,
            headSHA: headSHA,
            headRepositoryOwner: headRepositoryOwner,
            headRepositoryName: headRepositoryName,
            reviewDecision: reviewDecision,
            mergeState: .clean,
            checks: checks,
            threads: threads,
            isMergeQueueEnabled: isMergeQueueEnabled,
            isInMergeQueue: isInMergeQueue
        )
    }

    private static func makeProviderDraftComment(
        id: String,
        path: String,
        side: DiffReviewInlineFeedbackSide,
        startLine: Int,
        endLine: Int?,
        body: String
    ) throws -> ProviderReviewDraftComment {
        let draft = ReviewDraftComment(
            id: id,
            sessionID: .reviewRequest(
                worktreeID: "wt",
                provider: .github,
                host: "github.com",
                repositorySlug: "mrmans0n/alas",
                number: 42
            ),
            fileID: DiffReviewFileID(namespace: "github", path: path),
            path: path,
            originalPath: nil,
            side: side,
            startLine: startLine,
            endLine: endLine,
            selectedText: nil,
            bodyMarkdown: body,
            state: .active,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        )
        return try #require(ProviderReviewDraftComment(localDraft: draft))
    }

    private static func graphQLVariables(from stdin: String?) throws -> [String: Any] {
        let stdin = try #require(stdin)
        let data = Data(stdin.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        let payload = try #require(object as? [String: Any])
        return try #require(payload["variables"] as? [String: Any])
    }

    private static let prListOutput = """
    [
      {
        "number": 42,
        "title": "Add GitHub provider",
        "url": "https://github.com/mrmans0n/alas/pull/42",
        "state": "OPEN",
        "isDraft": false,
        "headRefName": "feature/github-provider",
        "headRefOid": "head-sha-42",
        "baseRefName": "main",
        "baseRefOid": "base-sha-42",
        "reviewDecision": "APPROVED",
        "mergeStateStatus": "CLEAN"
      }
    ]
    """

    private static let prViewOutput = """
    {
      "number": 42,
      "title": "Add GitHub provider",
      "url": "https://github.com/mrmans0n/alas/pull/42",
      "state": "OPEN",
      "isDraft": false,
      "headRefName": "feature/github-provider",
      "headRefOid": "head-sha-42",
      "baseRefName": "main",
      "baseRefOid": "base-sha-42",
      "reviewDecision": "APPROVED",
      "mergeStateStatus": "CLEAN"
    }
    """

    private static let mergeQueueMetadataQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          isMergeQueueEnabled
          isInMergeQueue
        }
      }
    }
    """

    private static let mergeQueueEnabledOutput = """
    {"data":{"repository":{"pullRequest":{"isMergeQueueEnabled":true,"isInMergeQueue":true}}}}
    """

    private static let mergeQueueDisabledOutput = """
    {"data":{"repository":{"pullRequest":{"isMergeQueueEnabled":false,"isInMergeQueue":false}}}}
    """

    private static let checksOutput = """
    [
      {
        "bucket": "pending",
        "completedAt": null,
        "description": "Unit tests running",
        "event": "push",
        "link": "https://github.com/mrmans0n/alas/actions/runs/1/job/2",
        "name": "test",
        "startedAt": "2026-06-01T12:30:00Z",
        "state": "PENDING",
        "workflow": "CI"
      }
    ]
    """

    private static let failedChecksOutput = """
    [
      {
        "bucket": "fail",
        "completedAt": "2026-06-01T12:35:56Z",
        "description": "Unit tests failed",
        "event": "push",
        "link": "https://github.com/mrmans0n/alas/actions/runs/1/job/3",
        "name": "test",
        "startedAt": "2026-06-01T12:31:00Z",
        "state": "FAILURE",
        "workflow": "CI"
      }
    ]
    """

    private static let ciActivityChecksOutput = """
    [
      {
        "bucket": "pass",
        "completedAt": "2026-06-01T12:34:56Z",
        "description": "Build passed",
        "event": "push",
        "link": "https://github.com/mrmans0n/alas/actions/runs/1/job/1",
        "name": "build",
        "startedAt": "2026-06-01T12:30:00Z",
        "state": "SUCCESS",
        "workflow": "CI"
      },
      {
        "bucket": "fail",
        "completedAt": "2026-06-01T12:35:56Z",
        "description": "Unit tests failed",
        "event": "push",
        "link": "https://github.com/mrmans0n/alas/actions/runs/1/job/3",
        "name": "test",
        "startedAt": "2026-06-01T12:31:00Z",
        "state": "FAILURE",
        "workflow": "CI"
      },
      {
        "bucket": "pending",
        "completedAt": null,
        "description": "Lint is running",
        "event": "push",
        "link": "https://github.com/mrmans0n/alas/actions/runs/1/job/4",
        "name": "lint",
        "startedAt": "2026-06-01T12:32:00Z",
        "state": "PENDING",
        "workflow": "CI"
      },
      {
        "bucket": "skipping",
        "completedAt": null,
        "description": "Docs skipped",
        "event": "push",
        "link": "https://github.com/mrmans0n/alas/actions/runs/1/job/5",
        "name": "docs",
        "startedAt": null,
        "state": "SKIPPED",
        "workflow": "Docs"
      },
      {
        "bucket": "cancel",
        "completedAt": "2026-06-01T12:36:56Z",
        "description": "Deploy cancelled",
        "event": "push",
        "link": "https://github.com/mrmans0n/alas/actions/runs/1/job/6",
        "name": "deploy",
        "startedAt": "2026-06-01T12:33:00Z",
        "state": "CANCELLED",
        "workflow": "Deploy"
      }
    ]
    """

    private static let reviewThreadsOutput = """
    {
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "id": "thread-1",
                  "isResolved": false,
                  "isOutdated": false,
                  "comments": {
                    "nodes": [
                      {
                        "id": "comment-1",
                        "body": "Please tighten this branch lookup.",
                        "url": "https://github.com/mrmans0n/alas/pull/42#discussion_r1",
                        "author": { "login": "reviewer" }
                      }
                    ]
                  }
                },
                {
                  "id": "thread-2",
                  "isResolved": false,
                  "isOutdated": true,
                  "comments": {
                    "nodes": [
                      {
                        "id": "comment-2",
                        "body": "Old feedback.",
                        "url": "https://github.com/mrmans0n/alas/pull/42#discussion_r2",
                        "author": { "login": "reviewer" }
                      }
                    ]
                  }
                },
                {
                  "id": "thread-3",
                  "isResolved": true,
                  "isOutdated": false,
                  "comments": {
                    "nodes": [
                      {
                        "id": "comment-3",
                        "body": "",
                        "url": "https://github.com/mrmans0n/alas/pull/42#discussion_r3",
                        "author": { "login": "reviewer" }
                      }
                    ]
                  }
                }
              ],
              "pageInfo": {
                "hasNextPage": false,
                "endCursor": null
              }
            }
          }
        }
      }
    }
    """

    private static let pullRequestNodeOutput = """
    {"data":{"repository":{"pullRequest":{"id":"PR_node_42"}}}}
    """

    private static let publishReviewMutationOutput = """
    {"data":{"addPullRequestReview":{"pullRequestReview":{"comments":{"nodes":[{"id":"PRRC_comment_1","url":"https://github.com/mrmans0n/alas/pull/42#discussion_r1","pullRequestReviewThread":{"id":"PRRT_thread_1"}}]}}}}}
    """

    private static func publishReviewMutationOutput(commentCount: Int) -> String {
        let nodes = (1...commentCount).map { index in
            #"{"id":"PRRC_comment_\#(index)","url":"https://github.com/mrmans0n/alas/pull/42#discussion_r\#(index)","pullRequestReviewThread":{"id":"PRRT_thread_\#(index)"}}"#
        }.joined(separator: ",")
        return #"{"data":{"addPullRequestReview":{"pullRequestReview":{"comments":{"nodes":[\#(nodes)]}}}}}"#
    }

    private static let publishReviewMutationWithoutCommentsOutput = """
    {"data":{"addPullRequestReview":{"pullRequestReview":{"comments":{"nodes":[]}}}}}
    """

    private static let replyMutationOutput = """
    {"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"PRRC_reply_1","url":"https://github.com/mrmans0n/alas/pull/42#discussion_r2"}}}}
    """

    private static let resolveThreadMutationOutput = """
    {"data":{"resolveReviewThread":{"thread":{"id":"PRRT_thread_1","isResolved":true}}}}
    """

    private static let reviewThreadsFirstPageOutput = """
    {
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "id": "thread-page-1",
                  "isResolved": false,
                  "isOutdated": false,
                  "comments": {
                    "nodes": [
                      {
                        "body": "First page feedback.",
                        "url": "https://github.com/mrmans0n/alas/pull/42#discussion_page_1",
                        "author": { "login": "reviewer" }
                      }
                    ]
                  }
                }
              ],
              "pageInfo": {
                "hasNextPage": true,
                "endCursor": "cursor-1"
              }
            }
          }
        }
      }
    }
    """

    private static let reviewThreadsSecondPageOutput = """
    {
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "id": "thread-page-2",
                  "isResolved": false,
                  "isOutdated": false,
                  "comments": {
                    "nodes": [
                      {
                        "body": "Second page feedback.",
                        "url": "https://github.com/mrmans0n/alas/pull/42#discussion_page_2",
                        "author": { "login": "reviewer" }
                      }
                    ]
                  }
                }
              ],
              "pageInfo": {
                "hasNextPage": false,
                "endCursor": null
              }
            }
          }
        }
      }
    }
    """

    private static let richReviewThreadsOutput = """
    {
      "data": { "repository": { "pullRequest": { "reviewThreads": {
        "nodes": [
          {
            "id": "thread-1", "isResolved": false, "isOutdated": false,
            "path": "Sources/Foo.swift", "line": 42, "startLine": null,
            "originalLine": 40, "originalStartLine": 38,
            "subjectType": "LINE", "viewerCanResolve": true, "viewerCanReply": true,
            "comments": { "nodes": [
              { "id": "c1", "body": "rename this",
                "url": "https://github.com/mrmans0n/alas/pull/42#discussion_r1",
                "createdAt": "2026-06-16T10:00:00Z", "diffHunk": "@@ -40,3 +40,3 @@",
                "author": { "login": "reviewer" },
                "viewerDidAuthor": false }
            ] }
          }
        ],
        "pageInfo": { "hasNextPage": false, "endCursor": null }
      }}}}
    }
    """

    private static let fileLevelReviewThreadOutput = """
    {
      "data": { "repository": { "pullRequest": { "reviewThreads": {
        "nodes": [
          {
            "id": "thread-file-1", "isResolved": false, "isOutdated": false,
            "path": "Sources/Bar.swift", "line": null, "startLine": null,
            "originalLine": null,
            "subjectType": "FILE", "viewerCanResolve": true, "viewerCanReply": true,
            "comments": { "nodes": [
              { "id": "cf1", "body": "file-level comment",
                "url": "https://github.com/mrmans0n/alas/pull/42#discussion_r10",
                "createdAt": "2026-06-16T11:00:00Z", "diffHunk": null,
                "author": { "login": "reviewer" },
                "viewerDidAuthor": false }
            ] }
          }
        ],
        "pageInfo": { "hasNextPage": false, "endCursor": null }
      }}}}
    }
    """

    private static let emptyCommentReviewThreadsOutput = """
    {
      "data": { "repository": { "pullRequest": { "reviewThreads": {
        "nodes": [
          {
            "id": "thread-kept", "isResolved": false, "isOutdated": false,
            "path": "Sources/Foo.swift", "line": 10, "startLine": null,
            "originalLine": 8,
            "subjectType": "LINE", "viewerCanResolve": true, "viewerCanReply": true,
            "comments": { "nodes": [
              { "id": "c-empty", "body": "   ",
                "url": "https://github.com/mrmans0n/alas/pull/42#discussion_r1",
                "createdAt": "2026-06-16T10:00:00Z", "diffHunk": "@@ -8,3 +8,3 @@",
                "author": { "login": "reviewer" },
                "viewerDidAuthor": false },
              { "id": "c-keep", "body": "keep me",
                "url": "https://github.com/mrmans0n/alas/pull/42#discussion_r2",
                "createdAt": "2026-06-16T10:01:00Z", "diffHunk": "@@ -8,3 +8,3 @@",
                "author": { "login": "reviewer" },
                "viewerDidAuthor": false }
            ] }
          },
          {
            "id": "thread-dropped", "isResolved": false, "isOutdated": false,
            "path": "Sources/Bar.swift", "line": 20, "startLine": null,
            "originalLine": 18,
            "subjectType": "LINE", "viewerCanResolve": true, "viewerCanReply": true,
            "comments": { "nodes": [
              { "id": "c-only-empty", "body": "",
                "url": "https://github.com/mrmans0n/alas/pull/42#discussion_r3",
                "createdAt": "2026-06-16T10:02:00Z", "diffHunk": "@@ -18,3 +18,3 @@",
                "author": { "login": "reviewer" },
                "viewerDidAuthor": false }
            ] }
          }
        ],
        "pageInfo": { "hasNextPage": false, "endCursor": null }
      }}}}
    }
    """

    private static let unresolvedThread = ReviewThread(
        id: "thread-1",
        path: "Sources/Foo.swift",
        line: 10,
        startLine: nil,
        originalLine: 8,
        diffHunk: "@@ -8,3 +8,3 @@",
        isResolved: false,
        isOutdated: false,
        isFileLevel: false,
        comments: [
            ReviewComment(
                id: "c1",
                author: "reviewer",
                body: "Original comment.",
                url: URL(string: "https://github.com/mrmans0n/alas/pull/42#discussion_r1"),
                createdAt: nil,
                viewerCanUpdate: false,
                viewerCanDelete: false,
                isPending: false
            )
        ],
        viewerCanResolve: true,
        viewerCanReply: true,
        url: URL(string: "https://github.com/mrmans0n/alas/pull/42#discussion_r1")
    )

    private static let replyToThreadOutput = """
    {
      "data": {
        "addPullRequestReviewThreadReply": {
          "comment": {
            "id": "reply-1",
            "body": "Reply body.",
            "url": "https://github.com/mrmans0n/alas/pull/42#discussion_rreply",
            "createdAt": "2026-06-16T12:00:00Z",
            "author": { "login": "author" },
            "viewerDidAuthor": true
          }
        }
      }
    }
    """

    private static let resolveThreadOutput = """
    {
      "data": {
        "resolveReviewThread": {
          "thread": {
            "id": "thread-1",
            "isResolved": true,
            "isOutdated": false
          }
        }
      }
    }
    """

    private static let unresolveThreadOutput = """
    {
      "data": {
        "unresolveReviewThread": {
          "thread": {
            "id": "thread-1",
            "isResolved": false,
            "isOutdated": false
          }
        }
      }
    }
    """

    private static let editCommentOutput = """
    {
      "data": {
        "updatePullRequestReviewComment": {
          "pullRequestReviewComment": {
            "id": "comment-1",
            "body": "Updated body.",
            "url": "https://github.com/mrmans0n/alas/pull/42#discussion_r1",
            "createdAt": "2026-06-16T12:00:00Z",
            "author": { "login": "author" },
            "viewerDidAuthor": true
          }
        }
      }
    }
    """

    private static let deleteCommentOutput = """
    {
      "data": {
        "deletePullRequestReviewComment": {
          "clientMutationId": "comment-1"
        }
      }
    }
    """

    private static let enterpriseRemote = CodeHostRemote(
        kind: .github,
        host: "github.example.com",
        owner: "mrmans0n",
        repository: "alas",
        remoteName: "origin",
        webURL: URL(string: "https://github.example.com/mrmans0n/alas")!
    )

    private static let issueOutput = """
    {
      "number": 1842,
      "title": "Fix remote issue loading",
      "body": "Load the issue through the API.",
      "state": "open",
      "html_url": "https://github.example.com/mrmans0n/alas/issues/1842",
      "updated_at": "2026-08-01T10:20:30Z",
      "labels": [{ "name": "bug" }, { "name": "remote" }],
      "assignees": [{ "login": "nacho" }]
    }
    """

    private actor FakeRunner: CodeHostCommandRunning {
        struct Command: Equatable {
            let executable: String
            let args: [String]
            let cwd: URL?
            let stdin: String?

            init(executable: String, args: [String], cwd: URL?, stdin: String? = nil) {
                self.executable = executable
                self.args = args
                self.cwd = cwd
                self.stdin = stdin
            }
        }

        private var results: [ProcessResult]
        private(set) var commands: [Command] = []

        init(results: [ProcessResult]) {
            self.results = results
        }

        func run(_ executable: String, args: [String], cwd: URL?, stdin: String?) async throws -> ProcessResult {
            commands.append(Command(executable: executable, args: args, cwd: cwd, stdin: stdin))
            guard !results.isEmpty else {
                return ProcessResult(exitCode: 1, stdout: "", stderr: "unexpected command")
            }
            return results.removeFirst()
        }
    }
}
