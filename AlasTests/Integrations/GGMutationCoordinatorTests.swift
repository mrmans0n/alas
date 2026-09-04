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
    var clientOperationIDs: [String?] = []
    var syncJSONLCapabilities: [Bool] = []
    var result: GGMutationExecutionResult = .none
    var error: Error?
    var newestOperation: GGOperationSummary?
    var operationLists: [[GGOperationSummary]] = []
    var operationListCallCount = 0
    var onListUndoOperations: (() async -> Void)?
    var restackPreview = GGRestackResult(
        stackName: "feature", totalEntries: 2, entriesRestacked: 1, entriesOK: 1,
        dryRun: true,
        steps: [GGRestackStep(
            position: 2, ggID: "change-2", title: "Head", action: "restack",
            currentParent: "old", expectedParent: "base"
        )]
    )
    var restackPreviewCallCount = 0
    var blockExecution = false
    var syncEvents: [GGSyncEvent] = [.start(totalEntries: 1), .summary]
    private var executionContinuation: CheckedContinuation<Void, Never>?

    func execute(
        _ request: GGMutationRequest,
        worktreePath: String,
        clientOperationID: String?,
        supportsSyncJSONL: Bool,
        onSyncEvent: (GGSyncEvent) -> Void
    ) async throws -> GGMutationExecutionResult {
        requests.append(request)
        clientOperationIDs.append(clientOperationID)
        syncJSONLCapabilities.append(supportsSyncJSONL)
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
        let operations: [GGOperationSummary]
        if !operationLists.isEmpty {
            operations = operationLists[min(operationListCallCount, operationLists.count - 1)]
        } else {
            operations = newestOperation.map { [$0] } ?? []
        }
        operationListCallCount += 1
        await onListUndoOperations?()
        return operations
    }

    func previewRestack(worktreePath: String) async throws -> GGRestackResult {
        restackPreviewCallCount += 1
        if let error { throw error }
        return restackPreview
    }

    func resumeExecution() {
        executionContinuation?.resume()
        executionContinuation = nil
    }
}

@MainActor
private final class GGClientOperationCapabilityBox {
    var isSupported: Bool
    init(_ isSupported: Bool) { self.isSupported = isSupported }
}

@MainActor
private final class GGSyncJSONLCapabilityBox {
    var isSupported: Bool
    init(_ isSupported: Bool) { self.isSupported = isSupported }
}

@MainActor
private final class GGClientOperationTokenGenerator {
    private var count = 0

