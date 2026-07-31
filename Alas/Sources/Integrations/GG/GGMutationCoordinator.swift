import Foundation
import Observation

@MainActor
struct GGMutationContext {
    var loadFreshStack: () async throws -> GGStackSnapshot
    var refreshStack: () async -> Void
    var refreshGitChanges: () async -> Void
    var refreshProviderReviews: () async -> Void
    var refreshProjectTopology: () async -> Void
    var worktreeExists: () -> Bool
    var invalidateInbox: () -> Void
    var selectWorktreeAtPath: (String) async -> Void
    /// The worktree's current branch, used to scope final-drop undo recovery.
    var currentBranch: () -> String?
}

enum GGMutationExecutionResult {
    case none
    case drop(GGDropResult)
    case land(GGLandResult)
    case unstack(GGUnstackResult)
    case split(GGSplitApplyResult)
}

@MainActor
protocol GGMutationExecuting {
    func execute(
        _ request: GGMutationRequest,
        worktreePath: String,
        clientOperationID: String?,
        supportsSyncJSONL: Bool,
        onSyncEvent: (GGSyncEvent) -> Void
    ) async throws -> GGMutationExecutionResult
    func listUndoOperations(worktreePath: String, limit: Int) async throws -> [GGOperationSummary]
    func previewRestack(worktreePath: String) async throws -> GGRestackResult
}

@MainActor
@Observable
final class GGMutationCoordinator {
    private let worktreeId: String
    private let worktreePath: String
    private let service: any GGMutationExecuting
    private let actionState: GGStackActionState
    private let undoMarkerStore: any GGUndoMarkerStoring
    private let clientOperationIDCapability: () -> Bool
    private let syncJSONLCapability: () -> Bool
    private let clientOperationIDGenerator: () -> String
    private let context: GGMutationContext

    private(set) var activeRequest: GGMutationRequest?
    private(set) var undoCandidate: GGUndoCandidate?

    var hasUndoStateToReconcile: Bool {
        undoCandidate != nil || undoMarkerStore.marker(worktreeId: worktreeId) != nil
    }

    init(
        worktreeId: String,
        worktreePath: String,
        service: any GGMutationExecuting,
        actionState: GGStackActionState,
        undoMarkerStore: any GGUndoMarkerStoring = GGUndoMarkerStore(),
        clientOperationIDCapability: @escaping () -> Bool = {
            GGAvailability.shared.capabilities.clientOperationID
        },
        syncJSONLCapability: @escaping () -> Bool = {
            GGAvailability.shared.capabilities.syncJSONL
        },
        clientOperationIDGenerator: @escaping () -> String = {
            "alas:\(UUID().uuidString)"
        },
        context: GGMutationContext
    ) {
        self.worktreeId = worktreeId
        self.worktreePath = worktreePath
        self.service = service
        self.actionState = actionState
        self.undoMarkerStore = undoMarkerStore
        self.clientOperationIDCapability = clientOperationIDCapability
        self.syncJSONLCapability = syncJSONLCapability
        self.clientOperationIDGenerator = clientOperationIDGenerator
        self.context = context
    }

    func prepare(_ request: GGMutationRequest) async throws -> GGPreparedMutation {
        guard activeRequest == nil else { throw GGMutationError.operationInFlight }
        activeRequest = request
        defer { activeRequest = nil }

        let snapshot = try await context.loadFreshStack()
        return try preflight(request, snapshot: snapshot)
    }

    func prepareRestackPreview() async throws -> GGPreparedRestack {
        guard activeRequest == nil else { throw GGMutationError.operationInFlight }
        activeRequest = .restack
        defer { activeRequest = nil }

        let before = try await context.loadFreshStack()
        let prepared = try preflight(.restack, snapshot: before)
        let plan = try await service.previewRestack(worktreePath: worktreePath)
        guard plan.dryRun, plan.stackName == prepared.snapshot.stackName else {
            throw GGServiceError.malformedOutput("gg returned a restack plan for a different stack.")
        }
        let after = try await context.loadFreshStack()
        guard after.identity == prepared.snapshot else {
            throw GGMutationError.staleConfirmation
        }
        return GGPreparedRestack(plan: plan, snapshot: prepared.snapshot)
    }

