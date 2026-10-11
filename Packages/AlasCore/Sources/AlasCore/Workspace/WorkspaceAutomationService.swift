import Foundation

public enum WorkspaceAutomationError: Error, Equatable, Sendable {
    case recoveryRequired
    case checkoutNotFound
    case memberNotFound
    case memberRequired
    case memberUnavailable
    case ambiguous

    public var code: String {
        switch self {
        case .recoveryRequired: "workspace_recovery_required"
        case .checkoutNotFound: "workspace_checkout_not_found"
        case .memberNotFound: "workspace_member_not_found"
        case .memberRequired: "workspace_member_required"
        case .memberUnavailable: "workspace_member_unavailable"
        case .ambiguous: "workspace_ambiguous"
        }
    }

    public var exitCode: Int {
        switch self {
        case .checkoutNotFound, .memberNotFound, .memberRequired, .memberUnavailable: 2
        case .ambiguous: 1
        case .recoveryRequired: 3
        }
    }

    public var message: String {
        switch self {
        case .recoveryRequired: "Workspace storage requires recovery."
        case .checkoutNotFound: "Workspace Checkout not found."
        case .memberNotFound: "Workspace Checkout member not found."
        case .memberRequired: "Workspace Checkout member is required."
        case .memberUnavailable: "Workspace Checkout member is unavailable."
        case .ambiguous: "Workspace target is ambiguous."
        }
    }
}

public struct WorkspaceAutomationDiagnostic: Codable, Equatable, Sendable {
    public var severity: WorkspaceDiagnosticSeverity
    public var code: String
    public var message: String

    public init(severity: WorkspaceDiagnosticSeverity, code: String, message: String) {
        self.severity = severity
        self.code = code
        self.message = message
    }
}

public struct WorkspaceAutomationMemberSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectID: String
    public var name: String
    public var worktreePath: String
    public var availability: WorkspaceCheckoutMemberAvailability
    public var checkpoint: WorkspaceCheckoutCheckpoint

    public init(id: UUID, projectID: String, name: String, worktreePath: String, availability: WorkspaceCheckoutMemberAvailability, checkpoint: WorkspaceCheckoutCheckpoint) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.worktreePath = worktreePath
        self.availability = availability
        self.checkpoint = checkpoint
    }
}

public struct WorkspaceAutomationCheckoutSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var workspaceID: UUID?
    public var name: String
    public var executionLocation: ExecutionLocation
    public var branch: String
    public var rootPath: String
    public var operation: WorkspaceCheckoutOperation
    public var health: WorkspaceCheckoutHealth
    public var archivedAt: Date?
    public var diagnostics: [WorkspaceAutomationDiagnostic]
    public var members: [WorkspaceAutomationMemberSummary]

    public init(id: UUID, workspaceID: UUID? = nil, name: String, executionLocation: ExecutionLocation, branch: String, rootPath: String, operation: WorkspaceCheckoutOperation, health: WorkspaceCheckoutHealth, archivedAt: Date? = nil, diagnostics: [WorkspaceAutomationDiagnostic], members: [WorkspaceAutomationMemberSummary]) {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.executionLocation = executionLocation
        self.branch = branch
        self.rootPath = rootPath
        self.operation = operation
        self.health = health
        self.archivedAt = archivedAt
        self.diagnostics = diagnostics
        self.members = members
    }
}

public struct WorkspaceAutomationListResponse: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var checkouts: [WorkspaceAutomationCheckoutSummary]
    public var diagnostics: [WorkspaceAutomationDiagnostic] = []

    public init(version: Int = 1, checkouts: [WorkspaceAutomationCheckoutSummary], diagnostics: [WorkspaceAutomationDiagnostic] = []) {
        self.version = version
        self.checkouts = checkouts
        self.diagnostics = diagnostics
    }
}

public struct WorkspaceAutomationShowResponse: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var checkout: WorkspaceAutomationCheckoutSummary
    public var diagnostics: [WorkspaceAutomationDiagnostic] = []

    public init(version: Int = 1, checkout: WorkspaceAutomationCheckoutSummary, diagnostics: [WorkspaceAutomationDiagnostic] = []) {
        self.version = version
        self.checkout = checkout
        self.diagnostics = diagnostics
    }
}

public struct WorkspaceAutomationTarget: Codable, Equatable, Sendable {
    public var checkoutID: UUID
    public var memberID: UUID
    public var executionLocation: ExecutionLocation
    public var checkoutRoot: String
    public var worktreePath: String
    public var projectID: String

    public init(checkoutID: UUID, memberID: UUID, executionLocation: ExecutionLocation, checkoutRoot: String, worktreePath: String, projectID: String) {
        self.checkoutID = checkoutID
        self.memberID = memberID
        self.executionLocation = executionLocation
        self.checkoutRoot = checkoutRoot
        self.worktreePath = worktreePath
        self.projectID = projectID
    }
}

public struct WorkspaceAutomationService: Sendable {
    public var store: WorkspaceStore
    public var refreshNavigation: @MainActor @Sendable () async -> Void
    public var selectCheckout: @MainActor @Sendable (UUID) -> Void
    public var focusMember: @MainActor @Sendable (UUID, UUID) -> Void
    public var observer: any WorkspaceCheckoutObserving

