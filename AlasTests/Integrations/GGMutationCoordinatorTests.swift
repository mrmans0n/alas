import Foundation
import Testing
@testable import Alas

private enum GGMutationTestTimeout: Error {
    case timedOut
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw GGMutationTestTimeout.timedOut }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

@MainActor
private final class RecordingGGMutationExecutor: GGMutationExecuting {
    var requests: [GGMutationRequest] = []
    var result: GGMutationExecutionResult = .none
    var error: Error?
    var newestOperation: GGOperationSummary?
    var operationLists: [[GGOperationSummary]] = []
    var operationListCallCount = 0
    var blockExecution = false
    var syncEvents: [GGSyncEvent] = [.start(totalEntries: 1), .summary]
    private var executionContinuation: CheckedContinuation<Void, Never>?

    func execute(
        _ request: GGMutationRequest,
        worktreePath: String,
        onSyncEvent: (GGSyncEvent) -> Void
    ) async throws -> GGMutationExecutionResult {
        requests.append(request)
        if request == .sync {
            for event in syncEvents { onSyncEvent(event) }
        }
        if blockExecution {
            await withCheckedContinuation { executionContinuation = $0 }
        }
        if let error { throw error }
        return result
    }

    func listUndoOperations(worktreePath: String, limit: Int) async throws -> [GGOperationSummary] {
        defer { operationListCallCount += 1 }
        if !operationLists.isEmpty {
            return operationLists[min(operationListCallCount, operationLists.count - 1)]
        }
        return newestOperation.map { [$0] } ?? []
    }

    func resumeExecution() {
        executionContinuation?.resume()
        executionContinuation = nil
    }
}

private final class RecordingUndoMarkerStore: GGUndoMarkerStoring, @unchecked Sendable {
    private let lock = NSLock()
    var values: [String: GGUndoMarker] = [:]

    func marker(worktreeId: String) -> GGUndoMarker? {
        lock.lock()
        defer { lock.unlock() }
        return values[worktreeId]
    }

    func set(_ marker: GGUndoMarker, worktreeId: String) {
        lock.lock()
        defer { lock.unlock() }
        values[worktreeId] = marker
    }

    func clear(worktreeId: String) {
        lock.lock()
        defer { lock.unlock() }
        values[worktreeId] = nil
    }

    func operationID(worktreeId: String) -> String? {
        marker(worktreeId: worktreeId)?.operationID
    }
}

@MainActor
private final class GGMutationHarness {
    enum Refresh: Equatable {
        case stack, gitChanges, providerReviews, topology, worktreeExistenceCheck, inbox
    }

    let service = RecordingGGMutationExecutor()
    let markers = RecordingUndoMarkerStore()
    let actionState = GGStackActionState()
    var stacks: [GGStackSnapshot]
    var loadError: Error?
    var loadCount = 0
    var refreshes: [Refresh] = []
    var selectedPaths: [String] = []
    var worktreeExists = true
    var onRefreshStack: (() async -> Void)?
    private(set) var coordinator: GGMutationCoordinator!

    init(stacks: [GGStackSnapshot]) {
        self.stacks = stacks
        coordinator = GGMutationCoordinator(
            worktreeId: "wt",
            worktreePath: "/repo/wt",
            service: service,
            actionState: actionState,
            undoMarkerStore: markers,
            context: GGMutationContext(
                loadFreshStack: { [unowned self] in
                    if let loadError { throw loadError }
                    defer { loadCount += 1 }
                    return stacks[min(loadCount, stacks.count - 1)]
                },
                refreshStack: { [unowned self] in
                    refreshes.append(.stack)
                    await onRefreshStack?()
                },
                refreshGitChanges: { [unowned self] in refreshes.append(.gitChanges) },
                refreshProviderReviews: { [unowned self] in refreshes.append(.providerReviews) },
                refreshProjectTopology: { [unowned self] in refreshes.append(.topology) },
                worktreeExists: { [unowned self] in
                    refreshes.append(.worktreeExistenceCheck)
                    return worktreeExists
                },
                invalidateInbox: { [unowned self] in refreshes.append(.inbox) },
                selectWorktreeAtPath: { [unowned self] path in selectedPaths.append(path) }
            )
        )
    }
}

