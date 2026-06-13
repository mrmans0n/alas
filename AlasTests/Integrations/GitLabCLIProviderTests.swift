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

    @Test func discussionsJSONParsesActionableThreads() throws {
        let threads = try GitLabCLIProvider.parseDiscussions(
            Self.discussionsOutput,
            requestURL: URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42")!
        )

        #expect(threads.count == 2)
        #expect(threads[0].id == "discussion-1")
        #expect(threads[0].author == "reviewer")
        #expect(threads[0].body == "Please surface this unresolved note.")
        #expect(threads[0].url == URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42#note_501"))
        #expect(threads[0].isResolved == false)
        #expect(threads[0].isActionable)
        #expect(threads[1].id == "discussion-2")
        #expect(threads[1].author == "maintainer")
        #expect(threads[1].url == URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42#note_503"))
        #expect(threads[1].isResolved == false)
        #expect(threads[1].isActionable)
    }

    @Test func discussionsJSONPreservesLocationMetadata() throws {
        let threads = try GitLabCLIProvider.parseDiscussions(
            """
            [
              {
                "id": "discussion-1",
                "resolved": false,
                "notes": [
                  {
                    "id": 100,
                    "body": "This needs a guard.",
                    "system": false,
                    "web_url": "https://gitlab.example.com/group/proj/-/merge_requests/7#note_100",
                    "author": { "username": "reviewer" },
                    "position": {
                      "new_path": "Sources/App.swift",
                      "old_path": "Sources/OldApp.swift",
                      "new_line": 24,
                      "old_line": null
                    }
                  }
                ]
              }
            ]
            """,
            requestURL: URL(string: "https://gitlab.example.com/group/proj/-/merge_requests/7")!
        )

        #expect(threads.first?.location?.path == "Sources/App.swift")
        #expect(threads.first?.location?.originalPath == "Sources/OldApp.swift")
        #expect(threads.first?.location?.line == 24)
        #expect(threads.first?.location?.side == .new)
        #expect(threads.first?.location?.providerPosition == "100")
    }

    @Test func discussionsJSONIgnoresMalformedPositionMetadata() throws {
        let threads = try GitLabCLIProvider.parseDiscussions(
            """
            [
              {
                "id": "discussion-malformed",
                "resolved": false,
                "notes": [
                  {
                    "id": 101,
                    "body": "Keep this discussion.",
                    "system": false,
                    "web_url": "https://gitlab.example.com/group/proj/-/merge_requests/7#note_101",
                    "author": { "username": "reviewer" },
                    "position": {
                      "new_path": 123,
                      "old_path": "Sources/OldApp.swift",
                      "new_line": "24",
                      "old_line": false
                    }
                  }
                ]
              },
              {
                "id": "discussion-position-string",
                "resolved": false,
                "notes": [
                  {
                    "id": 102,
                    "body": "Keep this non-object position discussion.",
                    "system": false,
                    "web_url": "https://gitlab.example.com/group/proj/-/merge_requests/7#note_102",
                    "author": { "username": "reviewer" },
                    "position": "not-a-position-object"
                  }
                ]
              }
            ]
            """,
            requestURL: URL(string: "https://gitlab.example.com/group/proj/-/merge_requests/7")!
        )

        #expect(threads.map(\.id) == ["discussion-malformed", "discussion-position-string"])
        #expect(threads.first?.body == "Keep this discussion.")
        #expect(threads.allSatisfy { $0.location == nil })
    }

    @Test func discussionsJSONSkipsSystemOnlyDiscussions() throws {
        let threads = try GitLabCLIProvider.parseDiscussions(
            Self.systemOnlyDiscussionsOutput,
            requestURL: URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42")!
        )

        #expect(threads == [])
    }

    @Test func discussionsJSONRejectsMalformedURL() throws {
        let output = """
        [
          {
            "id": "discussion-1",
            "notes": [
              {
                "id": 501,
                "body": "Please surface this unresolved note.",
                "system": false,
                "resolvable": true,
                "resolved": false,
                "web_url": "file:///tmp/note",
                "author": { "username": "reviewer" }
              }
            ]
          }
        ]
        """

        #expect(throws: CodeHostProviderError.malformedOutput("glab mr note list returned an invalid URL")) {
            _ = try GitLabCLIProvider.parseDiscussions(
                output,
                requestURL: URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42")!
            )
        }
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

    @Test func mrListFiltersByResolvedSourceProjectID() throws {
        let request = try #require(try GitLabCLIProvider.parseMRList(
            Self.duplicateForkMRListOutput,
            remote: Self.remote,
            headOwner: "nacho",
            sourceProjectPathsByID: [
                1001: "platform/mobile/alas",
                1002: "nacho/alas",
            ]
        ))

        #expect(request.number == 43)
        #expect(request.title == "Fork MR")
    }

    @Test func mrListFiltersSingleItemByResolvedSourceProjectID() throws {
        let request = try #require(try GitLabCLIProvider.parseMRList(
            Self.singleSourceProjectIDMRListOutput,
            remote: Self.remote,
            headOwner: "nacho",
            sourceProjectPathsByID: [1002: "nacho/alas"]
        ))

        #expect(request.number == 43)
        #expect(try GitLabCLIProvider.parseMRList(
            Self.singleSourceProjectIDMRListOutput,
            remote: Self.remote,
            headOwner: "other",
            sourceProjectPathsByID: [1002: "nacho/alas"]
        ) == nil)
    }

    @Test func projectPathParsingRequiresPathWithNamespace() throws {
        #expect(try GitLabCLIProvider.parseProjectPath(#"{"path_with_namespace":"nacho/alas"}"#) == "nacho/alas")
        #expect(throws: CodeHostProviderError.malformedOutput("glab api project output is missing path_with_namespace")) {
            _ = try GitLabCLIProvider.parseProjectPath(#"{"name":"alas"}"#)
        }
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

    @Test func pipelineJSONTreatsAllowedFailureJobsAsNonBlocking() throws {
        let checks = try GitLabCLIProvider.parsePipeline(Self.pipelineWithAllowedFailureJobsOutput)

        #expect(checks.map(\.name) == ["build", "lint"])
        #expect(checks.map(\.bucket) == [.pass, .skipping])
        #expect(checks.max { $0.bucket.severity < $1.bucket.severity }?.bucket == .pass)
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

    @Test func failedCheckEvidenceUsesPipelineJobs() async throws {
        let checks = try GitLabCLIProvider.parsePipeline(Self.pipelineWithFailedJobsOutput)
        let request = Self.makeRequest(checks: checks)

        let evidence = try await GitLabCLIProvider().failedCheckEvidence(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )

        #expect(evidence.map(\.title) == ["build", "test", "lint", "deploy"])
        #expect(evidence.map(\.status) == [.passed, .failed, .failed, .pending])
    }

    @Test func checkEvidenceDetailLoadsGitLabTraceForJobID() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "failed assertion\n", stderr: ""),
        ])
        let checks = try GitLabCLIProvider.parsePipeline(Self.pipelineWithFailedJobsOutput)
        let request = Self.makeRequest(checks: checks)
        let evidence = try await GitLabCLIProvider(runner: runner).failedCheckEvidence(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )
        let item = try #require(evidence.first { $0.title == "test" })

        let detail = try await GitLabCLIProvider(runner: runner).checkEvidenceDetail(
            remote: Self.remote,
            request: request,
            item: item,
            cwd: Self.cwd
        )

        #expect(detail.body.contains("failed assertion"))
        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "glab",
                args: ["ci", "trace", "102", "-R", "platform/mobile/alas"],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func feedbackEvidenceDetailUsesDiscussionBody() async throws {
        let threads = try GitLabCLIProvider.parseDiscussions(
            Self.discussionsOutput,
            requestURL: URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42")!
        )
        let request = Self.makeRequest(threads: threads)
        let item = try #require(try await GitLabCLIProvider().feedbackEvidence(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        ).first)

        let detail = try await GitLabCLIProvider().feedbackEvidenceDetail(
            remote: Self.remote,
            request: request,
            item: item,
            cwd: Self.cwd
        )

        #expect(detail.body.contains("Please"))
        #expect(detail.item.status == .actionable)
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
        #expect(request?.threads.map(\.id) == ["discussion-1", "discussion-2"])
        #expect(request?.hasActionableFeedback == true)
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

    @Test func reviewDiffUsesMRDiffCommand() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "diff --git a/A.swift b/A.swift\n", stderr: ""),
        ])
        let request = try GitLabCLIProvider.parseMRView(Self.mrViewOutput, remote: Self.remote)

        let diff = try await GitLabCLIProvider(runner: runner).reviewDiff(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )

        #expect(diff == "diff --git a/A.swift b/A.swift\n")
        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "glab",
                args: ["mr", "diff", "42", "--raw", "--color=never", "-R", "platform/mobile/alas"],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func reviewDiffSurfacesGitLabCommandFailure() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "not found"),
        ])
        let request = try GitLabCLIProvider.parseMRView(Self.mrViewOutput, remote: Self.remote)

        await #expect(throws: CodeHostProviderError.commandFailed(command: "glab mr diff", stderr: "not found")) {
            _ = try await GitLabCLIProvider(runner: runner).reviewDiff(
                remote: Self.remote,
                request: request,
                cwd: Self.cwd
            )
        }
    }

    @Test func currentReviewRequestResolvesSourceProjectIDsBeforeFilteringForkMRs() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.duplicateForkMRListOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: #"{"path_with_namespace":"platform/mobile/alas"}"#, stderr: ""),
            ProcessResult(exitCode: 0, stdout: #"{"path_with_namespace":"nacho/alas"}"#, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.forkMRViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.discussionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.pipelineOutput, stderr: ""),
        ])

        let request = try await GitLabCLIProvider(runner: runner).currentReviewRequest(
            remote: Self.remote,
            branch: "feature/gitlab-provider",
            headOwner: "nacho",
            baseBranch: "origin/main",
            cwd: Self.cwd
        )

        #expect(request?.number == 43)
        #expect(await runner.commands.map { Array($0.args.prefix(2)) } == [
            ["mr", "list"],
            ["api", "projects/1001"],
            ["api", "projects/1002"],
            ["mr", "view"],
            ["mr", "note"],
            ["ci", "get"],
        ])
        #expect(await runner.commands[1] == FakeRunner.Command(
            executable: "glab",
            args: ["api", "projects/1001", "--hostname", "gitlab.example.com", "--output", "json"],
            cwd: Self.cwd
        ))
        #expect(await runner.commands[2] == FakeRunner.Command(
            executable: "glab",
            args: ["api", "projects/1002", "--hostname", "gitlab.example.com", "--output", "json"],
            cwd: Self.cwd
        ))
        #expect(await runner.commands[3] == FakeRunner.Command(
            executable: "glab",
            args: ["mr", "view", "43", "--output", "json", "-R", "platform/mobile/alas"],
            cwd: Self.cwd
        ))
    }

    @Test func currentReviewRequestResolvesSingleSourceProjectIDBeforeFiltering() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.singleSourceProjectIDMRListOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: #"{"path_with_namespace":"other/alas"}"#, stderr: ""),
        ])

        let request = try await GitLabCLIProvider(runner: runner).currentReviewRequest(
            remote: Self.remote,
            branch: "feature/gitlab-provider",
            headOwner: "nacho",
            baseBranch: "origin/main",
            cwd: Self.cwd
        )

        #expect(request == nil)
        #expect(await runner.commands == [
            FakeRunner.Command(
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
            ),
            FakeRunner.Command(
                executable: "glab",
                args: ["api", "projects/1002", "--hostname", "gitlab.example.com", "--output", "json"],
                cwd: Self.cwd
            ),
        ])
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
                args: ["ci", "retry", "102", "--pipeline-id", "778", "-R", "platform/mobile/alas"],
                cwd: Self.cwd
            ),
            FakeRunner.Command(
                executable: "glab",
                args: ["ci", "retry", "103", "--pipeline-id", "778", "-R", "platform/mobile/alas"],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func rerunFailedChecksSkipsAllowedFailureJobs() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.pipelineWithAllowedFailureJobsOutput, stderr: ""),
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

    @Test func rerunFailedChecksThrowsWhenFailedPipelineHasNoRetryableJobIDs() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.failedPipelineWithoutRetryableJobIDsOutput, stderr: ""),
        ])
        let request = try GitLabCLIProvider.parseMRView(Self.mrViewOutput, remote: Self.remote)

        await #expect(throws: CodeHostProviderError.malformedOutput(
            "glab ci get output did not include retryable failed job IDs"
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

    @Test func rerunFailedChecksThrowsWhenFailedPipelineIsMissingPipelineID() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.failedPipelineWithoutPipelineIDOutput, stderr: ""),
        ])
        let request = try GitLabCLIProvider.parseMRView(Self.mrViewOutput, remote: Self.remote)

        await #expect(throws: CodeHostProviderError.malformedOutput(
            "glab ci get output is missing a pipeline id for retry"
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

    private static func makeRequest(
        checks: [ReviewCheck] = [],
        threads: [ReviewThreadSummary] = []
    ) -> ReviewRequest {
        ReviewRequest(
            remote: Self.remote,
            number: 42,
            title: "Add GitLab provider",
            url: URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42")!,
            state: .open,
            isDraft: false,
            headRefName: "feature/gitlab-provider",
            baseRefName: "main",
            reviewDecision: .unknown,
            mergeState: .unknown,
            checks: checks,
            threads: threads
        )
    }

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

    private static let forkMRViewOutput = """
    {
      "iid": 43,
      "title": "Fork MR",
      "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/43",
      "state": "opened",
      "draft": false,
      "source_branch": "feature/gitlab-provider",
      "target_branch": "main",
      "merge_status": "can_be_merged",
      "detailed_merge_status": "mergeable"
    }
    """

    private static let duplicateForkMRListOutput = """
    [
      {
        "iid": 42,
        "title": "Base project MR",
        "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42",
        "state": "opened",
        "draft": false,
        "source_branch": "feature/gitlab-provider",
        "target_branch": "main",
        "source_project_id": 1001
      },
      {
        "iid": 43,
        "title": "Fork MR",
        "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/43",
        "state": "opened",
        "draft": false,
        "source_branch": "feature/gitlab-provider",
        "target_branch": "main",
        "source_project_id": 1002
      }
    ]
    """

    private static let singleSourceProjectIDMRListOutput = """
    [
      {
        "iid": 43,
        "title": "Fork MR",
        "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/43",
        "state": "opened",
        "draft": false,
        "source_branch": "feature/gitlab-provider",
        "target_branch": "main",
        "source_project_id": 1002
      }
    ]
    """

    private static let discussionsOutput = """
    [
      {
        "id": "discussion-1",
        "notes": [
          {
            "id": 501,
            "body": "Please surface this unresolved note.",
            "system": false,
            "resolvable": true,
            "resolved": false,
            "author": { "username": "reviewer" }
          },
          {
            "id": 502,
            "body": "changed the title",
            "system": true,
            "resolvable": false,
            "resolved": false,
            "author": { "username": "gitlab-bot" }
          }
        ]
      },
      {
        "id": "discussion-2",
        "resolved": false,
        "notes": [
          {
            "id": 503,
            "body": "This general note should also be actionable.",
            "system": false,
            "author": { "username": "maintainer" },
            "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42#note_503"
          }
        ]
      },
      {
        "id": "system-only",
        "notes": [
          {
            "id": 504,
            "body": "added 1 commit",
            "system": true,
            "author": { "username": "gitlab-bot" }
          }
        ]
      }
    ]
    """

    private static let systemOnlyDiscussionsOutput = """
    [
      {
        "id": "system-only",
        "notes": [
          {
            "id": 504,
            "body": "added 1 commit",
            "system": true,
            "author": { "username": "gitlab-bot" }
          }
        ]
      }
    ]
    """

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
        },
        {
          "id": 104,
          "name": "deploy",
          "status": "running",
          "web_url": "https://gitlab.example.com/platform/mobile/alas/-/jobs/104"
        }
      ]
    }
    """

    private static let failedPipelineWithoutRetryableJobIDsOutput = """
    {
      "id": 781,
      "status": "failed",
      "ref": "feature/gitlab-provider",
      "web_url": "https://gitlab.example.com/platform/mobile/alas/-/pipelines/781",
      "jobs": [
        {
          "name": "test",
          "status": "failed",
          "web_url": "https://gitlab.example.com/platform/mobile/alas/-/jobs/unknown"
        }
      ]
    }
    """

    private static let failedPipelineWithoutPipelineIDOutput = """
    {
      "status": "failed",
      "ref": "feature/gitlab-provider",
      "web_url": "https://gitlab.example.com/platform/mobile/alas/-/pipelines/unknown",
      "jobs": [
        {
          "id": 108,
          "name": "test",
          "status": "failed",
          "web_url": "https://gitlab.example.com/platform/mobile/alas/-/jobs/108"
        }
      ]
    }
    """

    private static let pipelineWithAllowedFailureJobsOutput = """
    {
      "id": 780,
      "status": "success",
      "ref": "feature/gitlab-provider",
      "web_url": "https://gitlab.example.com/platform/mobile/alas/-/pipelines/780",
      "jobs": [
        {
          "id": 106,
          "name": "build",
          "status": "success",
          "allow_failure": false,
          "web_url": "https://gitlab.example.com/platform/mobile/alas/-/jobs/106"
        },
        {
          "id": 107,
          "name": "lint",
          "status": "failed",
          "allow_failure": true,
          "web_url": "https://gitlab.example.com/platform/mobile/alas/-/jobs/107"
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
