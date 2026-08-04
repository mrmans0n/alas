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

    init(
        identity: MissionIssueIdentity,
        canonicalURL: URL,
        title: String,
        body: String,
        state: MissionIssueState,
        labels: [String],
        assignees: [String],
        providerUpdatedAt: Date?,
        capturedAt: Date,
        refreshError: String?
    ) {
        self.identity = identity
        self.canonicalURL = canonicalURL
        self.title = title
        self.body = body
        self.state = state
        self.labels = labels
        self.assignees = assignees
        self.providerUpdatedAt = providerUpdatedAt
        self.capturedAt = capturedAt
        self.refreshError = refreshError
    }

    init?(source: MissionSourceSnapshot) {
        guard let repositoryLocator = source.repositoryLocator,
              let displayReference = source.displayReference,
              displayReference.first == "#",
              let number = Int(displayReference.dropFirst())
        else {
            return nil
        }

        self.init(
            identity: .init(
                provider: repositoryLocator.provider,
                host: repositoryLocator.host,
                repositorySlug: repositoryLocator.repositorySlug,
                number: number
            ),
            canonicalURL: source.canonicalURL,
            title: source.title,
            body: source.body,
            state: .init(rawValue: source.state.rawValue) ?? .unknown,
            labels: source.labels,
            assignees: source.assignees,
            providerUpdatedAt: source.providerUpdatedAt,
            capturedAt: source.capturedAt,
            refreshError: source.refreshError
        )
    }
}

struct MissionSourceProviderID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    static let github = Self(rawValue: "github")
    static let gitlab = Self(rawValue: "gitlab")
    static let manual = Self(rawValue: "manual")
}

struct MissionSourceIdentity: Codable, Hashable, Sendable {
    let providerID: MissionSourceProviderID
    let stableID: String
}

enum MissionSourceContentOrigin: String, Codable, Equatable, Sendable {
    case provider
    case manual
}

enum MissionSourceState: String, Codable, Equatable, Sendable {
    case open
    case closed
    case unknown
}

struct MissionRepositoryLocator: Codable, Equatable, Sendable {
    let provider: CodeHostKind
    let host: String
    let repositorySlug: String
}

struct MissionSourceSnapshot: Codable, Equatable, Sendable {
    let identity: MissionSourceIdentity
    let canonicalURL: URL
    let providerLabel: String
    let displayReference: String?
    let repositoryLocator: MissionRepositoryLocator?
    let title: String
    let body: String
    let state: MissionSourceState
    let labels: [String]
    let assignees: [String]
    let providerUpdatedAt: Date?
    let capturedAt: Date
    var refreshError: String?
    let contentOrigin: MissionSourceContentOrigin
    let isEditable: Bool
    let isRefreshable: Bool

    init(
        identity: MissionSourceIdentity,
        canonicalURL: URL,
        providerLabel: String,
        displayReference: String?,
        repositoryLocator: MissionRepositoryLocator?,
        title: String,
        body: String,
        state: MissionSourceState,
        labels: [String],
        assignees: [String],
        providerUpdatedAt: Date?,
        capturedAt: Date,
        refreshError: String?,
        contentOrigin: MissionSourceContentOrigin,
        isEditable: Bool,
        isRefreshable: Bool
    ) {
        self.identity = identity
        self.canonicalURL = canonicalURL
        self.providerLabel = providerLabel
        self.displayReference = displayReference
        self.repositoryLocator = repositoryLocator
        self.title = title
        self.body = body
        self.state = state
        self.labels = labels
        self.assignees = assignees
        self.providerUpdatedAt = providerUpdatedAt
        self.capturedAt = capturedAt
        self.refreshError = refreshError
        self.contentOrigin = contentOrigin
        self.isEditable = isEditable
        self.isRefreshable = isRefreshable
    }

    init(issue: MissionIssueSnapshot) {
        let providerID: MissionSourceProviderID = switch issue.identity.provider {
        case .github: .github
        case .gitlab: .gitlab
        }
        self.init(
            identity: .init(
                providerID: providerID,
                stableID: "\(issue.identity.host)/\(issue.identity.repositorySlug)#\(issue.identity.number)".lowercased()
            ),
            canonicalURL: issue.canonicalURL,
            providerLabel: issue.identity.provider.displayName,
            displayReference: "#\(issue.identity.number)",
            repositoryLocator: .init(
                provider: issue.identity.provider,
                host: issue.identity.host,
                repositorySlug: issue.identity.repositorySlug
            ),
            title: issue.title,
            body: issue.body,
            state: .init(rawValue: issue.state.rawValue) ?? .unknown,
            labels: issue.labels,
            assignees: issue.assignees,
            providerUpdatedAt: issue.providerUpdatedAt,
            capturedAt: issue.capturedAt,
            refreshError: issue.refreshError,
            contentOrigin: .provider,
            isEditable: false,
            isRefreshable: true
        )
    }
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
    var source: MissionSourceSnapshot
    var legs: [MissionLeg]
    var events: [MissionEvent]

    init(
        mission: MissionRecord,
        source: MissionSourceSnapshot,
        legs: [MissionLeg],
        events: [MissionEvent]
    ) {
        self.mission = mission
        self.source = source
        self.legs = legs
        self.events = events
    }

    init(
        mission: MissionRecord,
        issue: MissionIssueSnapshot,
        legs: [MissionLeg],
        events: [MissionEvent]
    ) {
        self.init(
            mission: mission,
            source: MissionSourceSnapshot(issue: issue),
            legs: legs,
            events: events
        )
    }

    // Temporary compatibility for code-host callers while they migrate to
    // provider-neutral Mission sources. Remove with the Task 7 migration.
    var issue: MissionIssueSnapshot {
        get {
            guard let issue = MissionIssueSnapshot(source: source) else {
                preconditionFailure("Mission source is not a code-host issue")
            }
            return issue
        }
        set { source = MissionSourceSnapshot(issue: newValue) }
    }

    var primaryLeg: MissionLeg? {
        legs.first { $0.id == mission.primaryLegID }
    }
}

struct MissionDraft: Equatable, Sendable {
    let source: MissionSourceSnapshot
    let projectId: String
    let baseRef: String
    let baseRemoteName: String?
    let branch: String
    let destinationPath: String
    let agentId: String
    let initialPromptId: UUID
    let initialPrompt: String

    // Temporary compatibility for code-host callers while they migrate to
    // provider-neutral Mission sources. Remove with the Task 7 migration.
    var issue: MissionIssueSnapshot {
        guard let issue = MissionIssueSnapshot(source: source) else {
            preconditionFailure("Mission source is not a code-host issue")
        }
        return issue
    }

    init(
        source: MissionSourceSnapshot,
        projectId: String,
        baseRef: String,
        baseRemoteName: String? = nil,
        branch: String,
        destinationPath: String,
        agentId: String,
        initialPromptId: UUID,
        initialPrompt: String
    ) {
        self.source = source
        self.projectId = projectId
        self.baseRef = baseRef
        self.baseRemoteName = baseRemoteName
        self.branch = branch
        self.destinationPath = destinationPath
        self.agentId = agentId
        self.initialPromptId = initialPromptId
        self.initialPrompt = initialPrompt
    }

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
        self.init(
            source: MissionSourceSnapshot(issue: issue),
            projectId: projectId,
            baseRef: baseRef,
            baseRemoteName: baseRemoteName,
            branch: branch,
            destinationPath: destinationPath,
            agentId: agentId,
            initialPromptId: initialPromptId,
            initialPrompt: initialPrompt
        )
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
