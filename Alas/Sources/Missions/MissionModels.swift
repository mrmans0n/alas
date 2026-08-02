import Foundation

enum MissionBaseReference {
    static func branchName(_ baseRef: String, currentRemoteName: String) -> String {
        let remoteNames = [currentRemoteName, "origin"]
        for remoteName in remoteNames where !remoteName.isEmpty {
            let prefix = "\(remoteName)/"
            if baseRef.hasPrefix(prefix) {
                return String(baseRef.dropFirst(prefix.count))
            }
        }
        return baseRef
    }
}

struct MissionID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
}

struct MissionLegID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
}

enum MissionState: String, Codable, Equatable, Hashable, Sendable {
    case creating
    case running
    case needsAttention
    case readyToComplete
    case completed
}

enum MissionSetupCheckpoint: String, Codable, Equatable, Sendable {
    case creatingWorktree
    case startingAgent
    case running
}

enum MissionEventKind: String, Codable, Equatable, Sendable {
    case created
    case worktreeCreated
    case agentStarted
    case retryStarted
    case sourceRefreshed
    case reviewLinked
    case ready
    case attentionRequired
    case completed
}

enum MissionIssueState: String, Codable, Equatable, Sendable {
    case open
    case closed
    case unknown
}

struct MissionIssueIdentity: Codable, Equatable, Sendable {
    let provider: CodeHostKind
    let host: String
    let repositorySlug: String
    let number: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.provider == rhs.provider
            && lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame
            && lhs.repositorySlug.caseInsensitiveCompare(rhs.repositorySlug) == .orderedSame
            && lhs.number == rhs.number
    }
}

struct MissionIssueSnapshot: Codable, Equatable, Sendable {
    let identity: MissionIssueIdentity
    let canonicalURL: URL
    let title: String
    let body: String
    let state: MissionIssueState
    let labels: [String]
    let assignees: [String]
    let providerUpdatedAt: Date?
    let capturedAt: Date
    var refreshError: String?
}

struct MissionReviewIdentity: Codable, Equatable, Sendable {
    let provider: CodeHostKind
    let host: String
    let repositorySlug: String
    let number: Int
    let url: URL
}

struct MissionRecord: Codable, Equatable, Sendable {
    let id: MissionID
    var title: String
    var state: MissionState
    var setupCheckpoint: MissionSetupCheckpoint
    let primaryLegID: MissionLegID
    var attentionReason: String?
    let createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
}

struct MissionLeg: Codable, Equatable, Sendable {
    let id: MissionLegID
    let missionID: MissionID
    let ordinal: Int
    let projectId: String
    let baseRef: String
    let branch: String
    let destinationPath: String
    var worktreeId: String?
    var agentId: String
    var acpSessionId: String?
    let initialPromptId: UUID
    var pendingInitialPrompt: String?
    var reviewIdentity: MissionReviewIdentity?
}

struct MissionEvent: Codable, Equatable, Sendable {
    let id: String
    let missionID: MissionID
    let legID: MissionLegID?
    let kind: MissionEventKind
    let message: String
    let createdAt: Date
}

struct MissionAggregate: Equatable, Sendable {
    var mission: MissionRecord
    var issue: MissionIssueSnapshot
    var legs: [MissionLeg]
    var events: [MissionEvent]

    var primaryLeg: MissionLeg? {
        guard legs.count == 1 else { return nil }
        return legs.first { $0.id == mission.primaryLegID }
    }
}

struct MissionDraft: Equatable, Sendable {
    let issue: MissionIssueSnapshot
    let projectId: String
    let baseRef: String
    let branch: String
    let destinationPath: String
    let agentId: String
    let initialPromptId: UUID
    let initialPrompt: String
}
