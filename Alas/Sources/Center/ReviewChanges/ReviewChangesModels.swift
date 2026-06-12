import Foundation

typealias ReviewChangesFileID = DiffReviewFileID
typealias ReviewChangesFileStatus = DiffReviewFileStatus
typealias ReviewChangesFileSummary = DiffReviewFileSummary
typealias ReviewChangesFileSectionModel = DiffReviewFileSectionModel
typealias ReviewChangesSessionModel = DiffReviewSessionModel
typealias ReviewChangesSourceSection = DiffReviewSourceGroup
typealias ReviewChangesLoadedSession = DiffReviewLoadedSession
typealias ReviewChangesFileTreeNode = DiffReviewFileTreeNode
typealias ReviewChangesFileTreeBuilder = DiffReviewFileTreeBuilder

enum ReviewChangesSource: String, Codable, Equatable, Hashable, Comparable {
    case unstaged
    case staged

    var title: String {
        switch self {
        case .unstaged: "Unstaged"
        case .staged: "Staged"
        }
    }

    static func < (lhs: ReviewChangesSource, rhs: ReviewChangesSource) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    private var sortOrder: Int {
        switch self {
        case .unstaged: 0
        case .staged: 1
        }
    }
}

extension DiffReviewFileID {
    init(source: ReviewChangesSource, path: String) {
        self.init(namespace: source.rawValue, path: path)
    }
}

extension DiffReviewFileSummary {
    init(
        path: String,
        source: ReviewChangesSource,
        status: DiffReviewFileStatus,
        additions: Int,
        deletions: Int,
        isRenderable: Bool,
        originalPath: String? = nil
    ) {
        self.init(
            path: path,
            namespace: source.rawValue,
            groupID: source.rawValue,
            groupTitle: source.title,
            status: status,
            additions: additions,
            deletions: deletions,
            isRenderable: isRenderable,
            originalPath: originalPath
        )
    }

    var reviewChangesSource: ReviewChangesSource? {
        ReviewChangesSource(rawValue: namespace)
    }

    var source: ReviewChangesSource {
        guard let source = reviewChangesSource else {
            preconditionFailure("DiffReviewFileSummary namespace '\(namespace)' is not a Review Changes source")
        }
        return source
    }
}

extension DiffReviewSourceGroup {
    var source: ReviewChangesSource {
        guard let source = ReviewChangesSource(rawValue: id) else {
            preconditionFailure("DiffReviewSourceGroup id '\(id)' is not a Review Changes source")
        }
        return source
    }
}

extension DiffReviewSessionModel {
    init(files: [ReviewChangesFileSummary]) {
        self.init(files: files, groupsEnabled: true)
    }

    var sections: [DiffReviewSourceGroup] {
        groups
    }
}
