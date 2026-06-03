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
