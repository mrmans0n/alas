import SwiftUI

/// Create or edit one schedule. Scripts are discovered from the worktree the
/// schedule will run in, through the same host-aware discovery the Run tab
/// uses, so a remote project lists what actually launches there.
struct RunScheduleEditorView: View {
    @Bindable var state: AppState
    let originWorktree: Worktree
    let schedule: RunSchedule?
    let onDismiss: () -> Void

    @State private var draft: RunScheduleDraft
    @State private var scripts: [RunScript] = []
    @State private var scriptDiscoveryError: String?
    @State private var errorMessage: String?
    @Environment(\.theme) private var theme

    init(state: AppState, originWorktree: Worktree, schedule: RunSchedule?, onDismiss: @escaping () -> Void) {
        _state = Bindable(wrappedValue: state)
        self.originWorktree = originWorktree
        self.schedule = schedule
        self.onDismiss = onDismiss
        if let schedule {
            _draft = State(initialValue: RunScheduleDraft(schedule: schedule))
        } else {
            let isMain = state.projectsManager.visibleMainWorktree(projectId: originWorktree.projectId)?.id == originWorktree.id
            _draft = State(initialValue: RunScheduleDraft(
                projectID: originWorktree.projectId,
                worktreeID: originWorktree.id,
                isMainWorktree: isMain
            ))
        }
    }

