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

/// Always throws, simulating a transient gg/provider failure (e.g. a gh/glab
/// auth hiccup) rather than a real "not a stack" result.
private final class ThrowingFakeGGRunner: GGCommandRunning, @unchecked Sendable {
    private(set) var callCount = 0

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        callCount += 1
        throw GGServiceError.commandFailed(stderr: "boom")
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
struct RightPaneGGStackTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
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

    private func commit(sha: String, stackShaped: Bool) -> CommitInfo {
        CommitInfo(
            sha: sha, shortSha: String(sha.prefix(7)),
            author: "Test", authorInitials: "T", date: Date(),
            subject: "subject",
            body: stackShaped ? "Some detail.\n\nGG-ID: abc123\nGG-Parent: def456" : "Just a plain commit body.",
            conventionalTag: nil,
            filesChanged: 1, insertions: 1, deletions: 0
        )
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        for _ in 0..<500 where !runner.arguments.contains(["rebase", "origin/main"]) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(runner.arguments.contains(["rebase", "origin/main"]))
        #expect(!runner.arguments.contains(["rebase", "main"]))
    }

    @Test func manualRebaseIgnoresBehindRefForADifferentStackBase() async throws {
        let wt = makeWorktree()
        try FileManager.default.createDirectory(
            at: wt.path.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: wt.path) }
        let runner = RecordingLifecycleGGRunner()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        for _ in 0..<500 where !runner.arguments.contains(["rebase", "release"]) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(runner.arguments.contains(["rebase", "release"]))
        #expect(!runner.arguments.contains(["rebase", "origin/main"]))
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

