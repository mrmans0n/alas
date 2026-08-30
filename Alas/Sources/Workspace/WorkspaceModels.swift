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

    init(
        id: UUID = UUID(),
        name: String,
        executionLocation: ExecutionLocation,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        members: [WorkspaceMember]
    ) {
        self.id = id
        self.name = name
        self.executionLocation = executionLocation.normalized
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.members = members
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
}

enum WorkspaceCheckoutHealth: String, Codable, Equatable, Sendable {
    case ready
    case incomplete
    case needsAttention
}

enum WorkspaceCheckoutCheckpoint: String, Codable, Equatable, Sendable {
    case notStarted
    case planPersisted
    case branchPrepared
    case worktreeCreated
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
        plan: WorkspaceCheckoutMemberPlan? = nil
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
    }

    enum CodingKeys: String, CodingKey {
        case id, workspaceMemberID, projectID, fallbackProjectName, fallbackRepositoryRoot
        case worktreePath, gitLineageID, availability, checkpoint, cleanupOwnership, plan
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
    }
}

enum WorkspaceBranchIntent: Codable, Equatable, Sendable {
    case create(atCommit: String)
    case reuse
}

struct WorkspaceCheckoutMemberPlan: Codable, Equatable, Sendable {
    var checkoutMemberID: UUID
    var projectID: String
    var destinationPath: String
    var baseReference: String
    var baseCommit: String
    var branchIntent: WorkspaceBranchIntent
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

struct WorkspaceWorkItemSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var providerID: String?
    var hostingMemberID: UUID?
    var capturedAt: Date

    init(id: UUID = UUID(), title: String, providerID: String? = nil, hostingMemberID: UUID? = nil, capturedAt: Date = .now) {
        self.id = id
        self.title = title
        self.providerID = providerID
        self.hostingMemberID = hostingMemberID
        self.capturedAt = capturedAt
    }
}

struct WorkspaceCheckoutConfigurationSnapshot: Codable, Equatable, Sendable {
    var capturedAt: Date
    var sharedSettings: [String: String]
    var memberSettings: [UUID: [String: String]]

    init(capturedAt: Date = .now, sharedSettings: [String: String] = [:], memberSettings: [UUID: [String: String]] = [:]) {
        self.capturedAt = capturedAt
        self.sharedSettings = sharedSettings
        self.memberSettings = memberSettings
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
        configurationSnapshot: WorkspaceCheckoutConfigurationSnapshot? = nil
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
    }

    enum CodingKeys: String, CodingKey {
        case id, workspaceID, fallbackWorkspaceName, executionLocation, branch, rootPath
        case createdAt, archivedAt, operation, members, diagnostics, workItems, configurationSnapshot
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
