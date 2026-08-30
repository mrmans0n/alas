import Foundation

/// Runtime navigation for the mixed Project/Workspace sidebar. Workspace
/// selection is deliberately distinct from repository focus: the former owns
/// shared sessions, while the latter only supplies a member worktree to the
/// existing repository panes.
struct WorkspaceNavigationState: Equatable {
    var selectedWorkspaceID: UUID?
    var selectedCheckoutID: UUID?
    var focusedCheckoutMemberID: UUID?
    private(set) var repositoryFocusWorktreeID: String?
    private var lastFocusedMemberByCheckoutID: [UUID: UUID] = [:]

    init(
        selectedWorkspaceID: UUID? = nil,
        selectedCheckoutID: UUID? = nil,
        focusedCheckoutMemberID: UUID? = nil,
        repositoryFocusWorktreeID: String? = nil
    ) {
        self.selectedWorkspaceID = selectedWorkspaceID
        self.selectedCheckoutID = selectedCheckoutID
        self.focusedCheckoutMemberID = focusedCheckoutMemberID
        self.repositoryFocusWorktreeID = repositoryFocusWorktreeID
        if let selectedCheckoutID, let focusedCheckoutMemberID {
            lastFocusedMemberByCheckoutID[selectedCheckoutID] = focusedCheckoutMemberID
        }
    }

    mutating func selectWorkspace(_ workspaceID: UUID) {
        selectedWorkspaceID = workspaceID
        selectedCheckoutID = nil
        focusedCheckoutMemberID = nil
        repositoryFocusWorktreeID = nil
    }

    mutating func selectCheckout(
        _ checkout: WorkspaceCheckout,
        resolvedWorktreeIDs: [UUID: String]
    ) {
        selectedCheckoutID = checkout.id
        selectedWorkspaceID = checkout.workspaceID
        let preferred = lastFocusedMemberByCheckoutID[checkout.id] ?? focusedCheckoutMemberID
        selectAvailableMember(in: checkout, preferred: preferred, resolvedWorktreeIDs: resolvedWorktreeIDs)
    }

    mutating func selectMember(
        _ memberID: UUID,
        in checkout: WorkspaceCheckout,
        resolvedWorktreeIDs: [UUID: String]
    ) {
        guard checkout.members.contains(where: { $0.id == memberID && $0.availability == .available }),
              let worktreeID = resolvedWorktreeIDs[memberID]
        else { return }
        selectedCheckoutID = checkout.id
        selectedWorkspaceID = checkout.workspaceID
        focusedCheckoutMemberID = memberID
        repositoryFocusWorktreeID = worktreeID
        lastFocusedMemberByCheckoutID[checkout.id] = memberID
    }

    mutating func removeCheckout(_ checkoutID: UUID) {
        lastFocusedMemberByCheckoutID[checkoutID] = nil
        guard selectedCheckoutID == checkoutID else { return }
        selectedCheckoutID = nil
        focusedCheckoutMemberID = nil
        repositoryFocusWorktreeID = nil
    }

    mutating func clearCheckoutSelection() {
        selectedWorkspaceID = nil
        selectedCheckoutID = nil
        focusedCheckoutMemberID = nil
        repositoryFocusWorktreeID = nil
    }

    private mutating func selectAvailableMember(
        in checkout: WorkspaceCheckout,
        preferred: UUID?,
        resolvedWorktreeIDs: [UUID: String]
    ) {
        let members = checkout.members
        guard !members.isEmpty else {
            focusedCheckoutMemberID = nil
            repositoryFocusWorktreeID = nil
            return
        }

        let start = preferred.flatMap { id in members.firstIndex(where: { $0.id == id }) } ?? 0
        for offset in members.indices {
            let index = (start + offset) % members.count
            let member = members[index]
            if member.availability == .available,
               let worktreeID = resolvedWorktreeIDs[member.id] {
                focusedCheckoutMemberID = member.id
                repositoryFocusWorktreeID = worktreeID
                lastFocusedMemberByCheckoutID[checkout.id] = member.id
                return
            }
        }
        focusedCheckoutMemberID = nil
        repositoryFocusWorktreeID = nil
    }
}

enum WorkspaceSidebarRow: Equatable {
    case project(String)
    case workspace(UUID)
    case checkout(UUID)
    case member(UUID)
}

enum WorkspaceMemberWorktreeResolver {
    /// Resolves a checkout member only when both its frozen Project identity
    /// and destination match. A matching path from another Project is never
    /// a valid Repository Focus target.
    static func resolvedWorktreeIDs(
        checkout: WorkspaceCheckout,
        worktrees: [Worktree]
    ) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: checkout.members.compactMap { member in
            guard member.availability == .available,
                  let worktree = worktrees.first(where: {
                      $0.projectId == member.projectID
                          && $0.path.standardizedFileURL.path == URL(fileURLWithPath: member.worktreePath).standardizedFileURL.path
                  })
            else { return nil }
            return (member.id, worktree.id)
        })
    }
}

/// Pure presentation plan for the full sidebar tree. Views own disclosure
/// state; this type only protects ordering and archive visibility.
enum WorkspaceSidebarLayout {
    static func rows(
        members: [SpaceMemberReference],
        workspaces: [Workspace],
        checkouts: [WorkspaceCheckout]
    ) -> [WorkspaceSidebarRow] {
        let workspacesByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let activeCheckouts = checkouts.filter { $0.archivedAt == nil }
        var rows: [WorkspaceSidebarRow] = []
        for member in members {
            switch member {
            case .project(let projectID):
                rows.append(.project(projectID))
            case .workspace(let workspaceID):
                guard workspacesByID[workspaceID] != nil else { continue }
                rows.append(.workspace(workspaceID))
                for checkout in activeCheckouts where checkout.workspaceID == workspaceID {
                    rows.append(.checkout(checkout.id))
                }
            }
        }
        return rows
    }
}