    @Test func prepareFailurePresentsGGServiceUserMessage() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.ggService = GGService(runner: ThrowingFakeGGRunner())
        let entry = try #require(try GGStackSnapshot.decode(
            fromJSON: Data(GGStackModelsTests.fixture.utf8)
        ).stack?.entries.first)

        state.requestGGDrop(entry)
        for _ in 0..<500 where state.ggActionState.lastError == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(state.ggActionState.lastError == "boom")
    }

    @Test func applyPreflightFailurePresentsGGServiceUserMessage() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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

    @Test func ggOwnedPresentationUsesCommitTerminology() {
        let action = GGStackActionState()
        _ = action.beginAction(.sync)
        action.appendSyncEvent(.start(totalEntries: 2))
        let stack = GGStack(
            name: "feature",
            base: "main",
            totalCommits: 2,
            syncedCommits: 0,
            currentPosition: 2,
            behindBase: 0,
            entries: []
        )
        let drawer = GGStackReadinessModel.make(stack: stack, action: action)

        #expect(drawer.facts.first?.label == "Commits")
        #expect(drawer.progressRows.first == "Syncing 2 commits…")
        #expect(GGInboxTabView.commitCountLabel(1) == "1 commit")
        #expect(GGInboxTabView.commitCountLabel(2) == "2 commits")
        #expect(CommitRow.ggCheckoutTitle == "Checkout Commit")
        #expect(GGMutationConfirmation.clean(mergedCommits: 2).message.contains("2 merged commits"))

        let typedStrings = drawer.facts.map(\.label)
            + drawer.progressRows
            + [GGInboxTabView.commitCountLabel(2), CommitRow.ggCheckoutTitle]
            + [GGMutationConfirmation.clean(mergedCommits: 2).message]
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.comparisonMode = .branchUpstream

        await state.refresh()

        #expect(state.commits.isEmpty)
        #expect(!state.ggStackSourceCommits.isEmpty)
        #expect(GGStackGate.isStackShaped(commits: state.ggStackSourceCommits))
    }

    @Test func activeContextLoadsStackWithNoSourceCommits() async {
        let state = RightPaneState(worktree: makeWorktree(), baseBranch: "main")
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

    @Test func nilStackLeavesContextActiveAndPublishesEmpty() async {
        let state = RightPaneState(worktree: makeWorktree(), baseBranch: "main")
        let runner = CountingFakeGGRunner(
            result: ProcessResult(
                exitCode: 0,
                stdout: #"{"version": 1, "current_stack": null, "stacks": []}"#,
                stderr: ""
            )
        )
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }

        await state.refreshGGStack()

        #expect(state.ggContext == .active(stackName: "stack"))
        #expect(state.ggStack == nil)
        #expect(state.ggStackLoadState == .empty)
    }

    @Test func inactiveContextSkipsGGAndClearsPublishedState() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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

    @Test func stackLoadErrorLeavesContextActiveAndPublishesRetryableFailure() async {
        let state = RightPaneState(worktree: makeWorktree(), baseBranch: "main")
        let runner = ThrowingFakeGGRunner()
        state.ggService = GGService(runner: runner)
        state.ggContextProvider = { _ in .active(stackName: "stack") }

        await state.refreshGGStack()

        #expect(runner.callCount == 1)
        #expect(state.ggContext == .active(stackName: "stack"))
        #expect(state.ggStackLoadState == .failed(
            GGServiceError.commandFailed(stderr: "boom").localizedDescription
        ))
        #expect(state.ggStackCommitsKey == nil)
    }

    @Test func gateClosedSkipsCLIAndClearsStack() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "o", count: 40), stackShaped: false)]
        _ = state.ggActionState.beginAction(.sync)

        await state.refreshGGStack()

        #expect(state.ggActionState.pausedOperation != nil)
        state.ggActionState.endAction(.sync)
    }

    @Test func activeContextLoadsStackWithoutStackShapedCommits() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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

    /// `reevaluateGGGate()` must clear stale stack state immediately when the
    /// gate flips closed (e.g. the Settings master toggle goes off), rather
    /// than waiting for the next watcher-driven refresh. `reevaluateGGGate()`
    /// returns its underlying fire-and-forget task so the test can await it
    /// deterministically instead of racing the MainActor scheduler.
    @Test func reevaluateGGGateClearsStackWhenGateClosed() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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

    /// A thrown gg failure must not cache the commits key — otherwise a
    /// transient error (auth hiccup, network blip) permanently skips retries
    /// for that commit set via the unchanged-key guard, even after the
    /// underlying problem clears up.
    @Test func transientFailureDoesNotPoisonCommitsKeyCache() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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

        await staleRefresh.value
        #expect(state.ggStack?.name == "fresh-stack")
    }

    /// A stack loaded for one branch must not keep rendering after the user
    /// switches to a different stack-shaped branch and the reload for it
    /// fails transiently — the stale stack no longer matches `commits`.
    @Test func failedReloadClearsStaleStackFromDifferentBranch() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")

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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: makeWorktree(), baseBranch: "main")
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

    /// `markSnapshotUnknown()` resets `commits` along with the rest of the
    /// snapshot; gg stack state derives from `commits`, so it must be reset
    /// in lockstep or a delayed/failed refresh after invalidation can leave
    /// a stale "Stack · …" header/sidebar badge rendered against an emptied
    /// commit list.
    @Test func markSnapshotUnknownClearsStackState() async throws {
        let wt = makeWorktree()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        #expect(state.ggStackCommitsKey == nil)
        #expect(state.ggStackLoadState == .loading)
        #expect(GGStackSummaryStore.shared.summaries[wt.path.path] == nil)
    }

    @Test func markSnapshotUnknownKeepsInactiveLoadStateInactive() {
        let state = RightPaneState(worktree: makeWorktree(), baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.ggService = GGService(runner: CountingFakeGGRunner(
            result: ProcessResult(exitCode: 0, stdout: GGStackModelsTests.fixture, stderr: "")
        ))
        state.ggContextProvider = { _ in .active(stackName: "stack") }
        state.ggStackSourceCommits = [commit(sha: String(repeating: "r", count: 40), stackShaped: true)]

        await state.refreshGGStack()

        #expect(state.ggActionState.pausedOperation == GGPausedOperation(pausedBy: .sync))
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        for try await event in state.ggService.sync(worktreePath: wt.path.path) {
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

    @Test func repeatedSyncInvocationIsSilentlyIgnoredAtUIBoundary() async throws {
        let wt = makeWorktree()
        let runner = ReentrantSyncFakeGGRunner()
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
        let state = RightPaneState(worktree: wt, baseBranch: "main")
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
