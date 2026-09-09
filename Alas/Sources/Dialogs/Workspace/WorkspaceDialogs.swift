import AppKit
import SwiftUI

struct NewWorkspaceDialog: View {
    @Bindable var state: AppState
    @Binding var presented: Bool

    var body: some View {
        WorkspaceDefinitionEditor(state: state, workspace: nil, presented: $presented)
    }
}

struct EditWorkspaceDialog: View {
    @Bindable var state: AppState
    let workspace: Workspace
    @Binding var presented: Bool

    var body: some View {
        WorkspaceDefinitionEditor(state: state, workspace: workspace, presented: $presented)
    }
}

private struct WorkspaceDefinitionEditor: View {
    @Bindable var state: AppState
    let workspace: Workspace?
    @Binding var presented: Bool
    @State private var model: WorkspaceDefinitionDialogModel
    @State private var error: String?
    @State private var isSaving = false
    @State private var confirmingDeletion = false
    @State private var locationPickerOpen = false
    @Environment(\.theme) private var theme

    init(state: AppState, workspace: Workspace?, presented: Binding<Bool>) {
        self.state = state
        self.workspace = workspace
        self._presented = presented
        self._model = State(initialValue: workspace.map {
            WorkspaceDefinitionDialogModel(editing: $0, projects: state.projects)
        } ?? WorkspaceDefinitionDialogModel(
            executionLocation: state.projects.first?.host.map(ExecutionLocation.ssh) ?? .local,
            projects: state.projects
        ))
    }

