import SwiftUI

/// Expansion and presentation state of one `WorkspaceSidebarTree`. It lives
/// outside the tree because the tree's rows are lazy-stack elements that can
/// unmount while scrolled away; the sheets and dialogs hang off
/// `WorkspaceSidebarTreeHost`, which never does.
@MainActor
@Observable
final class WorkspaceSidebarTreeModel {
    var editingWorkspace: Workspace?
    var creatingCheckout: Workspace?
    var inspectedCheckout: WorkspaceCheckout?
    var collapsedWorkspaces: Set<UUID> = []
    var expandedCheckouts: Set<UUID> = []
    var lifecycleError: String?
    fileprivate var workspaceDeletionConfirmation: PendingWorkspaceDefinitionDeletion?
    fileprivate var checkoutRowDeletionConfirmation: PendingDeletionConfirmation?
    var formerWorkspaceDeletionConfirmation = false
}

/// Owns a tree's model and presents its sheets and dialogs. Wrap the scroll
/// view the tree's rows live in, and hand the model to the tree.
struct WorkspaceSidebarTreeHost<Content: View>: View {
    @Bindable var state: AppState
    @ViewBuilder let content: (WorkspaceSidebarTreeModel) -> Content
    @State private var model = WorkspaceSidebarTreeModel()

    var body: some View {
        content(model)
            .modifier(WorkspaceSidebarTreePresentations(state: state, model: model))
    }
}

/// Workspace and Project peers in the sidebar. The caller supplies the
/// existing concrete Project row so Workspace adoption cannot change any
/// Project/Worktree affordance or reorder projects around Workspace peers.
///
/// Every row is its own element, so a lazy stack around the tree mounts only
/// the rows on screen.
struct WorkspaceSidebarTree<ProjectRow: View>: View {
    @Bindable var state: AppState
    var model = WorkspaceSidebarTreeModel()
    var spaceID: String? = nil
    var isInteractive = true
    let projectRow: (ProjectConfig) -> ProjectRow
    @Environment(\.theme) private var theme
    @State private var hoveringWorkspaceID: UUID?
    @State private var plusHoveringWorkspaceID: UUID?
    @State private var hoveringCheckoutID: UUID?

