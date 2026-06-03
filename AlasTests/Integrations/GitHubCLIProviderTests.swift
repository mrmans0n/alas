import Foundation
import Testing
@testable import Alas

struct GitHubCLIProviderTests {
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
                "baseRefName": "main",
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
        #expect(request.checks.isEmpty)
        #expect(request.threads.isEmpty)
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
                "link": "https://github.com/mrmans0n/alas/actions/runs/1/job/2",
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

        #expect(await GitHubCLIProvider(runner: successRunner).isAvailable())
        #expect(await GitHubCLIProvider(runner: failureRunner).isAvailable() == false)
        #expect(await successRunner.commands == [
            FakeRunner.Command(executable: "gh", args: ["--version"], cwd: nil),
        ])
    }

    @Test func currentReviewRequestUsesExpectedCommandArgs() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.prListOutput, stderr: ""),
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
                    "--json", "number,title,url,state,isDraft,headRefName,headRepositoryOwner,baseRefName,reviewDecision,mergeStateStatus",
                    "-R", "mrmans0n/alas",
                ],
                cwd: Self.cwd
            ),
            FakeRunner.Command(
                executable: "gh",
                args: [
                    "api", "graphql",
                    "-f", "query=\(GitHubCLIProvider.reviewThreadsQuery)",
                    "-F", "owner=mrmans0n",
                    "-F", "repo=alas",
                    "-F", "number=42",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func currentReviewRequestKeepsRequestWhenReviewThreadFetchFails() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.prListOutput, stderr: ""),
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
        #expect(await runner.commands.count == 2)
    }

    @Test func currentReviewRequestPagesReviewThreads() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.prListOutput, stderr: ""),
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
        #expect(commands.count == 3)
        #expect(!commands[1].args.contains("-F cursor=cursor-1"))
        #expect(commands[2].args.contains("-F"))
        #expect(commands[2].args.contains("cursor=cursor-1"))
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
        #expect(threads[1].isResolved == false)
        #expect(threads[1].isActionable == false)
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

    @Test func commandFailureDescriptionIncludesStderr() {
        let error = CodeHostProviderError.commandFailed(
            command: "gh pr create",
            stderr: "GraphQL: Head sha can't be blank"
        )

        #expect(error.errorDescription == "gh pr create failed: GraphQL: Head sha can't be blank")
    }

    private static let remote = CodeHostRemote(
        kind: .github,
        host: "github.com",
        owner: "mrmans0n",
        repository: "alas",
        remoteName: "origin",
        webURL: URL(string: "https://github.com/mrmans0n/alas")!
    )

    private static let cwd = URL(fileURLWithPath: "/tmp/alas")

    private static let prListOutput = """
    [
      {
        "number": 42,
        "title": "Add GitHub provider",
        "url": "https://github.com/mrmans0n/alas/pull/42",
        "state": "OPEN",
        "isDraft": false,
        "headRefName": "feature/github-provider",
        "baseRefName": "main",
        "reviewDecision": "APPROVED",
        "mergeStateStatus": "CLEAN"
      }
    ]
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

    private actor FakeRunner: CodeHostCommandRunning {
        struct Command: Equatable {
            let executable: String
            let args: [String]
            let cwd: URL?
        }

        private var results: [ProcessResult]
        private(set) var commands: [Command] = []

        init(results: [ProcessResult]) {
            self.results = results
        }

        func run(_ executable: String, args: [String], cwd: URL?) async throws -> ProcessResult {
            commands.append(Command(executable: executable, args: args, cwd: cwd))
            guard !results.isEmpty else {
                return ProcessResult(exitCode: 1, stdout: "", stderr: "unexpected command")
            }
            return results.removeFirst()
        }
    }
}
