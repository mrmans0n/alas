import Foundation
import Testing
@testable import Alas

struct GGReorderModelTests {
    @Test func moveIsLimitedToContiguousMutableRegion() {
        var model = GGReorderModel(entries: [
            .mutable(id: "a", title: "A"),
            .mutable(id: "b", title: "B"),
            .immutable(id: "c", title: "C"),
            .mutable(id: "d", title: "D"),
        ])

        #expect(model.move(from: 0, to: 1) == .moved)
        #expect(model.orderedIDs == ["b", "a", "c", "d"])
        #expect(model.move(from: 1, to: 3) == .immutableBoundary)
        #expect(model.orderedIDs == ["b", "a", "c", "d"])
        #expect(model.move(from: 2, to: 1) == .immutableBoundary)
    }

    @Test func moveAllowsTheEndInsertionOffsetOfAMutableRegion() {
        var model = GGReorderModel(entries: [
            .mutable(id: "a", title: "A"),
            .mutable(id: "b", title: "B"),
            .immutable(id: "merged", title: "Merged"),
            .mutable(id: "c", title: "C"),
        ])

        #expect(model.move(from: 0, to: 2) == .moved)
        #expect(model.orderedIDs == ["b", "a", "merged", "c"])
    }

    @Test func reorderAlwaysSubmitsCompleteExactIdentifierOrderAndHasNoDropAction() {
        var model = GGReorderModel(entries: [
            .immutable(id: "merged", title: "Merged"),
            .mutable(id: "one", title: "One"),
            .mutable(id: "two", title: "Two"),
        ])

        #expect(model.move(from: 2, to: 1) == .moved)
        #expect(model.orderedIDs == ["merged", "two", "one"])
        #expect(model.availableActions == [.apply, .cancel])
    }
}

/// Counts `run(...)` calls so tests can assert `refreshGGStack()` skips the
/// gg CLI when gated closed / not stack-shaped, and dedupes when the commit
/// set is unchanged since the last query.
private final class CountingFakeGGRunner: GGCommandRunning, @unchecked Sendable {
    private(set) var callCount = 0
    let result: ProcessResult

    init(result: ProcessResult) {
        self.result = result
    }

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        callCount += 1
        return result
    }
}

private final class SequencedFakeGGRunner: GGCommandRunning, @unchecked Sendable {
    private(set) var callCount = 0
    private var results: [ProcessResult]

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        callCount += 1
        guard args == ["ls", "--json"], !results.isEmpty else {
            return ProcessResult(exitCode: 1, stdout: "", stderr: "unexpected args: \(args)")
        }
        return results.removeFirst()
    }
}

private final class LocalFirstGGRunner: GGCommandRunning, @unchecked Sendable {
    private(set) var calls: [[String]] = []
    var delaysRemote = false
    var localJSON = GGStackModelsTests.fixture
    var remoteResults: [ProcessResult] = []

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        calls.append(args)
        if args == ["ls", "--json", "--no-refresh"] {
            return ProcessResult(exitCode: 0, stdout: localJSON, stderr: "")
        }
        if delaysRemote {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if !remoteResults.isEmpty { return remoteResults.removeFirst() }
        throw GGServiceError.commandFailed(stderr: "remote unavailable")
    }
}

enum GGStackClassificationFixture: CaseIterable, Sendable {
    case nilStack
    case zeroTotalWithEntry
    case positiveTotalWithoutEntries
    case populated

    var isEmpty: Bool { self != .populated }
    var hasStack: Bool { self != .nilStack }
    var isMalformed: Bool {
        self == .zeroTotalWithEntry || self == .positiveTotalWithoutEntries
    }

    var json: String {
        guard self != .nilStack else {
            return #"{"version": 1, "stack": null}"#
        }
        let totalCommits = self == .zeroTotalWithEntry ? 0 : 1
        let entries = self == .positiveTotalWithoutEntries ? "[]" : """
        [
          {"position": 1, "sha": "aaaaaaa", "title": "feat: first",
           "gg_id": "id-1", "gg_parent": null, "pr_number": null, "pr_state": null,
           "approved": false, "ci_status": null, "is_current": true,
           "in_merge_train": false, "merge_train_position": null}
        ]
        """
        return """
        {
          "version": 1,
          "stack": {
            "name": "stack",
            "base": "main",
            "total_commits": \(totalCommits),
            "synced_commits": 0,
            "current_position": 1,
            "behind_base": 0,
            "entries": \(entries)
          }
        }
        """
    }
}

/// Always throws, simulating a transient gg/provider failure (e.g. a gh/glab
/// auth hiccup) rather than a real "not a stack" result.
private final class ThrowingFakeGGRunner: GGCommandRunning, @unchecked Sendable {
    private(set) var callCount = 0

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        callCount += 1
        throw GGServiceError.commandFailed(stderr: "boom")
    }
}

private final class SplitDescriptionGGRunner: GGCommandRunning, @unchecked Sendable {
    private(set) var calls: [[String]] = []

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        calls.append(args)
        if args == ["ls", "--json"] {
            return ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        }
        if args == ["split", "--describe", "--commit", "id-2", "--json"] {
            return ProcessResult(
                exitCode: 0,
                stdout: #"{"version":1,"plan_token":"token","target":{"gg_id":"id-2","sha":"bbbbbbb","tree":"tree"},"hunks":[],"non_textual_files":[],"first_message":"First","remainder_message":"Remainder"}"#,
                stderr: ""
            )
        }
        return ProcessResult(exitCode: 1, stdout: "", stderr: "unexpected args: \(args)")
    }
}

/// Delays the first stack read so a later refresh can publish a newer stack
/// before the stale watcher result returns.
private final class DelayedStackGGRunner: GGCommandRunning, @unchecked Sendable {
    private(set) var callCount = 0
    private let staleResult: ProcessResult
    private let freshResult: ProcessResult

    init(staleResult: ProcessResult, freshResult: ProcessResult) {
        self.staleResult = staleResult
        self.freshResult = freshResult
    }

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        callCount += 1
        if callCount == 1 {
            try await Task.sleep(nanoseconds: 100_000_000)
            return staleResult
        }
        return freshResult
    }
}

private actor ControlledStackGGRunner: GGCommandRunning {
    private let stackResults: [(name: String, result: ProcessResult)]
    private let suspendedCalls: Set<Int>
    private(set) var lsCallCount = 0
    private var lastStackName: String?
    private var callWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var completions: [Int: CheckedContinuation<Void, Never>] = [:]

    init(
        stackResults: [(name: String, result: ProcessResult)],
        suspendedCalls: Set<Int>
    ) {
        self.stackResults = stackResults
        self.suspendedCalls = suspendedCalls
    }

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        if args == ["undo", "--list", "--json", "--limit", "1"] {
            guard let lastStackName else {
                return ProcessResult(exitCode: 0, stdout: #"{"version":1,"operations":[]}"#, stderr: "")
            }
            return ProcessResult(
                exitCode: 0,
                stdout: """
                {"version":1,"operations":[{"id":"op_1","kind":"reorder","status":"committed","created_at_ms":1,"args":["--client-operation-id","alas:persisted","reorder"],"stack_name":"\(lastStackName)","touched_remote":false,"is_undoable":true}]}
                """,
                stderr: ""
            )
        }
        guard args == ["ls", "--json"], lsCallCount < stackResults.count else {
            return ProcessResult(exitCode: 1, stdout: "", stderr: "unexpected args: \(args)")
        }
        lsCallCount += 1
        let call = lsCallCount
        let waiters = callWaiters.removeValue(forKey: call) ?? []
        for waiter in waiters { waiter.resume() }
        if suspendedCalls.contains(call) {
            await withCheckedContinuation { completions[call] = $0 }
        }
        let response = stackResults[call - 1]
        lastStackName = response.name
        return response.result
    }

    func waitUntilCall(_ call: Int) async {
        if lsCallCount >= call { return }
        await withCheckedContinuation { callWaiters[call, default: []].append($0) }
    }

    func complete(call: Int) {
        completions.removeValue(forKey: call)?.resume()
    }
}

/// Answers the `sync --help` capability probe with `--jsonl` support, then
/// streams the given NDJSON body for `sync --jsonl` — needed because
/// `CountingFakeGGRunner` echoes the same stdout to every call, which would
/// make the probe see the sync body instead of a help string and fall back
/// to the non-streaming path.
private final class NDJSONSyncFakeGGRunner: GGCommandRunning, @unchecked Sendable {
    private let ndjson: String

    init(ndjson: String) {
        self.ndjson = ndjson
    }

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        if args == ["sync", "--help"] {
            return ProcessResult(exitCode: 0, stdout: "--jsonl", stderr: "")
        }
        return ProcessResult(exitCode: 0, stdout: ndjson, stderr: "")
    }
}

private final class ReentrantSyncFakeGGRunner: GGCommandRunning, @unchecked Sendable {
    private(set) var syncCallCount = 0

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        if args == ["sync", "--help"] {
            return ProcessResult(exitCode: 0, stdout: "--jsonl", stderr: "")
        }
        if args == ["sync", "--jsonl"] {
            syncCallCount += 1
            let ndjson = [
                #"{"event":"start","total_entries":1}"#,
                #"{"event":"push_done","position":1,"forced":false}"#,
                #"{"event":"summary"}"#,
            ].joined(separator: "\n")
            return ProcessResult(exitCode: 0, stdout: ndjson, stderr: "")
        }
        return ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
    }
}

/// Provides the three real calls made by a sync mutation: preflight stack
/// read, sync output, and post-sync stack refresh. The post-sync refresh
/// remains suspended until cancellation so a replacement gate refresh can
/// prove it owns that work through `ggStackRefreshTask`.
private actor PostMutationRefreshCancellationRunner: GGCommandRunning {
    private let preflightResult = ProcessResult(
        exitCode: 0,
        stdout: GGStackModelsTests.fixture,
        stderr: ""
    )
    private let replacementResult = ProcessResult(
        exitCode: 0,
        stdout: GGStackModelsTests.fixture.replacingOccurrences(
            of: "agent-inbox",
            with: "replacement-stack"
        ),
        stderr: ""
    )
    private let syncSummary = #"{"event":"summary"}"#

    private var lsCallCount = 0
    private var postSyncReadSuspended = false
    private var postSyncReadCancellationObserved = false
    private var postSyncReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var postSyncReadCancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var postSyncReadContinuation: CheckedContinuation<ProcessResult, Error>?

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        if args == ["sync", "--help"] {
            return ProcessResult(exitCode: 0, stdout: "--jsonl", stderr: "")
        }
        if args == ["sync", "--json"] || args == ["sync", "--jsonl"] {
            return ProcessResult(exitCode: 0, stdout: syncSummary, stderr: "")
        }
        guard args == ["ls", "--json"] else {
            return ProcessResult(exitCode: 1, stdout: "", stderr: "unexpected args: \(args)")
        }
        lsCallCount += 1
        switch lsCallCount {
        case 1:
            return preflightResult
        case 2:
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    postSyncReadSuspended = true
                    postSyncReadContinuation = continuation
                    let waiters = postSyncReadWaiters
                    postSyncReadWaiters.removeAll()
                    for waiter in waiters { waiter.resume() }
                }
            } onCancel: {
                Task { await self.cancelPostSyncRead() }
            }
        case 3:
            return replacementResult
        default:
            return ProcessResult(exitCode: 1, stdout: "", stderr: "unexpected stack read")
        }
    }

    func waitUntilPostSyncReadSuspends() async {
        if postSyncReadSuspended { return }
        await withCheckedContinuation { postSyncReadWaiters.append($0) }
    }

    func didObservePostSyncReadCancellation() -> Bool {
        postSyncReadCancellationObserved
    }

    func waitUntilPostSyncReadCancellationIsObserved() async {
        if postSyncReadCancellationObserved { return }
        await withCheckedContinuation { postSyncReadCancellationWaiters.append($0) }
    }

    func releasePostSyncRead() {
        postSyncReadContinuation?.resume(returning: replacementResult)
        postSyncReadContinuation = nil
    }

    private func cancelPostSyncRead() {
        postSyncReadCancellationObserved = true
        let waiters = postSyncReadCancellationWaiters
        postSyncReadCancellationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        postSyncReadContinuation?.resume(throwing: CancellationError())
        postSyncReadContinuation = nil
    }
}