    var body: some View {
        DialogContainer(
            title: schedule == nil ? "New schedule" : "Edit schedule",
            subtitle: RunSchedulePresentation.notRunningNotice,
            width: 520,
            content: {
                DialogField(label: "Name") {
                    AlasField(text: $draft.name, placeholder: "Morning test run", focusOnAppear: schedule == nil)
                }
                DialogField(label: "Where") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 0) {
                            AlasSegmentedControl(
                                selection: draft.targetKind,
                                options: [
                                    AlasSegmentedOption(id: .thisWorktree, label: "Worktree"),
                                    AlasSegmentedOption(id: .mainWorktree, label: "Main worktree"),
                                    AlasSegmentedOption(id: .allProjects, label: "All projects"),
                                ],
                                onSelect: { draft.targetKind = $0 }
                            )
                            Spacer(minLength: 0)
                        }
                        if draft.targetKind != .allProjects {
                            projectPicker
                        }
                        if draft.targetKind == .thisWorktree {
                            worktreePicker
                        }
                        Text(targetHint)
                            .font(.system(size: 11))
                            .foregroundColor(theme.color("fg-dim"))
                    }
                }
                DialogField(label: "Script") {
                    scriptPicker
                }
                DialogField(label: "When") {
                    triggerFields
                }
                DialogField(label: "If occurrences are missed") {
                    HStack(spacing: 0) {
                        AlasSegmentedControl(
                            selection: draft.missedRunPolicy,
                            options: [
                                AlasSegmentedOption(id: .skip, label: "Skip them"),
                                AlasSegmentedOption(id: .runLatest, label: "Run once"),
                            ],
                            onSelect: { draft.missedRunPolicy = $0 }
                        )
                        Spacer(minLength: 0)
                    }
                }
                Toggle("Create a new worktree and launch an agent", isOn: $draft.createsWorktree)
                    .toggleStyle(.checkbox)
                if draft.createsWorktree {
                    compositionFields
                }
                if let message = errorMessage ?? draft.validationError, !draft.name.isEmpty || errorMessage != nil {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("warn"))
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: schedule == nil ? "Create schedule" : "Save",
            confirmStyle: .primary,
            onCancel: onDismiss,
            onConfirm: submit,
            confirmEnabled: draft.isValid
        )
        .task(id: discoveryKey) { await discoverScripts() }
    }

    // MARK: - Pickers

    private var projectPicker: some View {
        Picker("", selection: Binding(
            get: { draft.projectID ?? "" },
            set: { newValue in
                guard newValue != draft.projectID else { return }
                draft.projectID = newValue
                draft.worktreeID = state.projectsManager.visibleMainWorktree(projectId: newValue)?.id
            }
        )) {
            ForEach(state.projects) { project in
                Text(project.name).tag(project.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Project")
    }

    private var worktreePicker: some View {
        let worktrees = draft.projectID.map { state.projectsManager.visibleWorktrees(projectId: $0) } ?? []
        return Picker("", selection: Binding(
            get: { draft.worktreeID ?? "" },
            set: { draft.worktreeID = $0 }
        )) {
            ForEach(worktrees) { worktree in
                Text(worktree.branch).tag(worktree.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Worktree")
    }

    private var scriptPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Binding(
                get: { draft.scriptKey ?? "" },
                set: { draft.scriptKey = $0.isEmpty ? nil : $0 }
            )) {
                Text(draft.createsWorktree ? "None (just launch the agent)" : "Choose a script").tag("")
                ForEach(RunScriptScope.allCases, id: \.self) { scope in
                    let scoped = scripts.filter { $0.scope == scope }
                    if !scoped.isEmpty {
                        Divider()
                        ForEach(scoped) { script in
                            Text("\(script.displayName) · \(scope.sectionTitle.lowercased())").tag(script.key)
                        }
                    }
                }
                if let key = draft.scriptKey, !scripts.contains(where: { $0.key == key }) {
                    Divider()
                    Text("\(RunSchedulePresentation.scriptDisplayName(key)) · missing").tag(key)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Script")
            if let scriptDiscoveryError {
                Text(scriptDiscoveryError)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("warn"))
            } else if scripts.isEmpty {
                Text("No run scripts found in the target worktree.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
            }
        }
    }

    private var triggerFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                AlasSegmentedControl(
                    selection: draft.triggerKind,
                    options: [
                        AlasSegmentedOption(id: .timeOfDay, label: "At a time"),
                        AlasSegmentedOption(id: .interval, label: "Every interval"),
                    ],
                    onSelect: { draft.triggerKind = $0 }
                )
                Spacer(minLength: 0)
            }
            switch draft.triggerKind {
            case .interval:
                HStack(spacing: 8) {
                    Text("Every")
                        .font(.system(size: 12))
                    Stepper(value: $draft.intervalValue, in: 1...999) {
                        Text("\(draft.intervalValue)")
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minWidth: 28, alignment: .trailing)
                    }
                    Picker("", selection: $draft.intervalUnit) {
                        ForEach(RunScheduleDraft.IntervalUnit.allCases, id: \.self) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Interval unit")
                }
            case .timeOfDay:
                HStack(spacing: 8) {
                    Text("At")
                        .font(.system(size: 12))
                    Stepper(value: $draft.hour, in: 0...23) {
                        Text(String(format: "%02d", draft.hour))
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .accessibilityLabel("Hour")
                    Text(":")
                    Stepper(value: $draft.minute, in: 0...59, step: 5) {
                        Text(String(format: "%02d", draft.minute))
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .accessibilityLabel("Minute")
                }
                HStack(spacing: 6) {
                    ForEach(1...7, id: \.self) { day in
                        Toggle(isOn: Binding(
                            get: { draft.weekdays.contains(day) },
                            set: { on in
                                if on { draft.weekdays.insert(day) } else { draft.weekdays.remove(day) }
                            }
                        )) {
                            Text(Calendar.current.veryShortWeekdaySymbols[day - 1])
                                .font(.system(size: 11))
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                    }
                }
            }
        }
    }

    private var compositionFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            DialogField(label: "Branch template") {
                VStack(alignment: .leading, spacing: 4) {
                    AlasField(text: $draft.branchTemplate, placeholder: RunScheduleComposition.defaultBranchTemplate, monospaced: true)
                    Text("Variables: {name}, {date}, {time}. Preview: \(branchPreview)")
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-dim"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            DialogField(label: "Agent") {
                Picker("", selection: Binding(
                    get: { draft.agentID ?? "" },
                    set: { draft.agentID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Project default").tag("")
                    ForEach(state.agentRegistry.enabled()) { agent in
                        Text(agent.displayName).tag(agent.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Agent")
            }
            Text("The worktree-create script runs first; the script above runs in the new worktree; the agent opens in a terminal there once it succeeds.")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Derived

    private var targetHint: String {
        switch draft.targetKind {
        case .allProjects:
            return "Runs in the main worktree of every project."
        case .mainWorktree:
            return "Runs in the project's main worktree, even after other worktrees come and go."
        case .thisWorktree:
            return "Runs in this worktree only; the schedule skips if the worktree is deleted."
        }
    }

    private var branchPreview: String {
        RunSchedulePlanner.renderBranch(
            template: draft.branchTemplate,
            name: draft.name.isEmpty ? "schedule" : draft.name,
            now: Date()
        )
    }

    /// The worktree whose scripts the picker lists.
    private var discoveryWorktree: Worktree? {
        switch draft.targetKind {
        case .allProjects:
            return state.projects.lazy
                .compactMap { state.projectsManager.visibleMainWorktree(projectId: $0.id) }
                .first
        case .mainWorktree:
            return draft.projectID.flatMap { state.projectsManager.visibleMainWorktree(projectId: $0) }
        case .thisWorktree:
            guard let projectID = draft.projectID, let worktreeID = draft.worktreeID else { return nil }
            return state.projectsManager.worktrees(projectId: projectID).first { $0.id == worktreeID }
        }
    }

    private var discoveryKey: String {
        "\(draft.targetKind.rawValue)|\(draft.projectID ?? "")|\(draft.worktreeID ?? "")"
    }

    private func discoverScripts() async {
        guard let worktree = discoveryWorktree else {
            scripts = []
            scriptDiscoveryError = nil
            return
        }
        let host = state.projects.first { $0.id == worktree.projectId }?.host
        switch await RunScriptStore.discoverScripts(worktreeRoot: worktree.path, remoteHost: host) {
        case .scripts(let found):
            guard !Task.isCancelled else { return }
            scripts = found
            scriptDiscoveryError = nil
        case .failed(let message):
            guard !Task.isCancelled else { return }
            scripts = []
            scriptDiscoveryError = message
        }
    }

    private func submit() {
        guard let built = draft.makeSchedule(existing: schedule) else {
            errorMessage = draft.validationError
            return
        }
        if schedule == nil {
            state.runScheduler.add(built)
        } else {
            state.runScheduler.update(built)
        }
        onDismiss()
    }
}
