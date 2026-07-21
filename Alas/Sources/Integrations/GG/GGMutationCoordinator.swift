import Foundation

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
}

enum GGMutationExecutionResult {
    case none
    case drop(GGDropResult)
    case land(GGLandResult)
    case unstack(GGUnstackResult)
    case split(GGSplitApplyResult)
}

private enum GGUndoBaseline {
    case unavailable
    case operationID(String?)
}

@MainActor
protocol GGMutationExecuting {
    func execute(
        _ request: GGMutationRequest,
        worktreePath: String,
        onSyncEvent: (GGSyncEvent) -> Void
    ) async throws -> GGMutationExecutionResult
    func listUndoOperations(worktreePath: String, limit: Int) async throws -> [GGOperationSummary]
}

@MainActor
final class GGMutationCoordinator {
    private let worktreeId: String
    private let worktreePath: String
    private let service: any GGMutationExecuting
    private let actionState: GGStackActionState
    private let undoMarkerStore: any GGUndoMarkerStoring
    private let context: GGMutationContext

    private(set) var activeRequest: GGMutationRequest?

    init(
        worktreeId: String,
        worktreePath: String,
        service: any GGMutationExecuting,
        actionState: GGStackActionState,
        undoMarkerStore: any GGUndoMarkerStoring = GGUndoMarkerStore(),
        context: GGMutationContext
    ) {
        self.worktreeId = worktreeId
        self.worktreePath = worktreePath
        self.service = service
        self.actionState = actionState
        self.undoMarkerStore = undoMarkerStore
        self.context = context
    }

    func prepare(_ request: GGMutationRequest) async throws -> GGPreparedMutation {
        guard activeRequest == nil else { throw GGMutationError.operationInFlight }
        activeRequest = request
        defer { activeRequest = nil }

        let snapshot = try await context.loadFreshStack()
        return try preflight(request, snapshot: snapshot)
    }

    func apply(_ request: GGMutationRequest, confirmedAgainst identity: GGStackIdentity?) async throws {
        guard reserve(request) else { throw GGMutationError.operationInFlight }
        try await applyReserved(request, confirmedAgainst: identity)
    }

    func startApplying(
        _ request: GGMutationRequest,
        confirmedAgainst identity: GGStackIdentity?
    ) -> Task<Void, Error>? {
        guard reserve(request) else { return nil }
        return Task { try await self.applyReserved(request, confirmedAgainst: identity) }
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
        confirmedAgainst identity: GGStackIdentity?
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

        if isRecoveryRequest {
            if let identity, snapshot?.identity != identity {
                throw GGMutationError.staleConfirmation
            }
        } else {
            guard let snapshot else { throw GGMutationError.staleConfirmation }
            let prepared = try preflight(request, snapshot: snapshot)
            if let identity, prepared.snapshot != identity {
                throw GGMutationError.staleConfirmation
            }
        }

        let undoBaseline = isRecoveryRequest
            ? GGUndoBaseline.unavailable
            : await captureUndoBaseline(for: request)
        undoMarkerStore.clear(worktreeId: worktreeId)
        GGStackGate.markAlasGGOperationInProgress(repoPath: worktreePath)

        do {
            let result = try await service.execute(
                request,
                worktreePath: worktreePath,
                onSyncEvent: { [actionState] event in
                    actionState.appendSyncEvent(event)
                    if case .error(let message) = event { actionState.setError(message) }
                }
            )
            recordSummary(for: request, result: result)
            reconcilePausedState(after: request, error: nil)
            await refresh(after: request, result: result)
            await recordUndoMarker(after: request, baseline: undoBaseline)
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
            let target = identity.ggID.flatMap { stack.entry(matchingStableID: $0) }
                ?? stack.entry(matchingStableID: identity.sha)
            guard target != nil else { throw GGMutationError.staleConfirmation }
        default:
            break
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
            target = identity.ggID.flatMap { stack.entry(matchingStableID: $0) }
                ?? stack.entry(matchingStableID: identity.sha)
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
        default:
            if request == .sync,
               actionState.lastError == nil,
               let summary = GGStackActionState.syncSummaryLine(from: actionState.syncProgress) {
                actionState.setActionSummary(summary)
                actionState.clearSyncProgress()
            }
        }
    }

    private func captureUndoBaseline(for request: GGMutationRequest) async -> GGUndoBaseline {
        guard !request.touchesRemote else { return .unavailable }
        do {
            let operationID = try await service.listUndoOperations(worktreePath: worktreePath, limit: 1).first?.id
            return .operationID(operationID)
        } catch {
            return .unavailable
        }
    }

    private func recordUndoMarker(after request: GGMutationRequest, baseline: GGUndoBaseline) async {
        guard !request.touchesRemote,
              case .operationID(let previousOperationID) = baseline,
              let newest = (try? await service.listUndoOperations(worktreePath: worktreePath, limit: 1))?.first,
              newest.id != previousOperationID,
              newest.status == .completed,
              newest.isUndoable,
              !newest.touchedRemote
        else { return }
        undoMarkerStore.set(operationID: newest.id, worktreeId: worktreeId)
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
}

private extension GGStack {
    func entry(matchingStableID target: String) -> GGStackEntry? {
        entries.first { $0.id == target || $0.sha == target }
    }
}

extension GGService: GGMutationExecuting {
    func execute(
        _ request: GGMutationRequest,
        worktreePath: String,
        onSyncEvent: (GGSyncEvent) -> Void
    ) async throws -> GGMutationExecutionResult {
        switch request {
        case .amendCurrent:
            try await amendCurrent(worktreePath: worktreePath)
        case .absorbStaged:
            try await absorbStaged(worktreePath: worktreePath)
        case .checkout(let target):
            try await checkout(worktreePath: worktreePath, target: target)
        case .drop(let target):
            _ = try await drop(worktreePath: worktreePath, target: target)
        case .unstack(let target, let name, let createWorktree):
            return .unstack(try await unstack(
                worktreePath: worktreePath,
                target: target,
                name: name,
                createWorktree: createWorktree
            ))
        case .reorder(let order):
            try await reorder(worktreePath: worktreePath, order: order)
        case .restack:
            _ = try await restack(worktreePath: worktreePath, dryRun: false)
        case .rebase(let target):
            try await rebase(worktreePath: worktreePath, target: target)
        case .sync:
            for try await event in sync(worktreePath: worktreePath) { onSyncEvent(event) }
        case .land(let target):
            return .land(try await land(worktreePath: worktreePath, until: target))
        case .clean:
            try await clean(worktreePath: worktreePath)
        case .continueOperation:
            try await continueOp(worktreePath: worktreePath)
        case .abortOperation:
            try await abortOp(worktreePath: worktreePath)
        case .undo(let operationID):
            _ = try await undo(worktreePath: worktreePath, operationID: operationID)
        case .applySplit(let planURL, _, _):
            return .split(try await applySplit(worktreePath: worktreePath, planURL: planURL))
        }
        return .none
    }
}
