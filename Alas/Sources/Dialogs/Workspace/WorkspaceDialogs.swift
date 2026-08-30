import SwiftUI

struct NewWorkspaceDialog: View {
    @Bindable var state: AppState
    @Binding var presented: Bool
    @State private var model: WorkspaceDefinitionDialogModel
    @State private var error: String?

    init(state: AppState, presented: Binding<Bool>) {
        self.state = state
        self._presented = presented
        let location = state.projects.first?.host.map(ExecutionLocation.ssh) ?? .local
        self._model = State(initialValue: .init(executionLocation: location, projects: state.projects))
    }
    var body: some View { definitionBody(title: "New Workspace") }
    @ViewBuilder private func definitionBody(title: String) -> some View {
        DialogContainer(title: title, subtitle: "A definition for future coordinated checkouts.", content: {
            TextField("Workspace name", text: $model.name)
            executionLocationControls
            Text("Members").font(.headline)
            ForEach(Array(model.members.enumerated()), id: \.element.id) { index, member in
                HStack { Text(member.fallbackProjectName)
                Spacer()
                Button("Up") { model.moveMember(from: index, to: max(0, index - 1)) }.disabled(index == 0)
                Button("Down") { model.moveMember(from: index, to: min(model.members.count - 1, index + 1)) }.disabled(index + 1 == model.members.count)
                Button("Remove", role: .destructive) { model.removeMember(id: member.id) } }
            }
            ForEach(model.eligibleProjects) { project in Button("Add \(project.name)") { _ = model.add(project: project) } }
            if let error { Text(error).foregroundStyle(.red) }
        }, cancelTitle: "Cancel", confirmTitle: model.saveTitle, confirmStyle: .primary, onCancel: { presented = false }, onConfirm: save, confirmEnabled: !model.trimmedName.isEmpty && !model.members.isEmpty)
    }
    private func save() { let definition = model.definition()
    Task { @MainActor in do { try await state.saveWorkspaceDefinition(definition)
    presented = false } catch { self.error = error.localizedDescription } } }
    @ViewBuilder private var executionLocationControls: some View { HStack { Text("Execution location")
    Button("Local") { model.executionLocation = .local }
    ForEach(Array(Set(state.projects.compactMap(\.host))).sorted(), id: \.self) { host in Button(host) { model.executionLocation = .ssh(host) } } } }
}

struct EditWorkspaceDialog: View {
    @Bindable var state: AppState
    @Binding var presented: Bool
    let workspace: Workspace
    @State private var model: WorkspaceDefinitionDialogModel
    @State private var error: String?
    init(state: AppState, workspace: Workspace, presented: Binding<Bool>) { self.state = state
    self.workspace = workspace
    self._presented = presented
    self._model = State(initialValue: .init(editing: workspace, projects: state.projects)) }
    var body: some View {
        DialogContainer(title: "Edit Workspace", subtitle: "Changes apply to future checkouts only.", content: {
            TextField("Workspace name", text: $model.name)
            HStack { Text("Execution location")
            Button("Local") { model.executionLocation = .local }
            ForEach(Array(Set(state.projects.compactMap(\.host))).sorted(), id: \.self) { host in Button(host) { model.executionLocation = .ssh(host) } } }
            ForEach(Array(model.members.enumerated()), id: \.element.id) { index, member in HStack { Text(member.fallbackProjectName)
            Button("Up") { model.moveMember(from: index, to: max(0, index - 1)) }.disabled(index == 0)
            Button("Down") { model.moveMember(from: index, to: min(model.members.count - 1, index + 1)) }.disabled(index + 1 == model.members.count)
            Button("Remove", role: .destructive) { model.removeMember(id: member.id) } } }
            ForEach(model.eligibleProjects) { project in Button("Add \(project.name)") { _ = model.add(project: project) } }
            if let error { Text(error).foregroundStyle(.red) }
        }, cancelTitle: "Cancel", confirmTitle: model.saveTitle, confirmStyle: .primary, onCancel: { presented = false }, onConfirm: save, confirmEnabled: !model.trimmedName.isEmpty && !model.members.isEmpty)
    }
    private func save() { let definition = model.definition()
    Task { @MainActor in do { try await state.saveWorkspaceDefinition(definition)
    presented = false } catch { self.error = error.localizedDescription } } }
}