    func restoreUndoCandidate(currentStackName: String?) async {
        guard let marker = undoMarkerStore.marker(worktreeId: worktreeId) else {
            undoCandidate = nil
            return
        }
        guard currentStackName != nil || marker.removedFinalStackCommit else {
            undoCandidate = nil
            undoMarkerStore.clear(worktreeId: worktreeId)
            return
        }
        guard isRecoveryInScope(currentStackName: currentStackName, marker: marker) else {
            undoCandidate = nil
            undoMarkerStore.clear(worktreeId: worktreeId)
            return
        }
        do {
            let newest = try await service.listUndoOperations(worktreePath: worktreePath, limit: 1).first
            guard let newest,
                  newest.id == marker.operationID,
                  newest.matchesUndoScope(currentStackName: currentStackName, marker: marker),
                  newest.status == .completed,
                  newest.isUndoable,
                  !newest.touchedRemote,
                  !newest.isUndo,
                  newest.isSafeLocalRewrite,
                  newest.hasAlasClientOperationID
            else {
                undoCandidate = nil
                undoMarkerStore.clear(worktreeId: worktreeId)
                return
            }
            undoCandidate = GGUndoCandidate(operation: newest)
        } catch {
            undoCandidate = nil
        }
    }

    /// A final-drop recovery leaves the stack empty, so `currentStackName` is
    /// nil both on the branch where the drop happened and on any other branch
    /// the user later checks out. Scope it to the recorded branch so the
    /// recovery isn't offered (or run) against an unrelated branch. Markers
    /// without a recorded branch (legacy) keep the prior behavior.
    private func isRecoveryInScope(currentStackName: String?, marker: GGUndoMarker) -> Bool {
        guard currentStackName == nil, let markerBranch = marker.branch else { return true }
        return markerBranch == context.currentBranch()
    }

    func clearUndoCandidate() {
        undoCandidate = nil
        undoMarkerStore.clear(worktreeId: worktreeId)
    }

    func suspendUndoCandidate() {
        undoCandidate = nil
    }

    func apply(_ request: GGMutationRequest, confirmedAgainst identity: GGStackIdentity?) async throws {
        guard reserve(request) else { throw GGMutationError.operationInFlight }
        try await applyReserved(request, confirmedAgainst: identity, confirmedWith: nil)
    }

    func apply(_ prepared: GGPreparedMutation) async throws {
        guard reserve(prepared.request) else { throw GGMutationError.operationInFlight }
        try await applyReserved(
            prepared.request,
            confirmedAgainst: prepared.snapshot,
            confirmedWith: prepared.confirmation
        )
    }

    func startApplying(
        _ request: GGMutationRequest,
        confirmedAgainst identity: GGStackIdentity?
    ) -> Task<Void, Error>? {
        guard reserve(request) else { return nil }
        return Task { try await self.applyReserved(request, confirmedAgainst: identity, confirmedWith: nil) }
    }

    func startApplying(_ prepared: GGPreparedMutation) -> Task<Void, Error>? {
        guard reserve(prepared.request) else { return nil }
        return Task {
            try await self.applyReserved(
                prepared.request,
                confirmedAgainst: prepared.snapshot,
                confirmedWith: prepared.confirmation
            )
        }
    }

    private func reserve(_ request: GGMutationRequest) -> Bool {
        guard activeRequest == nil,
              actionState.beginAction(request.actionKind)
        else { return false }
        activeRequest = request
        return true
    }

