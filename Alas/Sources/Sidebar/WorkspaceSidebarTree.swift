import SwiftUI

/// Workspace and Project peers in the sidebar. The caller supplies the
/// existing concrete Project row so Workspace adoption cannot change any
/// Project/Worktree affordance or reorder projects around Workspace peers.
struct WorkspaceSidebarTree<ProjectRow: View>: View {
    @Bindable var state: AppState
    let projectRow: (ProjectConfig) -> ProjectRow
    @State private var editingWorkspace: Workspace?
    @State private var creatingCheckout: Workspace?
    @State private var inspectedCheckout: WorkspaceCheckout?
    @State private var inspectorGeneration = UUID()
    @State private var collapsedWorkspaces: Set<UUID> = []
    @State private var expandedCheckouts: Set<UUID> = []
    @Environment(\.theme) private var theme
    @State private var lifecycleError: String?
    @State private var deletionConfirmation: PendingDeletionConfirmation?
    @State private var workspaceDeletionConfirmation: PendingWorkspaceDefinitionDeletion?
    @State private var repairPlan: PendingRepairPlan?
    @State private var hoveringWorkspaceID: UUID?
    @State private var plusHoveringWorkspaceID: UUID?

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

        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .project(let id):
                    if let project = projects[id] {
                        projectRow(project).padding(.vertical, 3)
                    }
                case .workspace(let id):
                    if let workspace = workspaces[id] {
                        workspaceHeader(workspace, projects: projects)
                    }
                case .formerWorkspace:
                    Label("Former Workspace", systemImage: "archivebox")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(theme.color("fg-muted"))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                case .checkout(let id):
                    if let checkout = checkouts[id], checkout.workspaceID.map({ !collapsedWorkspaces.contains($0) }) ?? true {
                        checkoutRows(checkout, projects: projects)
                    }
                case .member:
                    EmptyView()
                }
            }
        }
        .sheet(item: $editingWorkspace) { workspace in EditWorkspaceDialog(state: state, workspace: workspace, presented: Binding(get: { editingWorkspace != nil }, set: { if !$0 { editingWorkspace = nil } })) }
        .sheet(item: $creatingCheckout) { workspace in CreateWorkspaceCheckoutDialog(state: state, workspace: workspace, presented: Binding(get: { creatingCheckout != nil }, set: { if !$0 { creatingCheckout = nil } })) }
        .sheet(item: $inspectedCheckout) { snapshot in
            let checkout = state.workspacesManager.checkout(id: snapshot.id) ?? snapshot
            WorkspaceCheckoutDetailView(
                model: Self.detailModel(for: checkout, rollupBuilder: state.workspaceMemberReviewRollupBuilder(for: checkout)),
                perform: { action, memberID in perform(action, checkoutID: checkout.id, memberID: memberID) },
                openReview: { action in
                    inspectedCheckout = nil
                    state.openWorkspaceReview(action)
                }
            )
            .sheet(item: $deletionConfirmation) { pending in
                WorkspaceDeletionConfirmationSheet(model: pending.model) { action in
                    confirmDeletion(action, checkoutID: pending.checkoutID, memberID: pending.memberID)
                }
                .modifier(WorkspaceLifecycleErrorAlert(error: $lifecycleError))
            }
            .sheet(item: $repairPlan) { pending in
                WorkspaceRepairPlanSheet(model: pending.model) { candidate in
                    useRepairCandidate(candidate, checkoutID: pending.checkoutID, memberID: pending.memberID)
                }
                .modifier(WorkspaceLifecycleErrorAlert(error: $lifecycleError))
            }
            .modifier(WorkspaceLifecycleErrorAlert(
                error: $lifecycleError, enabled: deletionConfirmation == nil && repairPlan == nil
            ))
        }
        .modifier(WorkspaceLifecycleErrorAlert(error: $lifecycleError, enabled: inspectedCheckout == nil))
        .onChange(of: inspectedCheckout?.id) { _, _ in
            inspectorGeneration = UUID()
            deletionConfirmation = nil
            repairPlan = nil
            lifecycleError = nil
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
        .onChange(of: state.workspaceNavigationState.selectedCheckoutID, initial: true) { _, id in
            guard let id, let checkout = state.workspacesManager.checkout(id: id) else { return }
            expandedCheckouts.insert(id)
            if let workspaceID = checkout.workspaceID { collapsedWorkspaces.remove(workspaceID) }
        }
    }

    private func workspaceHeader(_ workspace: Workspace, projects: [String: ProjectConfig]) -> some View {
        let collapsed = collapsedWorkspaces.contains(workspace.id)
        let selected = state.workspaceNavigationState.selectedWorkspaceID == workspace.id
            && state.workspaceNavigationState.selectedCheckoutID == nil
        let hovering = hoveringWorkspaceID == workspace.id
        let plusHovering = plusHoveringWorkspaceID == workspace.id
        let checkoutCount = state.workspacesManager.checkouts.count { $0.workspaceID == workspace.id }
        return HStack(spacing: 7) {
            Button {
                if collapsed { collapsedWorkspaces.remove(workspace.id) }
                else { collapsedWorkspaces.insert(workspace.id) }
            } label: {
                Icon(name: collapsed ? "chev-right" : "chev-down", size: 10, color: theme.color("fg-faint"))
                    .frame(width: 14, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Expand workspace" : "Collapse workspace")
            .accessibilityLabel(collapsed ? "Expand workspace" : "Collapse workspace")
            Button { state.selectWorkspace(id: workspace.id) } label: {
                HStack(spacing: 7) {
                    WorkspaceRepositoryPile(workspace: workspace, projects: Array(projects.values))
                    Text(workspace.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(theme.color(selected ? "fg" : "fg-muted"))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(workspace.name)
            ZStack {
                Text("\(checkoutCount)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.color("fg-faint"))
                    .monospacedDigit()
                    .opacity(hovering ? 0 : 1)
                    .allowsHitTesting(false)
                Button {
                    creatingCheckout = workspace
                } label: {
                    Icon(
                        name: "plus",
                        size: 11,
                        color: plusHovering ? theme.color("fg") : theme.color("fg-faint")
                    )
                    .frame(width: 18, height: 18)
                    .background(plusHovering ? theme.color("bg-4") : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { plusHoveringWorkspaceID = $0 ? workspace.id : nil }
                .help("New checkout in \(workspace.name)")
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .frame(width: 18, height: 18)
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(selected ? theme.color("bg-4") : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.color("accent"))
                    .frame(width: 3, height: 14)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 6)
        .onHover { hoveringWorkspaceID = $0 ? workspace.id : nil }
        .contextMenu {
            Button("New checkout...", systemImage: "plus") { creatingCheckout = workspace }
            Button("Edit workspace...", systemImage: "pencil") { editingWorkspace = workspace }
            Divider()
            Button("Delete workspace...", role: .destructive) {
                workspaceDeletionConfirmation = .init(id: workspace.id, name: workspace.name)
            }
        }
    }

    private func checkoutRows(_ checkout: WorkspaceCheckout, projects: [String: ProjectConfig]) -> some View {
        let selected = state.workspaceNavigationState.selectedCheckoutID == checkout.id
        let expanded = expandedCheckouts.contains(checkout.id)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Button {
                    if expanded { expandedCheckouts.remove(checkout.id) }
                    else { expandedCheckouts.insert(checkout.id) }
                } label: {
                    Icon(name: expanded ? "chev-down" : "chev-right", size: 9, color: theme.color("fg-faint"))
                        .frame(width: 14, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide repositories" : "Show repositories")
                .accessibilityLabel(expanded ? "Hide repositories" : "Show repositories")
                Button {
                    state.selectWorkspaceCheckout(id: checkout.id)
                } label: {
                    HStack(spacing: 7) {
                        Icon(name: checkout.archivedAt == nil ? "branch" : "archivebox", size: 12)
                        Text(checkout.branch)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.color(checkout.archivedAt == nil ? "fg" : "fg-dim"))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        if checkout.operation != .idle {
                            ProgressView().controlSize(.mini)
                        } else if checkout.archivedAt == nil && checkout.health != .ready {
                            Icon(name: "alert", size: 11, color: theme.color("del"))
                                .help("Checkout needs attention")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ToolbarBtn(icon: "info.circle", tooltip: "Checkout details") { inspectedCheckout = checkout }
            }
            .padding(.leading, 20)
            .padding(.trailing, 4)
            .background(selected ? theme.color("bg-4") : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.color("accent"))
                        .frame(width: 3, height: 14)
                        .padding(.leading, 2)
                }
            }
            .contextMenu {
                Button("Checkout details...", systemImage: "info.circle") { inspectedCheckout = checkout }
            }
            .help(checkout.branch)
            if expanded {
                ForEach(checkout.members) { member in
                    let focused = selected && state.workspaceNavigationState.focusedCheckoutMemberID == member.id
                    Button {
                        state.selectWorkspaceCheckout(id: checkout.id)
                        state.focusWorkspaceCheckoutMember(id: member.id)
                    } label: {
                        HStack(spacing: 7) {
                            if let project = projects[member.projectID] {
                                ProjectIconView(icon: project.icon, fallbackName: project.name, size: .sidebar)
                            } else {
                                Icon(name: "folder", size: 12)
                            }
                            Text(member.fallbackProjectName)
                                .font(.system(size: 11.5, weight: focused ? .medium : .regular))
                                .foregroundColor(theme.color(member.availability == .available ? "fg-muted" : "fg-dim"))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if member.checkpoint == .failed || member.availability == .missing || member.availability == .identityConflict {
                                Icon(name: "alert", size: 10, color: theme.color("del"))
                            }
                        }
                        .padding(.leading, 48).padding(.trailing, 12)
                        .frame(height: 27)
                        .contentShape(Rectangle())
                        .background(focused ? theme.color("bg-3") : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(member.worktreePath)
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private func perform(_ action: WorkspaceCheckoutActionKind, checkoutID: UUID, memberID: UUID?) {
        let generation = inspectorGeneration
        Task { @MainActor in
            guard isCurrentInspector(checkoutID, generation: generation) else { return }
            do {
                switch action {
                case .archive:
                    _ = try await state.archiveWorkspaceCheckout(id: checkoutID)
                case .unarchive:
                    _ = try await state.unarchiveWorkspaceCheckout(id: checkoutID)
                case .deleteCheckout:
                    let confirmation = try await state.workspaceCheckoutDeletionConfirmation(checkoutID: checkoutID)
                    guard isCurrentInspector(checkoutID, generation: generation) else { return }
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
                        if isCurrentInspector(checkoutID, generation: generation) { inspectedCheckout = nil }
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
                            guard isCurrentInspector(checkoutID, generation: generation) else { return }
                            if confirmation.requiresConfirmation {
                                deletionConfirmation = PendingDeletionConfirmation(checkoutID: checkoutID, memberID: memberID, model: confirmation)
                            } else {
                                _ = try await state.deleteWorkspaceCheckoutMember(checkoutID: checkoutID, memberID: memberID)
                            }
                        }
                    }
                }
            } catch {
                if isCurrentInspector(checkoutID, generation: generation) { lifecycleError = error.localizedDescription }
            }
        }
    }

    private func isCurrentInspector(_ checkoutID: UUID, generation: UUID) -> Bool {
        inspectedCheckout?.id == checkoutID && inspectorGeneration == generation
    }

    static func detailModel(for checkout: WorkspaceCheckout, rollupBuilder: MemberReviewRollupBuilder = .init()) -> WorkspaceCheckoutDetailModel {
        WorkspaceCheckoutDetailModel(
            checkout: checkout,
            reviewRollup: try? rollupBuilder.build(for: checkout)
        )
    }

    private func confirmDeletion(_ action: WorkspaceLifecycleAction, checkoutID: UUID, memberID: UUID?) {
        let generation = inspectorGeneration
        let confirmationID = deletionConfirmation?.id
        Task { @MainActor in
            guard isCurrentInspector(checkoutID, generation: generation) else { return }
            do {
                switch action {
                case .deleteCheckout(let confirmingRisks):
                    _ = try await state.deleteWorkspaceCheckout(id: checkoutID, confirmingRisks: confirmingRisks)
                case .deleteMember(let confirmingRisks):
                    if let memberID {
                        _ = try await state.deleteWorkspaceCheckoutMember(checkoutID: checkoutID, memberID: memberID, confirmingRisks: confirmingRisks)
                    }
                case .forgetCheckout(let confirmedPreserveArtifacts):
                    try await state.forgetWorkspaceCheckout(id: checkoutID, confirmedPreserveArtifacts: confirmedPreserveArtifacts)
                    if isCurrentInspector(checkoutID, generation: generation) { inspectedCheckout = nil }
                }
                if deletionConfirmation?.id == confirmationID { deletionConfirmation = nil }
            } catch {
                if isCurrentInspector(checkoutID, generation: generation) { lifecycleError = error.localizedDescription }
            }
        }
    }

    private func useRepairCandidate(_ candidate: WorkspaceRepairCandidate, checkoutID: UUID, memberID: UUID) {
        let generation = inspectorGeneration
        let repairID = repairPlan?.id
        Task { @MainActor in
            guard isCurrentInspector(checkoutID, generation: generation) else { return }
            do {
                _ = try await state.useWorkspaceRepairCandidate(checkoutID: checkoutID, memberID: memberID, candidate: candidate)
                if repairPlan?.id == repairID { repairPlan = nil }
            } catch {
                if isCurrentInspector(checkoutID, generation: generation) { lifecycleError = error.localizedDescription }
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

struct WorkspaceRepositoryPile: View {
    let workspace: Workspace
    let projects: [ProjectConfig]
    var size: ProjectIconView.Size = .sidebar
    @Environment(\.theme) private var theme

    var body: some View {
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let repositories = workspace.members.compactMap { projectsByID[$0.projectID] }
        Group {
            if repositories.isEmpty {
                Icon(name: "folder", size: size.dimension * 0.8, color: theme.color("fg-muted"))
            } else {
                HStack(spacing: -size.dimension * 0.3125) {
                    ForEach(repositories.prefix(3)) { project in
                        ProjectIconView(icon: project.icon, fallbackName: project.name, size: size)
                            .overlay(
                                RoundedRectangle(cornerRadius: size.cornerRadius)
                                    .strokeBorder(theme.color("bg-1"), lineWidth: ringWidth)
                            )
                    }
                }
                .fixedSize()
            }
        }
        .accessibilityHidden(true)
    }

    /// The sidebar pile is too small for a separating ring to read as anything
    /// but grime, so only the larger piles get one.
    private var ringWidth: CGFloat {
        size.dimension >= 32 ? 2 : 0
    }
}

private struct WorkspaceLifecycleErrorAlert: ViewModifier {
    @Binding var error: String?
    var enabled = true

    func body(content: Content) -> some View {
        content.alert("Workspace checkout", isPresented: Binding(
            get: { enabled && error != nil },
            set: { if !$0 && enabled { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
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