    var body: some View {
        let space = state.spacesManager.space(id: spaceID ?? state.spacesManager.activeSpaceId)
        let members = space?.members
            ?? space?.projectIds.map(SpaceMemberReference.project)
            ?? []
        let rows = WorkspaceSidebarLayout.rows(
            members: members,
            workspaces: state.workspacesManager.workspaces,
            checkouts: state.workspacesManager.checkouts
        )
        let workspaces = Dictionary(uniqueKeysWithValues: state.workspacesManager.workspaces.map { ($0.id, $0) })
        let checkouts = Dictionary(uniqueKeysWithValues: state.workspacesManager.checkouts.map { ($0.id, $0) })
        let projects = Dictionary(uniqueKeysWithValues: state.projects.map { ($0.id, $0) })
        let drawnRows = WorkspaceSidebarLayout.drawnRows(
            rows,
            projectIDs: Set(projects.keys),
            workspaceIDs: Set(workspaces.keys),
            checkouts: checkouts,
            collapsedWorkspaces: model.collapsedWorkspaces
        )

        ForEach(Array(drawnRows.enumerated()), id: \.offset) { index, row in
            // The 2pt gap a VStack spaced drawn rows with.
            if index > 0 {
                Color.clear.frame(height: 2)
            }
            switch row {
            case .project(let id):
                // RepoGroupView supplies its own vertical margin.
                if let project = projects[id] {
                    projectRow(project)
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
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Delete all former checkouts...", role: .destructive) {
                            model.formerWorkspaceDeletionConfirmation = true
                        }
                    }
            case .checkout(let id):
                if let checkout = checkouts[id], checkout.workspaceID.map({ !model.collapsedWorkspaces.contains($0) }) ?? true {
                    checkoutRows(checkout, projects: projects)
                }
            case .member:
                EmptyView()
            }
        }
        .disabled(!isInteractive)
    }

    private func workspaceHeader(_ workspace: Workspace, projects: [String: ProjectConfig]) -> some View {
        let collapsed = model.collapsedWorkspaces.contains(workspace.id)
        let selected = state.workspaceNavigationState.selectedWorkspaceID == workspace.id
            && state.workspaceNavigationState.selectedCheckoutID == nil
        let hovering = hoveringWorkspaceID == workspace.id
        let plusHovering = plusHoveringWorkspaceID == workspace.id
        let checkoutCount = state.workspacesManager.checkouts.count { $0.workspaceID == workspace.id }
        return HStack(spacing: 7) {
            Button {
                if collapsed { model.collapsedWorkspaces.remove(workspace.id) }
                else { model.collapsedWorkspaces.insert(workspace.id) }
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
                    WorkspaceRepositoryPile(
                        workspace: workspace,
                        projects: Array(projects.values),
                        icon: { state.effectiveIcon(for: $0) }
                    )
                    Text(workspace.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .tracking(-0.12)
                        .foregroundColor(theme.color("fg"))
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
                    model.creatingCheckout = workspace
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
        // Own leading inset matches RepoGroupView's header `.padding(5)`, so
        // both header kinds land at the same 13pt from the sidebar edge once
        // the outer scroll-content padding (SidebarView.swift) is added.
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        // Matches RepoGroupView's header: same radius, same hover fill, and
        // accent-soft for selection rather than the pre-E1 bg-4 plus an inset
        // accent bar. A workspace and a repo sitting next to each other should
        // announce selection the same way.
        .background(
            selected ? theme.color("accent-soft") : (hovering ? theme.color("bg-2") : .clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.color("accent").opacity(0.5), lineWidth: 0.5)
            }
        }
        // Outer margin: trailing only. The leading side is already accounted
        // for by the outer scroll-content padding, so adding it here would
        // double-count it against the header's own leading inset above.
        .padding(.trailing, 6)
        .contentShape(Rectangle())
        .onHover { hoveringWorkspaceID = $0 ? workspace.id : nil }
        .contextMenu {
            Button("New checkout...", systemImage: "plus") { model.creatingCheckout = workspace }
            Button("Edit workspace...", systemImage: "pencil") { model.editingWorkspace = workspace }
            Divider()
            Button("Delete workspace...", role: .destructive) {
                model.workspaceDeletionConfirmation = .init(id: workspace.id, name: workspace.name, checkoutCount: checkoutCount)
            }
        }
    }

    /// Full strength at rest, matching a worktree row's branch label; archived
    /// checkouts stay dimmed because that is a property of the checkout rather
    /// than of the row's interaction state.
    private func checkoutBranchColorToken(checkout: WorkspaceCheckout) -> String {
        checkout.archivedAt != nil ? "fg-dim" : "fg"
    }

    private func checkoutRows(
        _ checkout: WorkspaceCheckout,
        projects: [String: ProjectConfig]
    ) -> some View {
        let selected = state.workspaceNavigationState.selectedCheckoutID == checkout.id
        let expanded = model.expandedCheckouts.contains(checkout.id)
        let hovering = hoveringCheckoutID == checkout.id
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Button {
                    if expanded { model.expandedCheckouts.remove(checkout.id) }
                    else { model.expandedCheckouts.insert(checkout.id) }
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
                            // Matches WorktreeRowView's branch label.
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.color(checkoutBranchColorToken(checkout: checkout)))
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
                ToolbarBtn(icon: "info.circle", tooltip: "Checkout details") { model.inspectedCheckout = checkout }
            }
            .padding(.leading, 20)
            .padding(.trailing, 4)
            // Same selection and hover language as a worktree row.
            .background(
                selected ? theme.color("accent-soft") : (hovering ? theme.color("bg-2") : .clear),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(theme.color("accent").opacity(0.5), lineWidth: 0.5)
                }
            }
            .onHover { hoveringCheckoutID = $0 ? checkout.id : nil }
            .contextMenu {
                Button("Checkout details...", systemImage: "info.circle") { model.inspectedCheckout = checkout }
                Divider()
                if checkout.archivedAt != nil {
                    Button("Unarchive") { model.performCheckoutRowAction(.unarchive, checkoutID: checkout.id, state: state) }
                } else {
                    Button("Archive") { model.performCheckoutRowAction(.archive, checkoutID: checkout.id, state: state) }
                }
                if checkout.health == .deleted {
                    Button("Forget Record", role: .destructive) { model.performCheckoutRowAction(.forgetCheckout, checkoutID: checkout.id, state: state) }
                } else {
                    Button("Delete Checkout...", role: .destructive) { model.performCheckoutRowAction(.deleteCheckout, checkoutID: checkout.id, state: state) }
                }
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
                                ProjectIconView(icon: state.effectiveIcon(for: project), fallbackName: project.name, size: .sidebar)
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
                    .help(RemotePath.display(member.worktreePath))
                }
            }
        }
        // Outer margin: trailing only, mirroring the workspace header above —
        // the leading side is already covered by the outer scroll-content
        // padding.
        .padding(.trailing, 6)
    }
}

