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
        #expect(await runner.commands.map(\.args.first) == ["mr", "mr", "mr"])
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
