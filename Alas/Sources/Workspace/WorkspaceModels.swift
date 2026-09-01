import Foundation

enum ExecutionLocation: Codable, Equatable, Sendable {
    case local
    case ssh(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case destination
    }

    private enum Kind: String, Codable {
        case local
        case ssh
    }

    var normalized: ExecutionLocation {
        switch self {
        case .local:
            .local
        case .ssh(let destination):
            .ssh(destination.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    var identityComponent: String {
        switch normalized {
        case .local: "local"
        case .ssh(let destination): "ssh:\(destination)"
        }
    }

    var sshHost: String? {
        guard case .ssh(let host) = normalized else { return nil }
        return host
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .local:
            self = .local
        case .ssh:
            self = .ssh(
                try container.decode(String.self, forKey: .destination)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch normalized {
        case .local:
            try container.encode(Kind.local, forKey: .kind)
        case .ssh(let destination):
            try container.encode(Kind.ssh, forKey: .kind)
            try container.encode(destination, forKey: .destination)
        }
    }
}

struct Workspace: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var executionLocation: ExecutionLocation
    var createdAt: Date
    var updatedAt: Date
    var members: [WorkspaceMember]
    var configuration: WorkspaceConfiguration

    init(
        id: UUID = UUID(),
        name: String,
        executionLocation: ExecutionLocation,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        members: [WorkspaceMember],
        configuration: WorkspaceConfiguration = .init()
    ) {
        self.id = id
        self.name = name
        self.executionLocation = executionLocation.normalized
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.members = members
        self.configuration = configuration
    }

    enum CodingKeys: String, CodingKey { case id, name, executionLocation, createdAt, updatedAt, members, configuration }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        executionLocation = try container.decode(ExecutionLocation.self, forKey: .executionLocation).normalized
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        members = try container.decode([WorkspaceMember].self, forKey: .members)
        configuration = try container.decodeIfPresent(WorkspaceConfiguration.self, forKey: .configuration) ?? .init()
    }
}

struct WorkspaceMember: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var projectID: String
    var fallbackProjectName: String
    var fallbackRepositoryRoot: String

    init(
        id: UUID = UUID(),
        projectID: String,
        fallbackProjectName: String,
        fallbackRepositoryRoot: String
    ) {
        self.id = id
        self.projectID = projectID
        self.fallbackProjectName = fallbackProjectName
        self.fallbackRepositoryRoot = fallbackRepositoryRoot
    }
}

enum WorkspaceCheckoutOperation: String, Codable, Equatable, Sendable {
    case idle
    case archiving
    case creating
    case repairing
    case cleaning
    case deleting
}

enum WorkspaceCheckoutMemberAvailability: String, Codable, Equatable, Sendable {
    case pending
    case available
    case missing
    case identityConflict
    case unavailable
    /// The user deliberately removed this exact snapshot worktree. It stays
    /// visible so recreation uses the frozen plan rather than guessing.
    case explicitlyDeleted
}

enum WorkspaceCheckoutCleanupCheckpoint: String, Codable, Equatable, Sendable {
    case planPersisted
    case worktreeRemoved
    case branchDeleteAttempted
    case complete
    case failed
}

struct WorkspaceCheckoutCleanupPlan: Codable, Equatable, Sendable {
    var checkoutID: UUID
    var memberID: UUID
    var executionLocation: ExecutionLocation
    var projectID: String
    var sourceRepositoryPath: String
    var baseReference: String
    var baseCommit: String
    /// The exact owned branch commit observed when cleanup was planned. Branch
    /// deletion must verify this value immediately before deleting by name.
    var branchCommit: String?
    var rootPath: String
    var managedMemberPaths: [String]
    var worktreePath: String
    var branch: String
    var expectedLineageID: String
    var branchOwnership: WorkspaceBranchOwnership
}

struct WorkspaceCheckoutCleanupRootObservation: Equatable, Sendable {
    var isContained: Bool
    /// Non-Alas files surviving below the authoritative root. These are never
    /// removed by cleanup and must be explicitly resolved before forgetting.
    var leftovers: [String]
}

struct WorkspaceCheckoutMemberCleanup: Codable, Equatable, Sendable {
    var plan: WorkspaceCheckoutCleanupPlan
    var checkpoint: WorkspaceCheckoutCleanupCheckpoint
    var worktreeRemoved: Bool
    var branchRemoved: Bool
    var sharedRootLeftovers: [String]