struct WorkspaceCheckoutInspector: View {
    @Bindable var state: AppState
    let checkout: WorkspaceCheckout
    @State private var inspectorGeneration = UUID()
    @State private var lifecycleError: String?
    @State private var deletionConfirmation: PendingDeletionConfirmation?
    @State private var repairPlan: PendingRepairPlan?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let current = state.workspacesManager.checkout(id: checkout.id) ?? checkout
        WorkspaceCheckoutDetailView(
            model: Self.detailModel(for: current, rollupBuilder: state.workspaceMemberReviewRollupBuilder(for: current)),
            perform: { action, memberID in perform(action, checkoutID: checkout.id, memberID: memberID) },
            openReview: { action in
                dismiss()
                state.openWorkspaceReview(action)
            }
        )
        .sheet(item: $deletionConfirmation) { pending in
            WorkspaceDeletionConfirmationSheet(
                model: pending.model,
                approvalQueue: state.repoHookApprovalQueue
            ) { action in
                confirmDeletion(action, checkoutID: pending.checkoutID, memberID: pending.memberID)
            }
            .modifier(WorkspaceLifecycleErrorAlert(error: $lifecycleError))
        }
        .sheet(item: $repairPlan) { pending in
            WorkspaceRepairPlanSheet(model: pending.model) { candidate in
                useRepairCandidate(candidate, checkoutID: pending.checkoutID, memberID: pending.memberID)
            }
            .modifier(RepoHookApprovalPresentationHandler(approvalQueue: state.repoHookApprovalQueue))
            .modifier(WorkspaceLifecycleErrorAlert(error: $lifecycleError))
        }
        .modifier(WorkspaceLifecycleErrorAlert(
            error: $lifecycleError, enabled: deletionConfirmation == nil && repairPlan == nil
        ))
        .onDisappear { inspectorGeneration = UUID() }
        .modifier(RepoHookApprovalPresentationHandler(
            approvalQueue: state.repoHookApprovalQueue,
            isActive: deletionConfirmation == nil && repairPlan == nil
        ))
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
                        let outcome = try await state.deleteAndForgetWorkspaceCheckout(id: checkoutID)
                        guard isCurrentInspector(checkoutID, generation: generation) else { return }
                        handle(outcome, checkoutID: checkoutID)
                    }
                case .forgetCheckout:
                    let confirmation = try state.workspaceForgetConfirmation(checkoutID: checkoutID)
                    if confirmation.requiresConfirmation {
                        deletionConfirmation = PendingDeletionConfirmation(checkoutID: checkoutID, memberID: nil, model: confirmation)
                    } else {
                        try await state.forgetWorkspaceCheckout(id: checkoutID)
                        if isCurrentInspector(checkoutID, generation: generation) { dismiss() }
                    }
                case .stopAfterCurrentOperations:
                    try await state.stopWorkspaceCheckoutAfterCurrentOperations(id: checkoutID)
                case .resumeCreation:
                    if let memberID {
                        _ = try await state.resumeWorkspaceCheckoutMemberCreation(checkoutID: checkoutID, memberID: memberID)
                    } else {
                        _ = try await state.resumeWorkspaceCheckoutCreation(id: checkoutID)
                    }
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
        checkout.id == checkoutID && inspectorGeneration == generation
    }

    /// "Delete Checkout" is really "delete and forget"; this is where the
    /// three possible outcomes turn into what the user sees.
    private func handle(_ outcome: WorkspaceCheckoutDeletionOutcome, checkoutID: UUID) {
        switch outcome {
        case .forgotten:
            dismiss()
        case .artifactsNeedConfirmation:
            do {
                let confirmation = try state.workspaceForgetConfirmation(checkoutID: checkoutID)
                deletionConfirmation = PendingDeletionConfirmation(checkoutID: checkoutID, memberID: nil, model: confirmation)
            } catch {
                lifecycleError = error.localizedDescription
            }
        case .retained(_, let failures):
            guard let first = failures.first else { return }
            let suffix = failures.count > 1 ? " (\(failures.count - 1) more)" : ""
            lifecycleError = "Could not delete \(first.memberName): \(first.message)\(suffix)"
        }
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
                    let outcome = try await state.deleteAndForgetWorkspaceCheckout(id: checkoutID, confirmingRisks: confirmingRisks)
                    guard isCurrentInspector(checkoutID, generation: generation) else { return }
                    handle(outcome, checkoutID: checkoutID)
                case .deleteMember(let confirmingRisks):
                    if let memberID {
                        _ = try await state.deleteWorkspaceCheckoutMember(checkoutID: checkoutID, memberID: memberID, confirmingRisks: confirmingRisks)
                    }
                case .forgetCheckout(let confirmedPreserveArtifacts):
                    try await state.forgetWorkspaceCheckout(id: checkoutID, confirmedPreserveArtifacts: confirmedPreserveArtifacts)
                    if isCurrentInspector(checkoutID, generation: generation) { dismiss() }
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
}

