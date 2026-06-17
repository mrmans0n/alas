import Foundation
import Testing
@testable import Alas

struct GitLabCLIProviderVerdictTests {
    // MARK: - startReview

    @Test func startReviewReturnsNonEmptyLocalID() async throws {
        let runner = FakeRunner(results: [])
        let provider = GitLabCLIProvider(runner: runner)
        let id = try await provider.startReview(
            remote: Self.remote,
            request: Self.makeRequest(),
            cwd: Self.cwd
        )
        #expect(!id.isEmpty)
    }

    // MARK: - addReviewComment

    @Test func addReviewCommentBuffersWithoutAPICall() async throws {
        let runner = FakeRunner(results: [])
        let provider = GitLabCLIProvider(runner: runner)
        let request = Self.makeRequest()

        let reviewID = try await provider.startReview(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )
        try await provider.addReviewComment(
            remote: Self.remote,
            request: request,
            reviewID: reviewID,
            comment: StagedComment(
                id: UUID(),
                threadID: nil,
                filePath: "Sources/Foo.swift",
                line: 10,
                side: .new,
                body: "Nice change",
                suggestion: nil
            ),
            cwd: Self.cwd
        )

        let commands = await runner.commands
        #expect(commands.isEmpty)
    }

    // MARK: - submitReview

    @Test func submitReviewPostsNoteForEachStagedComment() async throws {
        // 1 inline staged comment + non-empty body → 3 API calls (versions + discussion + summary note)
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.versionsOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: "{}", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "{}", stderr: ""),
        ])
        let provider = GitLabCLIProvider(runner: runner)
        let request = Self.makeRequest()

        let reviewID = try await provider.startReview(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )
        try await provider.addReviewComment(
            remote: Self.remote,
            request: request,
            reviewID: reviewID,
            comment: StagedComment(
                id: UUID(),
                threadID: nil,
                filePath: "Sources/Bar.swift",
                line: 5,
                side: .new,
                body: "Consider renaming this",
                suggestion: nil
            ),
            cwd: Self.cwd
        )
        try await provider.submitReview(
            remote: Self.remote,
            request: request,
            reviewID: reviewID,
            verdict: .comment,
            body: "Overall looks good",
            cwd: Self.cwd
        )

        let commands = await runner.commands
        #expect(commands.count == 3)
    }

    @Test func submitReviewWithApproveCallsGlabMrApprove() async throws {
        // .approve with body → summary note + glab mr approve = 2 calls
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: "{}", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "{}", stderr: ""),
        ])
        let provider = GitLabCLIProvider(runner: runner)
        let request = Self.makeRequest()

        let reviewID = try await provider.startReview(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )
        try await provider.submitReview(
            remote: Self.remote,
            request: request,
            reviewID: reviewID,
            verdict: .approve,
            body: "LGTM",
            cwd: Self.cwd
        )

        let commands = await runner.commands
        #expect(commands.count == 2)
        // Last call must be the glab mr approve command
        let lastArgs = commands.last?.args ?? []
        #expect(lastArgs.contains("approve"))
    }

    @Test func submitReviewWithEmptyBodySkipsSummaryNote() async throws {
        // .comment verdict + empty body + no staged comments → 0 API calls
        let runner = FakeRunner(results: [])
        let provider = GitLabCLIProvider(runner: runner)
        let request = Self.makeRequest()

        let reviewID = try await provider.startReview(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )
        try await provider.submitReview(
            remote: Self.remote,
            request: request,
            reviewID: reviewID,
            verdict: .comment,
            body: "",
            cwd: Self.cwd
        )

        let commands = await runner.commands
        #expect(commands.isEmpty)
    }

    // MARK: - Fixtures

    private static let remote = CodeHostRemote(
        kind: .gitlab,
        host: "gitlab.example.com",
        owner: "platform/mobile",
        repository: "alas",
        remoteName: "origin",
        webURL: URL(string: "https://gitlab.example.com/platform/mobile/alas")!
    )

    private static let cwd = URL(fileURLWithPath: "/tmp/alas")

    private static let versionsOutput = """
    [
      {
        "base_commit_sha": "base123",
        "head_commit_sha": "head123",
        "start_commit_sha": "start123"
      }
    ]
    """

    private static func makeRequest(
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
            reviewDecision: .unknown,
            mergeState: .unknown,
            checks: checks,
            threads: threads
        )
    }
}

// MARK: - FakeRunner

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
