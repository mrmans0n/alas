import Foundation
import Testing
@testable import Alas

struct GitLabCLIProviderTests {
    @Test func isAvailableReturnsTrueOnlyForVersionExitZero() async {
        let successRunner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "glab 1.101.0", stderr: ""),
        ])
        let failureRunner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "missing"),
        ])

        #expect(await GitLabCLIProvider(runner: successRunner).isAvailable())
        #expect(await GitLabCLIProvider(runner: failureRunner).isAvailable() == false)
        #expect(await successRunner.commands == [
            FakeRunner.Command(executable: "glab", args: ["--version"], cwd: nil),
        ])
    }

    @Test func authStatusUsesDetectedHost() async {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "gitlab.example.com: Logged in", stderr: ""),
        ])

        let authenticated = await GitLabCLIProvider(runner: runner).isAuthenticated(remote: Self.remote, cwd: Self.cwd)

        #expect(authenticated)
        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "glab",
                args: ["auth", "status", "--hostname", "gitlab.example.com"],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func normalizedBaseBranchStripsDetectedRemotePrefixOnly() {
        #expect(GitLabCLIProvider.normalizedBaseBranch("origin/main", remoteName: "origin") == "main")
        #expect(GitLabCLIProvider.normalizedBaseBranch("upstream/main", remoteName: "origin") == "upstream/main")
        #expect(GitLabCLIProvider.normalizedBaseBranch("release/1.0", remoteName: "origin") == "release/1.0")
    }

    @Test func qualifiedHeadProjectReturnsForkProjectOnlyForDifferentHeadOwner() {
        #expect(GitLabCLIProvider.qualifiedHeadProject(
            headOwner: "nacho",
            baseOwner: "platform/mobile",
            repository: "alas"
        ) == "nacho/alas")
        #expect(GitLabCLIProvider.qualifiedHeadProject(
            headOwner: nil,
            baseOwner: "platform/mobile",
            repository: "alas"
        ) == nil)
        #expect(GitLabCLIProvider.qualifiedHeadProject(
            headOwner: "",
            baseOwner: "platform/mobile",
            repository: "alas"
        ) == nil)
        #expect(GitLabCLIProvider.qualifiedHeadProject(
            headOwner: "platform/mobile",
            baseOwner: "platform/mobile",
            repository: "alas"
        ) == nil)
    }

    @Test func createOutputParsesHTTPURL() throws {
        let url = try GitLabCLIProvider.parseCreateOutput("https://gitlab.example.com/platform/mobile/alas/-/merge_requests/44\n")

        #expect(url == URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/44"))
    }

    @Test func createOutputParsesFirstHTTPURLFromHumanReadableOutput() throws {
        let url = try GitLabCLIProvider.parseCreateOutput(
            """
            !46 Add GitLab provider (feature/gitlab-provider)
            https://gitlab.example.com/platform/mobile/alas/-/merge_requests/46
            """
        )

        #expect(url == URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/46"))
    }

    @Test func createOutputRejectsNonURLAndNonHTTPURL() {
        #expect(throws: CodeHostProviderError.malformedOutput("glab mr create returned an invalid URL")) {
            try GitLabCLIProvider.parseCreateOutput("not a url")
        }
        #expect(throws: CodeHostProviderError.malformedOutput("glab mr create returned an invalid URL")) {
            try GitLabCLIProvider.parseCreateOutput("git@gitlab.example.com:platform/mobile/alas.git")
        }
        #expect(throws: CodeHostProviderError.malformedOutput("glab mr create returned an invalid URL")) {
            try GitLabCLIProvider.parseCreateOutput("file:///tmp/mr")
        }
        #expect(throws: CodeHostProviderError.malformedOutput("glab mr create returned an invalid URL")) {
            try GitLabCLIProvider.parseCreateOutput("https://")
        }
    }

    @Test func mrListJSONParsesReviewRequest() throws {
        let request = try #require(try GitLabCLIProvider.parseMRList(Self.mrListOutput, remote: Self.remote, headOwner: nil))

        #expect(request.number == 42)
        #expect(request.title == "Add GitLab provider")
        #expect(request.url == URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42"))
        #expect(request.state == .open)
        #expect(request.isDraft == false)
        #expect(request.headRefName == "feature/gitlab-provider")
        #expect(request.baseRefName == "main")
        #expect(request.reviewDecision == .unknown)
        #expect(request.mergeState == .clean)
        #expect(request.provider == .gitlab)
    }

    @Test func mrViewJSONParsesReviewRequest() throws {
        let request = try GitLabCLIProvider.parseMRView(Self.mrViewOutput, remote: Self.remote)

        #expect(request.number == 42)
        #expect(request.title == "Add GitLab provider")
        #expect(request.isDraft == true)
        #expect(request.reviewDecision == .reviewRequired)
        #expect(request.mergeState == .blocked)
    }

    @Test func mrListReturnsNilForNoItems() throws {
        #expect(try GitLabCLIProvider.parseMRList("[]", remote: Self.remote, headOwner: nil) == nil)
    }

    @Test func mrParsingRequiresIID() throws {
        let listOutput = """
        [
          {
            "id": 4242,
            "title": "Add GitLab provider",
            "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42",
            "state": "opened",
            "draft": false,
            "source_branch": "feature/gitlab-provider",
            "target_branch": "main"
          }
        ]
        """
        let viewOutput = """
        {
          "id": 4242,
          "title": "Add GitLab provider",
          "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42",
          "state": "opened",
          "draft": false,
          "source_branch": "feature/gitlab-provider",
          "target_branch": "main"
        }
        """

        #expect(throws: CodeHostProviderError.malformedOutput("glab mr list output is missing a merge request iid")) {
            _ = try GitLabCLIProvider.parseMRList(listOutput, remote: Self.remote, headOwner: nil)
        }
        #expect(throws: CodeHostProviderError.malformedOutput("glab mr view output is missing a merge request iid")) {
            _ = try GitLabCLIProvider.parseMRView(viewOutput, remote: Self.remote)
        }
    }

    @Test func mrListFiltersByHeadOwnerWhenSourceProjectMetadataMatches() throws {
        let output = """
        [
          {
            "iid": 42,
            "title": "Base project MR",
            "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42",
            "state": "opened",
            "draft": false,
            "source_branch": "feature/gitlab-provider",
            "target_branch": "main",
            "source_project": { "path_with_namespace": "platform/mobile/alas" }
          },
          {
            "iid": 43,
            "title": "Fork MR",
            "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/43",
            "state": "opened",
            "draft": false,
            "source_branch": "feature/gitlab-provider",
            "target_branch": "main",
            "source_project": { "path_with_namespace": "nacho/alas" }
          }
        ]
        """

        let request = try #require(try GitLabCLIProvider.parseMRList(output, remote: Self.remote, headOwner: "nacho"))

        #expect(request.number == 43)
        #expect(request.title == "Fork MR")
    }

    @Test func mrListReturnsNilWhenHeadOwnerMetadataDoesNotMatch() throws {
        let output = """
        [
          {
            "iid": 42,
            "title": "Base project MR",
            "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42",
            "state": "opened",
            "draft": false,
            "source_branch": "feature/gitlab-provider",
            "target_branch": "main",
            "source_project_path_with_namespace": "platform/mobile/alas"
          },
          {
            "iid": 43,
            "title": "Other fork MR",
            "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/43",
            "state": "opened",
            "draft": false,
            "source_branch": "feature/gitlab-provider",
            "target_branch": "main",
            "source_project_path": "other/alas"
          }
        ]
        """

        #expect(try GitLabCLIProvider.parseMRList(output, remote: Self.remote, headOwner: "nacho") == nil)
    }

    @Test func mrListReturnsNilForAmbiguousHeadOwnerWithoutSourceProjectMetadata() throws {
        let output = """
        [
          {
            "iid": 42,
            "title": "First MR",
            "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42",
            "state": "opened",
            "draft": false,
            "source_branch": "feature/gitlab-provider",
            "target_branch": "main"
          },
          {
            "iid": 43,
            "title": "Second MR",
            "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/43",
            "state": "opened",
            "draft": false,
            "source_branch": "feature/gitlab-provider",
            "target_branch": "main"
          }
        ]
        """

        #expect(try GitLabCLIProvider.parseMRList(output, remote: Self.remote, headOwner: "nacho") == nil)
    }

    @Test func mrMergeStatusesMapToReviewMergeState() throws {
        let cases: [(status: String, mergeState: ReviewMergeState)] = [
            ("mergeable", .clean),
            ("can_be_merged", .clean),
            ("conflict", .dirty),
            ("conflicts", .dirty),
            ("cannot_be_merged", .dirty),
            ("need_rebase", .dirty),
            ("cannot_be_merged_recheck", .unstable),
            ("checking", .unstable),
            ("unchecked", .unstable),
            ("preparing", .unstable),
            ("ci_still_running", .unstable),
            ("commits_status", .unstable),
            ("approvals_syncing", .unstable),
            ("not_ready", .unstable),
            ("requested_changes", .blocked),
            ("blocked_status", .blocked),
            ("ci_must_pass", .blocked),
            ("discussions_not_resolved", .blocked),
            ("not_approved", .blocked),
            ("draft_status", .blocked),
            ("external_status_checks", .blocked),
            ("security_policy_pipeline_check", .blocked),
        ]

        for testCase in cases {
            let output = """
            {
              "iid": 42,
              "title": "Add GitLab provider",
              "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42",
              "state": "opened",
              "draft": false,
              "source_branch": "feature/gitlab-provider",
              "target_branch": "main",
              "detailed_merge_status": "\(testCase.status)"
            }
            """

            let request = try GitLabCLIProvider.parseMRView(output, remote: Self.remote)

            #expect(request.mergeState == testCase.mergeState)
        }
    }

    @Test func pipelineJSONPrefersJobLevelChecks() throws {
        let checks = try GitLabCLIProvider.parsePipeline(Self.pipelineWithJobsOutput)

        #expect(checks.count == 2)
        #expect(checks.map(\.name) == ["build", "test"])
        #expect(checks.map(\.workflow) == ["feature/gitlab-provider", "feature/gitlab-provider"])
        #expect(checks.map(\.bucket) == [.pass, .fail])
        #expect(checks[0].detailURL == URL(string: "https://gitlab.example.com/platform/mobile/alas/-/jobs/101"))
        #expect(checks[1].detailURL == URL(string: "https://gitlab.example.com/platform/mobile/alas/-/jobs/102"))
        #expect(checks[0].completedAt == ISO8601DateFormatter().date(from: "2026-06-01T12:34:56Z"))
        #expect(checks[1].completedAt == ISO8601DateFormatter().date(from: "2026-06-01T12:35:56Z"))
        #expect(checks[0].id != checks[1].id)
    }

    @Test func pipelineJSONFallsBackToPipelineLevelCheckWhenJobsAreMissing() throws {
        let checks = try GitLabCLIProvider.parsePipeline(Self.pipelineOutput)

        #expect(checks.count == 1)
        #expect(checks[0].name == "pipeline")
        #expect(checks[0].workflow == "feature/gitlab-provider")
        #expect(checks[0].bucket == .pass)
        #expect(checks[0].detailURL == URL(string: "https://gitlab.example.com/platform/mobile/alas/-/pipelines/777"))
        #expect(checks[0].completedAt == ISO8601DateFormatter().date(from: "2026-06-01T12:36:56Z"))
    }

    @Test func pipelineCheckStatusesMapGitLabAliases() throws {
        let cases: [(status: String, bucket: ReviewCheckBucket)] = [
            ("waiting_for_resource", .pending),
            ("manual", .pending),
            ("scheduled", .pending),
            ("cancelled", .cancel),
            ("skipped", .skipping),
            ("blocked", .unknown),
        ]

        for testCase in cases {
            let checks = try GitLabCLIProvider.parsePipeline(
                """
                {
                  "id": 777,
                  "status": "\(testCase.status)",
                  "ref": "feature/gitlab-provider",
                  "web_url": "https://gitlab.example.com/platform/mobile/alas/-/pipelines/777",
                  "jobs": []
                }
                """
            )

            #expect(checks.map(\.bucket) == [testCase.bucket])
        }
    }

    @Test func pipelineJSONRejectsMalformedURLAndDate() throws {
        #expect(throws: CodeHostProviderError.malformedOutput("glab ci get returned an invalid URL")) {
            _ = try GitLabCLIProvider.parsePipeline(
                """
                {
                  "id": 777,
                  "status": "success",
                  "ref": "feature/gitlab-provider",
                  "web_url": "file:///tmp/pipeline",
                  "jobs": []
                }
                """
            )
        }

        #expect(throws: CodeHostProviderError.malformedOutput("Unable to parse GitLab date")) {
            _ = try GitLabCLIProvider.parsePipeline(
                """
                {
                  "id": 777,
                  "status": "success",
                  "ref": "feature/gitlab-provider",
                  "web_url": "https://gitlab.example.com/platform/mobile/alas/-/pipelines/777",
                  "finished_at": "not-a-date",
                  "jobs": []
                }
                """
            )
        }
    }

    @Test func currentReviewRequestUsesExpectedMRListCommand() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.mrListOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mrViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.discussionsOutput, stderr: ""),
        ])

        let request = try await GitLabCLIProvider(runner: runner).currentReviewRequest(
            remote: Self.remote,
            branch: "feature/gitlab-provider",
            headOwner: nil,
            baseBranch: "origin/main",
            cwd: Self.cwd
        )

        #expect(request?.number == 42)
        #expect(await runner.commands.map(\.args.first) == ["mr", "mr", "mr", "ci"])
        #expect(await runner.commands.first == FakeRunner.Command(
            executable: "glab",
            args: [
                "mr", "list",
                "--source-branch", "feature/gitlab-provider",
                "--target-branch", "main",
                "--output", "json",
                "--per-page", "20",
                "-R", "platform/mobile/alas",
            ],
            cwd: Self.cwd
        ))
        #expect(await runner.commands[1] == FakeRunner.Command(
            executable: "glab",
            args: ["mr", "view", "42", "--output", "json", "-R", "platform/mobile/alas"],
            cwd: Self.cwd
        ))
        #expect(await runner.commands[2] == FakeRunner.Command(
            executable: "glab",
            args: [
                "mr", "note", "list", "42",
                "--state", "unresolved",
                "--output", "json",
                "-R", "platform/mobile/alas",
            ],
            cwd: Self.cwd
        ))
        #expect(await runner.commands[3] == FakeRunner.Command(
            executable: "glab",
            args: [
                "ci", "get",
                "--merge-request", "42",
                "--with-job-details",
                "--output", "json",
                "-R", "platform/mobile/alas",
            ],
            cwd: Self.cwd
        ))
    }

    @Test func checksLoadsMRHeadPipeline() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.pipelineWithJobsOutput, stderr: ""),
        ])
        let request = try GitLabCLIProvider.parseMRView(Self.mrViewOutput, remote: Self.remote)

        let checks = try await GitLabCLIProvider(runner: runner).checks(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )

        #expect(checks.map(\.name) == ["build", "test"])
        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "glab",
                args: [
                    "ci", "get",
                    "--merge-request", "42",
                    "--with-job-details",
                    "--output", "json",
                    "-R", "platform/mobile/alas",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func checksReturnsEmptyWhenNoPipelineIsReported() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "no pipeline found for merge request !42"),
        ])
        let request = try GitLabCLIProvider.parseMRView(Self.mrViewOutput, remote: Self.remote)

        let checks = try await GitLabCLIProvider(runner: runner).checks(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )

        #expect(checks.isEmpty)
    }

    @Test func checksThrowsCommandFailedOnOtherNonzeroExit() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "authentication failed"),
        ])
        let request = try GitLabCLIProvider.parseMRView(Self.mrViewOutput, remote: Self.remote)

        await #expect(throws: CodeHostProviderError.commandFailed(
            command: "glab ci get",
            stderr: "authentication failed"
        )) {
            _ = try await GitLabCLIProvider(runner: runner).checks(
                remote: Self.remote,
                request: request,
                cwd: Self.cwd
            )
        }
    }

    @Test func rerunFailedChecksRetriesFailedJobs() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.pipelineWithFailedJobsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
        ])
        let request = try GitLabCLIProvider.parseMRView(Self.mrViewOutput, remote: Self.remote)

        try await GitLabCLIProvider(runner: runner).rerunFailedChecks(
            remote: Self.remote,
            branch: "feature/gitlab-provider",
            headSHA: "abc123",
            request: request,
            cwd: Self.cwd
        )

        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "glab",
                args: [
                    "ci", "get",
                    "--merge-request", "42",
                    "--status", "failed",
                    "--with-job-details",
                    "--output", "json",
                    "-R", "platform/mobile/alas",
                ],
                cwd: Self.cwd
            ),
            FakeRunner.Command(
                executable: "glab",
                args: ["ci", "retry", "102", "-R", "platform/mobile/alas"],
                cwd: Self.cwd
            ),
            FakeRunner.Command(
                executable: "glab",
                args: ["ci", "retry", "103", "-R", "platform/mobile/alas"],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func rerunFailedChecksDoesNothingWhenNoFailedJobs() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.pipelineWithSuccessfulJobsOutput, stderr: ""),
        ])
        let request = try GitLabCLIProvider.parseMRView(Self.mrViewOutput, remote: Self.remote)

        try await GitLabCLIProvider(runner: runner).rerunFailedChecks(
            remote: Self.remote,
            branch: "feature/gitlab-provider",
            headSHA: "abc123",
            request: request,
            cwd: Self.cwd
        )

        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "glab",
                args: [
                    "ci", "get",
                    "--merge-request", "42",
                    "--status", "failed",
                    "--with-job-details",
                    "--output", "json",
                    "-R", "platform/mobile/alas",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func rerunFailedChecksTreatsNoPipelineAsNoop() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "no pipeline found for branch feature/gitlab-provider"),
        ])
        let request = try GitLabCLIProvider.parseMRView(Self.mrViewOutput, remote: Self.remote)

        try await GitLabCLIProvider(runner: runner).rerunFailedChecks(
            remote: Self.remote,
            branch: "feature/gitlab-provider",
            headSHA: "abc123",
            request: request,
            cwd: Self.cwd
        )

        #expect(await runner.commands.count == 1)
    }

    @Test func rerunFailedChecksThrowsOnGetFailure() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "authentication failed"),
        ])
        let request = try GitLabCLIProvider.parseMRView(Self.mrViewOutput, remote: Self.remote)

        await #expect(throws: CodeHostProviderError.commandFailed(
            command: "glab ci get",
            stderr: "authentication failed"
        )) {
            try await GitLabCLIProvider(runner: runner).rerunFailedChecks(
                remote: Self.remote,
                branch: "feature/gitlab-provider",
                headSHA: "abc123",
                request: request,
                cwd: Self.cwd
            )
        }
    }

    @Test func rerunFailedChecksThrowsOnRetryFailure() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.pipelineWithFailedJobsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
            ProcessResult(exitCode: 1, stdout: "", stderr: "retry failed"),
        ])
        let request = try GitLabCLIProvider.parseMRView(Self.mrViewOutput, remote: Self.remote)

        await #expect(throws: CodeHostProviderError.commandFailed(
            command: "glab ci retry",
            stderr: "retry failed"
        )) {
            try await GitLabCLIProvider(runner: runner).rerunFailedChecks(
                remote: Self.remote,
                branch: "feature/gitlab-provider",
                headSHA: "abc123",
                request: request,
                cwd: Self.cwd
            )
        }
    }

    @Test func currentReviewRequestIncludesPipelineChecks() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.mrListOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mrViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.discussionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.pipelineWithJobsOutput, stderr: ""),
        ])

        let request = try await GitLabCLIProvider(runner: runner).currentReviewRequest(
            remote: Self.remote,
            branch: "feature/gitlab-provider",
            headOwner: nil,
            baseBranch: "origin/main",
            cwd: Self.cwd
        )

        #expect(request?.checks.map(\.name) == ["build", "test"])
        #expect(await runner.commands.map { Array($0.args.prefix(2)) } == [
            ["mr", "list"],
            ["mr", "view"],
            ["mr", "note"],
            ["ci", "get"],
        ])
    }

    @Test func createReviewRequestUsesExpectedArgsForNormalMR() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/44\n", stderr: ""),
        ])

        _ = try await GitLabCLIProvider(runner: runner).createReviewRequest(
            remote: Self.remote,
            branch: "feature/gitlab-provider",
            headOwner: nil,
            baseBranch: "origin/main",
            title: "Add GitLab provider",
            body: "## Summary\n- Adds GitLab support",
            isDraft: false,
            cwd: Self.cwd
        )

        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "glab",
                args: [
                    "mr", "create",
                    "--source-branch", "feature/gitlab-provider",
                    "--target-branch", "main",
                    "--title", "Add GitLab provider",
                    "--description", "## Summary\n- Adds GitLab support",
                    "--yes",
                    "-R", "platform/mobile/alas",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func createReviewRequestIncludesHeadProjectForForkHeadOwner() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/46\n", stderr: ""),
        ])

        _ = try await GitLabCLIProvider(runner: runner).createReviewRequest(
            remote: Self.remote,
            branch: "feature/gitlab-provider",
            headOwner: "nacho",
            baseBranch: "main",
            title: "Add GitLab provider",
            body: "Body",
            isDraft: false,
            cwd: Self.cwd
        )

        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "glab",
                args: [
                    "mr", "create",
                    "--source-branch", "feature/gitlab-provider",
                    "--target-branch", "main",
                    "--title", "Add GitLab provider",
                    "--description", "Body",
                    "--yes",
                    "-R", "platform/mobile/alas",
                    "--head", "nacho/alas",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func createReviewRequestThrowsCommandFailedOnNonzeroExit() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "create failed"),
        ])

        await #expect(throws: CodeHostProviderError.commandFailed(
            command: "glab mr create",
            stderr: "create failed"
        )) {
            _ = try await GitLabCLIProvider(runner: runner).createReviewRequest(
                remote: Self.remote,
                branch: "feature/gitlab-provider",
                headOwner: nil,
                baseBranch: "main",
                title: "Add GitLab provider",
                body: "Body",
                isDraft: false,
                cwd: Self.cwd
            )
        }
    }

    @Test func createReviewRequestAddsDraftFlagForDraftMR() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/45\n", stderr: ""),
        ])

        _ = try await GitLabCLIProvider(runner: runner).createReviewRequest(
            remote: Self.remote,
            branch: "feature/gitlab-provider",
            headOwner: nil,
            baseBranch: "main",
            title: "Add GitLab provider",
            body: "Body",
            isDraft: true,
            cwd: Self.cwd
        )

        let args = try #require(await runner.commands.first?.args)
        #expect(args.contains("--draft"))
    }

    private static let remote = CodeHostRemote(
        kind: .gitlab,
        host: "gitlab.example.com",
        owner: "platform/mobile",
        repository: "alas",
        remoteName: "origin",
        webURL: URL(string: "https://gitlab.example.com/platform/mobile/alas")!
    )

    private static let cwd = URL(fileURLWithPath: "/tmp/alas")

    private static let mrListOutput = """
    [
      {
        "iid": 42,
        "title": "Add GitLab provider",
        "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42",
        "state": "opened",
        "draft": false,
        "source_branch": "feature/gitlab-provider",
        "target_branch": "main",
        "merge_status": "can_be_merged",
        "detailed_merge_status": "mergeable"
      }
    ]
    """

    private static let mrViewOutput = """
    {
      "iid": 42,
      "title": "Add GitLab provider",
      "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42",
      "state": "opened",
      "draft": true,
      "source_branch": "feature/gitlab-provider",
      "target_branch": "main",
      "merge_status": "cannot_be_merged",
      "detailed_merge_status": "not_approved",
      "approvals_required": 1,
      "approvals_left": 1
    }
    """

    private static let discussionsOutput = "[]"

    private static let pipelineOutput = """
    {
      "id": 777,
      "status": "success",
      "ref": "feature/gitlab-provider",
      "web_url": "https://gitlab.example.com/platform/mobile/alas/-/pipelines/777",
      "updated_at": "2026-06-01T12:36:56Z",
      "jobs": []
    }
    """

    private static let pipelineWithJobsOutput = """
    {
      "id": 777,
      "status": "failed",
      "ref": "feature/gitlab-provider",
      "web_url": "https://gitlab.example.com/platform/mobile/alas/-/pipelines/777",
      "jobs": [
        {
          "id": 101,
          "name": "build",
          "status": "success",
          "web_url": "https://gitlab.example.com/platform/mobile/alas/-/jobs/101",
          "finished_at": "2026-06-01T12:34:56Z"
        },
        {
          "id": 102,
          "name": "test",
          "status": "failed",
          "web_url": "https://gitlab.example.com/platform/mobile/alas/-/jobs/102",
          "finished_at": "2026-06-01T12:35:56Z"
        }
      ]
    }
    """

    private static let pipelineWithFailedJobsOutput = """
    {
      "id": 778,
      "status": "failed",
      "ref": "feature/gitlab-provider",
      "web_url": "https://gitlab.example.com/platform/mobile/alas/-/pipelines/778",
      "jobs": [
        {
          "id": 101,
          "name": "build",
          "status": "success",
          "web_url": "https://gitlab.example.com/platform/mobile/alas/-/jobs/101"
        },
        {
          "id": 102,
          "name": "test",
          "status": "failed",
          "web_url": "https://gitlab.example.com/platform/mobile/alas/-/jobs/102"
        },
        {
          "id": 103,
          "name": "lint",
          "status": "failed",
          "web_url": "https://gitlab.example.com/platform/mobile/alas/-/jobs/103"
        }
      ]
    }
    """

    private static let pipelineWithSuccessfulJobsOutput = """
    {
      "id": 779,
      "status": "success",
      "ref": "feature/gitlab-provider",
      "web_url": "https://gitlab.example.com/platform/mobile/alas/-/pipelines/779",
      "jobs": [
        {
          "id": 104,
          "name": "build",
          "status": "success",
          "web_url": "https://gitlab.example.com/platform/mobile/alas/-/jobs/104"
        },
        {
          "id": 105,
          "name": "test",
          "status": "skipped",
          "web_url": "https://gitlab.example.com/platform/mobile/alas/-/jobs/105"
        }
      ]
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
