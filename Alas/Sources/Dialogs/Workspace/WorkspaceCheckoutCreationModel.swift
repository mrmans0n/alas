import Foundation

enum WorkspaceCheckoutCreationStep: Int, Equatable { case details, preflight, creating }
enum WorkspaceCheckoutCreationAdvanceResult: Equatable { case success, failure(String) }
struct WorkspaceCheckoutCreationProgress: Equatable { var completedMembers: Int; var totalMembers: Int }

/// UI-owned flow state. Git is read only until its complete frozen plan is
/// received; selection begins only after coordinator persistence succeeds.
struct WorkspaceCheckoutCreationModel: Equatable {
    let workspace: Workspace
    var branch: String
    var rootPath: String
    var baseReference: String
    var memberBaseReferences: [UUID: String] = [:]
    private(set) var step: WorkspaceCheckoutCreationStep = .details
    private(set) var preflightResult: WorkspaceCheckoutPreflightResult?
    private(set) var selectedCheckoutID: UUID?

    init(workspace: Workspace, branch: String = "", rootPath: String = "", baseReference: String = "main") {
        self.workspace = workspace; self.branch = branch; self.rootPath = rootPath; self.baseReference = baseReference
    }

    var preflightMessages: [String] {
        guard case .failure(let diagnostics) = preflightResult else { return [] }
        return diagnostics.map(\.message)
    }

    func request() -> WorkspaceCheckoutRequest {
        .init(workspace: workspace, branch: branch.trimmingCharacters(in: .whitespacesAndNewlines), rootPath: rootPath.trimmingCharacters(in: .whitespacesAndNewlines), baseReference: baseReference.trimmingCharacters(in: .whitespacesAndNewlines), memberBaseReferences: memberBaseReferences)
    }

    mutating func advance() -> WorkspaceCheckoutCreationAdvanceResult {
        guard !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure("A shared branch is required.") }
        guard !rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure("Checkout root is required.") }
        step = .preflight
        return .success
    }

    mutating func receivePreflight(_ result: WorkspaceCheckoutPreflightResult) { preflightResult = result; step = .preflight; selectedCheckoutID = nil }
    mutating func beginCreation() -> Bool { guard case .success = preflightResult else { return false }; step = .creating; return true }
    mutating func didPersist(checkoutID: UUID) { guard step == .creating, case .success = preflightResult else { return }; selectedCheckoutID = checkoutID }

    func progress(for checkout: WorkspaceCheckout) -> WorkspaceCheckoutCreationProgress {
        .init(completedMembers: checkout.members.filter { $0.checkpoint == .setupComplete }.count, totalMembers: checkout.members.count)
    }
}