    init(plan: WorkspaceCheckoutCleanupPlan, checkpoint: WorkspaceCheckoutCleanupCheckpoint = .planPersisted, worktreeRemoved: Bool = false, branchRemoved: Bool = false, sharedRootLeftovers: [String] = []) {
        self.plan = plan
        self.checkpoint = checkpoint
        self.worktreeRemoved = worktreeRemoved
        self.branchRemoved = branchRemoved
        self.sharedRootLeftovers = sharedRootLeftovers
    }
}

enum WorkspaceCheckoutHealth: String, Codable, Equatable, Sendable {
    case ready
    case incomplete
    case needsAttention
}

enum WorkspaceCheckoutCheckpoint: String, Codable, Equatable, Sendable {
    case notStarted
    case planPersisted
    case branchPreparing
    case branchPrepared
    case worktreeCreating
    case worktreeCreated
    case setupRunning
    case setupComplete
    case failed
}

enum WorkspaceBranchOwnership: String, Codable, Equatable, Sendable {
    case created
    case reused
    case unknown
}

struct WorkspaceCleanupOwnership: Codable, Equatable, Sendable {
    var worktreeCreated: Bool
    var branchOwnership: WorkspaceBranchOwnership

    init(worktreeCreated: Bool = false, branchOwnership: WorkspaceBranchOwnership = .unknown) {
        self.worktreeCreated = worktreeCreated
        self.branchOwnership = branchOwnership
    }
}

struct WorkspaceCheckoutMember: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var workspaceMemberID: UUID
    var projectID: String
    var fallbackProjectName: String
    var fallbackRepositoryRoot: String
    var worktreePath: String
    var gitLineageID: String?
    var availability: WorkspaceCheckoutMemberAvailability
    var checkpoint: WorkspaceCheckoutCheckpoint
    var cleanupOwnership: WorkspaceCleanupOwnership
    var plan: WorkspaceCheckoutMemberPlan?
    var cleanup: WorkspaceCheckoutMemberCleanup?

    init(
        id: UUID = UUID(),
        workspaceMemberID: UUID,
        projectID: String,
        fallbackProjectName: String,
        fallbackRepositoryRoot: String,
        worktreePath: String,
        gitLineageID: String? = nil,
        availability: WorkspaceCheckoutMemberAvailability = .pending,
        checkpoint: WorkspaceCheckoutCheckpoint = .notStarted,
        cleanupOwnership: WorkspaceCleanupOwnership = .init(),
        plan: WorkspaceCheckoutMemberPlan? = nil,
        cleanup: WorkspaceCheckoutMemberCleanup? = nil
    ) {
        self.id = id
        self.workspaceMemberID = workspaceMemberID
        self.projectID = projectID
        self.fallbackProjectName = fallbackProjectName
        self.fallbackRepositoryRoot = fallbackRepositoryRoot
        self.worktreePath = worktreePath
        self.gitLineageID = gitLineageID
        self.availability = availability
        self.checkpoint = checkpoint
        self.cleanupOwnership = cleanupOwnership
        self.plan = plan
        self.cleanup = cleanup
    }

    enum CodingKeys: String, CodingKey {
        case id, workspaceMemberID, projectID, fallbackProjectName, fallbackRepositoryRoot
        case worktreePath, gitLineageID, availability, checkpoint, cleanupOwnership, plan, cleanup
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        workspaceMemberID = try container.decode(UUID.self, forKey: .workspaceMemberID)
        projectID = try container.decode(String.self, forKey: .projectID)
        fallbackProjectName = try container.decode(String.self, forKey: .fallbackProjectName)
        fallbackRepositoryRoot = try container.decode(String.self, forKey: .fallbackRepositoryRoot)
        worktreePath = try container.decode(String.self, forKey: .worktreePath)
        gitLineageID = try container.decodeIfPresent(String.self, forKey: .gitLineageID)
        availability = try container.decodeIfPresent(WorkspaceCheckoutMemberAvailability.self, forKey: .availability) ?? .pending
        checkpoint = try container.decodeIfPresent(WorkspaceCheckoutCheckpoint.self, forKey: .checkpoint) ?? .notStarted
        cleanupOwnership = try container.decodeIfPresent(WorkspaceCleanupOwnership.self, forKey: .cleanupOwnership) ?? .init()
        plan = try container.decodeIfPresent(WorkspaceCheckoutMemberPlan.self, forKey: .plan)
        cleanup = try container.decodeIfPresent(WorkspaceCheckoutMemberCleanup.self, forKey: .cleanup)
    }
}

