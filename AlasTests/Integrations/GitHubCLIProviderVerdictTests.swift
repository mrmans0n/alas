import Foundation
import Testing
@testable import Alas

struct GitHubCLIProviderVerdictTests {
    // MARK: - startReview

    @Test func startReviewFetchesPRNodeIDThenCallsAddPullRequestReview() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.prNodeIDOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.addReviewOutput, stderr: ""),
        ])

        let reviewID = try await GitHubCLIProvider(runner: runner).startReview(
            remote: Self.remote,
            request: Self.makeRequest(),
            cwd: Self.cwd
        )

        #expect(reviewID == "review-abc123")
        let commands = await runner.commands
        #expect(commands.count == 2)

        // First command: fetch PR node ID
        let nodeIDCmd = commands[0]
        #expect(nodeIDCmd.executable == "gh")
        #expect(nodeIDCmd.args.contains("api"))
        #expect(nodeIDCmd.args.contains("graphql"))
        let nodeIDQueryArg = try #require(nodeIDCmd.args.first { $0.hasPrefix("query=") })
        #expect(nodeIDQueryArg.contains("pullRequest"))
        #expect(nodeIDCmd.args.contains("owner=mrmans0n"))
        #expect(nodeIDCmd.args.contains("repo=alas"))
        #expect(nodeIDCmd.args.contains("number=42"))

        // Second command: addPullRequestReview mutation
        let reviewCmd = commands[1]
        #expect(reviewCmd.executable == "gh")
        let reviewQueryArg = try #require(reviewCmd.args.first { $0.hasPrefix("query=") })
        #expect(reviewQueryArg.contains("addPullRequestReview"))
        #expect(reviewCmd.args.contains("prId=pr-node-42"))
        #expect(reviewCmd.args.contains("commitOID=head-sha-42"))
    }

    // MARK: - addReviewComment

    @Test func addReviewCommentCallsGraphQLWithReviewIDAndPath() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.prNodeIDOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.addCommentOutput, stderr: ""),
        ])
        let comment = StagedComment(
            id: UUID(),
            threadID: nil,
            filePath: "Sources/Foo.swift",
            line: 10,
            side: .new,
            body: "Please rename this variable.",
            suggestion: nil
        )

        try await GitHubCLIProvider(runner: runner).addReviewComment(
            remote: Self.remote,
            request: Self.makeRequest(),
            reviewID: "review-abc123",
            comment: comment,
            cwd: Self.cwd
        )

        let commands = await runner.commands
        #expect(commands.count == 2)
        let cmd = commands[1]
        #expect(cmd.executable == "gh")
        #expect(cmd.args.contains("reviewId=review-abc123"))
        #expect(cmd.args.contains("path=Sources/Foo.swift"))
        #expect(cmd.args.contains("body=Please rename this variable."))
    }

    @Test func addReviewCommentWrapsSuggestionInFence() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.prNodeIDOutput, stderr: ""),
            ProcessResult(exitCode: 0, stdout: Self.addCommentOutput, stderr: ""),
        ])
        let comment = StagedComment(
            id: UUID(),
            threadID: nil,
            filePath: "Sources/Bar.swift",
            line: 20,
            side: .new,
            body: "Use this instead:",
            suggestion: "let x = 42"
        )

        try await GitHubCLIProvider(runner: runner).addReviewComment(
            remote: Self.remote,
            request: Self.makeRequest(),
            reviewID: "review-abc123",
            comment: comment,
            cwd: Self.cwd
        )

        let commands = await runner.commands
        let cmd = commands[1]
        let bodyArg = try #require(cmd.args.first { $0.hasPrefix("body=") })
        #expect(bodyArg.contains("```suggestion"))
        #expect(bodyArg.contains("let x = 42"))
        #expect(bodyArg.contains("```"))
    }

    // MARK: - submitReview

    @Test func submitReviewCallsGraphQLWithVerdict() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.submitReviewOutput, stderr: ""),
        ])

        try await GitHubCLIProvider(runner: runner).submitReview(
            remote: Self.remote,
            request: Self.makeRequest(),
            reviewID: "review-abc123",
            verdict: .approve,
            body: "Looks good!",
            cwd: Self.cwd
        )

        let cmd = try #require(await runner.commands.first)
        #expect(cmd.executable == "gh")
        let queryArg = try #require(cmd.args.first { $0.hasPrefix("query=") })
        #expect(queryArg.contains("submitPullRequestReview"))
        #expect(cmd.args.contains("reviewId=review-abc123"))
        #expect(cmd.args.contains("event=APPROVE"))
        #expect(cmd.args.contains("body=Looks good!"))
    }

    @Test func submitReviewMapsRequestChangesToCorrectEvent() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: Self.submitReviewOutput, stderr: ""),
        ])

        try await GitHubCLIProvider(runner: runner).submitReview(
            remote: Self.remote,
            request: Self.makeRequest(),
            reviewID: "review-abc123",
            verdict: .requestChanges,
            body: "Please address the nits.",
            cwd: Self.cwd
        )

        let cmd = try #require(await runner.commands.first)
        #expect(cmd.args.contains("event=REQUEST_CHANGES"))
        #expect(cmd.args.contains("body=Please address the nits."))
    }

    // MARK: - Fixtures

    private static let remote = CodeHostRemote(
        kind: .github,
        host: "github.com",
        owner: "mrmans0n",
        repository: "alas",
        remoteName: "origin",
        webURL: URL(string: "https://github.com/mrmans0n/alas")!
    )

    private static let cwd = URL(fileURLWithPath: "/tmp/alas")

    private static func makeRequest() -> ReviewRequest {
        ReviewRequest(
            remote: Self.remote,
            number: 42,
            title: "Add GitHub provider",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/42")!,
            state: .open,
            isDraft: false,
            headRefName: "feature/github-provider",
            baseRefName: "main",
            headSHA: "head-sha-42",
            reviewDecision: .approved,
            mergeState: .clean,
            checks: [],
            threads: []
        )
    }

    private static let prNodeIDOutput = """
    {
      "data": {
        "repository": {
          "pullRequest": {
            "id": "pr-node-42"
          }
        }
      }
    }
    """

    private static let addReviewOutput = """
    {
      "data": {
        "addPullRequestReview": {
          "pullRequestReview": {
            "id": "review-abc123"
          }
        }
      }
    }
    """

    private static let addCommentOutput = """
    {
      "data": {
        "addPullRequestReviewComment": {
          "comment": {
            "id": "comment-1"
          }
        }
      }
    }
    """

    private static let submitReviewOutput = """
    {
      "data": {
        "submitPullRequestReview": {
          "pullRequestReview": {
            "id": "review-abc123"
          }
        }
      }
    }
    """
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
