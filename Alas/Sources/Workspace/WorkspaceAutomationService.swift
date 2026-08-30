import Foundation

enum WorkspaceAutomationError: Error, Equatable, Sendable {
    case disabled
    case recoveryRequired
    case checkoutNotFound
    case memberNotFound
    case memberRequired
    case memberUnavailable
    case ambiguous

    var code: String {
        switch self {
        case .disabled: "workspace_disabled"
        case .recoveryRequired: "workspace_recovery_required"
        case .checkoutNotFound: "workspace_checkout_not_found"
        case .memberNotFound: "workspace_member_not_found"
        case .memberRequired: "workspace_member_required"
        case .memberUnavailable: "workspace_member_unavailable"
        case .ambiguous: "workspace_ambiguous"
        }
    }

    var exitCode: Int {
        switch self {
        case .disabled, .checkoutNotFound, .memberNotFound, .memberRequired, .memberUnavailable: 2
        case .ambiguous: 1
        case .recoveryRequired: 3
        }
    }

    var message: String {
        switch self {
        case .disabled: "Workspace preview is disabled."
        case .recoveryRequired: "Workspace storage requires recovery."
        case .checkoutNotFound: "Workspace Checkout not found."
        case .memberNotFound: "Workspace Checkout member not found."
        case .memberRequired: "Workspace Checkout member is required."
        case .memberUnavailable: "Workspace Checkout member is unavailable."
        case .ambiguous: "Workspace target is ambiguous."
        }
    }
}

struct WorkspaceAutomationDiagnostic: Codable, Equatable, Sendable {
    var severity: WorkspaceDiagnosticSeverity
    var code: String
    var message: String
}

struct WorkspaceAutomationMemberSummary: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var projectID: String
    var name: String
    var worktreePath: String
    var availability: WorkspaceCheckoutMemberAvailability
    var checkpoint: WorkspaceCheckoutCheckpoint
}

struct WorkspaceAutomationCheckoutSummary: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var workspaceID: UUID?
    var name: String
    var executionLocation: ExecutionLocation
    var branch: String
    var rootPath: String
    var operation: WorkspaceCheckoutOperation
    var health: WorkspaceCheckoutHealth
    var archivedAt: Date?
    var diagnostics: [WorkspaceAutomationDiagnostic]
    var members: [WorkspaceAutomationMemberSummary]
}

struct WorkspaceAutomationListResponse: Codable, Equatable, Sendable {
    var version: Int = 1
    var checkouts: [WorkspaceAutomationCheckoutSummary]
    var diagnostics: [WorkspaceAutomationDiagnostic] = []
}

struct WorkspaceAutomationShowResponse: Codable, Equatable, Sendable {
    var version: Int = 1
    var checkout: WorkspaceAutomationCheckoutSummary
    var diagnostics: [WorkspaceAutomationDiagnostic] = []
}

struct WorkspaceAutomationTarget: Codable, Equatable, Sendable {
    var checkoutID: UUID
    var memberID: UUID
    var executionLocation: ExecutionLocation
    var checkoutRoot: String
    var worktreePath: String
    var projectID: String
}

struct WorkspaceAutomationService {
    var store: WorkspaceStore
    var isEnabled: () -> Bool
    var selectCheckout: @MainActor (UUID) -> Void
    var focusMember: @MainActor (UUID, UUID) -> Void

    init(
        store: WorkspaceStore,
        isEnabled: @escaping () -> Bool,
        selectCheckout: @escaping @MainActor (UUID) -> Void = { _ in },
        focusMember: @escaping @MainActor (UUID, UUID) -> Void = { _, _ in }
    ) {
        self.store = store
        self.isEnabled = isEnabled
        self.selectCheckout = selectCheckout
        self.focusMember = focusMember
    }

    func listCheckouts() async throws -> WorkspaceAutomationListResponse {
        let state = try await loadedState()
        return WorkspaceAutomationListResponse(
            checkouts: state.checkouts
                .filter { $0.archivedAt == nil }
                .map(Self.summary)
        )
    }

    func showCheckout(id: UUID) async throws -> WorkspaceAutomationShowResponse {
        let checkout = try await checkout(id: id)
        return WorkspaceAutomationShowResponse(checkout: Self.summary(checkout))
    }

    @MainActor
    func selectCheckout(id: UUID) async throws {
        _ = try await checkout(id: id)
        selectCheckout(id)
    }

    @MainActor
    func focusMember(checkoutID: UUID, memberID: UUID) async throws {
        _ = try await memberTarget(checkoutID: checkoutID, memberID: memberID)
        focusMember(checkoutID, memberID)
    }

    func memberTarget(checkoutID: UUID, memberID: UUID?) async throws -> WorkspaceAutomationTarget {
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
        guard isEnabled() else { throw WorkspaceAutomationError.disabled }
        switch await store.load() {
        case .loaded(let state): return state
        case .missing: return WorkspaceStateFile()
        case .unreadable: throw WorkspaceAutomationError.recoveryRequired
        }
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
    static var workspaceAutomation: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
