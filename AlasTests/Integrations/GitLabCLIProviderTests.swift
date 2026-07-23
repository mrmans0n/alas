import CryptoKit
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

        #expect(await GitLabCLIProvider(runner: successRunner).isAvailable(cwd: Self.cwd))
        #expect(await GitLabCLIProvider(runner: failureRunner).isAvailable(cwd: Self.cwd) == false)
        #expect(await successRunner.commands == [
            FakeRunner.Command(executable: "glab", args: ["--version"], cwd: Self.cwd),
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

    @Test func reviewImageRevisionsAndFileDataUseReviewedGitLabDiffRefs() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.versionsWithMultipleHeadsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: #"{"content":"iVBO\nRw==","encoding":"base64"}"#, stderr: ""),
        ])
        let request = Self.makeRequest(headSHA: "reviewed-head")
        let provider = GitLabCLIProvider(runner: runner)

        let revisions = try await provider.reviewImageRevisions(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )
        let data = try await provider.reviewFileData(
            remote: Self.remote,
            repository: "nacho/alas-fork",
            revision: revisions.afterSHA,
            path: "Assets/Diff image.png",
            cwd: Self.cwd
        )

        #expect(revisions == CodeHostReviewImageRevisions(
            beforeSHA: "reviewed-base",
            afterSHA: "reviewed-head"
        ))
        #expect(data == Data([0x89, 0x50, 0x4e, 0x47]))
        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "glab",
                args: [
                    "api",
                    "projects/platform%2Fmobile%2Falas/merge_requests/42/versions",
                    "--hostname", "gitlab.example.com",
                    "--output", "json",
                ],
                cwd: Self.cwd
            ),
            FakeRunner.Command(
                executable: "glab",
                args: [
                    "api",
                    "projects/nacho%2Falas-fork/repository/files/Assets%2FDiff%20image.png?ref=reviewed-head",
                    "--method", "GET",
                    "--hostname", "gitlab.example.com",
                    "--output", "json",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func reviewImageRevisionsRejectsMissingReviewedHeadSHA() async {
        let runner = FakeRunner(results: [])

        await #expect(throws: CodeHostProviderError.malformedOutput("GitLab image revisions require the reviewed merge request head SHA.")) {
            _ = try await GitLabCLIProvider(runner: runner).reviewImageRevisions(
                remote: Self.remote,
                request: Self.makeRequest(headSHA: " \n "),
                cwd: Self.cwd
            )
        }
        #expect(await runner.commands.isEmpty)
    }

    @Test func reviewFileDataRejectsInvalidBase64() async {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: #"{"content":"not valid base64!","encoding":"base64"}"#, stderr: ""),
        ])

        await #expect(throws: CodeHostProviderError.malformedOutput("glab api repository file returned invalid base64 content")) {
            _ = try await GitLabCLIProvider(runner: runner).reviewFileData(
                remote: Self.remote,
                repository: "platform/mobile/alas",
                revision: "head-sha",
                path: "Assets/Diff image.png",
                cwd: Self.cwd
            )
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
        #expect(request.headSHA == "head123")
        #expect(request.reviewDecision == .unknown)
        #expect(request.mergeState == .clean)
        #expect(request.provider == .gitlab)
    }

    @Test func mrViewJSONParsesReviewRequest() throws {
        let request = try GitLabCLIProvider.parseMRView(Self.mrViewOutput, remote: Self.remote)

        #expect(request.number == 42)
        #expect(request.title == "Add GitLab provider")
        #expect(request.isDraft == true)
        #expect(request.headSHA == "head123")
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
        #expect(threads[0].comments.first?.id == "501")
        #expect(threads[1].id == "discussion-2")
        #expect(threads[1].author == "maintainer")
        #expect(threads[1].url == URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42#note_503"))
        #expect(threads[1].isResolved == false)
        #expect(threads[1].isActionable)
        #expect(threads[1].comments.first?.id == "503")
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

        #expect(threads.first?.path == "Sources/App.swift")
        #expect(threads.first?.line == 24)
        #expect(threads.first?.comments.first?.id == "100")
    }

    @Test func discussionsJSONPreservesLineRangeMetadata() throws {
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
                      "old_path": "Sources/App.swift",
                      "new_line": 26,
                      "old_line": null,
                      "line_range": {
                        "start": {
                          "type": "new",
                          "new_line": 24,
                          "old_line": null
                        },
                        "end": {
                          "type": "new",
                          "new_line": 26,
                          "old_line": null
                        }
                      }
                    }
                  }
                ]
              },
              {
                "id": "discussion-2",
                "resolved": false,
                "notes": [
                  {
                    "id": 101,
                    "body": "This deleted range needs a guard.",
                    "system": false,
                    "web_url": "https://gitlab.example.com/group/proj/-/merge_requests/7#note_101",
                    "author": { "username": "reviewer" },
                    "position": {
                      "new_path": "Sources/App.swift",
                      "old_path": "Sources/App.swift",
                      "new_line": null,
                      "old_line": 14,
                      "line_range": {
                        "start": {
                          "type": "old",
                          "new_line": null,
                          "old_line": 12
                        },
                        "end": {
                          "type": "old",
                          "new_line": null,
                          "old_line": 14
                        }
                      }
                    }
                  }
                ]
              }
            ]
            """,
            requestURL: URL(string: "https://gitlab.example.com/group/proj/-/merge_requests/7")!
        )

        #expect(threads.map(\.id) == ["discussion-1", "discussion-2"])
        #expect(threads[0].line == 26)
        #expect(threads[0].startLine == 24)
        #expect(threads[0].originalLine == nil)
        #expect(threads[0].originalStartLine == nil)
        #expect(threads[1].line == nil)
        #expect(threads[1].startLine == nil)
        #expect(threads[1].originalLine == 14)
        #expect(threads[1].originalStartLine == 12)
        #expect(threads[1].diffSide == "LEFT")
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
        #expect(threads.allSatisfy { $0.path == nil })
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
        #expect(request.headRepositoryOwner == "nacho")
        #expect(request.headRepositoryName == "alas")
        #expect(request.headRepositorySlug == "nacho/alas")
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
            ProcessResult(exitCode: 0, stdout: #"{"username":"viewer"}"#, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.pipelineWithJobsOutput, stderr: ""),
        ])

        let request = try await GitLabCLIProvider(runner: runner).currentReviewRequest(
            remote: Self.remote,
            branch: "feature/gitlab-provider",
            headOwner: nil,
            baseBranch: "origin/main",
            cwd: Self.cwd
        )

        #expect(request?.number == 42)
        #expect(request?.headSHA == "head123")
        #expect(request?.threads.map(\.id) == ["discussion-1", "discussion-2"])
        #expect(request?.hasActionableFeedback == true)
        #expect(await runner.commands.map(\.args.first) == ["mr", "mr", "mr", "api", "ci"])
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
            args: ["api", "user", "--hostname", "gitlab.example.com", "--output", "json"],
            cwd: Self.cwd
        ))
        #expect(await runner.commands[4] == FakeRunner.Command(
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

    @Test func publishReviewCreatesDiscussionsApprovesAndRefreshesMR() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.versionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.createDiscussionOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.approveOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mrViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.discussionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.userOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.pipelineOutput, stderr: ""),
        ])
        let provider = GitLabCLIProvider(runner: runner)

        let result = try await provider.publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            comments: [
                try Self.makeProviderDraftComment(
                    localDraftID: "draft-1",
                    path: "Sources/App.swift",
                    originalPath: "Sources/OldApp.swift",
                    side: .new,
                    lineRange: 24...26,
                    bodyMarkdown: "Please fix this."
                ),
            ],
            decision: .approve,
            summaryBody: "Looks good after this note.",
            cwd: Self.cwd
        ))

        #expect(result.published == [
            ProviderReviewPublishedComment(
                localDraftID: "draft-1",
                providerThreadID: "discussion-1",
                providerCommentID: "501",
                providerURL: URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42#note_501")
            ),
        ])
        #expect(result.failed.isEmpty)
        #expect(result.refreshedRequest.threads.map(\.id) == ["discussion-1", "discussion-2"])

        let commands = await runner.commands
        #expect(commands.map { Array($0.args.prefix(2)) } == [
            ["api", "projects/platform%2Fmobile%2Falas/merge_requests/42/versions"],
            ["api", "projects/platform%2Fmobile%2Falas/merge_requests/42/discussions"],
            ["api", "projects/platform%2Fmobile%2Falas/merge_requests/42/approve"],
            ["mr", "view"],
            ["mr", "note"],
            ["api", "user"],
            ["ci", "get"],
        ])
        let discussionPayload = try Self.jsonObject(from: commands[1].stdin)
        #expect(discussionPayload["body"] as? String == "Please fix this.")
        // glab does not set Content-Type when the body is read from --input, so
        // GitLab rejects the request with HTTP 415 unless we send it explicitly.
        let discussionSetsJSONContentType = Self.sendsJSONContentType(commands[1].args)
        let approveSetsJSONContentType = Self.sendsJSONContentType(commands[2].args)
        #expect(discussionSetsJSONContentType)
        #expect(approveSetsJSONContentType)
        #expect(commands[2].args.suffix(2) == ["--input", "-"])
        let approvePayload = try Self.jsonObject(from: commands[2].stdin)
        #expect(approvePayload["sha"] as? String == "head123")
        let position = try #require(discussionPayload["position"] as? [String: Any])
        #expect(position["position_type"] as? String == "text")
        #expect(position["base_sha"] as? String == "base123")
        #expect(position["start_sha"] as? String == "start123")
        #expect(position["head_sha"] as? String == "head123")
        #expect(position["old_path"] as? String == "Sources/OldApp.swift")
        #expect(position["new_path"] as? String == "Sources/App.swift")
        #expect(position["new_line"] as? Int == 26)
        #expect(position["old_line"] == nil)
        let lineRange = try #require(position["line_range"] as? [String: Any])
        let lineRangeStart = try #require(lineRange["start"] as? [String: Any])
        let lineRangeEnd = try #require(lineRange["end"] as? [String: Any])
        #expect(lineRangeStart["type"] as? String == "new")
        #expect(lineRangeStart["new_line"] as? Int == 24)
        #expect(lineRangeStart["old_line"] == nil)
        #expect(lineRangeStart["line_code"] as? String == "\(Self.gitLabLineCodePathHash("Sources/App.swift"))_0_24")
        #expect(lineRangeEnd["type"] as? String == "new")
        #expect(lineRangeEnd["new_line"] as? Int == 26)
        #expect(lineRangeEnd["old_line"] == nil)
        #expect(lineRangeEnd["line_code"] as? String == "\(Self.gitLabLineCodePathHash("Sources/App.swift"))_0_26")
    }

    @Test func publishReviewUsesZeroNewLineInGitLabDeletedLineRangeCodes() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.versionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.createDiscussionOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mrViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.discussionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.pipelineOutput, stderr: ""),
        ])
        let provider = GitLabCLIProvider(runner: runner)

        _ = try await provider.publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            comments: [
                try Self.makeProviderDraftComment(
                    localDraftID: "draft-1",
                    path: "Sources/OldApp.swift",
                    side: .old,
                    lineRange: 12...14,
                    bodyMarkdown: "This removal needs another look."
                ),
            ],
            decision: .comment,
            summaryBody: "",
            cwd: Self.cwd
        ))

        let commands = await runner.commands
        let discussionPayload = try Self.jsonObject(from: commands[1].stdin)
        let position = try #require(discussionPayload["position"] as? [String: Any])
        let lineRange = try #require(position["line_range"] as? [String: Any])
        let lineRangeStart = try #require(lineRange["start"] as? [String: Any])
        let lineRangeEnd = try #require(lineRange["end"] as? [String: Any])
        #expect(lineRangeStart["type"] as? String == "old")
        #expect(lineRangeStart["old_line"] as? Int == 12)
        #expect(lineRangeStart["new_line"] == nil)
        #expect(lineRangeStart["line_code"] as? String == "\(Self.gitLabLineCodePathHash("Sources/OldApp.swift"))_12_0")
        #expect(lineRangeEnd["type"] as? String == "old")
        #expect(lineRangeEnd["old_line"] as? Int == 14)
        #expect(lineRangeEnd["new_line"] == nil)
        #expect(lineRangeEnd["line_code"] as? String == "\(Self.gitLabLineCodePathHash("Sources/OldApp.swift"))_14_0")
    }

    @Test func publishReviewSelectsGitLabDiffRefsForReviewedHeadSHA() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.versionsWithMultipleHeadsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.createDiscussionOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mrViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.discussionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.pipelineOutput, stderr: ""),
        ])

        _ = try await GitLabCLIProvider(runner: runner).publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(headSHA: "reviewed-head"),
            comments: [try Self.makeProviderDraftComment()],
            decision: .comment,
            summaryBody: "",
            cwd: Self.cwd
        ))

        let commands = await runner.commands
        let discussionPayload = try Self.jsonObject(from: commands[1].stdin)
        let position = try #require(discussionPayload["position"] as? [String: Any])
        #expect(position["base_sha"] as? String == "reviewed-base")
        #expect(position["start_sha"] as? String == "reviewed-start")
        #expect(position["head_sha"] as? String == "reviewed-head")
    }

    @Test func publishReviewRejectsGitLabDiffRefsWithoutReviewedHeadSHA() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.versionsWithMultipleHeadsOutput, stderr: ""),
        ])

        await #expect(throws: CodeHostProviderError.malformedOutput("Unable to find GitLab diff refs for reviewed head SHA.")) {
            _ = try await GitLabCLIProvider(runner: runner).publishReview(ProviderReviewPublishRequest(
                remote: Self.remote,
                reviewRequest: Self.makeRequest(headSHA: "missing-head"),
                comments: [try Self.makeProviderDraftComment()],
                decision: .comment,
                summaryBody: "",
                cwd: Self.cwd
            ))
        }

        let commands = await runner.commands
        #expect(commands.map { Array($0.args.prefix(2)) } == [
            ["api", "projects/platform%2Fmobile%2Falas/merge_requests/42/versions"],
        ])
    }

    @Test func publishReviewCreatesStatusNoteForGitLabRequestChanges() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.versionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.createDiscussionOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.createNoteOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mrViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.discussionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.userOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.pipelineOutput, stderr: ""),
        ])

        let result = try await GitLabCLIProvider(runner: runner).publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            comments: [try Self.makeProviderDraftComment()],
            decision: .requestChanges,
            summaryBody: "Please address the inline notes before merging.",
            cwd: Self.cwd
        ))

        #expect(result.published.map { $0.localDraftID } == ["draft-1"])
        #expect(result.failed.isEmpty)
        #expect(result.warnings.isEmpty)

        let commands = await runner.commands
        #expect(commands.map { Array($0.args.prefix(2)) } == [
            ["api", "projects/platform%2Fmobile%2Falas/merge_requests/42/versions"],
            ["api", "projects/platform%2Fmobile%2Falas/merge_requests/42/discussions"],
            ["api", "projects/platform%2Fmobile%2Falas/merge_requests/42/notes"],
            ["mr", "view"],
            ["mr", "note"],
            ["api", "user"],
            ["ci", "get"],
        ])
        let statusNotePayload = try Self.jsonObject(from: commands[2].stdin)
        #expect(statusNotePayload["body"] as? String == "Please address the inline notes before merging.")
    }

    @Test func publishReviewCreatesGitLabRequestChangesStatusNoteWithoutDrafts() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.createNoteOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mrViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.discussionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.userOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.pipelineOutput, stderr: ""),
        ])

        let result = try await GitLabCLIProvider(runner: runner).publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            comments: [],
            decision: .requestChanges,
            summaryBody: "Please address the inline notes before merging.",
            cwd: Self.cwd
        ))

        #expect(result.published.isEmpty)
        #expect(result.failed.isEmpty)
        #expect(result.warnings.isEmpty)

        let commands = await runner.commands
        #expect(commands.map { Array($0.args.prefix(2)) } == [
            ["api", "projects/platform%2Fmobile%2Falas/merge_requests/42/notes"],
            ["mr", "view"],
            ["mr", "note"],
            ["api", "user"],
            ["ci", "get"],
        ])
        let statusNotePayload = try Self.jsonObject(from: commands[0].stdin)
        #expect(statusNotePayload["body"] as? String == "Please address the inline notes before merging.")
    }

    @Test func publishReviewReturnsFailuresWithoutRemoteWriteForUnknownOnlyDrafts() async throws {
        let runner = FakeRunner(results: [])

        let result = try await GitLabCLIProvider(runner: runner).publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            comments: [
                try Self.makeProviderDraftComment(
                    localDraftID: "draft-1",
                    side: .unknown,
                    lineRange: 24...24
                ),
            ],
            decision: .approve,
            summaryBody: "Looks good.",
            cwd: Self.cwd
        ))

        #expect(result.published.isEmpty)
        #expect(result.failed.map(\.localDraftID) == ["draft-1"])
        #expect(await runner.commands.isEmpty)
    }

    @Test func publishReviewPreservesPublishedMappingsWhenRefreshFails() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.versionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.createDiscussionOutput, stderr: ""),
            ProcessResult(exitCode: 1, stdout: "", stderr: "refresh failed"),
        ])

        let result = try await GitLabCLIProvider(runner: runner).publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            comments: [try Self.makeProviderDraftComment(localDraftID: "draft-1", side: .new)],
            decision: .comment,
            summaryBody: "",
            cwd: Self.cwd
        ))

        #expect(result.published.map(\.localDraftID) == ["draft-1"])
        #expect(result.refreshedRequest == Self.makeRequest())
        #expect(result.warnings.first?.contains("could not refresh") == true)
    }

    @Test func publishReviewPreservesPublishedMappingsWhenDecisionFailsAfterDiscussionCreation() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.versionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.createDiscussionOutput, stderr: ""),
            ProcessResult(exitCode: 1, stdout: "", stderr: "approval failed"),
            ProcessResult(exitCode: 0, stdout: Self.mrViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.discussionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.pipelineOutput, stderr: ""),
        ])

        let result = try await GitLabCLIProvider(runner: runner).publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            comments: [try Self.makeProviderDraftComment(localDraftID: "draft-1", side: .new)],
            decision: .approve,
            summaryBody: "",
            cwd: Self.cwd
        ))

        #expect(result.published.map(\.localDraftID) == ["draft-1"])
        #expect(result.failed.isEmpty)
        #expect(result.refreshedRequest.threads.map(\.id) == ["discussion-1", "discussion-2"])
        #expect(result.warnings.contains {
            $0.contains("could not submit the review decision") && $0.contains("approval failed")
        })
    }

    @Test func publishReviewDoesNotSubmitDecisionWhenAllGitLabDraftPublishesFail() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.versionsOutput, stderr: ""),
            ProcessResult(exitCode: 1, stdout: "", stderr: "line is not commentable"),
        ])

        let result = try await GitLabCLIProvider(runner: runner).publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            comments: [try Self.makeProviderDraftComment(localDraftID: "draft-1", side: .new)],
            decision: .approve,
            summaryBody: "Looks good.",
            cwd: Self.cwd
        ))

        let commands = await runner.commands
        #expect(commands.map { Array($0.args.prefix(2)) } == [
            ["api", "projects/platform%2Fmobile%2Falas/merge_requests/42/versions"],
            ["api", "projects/platform%2Fmobile%2Falas/merge_requests/42/discussions"],
        ])
        #expect(result.published.isEmpty)
        #expect(result.failed.map(\.localDraftID) == ["draft-1"])
        #expect(result.failed.first?.message.contains("line is not commentable") == true)
        #expect(result.refreshedRequest == Self.makeRequest())
        #expect(result.warnings.contains { $0.contains("approval was not submitted") })
    }

    @Test func publishReviewDoesNotApproveWhenSomeGitLabDraftPublishesFail() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.versionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.createDiscussionOutput, stderr: ""),
            ProcessResult(exitCode: 1, stdout: "", stderr: "line is not commentable"),
            ProcessResult(exitCode: 0, stdout: Self.mrViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.discussionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.userOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.pipelineOutput, stderr: ""),
        ])

        let result = try await GitLabCLIProvider(runner: runner).publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            comments: [
                try Self.makeProviderDraftComment(localDraftID: "draft-1", side: .new, lineRange: 24...24),
                try Self.makeProviderDraftComment(localDraftID: "draft-2", side: .new, lineRange: 25...25),
            ],
            decision: .approve,
            summaryBody: "Looks good.",
            cwd: Self.cwd
        ))

        let commands = await runner.commands
        #expect(commands.map { Array($0.args.prefix(2)) } == [
            ["api", "projects/platform%2Fmobile%2Falas/merge_requests/42/versions"],
            ["api", "projects/platform%2Fmobile%2Falas/merge_requests/42/discussions"],
            ["api", "projects/platform%2Fmobile%2Falas/merge_requests/42/discussions"],
            ["mr", "view"],
            ["mr", "note"],
            ["api", "user"],
            ["ci", "get"],
        ])
        #expect(result.published.map(\.localDraftID) == ["draft-1"])
        #expect(result.failed.map(\.localDraftID) == ["draft-2"])
        #expect(result.refreshedRequest.threads.map(\.id) == ["discussion-1", "discussion-2"])
        #expect(result.warnings.contains { $0.contains("approval was not submitted") })
    }

    @Test func publishReviewDoesNotSubmitGitLabRequestChangesNoteWhenSomeDraftPublishesFail() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.versionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.createDiscussionOutput, stderr: ""),
            ProcessResult(exitCode: 1, stdout: "", stderr: "line is not commentable"),
            ProcessResult(exitCode: 0, stdout: Self.mrViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.discussionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.userOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.pipelineOutput, stderr: ""),
        ])

        let result = try await GitLabCLIProvider(runner: runner).publishReview(ProviderReviewPublishRequest(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            comments: [
                try Self.makeProviderDraftComment(localDraftID: "draft-1", side: .new, lineRange: 24...24),
                try Self.makeProviderDraftComment(localDraftID: "draft-2", side: .new, lineRange: 25...25),
            ],
            decision: .requestChanges,
            summaryBody: "Please address the inline notes before merging.",
            cwd: Self.cwd
        ))

        let commands = await runner.commands
        #expect(commands.map { Array($0.args.prefix(2)) } == [
            ["api", "projects/platform%2Fmobile%2Falas/merge_requests/42/versions"],
            ["api", "projects/platform%2Fmobile%2Falas/merge_requests/42/discussions"],
            ["api", "projects/platform%2Fmobile%2Falas/merge_requests/42/discussions"],
            ["mr", "view"],
            ["mr", "note"],
            ["api", "user"],
            ["ci", "get"],
        ])
        #expect(result.published.map(\.localDraftID) == ["draft-1"])
        #expect(result.failed.map(\.localDraftID) == ["draft-2"])
        #expect(result.refreshedRequest.threads.map(\.id) == ["discussion-1", "discussion-2"])
        #expect(result.warnings.contains { $0.contains("request changes note was not submitted") })
    }

    @Test func threadMutationsUseDiscussionEndpointsAndRefreshMR() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.createNoteOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mrViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.discussionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.userOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.pipelineOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.resolveDiscussionOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.mrViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.discussionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.userOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.pipelineOutput, stderr: ""),
        ])
        let thread = ReviewThreadSummary(
            id: "discussion-1",
            author: "reviewer",
            body: "Please fix this.",
            url: URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42#note_501"),
            isResolved: false,
            isActionable: true,
            location: nil,
            providerThreadID: "discussion-1",
            providerCommentID: "501"
        )
        let provider = GitLabCLIProvider(runner: runner)

        let reply = try await provider.mutateReviewThread(ProviderThreadMutation(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            thread: thread,
            kind: .reply,
            bodyMarkdown: "Fixed locally.",
            cwd: Self.cwd
        ))
        _ = try await provider.mutateReviewThread(ProviderThreadMutation(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            thread: thread,
            kind: .resolve,
            bodyMarkdown: nil,
            cwd: Self.cwd
        ))

        #expect(reply.providerURL == URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42#note_502"))
        let commands = await runner.commands
        #expect(commands[0].args == [
            "api",
            "projects/platform%2Fmobile%2Falas/merge_requests/42/discussions/discussion-1/notes",
            "--method", "POST",
            "--hostname", "gitlab.example.com",
            "-H", "Content-Type: application/json",
            "--input", "-",
        ])
        #expect(commands[5].args == [
            "api",
            "projects/platform%2Fmobile%2Falas/merge_requests/42/discussions/discussion-1",
            "--method", "PUT",
            "--hostname", "gitlab.example.com",
            "-H", "Content-Type: application/json",
            "--input", "-",
        ])
        #expect(try Self.jsonObject(from: commands[5].stdin)["resolved"] as? Bool == true)
    }

    @Test func gitLabMergeRequestAPIPathUsesSelectedRemoteProjectPath() {
        #expect(GitLabCLIProvider.mergeRequestAPIPath(
            remote: Self.remote,
            request: Self.makeRequest(),
            suffix: "discussions"
        ) == "projects/platform%2Fmobile%2Falas/merge_requests/42/discussions")
    }

    @Test func threadMutationRejectsUnsupportedGitLabUnresolve() async throws {
        let runner = FakeRunner(results: [])
        let thread = ReviewThreadSummary(
            id: "discussion-1",
            author: "reviewer",
            body: "Please fix this.",
            url: nil,
            isResolved: true,
            isActionable: true,
            location: nil,
            providerThreadID: "discussion-1",
            providerCommentID: "501"
        )

        await #expect(throws: CodeHostProviderError.malformedOutput("GitLab unresolve is not supported until resolved discussions are loaded.")) {
            _ = try await GitLabCLIProvider(runner: runner).mutateReviewThread(ProviderThreadMutation(
                remote: Self.remote,
                reviewRequest: Self.makeRequest(),
                thread: thread,
                kind: .unresolve,
                bodyMarkdown: nil,
                cwd: Self.cwd
            ))
        }

        let commands = await runner.commands
        #expect(commands.isEmpty)
    }

    @Test func threadMutationPreservesSuccessfulReplyWhenRefreshFails() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.createNoteOutput, stderr: ""),
            ProcessResult(exitCode: 1, stdout: "", stderr: "refresh failed"),
        ])
        let thread = ReviewThreadSummary(
            id: "discussion-1",
            author: nil,
            body: "Body",
            url: nil,
            isResolved: false,
            isActionable: true,
            location: nil,
            providerThreadID: "discussion-1",
            providerCommentID: "501"
        )

        let result = try await GitLabCLIProvider(runner: runner).mutateReviewThread(ProviderThreadMutation(
            remote: Self.remote,
            reviewRequest: Self.makeRequest(),
            thread: thread,
            kind: .reply,
            bodyMarkdown: "Fixed.",
            cwd: Self.cwd
        ))

        #expect(result.providerURL == URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42#note_502"))
        #expect(result.refreshedRequest == Self.makeRequest())
        #expect(result.warnings.contains {
            $0.contains("GitLab thread was updated, but Alas could not refresh the MR")
        })
    }

    @Test func currentReviewRequestResolvesSourceProjectIDsBeforeFilteringForkMRs() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.duplicateForkMRListOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: #"{"path_with_namespace":"platform/mobile/alas"}"#, stderr: ""),
            ProcessResult(exitCode: 0, stdout: #"{"path_with_namespace":"nacho/alas"}"#, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.forkMRViewOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.discussionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: #"{"username":"viewer"}"#, stderr: ""),
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
            ["api", "user"],
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
            ProcessResult(exitCode: 0, stdout: #"{"username":"viewer"}"#, stderr: ""),
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
            ["api", "user"],
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

    @Test func mergeReviewRequestRunsSquashRemoveSourceBranch() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
        ])
        let provider = GitLabCLIProvider(runner: runner)
        let request = Self.makeRequest()

        try await provider.mergeReviewRequest(request, method: .squash, deleteBranch: true, cwd: Self.cwd)

        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "glab",
                args: [
                    "mr", "merge", "42",
                    "--squash",
                    "--remove-source-branch",
                    "--sha", "head123",
                    "--yes",
                    "-R", "platform/mobile/alas",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    private static let discussionsWithPositionOutput = """
    [
      { "id": "disc-1", "resolved": false, "notes": [
        { "id": 101, "system": false, "body": "tighten this",
          "author": { "username": "reviewer" },
          "position": { "new_path": "src/foo.rb", "new_line": 12, "old_line": null } }
      ]}
    ]
    """

    @Test func parsesDiscussionPosition() throws {
        let threads = try GitLabCLIProvider.parseDiscussions(
            Self.discussionsWithPositionOutput,
            requestURL: URL(string: "https://gitlab.com/group/proj/-/merge_requests/7")!)
        let thread = try #require(threads.first)
        #expect(thread.path == "src/foo.rb")
        #expect(thread.line == 12)
        #expect(thread.comments.first?.id == "101")
    }

    @Test func parsesDiscussionWithoutPositionIsFileLevel() throws {
        let output = """
        [
          {
            "id": "disc-no-pos",
            "resolved": false,
            "notes": [
              {
                "id": 201,
                "system": false,
                "body": "General file comment, no position.",
                "author": { "username": "reviewer" }
              }
            ]
          }
        ]
        """
        let threads = try GitLabCLIProvider.parseDiscussions(
            output,
            requestURL: URL(string: "https://gitlab.com/group/proj/-/merge_requests/7")!)
        let thread = try #require(threads.first)
        #expect(thread.isFileLevel == true)
        #expect(thread.line == nil)
    }

    @Test func discussionsMarksCurrentUserCommentsAsEditableAndDeletable() throws {
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
                "author": { "username": "viewer" }
              }
            ]
          }
        ]
        """

        let threads = try GitLabCLIProvider.parseDiscussions(
            output,
            requestURL: URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42")!,
            currentUserUsername: "viewer"
        )

        let comment = try #require(threads.first?.comments.first)
        #expect(comment.viewerCanUpdate == true)
        #expect(comment.viewerCanDelete == true)
    }

    @Test func discussionsMarksOtherUserCommentsAsNotEditable() throws {
        let threads = try GitLabCLIProvider.parseDiscussions(
            Self.discussionsOutput,
            requestURL: URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42")!,
            currentUserUsername: "viewer"
        )

        #expect(threads[0].comments[0].viewerCanUpdate == false)
        #expect(threads[0].comments[0].viewerCanDelete == false)
    }

    @Test func urlEncodedProjectSlugPercentEncodesPathSegments() {
        let forkRemote = CodeHostRemote(
            kind: .gitlab,
            host: "gitlab.example.com",
            owner: "platform/mobile",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://gitlab.example.com/platform/mobile/alas")!
        )

        #expect(GitLabCLIProvider.urlEncodedProjectSlug(forkRemote) == "platform%2Fmobile%2Falas")
    }

    @Test func noteIDRequiresNumericCommentID() throws {
        let comment = ReviewComment(
            id: "123",
            author: nil,
            body: "note",
            url: nil,
            createdAt: nil,
            viewerCanUpdate: true,
            viewerCanDelete: true,
            isPending: false
        )

        #expect(try GitLabCLIProvider.noteID(from: comment) == 123)
        #expect(throws: CodeHostProviderError.malformedOutput("Unable to parse note id")) {
            _ = try GitLabCLIProvider.noteID(from: ReviewComment(
                id: "not-a-number",
                author: nil,
                body: "note",
                url: nil,
                createdAt: nil,
                viewerCanUpdate: false,
                viewerCanDelete: false,
                isPending: false
            ))
        }
    }

    @Test func noteIDFromThreadRequiresFirstCommentID() throws {
        let thread = ReviewThread(
            id: "discussion-1",
            path: nil,
            line: nil,
            startLine: nil,
            originalLine: nil,
            diffHunk: nil,
            isResolved: false,
            isOutdated: false,
            isFileLevel: true,
            comments: [
                ReviewComment(
                    id: "501",
                    author: nil,
                    body: "first",
                    url: nil,
                    createdAt: nil,
                    viewerCanUpdate: false,
                    viewerCanDelete: false,
                    isPending: false
                ),
            ],
            viewerCanResolve: true,
            viewerCanReply: true,
            url: nil
        )

        #expect(try GitLabCLIProvider.noteID(from: thread) == 501)

        let emptyThread = ReviewThread(
            id: "discussion-2",
            path: nil,
            line: nil,
            startLine: nil,
            originalLine: nil,
            diffHunk: nil,
            isResolved: false,
            isOutdated: false,
            isFileLevel: true,
            comments: [],
            viewerCanResolve: true,
            viewerCanReply: true,
            url: nil
        )

        #expect(throws: CodeHostProviderError.malformedOutput("Unable to determine discussion note id")) {
            _ = try GitLabCLIProvider.noteID(from: emptyThread)
        }
    }

    @Test func parseCurrentUserUsernameRequiresUsernameField() throws {
        #expect(try GitLabCLIProvider.parseCurrentUserUsername(#"{"username":"viewer"}"#) == "viewer")
        #expect(throws: CodeHostProviderError.malformedOutput("glab api user output is missing username")) {
            _ = try GitLabCLIProvider.parseCurrentUserUsername(#"{"id":1}"#)
        }
        #expect(throws: CodeHostProviderError.malformedOutput("Unable to parse glab api user output")) {
            _ = try GitLabCLIProvider.parseCurrentUserUsername("not json")
        }
    }

    @Test func parseNoteResponseReturnsReviewComment() throws {
        let json = """
        {
          "id": 601,
          "body": "reply body",
          "author": { "username": "viewer" },
          "created_at": "2026-06-01T12:00:00Z",
          "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42#note_601"
        }
        """

        let comment = try GitLabCLIProvider.parseNoteResponse(
            json,
            requestURL: URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42")!
        )

        #expect(comment.id == "601")
        #expect(comment.body == "reply body")
        #expect(comment.author == "viewer")
        #expect(comment.viewerCanUpdate == true)
        #expect(comment.viewerCanDelete == true)
    }

    @Test func parseNoteResponseFailsMissingID() {
        #expect(throws: CodeHostProviderError.malformedOutput("glab note response is missing a note id")) {
            _ = try GitLabCLIProvider.parseNoteResponse(
                #"{"body":"no id"}"#,
                requestURL: URL(string: "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42")!
            )
        }
    }

    @Test func replyToThreadCallsDiscussionNotesEndpoint() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(
                exitCode: 0,
                stdout: #"{"id": 601, "body": "Thanks for the feedback.", "author": {"username": "viewer"}}"#,
                stderr: ""
            ),
        ])
        let request = Self.makeRequest()
        let thread = ReviewThread(
            id: "discussion-1",
            path: nil,
            line: nil,
            startLine: nil,
            originalLine: nil,
            diffHunk: nil,
            isResolved: false,
            isOutdated: false,
            isFileLevel: true,
            comments: [
                ReviewComment(
                    id: "501",
                    author: "reviewer",
                    body: "Please surface this unresolved note.",
                    url: nil,
                    createdAt: nil,
                    viewerCanUpdate: false,
                    viewerCanDelete: false,
                    isPending: false
                ),
            ],
            viewerCanResolve: true,
            viewerCanReply: true,
            url: nil
        )

        let comment = try await GitLabCLIProvider(runner: runner).replyToThread(
            remote: Self.remote,
            request: request,
            thread: thread,
            body: "Thanks for the feedback.",
            cwd: Self.cwd
        )

        #expect(comment.id == "601")
        #expect(comment.body == "Thanks for the feedback.")
        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "glab",
                args: [
                    "api",
                    "projects/platform%2Fmobile%2Falas/merge_requests/42/discussions/discussion-1/notes",
                    "--hostname", "gitlab.example.com",
                    "--output", "json",
                    "-X", "POST",
                    "-f", "body=Thanks for the feedback.",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func resolveThreadCallsDiscussionResolveEndpoint() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
        ])
        let request = Self.makeRequest()
        let thread = Self.makeThread()

        let resolved = try await GitLabCLIProvider(runner: runner).resolveThread(
            remote: Self.remote,
            request: request,
            thread: thread,
            cwd: Self.cwd
        )

        #expect(resolved.isResolved == true)
        #expect(resolved.id == thread.id)
        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "glab",
                args: [
                    "api",
                    "projects/platform%2Fmobile%2Falas/merge_requests/42/discussions/discussion-1?resolved=true",
                    "--hostname", "gitlab.example.com",
                    "--output", "json",
                    "-X", "PUT",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func unresolveThreadCallsDiscussionUnresolveEndpoint() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
        ])
        let request = Self.makeRequest()
        let thread = Self.makeThread(isResolved: true)

        let unresolved = try await GitLabCLIProvider(runner: runner).unresolveThread(
            remote: Self.remote,
            request: request,
            thread: thread,
            cwd: Self.cwd
        )

        #expect(unresolved.isResolved == false)
        #expect(unresolved.id == thread.id)
        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "glab",
                args: [
                    "api",
                    "projects/platform%2Fmobile%2Falas/merge_requests/42/discussions/discussion-1?resolved=false",
                    "--hostname", "gitlab.example.com",
                    "--output", "json",
                    "-X", "PUT",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func resolveThreadThrowsOnNonzeroExit() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "not authorized"),
        ])
        let request = Self.makeRequest()
        let thread = Self.makeThread()

        await #expect(throws: CodeHostProviderError.commandFailed(command: "glab api resolve discussion", stderr: "not authorized")) {
            _ = try await GitLabCLIProvider(runner: runner).resolveThread(
                remote: Self.remote,
                request: request,
                thread: thread,
                cwd: Self.cwd
            )
        }
    }

    @Test func editCommentCallsNotesUpdateEndpoint() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(
                exitCode: 0,
                stdout: #"{"id": 501, "body": "Updated text.", "author": {"username": "viewer"}}"#,
                stderr: ""
            ),
        ])
        let request = Self.makeRequest()
        let comment = ReviewComment(
            id: "501",
            author: "viewer",
            body: "Please surface this unresolved note.",
            url: nil,
            createdAt: nil,
            viewerCanUpdate: true,
            viewerCanDelete: true,
            isPending: false
        )

        let updated = try await GitLabCLIProvider(runner: runner).editComment(
            remote: Self.remote,
            request: request,
            comment: comment,
            newBody: "Updated text.",
            cwd: Self.cwd
        )

        #expect(updated.id == "501")
        #expect(updated.body == "Updated text.")
        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "glab",
                args: [
                    "api",
                    "projects/platform%2Fmobile%2Falas/merge_requests/42/notes/501",
                    "--hostname", "gitlab.example.com",
                    "--output", "json",
                    "-X", "PUT",
                    "-f", "body=Updated text.",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func editCommentThrowsForNonNumericCommentID() async throws {
        let runner = FakeRunner(results: [])
        let request = Self.makeRequest()
        let comment = ReviewComment(
            id: "not-a-number",
            author: nil,
            body: "note",
            url: nil,
            createdAt: nil,
            viewerCanUpdate: false,
            viewerCanDelete: false,
            isPending: false
        )

        await #expect(throws: CodeHostProviderError.malformedOutput("Unable to parse note id")) {
            _ = try await GitLabCLIProvider(runner: runner).editComment(
                remote: Self.remote,
                request: request,
                comment: comment,
                newBody: "new",
                cwd: Self.cwd
            )
        }
    }

    @Test func deleteCommentCallsNotesDeleteEndpoint() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
        ])
        let request = Self.makeRequest()
        let comment = ReviewComment(
            id: "501",
            author: "viewer",
            body: "Please surface this unresolved note.",
            url: nil,
            createdAt: nil,
            viewerCanUpdate: true,
            viewerCanDelete: true,
            isPending: false
        )

        try await GitLabCLIProvider(runner: runner).deleteComment(
            remote: Self.remote,
            request: request,
            comment: comment,
            cwd: Self.cwd
        )

        #expect(await runner.commands == [
            FakeRunner.Command(
                executable: "glab",
                args: [
                    "api",
                    "projects/platform%2Fmobile%2Falas/merge_requests/42/notes/501",
                    "--hostname", "gitlab.example.com",
                    "-X", "DELETE",
                ],
                cwd: Self.cwd
            ),
        ])
    }

    @Test func deleteCommentThrowsOnNonzeroExit() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "forbidden"),
        ])
        let request = Self.makeRequest()
        let comment = ReviewComment(
            id: "501",
            author: nil,
            body: "note",
            url: nil,
            createdAt: nil,
            viewerCanUpdate: false,
            viewerCanDelete: false,
            isPending: false
        )

        await #expect(throws: CodeHostProviderError.commandFailed(command: "glab api delete note", stderr: "forbidden")) {
            try await GitLabCLIProvider(runner: runner).deleteComment(
                remote: Self.remote,
                request: request,
                comment: comment,
                cwd: Self.cwd
            )
        }
    }

    private static func makeThread(isResolved: Bool = false) -> ReviewThread {
        ReviewThread(
            id: "discussion-1",
            path: nil,
            line: nil,
            startLine: nil,
            originalLine: nil,
            diffHunk: nil,
            isResolved: isResolved,
            isOutdated: false,
            isFileLevel: true,
            comments: [
                ReviewComment(
                    id: "501",
                    author: "reviewer",
                    body: "Please surface this unresolved note.",
                    url: nil,
                    createdAt: nil,
                    viewerCanUpdate: false,
                    viewerCanDelete: false,
                    isPending: false
                ),
            ],
            viewerCanResolve: true,
            viewerCanReply: true,
            url: nil
        )
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
        baseSHA: String? = nil,
        headSHA: String = "head123",
        checks: [ReviewCheck] = [],
        threads: [ReviewThread] = []
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
            baseSHA: baseSHA,
            headSHA: headSHA,
            reviewDecision: .unknown,
            mergeState: .unknown,
            checks: checks,
            threads: threads
        )
    }

    private static func makeProviderDraftComment(
        localDraftID: String = "draft-1",
        path: String = "Sources/App.swift",
        originalPath: String? = nil,
        side: DiffReviewInlineFeedbackSide = .new,
        lineRange: ClosedRange<Int> = 24...24,
        selectedText: String? = nil,
        bodyMarkdown: String = "Please fix this."
    ) throws -> ProviderReviewDraftComment {
        let draft = ReviewDraftComment(
            id: localDraftID,
            sessionID: .reviewRequest(
                worktreeID: "wt",
                provider: .gitlab,
                host: "gitlab.example.com",
                repositorySlug: "platform/mobile/alas",
                number: 42
            ),
            fileID: DiffReviewFileID(namespace: "gitlab", path: path),
            path: path,
            originalPath: originalPath,
            side: side,
            startLine: lineRange.lowerBound,
            endLine: lineRange.upperBound == lineRange.lowerBound ? nil : lineRange.upperBound,
            selectedText: selectedText,
            bodyMarkdown: bodyMarkdown,
            state: .active,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        )
        return try #require(ProviderReviewDraftComment(localDraft: draft))
    }

    /// True when the argument list passes an explicit `-H Content-Type: application/json` header.
    private static func sendsJSONContentType(_ args: [String]) -> Bool {
        for index in args.indices.dropLast() where args[index] == "-H" {
            if args[index + 1] == "Content-Type: application/json" {
                return true
            }
        }
        return false
    }

    private static func jsonObject(from stdin: String?) throws -> [String: Any] {
        let stdin = try #require(stdin)
        let data = Data(stdin.utf8)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func gitLabLineCodePathHash(_ path: String) -> String {
        Insecure.SHA1.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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
        "sha": "head123",
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
      "sha": "head123",
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

    private static let versionsOutput = """
    [
      {
        "base_commit_sha": "base123",
        "start_commit_sha": "start123",
        "head_commit_sha": "head123"
      }
    ]
    """

    private static let versionsWithMultipleHeadsOutput = """
    [
      {
        "base_commit_sha": "latest-base",
        "start_commit_sha": "latest-start",
        "head_commit_sha": "latest-head"
      },
      {
        "base_commit_sha": "reviewed-base",
        "start_commit_sha": "reviewed-start",
        "head_commit_sha": "reviewed-head"
      }
    ]
    """

    private static let createDiscussionOutput = """
    {
      "id": "discussion-1",
      "notes": [
        {
          "id": 501,
          "body": "Please fix this.",
          "system": false,
          "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42#note_501",
          "author": { "username": "nacho" }
        }
      ]
    }
    """

    private static let createNoteOutput = """
    {
      "id": 502,
      "body": "Fixed locally.",
      "web_url": "https://gitlab.example.com/platform/mobile/alas/-/merge_requests/42#note_502"
    }
    """

    private static let resolveDiscussionOutput = """
    {
      "id": "discussion-1",
      "resolved": true
    }
    """

    private static let approveOutput = """
    {
      "id": 42,
      "approved": true
    }
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

    private static let userOutput = """
    {
      "id": 9001,
      "username": "viewer"
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
