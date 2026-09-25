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
    @State private var presentation: Presentation?
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

    enum Presentation: Identifiable {
        case edit(EditTarget)
        case reports(projectID: String)
        case report(projectID: String, reportID: String)

        var id: String {
            switch self {
            case .edit(let target): "edit:\(target.id)"
            case .reports(let projectID): "reports:\(projectID)"
            case .report(_, let reportID): "report:\(reportID)"
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
                            onEdit: { presentation = .edit(.existing(schedule.id)) },
                            onOpenReport: { openScheduledReport($0) }
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
        .task(id: historyPrimingToken) {
            await state.primeScheduleRunReportIDs(historyWorktreeIDs)
        }
        .task(id: "\(worktree.projectId)|\(state.scheduledAgentReportRoute?.reportID ?? "")") {
            guard let route = state.scheduledAgentReportRoute,
                  route.projectID == worktree.projectId
            else {
                return
            }
            presentation = .report(projectID: route.projectID, reportID: route.reportID)
            state.scheduledAgentReportRoute = nil
        }
        .sheet(item: $presentation) { target in
            switch target {
            case .edit(.new):
                RunScheduleEditorView(state: state, originWorktree: worktree, schedule: nil) { presentation = nil }
                    .modifier(RepoHookApprovalPresentationHandler(approvalQueue: state.repoHookApprovalQueue))
            case .edit(.existing(let id)):
                RunScheduleEditorView(
                    state: state,
                    originWorktree: worktree,
                    schedule: state.runScheduler.schedule(id: id)
                ) { presentation = nil }
                    .modifier(RepoHookApprovalPresentationHandler(approvalQueue: state.repoHookApprovalQueue))
            case .reports(let projectID):
                ScheduledAgentReportsSheet(state: state, projectID: projectID)
            case .report(let projectID, let reportID):
                ScheduledAgentReportsSheet(state: state, projectID: projectID, initialReportID: reportID)
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

    /// What the priming task keys on: the referenced worktrees *and* whether
    /// each is currently visible.
    ///
    /// The ids alone are not enough. Archiving a worktree clears its cached
    /// report ids, and unarchiving restores the worktree without changing
    /// which worktrees the histories reference — so keying on ids alone would
    /// leave the task unfired and the restored links dead until this pane was
    /// remounted.
    private var historyPrimingToken: [String] {
        historyWorktreeIDs.map { id in
            "\(id):\(state.visibleProjectForWorktree(id) != nil ? 1 : 0)"
        }
    }

    /// Worktrees the visible histories link runs in, deduplicated and stable.
    private var historyWorktreeIDs: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for schedule in schedules {
            for firing in state.runScheduler.firings(for: schedule.id) {
                for run in firing.runs where !seen.contains(run.worktreeID) {
                    seen.insert(run.worktreeID)
                    ordered.append(run.worktreeID)
                }
            }
        }
        return ordered
    }

    private func openScheduledReport(_ reportID: String) {
        Task { @MainActor in
            let reportProjectID: String
            do {
                reportProjectID = try await state.scheduledAgentReport(id: reportID)?.projectID ?? worktree.projectId
            } catch {
                reportProjectID = worktree.projectId
            }
            presentation = .report(projectID: reportProjectID, reportID: reportID)
        }
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
            Button {
                presentation = .reports(projectID: worktree.projectId)
            } label: {
                Icon(name: "doc.text", size: 12, color: theme.color("fg-muted"))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Scheduled reports")
            .accessibilityLabel("Scheduled reports")
            .accessibilityIdentifier("scheduled-agent-reports")
            Button { presentation = .edit(.new) } label: {
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
            Button("New Schedule") { presentation = .edit(.new) }
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
    let onOpenReport: (String) -> Void

    @Environment(\.theme) private var theme
    @State private var reportSummaries: [String: ScheduledAgentReport] = [:]
    /// Whether a `loadReportSummaries()` pass has completed: without it, a
    /// nil `reportSummaries[id]` means "still fetching", not "deleted".
    @State private var hasLoadedReportSummaries = false
    @State private var hovering = false
    @State private var menuHovered = false
    @State private var isConfirmingDelete = false
    @State private var isShowingHistory = false

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
            if !scheduleState.firings.isEmpty {
                history(scheduleState.firings)
            }
        }
        .padding(10)
        .rightPaneCardChrome(accent: accentColor(scheduleState, isRunning: isRunning), isHovering: hovering)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .onHover { hovering = $0 }
        .task(id: reportHistoryToken) {
            await loadReportSummaries()
        }
        .task(id: isShowingHistory ? schedule.id : "") {
            // Deletions by another Alas process never touch the firing IDs
            // or this process's deletion generation, so poll while the
            // history is open: the shared store is the only cross-instance
            // signal for a report that vanished.
            guard isShowingHistory else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, isShowingHistory else { return }
                await refreshReportSummaries()
            }
        }
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

    /// Past firings, collapsed by default. The card's job is the next run; the
    /// history is for the question you only ask after something looked wrong.
    private func history(_ firings: [RunScheduleFiring]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isShowingHistory.toggle()
            } label: {
                HStack(spacing: 4) {
                    Icon(
                        name: isShowingHistory ? "chev-down" : "chev-right",
                        size: 8,
                        color: theme.color("fg-faint")
                    )
                    Text(RunSchedulePresentation.historyLabel(firings))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(theme.color("fg-muted"))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Past firings of \(schedule.name)")
            .accessibilityLabel("\(isShowingHistory ? "Hide" : "Show") history for \(schedule.name)")
            .accessibilityIdentifier("schedule-history-toggle-\(schedule.id)")
            if isShowingHistory {
                ForEach(firings) { firing in
                    firingRow(firing)
                }
            }
        }
        .padding(.top, 2)
        .padding(.leading, 13)
    }

    private func firingRow(_ firing: RunScheduleFiring) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(RunSchedulePresentation.outcomeLabel(firing.outcome))
                .font(.system(size: 10))
                .foregroundColor(outcomeColor(firing.outcome))
                .lineLimit(2)
            Text(RunSchedulePresentation.firingTimeLabel(firing))
                .font(.system(size: 9.5))
                .foregroundColor(theme.color("fg-faint"))
            ForEach(firing.runs, id: \.runID) { run in
                runLink(run)
            }
            ForEach(firing.reportIDs, id: \.self) { reportID in
                scheduledReportLink(reportID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("schedule-firing-\(firing.id)")
    }

    /// A report link becomes inert once its report is known to be gone:
    /// `reportSummaries` only holds loaded reports, so a missing entry after
    /// loading means the report was deleted (or purged) — the history still
    /// names it, but it is no longer something to open.
    @ViewBuilder
    private func scheduledReportLink(_ reportID: String) -> some View {
        let isMissing = hasLoadedReportSummaries && reportSummaries[reportID] == nil
        let label = reportSummaries[reportID]
            .map(RunSchedulePresentation.scheduledAgentReportHistoryLabel)
            ?? (isMissing ? "Deleted scheduled report" : "Scheduled agent report")
        if isMissing {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundColor(theme.color("fg-faint"))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(label)
                .accessibilityIdentifier("schedule-firing-report-\(reportID)")
        } else {
            Button {
                onOpenReport(reportID)
            } label: {
                HStack(spacing: 3) {
                    Icon(name: "doc.text", size: 8, color: theme.color("accent"))
                    Text(label)
                        .font(.system(size: 9.5))
                        .foregroundColor(theme.color("accent"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the scheduled agent report")
            .accessibilityLabel(label)
            .accessibilityIdentifier("schedule-firing-report-\(reportID)")
        }
    }

    /// A run whose report has been purged, or whose worktree has since been
    /// archived, is still named but is not offered as something to open: the
    /// history outlives both the transcript and the worktree.
    @ViewBuilder
    private func runLink(_ run: RunScheduleFiring.RunReference) -> some View {
        let label = RunSchedulePresentation.firingRunLabel(run)
        if state.canOpenScheduleFiringRun(run) {
            Button {
                state.openScheduleFiringRun(run)
            } label: {
                HStack(spacing: 3) {
                    Icon(name: "doc.text", size: 8, color: theme.color("accent"))
                    Text(label)
                        .font(.system(size: 9.5))
                        .foregroundColor(theme.color("accent"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the run report for \(label)")
            .accessibilityLabel("Open the run report for \(label)")
            .accessibilityIdentifier("schedule-firing-run-\(run.runID)")
        } else {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundColor(theme.color("fg-faint"))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var reportHistoryToken: String {
        guard isShowingHistory else { return "" }
        let reportIDs = Array(Set(state.runScheduler.firings(for: schedule.id).flatMap(\.reportIDs)))
            .sorted()
            .joined(separator: "|")
        // A deletion keeps the firing history's IDs identical, so the token
        // needs the deletion generation to re-run `loadReportSummaries` and
        // flip the affected links to their unavailable rendering.
        return "\(reportIDs)|gen=\(state.scheduledAgentReportDeletionGeneration)"
    }

    private func loadReportSummaries() async {
        guard isShowingHistory else {
            reportSummaries = [:]
            hasLoadedReportSummaries = false
            return
        }
        let ids = Array(Set(state.runScheduler.firings(for: schedule.id).flatMap(\.reportIDs))).sorted()
        // A thrown lookup (e.g. the SQLite write lock held by another
        // process) is not proof the report is gone. `.task(id:)` re-runs
        // only when the token changes, so retry here with a short backoff
        // instead of leaving stale or generic links displayed indefinitely.
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(1))
            }
            var loaded: [String: ScheduledAgentReport] = [:]
            var sawReadError = false
            for id in ids {
                guard !Task.isCancelled else { return }
                do {
                    if let report = try await state.scheduledAgentReport(id: id) {
                        loaded[id] = report
                    }
                } catch {
                    sawReadError = true
                }
            }
            guard !Task.isCancelled else { return }
            if sawReadError { continue }
            reportSummaries = loaded
            hasLoadedReportSummaries = true
            return
        }
    }

    /// Lighter pass for the cross-instance poll: only downgrades a link when
    /// the shared store confirms the row is gone (a successful nil lookup),
    /// never on read errors — those leave the current rendering in place.
    private func refreshReportSummaries() async {
        guard isShowingHistory, hasLoadedReportSummaries else { return }
        let ids = Array(Set(state.runScheduler.firings(for: schedule.id).flatMap(\.reportIDs))).sorted()
        var summaries = reportSummaries
        var changed = false
        for id in ids {
            guard !Task.isCancelled else { return }
            do {
                if let report = try await state.scheduledAgentReport(id: id) {
                    if summaries[id]?.id != report.id {
                        summaries[id] = report
                        changed = true
                    }
                } else if summaries[id] != nil {
                    summaries[id] = nil
                    changed = true
                }
            } catch {
                continue
            }
        }
        guard !Task.isCancelled, changed else { return }
        reportSummaries = summaries
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