enum WorkspaceBranchIntent: Codable, Equatable, Sendable {
    case create(atCommit: String)
    case reuse

    func cleanupCommit(defaulting baseCommit: String) -> String {
        switch self {
        case .create(let atCommit): atCommit
        case .reuse: baseCommit
        }
    }
}

struct WorkspaceCheckoutMemberPlan: Codable, Equatable, Sendable {
    var checkoutMemberID: UUID
    var projectID: String
    /// The repository inspected during preflight. New plans always persist it
    /// before any Git operation; an empty value only represents old snapshots
    /// that must be reconciled before they can be repaired.
    var sourceRepositoryPath: String
    var destinationPath: String
    var baseReference: String
    var baseCommit: String
    var branchIntent: WorkspaceBranchIntent

    init(
        checkoutMemberID: UUID,
        projectID: String,
        sourceRepositoryPath: String = "",
        destinationPath: String,
        baseReference: String,
        baseCommit: String,
        branchIntent: WorkspaceBranchIntent
    ) {
        self.checkoutMemberID = checkoutMemberID
        self.projectID = projectID
        self.sourceRepositoryPath = sourceRepositoryPath
        self.destinationPath = destinationPath
        self.baseReference = baseReference
        self.baseCommit = baseCommit
        self.branchIntent = branchIntent
    }

    enum CodingKeys: String, CodingKey {
        case checkoutMemberID, projectID, sourceRepositoryPath, destinationPath, baseReference, baseCommit, branchIntent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        checkoutMemberID = try container.decode(UUID.self, forKey: .checkoutMemberID)
        projectID = try container.decode(String.self, forKey: .projectID)
        sourceRepositoryPath = try container.decodeIfPresent(String.self, forKey: .sourceRepositoryPath) ?? ""
        destinationPath = try container.decode(String.self, forKey: .destinationPath)
        baseReference = try container.decode(String.self, forKey: .baseReference)
        baseCommit = try container.decode(String.self, forKey: .baseCommit)
        branchIntent = try container.decode(WorkspaceBranchIntent.self, forKey: .branchIntent)
    }
}

enum WorkspaceDiagnosticSeverity: String, Codable, Equatable, Sendable {
    case info
    case warning
    case error
}

struct WorkspaceDiagnostic: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var severity: WorkspaceDiagnosticSeverity
    var message: String
    var createdAt: Date

    init(id: UUID = UUID(), severity: WorkspaceDiagnosticSeverity, message: String, createdAt: Date = .now) {
        self.id = id
        self.severity = severity
        self.message = message
        self.createdAt = createdAt
    }
}