    private func applyReserved(
        _ request: GGMutationRequest,
        confirmedAgainst identity: GGStackIdentity?,
        confirmedWith confirmation: GGMutationConfirmation?
    ) async throws {
        defer {
            activeRequest = nil
            actionState.endAction(request.actionKind)
        }

        actionState.clearError()
        if request == .sync { actionState.clearSyncProgress() }

        let isRecoveryRequest = request == .continueOperation || request == .abortOperation
        let snapshot: GGStackSnapshot?
        do {
            snapshot = try await context.loadFreshStack()
        } catch {
            guard isRecoveryRequest else { throw error }
            snapshot = nil
        }
        let continuedOperationID: String?
        switch request {
        case .continueOperation, .abortOperation:
            if let identity, snapshot?.identity != identity {
                throw GGMutationError.staleConfirmation
            }
            continuedOperationID = snapshot?.operationID
        case .undo:
            if let identity, snapshot?.identity != identity {
                throw GGMutationError.staleConfirmation
            }
            continuedOperationID = nil
        default:
            guard let snapshot else { throw GGMutationError.staleConfirmation }
            let prepared = try preflight(request, snapshot: snapshot)
            if let identity, prepared.snapshot != identity {
                throw GGMutationError.staleConfirmation
            }
            if let confirmation, prepared.confirmation != confirmation {
                throw GGMutationError.staleConfirmation
            }
            continuedOperationID = prepared.snapshot.operationID
        }
        try await validateUndoRequest(request, currentStackName: snapshot?.stack?.name)
        if !request.isUndo {
            undoCandidate = nil
            undoMarkerStore.clear(worktreeId: worktreeId)
        }

        let clientOperationID = request.generatesClientOperationID && clientOperationIDCapability()
            ? clientOperationIDGenerator()
            : nil
        GGStackGate.markAlasGGOperationInProgress(repoPath: worktreePath)

        do {
            let result = try await service.execute(
                request,
                worktreePath: worktreePath,
                clientOperationID: clientOperationID,
                supportsSyncJSONL: syncJSONLCapability(),
                onSyncEvent: { [actionState] event in
                    actionState.appendSyncEvent(event)
                    if case .error(_, _, let message) = event { actionState.setError(message) }
                }
            )
            await recordUndoMarker(
                after: request,
                result: result,
                clientOperationID: clientOperationID,
                continuedOperationID: continuedOperationID
            )
            recordSummary(for: request, result: result)
            reconcilePausedState(after: request, error: nil)
            await refresh(after: request, result: result)
            if request.isUndo {
                undoCandidate = nil
                undoMarkerStore.clear(worktreeId: worktreeId)
            }
        } catch let error as GGServiceError {
            reconcilePausedState(after: request, error: error)
            await refresh(after: request, result: .none)
            if request.touchesRemote, case .malformedOutput = error {
                return
            }
            if actionState.lastError == nil { actionState.setError(error.userMessage) }
            throw error
        } catch {
            reconcilePausedState(after: request, error: error)
            await refresh(after: request, result: .none)
            actionState.setError(error.localizedDescription)
            throw error
        }
    }

    private func preflight(
        _ request: GGMutationRequest,
        snapshot: GGStackSnapshot
    ) throws -> GGPreparedMutation {
        guard let stack = snapshot.stack, let identity = snapshot.identity else {
            throw GGMutationError.staleConfirmation
        }
        if snapshot.operationID != nil || actionState.pausedOperation != nil {
            switch request {
            case .continueOperation, .abortOperation:
                break
            default:
                throw GGMutationError.pausedOperation
            }
        }

        try validateTarget(for: request, stack: stack)
        try rejectKnownImmutableTarget(for: request, stack: stack)
        return GGPreparedMutation(
            request: request,
            snapshot: identity,
            confirmation: confirmation(for: request, stack: stack)
        )
    }

    private func validateTarget(for request: GGMutationRequest, stack: GGStack) throws {
        switch request {
        case .amendCurrent:
            guard stack.entries.contains(where: \.isCurrent) else {
                throw GGMutationError.staleConfirmation
            }
        case .checkout(let target), .drop(let target), .unstack(let target, _, _):
            guard stack.entry(matchingStableID: target) != nil else {
                throw GGMutationError.staleConfirmation
            }
        case .land(let target):
            guard let targetEntry = stack.entry(matchingStableID: target),
                  targetEntry.prState == .open,
                  targetEntry.approved,
                  targetEntry.ciStatus == nil || targetEntry.ciStatus == .success
            else { throw GGMutationError.staleConfirmation }
            let lowerEntriesAreReady = stack.entries
                .filter { $0.position < targetEntry.position }
                .allSatisfy {
                    $0.prState == .merged
                        || ($0.prState == .open
                            && $0.approved
                            && ($0.ciStatus == nil || $0.ciStatus == .success))
                }
            guard lowerEntriesAreReady else { throw GGMutationError.staleConfirmation }
        case .applySplit(_, let identity, _):
            let target = stack.splitTarget(matching: identity)
            guard target != nil else { throw GGMutationError.staleConfirmation }
        case .reorder(let order):
            let orderedEntries = stack.entries.sorted(by: { $0.position < $1.position })
            let exactIDs = orderedEntries.compactMap(\.ggId)
            guard exactIDs.count == stack.entries.count,
                  order.count == exactIDs.count,
                  Set(order).count == order.count,
                  Set(order) == Set(exactIDs)
            else { throw GGMutationError.staleConfirmation }
            for (index, id) in exactIDs.enumerated()
            where orderedEntries[index].prState == .merged && order[index] != id {
                throw GGMutationError.immutableTarget(
                    reason: "Merged commits must remain fixed while reordering."
                )
            }
            try validateReorderRegionMembership(
                originalIDs: exactIDs,
                submittedIDs: order,
                entries: orderedEntries
            )
        default:
            break
        }
    }

