import SwiftUI

/// Create or edit one schedule. Scripts are discovered from the worktree the
/// schedule will run in, through the same host-aware discovery the Run tab
/// uses, so a remote project lists what actually launches there.
///
/// Laid out as three hairline-separated sections — where, when, and the
/// optional worktree + agent step — with the trigger composed inside a card
/// that keeps a live "Runs weekdays at 09:00 · Next: Tomorrow" summary, so
/// the schedule reads back as a sentence before it is saved.
struct RunScheduleEditorView: View {
    @Bindable var state: AppState
    let originWorktree: Worktree
    let schedule: RunSchedule?
    let onDismiss: () -> Void

    @State private var draft: RunScheduleDraft
    @State private var scripts: [RunScript] = []
    @State private var scriptDiscoveryError: String?
    @State private var errorMessage: String?
    /// What the preview is measured from. It has to keep up with the clock,
    /// because saving anchors on the moment you press the button: a dialog
    /// left open at 09:00 would otherwise promise an hourly schedule at
    /// 10:00 and then create one at 10:20.
    ///
    /// Every second, so the displayed minute is the one saving would use.
    /// The label only redraws when that minute changes, so this is not the
    /// flicker a fast tick sounds like.
    @State private var now = Date()
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @Environment(\.theme) private var theme

