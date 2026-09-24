import Foundation

enum RepoHookPresentation: Equatable, Sendable {
    case approved(RepoHook)
    case approvalRequired(RepoHook)
    case unreadable(String)
    case notFound
    case checkAfterRepositoryAvailable

    static func make(
        result: RepoHookLoadResult?,
        isApproved: (String) -> Bool
    ) -> Self {
        guard let result else { return .checkAfterRepositoryAvailable }
        switch result {
        case .missing, .empty:
            return .notFound
        case let .loaded(hook):
            return isApproved(hook.hash) ? .approved(hook) : .approvalRequired(hook)
        case let .failed(_, message):
            return .unreadable(message)
        }
    }

    enum Action: Equatable, Sendable {
        case review
        case retry
    }

    func action(for mode: ProjectStartupScriptMode) -> Action? {
        switch self {
        case .approved:
            .review
        case .approvalRequired:
            mode.usesInheritedScripts ? .review : nil
        case .unreadable:
            mode.usesInheritedScripts ? .retry : nil
        case .notFound, .checkAfterRepositoryAvailable:
            nil
        }
    }

    var summary: String {
        switch self {
        case .approved:
            "Repository hook approved"
        case .approvalRequired:
            "Repository hook needs approval"
        case let .unreadable(message):
            "Repository hook unreadable: \(message)"
        case .notFound:
            "No repository hook found"
        case .checkAfterRepositoryAvailable:
            "Repository hook will be checked after the repository is available"
        }
    }
}