    private func validateReorderRegionMembership(
        originalIDs: [String],
        submittedIDs: [String],
        entries: [GGStackEntry]
    ) throws {
        var regionStart = 0
        for index in 0...entries.count {
            let isBoundary = index == entries.count || entries[index].prState == .merged
            guard isBoundary else { continue }
            if regionStart < index,
               Set(originalIDs[regionStart..<index]) != Set(submittedIDs[regionStart..<index]) {
                throw GGMutationError.immutableTarget(
                    reason: "Commits cannot move across an immutable boundary."
                )
            }
            regionStart = index + 1
        }
    }

    private func validateUndoRequest(
        _ request: GGMutationRequest,
        currentStackName: String?
    ) async throws {
        guard case .undo(let operationID) = request else { return }
        guard let marker = undoMarkerStore.marker(worktreeId: worktreeId),
              marker.operationID == operationID
        else {
            undoCandidate = nil
            undoMarkerStore.clear(worktreeId: worktreeId)
            throw GGMutationError.staleConfirmation
        }
        guard isRecoveryInScope(currentStackName: currentStackName, marker: marker) else {
            undoCandidate = nil
            undoMarkerStore.clear(worktreeId: worktreeId)
            throw GGMutationError.staleConfirmation
        }
        let newest = try await service.listUndoOperations(worktreePath: worktreePath, limit: 1).first
        guard let newest,
              newest.id == operationID,
              newest.matchesUndoScope(currentStackName: currentStackName, marker: marker),
              newest.status == .completed,
              newest.isUndoable,
              !newest.touchedRemote,
              !newest.isUndo,
              newest.isSafeLocalRewrite
        else {
            undoCandidate = nil
            undoMarkerStore.clear(worktreeId: worktreeId)
            throw GGMutationError.staleConfirmation
        }
    }

    private func rejectKnownImmutableTarget(for request: GGMutationRequest, stack: GGStack) throws {
        let target: GGStackEntry?
        switch request {
        case .amendCurrent:
            target = stack.entries.first(where: \.isCurrent)
        case .drop(let id), .unstack(let id, _, _):
            target = stack.entry(matchingStableID: id)
        case .applySplit(_, let identity, _):
            target = stack.splitTarget(matching: identity)
        default:
            target = nil
        }
        if target?.prState == .merged {
            throw GGMutationError.immutableTarget(reason: "Merged commits cannot be rewritten.")
        }
    }

    private func confirmation(for request: GGMutationRequest, stack: GGStack) -> GGMutationConfirmation? {
        switch request {
        case .drop(let target):
            guard let entry = stack.entry(matchingStableID: target) else { return nil }
            return .drop(
                target: target,
                rewrittenDescendants: stack.entries.filter { $0.position > entry.position }.count,
                hasOpenReview: entry.prState == .open || entry.prState == .draft
            )
        case .unstack(let target, let name, _):
            guard let entry = stack.entry(matchingStableID: target) else { return nil }
            return .unstack(
                target: target,
                targetTitle: entry.title,
                movedCommits: stack.entries.filter { $0.position >= entry.position }.count,
                lowerStack: stack.name,
                newStack: name
            )
        case .land(let target):
            guard let entry = stack.entry(matchingStableID: target) else { return nil }
            let count = stack.entries.filter {
                $0.position <= entry.position
                    && $0.prState == .open
                    && $0.approved
                    && ($0.ciStatus == nil || $0.ciStatus == .success)
            }.count
            return .land(target: target, readyCommits: count)
        case .clean:
            return .clean(mergedCommits: stack.entries.filter { $0.prState == .merged }.count)
        default:
            return nil
        }
    }

