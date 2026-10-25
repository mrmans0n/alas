import Foundation
import Observation
import AlasFoundation
import AlasModel

public struct RepoHookApprovalContext: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case sessionOpen
        case worktreeCreate
        /// A paired Mac asks before creating a worktree here. Nothing exists
        /// yet, so unlike `worktreeCreate` the user can abandon the request.
        case peerWorktreeCreate
        case workspaceMember
        case projectSettings

        public func coalescingKind(for event: RepoHookEvent) -> Self {
            switch self {
            case .workspaceMember:
                .worktreeCreate
            case .projectSettings:
                switch event {
                case .sessionOpen: .sessionOpen
                case .worktreeCreate: .worktreeCreate
                }
            case .sessionOpen, .worktreeCreate, .peerWorktreeCreate:
                self
            }
        }
    }

    public let kind: Kind

    public static let sessionOpen = Self(kind: .sessionOpen)
    public static let worktreeCreate = Self(kind: .worktreeCreate)
    public static let peerWorktreeCreate = Self(kind: .peerWorktreeCreate)
    public static let workspaceMember = Self(kind: .workspaceMember)
    public static let projectSettings = Self(kind: .projectSettings)

    public var allowsCancel: Bool {
        kind == .sessionOpen || kind == .peerWorktreeCreate || kind == .projectSettings
    }

    public var skipTitle: String {
        switch kind {
        case .sessionOpen: "Continue without hook"
        case .worktreeCreate, .peerWorktreeCreate: "Finish without hook"
        case .workspaceMember: "Finish member without hook"
        case .projectSettings: "Not now"
        }
    }

    public init(kind: Kind) {
        self.kind = kind
    }
}

public enum RepoHookApprovalDecision: Equatable, Sendable {
    case approve
    case skip
    case retry
    case cancel
}

public struct RepoHookApprovalRequest: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case hook(RepoHook)
        case review(RepoHook)
        case failure(RepoHookFailure)
    }

    public let id: UUID
    public let content: Content
    public let context: RepoHookApprovalContext

    public var hook: RepoHook? {
        switch content {
        case let .hook(hook), let .review(hook): hook
        case .failure: nil
        }
    }

    public var isReadOnlyReview: Bool {
        if case .review = content { true } else { false }
    }

    public var failure: RepoHookFailure? {
        guard case let .failure(failure) = content else { return nil }
        return failure
    }

    public var event: RepoHookEvent {
        switch content {
        case let .hook(hook), let .review(hook): hook.event
        case let .failure(failure): failure.event
        }
    }

    public var source: RepoHookSource {
        switch content {
        case let .hook(hook), let .review(hook): hook.source
        case let .failure(failure): failure.source
        }
    }

    public init(id: UUID, content: Content, context: RepoHookApprovalContext) {
        self.id = id
        self.content = content
        self.context = context
    }
}

@MainActor
@Observable
public final class RepoHookApprovalQueue {
    private struct CoalescingKey: Equatable {
        let projectID: String
        let event: RepoHookEvent
        let hash: String
        let context: RepoHookApprovalContext.Kind

        public init(projectID: String, event: RepoHookEvent, hash: String, context: RepoHookApprovalContext.Kind) {
            self.projectID = projectID
            self.event = event
            self.hash = hash
            self.context = context
        }
    }

    private struct Waiter {
        let id: UUID
        let request: RepoHookApprovalRequest
        let continuation: CheckedContinuation<RepoHookApprovalDecision, Never>

        public init(id: UUID, request: RepoHookApprovalRequest, continuation: CheckedContinuation<RepoHookApprovalDecision, Never>) {
            self.id = id
            self.request = request
            self.continuation = continuation
        }
    }

    private struct Entry {
        let coalescingKey: CoalescingKey?
        var waiters: [Waiter]

        public init(coalescingKey: CoalescingKey?, waiters: [Waiter]) {
            self.coalescingKey = coalescingKey
            self.waiters = waiters
        }
    }
    public var activeRequest: RepoHookApprovalRequest? {
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

    public func registerDialogPresenter(id: UUID) {
        _ = dialogPresenterIDs.insert(id)
    }

    public func unregisterDialogPresenter(id: UUID) {
        _ = dialogPresenterIDs.remove(id)
    }

    public var activeRuntimeRequest: RepoHookApprovalRequest? {
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

    public var activeDialogRequest: RepoHookApprovalRequest? {
        get {
            guard hasDialogPresenter else { return nil }
            return activeRequest
        }
        set {
            guard hasDialogPresenter, newValue == nil else { return }
            self.activeRequest = nil
        }
    }

    public func requestDecision(
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

    public func requestFailureDecision(
        failure: RepoHookFailure,
        context: RepoHookApprovalContext
    ) async -> RepoHookApprovalDecision {
        await requestDecision(
            .init(id: UUID(), content: .failure(failure), context: context),
            coalescingKey: nil
        )
    }

    public func requestReview(hook: RepoHook) async {
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

    public func decide(_ decision: RepoHookApprovalDecision) {
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

    public init() {}
}
