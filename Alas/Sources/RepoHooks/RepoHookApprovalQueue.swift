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
        case failure(RepoHookFailure)
    }

    let id: UUID
    let content: Content
    let context: RepoHookApprovalContext

    var hook: RepoHook? {
        guard case let .hook(hook) = content else { return nil }
        return hook
    }

    var failure: RepoHookFailure? {
        guard case let .failure(failure) = content else { return nil }
        return failure
    }

    var event: RepoHookEvent {
        switch content {
        case let .hook(hook): hook.event
        case let .failure(failure): failure.event
        }
    }

    var source: RepoHookSource {
        switch content {
        case let .hook(hook): hook.source
        case let .failure(failure): failure.source
        }
    }
}

@MainActor
@Observable
final class RepoHookApprovalQueue {
    private struct Entry {
        let request: RepoHookApprovalRequest
        let continuation: CheckedContinuation<RepoHookApprovalDecision, Never>
    }

    private var entries: [Entry] = []

    var activeRequest: RepoHookApprovalRequest? {
        get { entries.first?.request }
        set {
            guard newValue == nil, entries.first?.request.context.allowsCancel == true else { return }
            decide(.cancel)
        }
    }

    func requestDecision(
        hook: RepoHook,
        context: RepoHookApprovalContext
    ) async -> RepoHookApprovalDecision {
        await requestDecision(.init(id: UUID(), content: .hook(hook), context: context))
    }

    func requestFailureDecision(
        failure: RepoHookFailure,
        context: RepoHookApprovalContext
    ) async -> RepoHookApprovalDecision {
        await requestDecision(.init(id: UUID(), content: .failure(failure), context: context))
    }

    private func requestDecision(_ request: RepoHookApprovalRequest) async -> RepoHookApprovalDecision {
        let id = request.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                entries.append(.init(request: request, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(id: id, decision: .cancel)
            }
        }
    }

    func decide(_ decision: RepoHookApprovalDecision) {
        guard let active = entries.first else { return }
        entries.removeFirst()
        active.continuation.resume(returning: decision)
    }

    private func resolve(id: UUID, decision: RepoHookApprovalDecision) {
        guard let index = entries.firstIndex(where: { $0.request.id == id }) else { return }
        let entry = entries.remove(at: index)
        entry.continuation.resume(returning: decision)
    }
}