@MainActor
private func stack(
    head: String,
    base: String = "main",
    operationID: String? = nil,
    entries: [GGStackEntry]? = nil
) -> GGStackSnapshot {
    let entries = entries ?? [
        GGStackEntry(position: 1, sha: "base", title: "Base", ggId: "change-1"),
        GGStackEntry(position: 2, sha: head, title: "Head", ggId: "change-2", isCurrent: true),
    ]
    return GGStackSnapshot(
        version: 1,
        stack: GGStack(
            name: "feature",
            base: base,
            totalCommits: entries.count,
            syncedCommits: 0,
            currentPosition: entries.last?.position,
            behindBase: 0,
            entries: entries
        ),
        operationID: operationID
    )
}

@MainActor
struct GGMutationCoordinatorTests {
    @Test func prepareLoadsFreshStackAndReturnsTypedDropConfirmation() async throws {
        let entries = [
            GGStackEntry(position: 1, sha: "a", title: "Drop", ggId: "change-1", prState: .open),
            GGStackEntry(position: 2, sha: "b", title: "Child", ggId: "change-2"),
            GGStackEntry(position: 3, sha: "c", title: "Head", ggId: "change-3", isCurrent: true),
        ]
        let harness = GGMutationHarness(stacks: [stack(head: "c", entries: entries)])

        let prepared = try await harness.coordinator.prepare(.drop(target: "change-1"))

        #expect(harness.loadCount == 1)
        #expect(prepared.snapshot == GGStackIdentity(
            stackName: "feature",
            base: "main",
            headSHA: "c",
            operationID: nil
        ))
        #expect(prepared.confirmation == .drop(target: "change-1", rewrittenDescendants: 2, hasOpenReview: true))
        #expect(harness.service.requests.isEmpty)
    }

    @Test func applyRechecksSnapshotAfterConfirmation() async throws {
        let harness = GGMutationHarness(stacks: [stack(head: "a"), stack(head: "b")])
        let prepared = try await harness.coordinator.prepare(.drop(target: "change-2"))

        await #expect(throws: GGMutationError.staleConfirmation) {
            try await harness.coordinator.apply(.drop(target: "change-2"), confirmedAgainst: prepared.snapshot)
        }

        #expect(harness.loadCount == 2)
        #expect(harness.service.requests.isEmpty)
        #expect(harness.refreshes.isEmpty)
    }

    @Test func applyRejectsConfirmationWhenOnlyTheStackBaseChanges() async throws {
        let harness = GGMutationHarness(stacks: [
            stack(head: "a", base: "main"),
            stack(head: "a", base: "release"),
        ])
        let prepared = try await harness.coordinator.prepare(.drop(target: "change-2"))

        await #expect(throws: GGMutationError.staleConfirmation) {
            try await harness.coordinator.apply(
                .drop(target: "change-2"),
                confirmedAgainst: prepared.snapshot
            )
        }

        #expect(harness.loadCount == 2)
        #expect(harness.service.requests.isEmpty)
    }

    @Test func missingTargetIsRejectedBeforeProcessLaunch() async {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])

        await #expect(throws: GGMutationError.staleConfirmation) {
            try await harness.coordinator.apply(.drop(target: "missing"), confirmedAgainst: nil)
        }

        #expect(harness.service.requests.isEmpty)
        #expect(harness.refreshes.isEmpty)
    }

    @Test func applyRechecksLandReadinessWhenProviderStateChanges() async throws {
        let ready = [
            GGStackEntry(
                position: 1, sha: "a", title: "Ready", ggId: "change-1",
                prNumber: 7, prState: .open, approved: true, ciStatus: .success,
                isCurrent: true
            ),
        ]
        let blocked = [
            GGStackEntry(
                position: 1, sha: "a", title: "Blocked", ggId: "change-1",
                prNumber: 7, prState: .open, approved: false, ciStatus: .success,
                isCurrent: true
            ),
        ]
        let harness = GGMutationHarness(stacks: [
            stack(head: "a", entries: ready),
            stack(head: "a", entries: blocked),
        ])
        let prepared = try await harness.coordinator.prepare(.land(target: "change-1"))

        await #expect(throws: GGMutationError.staleConfirmation) {
            try await harness.coordinator.apply(.land(target: "change-1"), confirmedAgainst: prepared.snapshot)
        }

        #expect(harness.service.requests.isEmpty)
        #expect(harness.refreshes.isEmpty)
    }

    @Test func secondConcurrentRequestIsRefusedInsteadOfQueued() async throws {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.service.blockExecution = true
        let first = Task { try await harness.coordinator.apply(.checkout(target: "change-1"), confirmedAgainst: nil) }
        try await waitUntil { !harness.service.requests.isEmpty }

        await #expect(throws: GGMutationError.operationInFlight) {
            try await harness.coordinator.apply(.checkout(target: "change-2"), confirmedAgainst: nil)
        }
        #expect(harness.service.requests == [.checkout(target: "change-1")])

        harness.service.resumeExecution()
        try await first.value
    }

    @Test func immutableTargetIsRejectedBeforeProcessLaunch() async {
        let entries = [
            GGStackEntry(
                position: 1, sha: "a", title: "Merged", ggId: "change-1",
                prNumber: 7, prState: .merged
            ),
            GGStackEntry(position: 2, sha: "b", title: "Head", ggId: "change-2", isCurrent: true),
        ]
        let harness = GGMutationHarness(stacks: [stack(head: "b", entries: entries)])

        await #expect(throws: GGMutationError.immutableTarget(reason: "Merged commits cannot be rewritten.")) {
            _ = try await harness.coordinator.prepare(.drop(target: "change-1"))
        }
        #expect(harness.service.requests.isEmpty)
    }

    @Test func pausedOperationBlocksMutationsButAllowsRecoveryActions() async throws {
        let harness = GGMutationHarness(stacks: [
            stack(head: "a", operationID: "op_paused"),
            stack(head: "a", operationID: "op_paused"),
        ])

        await #expect(throws: GGMutationError.pausedOperation) {
            try await harness.coordinator.apply(.sync, confirmedAgainst: nil)
        }
        try await harness.coordinator.apply(.continueOperation, confirmedAgainst: nil)

        #expect(harness.service.requests == [.continueOperation])
    }

    @Test func recoveryActionWorksWhenPausedSnapshotHasNoStackShape() async throws {
        let harness = GGMutationHarness(stacks: [
            GGStackSnapshot(version: 1, stack: nil, operationID: "op_paused"),
        ])
        harness.actionState.setPaused(GGPausedOperation(pausedBy: .restack))

        try await harness.coordinator.apply(.continueOperation, confirmedAgainst: nil)

        #expect(harness.service.requests == [.continueOperation])
    }

    @Test func recoveryActionStillRunsWhenFreshStackLoadFails() async throws {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.loadError = GGServiceError.commandFailed(stderr: "stack unavailable during rebase")
        harness.actionState.setPaused(GGPausedOperation(pausedBy: .restack))

        try await harness.coordinator.apply(.abortOperation, confirmedAgainst: nil)

        #expect(harness.service.requests == [.abortOperation])
    }

    @Test func remoteMutationRefreshesEveryAffectedSurface() async throws {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])

        try await harness.coordinator.apply(.sync, confirmedAgainst: nil)

        #expect(harness.refreshes == [.stack, .gitChanges, .providerReviews, .inbox])
        #expect(harness.actionState.lastActionSummary == "Synced")
        #expect(harness.actionState.syncProgress.isEmpty)
    }

    @Test func localMutationRefreshesStackGitAndInboxAfterError() async {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.service.error = GGServiceError.partialMutation(message: "partially rewritten")

        await #expect(throws: GGServiceError.partialMutation(message: "partially rewritten")) {
            try await harness.coordinator.apply(.drop(target: "change-2"), confirmedAgainst: nil)
        }

        #expect(harness.refreshes == [.stack, .gitChanges, .inbox])
        #expect(harness.actionState.lastError == "partially rewritten")
    }

    @Test func topologyRefreshRunsOnlyForCleanAndWorktreeCreatingUnstack() async throws {
        let clean = GGMutationHarness(stacks: [stack(head: "a")])
        try await clean.coordinator.apply(.clean, confirmedAgainst: nil)
        #expect(clean.refreshes == [
            .topology, .worktreeExistenceCheck, .stack, .gitChanges, .providerReviews, .inbox,
        ])

        let withoutWorktree = GGMutationHarness(stacks: [stack(head: "a")])
        withoutWorktree.service.result = .unstack(.init(
            originalStack: "feature", newStack: "upper", movedCommits: [],
            worktreePath: nil, currentStack: "feature"
        ))
        try await withoutWorktree.coordinator.apply(
            .unstack(target: "change-2", name: "upper", createWorktree: false),
            confirmedAgainst: nil
        )
        #expect(!withoutWorktree.refreshes.contains(.topology))

        let withWorktree = GGMutationHarness(stacks: [stack(head: "a")])
        withWorktree.service.result = .unstack(.init(
            originalStack: "feature", newStack: "upper", movedCommits: [],
            worktreePath: "/repo/upper", currentStack: "feature"
        ))
        try await withWorktree.coordinator.apply(
            .unstack(target: "change-2", name: "upper", createWorktree: true),
            confirmedAgainst: nil
        )
        #expect(withWorktree.refreshes == [.stack, .gitChanges, .inbox, .topology])
        #expect(withWorktree.selectedPaths == ["/repo/upper"])
    }

    @Test func checkoutDoesNotInvalidateProjectInbox() async throws {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        try await harness.coordinator.apply(.checkout(target: "change-1"), confirmedAgainst: nil)
        #expect(harness.refreshes == [.stack, .gitChanges])
    }

    @Test func conflictFailurePreservesPausedAction() async {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.service.error = GGServiceError.pausedConflict(message: "Resolve conflicts")

        await #expect(throws: GGServiceError.pausedConflict(message: "Resolve conflicts")) {
            try await harness.coordinator.apply(.restack, confirmedAgainst: nil)
        }

        #expect(harness.actionState.pausedOperation == GGPausedOperation(pausedBy: .restack))
        #expect(harness.actionState.inFlightAction == nil)
    }

    @Test func localSuccessPersistsNewestUndoableOperationAndLaterMutationClearsIt() async throws {
        let harness = GGMutationHarness(stacks: [stack(head: "a"), stack(head: "a")])
        let operation = GGOperationSummary(
            id: "op_1", kind: "sc", status: .completed, createdAtMs: 1,
            args: ["sc"], touchedRemote: false, isUndoable: true
        )
        harness.service.operationLists = [[], [operation]]
        try await harness.coordinator.apply(.amendCurrent, confirmedAgainst: nil)
        #expect(harness.markers.operationID(worktreeId: "wt") == "op_1")

        harness.service.operationLists = []
        harness.service.error = GGServiceError.commandFailed(stderr: "failed")
        await #expect(throws: GGServiceError.commandFailed(stderr: "failed")) {
            try await harness.coordinator.apply(.checkout(target: "change-1"), confirmedAgainst: nil)
        }
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
    }

    @Test func successfulMutationDoesNotRestoreAnOlderUndoMarker() async throws {
        let oldOperation = GGOperationSummary(
            id: "op_old", kind: "squash", status: .completed, createdAtMs: 1,
            args: ["sc"], touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.markers.set(operationID: oldOperation.id, worktreeId: "wt")
        harness.service.operationLists = [[oldOperation], [oldOperation]]

        try await harness.coordinator.apply(.checkout(target: "change-1"), confirmedAgainst: nil)

        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
    }

    @Test func stackIdentityIncludesSnakeCaseOperationID() throws {
        let payload = #"{"version":1,"operation_id":"op_7","stack":{"name":"feature","base":"main","total_commits":1,"synced_commits":0,"current_position":1,"behind_base":0,"entries":[{"position":1,"sha":"abc","title":"Head","gg_id":"change-1","is_current":true}]}}"#

        let snapshot = try GGStackSnapshot.decode(fromJSON: Data(payload.utf8))

        #expect(snapshot.identity == GGStackIdentity(
            stackName: "feature", base: "main", headSHA: "abc", operationID: "op_7"
        ))
    }

    @Test func malformedRemoteOutputUsesObservedRefreshAsSuccess() async throws {
        let entries = [
            GGStackEntry(
                position: 1, sha: "a", title: "Ready", ggId: "change-2",
                prNumber: 7, prState: .open, approved: true, ciStatus: .success,
                isCurrent: true
            ),
        ]
        let harness = GGMutationHarness(stacks: [stack(head: "a", entries: entries)])
        harness.service.error = GGServiceError.malformedOutput("newer gg schema")

        try await harness.coordinator.apply(.land(target: "change-2"), confirmedAgainst: nil)

        #expect(harness.refreshes == [.stack, .gitChanges, .providerReviews, .inbox])
        #expect(harness.actionState.lastError == nil)
    }
}
