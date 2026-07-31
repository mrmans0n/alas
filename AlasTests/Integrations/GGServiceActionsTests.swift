import Foundation
import Testing
@testable import Alas

private final class RecordingGGRunner: GGCommandRunning, @unchecked Sendable {
    var stdout: String
    var exitCode: Int32
    var stderr: String
    private(set) var lastArgs: [String] = []
    private(set) var lastCwd: URL?
    private(set) var calls: [[String]] = []

    init(stdout: String = "", exitCode: Int32 = 0, stderr: String = "") {
        self.stdout = stdout
        self.exitCode = exitCode
        self.stderr = stderr
    }

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        calls.append(args)
        lastArgs = args
        lastCwd = cwd
        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}

struct GGServiceActionsTests {
    @Test func syncStreamsParsedEventsFromDefaultRunner() async throws {
        // The default runStreaming splits buffered stdout into lines, so a
        // fake that only implements run() still drives the streaming API.
        let ndjson = [
            #"{"event":"start","total_entries":1}"#,
            "not JSON",
            #"{"event":"push_started","position":1}"#,
            #"{"event":"pr_created","position":1,"pr_number":7,"pr_url":"https://x/pull/7","draft":false}"#,
            #"{"event":"summary"}"#,
        ].joined(separator: "\n")
        let runner = RecordingGGRunner(stdout: ndjson)
        let service = GGService(runner: runner)

        var events: [GGSyncEvent] = []
        for try await event in service.sync(worktreePath: "/tmp/wt", supportsJSONL: true) {
            events.append(event)
        }
        #expect(events == [
            .start(totalEntries: 1),
            .pushStarted(position: 1),
            .prCreated(position: 1, prNumber: 7, prURL: "https://x/pull/7", draft: false),
            .summary,
        ])
        #expect(runner.calls == [["sync", "--jsonl"]])
        #expect(runner.lastCwd == URL(fileURLWithPath: "/tmp/wt"))
    }

    @Test func syncFallsBackToJSONWhenJSONLIsUnsupported() async throws {
        let runner = RecordingGGRunner(stdout: #"{"event":"summary","entries":[]}"#)
        let service = GGService(runner: runner)

        var events: [GGSyncEvent] = []
        for try await event in service.sync(worktreePath: "/tmp/wt", supportsJSONL: false) {
            events.append(event)
        }

        #expect(events == [.summary])
        #expect(runner.calls == [["sync", "--json"]])
    }

    @Test func syncFallbackSurfacesJSONSummaryErrors() async throws {
        let runner = RecordingGGRunner(
            stdout: #"{"version":1,"sync":{"entries":[{"position":1,"error":"push failed"},{"position":2,"error":{"message":"PR failed"}}]}}"#
        )
        let service = GGService(runner: runner)

        var events: [GGSyncEvent] = []
        for try await event in service.sync(worktreePath: "/tmp/wt", supportsJSONL: false) {
            events.append(event)
        }

        #expect(events == [
            .error(position: 1, operation: nil, message: "push failed"),
            .error(position: 2, operation: nil, message: "PR failed"),
            .summary,
        ])
    }

    @Test func syncJSONLSummaryYieldsEveryEntryErrorBeforeTerminalSummary() async throws {
        let runner = RecordingGGRunner(
            stdout: #"{"event":"summary","entries":[{"position":1,"error":"push failed"},{"position":2,"error":"PR failed"}]}"#
        )
        let service = GGService(runner: runner)

        var events: [GGSyncEvent] = []
        for try await event in service.sync(worktreePath: "/tmp/wt", supportsJSONL: true) {
            events.append(event)
        }

        #expect(events == [
            .error(position: 1, operation: nil, message: "push failed"),
            .error(position: 2, operation: nil, message: "PR failed"),
            .summary,
        ])
    }

    @Test func landAllSendsAllFlagAndDecodes() async throws {
        let runner = RecordingGGRunner(
            stdout: #"{"version":1,"land":{"stack":"s","base":"main","landed":[{"position":1,"pr_number":9}]}}"#
        )
        let result = try await GGService(runner: runner).land(worktreePath: "/tmp/wt", until: nil)
        #expect(result.landed == [GGLandedEntry(position: 1, prNumber: 9)])
        #expect(runner.lastArgs == ["land", "--all", "--json", "--no-clean"])
    }

    @Test func landUntilSendsUntilTarget() async throws {
        let runner = RecordingGGRunner(
            stdout: #"{"version":1,"land":{"stack":"s","base":"main","landed":[]}}"#
        )
        _ = try await GGService(runner: runner).land(worktreePath: "/tmp/wt", until: "c-abc")
        #expect(runner.lastArgs == ["land", "--until", "c-abc", "--json", "--no-clean"])
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

    @Test func landMapsNonzeroJSONStdoutToCommandFailed() async {
        let runner = RecordingGGRunner(
            stdout: #"{"version":1,"land":{"landed":[],"error":{"message":"not approved"}}}"#,
            exitCode: 1
        )
        await #expect(throws: GGServiceError.commandFailed(stderr: "not approved")) {
            _ = try await GGService(runner: runner).land(worktreePath: "/tmp/wt", until: nil)
        }
    }

    @Test func syncFallbackMapsNonzeroJSONStdoutToCommandFailed() async {
        let runner = RecordingGGRunner(
            stdout: #"{"version":1,"sync":{"entries":[{"position":2,"error":{"message":"push rejected"}}]}}"#,
            exitCode: 1
        )
        let service = GGService(runner: runner)

        await #expect(throws: GGServiceError.commandFailed(stderr: "[2] push rejected")) {
            for try await _ in service.sync(worktreePath: "/tmp/wt", supportsJSONL: false) {}
        }
    }

    @Test func syncJSONLRequiresTerminalSummary() async {
        let runner = RecordingGGRunner(stdout: #"{"event":"start","total_entries":1}"#)
        let service = GGService(runner: runner)

        await #expect(throws: GGServiceError.malformedOutput(
            "gg sync ended without a summary event."
        )) {
            for try await _ in service.sync(worktreePath: "/tmp/wt", supportsJSONL: true) {}
        }
    }

    @Test func syncJSONLRejectsEventsAfterSummary() async {
        let runner = RecordingGGRunner(stdout: [
            #"{"event":"summary"}"#,
            #"{"event":"push_done","position":1,"forced":false}"#,
        ].joined(separator: "\n"))
        let service = GGService(runner: runner)

        await #expect(throws: GGServiceError.malformedOutput(
            "gg sync emitted data after a terminal event."
        )) {
            for try await _ in service.sync(worktreePath: "/tmp/wt", supportsJSONL: true) {}
        }
    }

    @Test func cleanContinueAbortCheckoutSendExpectedArgs() async throws {
        let runner = RecordingGGRunner(stdout: #"{"version":1,"clean":{"cleaned":[],"skipped":[]}}"#)
        let service = GGService(runner: runner)
        try await service.clean(worktreePath: "/tmp/wt")
        #expect(runner.lastArgs == ["clean", "--all", "--json"])
        #expect(runner.lastCwd == URL(fileURLWithPath: "/tmp/wt"))
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

    @Test func cleanToleratesEmptyOutputAfterSuccessfulExit() async throws {
        let runner = RecordingGGRunner(stdout: "", exitCode: 0)

        try await GGService(runner: runner).clean(worktreePath: "/tmp/wt")

        #expect(runner.lastArgs == ["clean", "--all", "--json"])
    }

    @Test func landToleratesUndecodableOutputAfterSuccessfulExit() async throws {
        let runner = RecordingGGRunner(stdout: "not json at all", exitCode: 0)
        let result = try await GGService(runner: runner).land(worktreePath: "/tmp/wt", until: "c-abc")
        #expect(result.landed.isEmpty)
    }

    @Test func landDoesNotTolerateInBandErrorOnSuccessfulExit() async {
        // Exit 0 with a well-formed JSON body that itself reports an
        // in-band error must still surface as a failure: only JSON-shape
        // drift is tolerated, not a genuine reported error.
        let runner = RecordingGGRunner(
            stdout: #"{"version":1,"land":{"landed":[],"error":{"message":"not approved"}}}"#,
            exitCode: 0
        )
        await #expect(throws: GGServiceError.commandFailed(stderr: "not approved")) {
            _ = try await GGService(runner: runner).land(worktreePath: "/tmp/wt", until: nil)
        }
    }

    @Test func amendCurrentUsesStagedOnlyCommandInWorktree() async throws {
        let runner = RecordingGGRunner()

        try await GGService(runner: runner).amendCurrent(worktreePath: "/repo")

        #expect(runner.calls == [["sc", "--staged-only"]])
        #expect(runner.lastCwd == URL(fileURLWithPath: "/repo"))
        #expect(!runner.lastArgs.contains("--force"))
    }

    @MainActor
    @Test func mutationExecutionPrefixesExactClientOperationID() async throws {
        let runner = RecordingGGRunner()

        _ = try await GGService(runner: runner).execute(
            .amendCurrent,
            worktreePath: "/repo",
            clientOperationID: "alas:1234",
            supportsSyncJSONL: false,
            onSyncEvent: { _ in }
        )

        #expect(runner.calls == [["--client-operation-id", "alas:1234", "sc", "--staged-only"]])
        #expect(runner.lastCwd == URL(fileURLWithPath: "/repo"))
    }

    @MainActor
    @Test func mutationExecutionWithoutClientOperationIDPreservesLegacyArguments() async throws {
        let runner = RecordingGGRunner()

        _ = try await GGService(runner: runner).execute(
            .amendCurrent,
            worktreePath: "/repo",
            clientOperationID: nil,
            supportsSyncJSONL: false,
            onSyncEvent: { _ in }
        )

        #expect(runner.calls == [["sc", "--staged-only"]])
    }

    @Test func absorbStagedUsesStagedOnlyCommandInWorktree() async throws {
        let runner = RecordingGGRunner()

        try await GGService(runner: runner).absorbStaged(worktreePath: "/repo")

        #expect(runner.calls == [["absorb", "-s"]])
        #expect(runner.lastCwd == URL(fileURLWithPath: "/repo"))
        #expect(!runner.lastArgs.contains("--force"))
    }

    @Test func dropUsesNoninteractiveJSONArgumentsAndDecodesRequiredResult() async throws {
        let runner = RecordingGGRunner(
            stdout: #"{"version":1,"drop":{"dropped":[{"position":2,"sha":"abc123","title":"Remove me"}],"remaining":1}}"#
        )

        let result = try await GGService(runner: runner).drop(worktreePath: "/repo", target: "change-2")

        #expect(result == GGDropResult(
            dropped: [GGDropCommit(position: 2, sha: "abc123", title: "Remove me")],
            remaining: 1
        ))
        #expect(runner.calls == [["drop", "change-2", "--yes", "--json"]])
        #expect(runner.lastCwd == URL(fileURLWithPath: "/repo"))
        #expect(!runner.lastArgs.contains("--force"))
    }

    @Test func unstackWithoutWorktreeUsesKeepCurrentAndDecodesCurrentStack() async throws {
        let runner = RecordingGGRunner(
            stdout: #"{"version":1,"unstack":{"original_stack":"feature","new_stack":"api","moved_entries":[{"position":2,"sha":"abc123","title":"API","gg_id":"change-2"}],"worktree_path":null,"current_stack":"feature"}}"#
        )

        let result = try await GGService(runner: runner).unstack(
            worktreePath: "/repo",
            target: "change-2",
            name: "api",
            createWorktree: false
        )

        #expect(result == GGUnstackResult(
            originalStack: "feature",
            newStack: "api",
            movedCommits: [GGUnstackCommit(position: 2, sha: "abc123", title: "API", ggID: "change-2")],
            worktreePath: nil,
            currentStack: "feature"
        ))
        #expect(runner.calls == [[
            "unstack", "--target", "change-2", "--name", "api", "--no-tui", "--json", "--keep-current",
        ]])
        #expect(runner.lastCwd == URL(fileURLWithPath: "/repo"))
        #expect(!runner.lastArgs.contains("--worktree"))
        #expect(!runner.lastArgs.contains("--force"))
    }

    @Test func unstackWithWorktreeAcceptsOlderResponseWithoutCurrentStack() async throws {
        let runner = RecordingGGRunner(
            stdout: #"{"version":1,"unstack":{"original_stack":"feature","new_stack":"api","moved_entries":[],"worktree_path":"/repo-api"}}"#
        )

        let result = try await GGService(runner: runner).unstack(
            worktreePath: "/repo",
            target: "change-2",
            name: "api",
            createWorktree: true
        )

        #expect(result.currentStack == "feature")
        #expect(result.worktreePath == "/repo-api")
        #expect(runner.calls == [[
            "unstack", "--target", "change-2", "--name", "api", "--no-tui", "--json", "--worktree",
        ]])
        #expect(runner.lastCwd == URL(fileURLWithPath: "/repo"))
        #expect(!runner.lastArgs.contains("--force"))
    }

    @Test func unstackWithoutWorktreeRequiresMatchingCurrentStack() async {
        let missingRunner = RecordingGGRunner(
            stdout: #"{"version":1,"unstack":{"original_stack":"feature","new_stack":"api","moved_entries":[]}}"#
        )
        await #expect(throws: GGServiceError.self) {
            _ = try await GGService(runner: missingRunner).unstack(
                worktreePath: "/repo", target: "change-2", name: "api", createWorktree: false
            )
        }

        let mismatchRunner = RecordingGGRunner(
            stdout: #"{"version":1,"unstack":{"original_stack":"feature","new_stack":"api","moved_entries":[],"current_stack":"api"}}"#
        )
        await #expect(throws: GGServiceError.self) {
            _ = try await GGService(runner: mismatchRunner).unstack(
                worktreePath: "/repo", target: "change-2", name: "api", createWorktree: false
            )
        }
    }

    @Test func reorderUsesCommaSeparatedCompleteOrderInWorktree() async throws {
        let runner = RecordingGGRunner()

        try await GGService(runner: runner).reorder(worktreePath: "/repo", order: ["a", "b", "c"])

        #expect(runner.calls == [["reorder", "--order", "a,b,c"]])
        #expect(runner.lastCwd == URL(fileURLWithPath: "/repo"))
        #expect(!runner.lastArgs.contains("--force"))
    }

    @Test func restackUsesJSONAndOptionalDryRunArguments() async throws {
        let runner = RecordingGGRunner(
            stdout: #"{"version":1,"restack":{"stack_name":"feature","total_entries":2,"entries_restacked":1,"entries_ok":1,"dry_run":true,"steps":[{"position":2,"gg_id":"change-2","title":"Second","action":"restack","current_parent":"old","expected_parent":"new"}]}}"#
        )
        let service = GGService(runner: runner)

        let preview = try await service.restack(worktreePath: "/repo", dryRun: true)

        #expect(preview.stackName == "feature")
        #expect(preview.steps == [GGRestackStep(
            position: 2,
            ggID: "change-2",
            title: "Second",
            action: "restack",
            currentParent: "old",
            expectedParent: "new"
        )])
        #expect(runner.lastArgs == ["restack", "--json", "--dry-run"])
        #expect(runner.lastCwd == URL(fileURLWithPath: "/repo"))
        #expect(!runner.lastArgs.contains("--force"))

        runner.stdout = #"{"version":1,"restack":{"stack_name":"feature","total_entries":2,"entries_restacked":0,"entries_ok":2,"dry_run":false,"steps":[]}}"#
        _ = try await service.restack(worktreePath: "/repo", dryRun: false)
        #expect(runner.lastArgs == ["restack", "--json"])
    }

    @Test func rebaseUsesOptionalTargetWithoutForce() async throws {
        let runner = RecordingGGRunner()
        let service = GGService(runner: runner)

        try await service.rebase(worktreePath: "/repo", target: nil)
        #expect(runner.lastArgs == ["rebase"])
        #expect(runner.lastCwd == URL(fileURLWithPath: "/repo"))

        try await service.rebase(worktreePath: "/repo", target: "main")
        #expect(runner.lastArgs == ["rebase", "main"])
        #expect(!runner.calls.flatMap { $0 }.contains("--force"))
    }

    @Test func undoListUsesLimitAndDecodesOperations() async throws {
        let runner = RecordingGGRunner(
            stdout: #"{"version":1,"operations":[{"id":"op_1","kind":"drop","status":"committed","created_at_ms":42,"args":["drop","2"],"stack_name":"feature","touched_remote":false,"is_undoable":true,"is_undo":false}]}"#
        )

        let operations = try await GGService(runner: runner).listUndoOperations(worktreePath: "/repo", limit: 5)

        #expect(operations.count == 1)
        #expect(operations[0].id == "op_1")
        #expect(operations[0].status == .completed)
        #expect(runner.calls == [["undo", "--list", "--json", "--limit", "5"]])
        #expect(runner.lastCwd == URL(fileURLWithPath: "/repo"))
        #expect(!runner.lastArgs.contains("--force"))
    }

    @Test func undoApplyUsesOperationIDAndRequiresUndoneResult() async throws {
        let runner = RecordingGGRunner(
            stdout: #"{"version":1,"status":"succeeded","undone":{"id":"op_1","kind":"drop","status":"committed","created_at_ms":42,"args":["drop","2"],"touched_remote":false,"is_undoable":true,"is_undo":false}}"#
        )

        let result = try await GGService(runner: runner).undo(worktreePath: "/repo", operationID: "op_1")

        #expect(result.undone.id == "op_1")
        #expect(runner.calls == [["undo", "op_1", "--json"]])
        #expect(runner.lastCwd == URL(fileURLWithPath: "/repo"))
        #expect(!runner.lastArgs.contains("--force"))

        runner.stdout = #"{"version":1,"status":"succeeded"}"#
        await #expect(throws: GGServiceError.self) {
            _ = try await GGService(runner: runner).undo(worktreePath: "/repo", operationID: "op_1")
        }
    }

    @Test func structuredSplitUsesExactDescribeAndApplyArguments() async throws {
        let runner = RecordingGGRunner(
            stdout: #"{"version":1,"plan_token":"token","target":{"gg_id":"change-2","sha":"abc123","tree":"tree123"},"hunks":[{"id":"h-1","path":"A.swift","header":"@@ -1 +1 @@","patch":"-a\n+b\n"}],"non_textual_files":["image.png"],"first_message":"First","remainder_message":"Remainder"}"#
        )
        let service = GGService(runner: runner)

        let description = try await service.describeSplit(worktreePath: "/repo", target: "change-2")

        #expect(description.planToken == "token")
        #expect(description.hunks.map(\.id) == ["h-1"])
        #expect(runner.lastArgs == ["split", "--describe", "--commit", "change-2", "--json"])
        #expect(runner.lastCwd == URL(fileURLWithPath: "/repo"))
        #expect(!runner.lastArgs.contains("--force"))

        runner.stdout = #"{"version":1,"operation_id":"op_2","original_sha":"abc123","first":{"sha":"first123","gg_id":"change-1"},"remainder":{"sha":"remaining123","gg_id":"change-2"},"rewritten_descendants":[{"sha":"child123","gg_id":"change-3"}]}"#
        let planURL = URL(fileURLWithPath: "/tmp/split-plan.json")
        let result = try await service.applySplit(worktreePath: "/repo", planURL: planURL)

        #expect(result.operationID == "op_2")
        #expect(result.rewrittenDescendants.map(\.sha) == ["child123"])
        #expect(runner.lastArgs == ["split", "--plan-json", planURL.path, "--json"])
        #expect(runner.lastCwd == URL(fileURLWithPath: "/repo"))
        #expect(!runner.lastArgs.contains("--force"))
    }

    @Test func typedResultsRejectUnknownSchemaMalformedJSONAndMissingFields() async {
        let unsupported = RecordingGGRunner(stdout: #"{"version":2}"#)
        await #expect(throws: GGServiceError.unsupportedSchema(2)) {
            _ = try await GGService(runner: unsupported).describeSplit(worktreePath: "/repo", target: "change-2")
        }

        let malformed = RecordingGGRunner(stdout: "not json")
        await #expect(throws: GGServiceError.self) {
            _ = try await GGService(runner: malformed).drop(worktreePath: "/repo", target: "change-2")
        }

        let missing = RecordingGGRunner(stdout: #"{"version":1,"drop":{"dropped":[]}}"#)
        await #expect(throws: GGServiceError.self) {
            _ = try await GGService(runner: missing).drop(worktreePath: "/repo", target: "change-2")
        }
    }

    @Test func actionErrorsUseStableCategoriesAndPreserveGGText() async {
        let cases: [(String, GGServiceError)] = [
            ("cannot rewrite immutable commits: change-2", .immutableTargets(message: "cannot rewrite immutable commits: change-2")),
            ("Dirty working directory. Please commit first.", .dirtyWorkingTree(message: "Dirty working directory. Please commit first.")),
            ("stale target: stack changed", .staleTarget(message: "stale target: stack changed")),
            ("stale split plan: hunks changed", .staleSplitPlan(message: "stale split plan: hunks changed")),
            ("Rebase conflict. Resolve conflicts and run gg continue.", .pausedConflict(message: "Rebase conflict. Resolve conflicts and run gg continue.")),
            ("partial mutation: refs may have changed", .partialMutation(message: "partial mutation: refs may have changed")),
        ]

        for (message, expected) in cases {
            let runner = RecordingGGRunner(
                stdout: #"{"version":1,"error":"\#(message)"}"#,
                exitCode: 1
            )
            await #expect(throws: expected) {
                _ = try await GGService(runner: runner).drop(worktreePath: "/repo", target: "change-2")
            }
        }
    }

    @Test func undoStructuredRefusalPreservesMessageAndRecoveryHint() async {
        let runner = RecordingGGRunner(
            stdout: #"{"version":1,"status":"refused","refusal":{"reason":"remote","message":"operation touched a remote","hints":["Close PR #7 manually"]}}"#,
            exitCode: 1
        )

        await #expect(throws: GGServiceError.undoRefused(
            message: "operation touched a remote",
            hint: "Close PR #7 manually"
        )) {
            _ = try await GGService(runner: runner).undo(worktreePath: "/repo", operationID: "op_1")
        }
    }

    @Test func undoStructuredRefusalAllowsProtocolOmittedEmptyHints() async {
        let runner = RecordingGGRunner(
            stdout: #"{"version":1,"status":"refused","refusal":{"reason":"stale","message":"ref moved since the operation"}}"#,
            exitCode: 1
        )

        await #expect(throws: GGServiceError.undoRefused(
            message: "ref moved since the operation",
            hint: nil
        )) {
            _ = try await GGService(runner: runner).undo(worktreePath: "/repo", operationID: "op_1")
        }
    }
}