struct CreateWorkspaceCheckoutDialog: View {
    @Bindable var state: AppState
    let workspace: Workspace
    @Binding var presented: Bool
    @State private var model: WorkspaceCheckoutCreationModel
    @State private var error: String?
    init(state: AppState, workspace: Workspace, presented: Binding<Bool>) { self.state = state
    self.workspace = workspace
    self._presented = presented
    self._model = State(initialValue: .init(workspace: workspace)) }
    var body: some View {
        DialogContainer(title: "Create Workspace Checkout", subtitle: subtitle, content: {
            if model.step == .details { TextField("Shared branch", text: $model.branch)
            TextField("Checkout root", text: $model.rootPath)
            TextField("Base reference", text: $model.baseReference)
            ForEach(workspace.members) { member in TextField("\(member.fallbackProjectName) base override", text: Binding(get: { model.memberBaseReferences[member.id] ?? "" }, set: { value in if value.isEmpty { model.memberBaseReferences[member.id] = nil } else { model.memberBaseReferences[member.id] = value } })) } }
            if model.step == .preflight { Text("Preflight never creates files or Git artifacts.").foregroundStyle(.secondary)
            ForEach(model.preflightMessages, id: \.self) { Text($0).foregroundStyle(.red) }
            if case .success(let plan) = model.preflightResult { ForEach(plan.warnings, id: \.id) { Text($0.message).foregroundStyle(.orange) }
            ForEach(plan.members, id: \.checkoutMemberID) { member in Text(verbatim: "✓ \(member.projectID): \(member.baseReference) @ \(member.baseCommit), \(member.branchIntent), \(member.destinationPath)") } } }
            if model.step == .creating, let id = model.selectedCheckoutID, let checkout = state.workspacesManager.checkout(id: id) { let progress = model.progress(for: checkout)
            Text("Creating \(progress.completedMembers) of \(progress.totalMembers) members") }
            if let error { Text(error).foregroundStyle(.red) }
        }, cancelTitle: "Cancel", confirmTitle: confirmTitle, confirmStyle: .primary, onCancel: { presented = false }, onConfirm: proceed, confirmEnabled: model.step != .creating || model.selectedCheckoutID == nil)
    }
    private var subtitle: String { "Step \(model.step.rawValue + 1) of 3" }
    private var confirmTitle: String { model.step == .details ? "Preflight" : model.step == .preflight ? "Create Checkout" : "Creating" }
    private func proceed() { switch model.step { case .details: let result = model.advance()
    guard case .success = result else { error = result.failureMessage
    return }
    Task { @MainActor in model.receivePreflight(await state.preflightWorkspaceCheckout(model.request())) }
    case .preflight: guard model.beginCreation(), case .success(let plan) = model.preflightResult else { return }
    Task { @MainActor in do { let checkout = try await state.createWorkspaceCheckout(workspace: workspace, plan: plan)
    model.didPersist(checkoutID: checkout.id)
    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(250))
    await state.workspacesManager.refreshCheckoutSnapshots()
    if let current = state.workspacesManager.checkout(id: checkout.id), current.operation == .idle { if current.members.allSatisfy({ $0.checkpoint == .setupComplete }) { presented = false } else { error = "Creation needs attention. Review the failed member before closing this dialog." }
    break } } } catch { self.error = error.localizedDescription } }
    case .creating: break } }
}

private extension WorkspaceCheckoutCreationAdvanceResult { var failureMessage: String? { if case .failure(let message) = self { message } else { nil } } }
