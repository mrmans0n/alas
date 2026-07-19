import Foundation
import Testing
@testable import Alas

private final class RecordingGGRunner: GGCommandRunning, @unchecked Sendable {
    var stdout: String
    var exitCode: Int32
    var stderr: String
    var syncHelpStdout: String
    private(set) var lastArgs: [String] = []
    private(set) var lastCwd: URL?
    private(set) var calls: [[String]] = []

    init(stdout: String = "", exitCode: Int32 = 0, stderr: String = "", syncHelpStdout: String = "--jsonl") {
        self.stdout = stdout
        self.exitCode = exitCode
        self.stderr = stderr
        self.syncHelpStdout = syncHelpStdout
    }

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        calls.append(args)
        lastArgs = args
        lastCwd = cwd
        if args == ["sync", "--help"] {
            return ProcessResult(exitCode: 0, stdout: syncHelpStdout, stderr: "")
        }
        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}

struct GGServiceActionsTests {
    @Test func syncStreamsParsedEventsFromDefaultRunner() async throws {
        // The default runStreaming splits buffered stdout into lines, so a
        // fake that only implements run() still drives the streaming API.
        let ndjson = [
            #"{"event":"start","total_entries":1}"#,
            #"{"event":"push_started","position":1}"#,
            #"{"event":"pr_created","position":1,"pr_number":7,"pr_url":"https://x/pull/7","draft":false}"#,
            #"{"event":"summary"}"#,
        ].joined(separator: "\n")
        let runner = RecordingGGRunner(stdout: ndjson)
        let service = GGService(runner: runner)

        var events: [GGSyncEvent] = []
        for try await event in service.sync(worktreePath: "/tmp/wt") {
            events.append(event)
        }
        #expect(events == [
            .start(totalEntries: 1),
            .pushStarted(position: 1),
            .prCreated(position: 1, prNumber: 7, prURL: "https://x/pull/7", draft: false),
            .summary,
        ])
        #expect(runner.lastArgs == ["sync", "--jsonl", "--no-rebase-check"])
        #expect(runner.lastCwd == URL(fileURLWithPath: "/tmp/wt"))
    }

    @Test func syncFallsBackToJSONWhenJSONLIsUnsupported() async throws {
        let runner = RecordingGGRunner(stdout: #"{"event":"summary","entries":[]}"#, syncHelpStdout: "--json")
        let service = GGService(runner: runner)

        var events: [GGSyncEvent] = []
        for try await event in service.sync(worktreePath: "/tmp/wt") {
            events.append(event)
        }

        #expect(events == [.summary])
        #expect(runner.calls == [["sync", "--help"], ["sync", "--json", "--no-rebase-check"]])
    }

    @Test func syncFallbackSurfacesJSONSummaryErrors() async throws {
        let runner = RecordingGGRunner(
            stdout: #"{"event":"summary","entries":[{"position":1,"error":"push failed"}]}"#,
            syncHelpStdout: "--json"
        )
        let service = GGService(runner: runner)

        var events: [GGSyncEvent] = []
        for try await event in service.sync(worktreePath: "/tmp/wt") {
            events.append(event)
        }

        #expect(events == [.error(message: "[1] push failed")])
    }

    @Test func landAllSendsAllFlagAndDecodes() async throws {
        let runner = RecordingGGRunner(
            stdout: #"{"version":1,"land":{"stack":"s","base":"main","landed":[{"position":1,"pr_number":9}]}}"#
        )
        let result = try await GGService(runner: runner).land(worktreePath: "/tmp/wt", until: nil)
        #expect(result.landed == [GGLandedEntry(position: 1, prNumber: 9)])
        #expect(runner.lastArgs == ["land", "--all", "--json"])
    }

    @Test func landUntilSendsUntilTarget() async throws {
        let runner = RecordingGGRunner(
            stdout: #"{"version":1,"land":{"stack":"s","base":"main","landed":[]}}"#
        )
        _ = try await GGService(runner: runner).land(worktreePath: "/tmp/wt", until: "c-abc")
        #expect(runner.lastArgs == ["land", "--until", "c-abc", "--json"])
    }

    @Test func landMapsExit127ToCliMissing() async {
        let runner = RecordingGGRunner(exitCode: 127, stderr: "not found")
        await #expect(throws: GGServiceError.cliMissing) {
            _ = try await GGService(runner: runner).land(worktreePath: "/tmp/wt", until: nil)
        }
    }

    @Test func landMapsNonzeroToCommandFailed() async {
        let runner = RecordingGGRunner(exitCode: 1, stderr: "boom")
        await #expect(throws: GGServiceError.commandFailed(stderr: "boom")) {
            _ = try await GGService(runner: runner).land(worktreePath: "/tmp/wt", until: nil)
        }
    }

    @Test func cleanContinueAbortCheckoutSendExpectedArgs() async throws {
        let runner = RecordingGGRunner(stdout: "ok")
        let service = GGService(runner: runner)
        try await service.clean(worktreePath: "/tmp/wt")
        #expect(runner.lastArgs == ["clean", "--all"])
        try await service.continueOp(worktreePath: "/tmp/wt")
        #expect(runner.lastArgs == ["continue"])
        try await service.abortOp(worktreePath: "/tmp/wt")
        #expect(runner.lastArgs == ["abort"])
        try await service.checkout(worktreePath: "/tmp/wt", target: "2")
        #expect(runner.lastArgs == ["mv", "2"])
    }

    @Test func cleanMapsNonzeroToCommandFailed() async {
        let runner = RecordingGGRunner(exitCode: 1, stderr: "dirty")
        await #expect(throws: GGServiceError.commandFailed(stderr: "dirty")) {
            try await GGService(runner: runner).clean(worktreePath: "/tmp/wt")
        }
    }
}
