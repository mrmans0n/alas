import Foundation

/// The result of inspecting the exact path and Git lineage frozen for a
/// checkout member. Implementations must not infer this from a branch or path
/// alone.
enum WorkspaceCheckoutMemberObservation: Equatable, Sendable {
    case missing
    case exactLineage(String)
    case identityConflict(String?)
    case unavailable(String)
}

/// Narrow read-only seam for relaunch classification. Git and scripts remain
/// outside this protocol so reconciliation cannot accidentally resume work.
protocol WorkspaceCheckoutObserving: Sendable {
    func observe(_ member: WorkspaceCheckoutMember, in checkout: WorkspaceCheckout) async -> WorkspaceCheckoutMemberObservation
}

actor WorkspaceCheckoutReconciler {
    private let store: WorkspaceStore
    private let observer: any WorkspaceCheckoutObserving

    init(store: WorkspaceStore, observer: any WorkspaceCheckoutObserving) {
        self.store = store
        self.observer = observer
    }

    /// Classifies persisted members after relaunch without writing state. This
    /// neither adopts/backfills lineage nor creates a worktree or script run.
    func reconcile(checkoutID: UUID) async throws -> WorkspaceCheckoutReconciliation {
        guard case .loaded(let state) = await store.load(),
              let checkout = state.checkouts.first(where: { $0.id == checkoutID })
        else { throw WorkspaceCheckoutCoordinatorError.checkoutMissing }

        var observations: [UUID: WorkspaceCheckoutMemberObservation] = [:]
        for member in checkout.members {
            observations[member.id] = await observer.observe(member, in: checkout)
        }
        return WorkspaceCheckoutReconciliation(checkoutID: checkout.id, observations: observations)
    }
}

struct WorkspaceCheckoutReconciliation: Equatable, Sendable {
    var checkoutID: UUID
    var observations: [UUID: WorkspaceCheckoutMemberObservation]
}

/// Concrete inspection uses read-only Git commands and existing transport;
/// notably it reads an existing lineage marker rather than creating one.
struct WorkspaceCheckoutObserver: WorkspaceCheckoutObserving {
    private let remote: WorkspaceRemoteTransport

    init(remote: WorkspaceRemoteTransport = .init()) {
        self.remote = remote
    }

    func observe(_ member: WorkspaceCheckoutMember, in checkout: WorkspaceCheckout) async -> WorkspaceCheckoutMemberObservation {
        guard let plan = member.plan,
              plan.checkoutMemberID == member.id,
              plan.destinationPath == member.worktreePath,
              !plan.sourceRepositoryPath.isEmpty,
              !plan.baseCommit.isEmpty
        else { return .identityConflict(nil) }
        switch checkout.executionLocation.normalized {
        case .local:
            let destination = URL(fileURLWithPath: plan.destinationPath)
            guard FileManager.default.fileExists(atPath: destination.path) else { return .missing }
            guard let lineage = WorktreeService.existingLocalLineageID(forWorktreeAt: destination) else {
                return .identityConflict(nil)
            }
            return member.gitLineageID == lineage ? .exactLineage(lineage) : .identityConflict(lineage)
        case .ssh(let host):
            let path = SSHCommand.shellQuote(plan.destinationPath)
            let command = "p=\(path); d=$(git -C \"$p\" rev-parse --absolute-git-dir) || exit 1; f=\"$d/alas-worktree-lineage\"; test -s \"$f\" && head -n 1 \"$f\""
            guard let result = try? await remote.run(host: host, command: command) else {
                return .unavailable("Could not inspect Workspace member on \(host).")
            }
            guard result.exitCode == 0 else { return .missing }
            let lineage = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lineage.isEmpty else { return .identityConflict(nil) }
            return member.gitLineageID == lineage ? .exactLineage(lineage) : .identityConflict(lineage)
        }
    }
}
