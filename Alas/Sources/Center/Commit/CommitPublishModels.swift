import Foundation

enum DraftCommitPreferredAction: String, Codable, Equatable, Sendable {
    case commit
    case publish
}

enum CommitPublishPhase: String, Codable, Equatable, Sendable {
    case push
    case createReviewRequest
    case sync
}

struct CommitPublishReviewTarget: Codable, Equatable, Sendable {
    let provider: CodeHostKind
    let host: String
    let owner: String
    let repository: String
    let repositorySlug: String
    let remoteName: String
    let webURL: URL
    let branch: String
    let upstreamBranch: String?
    let headOwner: String?
    let baseBranch: String
    let reviewRequestExisted: Bool
    let createAsDraft: Bool

    var remote: CodeHostRemote {
        CodeHostRemote(
            kind: provider,
            host: host,
            owner: owner,
            repository: repository,
            remoteName: remoteName,
            webURL: webURL
        )
    }
}

enum CommitPublishDestination: Codable, Equatable, Sendable {
    case review(CommitPublishReviewTarget)
    case gg
}

struct CommitPublishCheckpoint: Codable, Equatable, Sendable {
    let commitSHA: String
    let baseRef: String
    let commitTitle: String
    let subject: String
    let body: String
    let destination: CommitPublishDestination
    var nextPhase: CommitPublishPhase
}