    private func refresh(after request: GGMutationRequest, result: GGMutationExecutionResult) async {
        if request == .clean {
            await context.refreshProjectTopology()
            if context.worktreeExists() {
                await context.refreshStack()
                await context.refreshGitChanges()
                await context.refreshProviderReviews()
            }
            context.invalidateInbox()
            return
        }

        await context.refreshStack()
        await context.refreshGitChanges()
        if request.touchesRemote {
            await context.refreshProviderReviews()
        }
        if request.changesStack || request.touchesRemote {
            context.invalidateInbox()
        }
        if request.refreshesTopology {
            await context.refreshProjectTopology()
            if case .unstack(let unstack) = result, let path = unstack.worktreePath {
                await context.selectWorktreeAtPath(path)
            }
        }
    }

    private func reconcilePausedState(after request: GGMutationRequest, error: Error?) {
        let existingRecoveryPause: GGPausedOperation?
        switch request {
        case .continueOperation, .abortOperation:
            existingRecoveryPause = actionState.pausedOperation
        default:
            existingRecoveryPause = nil
        }
        let pausedByError: Bool
        if let serviceError = error as? GGServiceError, case .pausedConflict = serviceError {
            pausedByError = true
        } else {
            pausedByError = false
        }
        if pausedByError
            || GGStackGate.operationInProgress(repoPath: worktreePath)
            || (error != nil && existingRecoveryPause != nil)
        {
            actionState.setPaused(existingRecoveryPause ?? GGPausedOperation(pausedBy: request.actionKind))
        } else {
            actionState.clearPaused()
            GGStackGate.clearAlasGGOperationInProgress(repoPath: worktreePath)
        }
    }

    private func recordSummary(for request: GGMutationRequest, result: GGMutationExecutionResult) {
        switch result {
        case .land(let result):
            if let summary = GGStackActionState.landSummaryLine(from: result.landed) {
                actionState.setActionSummary(summary)
            }
        case .unstack(let result) where result.worktreePath == nil:
            precondition(
                result.currentStack == result.originalStack,
                "Unstack without a worktree must keep the current lower stack checked out."
            )
            actionState.setActionSummary("New stack created without a worktree")
        default:
            if request == .sync,
               actionState.lastError == nil,
               let summary = GGStackActionState.syncSummaryLine(from: actionState.syncProgress) {
                actionState.setActionSummary(summary)
                actionState.clearSyncProgress()
            }
        }
    }

    private func recordUndoMarker(
        after request: GGMutationRequest,
        result: GGMutationExecutionResult,
        clientOperationID: String?,
        continuedOperationID: String?
    ) async {
        guard request.recordsUndoCandidate else { return }

        let matchesRequest: (GGOperationSummary) -> Bool
        if request == .continueOperation {
            guard let continuedOperationID else { return }
            matchesRequest = {
                $0.id == continuedOperationID && $0.hasAlasClientOperationID
            }
        } else {
            guard let clientOperationID else { return }
            matchesRequest = { $0.hasClientOperationID(clientOperationID) }
        }

        guard let newest = (try? await service.listUndoOperations(
                  worktreePath: worktreePath,
                  limit: 1
              ))?.first,
              newest.stackName != nil,
              newest.status == .completed,
              newest.isUndoable,
              !newest.touchedRemote,
              !newest.isUndo,
              newest.isSafeLocalRewrite
        else { return }
        guard matchesRequest(newest) else { return }

        let removedFinalStackCommit = if case .drop(let drop) = result {
            drop.remaining == 0
        } else {
            false
        }
        undoMarkerStore.set(
            GGUndoMarker(
                operationID: newest.id,
                removedFinalStackCommit: removedFinalStackCommit,
                branch: context.currentBranch()
            ),
            worktreeId: worktreeId
        )
        undoCandidate = GGUndoCandidate(operation: newest)
    }
}

private extension GGMutationRequest {
    var isUndo: Bool {
        if case .undo = self { return true }
        return false
    }

    var touchesRemote: Bool {
        switch self {
        case .sync, .land, .clean: true
        default: false
        }
    }

    var changesStack: Bool {
        switch self {
        case .checkout: false
        default: true
        }
    }

    var refreshesTopology: Bool {
        switch self {
        case .clean: true
        case .unstack(_, _, let createWorktree): createWorktree
        default: false
        }
    }

    var recordsUndoCandidate: Bool {
        switch self {
        case .amendCurrent, .absorbStaged, .drop, .reorder, .restack,
             .rebase, .continueOperation, .applySplit:
            true
        default:
            false
        }
    }

