import Foundation

struct WorkspaceCheckoutProgress: Equatable, Sendable {
    var completedMembers: Int
    var totalMembers: Int
}

enum WorkspaceCheckoutDetailStatus: Equatable, Sendable {
    case ready(String)
    case creating(String)
    case partial(String)
    case needsAttention(String)
    case archived(String)
    case formerWorkspace(String)
    case deleted(String)
}

enum WorkspaceCheckoutHeaderBadge: Equatable, Sendable {
    case archived
    case formerWorkspace
    case stopRequested
}

enum WorkspaceCheckoutActionKind: Equatable, Sendable {
    case archive
    case unarchive
    case deleteCheckout
    case forgetCheckout
    case stopAfterCurrentOperations
    case resumeCreation
    case retrySetup
    case findExisting
    case deleteMember
    case recreateMember
}

struct WorkspaceCheckoutAction: Equatable, Identifiable, Sendable {
    var id: WorkspaceCheckoutActionKind { kind }
    var kind: WorkspaceCheckoutActionKind
    var title: String
    var isDestructive: Bool

    init(_ kind: WorkspaceCheckoutActionKind, title: String, isDestructive: Bool = false) {
        self.kind = kind
        self.title = title
        self.isDestructive = isDestructive
    }
}

enum WorkspaceCheckoutMemberPresentationStatus: Equatable, Sendable {
    case ready
    case creating
    case missing
    case unavailable
    case identityConflict
    case needsAttention
    case explicitlyDeleted
    case pending
}

struct WorkspaceCheckoutMemberRowModel: Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var detail: String
    var status: WorkspaceCheckoutMemberPresentationStatus
    var actions: [WorkspaceCheckoutAction]
}

struct WorkspaceWorkItemRowModel: Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var detail: String
    var hostingMemberID: UUID?
    var refreshError: String?
}

struct WorkspaceMemberReviewRollupRowModel: Equatable, Identifiable {
    var id: UUID { memberID }
    var memberID: UUID
    var title: String
    var reviewCount: Int
    var stackEntryCount: Int
    var unpublishedCount: Int
    var reviewActions: [WorkspaceReviewAction]
}

struct WorkspaceCheckoutDetailModel: Equatable, Sendable {
    var checkout: WorkspaceCheckout
    var reviewRollup: WorkspaceMemberReviewRollup?

    var title: String { checkout.fallbackWorkspaceName }

    var status: WorkspaceCheckoutDetailStatus {
        if checkout.workspaceID == nil { return .formerWorkspace("Former Workspace") }
        if checkout.archivedAt != nil { return .archived("Archived") }
        if checkout.operation == .creating || checkout.operation == .repairing { return .creating("Creating Workspace Checkout") }
        switch checkout.health {
        case .ready:
            return .ready("Ready")
        case .incomplete:
            return .partial("Partially available")
        case .needsAttention:
            return .needsAttention("Needs Attention")
        case .deleted:
            return .deleted("Worktrees deleted")
        }
    }

    var headerBadges: [WorkspaceCheckoutHeaderBadge] {
        var badges: [WorkspaceCheckoutHeaderBadge] = []
        if checkout.archivedAt != nil { badges.append(.archived) }
        if checkout.workspaceID == nil { badges.append(.formerWorkspace) }
        if checkout.stopAfterCurrentOperations { badges.append(.stopRequested) }
        return badges
    }

    var progress: WorkspaceCheckoutProgress {
        WorkspaceCheckoutProgress(
            completedMembers: checkout.members.filter { $0.checkpoint == .setupComplete }.count,
            totalMembers: checkout.members.count
        )
    }

    var stopMessage: String? {
        checkout.stopAfterCurrentOperations
            ? "Stop requested. Current member operations will finish before the checkout pauses."
            : nil
    }

    var diagnostics: [WorkspaceDiagnostic] {
        checkout.diagnostics
    }

