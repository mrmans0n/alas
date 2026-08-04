import Foundation

enum MissionBaseReference {
    static func remoteName(
        in baseRef: String,
        knownRemoteNames: Set<String>,
        localBranchNames: Set<String> = []
    ) -> String? {
        guard !localBranchNames.contains(baseRef) else { return nil }
        return longestRemotePrefix(in: baseRef, knownRemoteNames: knownRemoteNames)
    }

    static func resolveLegacyRemoteName(
        in baseRef: String,
        knownRemoteNames: Set<String>,
        localBranchNames: Set<String>,
        branchNames: Set<String>
    ) -> String? {
        guard let separator = baseRef.firstIndex(of: "/") else { return "" }
        let candidate = String(baseRef[..<separator])
        if localBranchNames.contains(baseRef) { return "" }
        if let remoteName = longestRemotePrefix(in: baseRef, knownRemoteNames: knownRemoteNames) {
            return remoteName
        }
        if knownRemoteNames.contains(where: { branchNames.contains("\($0)/\(baseRef)") }) {
            return ""
        }
        let branch = String(baseRef[baseRef.index(after: separator)...])
        if localBranchNames.contains(branch)
            || knownRemoteNames.contains(where: { branchNames.contains("\($0)/\(branch)") }) {
            return candidate
        }
        return nil
    }

    private static func longestRemotePrefix(
        in baseRef: String,
        knownRemoteNames: Set<String>
    ) -> String? {
        knownRemoteNames
            .filter { baseRef.hasPrefix("\($0)/") }
            .max { $0.count < $1.count }
    }

    static func branchName(
        _ baseRef: String,
        persistedRemoteName: String?
    ) -> String {
        guard let persistedRemoteName, !persistedRemoteName.isEmpty else { return baseRef }
        let prefix = "\(persistedRemoteName)/"
        if baseRef.hasPrefix(prefix) {
            return String(baseRef.dropFirst(prefix.count))
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
    // Temporary source compatibility while mission setup callers migrate to MissionLeg.
    case needsAttention
    case readyToComplete
    case completed
}

enum MissionLegState: String, Codable, Equatable, Hashable, Sendable {
    case creating
    case running
    case needsAttention
    case ready
}

enum MissionLegReadinessKind: String, Codable, Equatable, Sendable {
    case mergedReview
    case archivedWorktree
    case legacy
}

struct MissionLegReadinessEvidence: Codable, Equatable, Sendable {
    let kind: MissionLegReadinessKind
    let observedAt: Date
}

enum MissionSetupCheckpoint: String, Codable, Equatable, Sendable {
    case creatingWorktree
    case startingAgent
    case running
}

enum MissionEventKind: String, Codable, Equatable, Sendable {
    case created
    case legAdded
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
    // Temporary source compatibility while mission setup callers migrate to MissionLeg.
    var setupCheckpoint: MissionSetupCheckpoint
    let primaryLegID: MissionLegID
    // Temporary source compatibility while mission setup callers migrate to MissionLeg.
    var attentionReason: String?
    let createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    init(
        id: MissionID,
        title: String,
        state: MissionState = .creating,
        setupCheckpoint: MissionSetupCheckpoint = .creatingWorktree,
        primaryLegID: MissionLegID,
        attentionReason: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date?
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.setupCheckpoint = setupCheckpoint
        self.primaryLegID = primaryLegID
        self.attentionReason = attentionReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

struct MissionLeg: Codable, Equatable, Sendable {
    let id: MissionLegID
    let missionID: MissionID
    let ordinal: Int
    let projectId: String
    let baseRef: String
    var baseRemoteName: String?
    let branch: String
    let destinationPath: String
    var worktreeId: String?
    var worktreeLineageID: String?
    var agentId: String
    var acpSessionId: String?
    let initialPromptId: UUID
    let preparedInitialPrompt: String
    var pendingInitialPrompt: String?
    var reviewIdentity: MissionReviewIdentity?
    var state: MissionLegState
    var setupCheckpoint: MissionSetupCheckpoint
    var attentionReason: String?
    var readinessEvidence: MissionLegReadinessEvidence?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: MissionLegID,
        missionID: MissionID,
        ordinal: Int,
        projectId: String,
        baseRef: String,
        baseRemoteName: String? = nil,
        branch: String,
        destinationPath: String,
        worktreeId: String?,
        worktreeLineageID: String? = nil,
        agentId: String,
        acpSessionId: String?,
        initialPromptId: UUID,
        preparedInitialPrompt: String? = nil,
        pendingInitialPrompt: String?,
        reviewIdentity: MissionReviewIdentity?,
        state: MissionLegState = .creating,
        setupCheckpoint: MissionSetupCheckpoint = .creatingWorktree,
        attentionReason: String? = nil,
        readinessEvidence: MissionLegReadinessEvidence? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.missionID = missionID
        self.ordinal = ordinal
        self.projectId = projectId
        self.baseRef = baseRef
        self.baseRemoteName = baseRemoteName
        self.branch = branch
        self.destinationPath = destinationPath
        self.worktreeId = worktreeId
        self.worktreeLineageID = worktreeLineageID
        self.agentId = agentId
        self.acpSessionId = acpSessionId
        self.initialPromptId = initialPromptId
        self.preparedInitialPrompt = preparedInitialPrompt ?? pendingInitialPrompt ?? ""
        self.pendingInitialPrompt = pendingInitialPrompt
        self.reviewIdentity = reviewIdentity
        self.state = state
        self.setupCheckpoint = setupCheckpoint
        self.attentionReason = attentionReason
        self.readinessEvidence = readinessEvidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
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
        legs.first { $0.id == mission.primaryLegID }
    }
}

struct MissionDraft: Equatable, Sendable {
    let issue: MissionIssueSnapshot
    let projectId: String
    let baseRef: String
    let baseRemoteName: String?
    let branch: String
    let destinationPath: String
    let agentId: String
    let initialPromptId: UUID
    let initialPrompt: String

    init(
        issue: MissionIssueSnapshot,
        projectId: String,
        baseRef: String,
        baseRemoteName: String? = nil,
        branch: String,
        destinationPath: String,
        agentId: String,
        initialPromptId: UUID,
        initialPrompt: String
    ) {
        self.issue = issue
        self.projectId = projectId
        self.baseRef = baseRef
        self.baseRemoteName = baseRemoteName
        self.branch = branch
        self.destinationPath = destinationPath
        self.agentId = agentId
        self.initialPromptId = initialPromptId
        self.initialPrompt = initialPrompt
    }
}

struct MissionLegDraft: Equatable, Sendable {
    let projectId: String
    let baseRef: String
    let baseRemoteName: String?
    let branch: String
    let destinationPath: String
    let agentId: String
    let initialPromptId: UUID
    let preparedPrompt: String
}
