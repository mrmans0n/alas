import Foundation
import Testing
@testable import Alas

private actor LandPreflightSuspension {
    private var suspended = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
        await withCheckedContinuation { completion = $0 }
    }

    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() { completion?.resume(); completion = nil }
}

private final class LiveLandGGRunner: GGCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [[String]] = []
    private var cancellations = 0
    private var targetExists = true
    private var nextPreflight: LandPreflightSuspension?
    private var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []
    var calls: [[String]] { lock.withLock { recordedCalls } }
    var cancellationCount: Int { lock.withLock { cancellations } }

    func removeTarget() { lock.withLock { targetExists = false } }
    func suspendNextPreflight(_ preflight: LandPreflightSuspension) {
        lock.withLock { nextPreflight = preflight }
    }

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        let hasTarget = lock.withLock {
            recordedCalls.append(args)
            return targetExists
        }
        if args.first == "ls" {
            let preflight = lock.withLock {
                defer { nextPreflight = nil }
                return nextPreflight
            }
            await preflight?.suspend()
        }
        let stdout: String
        if args.first == "land" {
            stdout = Self.summaryJSON
        } else if args.first == "undo" {
            stdout = #"{"version":1,"operations":[]}"#
        } else {
            stdout = hasTarget ? Self.stackJSON : Self.stackJSON.replacingOccurrences(of: "change-1", with: "replacement")
        }
        return ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }

    func runStreaming(args: [String], cwd: URL?, timeout: TimeInterval?) -> AsyncThrowingStream<String, Error> {
        lock.withLock { recordedCalls.append(args) }
        return AsyncThrowingStream { continuation in
            lock.withLock { continuations.append(continuation) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.cancellations += 1 }
            }
            continuation.yield(#"{"version":1,"command":"land","status":"ok","event":"start","stack":"feat","base":"main","total_entries":1}"#)
        }
    }

    static let stackJSON = #"{"version":1,"stack":{"name":"feat","base":"main","total_commits":1,"synced_commits":1,"current_position":1,"entries":[{"position":1,"sha":"s","title":"t","gg_id":"change-1","pr_number":5,"pr_state":"open","approved":true,"ci_status":"success"}]}}"#
    static let summaryJSON = #"{"version":1,"command":"land","status":"ok","event":"summary","stack":"feat","base":"main","landed":[],"remaining":1,"cleaned":false,"warnings":[],"error":null}"#
}

private final class FreshUnstackGGRunner: GGCommandRunning, @unchecked Sendable {
    private(set) var calls: [[String]] = []
    private let stackResponses: [String]
    private let unstackError: String?