    func next() -> String {
        count += 1
        return "alas:test-\(count)"
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

private actor FirstRefreshSuspension {
    private var didSuspend = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?

    func suspend() async {
        guard !didSuspend else { return }
        didSuspend = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { completion = $0 }
    }

    func waitUntilSuspended() async {
        if didSuspend { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func resume() {
        completion?.resume()
        completion = nil
    }
}

private actor UndoOperationListSuspension {
    private let suspensionCall: Int
    private var callCount = 0
    private var didSuspend = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?

    init(suspendOnCall suspensionCall: Int) {
        self.suspensionCall = suspensionCall
    }

    func suspend() async {
        callCount += 1
        guard callCount == suspensionCall else { return }
        didSuspend = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { completion = $0 }
    }

    func waitUntilSuspended() async {
        if didSuspend { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func resume() {
        completion?.resume()
        completion = nil
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
    let clientOperationCapability: GGClientOperationCapabilityBox
    let syncJSONLCapability: GGSyncJSONLCapabilityBox
    let tokenGenerator: GGClientOperationTokenGenerator
    var stacks: [GGStackSnapshot]
    var loadError: Error?
    var loadCount = 0
    var refreshes: [Refresh] = []
    var selectedPaths: [String] = []
    var worktreeExists = true
    var currentBranch: String? = "feature"
    var finishPendingStaging: () async -> Bool = { true }
    var onRefreshStack: (() async -> Void)?
    private(set) var coordinator: GGMutationCoordinator!

    init(
        stacks: [GGStackSnapshot],
        supportsClientOperationID: Bool = false,
        supportsSyncJSONL: Bool = false
    ) {
        self.stacks = stacks
        let capability = GGClientOperationCapabilityBox(supportsClientOperationID)
        clientOperationCapability = capability
        let syncCapability = GGSyncJSONLCapabilityBox(supportsSyncJSONL)
        syncJSONLCapability = syncCapability
        let generator = GGClientOperationTokenGenerator()
        tokenGenerator = generator
        coordinator = GGMutationCoordinator(
            worktreeId: "wt",
            worktreePath: "/repo/wt",
            service: service,
            actionState: actionState,
            undoMarkerStore: markers,
            clientOperationIDCapability: { capability.isSupported },
            syncJSONLCapability: { syncCapability.isSupported },
            clientOperationIDGenerator: { generator.next() },
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
                finishPendingStaging: { [unowned self] in await finishPendingStaging() },
                worktreeExists: { [unowned self] in
                    refreshes.append(.worktreeExistenceCheck)
                    return worktreeExists
                },
                invalidateInbox: { [unowned self] in refreshes.append(.inbox) },
                selectWorktreeAtPath: { [unowned self] path in selectedPaths.append(path) },
                currentBranch: { [unowned self] in currentBranch }
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
    @Test func onlyStagedChangeMutationsWaitForStaging() {
        #expect(GGMutationRequest.amendCurrent.requiresStagedChanges)
        #expect(GGMutationRequest.absorbStaged.requiresStagedChanges)
        #expect(!GGMutationRequest.sync.requiresStagedChanges)
    }

    @Test func amendWaitsForPendingStagingBeforeExecuting() async throws {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        let staging = FirstRefreshSuspension()
        harness.finishPendingStaging = {
            await staging.suspend()
            return true
        }

        let task = try #require(
            harness.coordinator.startApplying(.amendCurrent, confirmedAgainst: nil)
        )
        await staging.waitUntilSuspended()

        #expect(harness.actionState.inFlightAction == .amendCurrent)
        #expect(harness.loadCount == 0)
        #expect(harness.service.requests.isEmpty)

        await staging.resume()
        try await task.value

        #expect(harness.service.requests == [.amendCurrent])
    }

    @Test func failedStagingPreventsAmend() async {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.finishPendingStaging = { false }

        await #expect(throws: GGMutationError.stagingFailed) {
            try await harness.coordinator.apply(.amendCurrent, confirmedAgainst: nil)
        }

        #expect(harness.loadCount == 0)
        #expect(harness.service.requests.isEmpty)
    }

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

    @Test func dropRejectsConfirmationWhenItsReviewWarningChanges() async throws {
        let open = [
            GGStackEntry(
                position: 1, sha: "a", title: "Drop", ggId: "change-1",
                prNumber: 7, prState: .open, isCurrent: true
            ),
        ]
        let closed = [
            GGStackEntry(
                position: 1, sha: "a", title: "Drop", ggId: "change-1",
                prNumber: 7, prState: .closed, isCurrent: true
            ),
        ]
        let harness = GGMutationHarness(stacks: [
            stack(head: "a", entries: open),
            stack(head: "a", entries: closed),
        ])
        let prepared = try await harness.coordinator.prepare(.drop(target: "change-1"))

        await #expect(throws: GGMutationError.staleConfirmation) {
            try await harness.coordinator.apply(prepared)
        }

        #expect(harness.service.requests.isEmpty)
    }

    @Test func startApplyingRejectsConfirmationWhenItsReviewWarningChanges() async throws {
        let open = [
            GGStackEntry(
                position: 1, sha: "a", title: "Drop", ggId: "change-1",
                prNumber: 7, prState: .open, isCurrent: true
            ),
        ]
        let closed = [
            GGStackEntry(
                position: 1, sha: "a", title: "Drop", ggId: "change-1",
                prNumber: 7, prState: .closed, isCurrent: true
            ),
        ]
        let harness = GGMutationHarness(stacks: [
            stack(head: "a", entries: open),
            stack(head: "a", entries: closed),
        ])
        let prepared = try await harness.coordinator.prepare(.drop(target: "change-1"))
        let task = try #require(harness.coordinator.startApplying(prepared))

        await #expect(throws: GGMutationError.staleConfirmation) {
            try await task.value
        }

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

    @Test func splitPreflightMatchesAnAbbreviatedSHAWhenNoGGIDIsAvailable() async throws {
        let entries = [
            GGStackEntry(position: 1, sha: "base", title: "Base", ggId: "change-1"),
            GGStackEntry(
                position: 2,
                sha: "abcdef1",
                title: "Target",
                isCurrent: true
            ),
        ]
        let harness = GGMutationHarness(stacks: [stack(head: "abcdef1", entries: entries)])
        let request = GGMutationRequest.applySplit(
            planURL: URL(fileURLWithPath: "/tmp/plan.json"),
            target: GGSplitTargetIdentity(
                ggID: nil,
                sha: "abcdef1234567890",
                tree: "tree"
            ),
            planToken: "token"
        )

        let prepared = try await harness.coordinator.prepare(request)

        #expect(prepared.request == request)
    }

    @Test func splitPreflightDoesNotFallBackToSHAWhenAGGIDIsPresent() async {
        let entries = [
            GGStackEntry(position: 1, sha: "base", title: "Base", ggId: "change-1"),
            GGStackEntry(
                position: 2,
                sha: "abcdef1",
                title: "Target",
                ggId: "change-2",
                isCurrent: true
            ),
        ]
        let harness = GGMutationHarness(stacks: [stack(head: "abcdef1", entries: entries)])
        let request = GGMutationRequest.applySplit(
            planURL: URL(fileURLWithPath: "/tmp/plan.json"),
            target: GGSplitTargetIdentity(
                ggID: "changed-id",
                sha: "abcdef1234567890",
                tree: "tree"
            ),
            planToken: "token"
        )

        await #expect(throws: GGMutationError.staleConfirmation) {
            _ = try await harness.coordinator.prepare(request)
        }
    }

    @Test func preflightFailurePreservesExistingUndoState() async {
        let candidate = GGOperationSummary(
            id: "op_existing", kind: "reorder", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:existing", "reorder"],
            stackName: "feature",
            touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.markers.set(operationID: candidate.id, worktreeId: "wt")
        harness.service.newestOperation = candidate
        await harness.coordinator.restoreUndoCandidate(currentStackName: "feature")

        await #expect(throws: GGMutationError.staleConfirmation) {
            try await harness.coordinator.apply(.drop(target: "missing"), confirmedAgainst: nil)
        }

        #expect(harness.coordinator.undoCandidate?.operationID == candidate.id)
        #expect(harness.markers.operationID(worktreeId: "wt") == candidate.id)
        #expect(harness.service.requests.isEmpty)
    }

    @Test func reorderRequiresCompleteGGIDOrderAndKeepsImmutableRowsFixed() async throws {
        let entries = [
            GGStackEntry(
                position: 1, sha: "a", title: "Merged", ggId: "change-1",
                prNumber: 1, prState: .merged
            ),
            GGStackEntry(position: 2, sha: "b", title: "Two", ggId: "change-2"),
            GGStackEntry(position: 3, sha: "c", title: "Three", ggId: "change-3", isCurrent: true),
        ]
        let harness = GGMutationHarness(stacks: [stack(head: "c", entries: entries)])

        await #expect(throws: GGMutationError.staleConfirmation) {
            _ = try await harness.coordinator.prepare(.reorder(order: ["change-2", "change-3"]))
        }
        await #expect(throws: GGMutationError.immutableTarget(
            reason: "Merged commits must remain fixed while reordering."
        )) {
            _ = try await harness.coordinator.prepare(
                .reorder(order: ["change-2", "change-1", "change-3"])
            )
        }

        let prepared = try await harness.coordinator.prepare(
            .reorder(order: ["change-1", "change-3", "change-2"])
        )
        #expect(prepared.request == .reorder(order: ["change-1", "change-3", "change-2"]))
        #expect(harness.service.requests.isEmpty)
    }

    @Test func reorderRejectsForgedOrderThatCrossesAnImmutableBoundary() async {
        let entries = [
            GGStackEntry(position: 1, sha: "a", title: "Lower", ggId: "change-1"),
            GGStackEntry(
                position: 2, sha: "b", title: "Merged", ggId: "change-2",
                prNumber: 2, prState: .merged
            ),
            GGStackEntry(position: 3, sha: "c", title: "Upper", ggId: "change-3", isCurrent: true),
        ]
        let harness = GGMutationHarness(stacks: [stack(head: "c", entries: entries)])

        await #expect(throws: GGMutationError.immutableTarget(
            reason: "Commits cannot move across an immutable boundary."
        )) {
            _ = try await harness.coordinator.prepare(
                .reorder(order: ["change-3", "change-2", "change-1"])
            )
        }

        #expect(harness.service.requests.isEmpty)
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

        #expect(harness.refreshes == [.gitChanges, .stack, .providerReviews, .inbox])
        #expect(harness.actionState.lastActionSummary == "Synced")
        #expect(harness.actionState.syncProgress.isEmpty)
    }

