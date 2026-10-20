import Foundation
import AlasFoundation

public enum CodeHostKind: String, Codable, Equatable, Sendable {
    case github
    case gitlab

    public var displayName: String {
        switch self {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        }
    }

    public var reviewRequestLabel: String {
        switch self {
        case .github: "PR"
        case .gitlab: "MR"
        }
    }

    public var reviewRequestNumberPrefix: String {
        switch self {
        case .github: "#"
        case .gitlab: "!"
        }
    }

    public var iconName: String {
        switch self {
        case .github: "github"
        case .gitlab: "gitlab"
        }
    }

    public var createReviewRequestTitle: String {
        "Create \(reviewRequestLabel)"
    }

    public var openReviewRequestTitle: String {
        "Open \(reviewRequestLabel)"
    }

    public var mergeReviewRequestTitle: String {
        "Merge \(reviewRequestLabel)"
    }
}