    var generatesClientOperationID: Bool {
        switch self {
        case .amendCurrent, .absorbStaged, .drop, .reorder, .restack,
             .rebase, .applySplit:
            true
        default:
            false
        }
    }
}

private extension GGStack {
    func entry(matchingStableID target: String) -> GGStackEntry? {
        entries.first { $0.id == target || $0.sha == target }
    }

    func splitTarget(matching identity: GGSplitTargetIdentity) -> GGStackEntry? {
        if let ggID = identity.ggID {
            return entry(matchingStableID: ggID)
        }
        return entry(matchingCommitSHA: identity.sha)
    }
}

extension GGService: GGMutationExecuting {
    func execute(
        _ request: GGMutationRequest,
        worktreePath: String,
        clientOperationID: String?,
        supportsSyncJSONL: Bool,
        onSyncEvent: (GGSyncEvent) -> Void
    ) async throws -> GGMutationExecutionResult {
        let service = clientOperationID.map {
            GGService(runner: GGClientOperationRunner(base: runner, clientOperationID: $0))
        } ?? self
        switch request {
        case .amendCurrent:
            try await service.amendCurrent(worktreePath: worktreePath)
        case .absorbStaged:
            try await service.absorbStaged(worktreePath: worktreePath)
        case .checkout(let target):
            try await service.checkout(worktreePath: worktreePath, target: target)
        case .drop(let target):
            return .drop(try await service.drop(worktreePath: worktreePath, target: target))
        case .unstack(let target, let name, let createWorktree):
            return .unstack(try await service.unstack(
                worktreePath: worktreePath,
                target: target,
                name: name,
                createWorktree: createWorktree
            ))
        case .reorder(let order):
            try await service.reorder(worktreePath: worktreePath, order: order)
        case .restack:
            _ = try await service.restack(worktreePath: worktreePath, dryRun: false)
        case .rebase(let target):
            try await service.rebase(worktreePath: worktreePath, target: target)
        case .sync:
            for try await event in service.sync(
                worktreePath: worktreePath,
                supportsJSONL: supportsSyncJSONL
            ) {
                onSyncEvent(event)
            }
        case .land(let target):
            return .land(try await service.land(worktreePath: worktreePath, until: target))
        case .clean:
            try await service.clean(worktreePath: worktreePath)
        case .continueOperation:
            try await service.continueOp(worktreePath: worktreePath)
        case .abortOperation:
            try await service.abortOp(worktreePath: worktreePath)
        case .undo(let operationID):
            _ = try await service.undo(worktreePath: worktreePath, operationID: operationID)
        case .applySplit(let planURL, _, _):
            return .split(try await service.applySplit(worktreePath: worktreePath, planURL: planURL))
        }
        return .none
    }

    func previewRestack(worktreePath: String) async throws -> GGRestackResult {
        try await restack(worktreePath: worktreePath, dryRun: true)
    }
}

private struct GGClientOperationRunner: GGCommandRunning {
    let base: any GGCommandRunning
    let clientOperationID: String

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        try await base.run(
            args: ["--client-operation-id", clientOperationID] + args,
            cwd: cwd
        )
    }

    func runStreaming(args: [String], cwd: URL?) -> AsyncThrowingStream<String, Error> {
        base.runStreaming(
            args: ["--client-operation-id", clientOperationID] + args,
            cwd: cwd
        )
    }
}

private extension GGOperationSummary {
    func matchesUndoScope(currentStackName: String?, marker: GGUndoMarker) -> Bool {
        if let currentStackName {
            return stackName == currentStackName
        }
        return marker.removedFinalStackCommit && kind == "drop" && stackName != nil
    }

    var isSafeLocalRewrite: Bool {
        switch kind {
        case "squash", "absorb", "drop", "reorder", "restack", "rebase", "split":
            true
        default:
            false
        }
    }

    func hasClientOperationID(_ clientOperationID: String) -> Bool {
        guard args.count >= 2 else { return false }
        return args.indices.dropLast().contains { index in
            args[index] == "--client-operation-id" && args[index + 1] == clientOperationID
        }
    }

    var hasAlasClientOperationID: Bool {
        guard args.count >= 2 else { return false }
        return args.indices.dropLast().contains { index in
            args[index] == "--client-operation-id" && args[index + 1].hasPrefix("alas:")
        }
    }
}
