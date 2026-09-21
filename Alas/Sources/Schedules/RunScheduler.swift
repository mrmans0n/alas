import AppKit
import Foundation
import os

private let schedulerLogger = Logger(subsystem: "io.nlopez.alas", category: "RunScheduler")

/// Owns the schedule list, its persisted state, and the clock that evaluates
/// it. It decides *when*; the injected `runner` (AppState) decides *how*, by
/// reusing the manual run-script and worktree-creation paths.
///
/// Nothing here runs while the app is quit. Evaluations happen on a timer
/// while the process is alive, immediately after the machine wakes, and once
/// at startup, where the distance from the last persisted evaluation is
/// reported as a gap instead of replayed.
@MainActor
@Observable
final class RunScheduler {
    typealias Runner = @MainActor (RunSchedule, RunScheduleInvocation) async -> RunScheduleOutcome

    private(set) var schedules: [RunSchedule] = []
    private(set) var states: [String: RunScheduleState] = [:]
    private(set) var pausedProjectIDs: Set<String> = []
    private(set) var isPausedGlobally = false
    /// The most recent stretch during which schedules could not be evaluated.
    private(set) var lastGap: RunScheduleGap?
    private(set) var runningScheduleIDs: Set<String> = []
    /// Bumped on every evaluation so views re-derive "next fire in …" labels.
    private(set) var evaluationGeneration = 0

    @ObservationIgnored var runner: Runner?
    @ObservationIgnored var persistenceErrorHandler: ((String) -> Void)?

    @ObservationIgnored private let store: any PersistenceStoreProtocol
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let tickInterval: TimeInterval
    @ObservationIgnored private let grace: TimeInterval
    @ObservationIgnored private let sleepThreshold: TimeInterval
    @ObservationIgnored private let evaluationPersistInterval: TimeInterval
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var runTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastEvaluatedAt: Date?
    @ObservationIgnored private var lastPersistedEvaluationAt: Date?
    @ObservationIgnored private var hasEvaluatedInThisProcess = false

