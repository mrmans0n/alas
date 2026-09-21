import SwiftUI

/// Schedules relevant to one worktree: the ones aimed at it, plus, on the
/// project's main worktree, every schedule for the project. Rows carry live
/// state (last outcome, next fire, running) and the header owns pausing and
/// the sleep / not-running notice. Firing itself happens in `RunScheduler`
/// regardless of whether this tab is showing.
struct SchedulesTabView: View {
    @Bindable var state: AppState
    let worktree: Worktree

    @Environment(\.theme) private var theme
    @State private var editing: EditTarget?
    @State private var now = Date()
    @State private var ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    enum EditTarget: Identifiable {
        case existing(String)
        case new
        var id: String {
            switch self {
            case .existing(let id): return id
            case .new: return "__new__"
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                notice(RunSchedulePresentation.notRunningNotice, tone: "fg-faint", icon: "info.circle")
                if let gap = state.runScheduler.lastGap {
                    notice(RunSchedulePresentation.gapLabel(gap), tone: "warn", icon: "exclamationmark.triangle")
                }
                if schedules.isEmpty {
                    emptyState
                } else {
                    ForEach(schedules) { schedule in
                        ScheduleCard(
                            state: state,
                            schedule: schedule,
                            now: now,
                            onEdit: { editing = .existing(schedule.id) }
                        )
                    }
                }
            }
            .padding(.top, PaneBandLayout.outerVertical)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(ticker) { now = $0 }
        .onChange(of: state.runScheduler.evaluationGeneration) { now = Date() }
        .sheet(item: $editing) { target in
            switch target {
            case .new:
                RunScheduleEditorView(state: state, originWorktree: worktree, schedule: nil) { editing = nil }
            case .existing(let id):
                RunScheduleEditorView(
                    state: state,
                    originWorktree: worktree,
                    schedule: state.runScheduler.schedule(id: id)
                ) { editing = nil }
            }
        }
    }

    private var isMainWorktree: Bool {
        state.projectsManager.visibleMainWorktree(projectId: worktree.projectId)?.id == worktree.id
    }

    private var schedules: [RunSchedule] {
        RunSchedulePresentation.visibleSchedules(
            state.runScheduler.schedules,
            worktreeID: worktree.id,
            projectID: worktree.projectId,
            isMainWorktree: isMainWorktree
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(isMainWorktree ? "PROJECT SCHEDULES" : "SCHEDULES")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(theme.color("fg-muted"))
            Text("\(schedules.count)")
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(theme.color("seg-pill-bg"))
                .clipShape(Capsule())
                .foregroundColor(theme.color("fg-muted"))
            Spacer(minLength: 8)
            pauseMenu
            Button { editing = .new } label: {
                Icon(name: "plus", size: 12, color: theme.color("fg-muted"))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New schedule")
            .accessibilityLabel("New schedule")
            .accessibilityIdentifier("schedules-new")
        }
        .paneBand(fill: theme.color("section-head-bg"))
    }

    private var pauseMenu: some View {
        let projectName = state.projects.first { $0.id == worktree.projectId }?.name ?? "this project"
        let isProjectPaused = state.runScheduler.pausedProjectIDs.contains(worktree.projectId)
        let isGloballyPaused = state.runScheduler.isPausedGlobally
        return Menu {
            Toggle("Pause all schedules", isOn: Binding(
                get: { isGloballyPaused },
                set: { state.runScheduler.setPausedGlobally($0) }
            ))
            Toggle("Pause \(projectName)", isOn: Binding(
                get: { isProjectPaused },
                set: { state.runScheduler.setProjectPaused($0, projectID: worktree.projectId) }
            ))
        } label: {
            Icon(
                name: isGloballyPaused || isProjectPaused ? "pause.circle.fill" : "pause.circle",
                size: 12,
                color: theme.color(isGloballyPaused || isProjectPaused ? "warn" : "fg-muted")
            )
            .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isGloballyPaused ? "All schedules are paused" : isProjectPaused ? "\(projectName) schedules are paused" : "Pause schedules")
        .accessibilityLabel("Pause schedules")
    }

    private func notice(_ text: String, tone: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Icon(name: icon, size: 11, color: theme.color(tone))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundColor(theme.color(tone))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Icon(name: "clock", size: 22, color: theme.color("fg-faint"))
            Text("No schedules yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
            Text("Run a script on a timer, or open a fresh worktree with an agent every morning.")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-faint"))
                .multilineTextAlignment(.center)
            Button("New Schedule") { editing = .new }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .accessibilityIdentifier("schedules-empty-state")
    }
}

private struct ScheduleCard: View {
    @Bindable var state: AppState
    let schedule: RunSchedule
    let now: Date
    let onEdit: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var menuHovered = false
    @State private var isConfirmingDelete = false

    var body: some View {
        let scheduleState = state.runScheduler.state(for: schedule.id)
        let isPaused = state.runScheduler.isPaused(schedule)
        let isRunning = state.runScheduler.isRunning(schedule)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RunScheduleStatusDot(tone: tone(scheduleState, isRunning: isRunning), isActive: isRunning)
                Text(schedule.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.color(schedule.isEnabled ? "fg" : "fg-dim"))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    state.runScheduler.runNow(id: schedule.id)
                } label: {
                    HStack(spacing: 4) {
                        Icon(name: "play", size: 10, color: theme.color(isRunning ? "fg-faint" : "accent"))
                        Text(isRunning ? "Running" : "Run Now")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(theme.color(isRunning ? "fg-faint" : "accent"))
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .background(isRunning ? .clear : theme.color("accent-soft"), in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.toolbarControl)
                .disabled(isRunning)
                .help("Run \(schedule.name) now")
                .accessibilityLabel("Run \(schedule.name) now")
                actionMenu
            }

            Text(RunSchedulePresentation.triggerLabel(schedule.trigger))
                .font(.system(size: 10.5))
                .foregroundColor(theme.color("fg-muted"))
                .padding(.leading, 13)
            Text(actionLabel)
                .font(.system(size: 10.5))
                .foregroundColor(theme.color("fg-faint"))
                .lineLimit(2)
                .padding(.leading, 13)
            HStack(spacing: 4) {
                Icon(name: "terminal", size: 9, color: theme.color("fg-faint"))
                Text("\(targetLabel) · \(hostLabel)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, 13)
            Text(lastOutcomeLabel(scheduleState))
                .font(.system(size: 10.5))
                .foregroundColor(outcomeColor(scheduleState.lastOutcome))
                .lineLimit(2)
                .padding(.leading, 13)
            Text("Next: " + RunSchedulePresentation.nextFireLabel(
                scheduleState.nextFireAt,
                now: now,
                isEnabled: schedule.isEnabled,
                isPaused: isPaused
            ))
            .font(.system(size: 10.5))
            .foregroundColor(theme.color("fg-faint"))
            .padding(.leading, 13)
            if let missed = scheduleState.lastMissed {
                HStack(spacing: 4) {
                    Icon(name: "exclamationmark.triangle", size: 9, color: theme.color("warn"))
                    Text(RunSchedulePresentation.missedLabel(missed))
                        .font(.system(size: 10))
                        .foregroundColor(theme.color("warn"))
                        .lineLimit(2)
                }
                .padding(.leading, 13)
            }
        }
        .padding(10)
        .rightPaneCardChrome(accent: accentColor(scheduleState, isRunning: isRunning), isHovering: hovering)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("schedule-card-\(schedule.id)")
        .confirmationDialog(
            "Delete \(schedule.name)?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Schedule", role: .destructive) {
                state.runScheduler.remove(id: schedule.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scripts and worktrees are not touched. Only the schedule is removed.")
        }
    }

    private var actionMenu: some View {
        Menu {
            Toggle("Enabled", isOn: Binding(
                get: { schedule.isEnabled },
                set: { state.runScheduler.setEnabled($0, id: schedule.id) }
            ))
            Button("Edit…", action: onEdit)
            Divider()
            Button("Delete…", role: .destructive) { isConfirmingDelete = true }
        } label: {
            Icon(name: "ellipsis", size: 12, color: theme.color("fg-muted"))
                .toolbarControlSurface(isLit: menuHovered)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { menuHovered = $0 }
        .help("More actions for \(schedule.name)")
        .accessibilityLabel("More actions for \(schedule.name)")
    }

    private var actionLabel: String {
        let agentName = schedule.composition?.agentId.flatMap { id in
            state.agentRegistry.agents.first { $0.id == id }?.displayName
        }
        return RunSchedulePresentation.actionLabel(
            scriptName: schedule.scriptKey.map(RunSchedulePresentation.scriptDisplayName),
            composition: schedule.composition,
            agentName: agentName
        )
    }

    private var targetLabel: String {
        RunSchedulePresentation.targetLabel(
            schedule.target,
            projectName: { id in state.projects.first { $0.id == id }?.name },
            worktreeBranch: { id in
                guard let projectID = schedule.target.projectID else { return nil }
                return state.projectsManager.worktrees(projectId: projectID).first { $0.id == id }?.branch
            }
        )
    }

    private var hostLabel: String {
        switch schedule.target {
        case .allProjects:
            let hosts = Set(state.projects.map { RunSchedulePresentation.hostLabel($0.host) })
            return hosts.sorted().joined(separator: ", ")
        default:
            let host = schedule.target.projectID.flatMap { id in state.projects.first { $0.id == id }?.host }
            return RunSchedulePresentation.hostLabel(host)
        }
    }

    private func lastOutcomeLabel(_ scheduleState: RunScheduleState) -> String {
        guard let outcome = scheduleState.lastOutcome, let at = scheduleState.lastOutcomeAt else {
            return "Never run"
        }
        return "\(RunSchedulePresentation.outcomeLabel(outcome)) · \(relativeTime(at)) ago"
    }

    private func tone(_ scheduleState: RunScheduleState, isRunning: Bool) -> RunStatusTone {
        if isRunning { return .active }
        guard schedule.isEnabled else { return .idle }
        switch scheduleState.lastOutcome {
        case .none, .skipped: return .idle
        case .succeeded: return .success
        case .failed, .launchFailed: return .failure
        case .stopped, .unknown: return .warning
        }
    }

    private func accentColor(_ scheduleState: RunScheduleState, isRunning: Bool) -> Color {
        switch tone(scheduleState, isRunning: isRunning) {
        case .idle:    theme.color("fg-faint")
        case .active:  theme.color("accent")
        case .success: theme.color("add")
        case .failure: theme.color("del")
        case .warning: theme.color("warn")
        }
    }

    private func outcomeColor(_ outcome: RunScheduleOutcome?) -> Color {
        switch outcome {
        case .none, .skipped: theme.color("fg-faint")
        case .succeeded: theme.color("add")
        case .failed, .launchFailed: theme.color("del")
        case .stopped, .unknown: theme.color("warn")
        }
    }
}

private struct RunScheduleStatusDot: View {
    let tone: RunStatusTone
    let isActive: Bool

    @Environment(\.theme) private var theme
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(isActive && pulsing ? 0.35 : 1)
            .animation(
                isActive ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                value: pulsing
            )
            .onAppear { pulsing = isActive }
            .onChange(of: isActive) { _, active in pulsing = active }
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch tone {
        case .idle:    theme.color("fg-faint")
        case .active:  theme.color("accent")
        case .success: theme.color("add")
        case .failure: theme.color("del")
        case .warning: theme.color("warn")
        }
    }
}
