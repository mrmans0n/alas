import Foundation
import Testing
@testable import Alas

private final class InboxRecordingGGRunner: GGCommandRunning, @unchecked Sendable {
    private let result: ProcessResult
    private(set) var lastArgs: [String] = []
    private(set) var lastCwd: URL?

    init(result: ProcessResult) {
        self.result = result
    }

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        lastArgs = args
        lastCwd = cwd
        return result
    }
}

struct GGServiceInboxTests {
    @Test func inboxRunsAtRepoPathAndDecodes() async throws {
        let json = #"{"version":1,"total_items":0,"buckets":{"ready_to_land":[],"changes_requested":[],"blocked_on_ci":[],"awaiting_review":[],"behind_base":[],"draft":[]},"stack_errors":[]}"#
        let runner = InboxRecordingGGRunner(result: ProcessResult(exitCode: 0, stdout: json, stderr: ""))
        let service = GGService(runner: runner)
        let snapshot = try await service.inbox(repoPath: "/repo/root")
        #expect(runner.lastArgs == ["inbox", "--json"])
        #expect(runner.lastCwd?.path == "/repo/root")
        #expect(snapshot.totalItems == 0)
    }

    @Test func inboxMapsExitCode127ToCLIMissing() async {
        let runner = InboxRecordingGGRunner(result: ProcessResult(exitCode: 127, stdout: "", stderr: "not found"))
        let service = GGService(runner: runner)
        await #expect(throws: GGServiceError.self) {
            _ = try await service.inbox(repoPath: "/repo/root")
        }
    }

    @Test func inboxThrowsOnMalformedStdout() async {
        let runner = InboxRecordingGGRunner(result: ProcessResult(exitCode: 0, stdout: "garbage", stderr: ""))
        let service = GGService(runner: runner)
        await #expect(throws: GGServiceError.self) {
            _ = try await service.inbox(repoPath: "/repo/root")
        }
    }
}