    var body: some View {
        DialogContainer(
            title: workspace == nil ? "New workspace" : "Edit workspace",
            subtitle: workspace == nil ? nil : "Changes apply to future checkouts only.",
            content: {
                DialogField(label: "Name") {
                    AlasField(text: $model.name, placeholder: "Workspace name", focusOnAppear: true, isEnabled: !isSaving)
                        .accessibilityLabel("Workspace name")
                }
                DialogField(label: "Location") {
                    Button { locationPickerOpen.toggle() } label: {
                        HStack(spacing: 8) {
                            Icon(name: model.executionLocation.sshHost == nil ? "desktopcomputer" : "server.rack")
                            Text(model.executionLocation.sshHost ?? "This Mac")
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Icon(name: "chev-down", size: 9)
                        }
                        .font(.system(size: 12))
                        .foregroundColor(theme.color("fg"))
                        .alasFieldChrome(theme: theme)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $locationPickerOpen, arrowEdge: .bottom) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                locationOption("This Mac", location: .local)
                                ForEach(hosts, id: \.self) { host in
                                    locationOption(host, location: .ssh(host))
                                }
                            }
                            .padding(6)
                        }
                        .frame(width: 300, height: CGFloat(min(hosts.count + 1, 8)) * 30 + 12)
                    }
                    .accessibilityLabel("Execution location")
                    .disabled(isSaving)
                }
                repositories
                if let error { WorkspaceNotice(message: error, isError: true) }
                if workspace != nil {
                    Button("Delete workspace...", role: .destructive) { confirmingDeletion = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.color("del"))
                        .disabled(isSaving)
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: isSaving ? "Saving..." : workspace == nil ? "Create workspace" : "Save changes",
            confirmStyle: .primary,
            onCancel: { if !isSaving { presented = false } },
            onConfirm: save,
            confirmEnabled: !isSaving && !model.trimmedName.isEmpty && !model.members.isEmpty
        )
        .interactiveDismissDisabled(isSaving)
        .onExitCommand { if !isSaving { presented = false } }
        .confirmationDialog("Delete workspace?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Delete workspace", role: .destructive, action: deleteWorkspace)
            Button("Cancel", role: .cancel) { confirmingDeletion = false }
        } message: {
            Text("Delete \(workspace?.name ?? "this workspace")? Existing checkouts are retained as Former Workspace checkouts.")
        }
    }

    private var hosts: [String] {
        Array(Set(state.projects.compactMap(\.host) + [model.executionLocation.sshHost].compactMap { $0 })).sorted()
    }

    private func locationOption(_ title: String, location: ExecutionLocation) -> some View {
        Button {
            if model.executionLocation != location { model.executionLocation = location }
            locationPickerOpen = false
        } label: {
            HStack(spacing: 8) {
                Icon(name: "check", size: 10)
                    .opacity(model.executionLocation == location ? 1 : 0)
                Text(title).font(.system(size: 12)).foregroundColor(theme.color("fg"))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var repositories: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Repositories")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
                Text("\(model.members.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("fg-faint"))
                Spacer()
                Menu {
                    ForEach(model.eligibleProjects) { project in
                        Button(project.name) { _ = model.add(project: project) }
                    }
                } label: {
                    Icon(name: "plus", size: 12)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.eligibleProjects.isEmpty)
                .help("Add repository")
                .accessibilityLabel("Add repository")
            }
            if model.members.isEmpty {
                Text(model.eligibleProjects.isEmpty ? "No repositories at this location." : "No repositories selected.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.members.enumerated()), id: \.element.id) { index, member in
                            repositoryRow(member, index: index)
                            if index < model.members.count - 1 { Divider() }
                        }
                    }
                }
                .frame(height: CGFloat(min(model.members.count, 5)) * 53)
            }
        }
        .disabled(isSaving)
    }

    private func repositoryRow(_ member: WorkspaceMember, index: Int) -> some View {
        HStack(spacing: 10) {
            if let project = state.projects.first(where: { $0.id == member.projectID }) {
                ProjectIconView(icon: project.icon, fallbackName: project.name, size: .sidebar)
            } else {
                Icon(name: "folder", size: 14)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(member.fallbackProjectName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.color("fg"))
                Text(member.fallbackRepositoryRoot)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(theme.color("fg-dim"))
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            ToolbarBtn(icon: "arrow.up", tooltip: "Move \(member.fallbackProjectName) up") {
                model.moveMember(from: index, to: index - 1)
            }.disabled(index == 0)
            ToolbarBtn(icon: "arrow.down", tooltip: "Move \(member.fallbackProjectName) down") {
                model.moveMember(from: index, to: index + 1)
            }.disabled(index == model.members.count - 1)
            ToolbarBtn(icon: "x", tooltip: "Remove \(member.fallbackProjectName)") {
                model.removeMember(id: member.id)
            }
        }
        .frame(height: 52)
        .help(member.fallbackRepositoryRoot)
    }

    private func save() {
        guard !isSaving, !model.trimmedName.isEmpty, !model.members.isEmpty else { return }
        isSaving = true
        error = nil
        let definition = model.definition()
        Task { @MainActor in
            do {
                try await state.saveWorkspaceDefinition(definition)
                presented = false
            } catch {
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func deleteWorkspace() {
        guard let workspace, !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            do {
                try await state.deleteWorkspaceDefinition(id: workspace.id)
                presented = false
            } catch {
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }
}

struct CreateWorkspaceCheckoutDialog: View {
    @Bindable var state: AppState
    let workspace: Workspace
    @Binding var presented: Bool
    @State private var model: WorkspaceCheckoutCreationModel
    @State private var error: String?
    @State private var showsBaseOverrides = false
    @State private var isChecking = false
    @State private var creationFinished = false
    @State private var isVisible = true
    @Environment(\.theme) private var theme

    init(state: AppState, workspace: Workspace, presented: Binding<Bool>) {
        self.state = state
        self.workspace = workspace
        self._presented = presented
        self._model = State(initialValue: .init(workspace: workspace, branchPrefix: state.config.worktrees.branchPrefix))
    }

    var body: some View {
        DialogContainer(
            title: "New workspace checkout",
            subtitle: workspace.name,
            width: 560,
            content: {
                steps
                Group {
                    switch model.step {
                    case .details:
                        ScrollView { details }
                    case .preflight: preflight
                    case .creating: creation
                    }
                }
                .frame(height: 280, alignment: .top)
                if let error { WorkspaceNotice(message: error, isError: true) }
            },
            cancelTitle: model.step == .preflight && !isChecking ? "Back" : model.step == .creating ? "Close" : "Cancel",
            confirmTitle: confirmTitle,
            confirmStyle: .primary,
            onCancel: goBackOrClose,
            onConfirm: proceed,
            confirmEnabled: canProceed
        )
        .onExitCommand(perform: goBackOrClose)
        .onDisappear { isVisible = false }
    }

    private var steps: some View {
        HStack(spacing: 8) {
            ForEach(Array(["Details", "Review", "Create"].enumerated()), id: \.offset) { index, title in
                HStack(spacing: 6) {
                    Image(systemName: index < model.step.rawValue ? "checkmark.circle.fill" : "\(index + 1).circle\(index == model.step.rawValue ? ".fill" : "")")
                    Text(title)
                }
                .font(.system(size: 11.5, weight: index == model.step.rawValue ? .semibold : .regular))
                .foregroundColor(theme.color(index == model.step.rawValue ? "fg" : "fg-dim"))
                if index < 2 {
                    Rectangle().fill(theme.color("line")).frame(height: 1)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            DialogField(label: "Shared branch") {
                AlasField(text: $model.branch, placeholder: "feature/my-change", monospaced: true, focusOnAppear: true)
            }
            DialogField(label: "Checkout folder") {
                HStack(spacing: 8) {
                    AlasField(text: $model.rootPath, placeholder: "/path/to/checkouts/my-change", monospaced: true)
                    if workspace.executionLocation == .local {
                        ToolbarBtn(icon: "folder", tooltip: "Choose checkout folder", action: chooseCheckoutFolder)
                    }
                }
            }
            DialogField(label: "Base reference") {
                AlasField(text: $model.baseReference, placeholder: "main", monospaced: true)
            }
            DisclosureGroup("Base references by repository", isExpanded: $showsBaseOverrides) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(workspace.members) { member in
                        DialogField(label: member.fallbackProjectName) {
                            AlasField(text: Binding(
                                get: { model.memberBaseReferences[member.id] ?? "" },
                                set: { model.memberBaseReferences[member.id] = $0.isEmpty ? nil : $0 }
                            ), placeholder: model.baseReference, monospaced: true)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .font(.system(size: 11.5))
            .foregroundColor(theme.color("fg-muted"))
        }
    }

    private var preflight: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isChecking {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking repositories...")
                        .font(.system(size: 12)).foregroundColor(theme.color("fg-muted"))
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.preflightMessages, id: \.self) { WorkspaceNotice(message: $0, isError: true) }
                        if case .success(let plan) = model.preflightResult {
                            ForEach(plan.warnings, id: \.id) { WorkspaceNotice(message: $0.message) }
                            ForEach(plan.members, id: \.checkoutMemberID) { member in
                                HStack(alignment: .top, spacing: 10) {
                                    Icon(name: "checkmark.circle.fill", size: 14, color: theme.color("add"))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(workspace.members.first(where: { $0.projectID == member.projectID })?.fallbackProjectName ?? member.projectID)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(theme.color("fg"))
                                        Text("\(member.baseReference) → \(model.branch)")
                                            .foregroundColor(theme.color("fg-muted"))
                                        Text(member.branchIntent == .reuse ? "Use existing branch" : "Create branch at \(member.baseCommit.prefix(8))")
                                            .foregroundColor(theme.color("fg-dim"))
                                            .help(member.baseCommit)
                                        Text(member.destinationPath)
                                            .foregroundColor(theme.color("fg-dim"))
                                            .textSelection(.enabled)
                                    }
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 240)
            }
        }
    }

    private var creation: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = model.selectedCheckoutID, let checkout = state.workspacesManager.checkout(id: id) {
                let progress = model.progress(for: checkout)
                ProgressView(value: Double(progress.completedMembers), total: Double(max(progress.totalMembers, 1)))
                    .tint(theme.color("accent"))
                Text("\(progress.completedMembers) of \(progress.totalMembers) repositories ready")
                    .font(.system(size: 12)).foregroundColor(theme.color("fg-muted"))
            } else if !creationFinished {
                ProgressView().controlSize(.small)
                Text("Preparing checkout...").font(.system(size: 12)).foregroundColor(theme.color("fg-muted"))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
    }

    private var confirmTitle: String {
        switch model.step {
        case .details: "Review checkout"
        case .preflight: isChecking ? "Checking..." : "Create checkout"
        case .creating: creationFinished ? "Done" : "Creating..."
        }
    }

    private var canProceed: Bool {
        switch model.step {
        case .details: return !model.request().branch.isEmpty && !model.request().rootPath.isEmpty
        case .preflight:
            if case .success = model.preflightResult { return !isChecking }
            return false
        case .creating: return creationFinished
        }
    }

    private func goBackOrClose() {
        if model.step == .preflight && !isChecking {
            var details = WorkspaceCheckoutCreationModel(
                workspace: workspace, branch: model.branch, rootPath: model.rootPath, baseReference: model.baseReference
            )
            details.memberBaseReferences = model.memberBaseReferences
            model = details
            error = nil
        } else {
            presented = false
        }
    }

    private func chooseCheckoutFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.rootPath = url.path
        }
    }

    private func proceed() {
        guard canProceed else { return }
        error = nil
        switch model.step {
        case .details:
            guard case .success = model.advance() else { return }
            isChecking = true
            Task { @MainActor in
                let result = await state.preflightWorkspaceCheckout(model.request())
                guard isVisible else { return }
                model.receivePreflight(result)
                isChecking = false
            }
        case .preflight:
            guard model.beginCreation(), case .success(let plan) = model.preflightResult else { return }
            Task { @MainActor in
                do {
                    let checkout = try await state.createWorkspaceCheckout(workspace: workspace, plan: plan)
                    guard isVisible else { return }
                    model.didPersist(checkoutID: checkout.id)
                    while isVisible && !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(250))
                        guard isVisible else { return }
                        await state.workspacesManager.refreshCheckoutSnapshots()
                        guard isVisible else { return }
                        if let current = state.workspacesManager.checkout(id: checkout.id), current.operation == .idle {
                            if current.members.allSatisfy({ $0.checkpoint == .setupComplete }) {
                                presented = false
                            } else {
                                error = "Some repositories need attention. Open checkout details to continue."
                            }
                            break
                        }
                    }
                } catch {
                    self.error = error.localizedDescription
                }
                creationFinished = true
            }
        case .creating:
            presented = false
        }
    }
}

struct WorkspaceNotice: View {
    let message: String
    var isError = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Icon(name: "alert", size: 12, color: theme.color(isError ? "del" : "fg-muted"))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundColor(theme.color(isError ? "del" : "fg-muted"))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