    init(
        store: any PersistenceStoreProtocol = PersistenceStore(),
        fileURL: URL = Paths.runSchedulesFile,
        now: @escaping () -> Date = { Date() },
        // Autoupdating on purpose: a time-of-day trigger is a local
        // wall-clock time, so travelling or changing the system time zone has
        // to move it without relaunching Alas.
        calendar: Calendar = .autoupdatingCurrent,
        tickInterval: TimeInterval = 30,
        grace: TimeInterval = RunSchedulePlanner.defaultGrace,
        evaluationPersistInterval: TimeInterval = 5 * 60
    ) {
        self.store = store
        self.fileURL = fileURL
        self.now = now
        self.calendar = calendar
        self.tickInterval = tickInterval
        self.grace = grace
        self.sleepThreshold = tickInterval * 2 + 30
        self.evaluationPersistInterval = evaluationPersistInterval
        load()
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        evaluate()
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluate()
            }
        }
        timer.tolerance = tickInterval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluate()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if lastEvaluatedAt != nil {
            persist()
        }
    }

    var isRunning: Bool { timer != nil }

    // MARK: - Queries

    func state(for id: String) -> RunScheduleState {
        states[id] ?? RunScheduleState()
    }

    func schedule(id: String) -> RunSchedule? {
        schedules.first { $0.id == id }
    }

    /// Whether a schedule is paused *as a whole*. An `.allProjects` schedule
    /// names no single project, so a per-project pause cannot silence it
    /// here; it is applied per target when the run fans out.
    func isPaused(_ schedule: RunSchedule) -> Bool {
        if isPausedGlobally { return true }
        guard let projectID = schedule.target.projectID else { return false }
        return pausedProjectIDs.contains(projectID)
    }

    func isProjectPaused(_ projectID: String) -> Bool {
        pausedProjectIDs.contains(projectID)
    }

    func isRunning(_ schedule: RunSchedule) -> Bool {
        runningScheduleIDs.contains(schedule.id)
    }

    /// Projects that have at least one schedule aimed at them. Pause toggles
    /// are offered for these only; pausing a project without schedules would
    /// be a no-op nobody could see.
    var projectIDsWithSchedules: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for schedule in schedules {
            guard let id = schedule.target.projectID, !seen.contains(id) else { continue }
            seen.insert(id)
            ordered.append(id)
        }
        return ordered
    }

    // MARK: - Mutations

    func add(_ schedule: RunSchedule) {
        guard schedule.hasAction, schedules.contains(where: { $0.id == schedule.id }) == false else { return }
        schedules.append(schedule)
        var state = RunScheduleState()
        state.nextFireAt = RunSchedulePlanner.nextFireDate(
            for: schedule.trigger,
            after: now(),
            anchor: schedule.createdAt,
            calendar: calendar
        )
        states[schedule.id] = state
        persist()
    }

    func update(_ schedule: RunSchedule) {
        guard schedule.hasAction, let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        let previous = schedules[index]
        schedules[index] = schedule
        var state = self.state(for: schedule.id)
        // Editing the trigger means the old "next" no longer describes this
        // schedule. Re-enabling starts fresh too: nothing that was due while
        // disabled counts as missed.
        if previous.trigger != schedule.trigger || (!previous.isEnabled && schedule.isEnabled) {
            let current = now()
            state.nextFireAt = RunSchedulePlanner.nextFireDate(
                for: schedule.trigger,
                after: current,
                anchor: state.lastFiredAt ?? current,
                calendar: calendar
            )
        }
        states[schedule.id] = state
        persist()
    }

    func remove(id: String) {
        schedules.removeAll { $0.id == id }
        states[id] = nil
        runTasks.removeValue(forKey: id)?.cancel()
        runningScheduleIDs.remove(id)
        persist()
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard var schedule = schedule(id: id), schedule.isEnabled != enabled else { return }
        schedule.isEnabled = enabled
        update(schedule)
    }

    func setProjectPaused(_ paused: Bool, projectID: String) {
        if paused {
            pausedProjectIDs.insert(projectID)
        } else {
            pausedProjectIDs.remove(projectID)
        }
        persist()
    }

    func setPausedGlobally(_ paused: Bool) {
        guard isPausedGlobally != paused else { return }
        isPausedGlobally = paused
        persist()
    }

    /// Removes schedules whose target project no longer exists. Called when
    /// a project is removed so the list does not accumulate dead rows.
    func pruneSchedules(missingProjectIDs: Set<String>) {
        let before = schedules.count
        schedules.removeAll { schedule in
            guard let projectID = schedule.target.projectID else { return false }
            return missingProjectIDs.contains(projectID)
        }
        for id in Set(states.keys).subtracting(schedules.map(\.id)) {
            states[id] = nil
        }
        pausedProjectIDs.subtract(missingProjectIDs)
        if schedules.count != before {
            persist()
        }
    }

    /// Fires a schedule immediately, ignoring its trigger and any pause. It
    /// still refuses to stack on a run that is already in progress.
    func runNow(id: String) {
        guard let schedule = schedule(id: id) else { return }
        dispatch(schedule, at: now(), invocation: .manual)
    }

    // MARK: - Evaluation

    /// One pass over every schedule. Safe to call at any time; it is what the
    /// timer, the wake notification, startup and tests all use.
    func evaluate(now overrideNow: Date? = nil) {
        let current = overrideNow ?? now()
        noteGap(at: current)
        var changed = false
        for schedule in schedules {
            let state = self.state(for: schedule.id)
            let decision = RunSchedulePlanner.decide(
                schedule: schedule,
                state: state,
                now: current,
                grace: grace,
                calendar: calendar
            )
            guard schedule.isEnabled, !isPaused(schedule) else {
                // Keep "next" honest for rows that cannot fire, without
                // recording anything as missed: the user opted out.
                if case .wait = decision { continue }
                var advanced = state
                advanced.nextFireAt = RunSchedulePlanner.nextFireDate(
                    for: schedule.trigger,
                    after: current,
                    anchor: state.lastFiredAt ?? schedule.createdAt,
                    calendar: calendar
                )
                states[schedule.id] = advanced
                changed = true
                continue
            }
            switch decision {
            case .wait(let next):
                if state.nextFireAt != next {
                    var updated = state
                    updated.nextFireAt = next
                    states[schedule.id] = updated
                    changed = true
                }
            case let .skip(next, missed):
                var updated = state
                updated.nextFireAt = next
                updated.lastMissed = RunScheduleMissedOccurrences(count: missed, policy: .skip, observedAt: current)
                states[schedule.id] = updated
                changed = true
                schedulerLogger.info(
                    "Skipped \(missed, privacy: .public) missed occurrence(s) of schedule \(schedule.id, privacy: .public)"
                )
            case let .fire(next, missed):
                var updated = state
                updated.nextFireAt = next
                updated.lastFiredAt = current
                if missed > 0 {
                    updated.lastMissed = RunScheduleMissedOccurrences(count: missed, policy: .runLatest, observedAt: current)
                }
                states[schedule.id] = updated
                changed = true
                dispatch(schedule, at: current, invocation: .scheduled)
            }
        }
        evaluationGeneration += 1
        lastEvaluatedAt = current
        hasEvaluatedInThisProcess = true
        if changed {
            persist()
        } else if let lastPersistedEvaluationAt,
                  current.timeIntervalSince(lastPersistedEvaluationAt) >= evaluationPersistInterval {
            persist()
        } else if lastPersistedEvaluationAt == nil {
            persist()
        }
    }

    /// Waits for in-flight runs. Test-only: production callers never block
    /// on a scheduled run.
    func waitForRunsForTesting() async {
        for task in runTasks.values {
            await task.value
        }
    }

    // MARK: - Private

    private func noteGap(at current: Date) {
        guard let previous = lastEvaluatedAt else { return }
        let elapsed = current.timeIntervalSince(previous)
        guard elapsed > sleepThreshold else { return }
        lastGap = RunScheduleGap(
            start: previous,
            end: current,
            reason: hasEvaluatedInThisProcess ? .asleep : .appNotRunning
        )
        schedulerLogger.info(
            "Schedules were not evaluated for \(Int(elapsed), privacy: .public)s (\(self.lastGap?.reason.rawValue ?? "", privacy: .public))"
        )
    }

    private func dispatch(_ schedule: RunSchedule, at current: Date, invocation: RunScheduleInvocation) {
        guard runTasks[schedule.id] == nil else {
            var state = self.state(for: schedule.id)
            state.lastOutcome = .skipped(reason: "The previous run is still in progress.")
            state.lastOutcomeAt = current
            states[schedule.id] = state
            persist()
            return
        }
        guard let runner else {
            schedulerLogger.error("No runner installed; schedule \(schedule.id, privacy: .public) cannot fire")
            return
        }
        runningScheduleIDs.insert(schedule.id)
        runTasks[schedule.id] = Task { @MainActor [weak self] in
            let outcome = await runner(schedule, invocation)
            guard let self else { return }
            var state = self.state(for: schedule.id)
            state.lastOutcome = outcome
            state.lastOutcomeAt = self.now()
            if self.schedules.contains(where: { $0.id == schedule.id }) {
                self.states[schedule.id] = state
            }
            self.runTasks[schedule.id] = nil
            self.runningScheduleIDs.remove(schedule.id)
            self.persist()
        }
    }

    private func load() {
        do {
            guard let file = try store.readIfExists(RunSchedulesFile.self, from: fileURL) else { return }
            schedules = file.schedules.filter(\.hasAction)
            states = file.states.filter { entry in schedules.contains { $0.id == entry.key } }
            pausedProjectIDs = file.pausedProjectIDs
            isPausedGlobally = file.isPausedGlobally
            lastEvaluatedAt = file.lastEvaluatedAt
        } catch {
            schedulerLogger.error("Could not read schedules: \(String(describing: error), privacy: .public)")
            persistenceErrorHandler?("Could not read schedules: \(error.localizedDescription)")
        }
    }

    private func persist() {
        var file = RunSchedulesFile()
        file.schedules = schedules
        file.states = states
        file.pausedProjectIDs = pausedProjectIDs
        file.isPausedGlobally = isPausedGlobally
        file.lastEvaluatedAt = lastEvaluatedAt
        do {
            try store.write(file, to: fileURL)
            lastPersistedEvaluationAt = lastEvaluatedAt
        } catch {
            schedulerLogger.error("Could not save schedules: \(String(describing: error), privacy: .public)")
            persistenceErrorHandler?("Could not save schedules: \(error.localizedDescription)")
        }
    }
}
