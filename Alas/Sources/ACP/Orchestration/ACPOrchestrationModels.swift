import Foundation

enum ACPDelegatedWorktreeRequest: Codable, Equatable, Sendable {
    case current(worktreeId: String)
    case existing(worktreeId: String)
    case new(branch: String, base: String?, destinationPath: String, optimisticId: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case worktreeId
        case branch
        case base
        case destinationPath
        case optimisticId
    }

    private enum Kind: String, Codable {
        case current
        case existing
        case new
    }

    var worktreeId: String? {
        switch self {
        case .current(let id), .existing(let id): id
        case .new(_, _, _, let id): id
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .current:
            self = .current(worktreeId: try container.decode(String.self, forKey: .worktreeId))
        case .existing:
            self = .existing(worktreeId: try container.decode(String.self, forKey: .worktreeId))
        case .new:
            self = .new(
                branch: try container.decode(String.self, forKey: .branch),
                base: try container.decodeIfPresent(String.self, forKey: .base),
                destinationPath: try container.decode(String.self, forKey: .destinationPath),
                optimisticId: try container.decode(String.self, forKey: .optimisticId)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .current(let worktreeId):
            try container.encode(Kind.current, forKey: .kind)
            try container.encode(worktreeId, forKey: .worktreeId)
        case .existing(let worktreeId):
            try container.encode(Kind.existing, forKey: .kind)
            try container.encode(worktreeId, forKey: .worktreeId)
        case .new(let branch, let base, let destinationPath, let optimisticId):
            try container.encode(Kind.new, forKey: .kind)
            try container.encode(branch, forKey: .branch)
            try container.encodeIfPresent(base, forKey: .base)
            try container.encode(destinationPath, forKey: .destinationPath)
            try container.encode(optimisticId, forKey: .optimisticId)
        }
    }
}

enum ACPDelegationPhase: String, Codable, Equatable, Sendable {
    case creatingWorktree
    case starting
    case ready
    case failed
    case closed
}

struct ACPDelegationRecord: Equatable, Sendable {
    let childSessionId: String
    let parentSessionId: String
    let projectId: String
    let parentWorktreeId: String
    var childWorktreeId: String?
    let agentId: String
    let worktreeRequest: ACPDelegatedWorktreeRequest
    var pendingInitialPrompt: String?
    var phase: ACPDelegationPhase
    var failureMessage: String?
    let createdAt: Int64
    var updatedAt: Int64
}

struct ACPDelegatedMessage: Equatable, Sendable {
    let id: String
    let sourceSessionId: String
    let targetSessionId: String
    let prompt: String
    let createdAt: Int64
}

struct ACPDelegatedMessageClaim: Equatable, Sendable {
    let instanceId: String
    let token: String
    let expiresAt: Int64
}

struct ACPClaimedDelegatedMessage: Equatable, Sendable {
    let message: ACPDelegatedMessage
    let claim: ACPDelegatedMessageClaim
}
