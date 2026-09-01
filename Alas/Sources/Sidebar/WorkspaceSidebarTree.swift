import SwiftUI

/// Workspace and Project peers in the sidebar. The caller supplies the
/// existing concrete Project row so Workspace adoption cannot change any
/// Project/Worktree affordance or reorder projects around Workspace peers.
struct WorkspaceSidebarTree<ProjectRow: View>: View {
    @Bindable var state: AppState
    let projectRow: (ProjectConfig) -> ProjectRow
    @State private var showingNewWorkspace = false
    @State private var editingWorkspace: Workspace?
    @State private var creatingCheckout: Workspace?
    @State private var lifecycleError: String?
    @State private var deletionConfirmation: PendingDeletionConfirmation?
    @State private var workspaceDeletionConfirmation: PendingWorkspaceDefinitionDeletion?
    @State private var repairPlan: PendingRepairPlan?

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

        if state.config.workspacesEnabled {
            Button("New Workspace", systemImage: "plus") { showingNewWorkspace = true }
                .buttonStyle(.plain).padding(.horizontal, 12)
        }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            switch row {
            case .project(let id):
                if let project = projects[id] {
                    projectRow(project)
                }
            case .workspace(let id):
                if let workspace = workspaces[id] {
                    HStack {
                        Button { state.selectWorkspace(id: id) } label: { Label(workspace.name, systemImage: "square.stack.3d.up") }
                            .buttonStyle(.plain)
                        Spacer()
                        Button("Create Checkout") { creatingCheckout = workspace }.buttonStyle(.plain)
                        Button("Edit") { editingWorkspace = workspace }.buttonStyle(.plain)
                        Button("Delete", role: .destructive) {
                            workspaceDeletionConfirmation = .init(id: id, name: workspace.name)
                        }.buttonStyle(.plain)
                    }.padding(.horizontal, 12)
                }
            case .formerWorkspace:
                Label("Former Workspace", systemImage: "archivebox")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
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
                        if state.workspaceNavigationState.selectedCheckoutID == id {
                            WorkspaceCheckoutDetailView(
                                model: Self.detailModel(
                                    for: checkout,
                                    rollupBuilder: state.workspaceMemberReviewRollupBuilder(for: checkout)
                                ),
                                perform: { action, memberID in
                                    perform(action, checkoutID: id, memberID: memberID)
                                },
                                openReview: { action in
                                    state.openWorkspaceReview(action)
                                }
                            )
                            .padding(.leading, 28)
                        }
                    }
                }
            case .member:
                EmptyView()
            }
        }
        .sheet(isPresented: $showingNewWorkspace) { NewWorkspaceDialog(state: state, presented: $showingNewWorkspace) }
        .sheet(item: $editingWorkspace) { workspace in EditWorkspaceDialog(state: state, workspace: workspace, presented: Binding(get: { editingWorkspace != nil }, set: { if !$0 { editingWorkspace = nil } })) }
        .sheet(item: $creatingCheckout) { workspace in CreateWorkspaceCheckoutDialog(state: state, workspace: workspace, presented: Binding(get: { creatingCheckout != nil }, set: { if !$0 { creatingCheckout = nil } })) }
        .alert("Workspace Checkout", isPresented: Binding(get: { lifecycleError != nil }, set: { if !$0 { lifecycleError = nil } })) {
            Button("OK", role: .cancel) { lifecycleError = nil }
        } message: {
            Text(lifecycleError ?? "")
        }
        .sheet(item: $deletionConfirmation) { pending in
            WorkspaceDeletionConfirmationSheet(model: pending.model) { action in
                confirmDeletion(action, checkoutID: pending.checkoutID, memberID: pending.memberID)
            }
        }
        .sheet(item: $repairPlan) { pending in
            WorkspaceRepairPlanSheet(model: pending.model) { candidate in
                useRepairCandidate(candidate, checkoutID: pending.checkoutID, memberID: pending.memberID)
            }
        }
        .confirmationDialog(
            "Delete Workspace?",
            isPresented: Binding(
                get: { workspaceDeletionConfirmation != nil },
                set: { if !$0 { workspaceDeletionConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Workspace", role: .destructive) {
                if let pending = workspaceDeletionConfirmation {
                    deleteWorkspace(id: pending.id)
                }
            }
            Button("Cancel", role: .cancel) { workspaceDeletionConfirmation = nil }
        } message: {
            let name = workspaceDeletionConfirmation?.name ?? "this Workspace"
            Text("Delete \(name)? Existing checkouts are retained as Former Workspace checkouts.")
        }
    }

    private func perform(_ action: WorkspaceCheckoutActionKind, checkoutID: UUID, memberID: UUID?) {
        Task { @MainActor in
            do {
                switch action {
                case .archive:
                    _ = try await state.archiveWorkspaceCheckout(id: checkoutID)
                case .unarchive:
                    _ = try await state.unarchiveWorkspaceCheckout(id: checkoutID)
                case .deleteCheckout:
                    let confirmation = try await state.workspaceCheckoutDeletionConfirmation(checkoutID: checkoutID)
                    if confirmation.requiresConfirmation {
                        deletionConfirmation = PendingDeletionConfirmation(checkoutID: checkoutID, memberID: nil, model: confirmation)
                    } else {
                        _ = try await state.deleteWorkspaceCheckout(id: checkoutID)
                    }
                case .forgetCheckout:
                    let confirmation = try state.workspaceForgetConfirmation(checkoutID: checkoutID)
                    if confirmation.requiresConfirmation {
                        deletionConfirmation = PendingDeletionConfirmation(checkoutID: checkoutID, memberID: nil, model: confirmation)
                    } else {
                        try await state.forgetWorkspaceCheckout(id: checkoutID)
                    }
                case .stopAfterCurrentOperations:
                    try await state.stopWorkspaceCheckoutAfterCurrentOperations(id: checkoutID)
                case .resumeCreation:
                    _ = try await state.resumeWorkspaceCheckoutCreation(id: checkoutID)
                case .recreateMember:
                    if let memberID {
                        _ = try await state.resumeWorkspaceCheckoutMemberCreation(checkoutID: checkoutID, memberID: memberID)
                    }
                case .retrySetup:
                    if let memberID { _ = try await state.retryWorkspaceCheckoutSetup(checkoutID: checkoutID, memberID: memberID) }
                case .findExisting:
                    if let memberID {
                        let model = try state.workspaceRepairPlan(checkoutID: checkoutID, memberID: memberID)
                        repairPlan = PendingRepairPlan(checkoutID: checkoutID, memberID: memberID, model: model)
                    }
                case .deleteMember:
                    if let memberID {
                        if state.workspacesManager.checkout(id: checkoutID)?
                            .members.first(where: { $0.id == memberID })?
                            .availability == .identityConflict {
                            _ = try await state.deleteWorkspaceCheckoutMemberSnapshot(checkoutID: checkoutID, memberID: memberID)
                        } else {
                            let confirmation = try await state.workspaceMemberDeletionConfirmation(checkoutID: checkoutID, memberID: memberID)
                            if confirmation.requiresConfirmation {
                                deletionConfirmation = PendingDeletionConfirmation(checkoutID: checkoutID, memberID: memberID, model: confirmation)
                            } else {
                                _ = try await state.deleteWorkspaceCheckoutMember(checkoutID: checkoutID, memberID: memberID)
                            }
                        }
                    }
                }
            } catch {
                lifecycleError = error.localizedDescription
            }
        }
    }

    static func detailModel(for checkout: WorkspaceCheckout, rollupBuilder: MemberReviewRollupBuilder = .init()) -> WorkspaceCheckoutDetailModel {
        WorkspaceCheckoutDetailModel(
            checkout: checkout,
            reviewRollup: try? rollupBuilder.build(for: checkout)
        )
    }

    private func confirmDeletion(_ action: WorkspaceLifecycleAction, checkoutID: UUID, memberID: UUID?) {
        Task { @MainActor in
            do {
                switch action {
                case .deleteCheckout(let confirmingRisks):
                    _ = try await state.deleteWorkspaceCheckout(id: checkoutID, confirmingRisks: confirmingRisks)
                    deletionConfirmation = nil
                case .deleteMember(let confirmingRisks):
                    if let memberID {
                        _ = try await state.deleteWorkspaceCheckoutMember(checkoutID: checkoutID, memberID: memberID, confirmingRisks: confirmingRisks)
                    }
                    deletionConfirmation = nil
                case .forgetCheckout(let confirmedPreserveArtifacts):
                    try await state.forgetWorkspaceCheckout(id: checkoutID, confirmedPreserveArtifacts: confirmedPreserveArtifacts)
                    deletionConfirmation = nil
                }
            } catch {
                lifecycleError = error.localizedDescription
            }
        }
    }

    private func useRepairCandidate(_ candidate: WorkspaceRepairCandidate, checkoutID: UUID, memberID: UUID) {
        Task { @MainActor in
            do {
                _ = try await state.useWorkspaceRepairCandidate(checkoutID: checkoutID, memberID: memberID, candidate: candidate)
                repairPlan = nil
            } catch {
                lifecycleError = error.localizedDescription
            }
        }
    }

    private func deleteWorkspace(id: UUID) {
        Task { @MainActor in
            do {
                try await state.deleteWorkspaceDefinition(id: id)
                workspaceDeletionConfirmation = nil
            } catch {
                lifecycleError = error.localizedDescription
            }
        }
    }
}

private struct PendingWorkspaceDefinitionDeletion {
    var id: UUID
    var name: String
}

private struct PendingDeletionConfirmation: Identifiable {
    let id = UUID()
    var checkoutID: UUID
    var memberID: UUID?
    var model: WorkspaceLifecycleConfirmationModel
}

private struct PendingRepairPlan: Identifiable {
    let id = UUID()
    var checkoutID: UUID
    var memberID: UUID
    var model: WorkspaceRepairPlanModel
}