struct WorkItemSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var snapshot: IssueSnapshot
    var lastGoodSnapshot: IssueSnapshot
    var hostingMemberID: UUID?
    var capturedAt: Date

    var contentOrigin: IssueContentOrigin { snapshot.contentOrigin }

    init(id: UUID = UUID(), snapshot: IssueSnapshot, lastGoodSnapshot: IssueSnapshot? = nil, hostingMemberID: UUID? = nil, capturedAt: Date? = nil) {
        self.id = id
        self.snapshot = snapshot
        self.lastGoodSnapshot = lastGoodSnapshot ?? snapshot
        self.hostingMemberID = hostingMemberID
        self.capturedAt = capturedAt ?? snapshot.capturedAt
    }

    init(id: UUID = UUID(), title: String, providerID: String? = nil, hostingMemberID: UUID? = nil, capturedAt: Date = .now) {
        let provider = providerID.map(IssueProviderID.init(rawValue:)) ?? .manual
        let origin: IssueContentOrigin = provider == .manual ? .manual : .provider
        let snapshot = IssueSnapshot(
            identity: .init(providerID: provider, stableID: "\(provider.rawValue):\(title)"),
            canonicalURL: URL(string: "about:blank")!,
            providerLabel: provider == .manual ? "Manual" : provider.rawValue,
            displayReference: nil,
            repositoryLocator: nil,
            title: title,
            body: "",
            state: .unknown,
            labels: [],
            assignees: [],
            providerUpdatedAt: nil,
            capturedAt: capturedAt,
            refreshError: nil,
            contentOrigin: origin,
            isEditable: origin == .manual,
            isRefreshable: origin == .provider
        )
        self.init(id: id, snapshot: snapshot, hostingMemberID: hostingMemberID, capturedAt: capturedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, snapshot, lastGoodSnapshot, hostingMemberID, capturedAt
        case title, providerID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let decodedHostingMemberID = try container.decodeIfPresent(UUID.self, forKey: .hostingMemberID)
        if let decoded = try container.decodeIfPresent(IssueSnapshot.self, forKey: .snapshot) {
            id = decodedID
            snapshot = decoded
            lastGoodSnapshot = try container.decodeIfPresent(IssueSnapshot.self, forKey: .lastGoodSnapshot) ?? decoded
            hostingMemberID = decodedHostingMemberID
            capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt) ?? decoded.capturedAt
            return
        }

        let title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled Work Item"
        let providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        let capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt) ?? .distantPast
        let provider = providerID.map(IssueProviderID.init(rawValue:)) ?? .manual
        let origin: IssueContentOrigin = provider == .manual ? .manual : .provider
        let legacySnapshot = IssueSnapshot(
            identity: .init(providerID: provider, stableID: "\(provider.rawValue):\(title)"),
            canonicalURL: URL(string: "about:blank")!,
            providerLabel: provider == .manual ? "Manual" : provider.rawValue,
            displayReference: nil,
            repositoryLocator: nil,
            title: title,
            body: "",
            state: .unknown,
            labels: [],
            assignees: [],
            providerUpdatedAt: nil,
            capturedAt: capturedAt,
            refreshError: nil,
            contentOrigin: origin,
            isEditable: origin == .manual,
            isRefreshable: origin == .provider
        )
        id = decodedID
        snapshot = legacySnapshot
        lastGoodSnapshot = legacySnapshot
        hostingMemberID = decodedHostingMemberID
        self.capturedAt = capturedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(snapshot, forKey: .snapshot)
        try container.encode(lastGoodSnapshot, forKey: .lastGoodSnapshot)
        try container.encodeIfPresent(hostingMemberID, forKey: .hostingMemberID)
        try container.encode(capturedAt, forKey: .capturedAt)
    }
}

typealias WorkspaceWorkItemSnapshot = WorkItemSnapshot

struct WorkspaceCheckoutConfigurationSnapshot: Codable, Equatable, Sendable {
    var capturedAt: Date
    var shared: WorkspaceSharedConfigurationSnapshot
    var members: [UUID: WorkspaceMemberConfigurationSnapshot]
    var warnings: [WorkspaceConfigurationWarning]
    /// Retained only to losslessly migrate slice-1 snapshots. New checkout
    /// plans use the typed `shared` and `members` fields above.
    var sharedSettings: [String: String]
    var memberSettings: [UUID: [String: String]]

    init(capturedAt: Date = .now, shared: WorkspaceSharedConfigurationSnapshot, members: [UUID: WorkspaceMemberConfigurationSnapshot] = [:], warnings: [WorkspaceConfigurationWarning] = [], sharedSettings: [String: String] = [:], memberSettings: [UUID: [String: String]] = [:]) {
        self.capturedAt = capturedAt
        self.shared = shared
        self.members = members
        self.warnings = warnings
        self.sharedSettings = sharedSettings
        self.memberSettings = memberSettings
    }