    init(
        stackResponses: [String] = [FreshUnstackGGRunner.freshStackJSON],
        unstackError: String? = nil
    ) {
        self.stackResponses = stackResponses
        self.unstackError = unstackError
    }

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        calls.append(args)
        if args.first == "undo" {
            return ProcessResult(
                exitCode: 0,
                stdout: #"{"version":1,"operations":[]}"#,
                stderr: ""
            )
        }
        if args.first == "unstack", let unstackError {
            return ProcessResult(exitCode: 1, stdout: "", stderr: unstackError)
        }
        let index = min(calls.filter { $0 == ["ls", "--json"] }.count - 1, stackResponses.count - 1)
        return ProcessResult(exitCode: 0, stdout: stackResponses[max(0, index)], stderr: "")
    }

    static let freshStackJSON = #"""
    {
      "version": 1,
      "stack": {
        "name": "fresh-lower",
        "base": "main",
        "total_commits": 5,
        "synced_commits": 0,
        "current_position": 5,
        "behind_base": 0,
        "entries": [
          {"position":1,"sha":"s1","title":"One","gg_id":"change-1","approved":false,"is_current":false},
          {"position":2,"sha":"s2","title":"Two","gg_id":"change-2","approved":false,"is_current":false},
          {"position":3,"sha":"s3","title":"Fresh target","gg_id":"change-3","approved":false,"is_current":false},
          {"position":4,"sha":"s4","title":"Four","gg_id":"change-4","approved":false,"is_current":false},
          {"position":5,"sha":"s5","title":"Five","gg_id":"change-5","approved":false,"is_current":true}
        ]
      }
    }
    """#

    static let changedStackJSON = #"""
    {
      "version": 1,
      "stack": {
        "name": "fresh-lower",
        "base": "main",
        "total_commits": 4,
        "synced_commits": 0,
        "current_position": 4,
        "behind_base": 0,
        "entries": [
          {"position":1,"sha":"s1","title":"One","gg_id":"change-1","approved":false,"is_current":false},
          {"position":2,"sha":"s2","title":"Two","gg_id":"change-2","approved":false,"is_current":false},
          {"position":3,"sha":"s3","title":"Fresh target","gg_id":"change-3","approved":false,"is_current":false},
          {"position":4,"sha":"s4","title":"Four","gg_id":"change-4","approved":false,"is_current":true}
        ]
      }
    }
    """#
}

@MainActor
struct RightPaneGGLandTests {
    private func landingState(
        store: GGLandingStore,
        runner: LiveLandGGRunner,
        supported: Bool,
        worktreeId: String = "live-wt",
        projectId: String = "live-project"
    ) -> RightPaneState {
        let worktree = Worktree(
            id: worktreeId, projectId: projectId, name: "feat", branch: "feat",
            path: URL(fileURLWithPath: "/tmp/alas-land-tests-\(UUID().uuidString)"),
            status: .clean, lastActivity: Date()
        )
        let state = RightPaneState(worktree: worktree, baseBranch: "main", ggLandingStore: store)
        state.ggCapabilities = { GGCapabilities(structuredSplit: false, keepCurrentUnstack: false, landJSONL: supported) }
        state.ggService = GGService(runner: runner)
        state.ggStack = stack([entry(id: "change-1", prState: .open, approved: true, ci: .success)])
        return state
    }

    private func waitForLand(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw GGServiceError.commandFailed(stderr: "Timed out waiting for landing")
    }

    @Test func liveLandingBeginsBeforeExecutionAndCancelsRawOperation() async throws {
        let store = GGLandingStore()
        let runner = LiveLandGGRunner()
        let state = landingState(store: store, runner: runner, supported: true)
        state.requestGGLand(.ready)
        try await waitForLand { state.pendingGGLand != nil }
        #expect(store.sessions.isEmpty)
        state.performGGLand(appState: AppState(store: MemoryStore()))
        #expect(store.sessions["live-project"]?.phase == .running)
        #expect(store.sessions["live-project"]?.target == "change-1")
        #expect(!runner.calls.contains { $0.first == "land" })
        try await waitForLand { runner.calls.contains { $0.first == "land" } }
        #expect(runner.calls.contains(["land", "--until", "change-1", "--wait", "--jsonl", "--no-clean"]))
        store.cancel(projectId: "live-project")
        await store.waitForOperation(projectId: "live-project")
        #expect(runner.cancellationCount == 1)
        #expect(store.sessions["live-project"]?.phase == .cancelled)
        #expect(state.ggActionState.lastError == nil)
    }

    @Test func shutdownDuringRestartPreflightNeverLaunchesLand() async throws {
        let store = GGLandingStore()
        let runner = LiveLandGGRunner()
        let state = landingState(store: store, runner: runner, supported: true)
        store.begin(.init(
            projectId: "live-project", worktreeId: "live-wt", stack: "feat", base: "main",
            target: "change-1", rows: [.init(position: 1, title: "t", ggId: "change-1", prNumber: 5)]
        ))
        store.fail(projectId: "live-project", message: "Previous attempt failed")
        let preflight = LandPreflightSuspension()
        runner.suspendNextPreflight(preflight)
        state.restartGGLand(target: "change-1")
        await preflight.waitUntilSuspended()
        let started = AsyncStream<Void>.makeStream()
        var shutdownFinished = false
        let shutdown = Task {
            started.continuation.yield(())
            await store.cancelAllAndWait()
            shutdownFinished = true
        }
        for await _ in started.stream { break }
        #expect(!shutdownFinished)
        #expect(store.sessions["live-project"]?.phase == .cancelling)
        await preflight.release()
        await shutdown.value
        #expect(!runner.calls.contains { $0.first == "land" })
        #expect(store.sessions["live-project"]?.phase == .cancelled)
        #expect(state.ggActionState.lastError == nil)
    }

    @Test func oldGGLandingUsesAtomicCommandWithoutSession() async throws {
        let store = GGLandingStore()
        let runner = LiveLandGGRunner()
        let state = landingState(store: store, runner: runner, supported: false)
        state.requestGGLand(.ready)
        try await waitForLand { state.pendingGGLand != nil }
        state.performGGLand(appState: AppState(store: MemoryStore()))
        try await waitForLand { runner.calls.contains { $0.first == "land" } }
        #expect(runner.calls.contains(["land", "--until", "change-1", "--json", "--no-clean"]))
        #expect(store.sessions.isEmpty)
        try await waitForLand { state.ggActionState.inFlightAction == nil }
    }

    @Test func duplicateProjectLandingDoesNotLaunchAnotherMutation() async throws {
        let store = GGLandingStore()
        let firstRunner = LiveLandGGRunner()
        let secondRunner = LiveLandGGRunner()
        let first = landingState(store: store, runner: firstRunner, supported: true)
        let second = landingState(store: store, runner: secondRunner, supported: true, worktreeId: "other-wt")
        first.requestGGLand(.ready)
        second.requestGGLand(.ready)
        try await waitForLand { first.pendingGGLand != nil && second.pendingGGLand != nil }
        let app = AppState(store: MemoryStore())
        first.performGGLand(appState: app)
        let sessionId = store.sessions["live-project"]?.id
        second.performGGLand(appState: app)
        #expect(store.sessions["live-project"]?.id == sessionId)
        #expect(!secondRunner.calls.contains { $0.first == "land" })
        await store.cancelAllAndWait()
    }

    @Test func restartRepreflightsStableTargetWithoutAnotherConfirmation() async throws {
        let store = GGLandingStore()
        let runner = LiveLandGGRunner()
        let state = landingState(store: store, runner: runner, supported: true)
        state.requestGGLand(.ready)
        try await waitForLand { state.pendingGGLand != nil }
        state.performGGLand(appState: AppState(store: MemoryStore()))
        try await waitForLand { runner.calls.contains { $0.first == "land" } }
        await store.cancelAllAndWait()
        let oldSessionId = store.sessions["live-project"]?.id
        state.restartGGLand(target: "change-1")
        try await waitForLand { runner.calls.filter { $0.first == "land" }.count == 2 }
        #expect(store.sessions["live-project"]?.id != oldSessionId)
        #expect(state.pendingGGLand == nil)
        #expect(runner.calls.filter { $0.first == "land" }.allSatisfy { $0.contains("change-1") })
        await store.cancelAllAndWait()
        runner.removeTarget()
        state.restartGGLand(target: "change-1")
        try await waitForLand { store.sessions["live-project"]?.phase == .failed }
        #expect(runner.calls.filter { $0.first == "land" }.count == 2)
        #expect(store.sessions["live-project"]?.error != nil)
    }

    private func entry(id: String, prState: GGPRState, approved: Bool, ci: GGCIStatus?) -> GGStackEntry {
        GGStackEntry(position: 1, sha: "s", title: "t", ggId: id, prNumber: 5,
                     prState: prState, approved: approved, ciStatus: ci)
    }

    private func entry(
        id: String,
        position: Int,
        prState: GGPRState,
        approved: Bool,
        ci: GGCIStatus?
    ) -> GGStackEntry {
        GGStackEntry(position: position, sha: "s\(position)", title: "t\(position)", ggId: id, prNumber: 5 + position,
                     prState: prState, approved: approved, ciStatus: ci)
    }

    private func stack(_ entries: [GGStackEntry]) -> GGStack {
        GGStack(name: "feat", base: "main", totalCommits: entries.count, syncedCommits: entries.count,
                currentPosition: nil, behindBase: nil, entries: entries)
    }

    private func waitForUnstackPresentation(_ state: RightPaneState) async throws {
        for _ in 0..<100 {
            if state.pendingGGUnstack != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for Unstack preparation")
    }

    @Test func readyLandableWhenAnyEntryOpenApprovedGreen() {
        let wt = Worktree(id: "i", projectId: "p", name: "f", branch: "f",
                          path: URL(fileURLWithPath: "/tmp/x"), status: .clean, lastActivity: Date())
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        let landable = stack([entry(id: "a", prState: .open, approved: true, ci: .success)])
        #expect(state.ggLandTargetStillLandable(.ready, in: landable))
        let landableWithoutCI = stack([entry(id: "a", prState: .open, approved: true, ci: nil)])
        #expect(state.ggLandTargetStillLandable(.ready, in: landableWithoutCI))
        let failingCI = stack([entry(id: "a", prState: .open, approved: true, ci: .failed)])
        #expect(!state.ggLandTargetStillLandable(.ready, in: failingCI))
        let notLandable = stack([entry(id: "a", prState: .open, approved: false, ci: .success)])
        #expect(!state.ggLandTargetStillLandable(.ready, in: notLandable))
    }

    @Test func readyRequiresContiguousBottomPrefix() {
        let wt = Worktree(id: "i", projectId: "p", name: "f", branch: "f",
                          path: URL(fileURLWithPath: "/tmp/x"), status: .clean, lastActivity: Date())
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        func positionedEntry(
            id: String,
            position: Int,
            prState: GGPRState,
            approved: Bool,
            ci: GGCIStatus?
        ) -> GGStackEntry {
            GGStackEntry(position: position, sha: "s\(position)", title: "t\(position)", ggId: id, prNumber: 5 + position,
                         prState: prState, approved: approved, ciStatus: ci)
        }

        let blockedBottom = stack([
            positionedEntry(id: "a", position: 1, prState: .open, approved: false, ci: .success),
            positionedEntry(id: "b", position: 2, prState: .open, approved: true, ci: .success),
        ])
        #expect(!state.ggLandTargetStillLandable(.ready, in: blockedBottom))

        let readyAfterMergedBottom = stack([
            positionedEntry(id: "a", position: 1, prState: .merged, approved: false, ci: .failed),
            positionedEntry(id: "b", position: 2, prState: .open, approved: true, ci: .success),
        ])
        #expect(state.ggLandTargetStillLandable(.ready, in: readyAfterMergedBottom))
        #expect(RightPaneState.ggLandReadyPrefix(in: readyAfterMergedBottom).map(\.id) == ["b"])
    }

    @Test func readyConfirmationCountsContiguousBottomPrefixOnly() {
        let message = RightPaneState.ggLandConfirmationMessage(
            for: .ready,
            stack: stack([
                GGStackEntry(position: 1, sha: "s1", title: "t1", ggId: "a", prNumber: 6,
                             prState: .open, approved: true, ciStatus: .success),
                GGStackEntry(position: 2, sha: "s2", title: "t2", ggId: "b", prNumber: 7,
                             prState: .open, approved: false, ciStatus: .success),
                GGStackEntry(position: 3, sha: "s3", title: "t3", ggId: "c", prNumber: 8,
                             prState: .open, approved: true, ciStatus: .success),
            ])
        )

        #expect(message == "Merge 1 approved, passing PR from the bottom of the stack.")
    }

    @Test func readyConfirmationCountsApprovedOpenEntriesWithNoCI() {
        let message = RightPaneState.ggLandConfirmationMessage(
            for: .ready,
            stack: stack([
                entry(id: "a", position: 1, prState: .open, approved: true, ci: .success),
                entry(id: "b", position: 2, prState: .open, approved: true, ci: nil),
                entry(id: "c", position: 3, prState: .open, approved: true, ci: .pending),
            ])
        )

        #expect(message == "Merge 2 approved, passing PRs from the bottom of the stack.")
    }

    @Test func readyLandUsesLastVerifiedPrefixEntryAsUntilTarget() {
        let s = stack([
            entry(id: "a", position: 1, prState: .open, approved: true, ci: .success),
            entry(id: "b", position: 2, prState: .open, approved: true, ci: nil),
            entry(id: "c", position: 3, prState: .open, approved: false, ci: .success),
        ])

        #expect(RightPaneState.ggLandUntilTarget(for: .ready, in: s) == "b")
    }

    @Test func untilLandUsesRequestedEntryAsUntilTarget() {
        let s = stack([
            entry(id: "a", position: 1, prState: .open, approved: true, ci: .success),
            entry(id: "b", position: 2, prState: .open, approved: true, ci: .success),
        ])

        #expect(RightPaneState.ggLandUntilTarget(for: .until(entryId: "b", title: "t2"), in: s) == "b")
    }

    @Test func landStackFingerprintTracksConfirmedStackIdentity() {
        let original = stack([
            GGStackEntry(position: 1, sha: "s1", title: "t1", ggId: "a", prNumber: 6,
                         prState: .open, approved: true, ciStatus: .success),
            GGStackEntry(position: 2, sha: "s2", title: "t2", ggId: "b", prNumber: 7,
                         prState: .open, approved: true, ciStatus: .success),
        ])
        let rebased = stack([
            GGStackEntry(position: 1, sha: "s1-rebased", title: "t1", ggId: "a", prNumber: 6,
                         prState: .open, approved: true, ciStatus: .success),
            GGStackEntry(position: 2, sha: "s2", title: "t2", ggId: "b", prNumber: 7,
                         prState: .open, approved: true, ciStatus: .success),
        ])
        let fingerprint = RightPaneState.ggLandStackFingerprint(original)

        #expect(RightPaneState.ggLandStackMatchesPendingConfirmation(original, fingerprint: fingerprint))
        #expect(!RightPaneState.ggLandStackMatchesPendingConfirmation(rebased, fingerprint: fingerprint))
        #expect(!RightPaneState.ggLandStackMatchesPendingConfirmation(original, fingerprint: nil))
    }

    @Test func untilLandableWhenTargetEntryPresent() {
        let wt = Worktree(id: "i", projectId: "p", name: "f", branch: "f",
                          path: URL(fileURLWithPath: "/tmp/x"), status: .clean, lastActivity: Date())
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        let s = stack([entry(id: "a", prState: .open, approved: true, ci: .success)])
        #expect(state.ggLandTargetStillLandable(.until(entryId: "a", title: "t"), in: s))
        #expect(!state.ggLandTargetStillLandable(.until(entryId: "missing", title: "t"), in: s))
    }

    @Test func untilRequiresReadyTargetEntry() {
        let wt = Worktree(id: "i", projectId: "p", name: "f", branch: "f",
                          path: URL(fileURLWithPath: "/tmp/x"), status: .clean, lastActivity: Date())
        let state = RightPaneState(worktree: wt, baseBranch: "main")

        #expect(!state.ggLandTargetStillLandable(
            .until(entryId: "a", title: "t"),
            in: stack([entry(id: "a", prState: .open, approved: false, ci: .success)])
        ))
        #expect(!state.ggLandTargetStillLandable(
            .until(entryId: "a", title: "t"),
            in: stack([entry(id: "a", prState: .draft, approved: true, ci: .success)])
        ))
        #expect(!state.ggLandTargetStillLandable(
            .until(entryId: "a", title: "t"),
            in: stack([entry(id: "a", prState: .open, approved: true, ci: .failed)])
        ))
        #expect(state.ggLandTargetStillLandable(
            .until(entryId: "a", title: "t"),
            in: stack([entry(id: "a", prState: .open, approved: true, ci: nil)])
        ))
    }

    @Test func untilRequiresReadyLowerEntries() {
        let wt = Worktree(id: "i", projectId: "p", name: "f", branch: "f",
                          path: URL(fileURLWithPath: "/tmp/x"), status: .clean, lastActivity: Date())
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        func positionedEntry(
            id: String,
            position: Int,
            prState: GGPRState,
            approved: Bool,
            ci: GGCIStatus?
        ) -> GGStackEntry {
            GGStackEntry(position: position, sha: "s\(position)", title: "t\(position)", ggId: id, prNumber: 5 + position,
                         prState: prState, approved: approved, ciStatus: ci)
        }

        #expect(state.ggLandTargetStillLandable(
            .until(entryId: "b", title: "t2"),
            in: stack([
                positionedEntry(id: "a", position: 1, prState: .open, approved: true, ci: .success),
                positionedEntry(id: "b", position: 2, prState: .open, approved: true, ci: .success),
            ])
        ))
        #expect(state.ggLandTargetStillLandable(
            .until(entryId: "b", title: "t2"),
            in: stack([
                positionedEntry(id: "a", position: 1, prState: .merged, approved: false, ci: .failed),
                positionedEntry(id: "b", position: 2, prState: .open, approved: true, ci: .success),
            ])
        ))
        #expect(!state.ggLandTargetStillLandable(
            .until(entryId: "b", title: "t2"),
            in: stack([
                positionedEntry(id: "a", position: 1, prState: .open, approved: false, ci: .success),
                positionedEntry(id: "b", position: 2, prState: .open, approved: true, ci: .success),
            ])
        ))
    }

    @Test func requestWithoutCachedStackDoesNotStageLandConfirmation() {
        let wt = Worktree(id: "i", projectId: "p", name: "f", branch: "f",
                          path: URL(fileURLWithPath: "/tmp/x"), status: .clean, lastActivity: Date())
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.requestGGLand(.ready)
        #expect(state.pendingGGLand == nil)
        #expect(state.ggActionState.lastError == "This stack is no longer ready to land.")
    }

    @Test func cleanPreflightFailureDoesNotStageConfirmation() async throws {
        let wt = Worktree(id: "i", projectId: "p", name: "f", branch: "f",
                          path: URL(fileURLWithPath: "/tmp/x"), status: .clean, lastActivity: Date())
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.requestGGCleanAll()
        for _ in 0..<100 where state.ggActionState.lastError == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!state.pendingGGCleanAll)
        #expect(state.ggActionState.lastError != nil)
    }

    @Test func dropConfirmationNamesCommitDescendantsAndOpenReviewWarning() {
        let confirmation = GGMutationConfirmation.drop(
            target: "change-2",
            rewrittenDescendants: 2,
            hasOpenReview: true
        )

        #expect(confirmation.message == "Drop change-2 and rewrite 2 descendant commits. The selected commit has an open review.")
    }

    @Test func unstackConfirmationNamesTargetStacksAndExactMovedCount() {
        let confirmation = GGMutationConfirmation.unstack(
            target: "change-3",
            targetTitle: "Add OAuth callbacks",
            movedCommits: 3,
            lowerStack: "feature",
            newStack: "oauth-callbacks"
        )

        #expect(confirmation.message == "Split at \u{201C}Add OAuth callbacks\u{201D}. Move 3 commits from feature to oauth-callbacks.")
    }

    @Test func dropPresentationNamesCommitAndProviderWarning() {
        let presentation = GGDropPresentation(
            target: "change-2",
            title: "Add OAuth callbacks",
            rewrittenDescendants: 2,
            openReviewLabel: "PR"
        )

        #expect(presentation.message == "Drop \u{201C}Add OAuth callbacks\u{201D}. GG will rewrite and retain 2 descendant commits. The selected commit has an open PR.")
    }

    @Test func unstackPreparesFreshConfirmationBeforePresenting() async throws {
        let target = GGStackEntry(
            position: 2,
            sha: "cached",
            title: "Cached target",
            ggId: "change-3"
        )
        let wt = Worktree(
            id: "i",
            projectId: "p",
            name: "f",
            branch: "f",
            path: URL(fileURLWithPath: "/tmp/x"),
            status: .clean,
            lastActivity: Date()
        )
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.ggStack = GGStack(
            name: "cached-lower",
            base: "main",
            totalCommits: 2,
            syncedCommits: 0,
            currentPosition: 2,
            behindBase: 0,
            entries: [
                GGStackEntry(position: 1, sha: "cached-1", title: "Cached one", ggId: "change-1"),
                target,
            ]
        )
        let runner = FreshUnstackGGRunner()
        state.ggService = GGService(runner: runner)

        state.requestGGUnstack(target)
        try await waitForUnstackPresentation(state)

        #expect(runner.calls == [["ls", "--json"]])
        #expect(state.pendingGGUnstack?.targetTitle == "Fresh target")
        #expect(state.pendingGGUnstack?.lowerStackName == "fresh-lower")
        #expect(state.pendingGGUnstack?.movedCommitCount == 3)
        #expect(state.pendingGGUnstackPrepared?.snapshot.stackName == "fresh-lower")
    }

    @Test func editedUnstackNameRepreparesAndRequiresFreshConfirmation() async throws {
        let target = GGStackEntry(position: 3, sha: "s3", title: "Fresh target", ggId: "change-3")
        let wt = Worktree(
            id: "i",
            projectId: "p",
            name: "f",
            branch: "f",
            path: URL(fileURLWithPath: "/tmp/x"),
            status: .clean,
            lastActivity: Date()
        )
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.ggStack = stack([target])
        let runner = FreshUnstackGGRunner()
        state.ggService = GGService(runner: runner)
        state.requestGGUnstack(target)
        try await waitForUnstackPresentation(state)
        var edited = try #require(state.pendingGGUnstack)
        edited.setStackName("edited destination")

        let result = try await state.submitGGUnstack(edited)

        guard case .reconfirm(let reconfirmed) = result else {
            Issue.record("Edited request should require a fresh confirmation")
            return
        }
        #expect(runner.calls == [["ls", "--json"], ["ls", "--json"]])
        #expect(reconfirmed.confirmedStackName == "edited-destination")
        #expect(state.pendingGGUnstack?.stackName == "edited-destination")
        #expect(state.pendingGGUnstack?.confirmedStackName == "edited-destination")
        #expect(state.pendingGGUnstack != nil)
    }

    @Test func unchangedUnstackRequestReconfirmsWhenFreshFactsChange() async throws {
        let target = GGStackEntry(position: 3, sha: "s3", title: "Fresh target", ggId: "change-3")
        let wt = Worktree(
            id: "i",
            projectId: "p",
            name: "f",
            branch: "f",
            path: URL(fileURLWithPath: "/tmp/x"),
            status: .clean,
            lastActivity: Date()
        )
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.ggStack = stack([target])
        let runner = FreshUnstackGGRunner(stackResponses: [
            FreshUnstackGGRunner.freshStackJSON,
            FreshUnstackGGRunner.changedStackJSON,
        ])
        state.ggService = GGService(runner: runner)
        state.requestGGUnstack(target)
        try await waitForUnstackPresentation(state)
        let confirmed = try #require(state.pendingGGUnstack)
        #expect(confirmed.movedCommitCount == 3)

        let result = try await state.submitGGUnstack(confirmed)

        guard case .reconfirm(let fresh) = result else {
            Issue.record("Changed moved count should require a fresh confirmation")
            return
        }
        #expect(fresh.movedCommitCount == 2)
        #expect(runner.calls == [["ls", "--json"], ["ls", "--json"]])
    }

    @Test func unchangedUnstackRequestReconfirmsWhenOnlyTheSnapshotChanges() async throws {
        let target = GGStackEntry(position: 3, sha: "s3", title: "Fresh target", ggId: "change-3")
        let wt = Worktree(
            id: "i", projectId: "p", name: "f", branch: "f",
            path: URL(fileURLWithPath: "/tmp/x"), status: .clean, lastActivity: Date()
        )
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.ggStack = stack([target])
        let rewrittenHead = FreshUnstackGGRunner.freshStackJSON.replacingOccurrences(
            of: #""sha":"s5""#,
            with: #""sha":"rewritten-s5""#
        )
        let runner = FreshUnstackGGRunner(stackResponses: [
            FreshUnstackGGRunner.freshStackJSON,
            rewrittenHead,
        ])
        state.ggService = GGService(runner: runner)
        state.requestGGUnstack(target)
        try await waitForUnstackPresentation(state)
        let confirmed = try #require(state.pendingGGUnstack)

        let result = try await state.submitGGUnstack(confirmed)

        guard case .reconfirm = result else {
            Issue.record("A rewritten stack must require fresh unstack confirmation")
            return
        }
        #expect(runner.calls == [["ls", "--json"], ["ls", "--json"]])
    }

    @Test func contextualUnstackExecutionErrorKeepsPreparedSheetOpen() async throws {
        let target = GGStackEntry(position: 3, sha: "s3", title: "Fresh target", ggId: "change-3")
        let wt = Worktree(
            id: "i",
            projectId: "p",
            name: "f",
            branch: "f",
            path: URL(fileURLWithPath: "/tmp/x"),
            status: .clean,
            lastActivity: Date()
        )
        let state = RightPaneState(worktree: wt, baseBranch: "main")
        state.ggStack = stack([target])
        let runner = FreshUnstackGGRunner(
            unstackError: "Stack 'fresh-target' already exists."
        )
        state.ggService = GGService(runner: runner)
        state.requestGGUnstack(target)
        try await waitForUnstackPresentation(state)
        let confirmed = try #require(state.pendingGGUnstack)
        let prepared = try #require(state.pendingGGUnstackPrepared)

        await #expect(throws: GGServiceError.self) {
            try await state.submitGGUnstack(confirmed)
        }

        #expect(state.pendingGGUnstack == confirmed)
        #expect(state.pendingGGUnstackPrepared?.request == prepared.request)
        #expect(state.pendingGGUnstackPrepared?.snapshot == prepared.snapshot)
        #expect(state.ggActionState.lastError == "Stack 'fresh-target' already exists.")
        #expect(runner.calls.contains { $0.first == "unstack" })
    }
}