    private let calendar = Calendar.autoupdatingCurrent

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
            width: 560,
            content: {
                DialogField(label: "Name") {
                    AlasField(text: $draft.name, placeholder: "Morning test run", focusOnAppear: schedule == nil)
                }
                sectionRule
                whereSection
                sectionRule
                whenSection
                sectionRule
                compositionSection
                if let message = errorMessage ?? draft.validationError, !draft.name.isEmpty || errorMessage != nil {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("warn"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: schedule == nil ? "Create schedule" : "Save",
            confirmStyle: .primary,
            onCancel: onDismiss,
            onConfirm: submit,
            confirmEnabled: draft.isValid,
            footerHint: nextFireLabel
        )
        .task(id: discoveryKey) { await discoverScripts() }
        .onAppear { now = Date() }
        .onReceive(ticker) { now = $0 }
    }

    // MARK: - Sections

    private var sectionRule: some View {
        Rectangle()
            .fill(theme.color("line-soft"))
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(theme.color("fg-dim"))
    }

    private var whereSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Where")
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
                HStack(spacing: 8) {
                    projectPicker
                    if draft.targetKind == .thisWorktree {
                        worktreePicker
                    }
                }
            }
            helpText(targetHint)
            DialogField(label: "Script") {
                scriptPicker
            }
            .padding(.top, 4)
        }
    }

    private var whenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionTitle("When")
                Spacer(minLength: 8)
                AlasSegmentedControl(
                    selection: draft.triggerKind,
                    options: [
                        AlasSegmentedOption(id: .timeOfDay, label: "At a time"),
                        AlasSegmentedOption(id: .interval, label: "Every interval"),
                    ],
                    onSelect: { draft.triggerKind = $0 }
                )
            }
            triggerComposer
            HStack(spacing: 10) {
                Text("If occurrences are missed")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-muted"))
                Spacer(minLength: 8)
                AlasSegmentedControl(
                    selection: draft.missedRunPolicy,
                    options: [
                        AlasSegmentedOption(id: .skip, label: "Skip"),
                        AlasSegmentedOption(id: .runLatest, label: "Run once"),
                    ],
                    onSelect: { draft.missedRunPolicy = $0 }
                )
            }
        }
    }

    private var compositionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScheduleCheckbox(isOn: $draft.createsWorktree, label: "Create a new worktree and launch an agent")
            if draft.createsWorktree {
                compositionFields
            }
        }
    }

    // MARK: - Trigger composer

    private var triggerComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch draft.triggerKind {
            case .timeOfDay:
                HStack(spacing: 10) {
                    composerLead("At")
                    ClockField(hour: $draft.hour, minute: $draft.minute)
                    composerLead("on")
                    weekdayCircles
                }
                HStack(spacing: 4) {
                    ForEach(RunScheduleDraft.WeekdayPreset.allCases, id: \.self) { preset in
                        presetPill(preset)
                    }
                }
            case .interval:
                HStack(spacing: 10) {
                    composerLead("Every")
                    NumberField(value: $draft.intervalValue, range: 1...999, accessibilityLabel: "Interval")
                    AlasSegmentedControl(
                        selection: draft.intervalUnit,
                        options: RunScheduleDraft.IntervalUnit.allCases.map {
                            AlasSegmentedOption(id: $0, label: $0.rawValue)
                        },
                        onSelect: { draft.intervalUnit = $0 }
                    )
                    .accessibilityLabel("Interval unit")
                }
            }
            summaryRow
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background(theme.color("field-bg"))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(theme.color("line-soft"), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func composerLead(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundColor(theme.color("fg-muted"))
    }

    /// Sunday-first or Monday-first, whichever the user's calendar says.
    private var orderedWeekdays: [Int] {
        (0..<7).map { ((calendar.firstWeekday - 1 + $0) % 7) + 1 }
    }

    private var weekdayCircles: some View {
        HStack(spacing: 4) {
            ForEach(orderedWeekdays, id: \.self) { day in
                let isOn = draft.weekdays.contains(day)
                let name = calendar.weekdaySymbols[day - 1]
                Button {
                    draft.toggleWeekday(day)
                } label: {
                    Text(calendar.veryShortStandaloneWeekdaySymbols[day - 1])
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(isOn ? theme.color("bg-0") : theme.color("fg-dim"))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(isOn ? theme.color("accent") : Color.clear))
                        .overlay(Circle().strokeBorder(isOn ? Color.clear : theme.color("line"), lineWidth: 0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(name)
                .accessibilityLabel(name)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    private func presetPill(_ preset: RunScheduleDraft.WeekdayPreset) -> some View {
        let isOn = draft.weekdayPreset == preset
        return Button {
            draft.apply(preset)
        } label: {
            Text(preset.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isOn ? theme.color("seg-pill-active-fg") : theme.color("fg-faint"))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(isOn ? theme.color("accent-soft") : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var summaryRow: some View {
        HStack(spacing: 8) {
            Icon(name: "clock", size: 12, color: theme.color("accent"))
            summaryText
                .font(.system(size: 11.5))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(nextFireLabel)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundColor(theme.color("fg-faint"))
                .lineLimit(1)
        }
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.color("line-soft"))
                .frame(height: 0.5)
        }
    }

    private var summaryText: Text {
        RunSchedulePresentation.triggerSummarySegments(draft.trigger, calendar: calendar)
            .reduce(Text("")) { partial, segment in
                partial + Text(segment.text)
                    .fontWeight(segment.isEmphasized ? .medium : .regular)
                    .foregroundColor(theme.color(segment.isEmphasized ? "fg-muted" : "fg-dim"))
            }
    }

    private var nextFireLabel: String {
        let scheduleState = schedule.map { state.runScheduler.state(for: $0.id) }
        let next = RunSchedulePresentation.editorNextFireDate(
            existingTrigger: schedule?.trigger,
            draftTrigger: draft.trigger,
            storedNextFireAt: scheduleState?.nextFireAt,
            // Anchored where the scheduler will anchor it: an edited trigger
            // is measured from the schedule's last fire, so a preview taken
            // from now would promise a later occurrence than saving gives.
            computedNextFireAt: draft.nextFireDate(
                now: now,
                anchor: scheduleState?.lastFiredAt,
                calendar: calendar
            )
        )
        return RunSchedulePresentation.nextFirePreviewLabel(next, now: now, calendar: calendar)
    }

    // MARK: - Pickers

    private var projectPicker: some View {
        ProjectPicker(
            selection: Binding(
                get: { draft.projectID ?? "" },
                set: { newValue in
                    guard newValue != draft.projectID else { return }
                    draft.projectID = newValue
                    draft.worktreeID = state.projectsManager.visibleMainWorktree(projectId: newValue)?.id
                }
            ),
            projects: state.projects,
            icon: { state.effectiveIcon(for: $0) }
        )
        .fixedSize()
        .accessibilityLabel("Project")
    }

    private var worktreePicker: some View {
        let worktrees = draft.projectID.map { state.projectsManager.visibleWorktrees(projectId: $0) } ?? []
        let selected = worktrees.first { $0.id == draft.worktreeID }
        return ScheduleChipMenu(
            title: selected?.branch ?? "Choose a worktree",
            monospaced: true,
            grows: true
        ) {
            Picker("", selection: Binding(
                get: { draft.worktreeID ?? "" },
                set: { draft.worktreeID = $0 }
            )) {
                ForEach(worktrees) { worktree in
                    Text(worktree.branch).tag(worktree.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .accessibilityLabel("Worktree")
    }

    private var scriptPicker: some View {
        let noneTitle = draft.createsWorktree ? "None (just launch the agent)" : "Choose a script"
        let selectedTitle: String = {
            guard let key = draft.scriptKey else { return noneTitle }
            if let script = scripts.first(where: { $0.key == key }) {
                return "\(script.displayName) · \(script.scope.sectionTitle.lowercased())"
            }
            return "\(RunSchedulePresentation.scriptDisplayName(key)) · missing"
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ScheduleChipMenu(title: selectedTitle) {
                    Picker("", selection: Binding(
                        get: { draft.scriptKey ?? "" },
                        set: { draft.scriptKey = $0.isEmpty ? nil : $0 }
                    )) {
                        Text(noneTitle).tag("")
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
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .accessibilityLabel("Script")
                Spacer(minLength: 0)
            }
            if let scriptDiscoveryError {
                Text(scriptDiscoveryError)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("warn"))
            } else if scripts.isEmpty {
                helpText("No run scripts found in the target worktree.")
            }
        }
    }

    private var agentPicker: some View {
        let agents = state.agentRegistry.enabled()
        // An agent that has since been disabled or removed is still named,
        // the way a missing script is. Showing "Project default" for it
        // would be a lie: the id stays in the draft and is saved, and the
        // next firing fails on an agent the dialog claimed was not selected.
        let missingAgentID = draft.agentID.flatMap { id in
            agents.contains { $0.id == id } ? nil : id
        }
        let title: String = {
            guard let id = draft.agentID else { return "Project default" }
            if let agent = agents.first(where: { $0.id == id }) { return agent.displayName }
            return "\(id) · unavailable"
        }()
        return ScheduleChipMenu(title: title) {
            Picker("", selection: Binding(
                get: { draft.agentID ?? "" },
                set: { draft.agentID = $0.isEmpty ? nil : $0 }
            )) {
                Text("Project default").tag("")
                ForEach(agents) { agent in
                    Text(agent.displayName).tag(agent.id)
                }
                if let missingAgentID {
                    Divider()
                    Text("\(missingAgentID) · unavailable").tag(missingAgentID)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .accessibilityLabel("Agent")
    }

    // MARK: - Composition

    private var compositionFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            DialogField(label: "Branch template") {
                VStack(alignment: .leading, spacing: 4) {
                    AlasField(text: $draft.branchTemplate, placeholder: RunScheduleComposition.defaultBranchTemplate, monospaced: true)
                    (Text("Variables ")
                        + Text("{name}").font(.system(size: 10.5, design: .monospaced))
                        + Text(" ")
                        + Text("{date}").font(.system(size: 10.5, design: .monospaced))
                        + Text(" ")
                        + Text("{time}").font(.system(size: 10.5, design: .monospaced))
                        + Text(" · Preview ")
                        + Text(branchPreview).font(.system(size: 10.5, design: .monospaced)))
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-faint"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            DialogField(label: "Agent") {
                HStack(spacing: 0) {
                    agentPicker
                    Spacer(minLength: 0)
                }
            }
            DialogField(label: "Prompt") {
                VStack(alignment: .leading, spacing: 8) {
                    PromptField(
                        text: $draft.prompt,
                        placeholder: "e.g. Run the full test suite, fix any failures, and open a PR summarising the changes."
                    )
                    ScheduleCheckbox(isOn: $draft.sendsPromptAutomatically, label: "Send the prompt automatically when the agent starts")
                    helpText(RunSchedulePresentation.promptDeliveryHint(sendsAutomatically: draft.sendsPromptAutomatically))
                }
            }
            helpText("The worktree-create script runs first; the script above runs in the new worktree; the agent opens in a terminal there once it succeeds.")
        }
        .padding(.leading, 23)
        .padding(.top, 2)
        .overlay(alignment: .leading) {
            // The rule that ties the sub-fields to the checkbox above them.
            Rectangle()
                .fill(theme.color("line"))
                .frame(width: 1)
                .padding(.leading, 7)
                .padding(.vertical, 4)
                .accessibilityHidden(true)
        }
    }

    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-faint"))
            .fixedSize(horizontal: false, vertical: true)
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
            now: now
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

// MARK: - Controls

/// A field-shaped menu: current value, chevron, and a menu of choices. The
/// same silhouette as `ProjectPicker` so a row of the two reads as one kind
/// of control.
private struct ScheduleChipMenu<Items: View>: View {
    let title: String
    var monospaced = false
    var grows = false
    @ViewBuilder let items: () -> Items

    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: monospaced ? 11.5 : 12, design: monospaced ? .monospaced : .default))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if grows {
                    Spacer(minLength: 0)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.color("fg-dim"))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: grows ? .infinity : nil)
            .background(theme.color("bg-1"))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !grows, vertical: true)
    }
}

/// The design's small square checkbox, drawn in theme colours rather than
/// AppKit's, with the label as part of the click target.
private struct ScheduleCheckbox: View {
    @Binding var isOn: Bool
    let label: String

    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn ? theme.color("accent") : theme.color("field-bg"))
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isOn ? Color.clear : theme.color("line"), lineWidth: 0.5)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.color("bg-0"))
                    }
                }
                .frame(width: 15, height: 15)
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundColor(theme.color("fg"))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(label, isOn: $isOn)
        }
    }
}

/// `HH:MM` as two digit cells sharing one field chrome.
private struct ClockField: View {
    @Binding var hour: Int
    @Binding var minute: Int

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            DigitCell(value: $hour, range: 0...23, width: 34, accessibilityLabel: "Hour")
            Text(":")
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(theme.color("fg-dim"))
                .padding(.horizontal, -2)
                .padding(.bottom, 2)
            DigitCell(value: $minute, range: 0...59, width: 34, accessibilityLabel: "Minute")
        }
        .digitFieldChrome(theme: theme)
    }
}