    enum CodingKeys: String, CodingKey { case capturedAt, shared, members, warnings, sharedSettings, memberSettings }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        sharedSettings = try container.decodeIfPresent([String: String].self, forKey: .sharedSettings) ?? [:]
        if let decoded = try? container.decodeIfPresent([UUID: [String: String]].self, forKey: .memberSettings) {
            memberSettings = decoded
        } else {
            let legacy = try container.decodeIfPresent([String: [String: String]].self, forKey: .memberSettings) ?? [:]
            memberSettings = legacy.reduce(into: [:]) { result, entry in
                if let id = UUID(uuidString: entry.key) { result[id] = entry.value }
            }
        }
        shared = try container.decodeIfPresent(WorkspaceSharedConfigurationSnapshot.self, forKey: .shared)
            ?? .init(sessionOpenScript: sharedSettings["script"] ?? "", worktreeCreateScript: "", creationLaunchPreference: .init(agentID: sharedSettings["launcher"]))
        members = try container.decodeIfPresent([UUID: WorkspaceMemberConfigurationSnapshot].self, forKey: .members) ?? [:]
        warnings = try container.decodeIfPresent([WorkspaceConfigurationWarning].self, forKey: .warnings) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(shared, forKey: .shared)
        try container.encode(members, forKey: .members)
        try container.encode(warnings, forKey: .warnings)
        if !sharedSettings.isEmpty { try container.encode(sharedSettings, forKey: .sharedSettings) }
        if !memberSettings.isEmpty {
            try container.encode(Dictionary(uniqueKeysWithValues: memberSettings.map { ($0.key.uuidString, $0.value) }), forKey: .memberSettings)
        }
    }
}

struct WorkspaceCheckout: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var workspaceID: UUID?
    var fallbackWorkspaceName: String
    var executionLocation: ExecutionLocation
    var branch: String
    var rootPath: String
    var createdAt: Date
    var archivedAt: Date?
    var operation: WorkspaceCheckoutOperation
    var members: [WorkspaceCheckoutMember]
    var diagnostics: [WorkspaceDiagnostic]
    var workItems: [WorkspaceWorkItemSnapshot]
    var configurationSnapshot: WorkspaceCheckoutConfigurationSnapshot?
    /// Persisted cancellation boundary for destructive work. It deliberately
    /// never interrupts an in-flight Git command.
    var stopAfterCurrentOperations: Bool

    init(
        id: UUID = UUID(),
        workspaceID: UUID?,
        fallbackWorkspaceName: String,
        executionLocation: ExecutionLocation,
        branch: String,
        rootPath: String,
        createdAt: Date = .now,
        archivedAt: Date? = nil,
        operation: WorkspaceCheckoutOperation = .idle,
        members: [WorkspaceCheckoutMember],
        diagnostics: [WorkspaceDiagnostic] = [],
        workItems: [WorkspaceWorkItemSnapshot] = [],
        configurationSnapshot: WorkspaceCheckoutConfigurationSnapshot? = nil,
        stopAfterCurrentOperations: Bool = false
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.fallbackWorkspaceName = fallbackWorkspaceName
        self.executionLocation = executionLocation.normalized
        self.branch = branch
        self.rootPath = rootPath
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.operation = operation
        self.members = members
        self.diagnostics = diagnostics
        self.workItems = workItems
        self.configurationSnapshot = configurationSnapshot
        self.stopAfterCurrentOperations = stopAfterCurrentOperations
    }

    enum CodingKeys: String, CodingKey {
        case id, workspaceID, fallbackWorkspaceName, executionLocation, branch, rootPath
        case createdAt, archivedAt, operation, members, diagnostics, workItems, configurationSnapshot, stopAfterCurrentOperations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        fallbackWorkspaceName = try container.decode(String.self, forKey: .fallbackWorkspaceName)
        executionLocation = try container.decode(ExecutionLocation.self, forKey: .executionLocation).normalized
        branch = try container.decode(String.self, forKey: .branch)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        operation = try container.decodeIfPresent(WorkspaceCheckoutOperation.self, forKey: .operation) ?? .idle
        members = try container.decodeIfPresent([WorkspaceCheckoutMember].self, forKey: .members) ?? []
        diagnostics = try container.decodeIfPresent([WorkspaceDiagnostic].self, forKey: .diagnostics) ?? []
        workItems = try container.decodeIfPresent([WorkspaceWorkItemSnapshot].self, forKey: .workItems) ?? []
        configurationSnapshot = try container.decodeIfPresent(WorkspaceCheckoutConfigurationSnapshot.self, forKey: .configurationSnapshot)
        stopAfterCurrentOperations = try container.decodeIfPresent(Bool.self, forKey: .stopAfterCurrentOperations) ?? false
    }

    var health: WorkspaceCheckoutHealth {
        if members.contains(where: { $0.availability == .identityConflict || $0.checkpoint == .failed }) {
            return .needsAttention
        }
        if members.contains(where: { $0.availability != .available }) {
            return .incomplete
        }
        return .ready
    }
}