    @Test func terminalSyncSummaryKeepsRefreshProgressVisibleUntilRefreshCompletes() async throws {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        var refreshStarted = false
        var resumeRefresh: CheckedContinuation<Void, Never>?
        harness.onRefreshStack = {
            await withCheckedContinuation { continuation in
                resumeRefresh = continuation
                refreshStarted = true
            }
        }

        let task = try #require(harness.coordinator.startApplying(.sync, confirmedAgainst: nil))
        try await waitUntil { refreshStarted }

        let model = GGStackReadinessModel.make(
            stack: try #require(harness.stacks[0].stack),
            action: harness.actionState
        )
        #expect(harness.coordinator.activeRequest == .sync)
        #expect(harness.actionState.inFlightAction == .sync)
        #expect(harness.actionState.lastActionSummary == "Synced")
        #expect(!harness.actionState.syncProgress.isEmpty)
        #expect(model.syncProgress?.liveStatus == "Refreshing Changes…")
        #expect(model.primaryActions.first(where: { $0.kind == .sync })?.isInFlight == true)

        resumeRefresh?.resume()
        try await task.value
        #expect(harness.coordinator.activeRequest == nil)
        #expect(harness.actionState.inFlightAction == nil)
        #expect(harness.actionState.syncProgress.isEmpty)
    }