/// Drives a failed mutation through its suspended post-mutation refresh while
/// a replacement mutation is already running.
private actor StaleMutationFailureRunner: GGCommandRunning {
    private let stackResult = ProcessResult(
        exitCode: 0,
        stdout: GGStackModelsTests.fixture,
        stderr: ""
    )
    private var stackReadCount = 0
    private var firstRefreshSuspended = false
    private var secondSyncSuspended = false
    private var firstRefreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondSyncWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRefreshContinuation: CheckedContinuation<ProcessResult, Error>?
    private var secondSyncContinuation: CheckedContinuation<ProcessResult, Error>?

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        if args == ["sync", "--help"] {
            return ProcessResult(exitCode: 0, stdout: "--jsonl", stderr: "")
        }
        if args == ["restack", "--json"] {
            return ProcessResult(exitCode: 1, stdout: "", stderr: "mutation A failed")
        }
        if args == ["sync", "--json"] || args == ["sync", "--jsonl"] {
            return try await withCheckedThrowingContinuation { continuation in
                secondSyncSuspended = true
                secondSyncContinuation = continuation
                let waiters = secondSyncWaiters
                secondSyncWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        guard args == ["ls", "--json"] else {
            return ProcessResult(exitCode: 1, stdout: "", stderr: "unexpected args: \(args)")
        }
        stackReadCount += 1
        switch stackReadCount {
        case 1, 3, 4:
            return stackResult
        case 2:
            return try await withCheckedThrowingContinuation { continuation in
                firstRefreshSuspended = true
                firstRefreshContinuation = continuation
                let waiters = firstRefreshWaiters
                firstRefreshWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        default:
            return ProcessResult(exitCode: 1, stdout: "", stderr: "unexpected stack read")
        }
    }

    func waitUntilFirstRefreshSuspends() async {
        if firstRefreshSuspended { return }
        await withCheckedContinuation { firstRefreshWaiters.append($0) }
    }

    func waitUntilSecondSyncSuspends() async {
        if secondSyncSuspended { return }
        await withCheckedContinuation { secondSyncWaiters.append($0) }
    }

    func finishFirstRefresh() {
        firstRefreshContinuation?.resume(returning: stackResult)
        firstRefreshContinuation = nil
    }

    func finishSecondSync() {
        secondSyncContinuation?.resume(returning: ProcessResult(
            exitCode: 0,
            stdout: #"{"event":"summary"}"#,
            stderr: ""
        ))
        secondSyncContinuation = nil
    }
}

private final class ConflictAfterSyncRunner: GGCommandRunning, @unchecked Sendable {
    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        if args == ["sync", "--help"] {
            return ProcessResult(exitCode: 0, stdout: "--jsonl", stderr: "")
        }
        if args == ["sync", "--jsonl"], let cwd {
            try FileManager.default.createDirectory(
                at: cwd.appendingPathComponent(".git/rebase-merge"),
                withIntermediateDirectories: true
            )
            return ProcessResult(exitCode: 1, stdout: "", stderr: "conflict")
        }
        return ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
    }
}

private final class CleanMutationFakeGGRunner: GGCommandRunning, @unchecked Sendable {
    private(set) var arguments: [[String]] = []

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        arguments.append(args)
        if args == ["clean", "--all", "--json"] {
            return ProcessResult(
                exitCode: 0,
                stdout: #"{"version":1,"clean":{"cleaned":[],"skipped":[]}}"#,
                stderr: ""
            )
        }
        return ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
    }
}

private final class RecordingLifecycleGGRunner: GGCommandRunning, @unchecked Sendable {
    private(set) var arguments: [[String]] = []

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        arguments.append(args)
        if args == ["undo", "--list", "--json", "--limit", "1"] {
            return ProcessResult(
                exitCode: 0,
                stdout: #"{"version":1,"operations":[]}"#,
                stderr: ""
            )
        }
        return ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
    }

    func containsCommand(suffix: [String]) -> Bool {
        arguments.contains { $0.suffix(suffix.count) == suffix }
    }
}

private final class AdvancingUndoGGRunner: GGCommandRunning, @unchecked Sendable {
    private(set) var lsCallCount = 0
    private(set) var undoListCallCount = 0

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        if args == ["ls", "--json"] {
            lsCallCount += 1
            return ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        }
        if args == ["undo", "--list", "--json", "--limit", "1"] {
            undoListCallCount += 1
            let id = undoListCallCount == 1 ? "op_1" : "op_2"
            return ProcessResult(
                exitCode: 0,
                stdout: """
                {"version":1,"operations":[{"id":"\(id)","kind":"reorder","status":"committed","created_at_ms":1,"args":["--client-operation-id","alas:persisted","reorder"],"stack_name":"agent-inbox","touched_remote":false,"is_undoable":true}]}
                """,
                stderr: ""
            )
        }
        return ProcessResult(exitCode: 1, stdout: "", stderr: "unexpected args: \(args)")
    }
}

/// Serves a valid stack + undo candidate on the first `ls`, then throws on the
/// next `ls` to simulate a stale-key refresh failure after switching branches.
private final class FailSecondLsUndoGGRunner: GGCommandRunning, @unchecked Sendable {
    private(set) var lsCallCount = 0

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        if args == ["ls", "--json"] {
            lsCallCount += 1
            if lsCallCount >= 2 {
                throw GGServiceError.commandFailed(stderr: "boom")
            }
            return ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        }
        if args == ["undo", "--list", "--json", "--limit", "1"] {
            return ProcessResult(
                exitCode: 0,
                stdout: """
                {"version":1,"operations":[{"id":"op_1","kind":"reorder","status":"committed","created_at_ms":1,"args":["--client-operation-id","alas:persisted","reorder"],"stack_name":"agent-inbox","touched_remote":false,"is_undoable":true}]}
                """,
                stderr: ""
            )
        }
        return ProcessResult(exitCode: 1, stdout: "", stderr: "unexpected args: \(args)")
    }
}

private final class NoCurrentStackUndoGGRunner: GGCommandRunning, @unchecked Sendable {
    private(set) var undoListCallCount = 0

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        if args == ["ls", "--json"] {
            return ProcessResult(exitCode: 0, stdout: #"{"version":1,"stacks":[]}"#, stderr: "")
        }
        if args == ["undo", "--list", "--json", "--limit", "1"] {
            undoListCallCount += 1
            return ProcessResult(
                exitCode: 0,
                stdout: #"{"version":1,"operations":[{"id":"op_drop","kind":"drop","status":"committed","created_at_ms":1,"args":["--client-operation-id","alas:persisted","drop","change-1"],"stack_name":"agent-inbox","touched_remote":false,"is_undoable":true}]}"#,
                stderr: ""
            )
        }
        return ProcessResult(exitCode: 1, stdout: "", stderr: "unexpected args: \(args)")
    }
}

private final class PausedContinueGGRunner: GGCommandRunning, @unchecked Sendable {
    let snapshotOperationID: String?
    let listedOperationID: String
    private(set) var continueCallCount = 0
    private(set) var abortCallCount = 0
    private(set) var undoListCallCount = 0

    init(snapshotOperationID: String?, listedOperationID: String) {
        self.snapshotOperationID = snapshotOperationID
        self.listedOperationID = listedOperationID
    }

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        if args == ["ls", "--json"] {
            let operationField = snapshotOperationID.map { #", "operation_id": "\#($0)""# } ?? ""
            let payload = GGStackModelsTests.fixture.replacingOccurrences(
                of: #""version": 1"#,
                with: #""version": 1\#(operationField)"#
            )
            return ProcessResult(exitCode: 0, stdout: payload, stderr: "")
        }
        if args == ["continue"] {
            continueCallCount += 1
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        if args == ["abort"] {
            abortCallCount += 1
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        if args == ["undo", "--list", "--json", "--limit", "1"] {
            undoListCallCount += 1
            return ProcessResult(
                exitCode: 0,
                stdout: """
                {"version":1,"operations":[{"id":"\(listedOperationID)","kind":"restack","status":"committed","created_at_ms":1,"args":["--client-operation-id","alas:original","restack"],"stack_name":"agent-inbox","touched_remote":false,"is_undoable":true}]}
                """,
                stderr: ""
            )
        }
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

@MainActor
struct RightPaneGGStackErrorPresentationTests {
    @Test func cliErrorReachesRetryableDrawerDetail() async {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-stack-error-\(UUID().uuidString)")
        let worktree = Worktree(
            id: Worktree.makeId(path: path),
            projectId: "test-project",
            name: "feature",
            branch: "feature",
            path: path,
            status: .clean,
            lastActivity: Date()
        )
        let state = RightPaneState(worktree: worktree, baseBranch: "main")
        let runner = ThrowingFakeGGRunner()
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }

        await state.refreshGGStack()

        #expect(runner.callCount == 1)
        #expect(state.ggContext == .active(stackName: "stack"))
        #expect(state.ggStackLoadState == .failed("boom"))
        #expect(GGStackPlaceholderModel.make(
            context: state.ggContext,
            loadState: state.ggStackLoadState
        )?.detail == "boom")
        #expect(state.ggStackCommitsKey == nil)
    }
}

@MainActor
struct RightPaneGGRefreshSchedulingTests {
    @Test func watcherStackRefreshIsSuppressedOnlyDuringSync() {
        #expect(!RightPaneState.shouldScheduleGGStackRefresh(inFlightAction: .sync))
        #expect(RightPaneState.shouldScheduleGGStackRefresh(inFlightAction: .rebase))
        #expect(RightPaneState.shouldScheduleGGStackRefresh(inFlightAction: nil))
    }
}

@MainActor
struct RightPaneGGStackTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        var projectsFile: ProjectsFile?

