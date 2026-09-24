import Foundation
import Observation

struct RepoHookApprovalContext: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case sessionOpen
        case worktreeCreate
        case workspaceMember
        case projectSettings

        func coalescingKind(for event: RepoHookEvent) -> Self {
            switch self {
            case .workspaceMember:
                .worktreeCreate
            case .projectSettings:
                switch event {
                case .sessionOpen: .sessionOpen
                case .worktreeCreate: .worktreeCreate
                }
            case .sessionOpen, .worktreeCreate:
                self
            }
        }
    }

    let kind: Kind

    static let sessionOpen = Self(kind: .sessionOpen)
    static let worktreeCreate = Self(kind: .worktreeCreate)
    static let workspaceMember = Self(kind: .workspaceMember)
    static let projectSettings = Self(kind: .projectSettings)

    var allowsCancel: Bool {
        kind == .sessionOpen || kind == .projectSettings
    }

    var skipTitle: String {
        switch kind {
        case .sessionOpen: "Continue without hook"
        case .worktreeCreate: "Finish without hook"
        case .workspaceMember: "Finish member without hook"
        case .projectSettings: "Not now"
        }
    }
}

enum RepoHookApprovalDecision: Equatable, Sendable {
    case approve
    case skip
    case retry
    case cancel
}

struct RepoHookApprovalRequest: Identifiable, Equatable {
    enum Content: Equatable {
        case hook(RepoHook)
        case review(RepoHook)
        case failure(RepoHookFailure)
    }

    let id: UUID
    let content: Content
    let context: RepoHookApprovalContext

    var hook: RepoHook? {
        switch content {
        case let .hook(hook), let .review(hook): hook
        case .failure: nil
        }
    }

    var isReadOnlyReview: Bool {
        if case .review = content { true } else { false }
    }

    var failure: RepoHookFailure? {
        guard case let .failure(failure) = content else { return nil }
        return failure
    }

    var event: RepoHookEvent {
        switch content {
        case let .hook(hook), let .review(hook): hook.event
        case let .failure(failure): failure.event
        }
    }

    var source: RepoHookSource {
        switch content {
        case let .hook(hook), let .review(hook): hook.source
        case let .failure(failure): failure.source
        }
    }
}

@MainActor
@Observable
final class RepoHookApprovalQueue {
    private struct CoalescingKey: Equatable {
        let projectID: String
        let event: RepoHookEvent
        let hash: String
        let context: RepoHookApprovalContext.Kind
    }

    private struct Waiter {
        let id: UUID
        let request: RepoHookApprovalRequest
        let continuation: CheckedContinuation<RepoHookApprovalDecision, Never>
    }

    private struct Entry {
        let coalescingKey: CoalescingKey?
        var waiters: [Waiter]
    }
    var activeRequest: RepoHookApprovalRequest? {
        get { entries.first?.waiters.first?.request }
        set {
            guard newValue == nil, entries.first?.waiters.first?.request.context.allowsCancel == true else { return }
            decide(.cancel)
        }
    }

    private var entries: [Entry] = []
    private var dialogPresenterIDs = Set<UUID>()

    private var hasDialogPresenter: Bool {
        !dialogPresenterIDs.isEmpty
    }

    func registerDialogPresenter(id: UUID) {
        _ = dialogPresenterIDs.insert(id)
    }

    func unregisterDialogPresenter(id: UUID) {
        _ = dialogPresenterIDs.remove(id)
    }

    var activeRuntimeRequest: RepoHookApprovalRequest? {
        get {
            guard !hasDialogPresenter,
                  let request = activeRequest,
                  request.context.kind != .projectSettings else {
                return nil
            }
            return request
        }
        set {
            guard !hasDialogPresenter,
                  newValue == nil,
                  let activeRequest,
                  activeRequest.context.kind != .projectSettings
            else {
                return
            }
            self.activeRequest = nil
        }
    }

    var activeDialogRequest: RepoHookApprovalRequest? {
        get {
            guard hasDialogPresenter else { return nil }
            return activeRequest
        }
        set {
            guard hasDialogPresenter, newValue == nil else { return }
            self.activeRequest = nil
        }
    }

    func requestDecision(
        hook: RepoHook,
        projectID: String,
        context: RepoHookApprovalContext
    ) async -> RepoHookApprovalDecision {
        await requestDecision(
            .init(id: UUID(), content: .hook(hook), context: context),
            coalescingKey: .init(
                projectID: projectID,
                event: hook.event,
                hash: hook.hash,
                context: context.kind.coalescingKind(for: hook.event)
            )
        )
    }

    func requestFailureDecision(
        failure: RepoHookFailure,
        context: RepoHookApprovalContext
    ) async -> RepoHookApprovalDecision {
        await requestDecision(
            .init(id: UUID(), content: .failure(failure), context: context),
            coalescingKey: nil
        )
    }

    func requestReview(hook: RepoHook) async {
        _ = await requestDecision(
            .init(id: UUID(), content: .review(hook), context: .projectSettings),
            coalescingKey: nil
        )
    }

    private func requestDecision(
        _ request: RepoHookApprovalRequest,
        coalescingKey: CoalescingKey?
    ) async -> RepoHookApprovalDecision {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let waiter = Waiter(id: waiterID, request: request, continuation: continuation)
                if let coalescingKey,
                   let index = entries.firstIndex(where: { $0.coalescingKey == coalescingKey }) {
                    entries[index].waiters.append(waiter)
                } else {
                    entries.append(.init(coalescingKey: coalescingKey, waiters: [waiter]))
                }
                if Task.isCancelled {
                    resolve(waiterID: waiterID, decision: .cancel)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(waiterID: waiterID, decision: .cancel)
            }
        }
    }

    func decide(_ decision: RepoHookApprovalDecision) {
        guard !entries.isEmpty else { return }
        // Approval trusts matching contents across actions; skip and cancel affect only one waiter.
        if decision == .approve {
            let active = entries.removeFirst()
            for waiter in active.waiters {
                waiter.continuation.resume(returning: decision)
            }
            return
        }

        let waiter = entries[0].waiters.removeFirst()
        if entries[0].waiters.isEmpty {
            entries.removeFirst()
        }
        waiter.continuation.resume(returning: decision)
    }

    private func resolve(waiterID: UUID, decision: RepoHookApprovalDecision) {
        guard let entryIndex = entries.firstIndex(where: { entry in
            entry.waiters.contains(where: { $0.id == waiterID })
        }),
            let waiterIndex = entries[entryIndex].waiters.firstIndex(where: { $0.id == waiterID })
        else {
            return
        }

        let waiter = entries[entryIndex].waiters.remove(at: waiterIndex)
        if entries[entryIndex].waiters.isEmpty {
            entries.remove(at: entryIndex)
        }
        waiter.continuation.resume(returning: decision)
    }
}