/// One integer in the same chrome as `ClockField`, for the interval count.
private struct NumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let accessibilityLabel: String

    @Environment(\.theme) private var theme

    var body: some View {
        DigitCell(value: $value, range: range, width: 40, pads: false, accessibilityLabel: accessibilityLabel)
            .digitFieldChrome(theme: theme)
    }
}

private extension View {
    func digitFieldChrome(theme: Theme) -> some View {
        padding(.horizontal, 4)
            .frame(height: 34)
            .background(theme.color("bg-0"))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// A numeric text cell that clamps into `range` as you type and re-pads on
/// blur, so "9" reads back as "09" without fighting the caret mid-edit.
private struct DigitCell: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let width: CGFloat
    var pads = true
    let accessibilityLabel: String

    @State private var text = ""
    @FocusState private var isFocused: Bool
    @Environment(\.theme) private var theme

    private var maxDigits: Int { String(range.upperBound).count }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 17, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .foregroundColor(theme.color("fg"))
            .frame(width: width, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isFocused ? theme.color("accent-soft") : Color.clear)
            )
            .focused($isFocused)
            .onAppear { text = formatted(value) }
            .onChange(of: value) { _, newValue in
                if !isFocused { text = formatted(newValue) }
            }
            .onChange(of: text) { _, newText in
                // Any decimal digit is accepted and rewritten as ASCII.
                // `Character.isNumber` alone would keep Arabic-Indic and
                // full-width digits that `Int` then refuses to parse, which
                // left the box showing a number the draft did not have.
                // `wholeNumberValue` also answers for things like Roman
                // numerals, so the range check is what keeps this to digits.
                let digits = String(
                    newText.compactMap { character -> Character? in
                        guard let value = character.wholeNumberValue, (0...9).contains(value) else { return nil }
                        return Character(String(value))
                    }
                    .prefix(maxDigits)
                )
                if digits != newText {
                    text = digits
                    return
                }
                // An emptied box reads as its lowest legal value rather than
                // silently keeping the old one: the field would otherwise
                // show nothing while the draft still carried, and saved, the
                // number the user just deleted.
                let typed = Int(digits) ?? range.lowerBound
                let clamped = min(max(typed, range.lowerBound), range.upperBound)
                if clamped != typed {
                    text = formatted(clamped)
                }
                value = clamped
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { text = formatted(value) }
            }
            .onSubmit { text = formatted(value) }
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(formatted(value))
    }

    private func formatted(_ number: Int) -> String {
        pads ? String(format: "%02d", number) : String(number)
    }
}

/// A few lines of prompt with a placeholder, in field chrome.
private struct PromptField: View {
    @Binding var text: String
    let placeholder: String

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 12.5))
                .foregroundColor(theme.color("fg"))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 64, maxHeight: 140)
                .padding(.horizontal, 5)
                .padding(.vertical, 6)
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12.5))
                    .foregroundColor(theme.color("fg-faint"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(theme.color("field-bg"))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Prompt")
    }
}