struct WorkspaceRepositoryPile: View {
    let workspace: Workspace
    let projects: [ProjectConfig]
    /// Resolves each member's icon, which may come from the repo's `.alas/`
    /// directory when the project has no explicit icon.
    let icon: (ProjectConfig) -> ProjectIcon
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
                        ProjectIconView(icon: icon(project), fallbackName: project.name, size: size)
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
    var checkoutCount: Int = 0
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

extension WorkspaceSidebarTreeModel {
    func performCheckoutRowAction(_ action: WorkspaceCheckoutActionKind, checkoutID: UUID, state: AppState) {
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
                        checkoutRowDeletionConfirmation = PendingDeletionConfirmation(checkoutID: checkoutID, memberID: nil, model: confirmation)
                    } else {
                        let outcome = try await state.deleteAndForgetWorkspaceCheckout(id: checkoutID)
                        handleCheckoutRowOutcome(outcome, checkoutID: checkoutID, state: state)
                    }
                case .forgetCheckout:
                    let confirmation = try state.workspaceForgetConfirmation(checkoutID: checkoutID)
                    if confirmation.requiresConfirmation {
                        checkoutRowDeletionConfirmation = PendingDeletionConfirmation(checkoutID: checkoutID, memberID: nil, model: confirmation)
                    } else {
                        try await state.forgetWorkspaceCheckout(id: checkoutID)
                    }
                default:
                    break
                }
            } catch {
                lifecycleError = error.localizedDescription
            }
        }
    }

    fileprivate func handleCheckoutRowOutcome(_ outcome: WorkspaceCheckoutDeletionOutcome, checkoutID: UUID, state: AppState) {
        switch outcome {
        case .forgotten:
            break
        case .artifactsNeedConfirmation:
            do {
                let confirmation = try state.workspaceForgetConfirmation(checkoutID: checkoutID)
                checkoutRowDeletionConfirmation = PendingDeletionConfirmation(checkoutID: checkoutID, memberID: nil, model: confirmation)
            } catch {
                lifecycleError = error.localizedDescription
            }
        case .retained(_, let failures):
            guard let first = failures.first else { return }
            let suffix = failures.count > 1 ? " (\(failures.count - 1) more)" : ""
            lifecycleError = "Could not delete \(first.memberName): \(first.message)\(suffix)"
        }
    }

    fileprivate func confirmCheckoutRowDeletion(_ action: WorkspaceLifecycleAction, checkoutID: UUID, state: AppState) {
        // A `.deleteCheckout` confirmation can resolve into `.artifactsNeedConfirmation`,
        // which installs a fresh preserve-artifacts sheet via `handleCheckoutRowOutcome`.
        // Capture the sheet's identity before that runs, so an unconditional clear below
        // never wipes out a sheet installed during this very call.
        let confirmationID = checkoutRowDeletionConfirmation?.id
        Task { @MainActor in
            do {
                switch action {
                case .deleteCheckout(let confirmingRisks):
                    let outcome = try await state.deleteAndForgetWorkspaceCheckout(id: checkoutID, confirmingRisks: confirmingRisks)
                    handleCheckoutRowOutcome(outcome, checkoutID: checkoutID, state: state)
                case .deleteMember:
                    break
                case .forgetCheckout(let confirmedPreserveArtifacts):
                    try await state.forgetWorkspaceCheckout(id: checkoutID, confirmedPreserveArtifacts: confirmedPreserveArtifacts)
                }
                if checkoutRowDeletionConfirmation?.id == confirmationID { checkoutRowDeletionConfirmation = nil }
            } catch {
                lifecycleError = error.localizedDescription
            }
        }
    }

    fileprivate func deleteAllFormerCheckouts(state: AppState) {
        formerWorkspaceDeletionConfirmation = false
        let formerCheckoutIDs = state.workspacesManager.checkouts
            .filter { $0.workspaceID == nil }
            .map(\.id)
        Task { @MainActor in
            var remainingFailures = 0
            for checkoutID in formerCheckoutIDs {
                do {
                    // Same reasoning as the "Delete Workspace and N
                    // Checkouts" bulk path: refuse a checkout with
                    // unconfirmed risks (including live sessions that would
                    // otherwise close silently) instead of deleting it
                    // without ever showing them. An archived checkout is
                    // refused without ever calling
                    // workspaceCheckoutDeletionConfirmation — that call
                    // unarchives as prep for an imminent deletion, and
                    // there's no side-effect-free way to restore that here
                    // if this loop ends up not deleting it after all (the
                    // only restore path, the coordinator's archive(), stops
                    // live sessions and would defeat this very fix).
                    guard state.workspacesManager.checkout(id: checkoutID)?.archivedAt == nil else {
                        remainingFailures += 1
                        continue
                    }
                    let confirmation = try await state.workspaceCheckoutDeletionConfirmation(checkoutID: checkoutID)
                    guard !confirmation.requiresConfirmation else {
                        remainingFailures += 1
                        continue
                    }
                    let outcome = try await state.deleteAndForgetWorkspaceCheckout(id: checkoutID)
                    if outcome != .forgotten { remainingFailures += 1 }
                } catch {
                    remainingFailures += 1
                }
            }
            if remainingFailures > 0 {
                lifecycleError = "\(remainingFailures) former \(remainingFailures == 1 ? "checkout needs" : "checkouts need") attention and could not be deleted."
            }
        }
    }

    fileprivate func deleteWorkspace(id: UUID, state: AppState) {
        Task { @MainActor in
            do {
                try await state.deleteWorkspaceDefinition(id: id)
                workspaceDeletionConfirmation = nil
            } catch {
                lifecycleError = error.localizedDescription
            }
        }
    }

    fileprivate func deleteWorkspaceAndCheckouts(id: UUID, state: AppState) {
        Task { @MainActor in
            do {
                try await state.deleteWorkspaceDefinitionAndCheckouts(id: id)
                workspaceDeletionConfirmation = nil
            } catch {
                lifecycleError = error.localizedDescription
            }
        }
    }
}

