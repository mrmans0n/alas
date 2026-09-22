import Foundation

enum WorkspaceCheckoutCreationStep: Int, Equatable { case details, preflight, creating }
enum WorkspaceCheckoutCreationAdvanceResult: Equatable { case success, failure(String) }
struct WorkspaceCheckoutCreationProgress: Equatable { var completedMembers: Int
var totalMembers: Int }

/// UI-owned flow state. Git is read only until its complete frozen plan is
/// received; selection begins only after coordinator persistence succeeds.
struct WorkspaceCheckoutCreationModel: Equatable {
    let workspace: Workspace
    /// Configured worktree branch prefix. Never part of `branch`: the field
    /// holds the bare name and `composedBranch` is the ref git is asked for.
    let branchPrefix: String
    /// The typed branch name, without `branchPrefix`.
    var branch: String
    var rootPath: String
    var baseReference: String
    private(set) var checkoutParentPath: String?
    var memberBaseReferences: [UUID: String] = [:]
    private(set) var step: WorkspaceCheckoutCreationStep = .details
    private(set) var preflightResult: WorkspaceCheckoutPreflightResult?
    private(set) var selectedCheckoutID: UUID?

    init(
        workspace: Workspace,
        branchPrefix: String = "",
        branch: String = "",
        rootPath: String = "",
        baseReference: String = "main"
    ) {
        self.workspace = workspace
        self.branchPrefix = branchPrefix
        self.branch = branch
        self.rootPath = rootPath
        self.baseReference = baseReference
    }

    /// The shared branch actually created: prefix + typed name.
    var composedBranch: String {
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "" : branchPrefix + name
    }

    static func checkoutRoot(parentPath: String, branch: String) -> String {
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return "" }
        return URL(fileURLWithPath: parentPath)
            .appendingPathComponent(branch.replacingOccurrences(of: "/", with: "-"))
            .path
    }

    mutating func selectCheckoutParent(_ parentPath: String) {
        checkoutParentPath = parentPath
        rootPath = Self.checkoutRoot(parentPath: parentPath, branch: composedBranch)
    }

    mutating func setBranch(_ branch: String) {
        self.branch = branch
        if let checkoutParentPath {
            rootPath = Self.checkoutRoot(parentPath: checkoutParentPath, branch: composedBranch)
        }
    }

    mutating func setRootPath(_ rootPath: String) {
        checkoutParentPath = nil
        self.rootPath = rootPath
    }

    var preflightMessages: [String] {
        guard case .failure(let diagnostics) = preflightResult else { return [] }
        return diagnostics.map(\.message)
    }

    func request() -> WorkspaceCheckoutRequest {
        .init(workspace: workspace, branch: composedBranch, rootPath: rootPath.trimmingCharacters(in: .whitespacesAndNewlines), baseReference: baseReference.trimmingCharacters(in: .whitespacesAndNewlines), memberBaseReferences: memberBaseReferences)
    }

    mutating func advance() -> WorkspaceCheckoutCreationAdvanceResult {
        guard !composedBranch.isEmpty else { return .failure("A shared branch is required.") }
        guard !rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure("Checkout root is required.") }
        step = .preflight
        return .success
    }

    mutating func receivePreflight(_ result: WorkspaceCheckoutPreflightResult) { preflightResult = result
    step = .preflight
    selectedCheckoutID = nil }
    mutating func returnToDetails() {
        step = .details
        preflightResult = nil
        selectedCheckoutID = nil
    }
    mutating func beginCreation() -> Bool { guard case .success = preflightResult else { return false }
    step = .creating
    return true }
    mutating func didPersist(checkoutID: UUID) { guard step == .creating, case .success = preflightResult else { return }
    selectedCheckoutID = checkoutID }

    func progress(for checkout: WorkspaceCheckout) -> WorkspaceCheckoutCreationProgress {
        .init(completedMembers: checkout.members.filter { $0.checkpoint == .setupComplete }.count, totalMembers: checkout.members.count)
    }
}