    var primaryActions: [WorkspaceCheckoutAction] {
        if checkout.archivedAt != nil {
            return [.init(.unarchive, title: "Unarchive")]
        }
        switch checkout.operation {
        case .creating:
            return checkout.stopAfterCurrentOperations
                ? [.init(.resumeCreation, title: "Resume Creation")]
                : [.init(.resumeCreation, title: "Resume Creation"), .init(.stopAfterCurrentOperations, title: "Stop After Current Operations")]
        case .repairing:
            return checkout.stopAfterCurrentOperations
                ? [.init(.resumeCreation, title: "Resume Creation")]
                : [.init(.resumeCreation, title: "Resume Creation"), .init(.stopAfterCurrentOperations, title: "Stop After Current Operations")]
        case .idle:
            if checkout.health == .deleted {
                // Every worktree is gone; the only thing left to do with the
                // record is drop it. Members keep their own recreate action.
                return [.init(.forgetCheckout, title: "Forget Record", isDestructive: true)]
            }
            var actions: [WorkspaceCheckoutAction] = [.init(.archive, title: "Archive")]
            if checkout.members.contains(where: { $0.availability == .missing || $0.checkpoint == .failed || ($0.availability == .pending && $0.checkpoint != .setupComplete) }) {
                actions.append(.init(.resumeCreation, title: "Resume Creation"))
            }
            if checkout.members.allSatisfy({ $0.cleanup?.worktreeRemoved == true }) {
                actions.append(.init(.forgetCheckout, title: "Forget Record", isDestructive: true))
            } else {
                actions.append(.init(.deleteCheckout, title: "Delete Checkout", isDestructive: true))
            }
            return actions
        case .deleting:
            return [.init(.deleteCheckout, title: "Resume Deletion", isDestructive: true)]
        case .archiving:
            return [.init(.archive, title: "Resume Archive")]
        case .cleaning:
            return []
        }
    }

    var memberRows: [WorkspaceCheckoutMemberRowModel] {
        checkout.members.map { member in
            WorkspaceCheckoutMemberRowModel(
                id: member.id,
                title: member.fallbackProjectName,
                detail: detail(for: member),
                status: status(for: member),
                actions: checkout.archivedAt == nil && checkout.operation == .idle ? actions(for: member) : []
            )
        }
    }

    var workItemRows: [WorkspaceWorkItemRowModel] {
        checkout.workItems.map {
            WorkspaceWorkItemRowModel(
                id: $0.id,
                title: $0.snapshot.title,
                detail: $0.snapshot.displayReference ?? $0.snapshot.providerLabel,
                hostingMemberID: $0.hostingMemberID,
                refreshError: $0.snapshot.refreshError
            )
        }
    }

    var reviewRollupRows: [WorkspaceMemberReviewRollupRowModel] {
        reviewRollup?.members.map {
            WorkspaceMemberReviewRollupRowModel(
                memberID: $0.memberID,
                title: $0.title,
                reviewCount: $0.reviews.count,
                stackEntryCount: $0.ggStack?.entries.count ?? 0,
                unpublishedCount: $0.unpublishedStackEntries.count,
                reviewActions: $0.reviewActions
            )
        } ?? []
    }

    static func nearestPeer(afterDeleting deletedID: UUID, orderedCheckoutIDs: [UUID]) -> UUID? {
        guard let index = orderedCheckoutIDs.firstIndex(of: deletedID) else { return orderedCheckoutIDs.first }
        if index + 1 < orderedCheckoutIDs.count { return orderedCheckoutIDs[index + 1] }
        if index > 0 { return orderedCheckoutIDs[index - 1] }
        return nil
    }

    private func status(for member: WorkspaceCheckoutMember) -> WorkspaceCheckoutMemberPresentationStatus {
        switch member.availability {
        case .available where member.deletionFailed:
            return .needsAttention
        case .available where member.checkpoint == .setupComplete:
            return .ready
        case .available where member.checkpoint == .failed:
            return .needsAttention
        case .available:
            return .creating
        case .pending:
            return .pending
        case .missing:
            return .missing
        case .unavailable:
            return .unavailable
        case .identityConflict:
            return .identityConflict
        case .explicitlyDeleted:
            return .explicitlyDeleted
        }
    }

    private func detail(for member: WorkspaceCheckoutMember) -> String {
        if member.deletionFailed, member.checkpoint != .failed {
            if let diagnostic = checkout.diagnostics.last(where: { $0.isDeletionFailure(for: member.id) }) {
                return [diagnostic.message, diagnostic.detail ?? ""]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            return "The worktree could not be removed. Delete it again to retry."
        }
        switch member.availability {
        case .missing: return "Worktree not found at \(member.worktreePath)"
        case .unavailable: return "Could not access \(member.worktreePath)"
        case .identityConflict: return "The worktree at \(member.worktreePath) does not match this checkout."
        case .explicitlyDeleted: return "Worktree removed from \(member.worktreePath)"
        case .available, .pending: break
        }
        switch member.checkpoint {
        case .notStarted:
            return "Waiting to start"
        case .planPersisted:
            return "Plan persisted"
        case .branchPreparing:
            return "Preparing branch"
        case .branchPrepared:
            return "Branch prepared"
        case .worktreeCreating:
            return "Creating worktree"
        case .worktreeCreated:
            return "Worktree created"
        case .setupRunning:
            return "Running setup"
        case .setupComplete:
            return "Ready at \(member.worktreePath)"
        case .failed:
            return "Needs attention before continuing"
        }
    }

    private func actions(for member: WorkspaceCheckoutMember) -> [WorkspaceCheckoutAction] {
        switch member.availability {
        case .identityConflict:
            return [.init(.findExisting, title: "Find Existing"), .init(.deleteMember, title: "Delete Snapshot", isDestructive: true)]
        case .explicitlyDeleted:
            return [.init(.recreateMember, title: "Recreate from Frozen Plan")]
        case .missing, .unavailable:
            return [.init(.findExisting, title: "Find Existing"), .init(.resumeCreation, title: "Resume Creation")]
        case .available where member.checkpoint == .failed:
            return [.init(.retrySetup, title: "Retry Setup")]
        case .available:
            return [.init(.deleteMember, title: "Delete Worktree", isDestructive: true)]
        case .pending where member.checkpoint != .setupComplete:
            return [.init(.resumeCreation, title: "Resume Creation")]
        case .pending:
            return []
        }
    }
}

enum WorkspaceLifecycleAction: Equatable, Sendable {
    case deleteCheckout(confirmingRisks: Bool)
    case deleteMember(confirmingRisks: Bool)
    case forgetCheckout(confirmedPreserveArtifacts: Bool)
}

struct WorkspaceLifecycleConfirmationModel: Equatable, Sendable {
    var title: String
    var risks: [String]
    var confirmAction: WorkspaceLifecycleAction
    var canForceDelete: Bool

