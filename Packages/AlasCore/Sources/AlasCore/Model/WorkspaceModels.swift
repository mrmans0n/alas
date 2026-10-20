import Foundation

public enum ExecutionLocation: Codable, Equatable, Sendable {
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

    public var normalized: ExecutionLocation {
        switch self {
        case .local:
            .local
        case .ssh(let destination):
            .ssh(destination.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public var identityComponent: String {
        switch normalized {
        case .local: "local"
        case .ssh(let destination): "ssh:\(destination)"
        }
    }

    public var sshHost: String? {
        guard case .ssh(let host) = normalized else { return nil }
        return host
    }

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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

public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var executionLocation: ExecutionLocation
    public var createdAt: Date
    public var updatedAt: Date
    public var members: [WorkspaceMember]
    public var configuration: WorkspaceConfiguration

    public init(
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

    public enum CodingKeys: String, CodingKey, Sendable { case id, name, executionLocation, createdAt, updatedAt, members, configuration }

    public init(from decoder: Decoder) throws {
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

public struct WorkspaceMember: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectID: String
    public var fallbackProjectName: String
    public var fallbackRepositoryRoot: String

    public init(
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

public enum WorkspaceCheckoutOperation: String, Codable, Equatable, Sendable {
    case idle
    case archiving
    case creating
    case repairing
    case cleaning
    case deleting
}

public enum WorkspaceCheckoutMemberAvailability: String, Codable, Equatable, Sendable {
    case pending
    case available
    case missing
    case identityConflict
    case unavailable
    /// The user deliberately removed this exact snapshot worktree. It stays
    /// visible so recreation uses the frozen plan rather than guessing.
    case explicitlyDeleted
}

public enum WorkspaceCheckoutCleanupCheckpoint: String, Codable, Equatable, Sendable {
    case planPersisted
    case worktreeRemoved
    case branchDeleteAttempted
    case complete
    case failed
}

public struct WorkspaceCheckoutCleanupPlan: Codable, Equatable, Sendable {
    public var checkoutID: UUID
    public var memberID: UUID
    public var executionLocation: ExecutionLocation
    public var projectID: String
    public var sourceRepositoryPath: String
    public var baseReference: String
    public var baseCommit: String
    /// The exact owned branch commit observed when cleanup was planned. Branch
    /// deletion must verify this value immediately before deleting by name.
    public var branchCommit: String?
    public var rootPath: String
    public var managedMemberPaths: [String]
    public var worktreePath: String
    public var branch: String
    public var expectedLineageID: String
    public var branchOwnership: WorkspaceBranchOwnership

    public init(checkoutID: UUID, memberID: UUID, executionLocation: ExecutionLocation, projectID: String, sourceRepositoryPath: String, baseReference: String, baseCommit: String, branchCommit: String? = nil, rootPath: String, managedMemberPaths: [String], worktreePath: String, branch: String, expectedLineageID: String, branchOwnership: WorkspaceBranchOwnership) {
        self.checkoutID = checkoutID
        self.memberID = memberID
        self.executionLocation = executionLocation
        self.projectID = projectID
        self.sourceRepositoryPath = sourceRepositoryPath
        self.baseReference = baseReference
        self.baseCommit = baseCommit
        self.branchCommit = branchCommit
        self.rootPath = rootPath
        self.managedMemberPaths = managedMemberPaths
        self.worktreePath = worktreePath
        self.branch = branch
        self.expectedLineageID = expectedLineageID
        self.branchOwnership = branchOwnership
    }
}

public struct WorkspaceCheckoutCleanupRootObservation: Equatable, Sendable {
    public var isContained: Bool
    /// Non-Alas files surviving below the authoritative root. These are never
    /// removed by cleanup and must be explicitly resolved before forgetting.
    public var leftovers: [String]

    public init(isContained: Bool, leftovers: [String]) {
        self.isContained = isContained
        self.leftovers = leftovers
    }
}

public struct WorkspaceCheckoutMemberCleanup: Codable, Equatable, Sendable {
    public var plan: WorkspaceCheckoutCleanupPlan
    public var checkpoint: WorkspaceCheckoutCleanupCheckpoint
    public var worktreeRemoved: Bool
    public var branchRemoved: Bool
    public var sharedRootLeftovers: [String]

    public init(plan: WorkspaceCheckoutCleanupPlan, checkpoint: WorkspaceCheckoutCleanupCheckpoint = .planPersisted, worktreeRemoved: Bool = false, branchRemoved: Bool = false, sharedRootLeftovers: [String] = []) {
        self.plan = plan
        self.checkpoint = checkpoint
        self.worktreeRemoved = worktreeRemoved
        self.branchRemoved = branchRemoved
        self.sharedRootLeftovers = sharedRootLeftovers
    }
}

public enum WorkspaceCheckoutHealth: String, Codable, Equatable, Sendable {
    case ready
    case incomplete
    case needsAttention
    /// Every member worktree was explicitly deleted; only the record remains.
    case deleted
}

public enum WorkspaceCheckoutCheckpoint: String, Codable, Equatable, Sendable {
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

public enum WorkspaceBranchOwnership: String, Codable, Equatable, Sendable {
    case created
    case reused
    case unknown
}

public struct WorkspaceCleanupOwnership: Codable, Equatable, Sendable {
    public var worktreeCreated: Bool
    public var branchOwnership: WorkspaceBranchOwnership

    public init(worktreeCreated: Bool = false, branchOwnership: WorkspaceBranchOwnership = .unknown) {
        self.worktreeCreated = worktreeCreated
        self.branchOwnership = branchOwnership
    }
}

public struct WorkspaceCheckoutMember: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var workspaceMemberID: UUID
    public var projectID: String
    public var fallbackProjectName: String
    public var fallbackRepositoryRoot: String
    public var worktreePath: String
    public var gitLineageID: String?
    public var availability: WorkspaceCheckoutMemberAvailability
    public var checkpoint: WorkspaceCheckoutCheckpoint
    /// The terminal checkpoint that an interrupted recreation must restore.
    public var recreationSourceCheckpoint: WorkspaceCheckoutCheckpoint?
    public var recreationWorktreeCreationBegan: Bool
    public var cleanupOwnership: WorkspaceCleanupOwnership
    public var plan: WorkspaceCheckoutMemberPlan?
    public var cleanup: WorkspaceCheckoutMemberCleanup?

    public init(
        id: UUID = UUID(),
        workspaceMemberID: UUID,
        projectID: String,
        fallbackProjectName: String,
        fallbackRepositoryRoot: String,
        worktreePath: String,
        gitLineageID: String? = nil,
        availability: WorkspaceCheckoutMemberAvailability = .pending,
        checkpoint: WorkspaceCheckoutCheckpoint = .notStarted,
        recreationSourceCheckpoint: WorkspaceCheckoutCheckpoint? = nil,
        recreationWorktreeCreationBegan: Bool = false,
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
        self.recreationSourceCheckpoint = recreationSourceCheckpoint
        self.recreationWorktreeCreationBegan = recreationWorktreeCreationBegan
        self.cleanupOwnership = cleanupOwnership
        self.plan = plan
        self.cleanup = cleanup
    }

    public enum CodingKeys: String, CodingKey, Sendable {
        case id, workspaceMemberID, projectID, fallbackProjectName, fallbackRepositoryRoot
        case worktreePath, gitLineageID, availability, checkpoint, recreationSourceCheckpoint, recreationWorktreeCreationBegan, cleanupOwnership, plan, cleanup
    }

    public init(from decoder: Decoder) throws {
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
        recreationSourceCheckpoint = try container.decodeIfPresent(WorkspaceCheckoutCheckpoint.self, forKey: .recreationSourceCheckpoint)
        recreationWorktreeCreationBegan = try container.decodeIfPresent(Bool.self, forKey: .recreationWorktreeCreationBegan) ?? false
        cleanupOwnership = try container.decodeIfPresent(WorkspaceCleanupOwnership.self, forKey: .cleanupOwnership) ?? .init()
        plan = try container.decodeIfPresent(WorkspaceCheckoutMemberPlan.self, forKey: .plan)
        cleanup = try container.decodeIfPresent(WorkspaceCheckoutMemberCleanup.self, forKey: .cleanup)
    }
}

public enum WorkspaceBranchIntent: Codable, Equatable, Sendable {
    case create(atCommit: String)
    case reuse

    public func cleanupCommit(defaulting baseCommit: String) -> String {
        switch self {
        case .create(let atCommit): atCommit
        case .reuse: baseCommit
        }
    }
}

public struct WorkspaceCheckoutMemberPlan: Codable, Equatable, Sendable {
    public var checkoutMemberID: UUID
    public var projectID: String
    /// The repository inspected during preflight. New plans always persist it
    /// before any Git operation; an empty value only represents old snapshots
    /// that must be reconciled before they can be repaired.
    public var sourceRepositoryPath: String
    public var destinationPath: String
    public var baseReference: String
    public var baseCommit: String
    public var branchIntent: WorkspaceBranchIntent

    public init(
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

    public enum CodingKeys: String, CodingKey, Sendable {
        case checkoutMemberID, projectID, sourceRepositoryPath, destinationPath, baseReference, baseCommit, branchIntent
    }

    public init(from decoder: Decoder) throws {
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

public enum WorkspaceDiagnosticSeverity: String, Codable, Equatable, Sendable {
    case info
    case warning
    case error
}

public struct WorkspaceDiagnostic: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var severity: WorkspaceDiagnosticSeverity
    public var message: String
    public var createdAt: Date
    public var memberID: UUID?
    public var detail: String?

    public init(id: UUID = UUID(), severity: WorkspaceDiagnosticSeverity, message: String, createdAt: Date = .now, memberID: UUID? = nil, detail: String? = nil) {
        self.id = id
        self.severity = severity
        self.message = message
        self.createdAt = createdAt
        self.memberID = memberID
        self.detail = detail
    }

    public func isCreationFailure(for member: WorkspaceCheckoutMember) -> Bool {
        severity == .error && (memberID == nil || memberID == member.id)
            && (message == "Workspace creation failed for \(member.fallbackProjectName)."
                || message == "Workspace setup failed for \(member.fallbackProjectName).")
    }

    public static func deletionFailureMessage(memberName: String) -> String {
        "Could not delete \(memberName)."
    }

    /// A whole-checkout deletion could not remove this member. Replaced on
    /// every retry so the checkout never accumulates stale reasons.
    public func isDeletionFailure(for memberID: UUID) -> Bool {
        severity == .error && self.memberID == memberID && message.hasPrefix("Could not delete ")
    }
}

public struct WorkItemSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var snapshot: IssueSnapshot
    public var lastGoodSnapshot: IssueSnapshot
    public var hostingMemberID: UUID?
    public var capturedAt: Date

    public var contentOrigin: IssueContentOrigin { snapshot.contentOrigin }

    public init(id: UUID = UUID(), snapshot: IssueSnapshot, lastGoodSnapshot: IssueSnapshot? = nil, hostingMemberID: UUID? = nil, capturedAt: Date? = nil) {
        self.id = id
        self.snapshot = snapshot
        self.lastGoodSnapshot = lastGoodSnapshot ?? snapshot
        self.hostingMemberID = hostingMemberID
        self.capturedAt = capturedAt ?? snapshot.capturedAt
    }

    public init(id: UUID = UUID(), title: String, providerID: String? = nil, hostingMemberID: UUID? = nil, capturedAt: Date = .now) {
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

    public enum CodingKeys: String, CodingKey, Sendable {
        case id, snapshot, lastGoodSnapshot, hostingMemberID, capturedAt
        case title, providerID
    }

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(snapshot, forKey: .snapshot)
        try container.encode(lastGoodSnapshot, forKey: .lastGoodSnapshot)
        try container.encodeIfPresent(hostingMemberID, forKey: .hostingMemberID)
        try container.encode(capturedAt, forKey: .capturedAt)
    }
}

public typealias WorkspaceWorkItemSnapshot = WorkItemSnapshot

public struct WorkspaceCheckoutConfigurationSnapshot: Codable, Equatable, Sendable {
    public var capturedAt: Date
    public var shared: WorkspaceSharedConfigurationSnapshot
    public var members: [UUID: WorkspaceMemberConfigurationSnapshot]
    public var warnings: [WorkspaceConfigurationWarning]
    /// Retained only to losslessly migrate slice-1 snapshots. New checkout
    /// plans use the typed `shared` and `members` fields above.
    public var sharedSettings: [String: String]
    public var memberSettings: [UUID: [String: String]]

    public init(capturedAt: Date = .now, shared: WorkspaceSharedConfigurationSnapshot, members: [UUID: WorkspaceMemberConfigurationSnapshot] = [:], warnings: [WorkspaceConfigurationWarning] = [], sharedSettings: [String: String] = [:], memberSettings: [UUID: [String: String]] = [:]) {
        self.capturedAt = capturedAt
        self.shared = shared
        self.members = members
        self.warnings = warnings
        self.sharedSettings = sharedSettings
        self.memberSettings = memberSettings
    }

    public enum CodingKeys: String, CodingKey, Sendable { case capturedAt, shared, members, warnings, sharedSettings, memberSettings }

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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

public struct WorkspaceCheckout: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var workspaceID: UUID?
    public var fallbackWorkspaceName: String
    public var executionLocation: ExecutionLocation
    public var branch: String
    public var rootPath: String
    public var createdAt: Date
    public var archivedAt: Date?
    public var operation: WorkspaceCheckoutOperation
    public var members: [WorkspaceCheckoutMember]
    public var diagnostics: [WorkspaceDiagnostic]
    public var workItems: [WorkspaceWorkItemSnapshot]
    public var configurationSnapshot: WorkspaceCheckoutConfigurationSnapshot?
    /// Persisted cancellation boundary for destructive work. It deliberately
    /// never interrupts an in-flight Git command.
    public var stopAfterCurrentOperations: Bool

    public init(
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

    public enum CodingKeys: String, CodingKey, Sendable {
        case id, workspaceID, fallbackWorkspaceName, executionLocation, branch, rootPath
        case createdAt, archivedAt, operation, members, diagnostics, workItems, configurationSnapshot, stopAfterCurrentOperations
    }

    public init(from decoder: Decoder) throws {
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

    /// Members persist real host paths, while an ssh project lists the same
    /// worktree under its virtual path. Joins against in-app worktrees go
    /// through this; local checkouts are unchanged.
    public func inAppWorktreePath(_ path: String) -> String {
        guard let host = executionLocation.sshHost, RemotePath.isValidHost(host) else { return path }
        return RemotePath.virtualizing(path, like: RemotePath.virtual(host: host, realPath: "/"))
    }

    public var health: WorkspaceCheckoutHealth {
        if members.contains(where: { $0.availability == .identityConflict || $0.checkpoint == .failed || $0.deletionFailed }) {
            return .needsAttention
        }
        if !members.isEmpty, members.allSatisfy({ $0.availability == .explicitlyDeleted }) {
            return .deleted
        }
        if members.contains(where: { $0.availability != .available }) {
            return .incomplete
        }
        return .ready
    }
}

extension WorkspaceCheckoutMember {
    /// The last attempt to remove this worktree failed and it is still here.
    public var deletionFailed: Bool {
        availability != .explicitlyDeleted && cleanup?.checkpoint == .failed
    }
}