    public init(
        store: WorkspaceStore,
        refreshNavigation: @escaping @MainActor @Sendable () async -> Void = {},
        selectCheckout: @escaping @MainActor @Sendable (UUID) -> Void = { _ in },
        focusMember: @escaping @MainActor @Sendable (UUID, UUID) -> Void = { _, _ in },
        observer: any WorkspaceCheckoutObserving = WorkspaceCheckoutObserver()
    ) {
        self.store = store
        self.refreshNavigation = refreshNavigation
        self.selectCheckout = selectCheckout
        self.focusMember = focusMember
        self.observer = observer
    }

    public func listCheckouts() async throws -> WorkspaceAutomationListResponse {
        let state = try await loadedState()
        return WorkspaceAutomationListResponse(
            checkouts: state.checkouts
                .filter { $0.archivedAt == nil }
                .map(Self.summary)
        )
    }

    public func showCheckout(id: UUID) async throws -> WorkspaceAutomationShowResponse {
        let checkout = try await checkout(id: id)
        return WorkspaceAutomationShowResponse(checkout: Self.summary(checkout))
    }

    @MainActor
    public func selectCheckout(id: UUID) async throws {
        _ = try await checkout(id: id)
        await refreshNavigation()
        selectCheckout(id)
    }

    @MainActor
    public func focusMember(checkoutID: UUID, memberID: UUID) async throws {
        _ = try await memberTarget(checkoutID: checkoutID, memberID: memberID)
        await refreshNavigation()
        focusMember(checkoutID, memberID)
    }

    public func memberTarget(checkoutID: UUID, memberID: UUID?) async throws -> WorkspaceAutomationTarget {
        let checkout = try await checkout(id: checkoutID)
        guard let memberID else {
            throw WorkspaceAutomationError.memberRequired
        }
        guard let member = checkout.members.first(where: { $0.id == memberID }) else {
            throw WorkspaceAutomationError.memberNotFound
        }
        guard member.availability == .available else {
            throw WorkspaceAutomationError.memberUnavailable
        }
        return Self.target(checkout: checkout, member: member)
    }

    private func loadedState() async throws -> WorkspaceStateFile {
        switch await store.load() {
        case .loaded(let state): return await reconciled(state)
        case .missing: return WorkspaceStateFile()
        case .unreadable: throw WorkspaceAutomationError.recoveryRequired
        }
    }

    private func reconciled(_ state: WorkspaceStateFile) async -> WorkspaceStateFile {
        var copy = state
        for checkoutIndex in copy.checkouts.indices {
            let checkout = copy.checkouts[checkoutIndex]
            for memberIndex in checkout.members.indices {
                let member = checkout.members[memberIndex]
                guard member.availability != .explicitlyDeleted else { continue }
                switch await observer.observe(member, in: checkout) {
                case .exactLineage:
                    copy.checkouts[checkoutIndex].members[memberIndex].availability = .available
                case .missing:
                    copy.checkouts[checkoutIndex].members[memberIndex].availability = .missing
                case .identityConflict:
                    copy.checkouts[checkoutIndex].members[memberIndex].availability = .identityConflict
                case .unavailable:
                    copy.checkouts[checkoutIndex].members[memberIndex].availability = .unavailable
                }
            }
        }
        return copy
    }

    private func checkout(id: UUID) async throws -> WorkspaceCheckout {
        let state = try await loadedState()
        guard let checkout = state.checkouts.first(where: { $0.id == id && $0.archivedAt == nil }) else {
            throw WorkspaceAutomationError.checkoutNotFound
        }
        return checkout
    }

    private static func summary(_ checkout: WorkspaceCheckout) -> WorkspaceAutomationCheckoutSummary {
        WorkspaceAutomationCheckoutSummary(
            id: checkout.id,
            workspaceID: checkout.workspaceID,
            name: checkout.fallbackWorkspaceName,
            executionLocation: checkout.executionLocation,
            branch: checkout.branch,
            rootPath: checkout.rootPath,
            operation: checkout.operation,
            health: checkout.health,
            archivedAt: checkout.archivedAt,
            diagnostics: checkout.diagnostics.map {
                WorkspaceAutomationDiagnostic(severity: $0.severity, code: "workspace_diagnostic", message: $0.message)
            },
            members: checkout.members.map {
                WorkspaceAutomationMemberSummary(
                    id: $0.id,
                    projectID: $0.projectID,
                    name: $0.fallbackProjectName,
                    worktreePath: $0.worktreePath,
                    availability: $0.availability,
                    checkpoint: $0.checkpoint
                )
            }
        )
    }

    private static func target(checkout: WorkspaceCheckout, member: WorkspaceCheckoutMember) -> WorkspaceAutomationTarget {
        WorkspaceAutomationTarget(
            checkoutID: checkout.id,
            memberID: member.id,
            executionLocation: checkout.executionLocation,
            checkoutRoot: checkout.rootPath,
            worktreePath: member.worktreePath,
            projectID: member.projectID
        )
    }
}

extension JSONEncoder {
    public static var workspaceAutomation: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
