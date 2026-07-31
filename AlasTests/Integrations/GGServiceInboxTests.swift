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

private struct InboxSequenceFailure: Sendable {
    let name: String
    let lines: [String]
}

struct GGServiceInboxTests {
    @Test func inboxStreamsAtRepoPathAndDecodes() async throws {
        let ndjson = [
            #"{"event":"start","total_candidates":0,"total_stack_errors":0,"version":1,"command":"inbox"}"#,
            #"{"event":"summary","total_items":0,"buckets":{"refresh_failed":[],"ready_to_land":[],"changes_requested":[],"blocked_on_ci":[],"awaiting_review":[],"behind_base":[],"draft":[]},"stack_errors":[],"version":1,"command":"inbox"}"#,
        ].joined(separator: "\n")
        let runner = InboxRecordingGGRunner(result: ProcessResult(exitCode: 0, stdout: ndjson, stderr: ""))

        var events: [GGInboxEvent] = []
        for try await event in GGService(runner: runner).inboxStream(repoPath: "/repo/root") {
            events.append(event)
        }

        #expect(runner.lastArgs == ["inbox", "--jsonl"])
        #expect(runner.lastCwd?.path == "/repo/root")
        #expect(events.count == 2)
    }

    @Test(arguments: [
        InboxSequenceFailure(
            name: "summary without start",
            lines: [summaryLine]
        ),
        InboxSequenceFailure(
            name: "duplicate start",
            lines: [startLine, startLine, summaryLine]
        ),
        InboxSequenceFailure(
            name: "duplicate summary",
            lines: [startLine, summaryLine, summaryLine]
        ),
        InboxSequenceFailure(
            name: "entry after summary",
            lines: [startLine, summaryLine, entryLine]
        ),
        InboxSequenceFailure(
            name: "clean EOF after start without summary",
            lines: [startLine]
        ),
        InboxSequenceFailure(
            name: "malformed line",
            lines: [startLine, "not json"]
        ),
        InboxSequenceFailure(
            name: "entry total differs from start",
            lines: [startLine, entryWithDifferentTotalLine]
        ),
    ])
    func inboxRejectsInvalidSequence(_ fixture: InboxSequenceFailure) async {
        let runner = InboxRecordingGGRunner(result: ProcessResult(
            exitCode: 0,
            stdout: fixture.lines.joined(separator: "\n"),
            stderr: ""
        ))

        await #expect(throws: GGServiceError.self, "Expected \(fixture.name) to be rejected.") {
            for try await _ in GGService(runner: runner).inboxStream(repoPath: "/repo/root") {}
        }
    }

    @Test func inboxAcceptsSoleFatalEventAndSurfacesItsMessage() async {
        let line = #"{"version":1,"command":"inbox","status":"error","event":"error","message":"Not in a git repository"}"#
        let runner = InboxRecordingGGRunner(result: ProcessResult(exitCode: 1, stdout: line, stderr: "fallback stderr"))

        await #expect(throws: GGServiceError.commandFailed(stderr: "Not in a git repository")) {
            for try await _ in GGService(runner: runner).inboxStream(repoPath: "/repo/root") {}
        }
    }

    private static let startLine = #"{"event":"start","total_candidates":1,"total_stack_errors":0,"version":1,"command":"inbox"}"#
    private static let summaryLine = #"{"event":"summary","total_items":0,"buckets":{"refresh_failed":[],"ready_to_land":[],"changes_requested":[],"blocked_on_ci":[],"awaiting_review":[],"behind_base":[],"draft":[]},"stack_errors":[],"version":1,"command":"inbox"}"#
    private static let entryLine = #"{"event":"entry","completed":1,"total_candidates":1,"included":true,"bucket":"ready_to_land","remote_state":"open","entry":{"stack_name":"auth","position":1,"sha":"abc123","title":"Add login","pr_number":42,"pr_url":"https://example.test/42","ci_status":"success","behind_base":null},"version":1,"command":"inbox"}"#
    private static let entryWithDifferentTotalLine = #"{"event":"entry","completed":1,"total_candidates":2,"included":true,"bucket":"ready_to_land","remote_state":"open","entry":{"stack_name":"auth","position":1,"sha":"abc123","title":"Add login","pr_number":42,"pr_url":"https://example.test/42","ci_status":"success","behind_base":null},"version":1,"command":"inbox"}"#
}
