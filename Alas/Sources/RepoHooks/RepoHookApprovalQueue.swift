import Foundation
import Observation

struct RepoHookApprovalContext: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case sessionOpen
        case worktreeCreate
        case workspaceMember
        case projectSettings
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

    private struct Entry {
        let request: RepoHookApprovalRequest
        let coalescingKey: CoalescingKey?
        var waiters: [UUID: CheckedContinuation<RepoHookApprovalDecision, Never>]
    }

    private var entries: [Entry] = []
    private var projectDialogPresenterIDs = Set<UUID>()

    private var hasProjectDialogPresenter: Bool {
        !projectDialogPresenterIDs.isEmpty
    }

    func registerProjectDialogPresenter(id: UUID) {
        _ = projectDialogPresenterIDs.insert(id)
    }

    func unregisterProjectDialogPresenter(id: UUID) {
        _ = projectDialogPresenterIDs.remove(id)
    }

    var activeRequest: RepoHookApprovalRequest? {
        get { entries.first?.request }
        set {
            guard newValue == nil, entries.first?.request.context.allowsCancel == true else { return }
            decide(.cancel)
        }
    }

    var activeRuntimeRequest: RepoHookApprovalRequest? {
        get {
            guard !hasProjectDialogPresenter,
                  let request = activeRequest,
                  request.context.kind != .projectSettings else {
                return nil
            }
            return request
        }
        set {
            guard !hasProjectDialogPresenter,
                  newValue == nil,
                  let activeRequest,
                  activeRequest.context.kind != .projectSettings
            else {
                return
            }
            self.activeRequest = nil
        }
    }

    var activeProjectDialogRequest: RepoHookApprovalRequest? {
        get {
            guard hasProjectDialogPresenter else { return nil }
            return activeRequest
        }
        set {
            guard hasProjectDialogPresenter, newValue == nil else { return }
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
                context: context.kind
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
                if let coalescingKey,
                   let index = entries.firstIndex(where: { $0.coalescingKey == coalescingKey }) {
                    entries[index].waiters[waiterID] = continuation
                } else {
                    entries.append(.init(
                        request: request,
                        coalescingKey: coalescingKey,
                        waiters: [waiterID: continuation]
                    ))
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
        let active = entries.removeFirst()
        for continuation in active.waiters.values {
            continuation.resume(returning: decision)
        }
    }

    private func resolve(waiterID: UUID, decision: RepoHookApprovalDecision) {
        guard let index = entries.firstIndex(where: { $0.waiters.keys.contains(waiterID) }),
              let continuation = entries[index].waiters.removeValue(forKey: waiterID)
        else {
            return
        }
        if entries[index].waiters.isEmpty {
            entries.remove(at: index)
        }
        continuation.resume(returning: decision)
    }
}