        init(projectsFile: ProjectsFile? = nil) {
            self.projectsFile = projectsFile
        }

        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            if type == ProjectsFile.self { return projectsFile as? T }
            if type == AppConfig.self { return AppConfig.defaults as? T }
            return nil
        }
    }

    private func makeWorktree() -> Worktree {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-stack-\(UUID().uuidString)")
        return Worktree(
            id: Worktree.makeId(path: path),
            projectId: "test-project",
            name: "feature",
            branch: "feature",
            path: path,
            status: .clean,
            lastActivity: Date()
        )
    }

    private func commit(sha: String, stackShaped: Bool, subject: String = "subject") -> CommitInfo {
        CommitInfo(
            sha: sha, shortSha: String(sha.prefix(7)),
            author: "Test", authorInitials: "T", date: Date(),
            subject: subject,
            body: stackShaped ? "Some detail.\n\nGG-ID: abc123\nGG-Parent: def456" : "Just a plain commit body.",
            conventionalTag: nil,
            filesChanged: 1, insertions: 1, deletions: 0
        )
    }

    private func makeState(worktree: Worktree? = nil) -> RightPaneState {
        let state = RightPaneState(worktree: worktree ?? makeWorktree(), baseBranch: "main")
        installFakeGGStackLoader(on: state)
        return state
    }

    private func installFakeGGStackLoader(on state: RightPaneState) {
        state.ggStackCommitLoader = { _, shas in
            Dictionary(uniqueKeysWithValues: shas.map { sha in
                let fullSHA = sha.count == 40
                    ? sha
                    : sha + String(repeating: "0", count: 40 - sha.count)
                return (fullSHA, self.commit(sha: fullSHA, stackShaped: true))
            })
        }
    }

    @Test func successfulRefreshPublishesFullStackRowsInPositionOrder() async {
        let state = makeState()
        let reachable = commit(sha: String(repeating: "f", count: 40), stackShaped: true)
        state.commits = [reachable]
        state.ggService = GGService(runner: CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        ))
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "a", count: 40), stackShaped: true)]

        await state.refreshGGStack()

        #expect(state.ggStackLoadState == .loaded)
        #expect(state.ggStackDisplayCommits.map(\.shortSha) == ["ccccccc", "bbbbbbb", "aaaaaaa"])
        #expect(state.commitsForDisplay == state.ggStackDisplayCommits)
        #expect(state.commits == [reachable])
    }

    @Test func localFirstRefreshKeepsRowsWhenRemoteEnrichmentFails() async {
        let runner = LocalFirstGGRunner()
        let state = makeState()
        state.ggService = GGService(runner: runner)
        state.ggCapabilities = {
            GGCapabilities(
                structuredSplit: false,
                keepCurrentUnstack: false,
                localStackSnapshot: true
            )
        }
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "a", count: 40), stackShaped: true)]

        await state.refreshGGStack()

        #expect(runner.calls == [
            ["ls", "--json", "--no-refresh"],
            ["ls", "--json"],
        ])
        #expect(state.ggStackLoadState == .loaded)
        #expect(state.ggStackDisplayCommits.count == 3)
        #expect(state.ggStackRemoteError == "remote unavailable")
    }

    @Test func localFirstRefreshPublishesRowsBeforeRemoteEnrichmentCompletes() async throws {
        let runner = LocalFirstGGRunner()
        runner.delaysRemote = true
        let state = makeState()
        state.ggService = GGService(runner: runner)
        state.ggCapabilities = {
            GGCapabilities(
                structuredSplit: false,
                keepCurrentUnstack: false,
                localStackSnapshot: true
            )
        }
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }

        let refresh = Task { @MainActor in await state.refreshGGStack() }
        for _ in 0..<500 where runner.calls.count < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        #expect(state.ggStackLoadState == .loaded)
        #expect(state.ggStackDisplayCommits.count == 3)
        refresh.cancel()
        await refresh.value
    }

    @Test func cancelledRemoteEnrichmentIsRetriedForTheSameStack() async throws {
        let runner = LocalFirstGGRunner()
        runner.delaysRemote = true
        let state = makeState()
        state.ggService = GGService(runner: runner)
        state.ggCapabilities = {
            GGCapabilities(
                structuredSplit: false,
                keepCurrentUnstack: false,
                localStackSnapshot: true
            )
        }
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }

        let first = Task { @MainActor in await state.refreshGGStack() }
        for _ in 0..<500 where runner.calls.count < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        first.cancel()
        await first.value

        #expect(state.ggStackLoadState == .loaded)
        #expect(state.ggStackDisplayCommits.count == 3)
        #expect(state.ggStackRemoteEnrichmentPending)

        await state.refreshGGStack()

        #expect(runner.calls == [
            ["ls", "--json", "--no-refresh"],
            ["ls", "--json"],
            ["ls", "--json"],
        ])
        #expect(state.ggStackLoadState == .loaded)
        #expect(state.ggStackDisplayCommits.count == 3)
        #expect(state.ggStackRemoteError == "remote unavailable")
        #expect(!state.ggStackRemoteEnrichmentPending)
    }

    @Test func cancelledRemoteEnrichmentKeepsPublishedEmptyStack() async throws {
        let runner = LocalFirstGGRunner()
        runner.delaysRemote = true
        runner.localJSON = GGStackClassificationFixture.nilStack.json
        let state = makeState()
        state.ggService = GGService(runner: runner)
        state.ggCapabilities = {
            GGCapabilities(
                structuredSplit: false,
                keepCurrentUnstack: false,
                localStackSnapshot: true
            )
        }
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "a", count: 40), stackShaped: true)]

        let refresh = Task { @MainActor in await state.refreshGGStack() }
        for _ in 0..<500 where runner.calls.count < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        refresh.cancel()
        await refresh.value

        #expect(state.ggStackLoadState == .empty)
        #expect(state.ggStackDisplayCommits.isEmpty)
        #expect(state.ggStackRemoteEnrichmentPending)
    }

    @Test func manualRetryPreservesCachedMetadataWhenRemoteFailsAgain() async {
        let runner = LocalFirstGGRunner()
        runner.localJSON = GGStackModelsTests.fixture
            .replacingOccurrences(of: #""pr_state": "merged""#, with: #""pr_state": null"#)
            .replacingOccurrences(of: #""pr_state": "open""#, with: #""pr_state": null"#)
            .replacingOccurrences(of: #""ci_status": "success""#, with: #""ci_status": null"#)
            .replacingOccurrences(of: #""ci_status": "running""#, with: #""ci_status": null"#)
        runner.remoteResults = [
            ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: ""),
        ]
        let state = makeState()
        state.ggService = GGService(runner: runner)
        state.ggCapabilities = {
            GGCapabilities(
                structuredSplit: false,
                keepCurrentUnstack: false,
                localStackSnapshot: true
            )
        }
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }

        await state.refreshGGStack()
        #expect(state.ggStack?.entries[0].prState == .merged)

        await state.reevaluateGGGate().value

        #expect(state.ggStack?.entries[0].prState == .merged)
        #expect(state.ggStack?.entries[0].ciStatus == .success)
        #expect(state.ggStackRemoteError == "remote unavailable")
    }

    @Test func failedHydrationClearsStackAndKeepsPlainCommitRows() async {
        let state = makeState()
        let reachable = commit(sha: String(repeating: "f", count: 40), stackShaped: true)
        state.commits = [reachable]
        state.ggService = GGService(runner: CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        ))
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "a", count: 40), stackShaped: true)]
        state.ggStackCommitLoader = { _, shas in
            throw StackCommitInfoError.missingCommits(shas)
        }

        await state.refreshGGStack()

        #expect(state.ggStack == nil)
        #expect(state.ggStackDisplayCommits.isEmpty)
        #expect(state.commitsForDisplay == state.commits)
        #expect(state.ggStackCommitsKey == nil)
        #expect(state.ggStackLoadState == .failed("One or more GG stack commits are unavailable locally."))
    }

    @Test func seedingContextMakesEligibleFirstActivationLoadingImmediately() {
        let state = makeState()
        state.ggContextProvider = { branch in
            .active(stackName: String(branch.dropFirst("nacho/".count)))
        }

        state.seedGGContext(branch: "nacho/first-stack")

        #expect(state.currentBranch == "nacho/first-stack")
        #expect(state.ggContext == .active(stackName: "first-stack"))
        #expect(state.ggStackLoadState == .loading)
    }

    @Test func prepareCardRemainsVisibleAlongsideGGDrawer() {
        #expect(ChangesTabView.shouldShowChangesPreparationCard(
            preparationIsVisible: true
        ))
        #expect(!ChangesTabView.shouldShowChangesPreparationCard(
            preparationIsVisible: false
        ))
    }

    @Test func ggPreparationDestinationsRouteToExistingActions() {
        #expect(ChangesTabView.stackAction(for: .newStackCommit) == nil)
        #expect(ChangesTabView.stackAction(for: .amendCurrent) == .amendCurrent)
        #expect(ChangesTabView.stackAction(for: .absorbIntoStack) == .absorbStaged)
    }

    @Test func manualRebaseActionTargetsTheProbedBehindBaseRef() async throws {
        let wt = makeWorktree()
        try FileManager.default.createDirectory(
            at: wt.path.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: wt.path) }
        let runner = RecordingLifecycleGGRunner()
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: runner)
        state.ggStack = try GGStackSnapshot.decode(
            fromJSON: Data(GGStackModelsTests.fixture.utf8)
        ).stack
        state.behindBase = GitService.BehindStatus(
            ref: "origin/main",
            sha: "base-sha",
            count: 2,
            probedAt: Date()
        )

        state.onGGStackAction(.rebase, appState: AppState(store: MemoryStore()))
        for _ in 0..<500 where !runner.containsCommand(suffix: ["rebase", "origin/main"]) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(runner.containsCommand(suffix: ["rebase", "origin/main"]))
        #expect(!runner.containsCommand(suffix: ["rebase", "main"]))
    }

    @Test func manualRebaseIgnoresBehindRefForADifferentStackBase() async throws {
        let wt = makeWorktree()
        try FileManager.default.createDirectory(
            at: wt.path.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: wt.path) }
        let runner = RecordingLifecycleGGRunner()
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: runner)
        let releaseFixture = GGStackModelsTests.fixture.replacingOccurrences(
            of: #""base": "main""#,
            with: #""base": "release""#
        )
        state.ggStack = try GGStackSnapshot.decode(fromJSON: Data(releaseFixture.utf8)).stack
        state.behindBase = GitService.BehindStatus(
            ref: "origin/main",
            sha: "base-sha",
            count: 2,
            probedAt: Date()
        )

        state.onGGStackAction(.rebase, appState: AppState(store: MemoryStore()))
        for _ in 0..<500 where !runner.containsCommand(suffix: ["rebase", "release"]) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(runner.containsCommand(suffix: ["rebase", "release"]))
        #expect(!runner.containsCommand(suffix: ["rebase", "origin/main"]))
    }

    @Test func manualRebaseUsesRemoteQualifiedRefOnlyForTheExactStackBase() {
        let qualifiedRelease = GitService.BehindStatus(
            ref: "origin/release",
            sha: "base-sha",
            count: 2,
            probedAt: Date()
        )
        let nestedRelease = GitService.BehindStatus(
            ref: "origin/team/release",
            sha: "base-sha",
            count: 2,
            probedAt: Date()
        )

        #expect(RightPaneState.ggManualRebaseTarget(
            stackBase: "release",
            behindBase: qualifiedRelease
        ) == "origin/release")
        #expect(RightPaneState.ggManualRebaseTarget(
            stackBase: "release",
            behindBase: nestedRelease
        ) == "release")
        #expect(RightPaneState.ggManualRebaseTarget(
            stackBase: "team/release",
            behindBase: nestedRelease
        ) == "origin/team/release")
    }

    @Test func genericGitRecoveryBlocksOnlyTheGGUndoPresentation() {
        #expect(RightPaneState.ggUndoRecoveryIsBlockedByGenericGitOperation(
            operationInProgress: true,
            alasGGOperationInProgress: false
        ))
        #expect(!RightPaneState.ggUndoRecoveryIsBlockedByGenericGitOperation(
            operationInProgress: false,
            alasGGOperationInProgress: false
        ))
        #expect(!RightPaneState.ggUndoRecoveryIsBlockedByGenericGitOperation(
            operationInProgress: true,
            alasGGOperationInProgress: true
        ))
    }

    @Test func dropPresentationUsesLoadedStackWithoutRunningGG() async throws {
        let wt = makeWorktree()
        let state = makeState(worktree: wt)
        let runner = ThrowingFakeGGRunner()
        state.ggService = GGService(runner: runner)
        let stack = try #require(try GGStackSnapshot.decode(
            fromJSON: Data(GGStackModelsTests.fixture.utf8)
        ).stack)
        state.ggStack = stack
        state.ggStackCommitsKey = state.currentGGStackCommitsKey
        let entry = stack.entries[1]

        state.requestGGDrop(entry)
        await Task.yield()

        #expect(state.pendingGGDrop?.target == "id-2")
        #expect(state.pendingGGDrop?.rewrittenDescendants == 1)
        #expect(runner.callCount == 0)
    }

    @Test func staleDropApplyRefreshesLoadedStack() async throws {
        let state = makeState()
        try FileManager.default.createDirectory(
            at: state.worktree.path.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let staleJSON = GGStackModelsTests.fixture.replacingOccurrences(
            of: #""pr_state": "open""#,
            with: #""pr_state": null"#
        )
        let runner = SequencedFakeGGRunner(results: [
            ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: ""),
            ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: ""),
        ])
        state.ggService = GGService(runner: runner)
        state.ggCapabilities = {
            GGCapabilities(
                structuredSplit: false,
                keepCurrentUnstack: false,
                localStackSnapshot: false
            )
        }
        state.ggContext = .active(stackName: "agent-inbox")
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "a", count: 40), stackShaped: true)]
        let stack = try #require(try GGStackSnapshot.decode(fromJSON: Data(staleJSON.utf8)).stack)
        state.ggStack = stack
        state.ggStackCommitsKey = state.currentGGStackCommitsKey

        state.requestGGDrop(stack.entries[1])
        state.performGGDrop()
        for _ in 0..<500 where runner.callCount < 2 || state.ggActionState.lastError == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(runner.callCount == 2)
        #expect(state.ggStack?.entries[1].prState == .open)
        #expect(state.ggActionState.lastError == "The stack changed. Review the updated state and try again.")
    }

    @Test func immutableDropApplyRefreshesLoadedStack() async throws {
        let state = makeState()
        try FileManager.default.createDirectory(
            at: state.worktree.path.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let mergedJSON = GGStackModelsTests.fixture.replacingOccurrences(
            of: #""pr_state": "open""#,
            with: #""pr_state": "merged""#
        )
        let runner = SequencedFakeGGRunner(results: [
            ProcessResult(exitCode: 0, stdout: mergedJSON, stderr: ""),
            ProcessResult(exitCode: 0, stdout: mergedJSON, stderr: ""),
        ])
        state.ggService = GGService(runner: runner)
        state.ggCapabilities = {
            GGCapabilities(
                structuredSplit: false,
                keepCurrentUnstack: false,
                localStackSnapshot: false
            )
        }
        state.ggContext = .active(stackName: "agent-inbox")
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "a", count: 40), stackShaped: true)]
        let stack = try #require(try GGStackSnapshot.decode(fromJSON: Data(GGStackModelsTests.fixture.utf8)).stack)
        state.ggStack = stack
        state.ggStackCommitsKey = state.currentGGStackCommitsKey

        state.requestGGDrop(stack.entries[1])
        state.performGGDrop()
        for _ in 0..<500 where runner.callCount < 2 || state.ggActionState.lastError == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(runner.callCount == 2)
        #expect(state.ggStack?.entries[1].prState == .merged)
        #expect(state.ggActionState.lastError == "Merged commits cannot be rewritten.")
    }

    @Test func splitDescriptionUsesLoadedStackWithoutRefreshingGG() async throws {
        let state = makeState()
        let runner = SplitDescriptionGGRunner()
        state.ggService = GGService(runner: runner)
        let snapshot = try GGStackSnapshot.decode(fromJSON: Data(GGStackModelsTests.fixture.utf8))
        state.ggStack = snapshot.stack
        state.ggStackCommitsKey = state.currentGGStackCommitsKey

        let loaded = try await state.loadDescription(target: GGSplitCommitTarget(
            worktreeId: state.worktree.id,
            targetGGID: "id-2",
            targetSHA: "bbbbbbb"
        ))

        #expect(runner.calls == [["split", "--describe", "--commit", "id-2", "--json"]])
        #expect(loaded.stackIdentity == snapshot.identity)
    }

    @Test func applyPreflightFailurePresentsGGServiceUserMessage() async throws {
        let wt = makeWorktree()
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: ThrowingFakeGGRunner())

        state.requestGGCheckout(target: "change-1")
        for _ in 0..<500 where state.ggActionState.lastError == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(state.ggActionState.lastError == "boom")
    }

    @Test func unchangedStackKeyStillReloadsEffectiveConfig() async throws {
        let wt = makeWorktree()
        let configURL = wt.path.appendingPathComponent(".git/gg/config.json")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: wt.path) }
        try #"{"defaults":{"sync_auto_rebase":false,"sync_behind_threshold":2}}"#
            .write(to: configURL, atomically: true, encoding: .utf8)
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "q", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(state.ggEffectiveConfig == .init(syncAutoRebase: false, syncBehindThreshold: 2))
        try #"{"defaults":{"sync_auto_rebase":true,"sync_behind_threshold":7}}"#
            .write(to: configURL, atomically: true, encoding: .utf8)

        await state.refreshGGStack()

        #expect(state.ggEffectiveConfig == .init(syncAutoRebase: true, syncBehindThreshold: 7))
        #expect(runner.callCount == 1)
    }

    @Test func forcedRemoteRefreshReloadsUnchangedStack() async {
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        let state = makeState()
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "r", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        await state.refreshGGStack(forceRemote: true)

        #expect(runner.callCount == 2)
    }

    @Test func unchangedStackKeyReconcilesUndoAgainstExternalLaterOperation() async throws {
        let wt = makeWorktree()
        try FileManager.default.createDirectory(
            at: wt.path.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        defer {
            GGUndoMarkerStore().clear(worktreeId: wt.id)
            try? FileManager.default.removeItem(at: wt.path)
        }
        let markerStore = GGUndoMarkerStore()
        markerStore.set(GGUndoMarker(operationID: "op_1"), worktreeId: wt.id)
        let runner = AdvancingUndoGGRunner()
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "u", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(state.ggUndoCandidate?.operationID == "op_1")
        #expect(markerStore.marker(worktreeId: wt.id)?.operationID == "op_1")

        await state.refreshGGStack()

        #expect(state.ggUndoCandidate == nil)
        #expect(markerStore.marker(worktreeId: wt.id) == nil)
        #expect(runner.lsCallCount == 1)
        #expect(runner.undoListCallCount == 2)
    }

    @Test func relaunchRestoresFinalDropUndoWhenCurrentBranchHasNoStack() async throws {
        let wt = makeWorktree()
        try FileManager.default.createDirectory(
            at: wt.path.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        defer {
            GGUndoMarkerStore().clear(worktreeId: wt.id)
            try? FileManager.default.removeItem(at: wt.path)
        }
        GGUndoMarkerStore().set(
            GGUndoMarker(operationID: "op_drop", removedFinalStackCommit: true),
            worktreeId: wt.id
        )
        let runner = NoCurrentStackUndoGGRunner()
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [
            commit(sha: String(repeating: "u", count: 40), stackShaped: true),
        ]

        await state.refreshGGStack()

        #expect(state.ggStack == nil)
        #expect(state.ggUndoCandidate?.operationID == "op_drop")
        #expect(runner.undoListCallCount == 1)
    }

    @Test func continueUsesExactPausedOperationIDFromProductionSnapshotPath() async throws {
        let wt = makeWorktree()
        try FileManager.default.createDirectory(
            at: wt.path.appendingPathComponent(".git/rebase-merge"),
            withIntermediateDirectories: true
        )
        defer {
            GGUndoMarkerStore().clear(worktreeId: wt.id)
            try? FileManager.default.removeItem(at: wt.path)
        }
        let runner = PausedContinueGGRunner(
            snapshotOperationID: "op_paused",
            listedOperationID: "op_paused"
        )
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: runner)
        // Seed the gg gate and a stack-shaped commit set so the post-continue
        // refresh loads the `agent-inbox` stack and reconciles the undo
        // candidate against a matching scope, rather than treating the gate as
        // closed and suspending it.
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "c", count: 40), stackShaped: true)]
        state.ggActionState.setPaused(GGPausedOperation(pausedBy: .restack))

        state.onGGStackAction(.continueOp, appState: AppState(store: MemoryStore()))
        for _ in 0..<500 where runner.continueCallCount == 0 || state.ggUndoCandidate == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(runner.continueCallCount == 1)
        #expect(state.ggUndoCandidate?.operationID == "op_paused")
    }

    @Test func continueNeverSynthesizesMissingPausedOperationID() async throws {
        let wt = makeWorktree()
        try FileManager.default.createDirectory(
            at: wt.path.appendingPathComponent(".git/rebase-merge"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: wt.path) }
        let runner = PausedContinueGGRunner(
            snapshotOperationID: nil,
            listedOperationID: "in-progress"
        )
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: runner)
        state.ggActionState.setPaused(GGPausedOperation(pausedBy: .restack))

        state.onGGStackAction(.continueOp, appState: AppState(store: MemoryStore()))
        for _ in 0..<500 where runner.continueCallCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(runner.continueCallCount == 1)
        #expect(runner.undoListCallCount == 0)
        #expect(state.ggUndoCandidate == nil)
    }

    @Test func ggOwnedPresentationUsesCommitTerminology() throws {
        let action = GGStackActionState()
        _ = action.beginAction(.sync)
        action.appendSyncEvent(.start(totalEntries: 2))
        action.appendSyncEvent(.entryStarted(position: 1, title: "First"))
        action.appendSyncEvent(.pushDone(position: 1, forced: false))
        action.appendSyncEvent(.prCreated(position: 1, prNumber: 7, prURL: nil, draft: false))
        let stack = GGStack(
            name: "feature", base: "main", totalCommits: 2, syncedCommits: 0,
            currentPosition: 2, behindBase: 0, entries: []
        )

        let drawer = GGStackReadinessModel.make(stack: stack, action: action)
        let progress = try #require(drawer.syncProgress)

        #expect(progress.liveStatus == "Syncing 1 of 2 commits…")
        #expect(progress.rows.map(\.text) == ["[1] Pushed · PR #7 created"])

        let typedStrings = drawer.facts.map(\.label)
            + progress.rows.map(\.text)
            + [progress.liveStatus ?? "", GGInboxTabView.commitCountLabel(2)]
            + [CommitRow.ggCheckoutTitle, GGMutationConfirmation.clean(mergedCommits: 2).message]
        #expect(typedStrings.allSatisfy {
            !$0.lowercased().contains("entry") && !$0.lowercased().contains("entries")
        })
    }

    /// A real repo with `main` pushed to a bare remote, then a `nacho/stack`
    /// branch carrying one GG-ID-trailered commit — also fully pushed, so
    /// `@{u}` == HEAD and the branch has nothing left unpushed.
    private func createSyncedStackRepoWithUpstream() async throws -> (worktree: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-stack-upstream-\(UUID().uuidString)")
        let remote = root.appendingPathComponent("remote.git")
        let worktree = root.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "--bare", "-b", "main"], cwd: remote)
        _ = try await Process.git(["clone", "-q", remote.path, worktree.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: worktree)
        _ = try await Process.git(["config", "user.name", "t"], cwd: worktree)
        try "base\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: worktree)
        _ = try await Process.git(["commit", "-q", "-m", "base"], cwd: worktree)
        _ = try await Process.git(["push", "-q", "-u", "origin", "main"], cwd: worktree)
        _ = try await Process.git(["checkout", "-q", "-b", "nacho/stack"], cwd: worktree)
        try "stack\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: worktree)
        _ = try await Process.git(
            ["commit", "-q", "-m", "feat: stack work", "-m", "GG-ID: abc123\nGG-Parent: def456"],
            cwd: worktree
        )
        _ = try await Process.git(["push", "-q", "-u", "origin", "nacho/stack"], cwd: worktree)
        return (worktree, root)
    }

    /// A gg stack that's already fully pushed (`gg sync` already ran) must
    /// still be detected under "Branch upstream" comparison mode. There the
    /// *display* `commits` list is `@{u}..HEAD` — empty once synced — but
    /// `ggStackSourceCommits` (fed by the review-loop base resolution,
    /// which never uses upstream) must still reflect the branch's GG-ID
    /// commit relative to `main`, or the stack-shape gate would incorrectly
    /// treat a synced stack as "not a stack" and clear the UI.
    @Test func performRefreshPopulatesGGStackSourceCommitsUnderBranchUpstreamMode() async throws {
        let (repo, root) = try await createSyncedStackRepoWithUpstream()
        defer { try? FileManager.default.removeItem(at: root) }
        let wt = Worktree(
            id: Worktree.makeId(path: repo),
            projectId: "test-project",
            name: "nacho/stack",
            branch: "nacho/stack",
            path: repo,
            status: .clean,
            lastActivity: Date()
        )
        let state = makeState(worktree: wt)
        state.comparisonMode = .branchUpstream

        await state.refresh()

        #expect(state.commits.isEmpty)
        #expect(!state.ggStackSourceCommits.isEmpty)
        #expect(GGStackGate.isStackShaped(commits: state.ggStackSourceCommits))
    }

    @Test func activeContextLoadsStackWithNoSourceCommits() async {
        let state = makeState()
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = []

        await state.refreshGGStack()

        #expect(runner.callCount == 1)
        #expect(state.ggStack != nil)
        #expect(state.ggStackLoadState == .loaded)
    }

    @Test func detachedRefreshRecoversCurrentStackAndDedupesThePromotedContext() async {
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        let state = makeState()
        var branchContext = GGWorktreeContext.active(stackName: "agent-inbox")
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in branchContext }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "d", count: 40), stackShaped: true)]

        state.seedGGContext(branch: "nacho/agent-inbox")
        await state.refreshGGStack()

        branchContext = .inactive(reason: .branchPrefixMismatch(expectedPrefix: "nacho/"))
        state.seedGGContext(branch: "")
        await state.refreshGGStack()

        #expect(runner.callCount == 2)
        #expect(state.ggContext == .active(stackName: "agent-inbox"))
        #expect(state.ggStackLoadState == .loaded)
        #expect(state.ggStackDisplayCommits.map(\.shortSha) == ["ccccccc", "bbbbbbb", "aaaaaaa"])

        await state.refreshGGStack()

        #expect(runner.callCount == 2)
    }

    @Test func coldDetachedRefreshPublishesStackToStoreSnapshotConsumers() async throws {
        let store = RightPaneStore()
        let worktree = makeWorktree()
        let state = store.state(for: worktree, baseBranch: "main", comparisonMode: .manual)
        store.deactivate()
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .inactive(reason: .branchPrefixMismatch(expectedPrefix: "nacho/")) }
        state.ggStackCommitLoader = { _, entries in
            Dictionary(uniqueKeysWithValues: entries.map { sha in
                (sha, commit(sha: sha, stackShaped: true))
            })
        }
        state.seedGGContext(branch: "")

        await state.refreshGGStack()

        let snapshot = try #require(store.ggStackSnapshotForWorktreePath(
            worktree.path.path,
            effectiveContext: .inactive(reason: .branchPrefixMismatch(expectedPrefix: "nacho/")),
            liveBranch: ""
        ))
        #expect(snapshot.stack?.name == "agent-inbox")
        #expect(snapshot.loadState == .loaded)
        #expect(state.ggStackDisplayCommits.map(\.shortSha) == ["ccccccc", "bbbbbbb", "aaaaaaa"])

        await state.refreshGGStack()

        #expect(runner.callCount == 1)
    }

    @Test func quiescentActiveStackDoesNotPublishAsDetachedRecovery() throws {
        let store = RightPaneStore()
        let worktree = makeWorktree()
        let state = store.state(for: worktree, baseBranch: "main", comparisonMode: .manual)
        store.deactivate()
        state.currentBranch = "nacho/old-stack"
        state.ggContext = .active(stackName: "old-stack")
        state.ggStack = try GGStackSnapshot.decode(
            fromJSON: Data(GGStackModelsTests.fixture.utf8)
        ).stack
        state.ggStackLoadState = .loaded
        state.ggStackCommitsKey = state.currentGGStackCommitsKey

        let detachedContext = GGWorktreeContext.inactive(
            reason: .branchPrefixMismatch(expectedPrefix: "nacho/")
        )
        #expect(store.effectiveGGContextForWorktreePath(
            worktree.path.path,
            branchContext: detachedContext,
            liveBranch: ""
        ) == detachedContext)
        let snapshot = try #require(store.ggStackSnapshotForWorktreePath(
            worktree.path.path,
            effectiveContext: detachedContext,
            liveBranch: ""
        ))
        #expect(snapshot.loadState == .inactive)
    }

    @Test func detachedRefreshWithNoCurrentStackClearsPriorPresentation() async {
        let runner = SequencedFakeGGRunner(results: [
            ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: ""),
            ProcessResult(exitCode: 0, stdout: #"{"version":1,"stack":null}"#, stderr: ""),
        ])
        let state = makeState()
        var branchContext = GGWorktreeContext.active(stackName: "agent-inbox")
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in branchContext }
        state.commits = [commit(sha: String(repeating: "p", count: 40), stackShaped: true)]
        state.ggStackSourceCommits = [commit(sha: String(repeating: "d", count: 40), stackShaped: true)]

        state.seedGGContext(branch: "nacho/agent-inbox")
        await state.refreshGGStack()
        branchContext = .inactive(reason: .branchPrefixMismatch(expectedPrefix: "nacho/"))
        state.seedGGContext(branch: "")
        await state.refreshGGStack()

        #expect(runner.callCount == 2)
        #expect(state.ggContext == .inactive(reason: .branchPrefixMismatch(expectedPrefix: "nacho/")))
        #expect(state.ggStack == nil)
        #expect(state.ggStackDisplayCommits.isEmpty)
        #expect(state.commitsForDisplay == state.commits)
    }

    @Test func policyDeniedDetachedRefreshDoesNotQueryGG() async {
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        let state = makeState()
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .inactive(reason: .policyOff) }
        state.seedGGContext(branch: "")

        await state.refreshGGStack()

        #expect(runner.callCount == 0)
        #expect(state.ggContext == .inactive(reason: .policyOff))
        #expect(state.ggStackLoadState == .inactive)
    }

    @Test func missingBranchUsernameDetachedRefreshDoesNotQueryGG() async {
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        let state = makeState()
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .inactive(reason: .branchUsernameMissing) }
        state.seedGGContext(branch: "")

        await state.refreshGGStack()

        #expect(runner.callCount == 0)
        #expect(state.ggContext == .inactive(reason: .branchUsernameMissing))
        #expect(state.ggStackLoadState == .inactive)
    }

    @Test(arguments: GGStackClassificationFixture.allCases)
    func stackClassificationKeepsEmptyUIConsistent(_ fixture: GGStackClassificationFixture) async {
        let worktree = makeWorktree()
        defer { GGStackSummaryStore.shared.summaries[worktree.path.path] = nil }
        let state = makeState(worktree: worktree)
        let runner = CountingFakeGGRunner(
            result: ProcessResult(
                exitCode: 0,
                stdout: fixture.json,
                stderr: ""
            )
        )
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.currentHeadSHA = String(repeating: "a", count: 40)

        await state.refreshGGStack()

        if fixture.isMalformed {
            #expect(state.ggStack == nil)
            #expect(state.ggStackLoadState == .failed("GG returned incomplete or inconsistent stack metadata."))
            #expect(GGStackSummaryStore.shared.summaries[worktree.path.path] == nil)
            #expect(ChangesTabView.ggNewStackCommitDisabledReason(
                contextIsActive: state.ggContext.isActive,
                stackLoadState: state.ggStackLoadState,
                stack: state.ggStack,
                currentHeadSHA: state.currentHeadSHA
            ) == "Retry loading the GG stack.")
            return
        }

        #expect((state.ggStack != nil) == fixture.hasStack)
        #expect((state.ggStackLoadState == .empty) == fixture.isEmpty)
        #expect((GGStackSummaryStore.shared.summaries[worktree.path.path] == nil) == fixture.isEmpty)
        #expect(ChangesTabView.ggNewStackCommitDisabledReason(
            contextIsActive: state.ggContext.isActive,
            stackLoadState: state.ggStackLoadState,
            stack: state.ggStack,
            currentHeadSHA: state.currentHeadSHA
        ) == nil)
        let hasLoadedCommit = state.ggStackLoadState.hasLoadedCommit
        #expect(hasLoadedCommit == !fixture.isEmpty)
        let preparation = ChangesPreparationModel.makeGG(
            staged: .init(files: 1, insertions: 1, deletions: 0),
            hasDraft: false,
            capabilities: GGCapabilities(
                structuredSplit: true,
                keepCurrentUnstack: true,
                stagedOnlyAmend: true
            ),
            hasLoadedCommit: hasLoadedCommit
        )
        #expect(preparation.ggAction(.newStackCommit)?.isEnabled == true)
        #expect(preparation.ggAction(.amendCurrent)?.isEnabled == !fixture.isEmpty)
    }

    @Test func inactiveContextSkipsGGAndClearsPublishedState() async throws {
        let wt = makeWorktree()
        let state = makeState(worktree: wt)
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        await state.refreshGGStack()
        #expect(state.ggStack != nil)

        state.ggContextProvider = { _ in .inactive(reason: .policyOff) }
        await state.refreshGGStack()

        #expect(runner.callCount == 1)
        #expect(state.ggContext == .inactive(reason: .policyOff))
        #expect(state.ggStack == nil)
        #expect(state.ggStackLoadState == .inactive)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] == nil)
    }

    @Test func gateClosedSkipsCLIAndClearsStack() async throws {
        let wt = makeWorktree()
        let state = makeState(worktree: wt)
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .inactive(reason: .policyOff) }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "a", count: 40), stackShaped: true)]

        await state.refreshGGStack()

        #expect(runner.callCount == 0)
        #expect(state.ggStack == nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] == nil)
    }

    @Test func gateClosedClearsPausedOperation() async throws {
        let wt = makeWorktree()
        let state = makeState(worktree: wt)
        state.ggContextProvider = { _ in .inactive(reason: .policyOff) }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "n", count: 40), stackShaped: true)]
        state.ggActionState.setPaused(GGPausedOperation(pausedBy: .sync))

        await state.refreshGGStack()

        #expect(state.ggActionState.pausedOperation == nil)
    }

    @Test func gateClosedHidesUndoRecoveryButPreservesMarker() async throws {
        let wt = makeWorktree()
        defer { GGUndoMarkerStore().clear(worktreeId: wt.id) }
        let markerStore = GGUndoMarkerStore()
        markerStore.set(GGUndoMarker(operationID: "op_1"), worktreeId: wt.id)
        let state = makeState(worktree: wt)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "n", count: 40), stackShaped: true)]
        state.ggService = GGService(runner: AdvancingUndoGGRunner())

        await state.refreshGGStack()
        #expect(state.ggUndoCandidate?.operationID == "op_1")

        // The gg gate can read closed transiently before the startup
        // availability probe resolves. Hide the candidate but keep the marker
        // so a valid recovery Undo is not destroyed by that race.
        state.ggContextProvider = { _ in .inactive(reason: .policyOff) }
        await state.refreshGGStack()

        #expect(state.ggUndoCandidate == nil)
        #expect(markerStore.marker(worktreeId: wt.id)?.operationID == "op_1")
    }

    @Test func failedStackRefreshHidesUndoRecoveryButPreservesMarker() async throws {
        let wt = makeWorktree()
        try FileManager.default.createDirectory(
            at: wt.path.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        defer {
            GGUndoMarkerStore().clear(worktreeId: wt.id)
            try? FileManager.default.removeItem(at: wt.path)
        }
        let markerStore = GGUndoMarkerStore()
        markerStore.set(GGUndoMarker(operationID: "op_1"), worktreeId: wt.id)
        let runner = FailSecondLsUndoGGRunner()
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "a", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(state.ggUndoCandidate?.operationID == "op_1")

        // Switch to a different stack-shaped branch: the commits key changes and
        // the `gg ls` refresh for it fails, so the cached stack is dropped and
        // the current identity is unknown. The candidate must be hidden (not
        // offered for the previous stack) while the marker survives for a later
        // reconcile to rebuild.
        state.ggStackSourceCommits = [commit(sha: String(repeating: "b", count: 40), stackShaped: true)]
        await state.refreshGGStack()

        #expect(state.ggStack == nil)
        #expect(state.ggUndoCandidate == nil)
        #expect(markerStore.marker(worktreeId: wt.id)?.operationID == "op_1")
        #expect(runner.lsCallCount == 2)
    }

    @Test func activeGGOperationPreservesPausedWhenStackShapeDisappears() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-paused-unshaped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git/rebase-merge"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wt = Worktree(
            id: Worktree.makeId(path: dir), projectId: "p", name: "feature",
            branch: "feature", path: dir, status: .clean, lastActivity: Date()
        )
        let state = makeState(worktree: wt)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "o", count: 40), stackShaped: false)]
        _ = state.ggActionState.beginAction(.sync)

        await state.refreshGGStack()

        #expect(state.ggActionState.pausedOperation != nil)
        state.ggActionState.endAction(.sync)
    }

    @Test func activeContextLoadsStackWithoutStackShapedCommits() async throws {
        let wt = makeWorktree()
        let state = makeState(worktree: wt)
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "b", count: 40), stackShaped: false)]

        await state.refreshGGStack()

        #expect(runner.callCount == 1)
        #expect(state.ggStack != nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] != nil)
    }

    @Test func unchangedCommitSetDoesNotReinvokeCLI() async throws {
        let wt = makeWorktree()
        let state = makeState(worktree: wt)
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "c", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(runner.callCount == 1)
        #expect(state.ggStack != nil)

        // Same commit set (same fingerprint) — must not hit the CLI again.
        await state.refreshGGStack()
        #expect(runner.callCount == 1)

        // Changing the commit set (new fingerprint) — must re-query.
        state.ggStackSourceCommits = [commit(sha: String(repeating: "d", count: 40), stackShaped: true)]
        await state.refreshGGStack()
        #expect(runner.callCount == 2)
    }

    @Test func projectRevisionWatcherReloadsAnUpperEntryWhenReachableCommitsAreUnchanged() async throws {
        let project = ProjectConfig(
            id: "test-project",
            name: "Test",
            path: "/repo",
            color: "blue",
            addedAt: .now
        )
        let worktree = makeWorktree()
        let gitDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-upper-stack-watch-\(UUID().uuidString)/.git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: gitDir.deletingLastPathComponent()) }
        let watcher = ProjectGitWatcher(
            repoPath: URL(fileURLWithPath: project.path),
            resolvedGitDir: gitDir,
            resolvedWorktreeRoot: worktree.path,
            headDebounceInterval: 0.01,
            headDebounceMaxWait: 0.05,
            topologyDebounceInterval: 0.01,
            topologyDebounceMaxWait: 0.05,
            startStreamOverride: { _, _ in }
        )
        let app = AppState(
            store: MemoryStore(projectsFile: ProjectsFile(projects: [project])),
            projectGitWatcherFactory: { _ in watcher }
        )
        app.projectsManager.insertOptimisticWorktree(worktree)
        app.projectsManager.setOperationState(id: worktree.id, state: nil)
        let state = app.rightPaneStore.state(
            for: worktree,
            baseBranch: "main",
            comparisonMode: .manual
        )
        state.stop()

        let lowerSnapshot = GGStackModelsTests.fixture
            .replacingOccurrences(of: #""current_position": 3"#, with: #""current_position": 1"#)
            .replacingOccurrences(of: #""is_current": true"#, with: #""is_current": false"#)
            .replacingOccurrences(
                of: #""ci_status": "success", "is_current": false"#,
                with: #""ci_status": "success", "is_current": true"#
            )
        let rewrittenUpperSnapshot = lowerSnapshot.replacingOccurrences(of: "ccccccc", with: "ddddddd")
        let runner = ControlledStackGGRunner(
            stackResults: [
                ("agent-inbox", ProcessResult(exitCode: 0, stdout: lowerSnapshot, stderr: "")),
                ("agent-inbox", ProcessResult(exitCode: 0, stdout: rewrittenUpperSnapshot, stderr: "")),
            ],
            suspendedCalls: []
        )
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "a", count: 40), stackShaped: true)]
        installFakeGGStackLoader(on: state)

        await state.refreshGGStack()
        #expect(state.ggStackDisplayCommits.first?.shortSha == "ccccccc")
        let unchangedReachableKey = state.currentGGStackCommitsKey

        app.startProjectGitWatcher(for: project)
        watcher.processEvents([gitDir.appendingPathComponent("refs/remotes/origin/upper-entry").path])
        for _ in 0..<500 where await runner.lsCallCount < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        for _ in 0..<500 where state.ggStackDisplayCommits.first?.shortSha != "ddddddd" {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        #expect(state.currentGGStackCommitsKey == unchangedReachableKey)
        #expect(await runner.lsCallCount == 2)
        #expect(state.ggStackDisplayCommits.first?.shortSha == "ddddddd")
        app.stopProjectGitWatcher(projectId: project.id)
    }

    @Test func projectRevisionInvalidatesInactiveCachedGGPresentation() async throws {
        let store = RightPaneStore()
        let inactiveWorktree = makeWorktree()
        let activeWorktree = makeWorktree()
        let inactive = store.state(
            for: inactiveWorktree,
            baseBranch: "main",
            comparisonMode: .manual
        )
        let active = store.state(
            for: activeWorktree,
            baseBranch: "main",
            comparisonMode: .manual
        )

        inactive.stop()
        active.stop()
        inactive.ggContext = .active(stackName: "agent-inbox")
        inactive.ggStackSourceCommits = [commit(sha: String(repeating: "a", count: 40), stackShaped: true)]
        inactive.ggStackCommitsKey = inactive.currentGGStackCommitsKey
        inactive.ggStackLoadState = .loaded
        active.ggService = GGService(runner: CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        ))
        active.ggContext = .active(stackName: "agent-inbox")
        active.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
        active.ggStackSourceCommits = [commit(sha: String(repeating: "a", count: 40), stackShaped: true)]
        installFakeGGStackLoader(on: active)

        let task = try #require(store.refreshActiveGGPresentationForProjectRevision(
            projectId: inactiveWorktree.projectId
        ))
        await task.value

        #expect(inactive.ggStackCommitsKey == nil)
        #expect(store.ggStackSnapshotForWorktreePath(
            inactiveWorktree.path.path,
            effectiveContext: .active(stackName: "agent-inbox"),
            liveBranch: inactive.currentBranch
        )?.loadState == .loading)
        #expect(active.ggStackLoadState == .loaded)
    }

    /// `reevaluateGGGate()` must clear stale stack state immediately when the
    /// gate flips closed (e.g. the Settings master toggle goes off), rather
    /// than waiting for the next watcher-driven refresh. `reevaluateGGGate()`
    /// returns its underlying fire-and-forget task so the test can await it
    /// deterministically instead of racing the MainActor scheduler.
    @Test func reevaluateGGGateClearsStackWhenGateClosed() async throws {
        let wt = makeWorktree()
        let state = makeState(worktree: wt)
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "e", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(state.ggStack != nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] != nil)

        // Simulate the master toggle going off in Settings.
        state.ggContextProvider = { _ in .inactive(reason: .policyOff) }
        await state.reevaluateGGGate().value

        #expect(state.ggStack == nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] == nil)
    }

    @Test func storeReevaluatesGGGateOnlyForRequestedWorktree() async throws {
        let firstWorktree = makeWorktree()
        let secondWorktree = makeWorktree()
        let store = RightPaneStore()
        let first = store.state(for: firstWorktree, baseBranch: "main", comparisonMode: .manual)
        let second = store.state(for: secondWorktree, baseBranch: "main", comparisonMode: .manual)
        store.deactivate()

        var firstEvaluationCount = 0
        var secondEvaluationCount = 0
        first.ggContextProvider = { _ in
            firstEvaluationCount += 1
            return .inactive(reason: .policyOff)
        }
        second.ggContextProvider = { _ in
            secondEvaluationCount += 1
            return .inactive(reason: .policyOff)
        }

        let task = try #require(store.reevaluateGGGate(worktreeId: firstWorktree.id))
        await task.value

        #expect(firstEvaluationCount == 1)
        #expect(secondEvaluationCount == 0)
        #expect(store.reevaluateGGGate(worktreeId: "missing") == nil)
    }

    /// A thrown gg failure must not cache the commits key — otherwise a
    /// transient error (auth hiccup, network blip) permanently skips retries
    /// for that commit set via the unchanged-key guard, even after the
    /// underlying problem clears up.
    @Test func transientFailureDoesNotPoisonCommitsKeyCache() async throws {
        let wt = makeWorktree()
        let state = makeState(worktree: wt)
        let runner = ThrowingFakeGGRunner()
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "f", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(runner.callCount == 1)
        #expect(state.ggStack == nil)
        #expect(state.ggStackCommitsKey == nil)

        // Same commit set again — since the key was never cached, this must
        // retry rather than being skipped by the unchanged-key guard.
        await state.refreshGGStack()
        #expect(runner.callCount == 2)
    }

    @Test func transientStackLoadFailurePreservesUndoRecoveryMarker() async throws {
        let wt = makeWorktree()
        defer { GGUndoMarkerStore().clear(worktreeId: wt.id) }
        let markerStore = GGUndoMarkerStore()
        markerStore.set(GGUndoMarker(operationID: "op_1"), worktreeId: wt.id)
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: ThrowingFakeGGRunner())
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "f", count: 40), stackShaped: true)]

        await state.refreshGGStack()

        #expect(state.ggUndoCandidate == nil)
        #expect(markerStore.marker(worktreeId: wt.id)?.operationID == "op_1")
    }

    @Test func staleWatcherStackLoadCannotOverwriteNewerRefresh() async throws {
        let wt = makeWorktree()
        let stale = ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        let fresh = ProcessResult(
            exitCode: 0,
            stdout: GGStackModelsTests.fixture.replacingOccurrences(of: "agent-inbox", with: "fresh-stack"),
            stderr: ""
        )
        let runner = DelayedStackGGRunner(staleResult: stale, freshResult: fresh)
        let state = makeState(worktree: wt)
        var hydrationInvocation = 0
        state.ggStackCommitLoader = { _, shas in
            hydrationInvocation += 1
            let subject = hydrationInvocation == 1 ? "fresh hydration" : "stale hydration"
            return Dictionary(uniqueKeysWithValues: shas.map { sha in
                let fullSHA = sha + String(repeating: "0", count: 40 - sha.count)
                return (fullSHA, self.commit(sha: fullSHA, stackShaped: true, subject: subject))
            })
        }
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "z", count: 40), stackShaped: true)]

        let staleRefresh = Task { @MainActor in await state.refreshGGStack() }
        for _ in 0..<500 where runner.callCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(runner.callCount == 1)

        state.ggStackCommitsKey = nil
        await state.refreshGGStack()
        #expect(state.ggStack?.name == "fresh-stack")
        #expect(state.ggStackDisplayCommits.allSatisfy { $0.subject == "fresh hydration" })

        await staleRefresh.value
        #expect(state.ggStack?.name == "fresh-stack")
        #expect(state.ggStackDisplayCommits.allSatisfy { $0.subject == "fresh hydration" })
    }

    /// A stack loaded for one branch must not keep rendering after the user
    /// switches to a different stack-shaped branch and the reload for it
    /// fails transiently — the stale stack no longer matches `commits`.
    @Test func failedReloadClearsStaleStackFromDifferentBranch() async throws {
        let wt = makeWorktree()
        let state = makeState(worktree: wt)

        let okRunner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: okRunner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.currentBranch = "nacho/stack-a"
        state.ggStackSourceCommits = [commit(sha: String(repeating: "i", count: 40), stackShaped: true)]
        await state.refreshGGStack()
        #expect(state.ggStack != nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] != nil)

        let throwingRunner = ThrowingFakeGGRunner()
        state.ggService = GGService(runner: throwingRunner)
        state.currentBranch = "nacho/stack-b"
        state.ggStackSourceCommits = [commit(sha: String(repeating: "j", count: 40), stackShaped: true)]
        await state.refreshGGStack()

        #expect(throwingRunner.callCount == 1)
        #expect(state.ggStack == nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] == nil)

        // The cache key is reset (not left at branch A's stale key, and not
        // set to branch B's failed key) — retrying must re-invoke gg rather
        // than being skipped by the unchanged-key guard either way.
        #expect(state.ggStackCommitsKey == nil)
        await state.refreshGGStack()
        #expect(throwingRunner.callCount == 2)
    }

    /// The cache key must be reset (not left pointing at the last
    /// *successful* key) when a later reload fails and clears `ggStack` —
    /// otherwise returning to that prior branch/commit set would hit the
    /// unchanged-key guard and skip re-fetching the now-cleared stack,
    /// leaving the UI stuck showing plain commits.
    @Test func failedReloadAllowsRefetchOnReturnToPriorBranch() async throws {
        let wt = makeWorktree()
        let state = makeState(worktree: wt)
        let commitsA = [commit(sha: String(repeating: "k", count: 40), stackShaped: true)]

        let firstRunner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: firstRunner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.currentBranch = "nacho/stack-a"
        state.ggStackSourceCommits = commitsA
        await state.refreshGGStack()
        #expect(state.ggStack != nil)

        let throwingRunner = ThrowingFakeGGRunner()
        state.ggService = GGService(runner: throwingRunner)
        state.currentBranch = "nacho/stack-b"
        state.ggStackSourceCommits = [commit(sha: String(repeating: "l", count: 40), stackShaped: true)]
        await state.refreshGGStack()
        #expect(state.ggStack == nil)

        // Back to branch A with the exact same commits as the first,
        // successful load — must re-fetch, not be skipped as "unchanged".
        let secondRunner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: secondRunner)
        state.currentBranch = "nacho/stack-a"
        state.ggStackSourceCommits = commitsA
        await state.refreshGGStack()

        #expect(secondRunner.callCount == 1)
        #expect(state.ggStack != nil)
    }

    /// `gg ls --json` answers for the *current* branch, so a checkout to a
    /// different branch that happens to share the same commit SHAs (e.g.
    /// right after `git checkout -b` from the same HEAD) must not reuse the
    /// previous branch's cached stack via the unchanged-commits guard.
    @Test func branchChangeWithSameCommitsReinvokesCLI() async throws {
        let wt = makeWorktree()
        let state = makeState(worktree: wt)
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.currentBranch = "nacho/stack-a"
        state.ggStackSourceCommits = [commit(sha: String(repeating: "h", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(runner.callCount == 1)

        state.currentBranch = "nacho/stack-b"
        await state.refreshGGStack()
        #expect(runner.callCount == 2)
    }

    @Test func activeContextNameChangeWithSameBranchAndCommitsReinvokesCLI() async {
        let state = makeState()
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        var stackName = "stack-a"
        state.ggContextProvider = { _ in .active(stackName: stackName) }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "h", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(runner.callCount == 1)

        stackName = "stack-b"
        await state.refreshGGStack()

        #expect(state.ggContext == .active(stackName: "stack-b"))
        #expect(runner.callCount == 2)
    }

    @Test func headInvalidationPreventsInFlightRefreshFromRepublishingQuiescentStack() async {
        let worktree = makeWorktree()
        defer { GGStackSummaryStore.shared.summaries[worktree.path.path] = nil }
        let runner = ControlledStackGGRunner(
            stackResults: [
                ("agent-inbox", ProcessResult(
                    exitCode: 0,
                    stdout: GGStackModelsTests.fixture,
                    stderr: ""
                )),
            ],
            suspendedCalls: [1]
        )
        let store = RightPaneStore()
        let state = store.state(for: worktree, baseBranch: "main", comparisonMode: .manual)
        state.stop()
        installFakeGGStackLoader(on: state)
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in
            .inactive(reason: .branchPrefixMismatch(expectedPrefix: "nacho/"))
        }
        state.seedGGContext(branch: "")

        let inFlightRefresh = Task { @MainActor in
            await state.refreshGGStack()
        }
        await runner.waitUntilCall(1)
        #expect(state.ggStackLoadState == .loading)

        store.deactivate()
        store.refreshActiveGGPresentationForHeadUpdates(
            projectId: worktree.projectId,
            worktreePaths: [worktree.path]
        )
        await runner.complete(call: 1)
        await inFlightRefresh.value

        #expect(state.ggStack == nil)
        #expect(state.ggStackDisplayCommits.isEmpty)
        #expect(state.ggStackCommitsKey == nil)
        #expect(state.ggStackLoadState != .loaded)
        #expect(GGStackSummaryStore.shared.summaries[worktree.path.path] == nil)
    }

    @Test func headInvalidationKeepsLoadedStackVisibleDuringSync() async {
        let worktree = makeWorktree()
        let state = makeState(worktree: worktree)
        let staleSnapshot = GGStackModelsTests.fixture.replacingOccurrences(
            of: "agent-inbox",
            with: "stale-stack"
        )
        let runner = ControlledStackGGRunner(
            stackResults: [("stale-stack", ProcessResult(exitCode: 0, stdout: staleSnapshot, stderr: ""))],
            suspendedCalls: [1]
        )
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "feature") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "a", count: 40), stackShaped: true)]
        state.ggContext = .active(stackName: "feature")
        state.ggStack = GGStack(
            name: "feature",
            base: "main",
            totalCommits: 1,
            syncedCommits: 0,
            currentPosition: 1,
            behindBase: nil,
            entries: [GGStackEntry(position: 1, sha: "abc1234", title: "Change", isCurrent: true)]
        )
        state.ggStackLoadState = .loaded
        state.ggStackCommitsKey = state.currentGGStackCommitsKey

        let staleRefresh = Task { @MainActor in await state.refreshGGStack(forceRemote: true) }
        await runner.waitUntilCall(1)
        _ = state.ggActionState.beginAction(.sync)

        let refresh = state.invalidateGGPresentation(startingRefresh: false)

        #expect(refresh == nil)
        #expect(state.ggStackLoadState == .loaded)
        #expect(state.ggStack?.name == "feature")
        #expect(state.ggStackCommitsKey == state.currentGGStackCommitsKey)

        await runner.complete(call: 1)
        await staleRefresh.value
        #expect(state.ggStack?.name == "feature")
    }

    @Test func activeHeadInvalidationReplacesInFlightColdDetachedRecovery() async throws {
        let worktree = makeWorktree()
        defer { GGStackSummaryStore.shared.summaries[worktree.path.path] = nil }
        let staleSnapshot = GGStackModelsTests.fixture.replacingOccurrences(
            of: "agent-inbox",
            with: "stale-stack"
        )
        let runner = ControlledStackGGRunner(
            stackResults: [
                ("stale-stack", ProcessResult(exitCode: 0, stdout: staleSnapshot, stderr: "")),
                ("agent-inbox", ProcessResult(
                    exitCode: 0,
                    stdout: GGStackModelsTests.fixture,
                    stderr: ""
                )),
            ],
            suspendedCalls: [1]
        )
        let store = RightPaneStore()
        let state = store.state(for: worktree, baseBranch: "main", comparisonMode: .manual)
        state.stop()
        installFakeGGStackLoader(on: state)
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in
            .inactive(reason: .branchPrefixMismatch(expectedPrefix: "nacho/"))
        }
        state.seedGGContext(branch: "")

        let initialRefresh = state.reevaluateGGGate()
        await runner.waitUntilCall(1)
        #expect(state.ggStackLoadState == .loading)

        let replacementRefresh = store.refreshActiveGGPresentationForHeadUpdates(
            projectId: worktree.projectId,
            worktreePaths: [worktree.path]
        )
        await runner.complete(call: 1)
        await initialRefresh.value
        for _ in 0..<500 where await runner.lsCallCount < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await replacementRefresh?.value

        #expect(await runner.lsCallCount == 2)
        #expect(state.ggContext == .active(stackName: "agent-inbox"))
        #expect(state.ggStack?.name == "agent-inbox")
        #expect(state.ggStackLoadState == .loaded)
        #expect(state.ggStackDisplayCommits.map(\.shortSha) == ["ccccccc", "bbbbbbb", "aaaaaaa"])
        #expect(state.ggStackCommitsKey != nil)
    }

    @Test func cancelledSameKeyReloadRestoresPreviousStableStack() async throws {
        let worktree = makeWorktree()
        defer { GGStackSummaryStore.shared.summaries[worktree.path.path] = nil }
        let result = ProcessResult(
            exitCode: 0,
            stdout: GGStackModelsTests.fixture,
            stderr: ""
        )
        let cancelledResult = ProcessResult(
            exitCode: 0,
            stdout: GGStackModelsTests.fixture.replacingOccurrences(
                of: "agent-inbox",
                with: "cancelled-response"
            ),
            stderr: ""
        )
        let runner = ControlledStackGGRunner(
            stackResults: [("agent-inbox", result), ("cancelled-response", cancelledResult)],
            suspendedCalls: [2]
        )
        let state = makeState(worktree: worktree)
        var hydrationInvocation = 0
        state.ggStackCommitLoader = { _, shas in
            hydrationInvocation += 1
            let subject = hydrationInvocation == 1 ? "stable hydration" : "cancelled hydration"
            return Dictionary(uniqueKeysWithValues: shas.map { sha in
                let fullSHA = sha + String(repeating: "0", count: 40 - sha.count)
                return (fullSHA, self.commit(sha: fullSHA, stackShaped: true, subject: subject))
            })
        }
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
        state.ggStackSourceCommits = [
            commit(sha: String(repeating: "q", count: 40), stackShaped: true),
        ]

        await state.refreshGGStack()
        let stableKey = try #require(state.ggStackCommitsKey)
        let stableSummary = try #require(GGStackSummaryStore.shared.summaries[worktree.path.path])
        let stableDisplayCommits = state.ggStackDisplayCommits

        let refresh = Task { @MainActor in
            await state.refreshGGStack(forceRemote: true)
        }
        await runner.waitUntilCall(2)
        #expect(state.ggStackLoadState == .loaded)
        #expect(state.ggStack?.name == "agent-inbox")
        #expect(state.ggStackDisplayCommits == stableDisplayCommits)

        refresh.cancel()
        await runner.complete(call: 2)
        await refresh.value

        #expect(state.ggStackLoadState == .loaded)
        #expect(state.ggStack?.name == "agent-inbox")
        #expect(state.ggStack?.name != "cancelled-response")
        #expect(state.ggStackCommitsKey == stableKey)
        #expect(state.ggStackDisplayCommits == stableDisplayCommits)
        #expect(state.ggStackDisplayCommits.allSatisfy { $0.subject == "stable hydration" })
        #expect(hydrationInvocation == 2)
        #expect(GGStackSummaryStore.shared.summaries[worktree.path.path] == stableSummary)
    }

    @Test func successfulSameKeyRetryClearsRemoteError() async {
        let worktree = makeWorktree()
        let result = ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        let runner = ControlledStackGGRunner(
            stackResults: [
                ("agent-inbox", result),
                ("agent-inbox", ProcessResult(exitCode: 1, stdout: "", stderr: "remote unavailable")),
                ("agent-inbox", result),
            ],
            suspendedCalls: []
        )
        let state = makeState(worktree: worktree)
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "q", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        await state.refreshGGStack(forceRemote: true)
        #expect(state.ggStackRemoteError == "remote unavailable")

        await state.refreshGGStack(forceRemote: true)
        #expect(state.ggStackRemoteError == nil)
    }

    @Test func sameKeyEmptyRefreshFailureBecomesRetryableFailure() async {
        let worktree = makeWorktree()
        let emptyResult = ProcessResult(exitCode: 0, stdout: GGStackClassificationFixture.nilStack.json, stderr: "")
        let runner = ControlledStackGGRunner(
            stackResults: [
                ("agent-inbox", emptyResult),
                ("agent-inbox", ProcessResult(exitCode: 1, stdout: "", stderr: "remote unavailable")),
            ],
            suspendedCalls: []
        )
        let state = makeState(worktree: worktree)
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "q", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(state.ggStackLoadState == .empty)

        await state.refreshGGStack(forceRemote: true)
        #expect(state.ggStackLoadState == .failed("remote unavailable"))
        #expect(state.ggStackRemoteError == nil)
    }

    @Test func cancelledRefreshWithChangedLiveKeyDoesNotRestorePreviousStack() async {
        let worktree = makeWorktree()
        defer { GGStackSummaryStore.shared.summaries[worktree.path.path] = nil }
        let result = ProcessResult(
            exitCode: 0,
            stdout: GGStackModelsTests.fixture,
            stderr: ""
        )
        let runner = ControlledStackGGRunner(
            stackResults: [("agent-inbox", result), ("agent-inbox", result)],
            suspendedCalls: [2]
        )
        let state = makeState(worktree: worktree)
        var hydrationInvocation = 0
        state.ggStackCommitLoader = { _, shas in
            hydrationInvocation += 1
            let subject = hydrationInvocation == 1 ? "old hydration" : "changed hydration"
            return Dictionary(uniqueKeysWithValues: shas.map { sha in
                let fullSHA = sha + String(repeating: "0", count: 40 - sha.count)
                return (fullSHA, self.commit(sha: fullSHA, stackShaped: true, subject: subject))
            })
        }
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
        state.currentBranch = "nacho/old-stack"
        state.ggStackSourceCommits = [
            commit(sha: String(repeating: "s", count: 40), stackShaped: true),
        ]
        await state.refreshGGStack()
        #expect(state.ggStack?.name == "agent-inbox")
        #expect(GGStackSummaryStore.shared.summaries[worktree.path.path] != nil)

        let refresh = Task { @MainActor in
            await state.refreshGGStack(forceRemote: true)
        }
        await runner.waitUntilCall(2)
        state.currentBranch = "nacho/new-stack"
        state.ggStackSourceCommits = [
            commit(sha: String(repeating: "t", count: 40), stackShaped: true),
        ]

        refresh.cancel()
        await runner.complete(call: 2)
        await refresh.value

        #expect(state.ggStackLoadState == .failed("Stack refresh was interrupted. Retry to load it again."))
        #expect(state.ggStack == nil)
        #expect(state.ggStackDisplayCommits.isEmpty)
        #expect(hydrationInvocation == 2)
        #expect(state.ggStackCommitsKey == nil)
        #expect(GGStackSummaryStore.shared.summaries[worktree.path.path] == nil)
    }

    @Test func cancelledFirstStackLoadBecomesRetryableFailure() async {
        let worktree = makeWorktree()
        let result = ProcessResult(
            exitCode: 0,
            stdout: GGStackModelsTests.fixture,
            stderr: ""
        )
        let runner = ControlledStackGGRunner(
            stackResults: [("agent-inbox", result)],
            suspendedCalls: [1]
        )
        let state = makeState(worktree: worktree)
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
        state.ggStackSourceCommits = [
            commit(sha: String(repeating: "r", count: 40), stackShaped: true),
        ]

        let refresh = Task { @MainActor in await state.refreshGGStack() }
        await runner.waitUntilCall(1)
        #expect(state.ggStackLoadState == .loading)

        refresh.cancel()
        await runner.complete(call: 1)
        await refresh.value

        #expect(state.ggStackLoadState == .failed("Stack refresh was interrupted. Retry to load it again."))
        #expect(state.ggStack == nil)
        #expect(state.ggStackCommitsKey == nil)
    }

    @Test func changedKeyLoadingInvalidatesOldCacheAndSuspendsUndoUntilReconciled() async throws {
        let worktree = makeWorktree()
        try FileManager.default.createDirectory(
            at: worktree.path.appendingPathComponent(".git/rebase-merge"),
            withIntermediateDirectories: true
        )
        let markerStore = GGUndoMarkerStore()
        markerStore.set(GGUndoMarker(operationID: "op_1"), worktreeId: worktree.id)
        GGStackGate.markAlasGGOperationInProgress(repoPath: worktree.path.path)
        defer {
            markerStore.clear(worktreeId: worktree.id)
            GGStackSummaryStore.shared.summaries[worktree.path.path] = nil
            try? FileManager.default.removeItem(at: worktree.path)
        }
        let oldResult = ProcessResult(
            exitCode: 0,
            stdout: GGStackModelsTests.fixture,
            stderr: ""
        )
        let newResult = ProcessResult(
            exitCode: 0,
            stdout: GGStackModelsTests.fixture.replacingOccurrences(
                of: "agent-inbox",
                with: "new-stack"
            ),
            stderr: ""
        )
        let runner = ControlledStackGGRunner(
            stackResults: [
                ("agent-inbox", oldResult),
                ("new-stack", newResult),
                ("agent-inbox", oldResult),
                ("new-stack", newResult),
            ],
            suspendedCalls: [2, 4]
        )
        let state = makeState(worktree: worktree)
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.currentBranch = "nacho/old-stack"
        state.ggStackSourceCommits = [commit(sha: String(repeating: "m", count: 40), stackShaped: true)]
        await state.refreshGGStack()
        #expect(state.ggStack?.name == "agent-inbox")
        #expect(GGStackSummaryStore.shared.summaries[worktree.path.path] != nil)
        #expect(state.ggUndoCandidate?.operationID == "op_1")
        #expect(state.ggActionState.pausedOperation != nil)
        let oldKey = try #require(state.ggStackCommitsKey)

        state.currentBranch = "nacho/new-stack"
        state.ggStackSourceCommits = [commit(sha: String(repeating: "n", count: 40), stackShaped: true)]
        let refresh = Task { @MainActor in await state.refreshGGStack() }
        await runner.waitUntilCall(2)

        #expect(await runner.lsCallCount == 2)
        #expect(state.ggStackLoadState == .loading)
        #expect(state.ggStack == nil)
        #expect(state.ggStackCommitsKey == nil)
        #expect(GGStackSummaryStore.shared.summaries[worktree.path.path] == nil)
        #expect(state.ggUndoCandidate == nil)
        #expect(markerStore.marker(worktreeId: worktree.id)?.operationID == "op_1")
        #expect(state.ggActionState.pausedOperation != nil)

        refresh.cancel()
        await runner.complete(call: 2)
        await refresh.value

        state.currentBranch = "nacho/old-stack"
        state.ggStackSourceCommits = [commit(sha: String(repeating: "m", count: 40), stackShaped: true)]
        await state.refreshGGStack()

        let retryCallCount = await runner.lsCallCount
        #expect(retryCallCount == 3)
        guard retryCallCount == 3 else { return }
        #expect(state.ggStackCommitsKey == oldKey)
        #expect(state.ggStack?.name == "agent-inbox")
        #expect(state.ggUndoCandidate?.operationID == "op_1")

        state.currentBranch = "nacho/new-stack"
        state.ggStackSourceCommits = [commit(sha: String(repeating: "n", count: 40), stackShaped: true)]
        let successfulRefresh = Task { @MainActor in await state.refreshGGStack() }
        await runner.waitUntilCall(4)
        #expect(state.ggUndoCandidate == nil)
        #expect(state.ggActionState.pausedOperation != nil)
        await runner.complete(call: 4)
        await successfulRefresh.value

        #expect(state.ggStackLoadState == .loaded)
        #expect(state.ggStack?.name == "new-stack")
        #expect(state.ggUndoCandidate?.operationID == "op_1")
        #expect(GGStackSummaryStore.shared.summaries[worktree.path.path] != nil)
        #expect(state.ggActionState.pausedOperation != nil)
    }

    @Test func storeSnapshotMarksStaleStackKeyAsLoading() async throws {
        let worktree = makeWorktree()
        let store = RightPaneStore()
        let state = store.state(for: worktree, baseBranch: "main", comparisonMode: .manual)
        store.deactivate()
        installFakeGGStackLoader(on: state)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggService = GGService(runner: CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        ))
        state.ggStackSourceCommits = [commit(sha: String(repeating: "o", count: 40), stackShaped: true)]
        await state.refreshGGStack()
        #expect(state.ggStackLoadState == .loaded)

        state.ggStackSourceCommits = [commit(sha: String(repeating: "p", count: 40), stackShaped: true)]
        let snapshot = try #require(store.ggStackSnapshotForWorktreePath(
            worktree.path.path,
            effectiveContext: .active(stackName: "stack"),
            liveBranch: state.currentBranch
        ))

        #expect(snapshot.stack != nil)
        #expect(snapshot.loadState == .loading)
    }

    @Test func storeSnapshotMarksStaleContextAsLoading() async throws {
        let worktree = makeWorktree()
        let store = RightPaneStore()
        let state = store.state(for: worktree, baseBranch: "main", comparisonMode: .manual)
        store.deactivate()
        installFakeGGStackLoader(on: state)
        state.ggContextProvider = { _ in .active(stackName: "old-stack") }
        state.ggService = GGService(runner: CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        ))
        await state.refreshGGStack()

        let snapshot = try #require(store.ggStackSnapshotForWorktreePath(
            worktree.path.path,
            effectiveContext: .active(stackName: "new-stack"),
            liveBranch: state.currentBranch
        ))

        #expect(snapshot.stack != nil)
        #expect(snapshot.loadState == .loading)
    }

    /// `markSnapshotUnknown()` resets `commits` along with the rest of the
    /// snapshot; gg stack state derives from `commits`, so it must be reset
    /// in lockstep or a delayed/failed refresh after invalidation can leave
    /// a stale "Stack · …" header/sidebar badge rendered against an emptied
    /// commit list.
    @Test func markSnapshotUnknownClearsStackState() async throws {
        let wt = makeWorktree()
        let state = makeState(worktree: wt)
        let runner = CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        )
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "g", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(state.ggStack != nil)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] != nil)

        state.markSnapshotUnknown()

        #expect(state.ggStack == nil)
        #expect(state.ggStackDisplayCommits.isEmpty)
        #expect(state.ggStackCommitsKey == nil)
        #expect(state.ggStackLoadState == .loading)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] == nil)
    }

    @Test func markSnapshotUnknownKeepsInactiveLoadStateInactive() {
        let state = makeState()
        state.ggContext = .inactive(reason: .policyOff)
        state.ggStackLoadState = .inactive

        state.markSnapshotUnknown()

        #expect(state.ggStackLoadState == .inactive)
    }

    /// Plain git actions use the same marker files as paused gg actions, so
    /// stack refresh must not infer a gg pause from filesystem state alone.
    @Test func refreshDoesNotInferPausedFromPlainGitProbe() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-paused-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git/rebase-merge"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wt = Worktree(
            id: Worktree.makeId(path: dir), projectId: "p", name: "feature",
            branch: "feature", path: dir, status: .clean, lastActivity: Date()
        )
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        ))
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "a", count: 40), stackShaped: true)]

        await state.refreshGGStack()
        #expect(state.ggActionState.pausedOperation == nil)

        _ = state.ggActionState.beginAction(.sync)
        GGStackGate.markAlasGGOperationInProgress(repoPath: dir.path)
        state.ggStackCommitsKey = nil
        await state.refreshGGStack()
        #expect(state.ggActionState.pausedOperation != nil)
        state.ggActionState.endAction(.sync)

        // Remove the marker → next refresh clears paused.
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".git/rebase-merge"))
        state.ggStackCommitsKey = nil // force a re-query past the unchanged-key guard
        await state.refreshGGStack()
        #expect(state.ggActionState.pausedOperation == nil)
    }

    @Test func refreshRestoresPausedGGOperationFromAlasMarker() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-paused-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git/rebase-merge"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        GGStackGate.markAlasGGOperationInProgress(repoPath: dir.path)
        let wt = Worktree(
            id: Worktree.makeId(path: dir), projectId: "p", name: "feature",
            branch: "feature", path: dir, status: .clean, lastActivity: Date()
        )
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        ))
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "r", count: 40), stackShaped: true)]

        await state.refreshGGStack()

        #expect(state.ggActionState.pausedOperation == GGPausedOperation(pausedBy: .sync))
    }

    @Test func inactiveDetachedRefreshRestoresPausedGGOperationAndRoutesRecoveryThroughGG() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-paused-detached-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".git/rebase-merge"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        GGStackGate.markAlasGGOperationInProgress(repoPath: dir.path)
        let wt = Worktree(
            id: Worktree.makeId(path: dir), projectId: "p", name: "detached",
            branch: "", path: dir, status: .clean, lastActivity: Date()
        )
        let runner = PausedContinueGGRunner(
            snapshotOperationID: nil,
            listedOperationID: "in-progress"
        )
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .inactive(reason: .branchPrefixMismatch(expectedPrefix: "nacho/")) }
        state.currentBranch = ""

        await state.refreshGGStack()

        #expect(state.ggContext == .active(stackName: "agent-inbox"))
        #expect(state.ggStackLoadState == .loaded)
        #expect(state.ggActionState.pausedOperation == GGPausedOperation(pausedBy: .sync))

        state.onGGStackAction(.continueOp, appState: AppState(store: MemoryStore()))
        for _ in 0..<500 where runner.continueCallCount == 0 || state.ggActionState.inFlightAction != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(runner.continueCallCount == 1)

        state.onGGStackAction(.abortOp, appState: AppState(store: MemoryStore()))
        for _ in 0..<500 where runner.abortCallCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(runner.abortCallCount == 1)
    }

    @Test func refreshClearsStaleAlasMarkerWhenNoGitOperationIsInProgress() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-stale-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        GGStackGate.markAlasGGOperationInProgress(repoPath: dir.path)
        let wt = Worktree(
            id: Worktree.makeId(path: dir), projectId: "p", name: "feature",
            branch: "feature", path: dir, status: .clean, lastActivity: Date()
        )
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        ))
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "t", count: 40), stackShaped: true)]

        await state.refreshGGStack()

        #expect(state.ggActionState.pausedOperation == nil)
        #expect(GGStackGate.alasGGOperationInProgress(repoPath: dir.path) == false)
    }

    @Test func thrownRefreshKeepsPausedOperationWhenGitProbeIsPaused() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-paused-throw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git/rebase-merge"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wt = Worktree(
            id: Worktree.makeId(path: dir), projectId: "p", name: "feature",
            branch: "feature", path: dir, status: .clean, lastActivity: Date()
        )
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: ThrowingFakeGGRunner())
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "m", count: 40), stackShaped: true)]
        state.ggActionState.setPaused(GGPausedOperation(pausedBy: .sync))

        await state.refreshGGStack()

        #expect(state.ggStack == nil)
        #expect(state.ggActionState.pausedOperation != nil)
    }

    @Test func syncConflictPreservesPausedBeforeClearingInFlight() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-sync-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wt = Worktree(
            id: Worktree.makeId(path: dir), projectId: "p", name: "feature",
            branch: "feature", path: dir, status: .clean, lastActivity: Date()
        )
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: ConflictAfterSyncRunner())
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "s", count: 40), stackShaped: true)]

        state.onGGStackAction(.sync, appState: AppState(store: MemoryStore()))
        for _ in 0..<500 where state.ggActionState.pausedOperation == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(state.ggActionState.pausedOperation == GGPausedOperation(pausedBy: .sync))
    }

    @Test func successfulCleanRefreshesProjectTopology() async throws {
        let wt = makeWorktree()
        try FileManager.default.createDirectory(
            at: wt.path.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: wt.path) }
        let runner = CleanMutationFakeGGRunner()
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: runner)
        var didRefreshProjectTopology = false
        state.refreshProjectTopologyAfterGGMutation = {
            didRefreshProjectTopology = true
        }

        state.requestGGCleanAll()
        for _ in 0..<500 where !state.pendingGGCleanAll && state.ggActionState.lastError == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        state.performGGCleanAll()
        for _ in 0..<500 where !didRefreshProjectTopology && state.ggActionState.lastError == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(runner.arguments.filter { $0 == ["clean", "--all", "--json"] }.count == 1)
        #expect(didRefreshProjectTopology)
    }

    @Test func syncActionLeavesSummaryAndClearsProgress() async throws {
        let wt = makeWorktree()
        let state = makeState(worktree: wt)
        let ndjson = [
            #"{"event":"start","total_entries":1}"#,
            #"{"event":"push_done","position":1,"forced":false}"#,
            #"{"event":"summary"}"#,
        ].joined(separator: "\n")
        state.ggService = GGService(runner: NDJSONSyncFakeGGRunner(ndjson: ndjson))
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "s", count: 40), stackShaped: true)]

        // Drive the same body onGGStackAction(.sync) runs, but awaitably:
        // consume the service stream and apply the summary exactly as
        // runGGSync does. If runGGSync is refactored to expose an awaitable
        // core (e.g. `func runGGSyncBody() async`), call that instead —
        // implementer's choice; the assertion is what matters:
        _ = state.ggActionState.beginAction(.sync)
        for try await event in state.ggService.sync(worktreePath: wt.path.path, supportsJSONL: true) {
            state.ggActionState.appendSyncEvent(event)
        }
        if let summary = GGStackActionState.syncSummaryLine(from: state.ggActionState.syncProgress) {
            state.ggActionState.setActionSummary(summary)
            state.ggActionState.clearSyncProgress()
        }
        state.ggActionState.endAction(.sync)

        #expect(state.ggActionState.lastActionSummary == "Synced · 1 pushed")
        #expect(state.ggActionState.syncProgress.isEmpty)
    }

    @Test func postMutationStackRefreshIsCancelledByReplacementRefresh() async {
        let worktree = makeWorktree()
        let runner = PostMutationRefreshCancellationRunner()
        let state = makeState(worktree: worktree)
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
        state.ggStackSourceCommits = [
            commit(sha: String(repeating: "s", count: 40), stackShaped: true),
        ]

        state.onGGStackAction(.sync, appState: AppState(store: MemoryStore()))
        await runner.waitUntilPostSyncReadSuspends()

        await state.reevaluateGGGate().value

        await runner.waitUntilPostSyncReadCancellationIsObserved()
        #expect(await runner.didObservePostSyncReadCancellation())
        #expect(state.ggStack?.name == "replacement-stack")
        #expect(state.ggActionState.inFlightAction == nil)
        #expect(state.ggActionState.lastActionSummary == "Synced")
        #expect(state.ggActionState.syncProgress.isEmpty)

        await runner.releasePostSyncRead()
    }

    @Test func reevaluatingGGGateKeepsCompatibleLoadedStackVisible() async throws {
        let worktree = makeWorktree()
        let result = ProcessResult(
            exitCode: 0,
            stdout: GGStackModelsTests.fixture,
            stderr: ""
        )
        let runner = ControlledStackGGRunner(
            stackResults: [("agent-inbox", result), ("agent-inbox", result)],
            suspendedCalls: [2]
        )
        let state = makeState(worktree: worktree)
        installFakeGGStackLoader(on: state)
        state.ggService = GGService(runner: runner)
        state.ggCapabilities = {
            GGCapabilities(
                structuredSplit: false,
                keepCurrentUnstack: false,
                localStackSnapshot: false
            )
        }
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
        state.ggStackSourceCommits = [
            commit(sha: String(repeating: "s", count: 40), stackShaped: true),
        ]

        await state.refreshGGStack()
        let refresh = state.reevaluateGGGate()
        for _ in 0..<500 where await runner.lsCallCount < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        #expect(await runner.lsCallCount == 2)
        #expect(state.ggStack?.name == "agent-inbox")
        #expect(state.ggStackLoadState == .loaded)

        await runner.complete(call: 2)
        await refresh.value
    }

    @Test func staleMutationFailureDoesNotOverwriteNewerActionState() async throws {
        let worktree = makeWorktree()
        let runner = StaleMutationFailureRunner()
        let state = RightPaneState(worktree: worktree, baseBranch: "main")
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "agent-inbox") }
        state.ggStackSourceCommits = [
            commit(sha: String(repeating: "s", count: 40), stackShaped: true),
        ]

        let mutationA = try #require(state.runGGMutation(.restack))
        await runner.waitUntilFirstRefreshSuspends()

        let mutationB = try #require(state.runGGMutation(.sync))
        await runner.waitUntilSecondSyncSuspends()
        #expect(state.ggActionState.inFlightAction == .sync)
        #expect(state.ggActionState.lastActionSummary == nil)
        #expect(state.ggActionState.syncProgress.isEmpty)
        #expect(state.ggActionState.lastError == nil)

        await runner.finishFirstRefresh()
        await mutationA.value

        #expect(state.ggActionState.inFlightAction == .sync)
        #expect(state.ggActionState.lastActionSummary == nil)
        #expect(state.ggActionState.syncProgress.isEmpty)
        #expect(state.ggActionState.lastError == nil)

        await runner.finishSecondSync()
        await mutationB.value

        #expect(state.ggActionState.lastActionSummary == "Synced")
        #expect(state.ggActionState.syncProgress.isEmpty)
        #expect(state.ggActionState.lastError == nil)
    }

    @Test func repeatedSyncInvocationIsSilentlyIgnoredAtUIBoundary() async throws {
        let wt = makeWorktree()
        let runner = ReentrantSyncFakeGGRunner()
        let state = makeState(worktree: wt)
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "s", count: 40), stackShaped: true)]

        state.onGGStackAction(.sync, appState: AppState(store: MemoryStore()))
        state.onGGStackAction(.sync, appState: AppState(store: MemoryStore()))

        let deadline = Date().addingTimeInterval(2)
        while state.ggActionState.lastActionSummary == nil,
              state.ggActionState.lastError == nil,
              Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        #expect(runner.syncCallCount == 1)
        #expect(state.ggActionState.lastError == nil)
        #expect(state.ggActionState.lastActionSummary == "Synced · 1 pushed")
    }

    @Test func syncErrorSuppressesSuccessSummary() async throws {
        let wt = makeWorktree()
        let state = makeState(worktree: wt)
        let ndjson = [
            #"{"event":"start","total_entries":1}"#,
            #"{"event":"push_done","position":1,"forced":false}"#,
            #"{"event":"error","message":"push rejected"}"#,
            #"{"event":"summary"}"#,
        ].joined(separator: "\n")
        state.ggService = GGService(runner: NDJSONSyncFakeGGRunner(ndjson: ndjson))
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "s", count: 40), stackShaped: true)]

        state.onGGStackAction(.sync, appState: AppState(store: MemoryStore()))
        for _ in 0..<500 where state.ggActionState.lastError == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(state.ggActionState.lastError != nil)
        #expect(state.ggActionState.lastActionSummary == nil)
    }

    @Test func commitMenuSelectionStalenessTracksStackSnapshotSourceKey() {
        let wt = makeWorktree()
        let state = makeState(worktree: wt)
        let source = commit(sha: String(repeating: "a", count: 40), stackShaped: true)
        state.ggStackSourceCommits = [source]
        state.ggStack = GGStack(
            name: "feature",
            base: "main",
            totalCommits: 1,
            syncedCommits: 0,
            currentPosition: 1,
            behindBase: 0,
            entries: [
                GGStackEntry(position: 1, sha: source.sha, title: source.subject, ggId: "change-1")
            ]
        )

        #expect(CommitsSectionView.ggSelectionIsStale(rps: state))

        state.ggStackCommitsKey = state.currentGGStackCommitsKey
        #expect(!CommitsSectionView.ggSelectionIsStale(rps: state))
    }

    @Test func providerReviewResponseSurfacesOnlyErrors() {
        #expect(RightPaneState.ggProviderReviewError(.ok) == nil)
        #expect(RightPaneState.ggProviderReviewError(.text(["opened"])) == nil)
        #expect(RightPaneState.ggProviderReviewError(.error("Review could not be opened")) == "Review could not be opened")
    }
}