private struct WorkspaceSidebarTreePresentations: ViewModifier {
    @Bindable var state: AppState
    @Bindable var model: WorkspaceSidebarTreeModel

    func body(content: Content) -> some View {
        content
        .sheet(item: $model.editingWorkspace) { workspace in EditWorkspaceDialog(state: state, workspace: workspace, presented: Binding(get: { model.editingWorkspace != nil }, set: { if !$0 { model.editingWorkspace = nil } })) }
        .sheet(item: $model.creatingCheckout) { workspace in CreateWorkspaceCheckoutDialog(state: state, workspace: workspace, presented: Binding(get: { model.creatingCheckout != nil }, set: { if !$0 { model.creatingCheckout = nil } })) }
        .sheet(item: $model.inspectedCheckout) { checkout in
            WorkspaceCheckoutInspector(state: state, checkout: checkout)
        }
        .modifier(WorkspaceLifecycleErrorAlert(error: $model.lifecycleError))
        .confirmationDialog(
            "Delete Workspace?",
            isPresented: Binding(
                get: { model.workspaceDeletionConfirmation != nil },
                set: { if !$0 { model.workspaceDeletionConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pending = model.workspaceDeletionConfirmation, pending.checkoutCount > 0 {
                Button("Delete Workspace and \(pending.checkoutCount) \(pending.checkoutCount == 1 ? "Checkout" : "Checkouts")", role: .destructive) {
                    model.deleteWorkspaceAndCheckouts(id: pending.id, state: state)
                }
                Button("Keep Checkouts", role: .destructive) {
                    model.deleteWorkspace(id: pending.id, state: state)
                }
            } else {
                Button("Delete Workspace", role: .destructive) {
                    if let pending = model.workspaceDeletionConfirmation {
                        model.deleteWorkspace(id: pending.id, state: state)
                    }
                }
            }
            Button("Cancel", role: .cancel) { model.workspaceDeletionConfirmation = nil }
        } message: {
            let name = model.workspaceDeletionConfirmation?.name ?? "this Workspace"
            if let pending = model.workspaceDeletionConfirmation, pending.checkoutCount > 0 {
                Text("Delete \(name)? It has \(pending.checkoutCount) \(pending.checkoutCount == 1 ? "checkout" : "checkouts"). Keeping them moves them to Former Workspace.")
            } else {
                Text("Delete \(name)?")
            }
        }
        .sheet(item: $model.checkoutRowDeletionConfirmation) { pending in
            WorkspaceDeletionConfirmationSheet(
                model: pending.model,
                approvalQueue: state.repoHookApprovalQueue
            ) { action in
                model.confirmCheckoutRowDeletion(action, checkoutID: pending.checkoutID, state: state)
            }
            .modifier(WorkspaceLifecycleErrorAlert(error: $model.lifecycleError))
        }
        .confirmationDialog(
            "Delete All Former Checkouts?",
            isPresented: $model.formerWorkspaceDeletionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { model.deleteAllFormerCheckouts(state: state) }
            Button("Cancel", role: .cancel) { model.formerWorkspaceDeletionConfirmation = false }
        } message: {
            Text("Deletes every checkout under Former Workspace and removes their worktrees. Checkouts that cannot be fully removed stay visible.")
        }
        .onChange(of: state.workspaceNavigationState.selectedCheckoutID, initial: true) { _, id in
            guard let id, let checkout = state.workspacesManager.checkout(id: id) else { return }
            model.expandedCheckouts.insert(id)
            if let workspaceID = checkout.workspaceID { model.collapsedWorkspaces.remove(workspaceID) }
        }
    }
}