    @Test func syncCommandFailurePublishesTerminalStateBeforeSuspendedRefresh() async throws {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.service.syncEvents = [.start(totalEntries: 1)]
        harness.service.error = GGServiceError.commandFailed(stderr: "sync failed")
        var refreshStarted = false
        var resumeRefresh: CheckedContinuation<Void, Never>?
        harness.onRefreshStack = {
            await withCheckedContinuation { continuation in
                resumeRefresh = continuation
                refreshStarted = true
            }
        }

        let task = try #require(harness.coordinator.startApplying(.sync, confirmedAgainst: nil))
        try await waitUntil { refreshStarted }

        let model = GGStackReadinessModel.make(
            stack: try #require(harness.stacks[0].stack),
            action: harness.actionState
        )
        #expect(harness.coordinator.activeRequest == .sync)
        #expect(harness.actionState.inFlightAction == .sync)
        #expect(harness.actionState.lastError == "sync failed")
        #expect(harness.actionState.syncHasTerminalFailure)
        #expect(model.syncProgress?.liveStatus == nil)
        #expect(model.syncProgress?.showsSpinner == false)

        resumeRefresh?.resume()
        await #expect(throws: GGServiceError.commandFailed(stderr: "sync failed")) {
            try await task.value
        }
        #expect(harness.coordinator.activeRequest == nil)
        #expect(harness.actionState.inFlightAction == nil)
    }

    @Test func syncProtocolViolationsPropagateAndPublishError() async {
        for message in [
            "gg sync ended without a summary event.",
            "gg sync emitted data after a terminal event.",
        ] {
            let harness = GGMutationHarness(stacks: [stack(head: "a")])
            harness.service.syncEvents = [.start(totalEntries: 1)]
            harness.service.error = GGServiceError.malformedOutput(message)

            await #expect(throws: GGServiceError.malformedOutput(message)) {
                try await harness.coordinator.apply(.sync, confirmedAgainst: nil)
            }

            #expect(harness.actionState.lastError == message)
            #expect(harness.actionState.syncHasTerminalFailure)
        }
    }

    @Test func reservingSyncImmediatelyPublishesPreparingFeedback() async throws {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.service.blockExecution = true
        let task = try #require(harness.coordinator.startApplying(.sync, confirmedAgainst: nil))

        let model = GGStackReadinessModel.make(
            stack: try #require(harness.stacks[0].stack),
            action: harness.actionState
        )
        #expect(model.syncProgress?.liveStatus == "Preparing stack…")

        try await waitUntil { !harness.service.requests.isEmpty }
        harness.service.resumeExecution()
        try await task.value
    }

    @Test func syncForwardsCachedJSONLCapability() async throws {
        let current = GGMutationHarness(
            stacks: [stack(head: "a")],
            supportsSyncJSONL: true
        )
        try await current.coordinator.apply(.sync, confirmedAgainst: nil)
        #expect(current.service.syncJSONLCapabilities == [true])

        let old = GGMutationHarness(
            stacks: [stack(head: "a")],
            supportsSyncJSONL: false
        )
        try await old.coordinator.apply(.sync, confirmedAgainst: nil)
        #expect(old.service.syncJSONLCapabilities == [false])
    }

    @Test func localMutationRefreshesStackGitAndInboxAfterError() async {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.service.error = GGServiceError.partialMutation(message: "partially rewritten")

        await #expect(throws: GGServiceError.partialMutation(message: "partially rewritten")) {
            try await harness.coordinator.apply(.drop(target: "change-2"), confirmedAgainst: nil)
        }

        #expect(harness.refreshes == [.gitChanges, .stack, .inbox])
        #expect(harness.actionState.lastError == "partially rewritten")
    }

    @Test func amendRefreshesGitChangesBeforeWaitingForStackRefresh() async throws {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        let refresh = FirstRefreshSuspension()
        harness.onRefreshStack = { await refresh.suspend() }

        let task = try #require(harness.coordinator.startApplying(.amendCurrent, confirmedAgainst: nil))
        await refresh.waitUntilSuspended()

        #expect(harness.refreshes == [.gitChanges, .stack])

        await refresh.resume()
        try await task.value
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
        #expect(withoutWorktree.actionState.lastActionSummary == "New stack created without a worktree")

        let withWorktree = GGMutationHarness(stacks: [stack(head: "a")])
        withWorktree.service.result = .unstack(.init(
            originalStack: "feature", newStack: "upper", movedCommits: [],
            worktreePath: "/repo/upper", currentStack: "feature"
        ))
        try await withWorktree.coordinator.apply(
            .unstack(target: "change-2", name: "upper", createWorktree: true),
            confirmedAgainst: nil
        )
        #expect(withWorktree.refreshes == [.gitChanges, .stack, .inbox, .topology])
        #expect(withWorktree.selectedPaths == ["/repo/upper"])
    }

    @Test func checkoutDoesNotInvalidateProjectInbox() async throws {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        try await harness.coordinator.apply(.checkout(target: "change-1"), confirmedAgainst: nil)
        #expect(harness.refreshes == [.gitChanges, .stack])
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

    @Test func continueConflictPreservesTheOriginalPausedAction() async {
        let harness = GGMutationHarness(stacks: [stack(head: "a", operationID: "op_paused")])
        harness.actionState.setPaused(GGPausedOperation(pausedBy: .restack))
        harness.service.error = GGServiceError.pausedConflict(message: "Resolve conflicts")

        await #expect(throws: GGServiceError.pausedConflict(message: "Resolve conflicts")) {
            try await harness.coordinator.apply(.continueOperation, confirmedAgainst: nil)
        }

        #expect(harness.actionState.pausedOperation == GGPausedOperation(pausedBy: .restack))
    }

    @Test func abortFailurePreservesTheOriginalPausedAction() async {
        let harness = GGMutationHarness(stacks: [stack(head: "a", operationID: "op_paused")])
        harness.actionState.setPaused(GGPausedOperation(pausedBy: .sync))
        harness.service.error = GGServiceError.commandFailed(stderr: "abort failed")

        await #expect(throws: GGServiceError.commandFailed(stderr: "abort failed")) {
            try await harness.coordinator.apply(.abortOperation, confirmedAgainst: nil)
        }

        #expect(harness.actionState.pausedOperation == GGPausedOperation(pausedBy: .sync))
    }

    @Test func restackAlwaysPreviewsBeforeApplyAndUsesTheSameStackIdentity() async throws {
        let harness = GGMutationHarness(stacks: [
            stack(head: "a"),
            stack(head: "a"),
            stack(head: "a"),
        ])

        let prepared = try await harness.coordinator.prepareRestackPreview()
        #expect(harness.service.restackPreviewCallCount == 1)
        #expect(prepared.plan.dryRun)
        #expect(prepared.snapshot.headSHA == "a")
        #expect(harness.service.requests.isEmpty)

        try await harness.coordinator.apply(.restack, confirmedAgainst: prepared.snapshot)
        #expect(harness.service.requests == [.restack])
    }

    @Test func restackRejectsAPreviewWhenTheStackChangesDuringTheDryRun() async {
        let harness = GGMutationHarness(stacks: [
            stack(head: "a"),
            stack(head: "b"),
        ])

        await #expect(throws: GGMutationError.staleConfirmation) {
            _ = try await harness.coordinator.prepareRestackPreview()
        }

        #expect(harness.service.restackPreviewCallCount == 1)
        #expect(harness.service.requests.isEmpty)
    }

    @Test func restackRejectsApplyWhenStackChangedAfterPreview() async throws {
        let harness = GGMutationHarness(stacks: [
            stack(head: "a"),
            stack(head: "a"),
            stack(head: "b"),
        ])

        let prepared = try await harness.coordinator.prepareRestackPreview()
        await #expect(throws: GGMutationError.staleConfirmation) {
            try await harness.coordinator.apply(.restack, confirmedAgainst: prepared.snapshot)
        }

        #expect(harness.service.restackPreviewCallCount == 1)
        #expect(harness.service.requests.isEmpty)
    }

    @Test func restackRejectsNonDryRunOrWrongStackPreviewPayload() async {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.service.restackPreview = GGRestackResult(
            stackName: "other", totalEntries: 1, entriesRestacked: 1, entriesOK: 0,
            dryRun: false, steps: []
        )

        await #expect(throws: GGServiceError.malformedOutput(
            "gg returned a restack plan for a different stack."
        )) {
            _ = try await harness.coordinator.prepareRestackPreview()
        }

        #expect(harness.service.restackPreviewCallCount == 1)
        #expect(harness.service.requests.isEmpty)
    }

    @Test func localSuccessPersistsNewestUndoableOperationAndLaterMutationClearsIt() async throws {
        let harness = GGMutationHarness(
            stacks: [stack(head: "a"), stack(head: "a")],
            supportsClientOperationID: true
        )
        let operation = GGOperationSummary(
            id: "op_1", kind: "squash", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:test-1", "sc"],
            stackName: "feature",
            touchedRemote: false, isUndoable: true
        )
        harness.service.operationLists = [[operation]]
        try await harness.coordinator.apply(.amendCurrent, confirmedAgainst: nil)
        #expect(harness.markers.operationID(worktreeId: "wt") == "op_1")
        #expect(harness.coordinator.undoCandidate?.operationID == "op_1")
        #expect(harness.service.clientOperationIDs == ["alas:test-1"])

        harness.service.operationLists = []
        harness.service.error = GGServiceError.commandFailed(stderr: "failed")
        await #expect(throws: GGServiceError.commandFailed(stderr: "failed")) {
            try await harness.coordinator.apply(.checkout(target: "change-1"), confirmedAgainst: nil)
        }
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
        #expect(harness.coordinator.undoCandidate == nil)
    }

    @Test func decodedSquashOperationExposesUndoAfterAmend() async throws {
        let payload = Data(#"{"id":"op_1","kind":"squash","status":"committed","created_at_ms":1,"args":["--client-operation-id","alas:test-1","sc","--staged-only"],"stack_name":"feature","touched_remote":false,"is_undoable":true}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let operation = try decoder.decode(GGOperationSummary.self, from: payload)
        let harness = GGMutationHarness(
            stacks: [stack(head: "a")], supportsClientOperationID: true
        )
        harness.service.newestOperation = operation

        try await harness.coordinator.apply(.amendCurrent, confirmedAgainst: nil)

        #expect(harness.coordinator.undoCandidate == GGUndoCandidate(operation: operation))
        #expect(harness.markers.operationID(worktreeId: "wt") == operation.id)
    }

    @Test func localOperationWithoutStackNameDoesNotExposeUnusableUndo() async throws {
        let operation = GGOperationSummary(
            id: "op_1", kind: "squash", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:test-1", "sc"],
            touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(
            stacks: [stack(head: "a")], supportsClientOperationID: true
        )
        harness.service.newestOperation = operation

        try await harness.coordinator.apply(.amendCurrent, confirmedAgainst: nil)

        #expect(harness.coordinator.undoCandidate == nil)
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
    }

    @Test func suspendingUndoCandidateKeepsItAvailableAfterGitRecovery() async {
        let operation = GGOperationSummary(
            id: "op_1", kind: "reorder", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:persisted", "reorder"],
            stackName: "feature",
            touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.markers.set(operationID: operation.id, worktreeId: "wt")
        harness.service.newestOperation = operation
        await harness.coordinator.restoreUndoCandidate(currentStackName: "feature")

        harness.coordinator.suspendUndoCandidate()

        #expect(harness.coordinator.undoCandidate == nil)
        #expect(harness.markers.operationID(worktreeId: "wt") == operation.id)
    }

    @Test func finalDropRecoveryRestoresOnRecordedBranch() async {
        let operation = GGOperationSummary(
            id: "op_drop", kind: "drop", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:persisted", "drop", "change-1"],
            stackName: "feature",
            touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.currentBranch = "feature"
        harness.markers.set(
            GGUndoMarker(operationID: operation.id, removedFinalStackCommit: true, branch: "feature"),
            worktreeId: "wt"
        )
        harness.service.newestOperation = operation

        // Empty stack after the final drop → currentStackName is nil.
        await harness.coordinator.restoreUndoCandidate(currentStackName: nil)

        #expect(harness.coordinator.undoCandidate?.operationID == "op_drop")
        #expect(harness.markers.operationID(worktreeId: "wt") == "op_drop")
    }

    @Test func finalDropRecoveryClearedAfterCheckoutToAnotherBranch() async {
        let operation = GGOperationSummary(
            id: "op_drop", kind: "drop", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:persisted", "drop", "change-1"],
            stackName: "feature",
            touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.currentBranch = "unrelated-branch"
        harness.markers.set(
            GGUndoMarker(operationID: operation.id, removedFinalStackCommit: true, branch: "feature"),
            worktreeId: "wt"
        )
        harness.service.newestOperation = operation

        await harness.coordinator.restoreUndoCandidate(currentStackName: nil)

        #expect(harness.coordinator.undoCandidate == nil)
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
    }

    @Test func unsupportedGGMutatesNormallyWithoutUndoCorrelation() async throws {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.service.newestOperation = GGOperationSummary(
            id: "op_external", kind: "squash", status: .completed, createdAtMs: 1,
            args: ["sc"], touchedRemote: false, isUndoable: true
        )

        try await harness.coordinator.apply(.amendCurrent, confirmedAgainst: nil)

        #expect(harness.service.requests == [.amendCurrent])
        #expect(harness.service.clientOperationIDs == [nil])
        #expect(harness.service.operationListCallCount == 0)
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
        #expect(harness.coordinator.undoCandidate == nil)
    }

    @Test func unrelatedNewestOperationCannotClaimGeneratedClientToken() async throws {
        let harness = GGMutationHarness(
            stacks: [stack(head: "a")], supportsClientOperationID: true
        )
        harness.service.newestOperation = GGOperationSummary(
            id: "op_external", kind: "reorder", status: .completed, createdAtMs: 2,
            args: ["--client-operation-id", "alas:other", "alas:test-1"],
            touchedRemote: false, isUndoable: true
        )

        try await harness.coordinator.apply(.amendCurrent, confirmedAgainst: nil)

        #expect(harness.service.clientOperationIDs == ["alas:test-1"])
        #expect(harness.service.operationListCallCount == 1)
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
        #expect(harness.coordinator.undoCandidate == nil)
    }

    @Test func dynamicCapabilityCanEnableCorrelationWithoutRecreatingCoordinator() async throws {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        try await harness.coordinator.apply(.amendCurrent, confirmedAgainst: nil)
        #expect(harness.service.clientOperationIDs == [nil])
        #expect(harness.service.operationListCallCount == 0)

        harness.clientOperationCapability.isSupported = true
        let matching = GGOperationSummary(
            id: "op_1", kind: "squash", status: .completed, createdAtMs: 2,
            args: ["--client-operation-id", "alas:test-1", "sc"],
            stackName: "feature",
            touchedRemote: false, isUndoable: true
        )
        harness.service.newestOperation = matching

        try await harness.coordinator.apply(.amendCurrent, confirmedAgainst: nil)

        #expect(harness.service.clientOperationIDs == [nil, "alas:test-1"])
        #expect(harness.service.operationListCallCount == 1)
        #expect(harness.coordinator.undoCandidate == GGUndoCandidate(operation: matching))
    }

    @Test func continueCorrelatesTheCompletedPausedOperationWithoutSendingANewToken() async throws {
        let completed = GGOperationSummary(
            id: "op_paused", kind: "restack", status: .completed, createdAtMs: 2,
            args: ["--client-operation-id", "alas:original", "restack"],
            stackName: "feature",
            touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(
            stacks: [stack(head: "a", operationID: "op_paused")],
            supportsClientOperationID: true
        )
        harness.service.newestOperation = completed

        try await harness.coordinator.apply(.continueOperation, confirmedAgainst: nil)

        #expect(harness.service.clientOperationIDs == [nil])
        #expect(harness.service.operationListCallCount == 1)
        #expect(harness.markers.operationID(worktreeId: "wt") == completed.id)
        #expect(harness.coordinator.undoCandidate == GGUndoCandidate(operation: completed))
    }

    @Test func continueRejectsANewerOperationThanThePausedOperation() async throws {
        let newer = GGOperationSummary(
            id: "op_external", kind: "reorder", status: .completed, createdAtMs: 3,
            args: ["--client-operation-id", "alas:external", "reorder"],
            touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(
            stacks: [stack(head: "a", operationID: "op_paused")],
            supportsClientOperationID: true
        )
        harness.service.newestOperation = newer

        try await harness.coordinator.apply(.continueOperation, confirmedAgainst: nil)

        #expect(harness.service.clientOperationIDs == [nil])
        #expect(harness.service.operationListCallCount == 1)
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
        #expect(harness.coordinator.undoCandidate == nil)
    }

    @Test func continueRejectsThePausedOperationWithoutAnAlasClientToken() async throws {
        let legacy = GGOperationSummary(
            id: "op_paused", kind: "restack", status: .completed, createdAtMs: 2,
            args: ["restack"], touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(
            stacks: [stack(head: "a", operationID: "op_paused")],
            supportsClientOperationID: true
        )
        harness.service.newestOperation = legacy

        try await harness.coordinator.apply(.continueOperation, confirmedAgainst: nil)

        #expect(harness.service.clientOperationIDs == [nil])
        #expect(harness.service.operationListCallCount == 1)
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
        #expect(harness.coordinator.undoCandidate == nil)
    }

    @Test func abortNeverSendsATokenOrQueriesForUndo() async throws {
        let harness = GGMutationHarness(
            stacks: [stack(head: "a", operationID: "op_paused")],
            supportsClientOperationID: true
        )
        harness.service.newestOperation = GGOperationSummary(
            id: "op_paused", kind: "restack", status: .completed, createdAtMs: 2,
            args: ["--client-operation-id", "alas:original", "restack"],
            touchedRemote: false, isUndoable: true
        )

        try await harness.coordinator.apply(.abortOperation, confirmedAgainst: nil)

        #expect(harness.service.clientOperationIDs == [nil])
        #expect(harness.service.operationListCallCount == 0)
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
        #expect(harness.coordinator.undoCandidate == nil)
    }

    @Test func relaunchRestoresOnlyMatchingPersistedLocalUndoableOperation() async {
        let matching = GGOperationSummary(
            id: "op_1", kind: "reorder", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:persisted", "reorder"],
            stackName: "feature",
            touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.markers.set(operationID: "op_1", worktreeId: "wt")
        harness.service.newestOperation = matching

        await harness.coordinator.restoreUndoCandidate(currentStackName: "feature")

        #expect(harness.coordinator.undoCandidate == GGUndoCandidate(operation: matching))
        #expect(harness.service.operationListCallCount == 1)
    }

    @Test func staleUndoRestoreDoesNotOverwriteNewerMutationCandidate() async throws {
        let restoredOperation = GGOperationSummary(
            id: "op_restored", kind: "reorder", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:restored", "reorder"],
            stackName: "feature", touchedRemote: false, isUndoable: true
        )
        let newerOperation = GGOperationSummary(
            id: "op_newer", kind: "squash", status: .completed, createdAtMs: 2,
            args: ["--client-operation-id", "alas:test-1", "sc"],
            stackName: "feature", touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(
            stacks: [stack(head: "a")], supportsClientOperationID: true
        )
        harness.markers.set(operationID: restoredOperation.id, worktreeId: "wt")
        harness.service.operationLists = [
            [restoredOperation],
            [restoredOperation],
            [newerOperation],
        ]
        let listSuspension = UndoOperationListSuspension(suspendOnCall: 2)
        harness.service.onListUndoOperations = { await listSuspension.suspend() }
        harness.onRefreshStack = {
            await harness.coordinator.restoreUndoCandidate(currentStackName: "feature")
        }

        let undoTask = try #require(harness.coordinator.startApplying(
            .undo(operationID: restoredOperation.id),
            confirmedAgainst: nil
        ))
        await listSuspension.waitUntilSuspended()

        try await harness.coordinator.apply(.amendCurrent, confirmedAgainst: nil)
        #expect(harness.coordinator.undoCandidate == GGUndoCandidate(operation: newerOperation))
        #expect(harness.markers.operationID(worktreeId: "wt") == newerOperation.id)

        await listSuspension.resume()
        try await undoTask.value

        #expect(harness.coordinator.undoCandidate == GGUndoCandidate(operation: newerOperation))
        #expect(harness.markers.operationID(worktreeId: "wt") == newerOperation.id)
    }

    @Test func relaunchClearsMarkerWhenNewestOperationDoesNotMatch() async {
        let newest = GGOperationSummary(
            id: "op_2", kind: "reorder", status: .completed, createdAtMs: 2,
            args: ["reorder"], touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.markers.set(operationID: "op_1", worktreeId: "wt")
        harness.service.newestOperation = newest

        await harness.coordinator.restoreUndoCandidate(currentStackName: "feature")

        #expect(harness.coordinator.undoCandidate == nil)
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
    }

    @Test func relaunchRejectsLegacyMarkerWithoutAlasClientCorrelation() async {
        let legacy = GGOperationSummary(
            id: "op_1", kind: "reorder", status: .completed, createdAtMs: 1,
            args: ["reorder"], touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.markers.set(operationID: legacy.id, worktreeId: "wt")
        harness.service.newestOperation = legacy

        await harness.coordinator.restoreUndoCandidate(currentStackName: "feature")

        #expect(harness.coordinator.undoCandidate == nil)
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
    }

    @Test func relaunchRejectsUndoOperationFromAnotherStack() async {
        let otherStack = GGOperationSummary(
            id: "op_1", kind: "reorder", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:persisted", "reorder"],
            stackName: "other",
            touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.markers.set(operationID: otherStack.id, worktreeId: "wt")
        harness.service.newestOperation = otherStack

        await harness.coordinator.restoreUndoCandidate(currentStackName: "feature")

        #expect(harness.coordinator.undoCandidate == nil)
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
    }

    @Test func relaunchClearsOrdinaryUndoWhenThereIsNoCurrentStack() async {
        let operation = GGOperationSummary(
            id: "op_1", kind: "reorder", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:persisted", "reorder"],
            stackName: "feature",
            touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.markers.set(operationID: operation.id, worktreeId: "wt")
        harness.service.newestOperation = operation

        await harness.coordinator.restoreUndoCandidate(currentStackName: nil)

        #expect(harness.coordinator.undoCandidate == nil)
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
        #expect(harness.service.operationListCallCount == 0)
    }

    @Test func remoteTouchedAndRemoteMutationsNeverExposeUndo() async throws {
        let remoteTouched = GGOperationSummary(
            id: "op_1", kind: "drop", status: .completed, createdAtMs: 1,
            args: ["drop"], touchedRemote: true, isUndoable: true
        )
        let local = GGMutationHarness(
            stacks: [stack(head: "a")], supportsClientOperationID: true
        )
        local.service.operationLists = [[GGOperationSummary(
            id: remoteTouched.id, kind: remoteTouched.kind, status: remoteTouched.status,
            createdAtMs: remoteTouched.createdAtMs,
            args: ["--client-operation-id", "alas:test-1", "drop"],
            touchedRemote: true, isUndoable: true
        )]]
        try await local.coordinator.apply(.drop(target: "change-2"), confirmedAgainst: nil)
        #expect(local.coordinator.undoCandidate == nil)
        #expect(local.markers.operationID(worktreeId: "wt") == nil)
        #expect(local.service.operationListCallCount == 1)

        let sync = GGMutationHarness(
            stacks: [stack(head: "a")], supportsClientOperationID: true
        )
        sync.service.operationLists = [[GGOperationSummary(
            id: "op_sync", kind: "sync", status: .completed, createdAtMs: 1,
            args: ["sync"], touchedRemote: false, isUndoable: true
        )]]
        try await sync.coordinator.apply(.sync, confirmedAgainst: nil)
        #expect(sync.service.clientOperationIDs == [nil])
        #expect(sync.service.operationListCallCount == 0)
        #expect(sync.coordinator.undoCandidate == nil)

        let landEntries = [
            GGStackEntry(
                position: 1, sha: "a", title: "Ready", ggId: "change-1",
                prNumber: 7, prState: .open, approved: true, ciStatus: .success,
                isCurrent: true
            ),
        ]
        let land = GGMutationHarness(
            stacks: [stack(head: "a", entries: landEntries)],
            supportsClientOperationID: true
        )
        try await land.coordinator.apply(.land(target: "change-1"), confirmedAgainst: nil)
        #expect(land.service.clientOperationIDs == [nil])
        #expect(land.service.operationListCallCount == 0)
        #expect(land.coordinator.undoCandidate == nil)
    }

    @Test func nonRewriteLocalMutationsNeverReceiveTokensOrExposeUndo() async throws {
        let requests: [GGMutationRequest] = [
            .checkout(target: "change-1"),
            .unstack(target: "change-2", name: "upper", createWorktree: false),
            .clean,
        ]
        for request in requests {
            let harness = GGMutationHarness(
                stacks: [stack(head: "a")], supportsClientOperationID: true
            )
            if case .unstack = request {
                harness.service.result = .unstack(.init(
                    originalStack: "feature", newStack: "upper", movedCommits: [],
                    worktreePath: nil, currentStack: "feature"
                ))
            }
            harness.service.newestOperation = GGOperationSummary(
                id: "op_1", kind: "checkout", status: .completed, createdAtMs: 1,
                args: ["--client-operation-id", "alas:test-1", "checkout"],
                touchedRemote: false, isUndoable: true
            )

            try await harness.coordinator.apply(request, confirmedAgainst: nil)

            #expect(harness.service.clientOperationIDs == [nil])
            #expect(harness.service.operationListCallCount == 0)
            #expect(harness.coordinator.undoCandidate == nil)
        }
    }

    @Test func cleanRefreshesPerWorktreeSurfacesAfterTopologyWhenWorktreeStillExists() async throws {
        let harness = GGMutationHarness(
            stacks: [stack(head: "a")], supportsClientOperationID: true
        )

        try await harness.coordinator.apply(.clean, confirmedAgainst: nil)

        #expect(harness.refreshes == [
            .topology, .worktreeExistenceCheck, .stack, .gitChanges, .providerReviews, .inbox,
        ])
        #expect(harness.service.clientOperationIDs == [nil])
        #expect(harness.service.operationListCallCount == 0)
    }

    @Test func cleanSkipsPerWorktreeRefreshesWhenTopologyRemovedTheWorktree() async throws {
        let harness = GGMutationHarness(
            stacks: [stack(head: "a")], supportsClientOperationID: true
        )
        harness.worktreeExists = false

        try await harness.coordinator.apply(.clean, confirmedAgainst: nil)

        #expect(harness.refreshes == [.topology, .worktreeExistenceCheck, .inbox])
    }

    @Test func restoreRejectsAlasTaggedNonRewriteOperation() async {
        let checkout = GGOperationSummary(
            id: "op_checkout", kind: "checkout", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:persisted", "mv"],
            touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.markers.set(operationID: checkout.id, worktreeId: "wt")
        harness.service.newestOperation = checkout

        await harness.coordinator.restoreUndoCandidate(currentStackName: "feature")

        #expect(harness.coordinator.undoCandidate == nil)
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
    }

    @Test func continueRejectsPausedNonRewriteOperation() async throws {
        let unstack = GGOperationSummary(
            id: "op_paused", kind: "unstack", status: .completed, createdAtMs: 2,
            args: ["--client-operation-id", "alas:original", "unstack"],
            touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(
            stacks: [stack(head: "a", operationID: "op_paused")],
            supportsClientOperationID: true
        )
        harness.service.newestOperation = unstack

        try await harness.coordinator.apply(.continueOperation, confirmedAgainst: nil)

        #expect(harness.service.operationListCallCount == 1)
        #expect(harness.coordinator.undoCandidate == nil)
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
    }

    @Test func streamedSyncErrorIsNotOverwrittenByGenericProcessFailure() async {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.service.syncEvents = [
            .pushDone(position: 1, forced: false),
            .prCreated(position: 1, prNumber: 7, prURL: nil, draft: false),
            .error(position: 2, operation: "push", message: "push rejected by protected branch"),
        ]
        harness.service.error = GGServiceError.commandFailed(stderr: "")

        await #expect(throws: GGServiceError.commandFailed(stderr: "")) {
            try await harness.coordinator.apply(.sync, confirmedAgainst: nil)
        }

        #expect(harness.actionState.lastError == "push rejected by protected branch")
        #expect(harness.actionState.syncHasTerminalFailure)
        let progress = GGStackReadinessModel.make(
            stack: stack(head: "a").stack!,
            action: harness.actionState
        ).syncProgress
        #expect(progress?.rows == [
            .init(position: 1, text: "[1] Pushed · PR #7 created"),
            .init(position: 2, text: "[2] Failed to push"),
        ])
        #expect(progress?.liveStatus == nil)
        #expect(progress?.showsSpinner == false)
    }

    @Test func streamedSyncErrorBecomesTerminalOnlyAfterSyncCompletes() async throws {
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.service.syncEvents = [.error(position: 1, operation: "push", message: "push failed")]
        harness.service.blockExecution = true

        let task = try #require(harness.coordinator.startApplying(.sync, confirmedAgainst: nil))
        try await waitUntil { harness.actionState.lastError == "push failed" }
        #expect(!harness.actionState.syncHasTerminalFailure)

        harness.service.resumeExecution()
        try await task.value
        #expect(harness.actionState.syncHasTerminalFailure)
    }

    @Test func undoRechecksNewestOperationImmediatelyBeforeLaunch() async {
        let candidate = GGOperationSummary(
            id: "op_1", kind: "reorder", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:persisted", "reorder"],
            stackName: "feature",
            touchedRemote: false, isUndoable: true
        )
        let later = GGOperationSummary(
            id: "op_2", kind: "restack", status: .completed, createdAtMs: 2,
            args: ["restack"], touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.markers.set(operationID: candidate.id, worktreeId: "wt")
        harness.service.operationLists = [[candidate], [later]]
        await harness.coordinator.restoreUndoCandidate(currentStackName: "feature")

        await #expect(throws: GGMutationError.staleConfirmation) {
            try await harness.coordinator.apply(.undo(operationID: candidate.id), confirmedAgainst: nil)
        }

        #expect(harness.service.requests.isEmpty)
        #expect(harness.coordinator.undoCandidate == nil)
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
    }

    @Test func undoRefusalSurfacesGGRecoveryHintWithoutFallbackRollback() async {
        let candidate = GGOperationSummary(
            id: "op_1", kind: "reorder", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:persisted", "reorder"],
            stackName: "feature",
            touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(stacks: [stack(head: "a")])
        harness.markers.set(operationID: candidate.id, worktreeId: "wt")
        harness.service.operationLists = [[candidate], [candidate], [candidate]]
        await harness.coordinator.restoreUndoCandidate(currentStackName: "feature")
        harness.service.error = GGServiceError.undoRefused(
            message: "This operation touched remote state.",
            hint: "Restore the affected branch manually."
        )

        await #expect(throws: GGServiceError.undoRefused(
            message: "This operation touched remote state.",
            hint: "Restore the affected branch manually."
        )) {
            try await harness.coordinator.apply(.undo(operationID: candidate.id), confirmedAgainst: nil)
        }

        #expect(harness.service.requests == [.undo(operationID: candidate.id)])
        #expect(harness.actionState.lastError == "This operation touched remote state.\nRestore the affected branch manually.")
        #expect(harness.coordinator.undoCandidate == GGUndoCandidate(operation: candidate))
        #expect(harness.markers.operationID(worktreeId: "wt") == candidate.id)
    }

    @Test func undoOfLastDroppedStackCommitRunsFromTheUndoLogWithoutACurrentStack() async throws {
        let candidate = GGOperationSummary(
            id: "op_drop", kind: "drop", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:persisted", "drop", "change-1"],
            stackName: "feature",
            touchedRemote: false, isUndoable: true
        )
        let noCurrentStack = GGStackSnapshot(version: 1, stack: nil)
        let harness = GGMutationHarness(stacks: [noCurrentStack])
        harness.markers.set(
            GGUndoMarker(operationID: candidate.id, removedFinalStackCommit: true),
            worktreeId: "wt"
        )
        harness.service.operationLists = [[candidate], [candidate]]
        await harness.coordinator.restoreUndoCandidate(currentStackName: "feature")

        try await harness.coordinator.apply(.undo(operationID: candidate.id), confirmedAgainst: nil)

        #expect(harness.service.requests == [.undo(operationID: candidate.id)])
        #expect(harness.coordinator.undoCandidate == nil)
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
    }

    @Test func completedUndoDoesNotClearNewerUndoCandidateAfterRefresh() async throws {
        let undoneOperation = GGOperationSummary(
            id: "op_undone", kind: "reorder", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:undone", "reorder"],
            stackName: "feature", touchedRemote: false, isUndoable: true
        )
        let newerOperation = GGOperationSummary(
            id: "op_newer", kind: "squash", status: .completed, createdAtMs: 2,
            args: ["--client-operation-id", "alas:test-1", "sc"],
            stackName: "feature", touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(
            stacks: [stack(head: "a")], supportsClientOperationID: true
        )
        harness.markers.set(operationID: undoneOperation.id, worktreeId: "wt")
        harness.service.operationLists = [
            [undoneOperation],
            [undoneOperation],
            [newerOperation],
        ]
        await harness.coordinator.restoreUndoCandidate(currentStackName: "feature")
        let refresh = FirstRefreshSuspension()
        harness.onRefreshStack = { await refresh.suspend() }

        let undoTask = try #require(harness.coordinator.startApplying(
            .undo(operationID: undoneOperation.id),
            confirmedAgainst: nil
        ))
        await refresh.waitUntilSuspended()

        try await harness.coordinator.apply(.amendCurrent, confirmedAgainst: nil)
        #expect(harness.coordinator.undoCandidate == GGUndoCandidate(operation: newerOperation))
        #expect(harness.markers.operationID(worktreeId: "wt") == newerOperation.id)

        await refresh.resume()
        try await undoTask.value

        #expect(harness.coordinator.undoCandidate == GGUndoCandidate(operation: newerOperation))
        #expect(harness.markers.operationID(worktreeId: "wt") == newerOperation.id)
    }

    @Test func lastDropPersistsNoStackEvidenceBeforeRefreshReconcilesUndo() async throws {
        let candidate = GGOperationSummary(
            id: "op_drop", kind: "drop", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:test-1", "drop", "change-1"],
            stackName: "feature",
            touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(
            stacks: [stack(head: "only")], supportsClientOperationID: true
        )
        harness.service.result = .drop(GGDropResult(
            dropped: [GGDropCommit(position: 1, sha: "only", title: "Only")],
            remaining: 0
        ))
        harness.service.operationLists = [[candidate], [candidate]]
        harness.onRefreshStack = {
            await harness.coordinator.restoreUndoCandidate(currentStackName: nil)
        }

        try await harness.coordinator.apply(.drop(target: "change-2"), confirmedAgainst: nil)

        #expect(harness.coordinator.undoCandidate == GGUndoCandidate(operation: candidate))
        #expect(harness.markers.marker(worktreeId: "wt") == GGUndoMarker(
            operationID: candidate.id, removedFinalStackCommit: true, branch: "feature"
        ))
        #expect(harness.service.requests == [.drop(target: "change-2")])
    }

    @Test func undoRejectsNewestOperationFromAnotherCurrentStack() async {
        let candidate = GGOperationSummary(
            id: "op_1", kind: "reorder", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:persisted", "reorder"],
            stackName: "feature",
            touchedRemote: false, isUndoable: true
        )
        let otherStack = GGStackSnapshot(
            version: 1,
            stack: GGStack(
                name: "other", base: "main", totalCommits: 1, syncedCommits: 0,
                currentPosition: 1, behindBase: 0,
                entries: [GGStackEntry(
                    position: 1, sha: "other-head", title: "Other",
                    ggId: "other-change", isCurrent: true
                )]
            )
        )
        let harness = GGMutationHarness(stacks: [otherStack])
        harness.markers.set(operationID: candidate.id, worktreeId: "wt")
        harness.service.operationLists = [[candidate], [candidate]]
        await harness.coordinator.restoreUndoCandidate(currentStackName: "feature")

        await #expect(throws: GGMutationError.staleConfirmation) {
            try await harness.coordinator.apply(.undo(operationID: candidate.id), confirmedAgainst: nil)
        }

        #expect(harness.service.requests.isEmpty)
        #expect(harness.coordinator.undoCandidate == nil)
        #expect(harness.markers.operationID(worktreeId: "wt") == nil)
    }

    @Test func undoWithoutACurrentStackRejectsOrdinaryDropWithoutFinalCommitEvidence() async {
        let candidate = GGOperationSummary(
            id: "op_1", kind: "drop", status: .completed, createdAtMs: 1,
            args: ["--client-operation-id", "alas:persisted", "drop", "change-1"],
            stackName: "feature",
            touchedRemote: false, isUndoable: true
        )
        let harness = GGMutationHarness(stacks: [GGStackSnapshot(version: 1, stack: nil)])
        harness.markers.set(operationID: candidate.id, worktreeId: "wt")
        harness.service.operationLists = [[candidate], [candidate]]
        await harness.coordinator.restoreUndoCandidate(currentStackName: "feature")

        await #expect(throws: GGMutationError.staleConfirmation) {
            try await harness.coordinator.apply(.undo(operationID: candidate.id), confirmedAgainst: nil)
        }

        #expect(harness.service.requests.isEmpty)
        #expect(harness.coordinator.undoCandidate == nil)
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

        #expect(harness.refreshes == [.gitChanges, .stack, .providerReviews, .inbox])
        #expect(harness.actionState.lastError == nil)
    }
}