    var requiresConfirmation: Bool { !risks.isEmpty }

    static func memberDeletion(member: WorkspaceCheckoutMember, preflight: WorktreeDeletePreflight) -> WorkspaceLifecycleConfirmationModel {
        var risks: [String] = []
        if preflight.reasons.contains(.dirty) { risks.append("Uncommitted changes") }
        if preflight.reasons.contains(.locked) { risks.append("Locked worktree") }
        return WorkspaceLifecycleConfirmationModel(
            title: "Delete Workspace Member Worktree?",
            risks: risks,
            confirmAction: .deleteMember(confirmingRisks: preflight.requiresForce),
            canForceDelete: false
        )
    }

    /// `requiresForce` separates "Git will force-remove content" from softer
    /// risks such as sessions that will close; only the former should make
    /// the coordinator pass a force flag to Git.
    static func checkoutDeletion(risks: [String], requiresForce: Bool? = nil) -> WorkspaceLifecycleConfirmationModel {
        WorkspaceLifecycleConfirmationModel(
            title: "Delete Workspace Checkout?",
            risks: risks,
            confirmAction: .deleteCheckout(confirmingRisks: requiresForce ?? !risks.isEmpty),
            canForceDelete: false
        )
    }

    /// `unverifiedMemberCount` counts members with no cleanup record at all —
    /// snapshot-only members whose creation never produced a worktree. The
    /// coordinator refuses to forget those without `confirmedPreserveArtifacts`,
    /// but they carry no concrete leftover to list, so without surfacing them
    /// here `requiresConfirmation` would stay false and nothing would ever
    /// set that flag — the record could never actually be forgotten.
    static func forgetCheckout(
        cleanups: [WorkspaceCheckoutMemberCleanup],
        unverifiedMemberCount: Int = 0,
        confirmedPreserveArtifacts: Bool
    ) -> WorkspaceLifecycleConfirmationModel {
        var risks: [String] = []
        for cleanup in cleanups {
            risks.append(contentsOf: cleanup.sharedRootLeftovers)
            if cleanup.plan.branchOwnership == .created, cleanup.branchRemoved == false {
                risks.append("Retained branch \(cleanup.plan.branch)")
            }
        }
        if unverifiedMemberCount > 0 {
            risks.append("\(unverifiedMemberCount) \(unverifiedMemberCount == 1 ? "member was" : "members were") never verified as removed")
        }
        return WorkspaceLifecycleConfirmationModel(
            title: risks.isEmpty ? "Forget Workspace Checkout?" : "Forget Workspace Checkout and Preserve Artifacts?",
            risks: risks,
            confirmAction: .forgetCheckout(confirmedPreserveArtifacts: confirmedPreserveArtifacts || !risks.isEmpty),
            canForceDelete: false
        )
    }
}

struct WorkspaceRepairCandidate: Equatable, Identifiable, Sendable {
    var id: String { path }
    var path: String
    var lineageID: String
    var isExactMatch: Bool
}

enum WorkspaceRepairAction: Equatable, Sendable {
    case useExistingVerifiedCandidate
}

struct WorkspaceRepairPlanModel: Equatable, Sendable {
    var memberName: String
    var candidates: [WorkspaceRepairCandidate]

    var verifiedCandidates: [WorkspaceRepairCandidate] { candidates.filter(\.isExactMatch) }

    func actions(for candidate: WorkspaceRepairCandidate) -> [WorkspaceRepairAction] {
        candidate.isExactMatch ? [.useExistingVerifiedCandidate] : []
    }
}
