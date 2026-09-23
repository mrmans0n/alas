import Foundation
import Observation

struct RepoHookApprovalContext: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case sessionOpen
        case worktreeCreate
        case workspaceMember
    }

    let kind: Kind

    static let sessionOpen = Self(kind: .sessionOpen)
    static let worktreeCreate = Self(kind: .worktreeCreate)
    static let workspaceMember = Self(kind: .workspaceMember)

    var allowsCancel: Bool {
        kind == .sessionOpen
    }

    var skipTitle: String {
        switch kind {
        case .sessionOpen: "Continue without hook"
        case .worktreeCreate: "Finish without hook"
        case .workspaceMember: "Finish member without hook"
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
    let id: UUID
    let hook: RepoHook
    let context: RepoHookApprovalContext
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
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                entries.append(.init(
                    request: .init(id: id, hook: hook, context: context),
                    continuation: continuation
                ))
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
