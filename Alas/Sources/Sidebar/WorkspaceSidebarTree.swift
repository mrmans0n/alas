import SwiftUI

/// Workspace and Project peers in the sidebar. The caller supplies the
/// existing concrete Project row so Workspace adoption cannot change any
/// Project/Worktree affordance or reorder projects around Workspace peers.
struct WorkspaceSidebarTree<ProjectRow: View>: View {
    @Bindable var state: AppState
    let projectRow: (ProjectConfig) -> ProjectRow

    var body: some View {
        let members = state.spacesManager.activeSpace?.members
            ?? state.spacesManager.activeSpace?.projectIds.map(SpaceMemberReference.project)
            ?? []
        let rows = WorkspaceSidebarLayout.rows(
            members: members,
            workspaces: state.workspacesManager.workspaces,
            checkouts: state.workspacesManager.checkouts
        )
        let workspaces = Dictionary(uniqueKeysWithValues: state.workspacesManager.workspaces.map { ($0.id, $0) })
        let checkouts = Dictionary(uniqueKeysWithValues: state.workspacesManager.checkouts.map { ($0.id, $0) })
        let projects = Dictionary(uniqueKeysWithValues: state.projects.map { ($0.id, $0) })

        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            switch row {
            case .project(let id):
                if let project = projects[id] {
                    projectRow(project)
                }
            case .workspace(let id):
                if let workspace = workspaces[id] {
                    Button {
                        state.selectWorkspace(id: id)
                    } label: {
                        Label(workspace.name, systemImage: "square.stack.3d.up")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                }
            case .checkout(let id):
                if let checkout = checkouts[id] {
                    VStack(alignment: .leading, spacing: 3) {
                        Button {
                            state.selectWorkspaceCheckout(id: id)
                        } label: {
                            Label(checkout.branch, systemImage: "arrow.triangle.branch")
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 28)
                        ForEach(checkout.members) { member in
                            Button {
                                state.selectWorkspaceCheckout(id: id)
                                state.focusWorkspaceCheckoutMember(id: member.id)
                            } label: {
                                Text(member.fallbackProjectName)
                                    .foregroundStyle(member.availability == .available ? .primary : .secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 48)
                        }
                    }
                }
            case .member:
                EmptyView()
            }
        }
    }
}
