import Foundation

/// The editor's working copy of a schedule. Pure so validation and the
/// draft → schedule mapping can be tested without the sheet.
struct RunScheduleDraft: Equatable {
    enum TargetKind: String, CaseIterable, Equatable {
        case thisWorktree
        case mainWorktree
        case allProjects
    }

    enum TriggerKind: String, CaseIterable, Equatable {
        case interval
        case timeOfDay
    }

    enum IntervalUnit: String, CaseIterable, Equatable {
        case minutes, hours, days

        var seconds: TimeInterval {
            switch self {
            case .minutes: 60
            case .hours: 3_600
            case .days: 86_400
            }
        }

        var label: String { rawValue.capitalized }
    }

    /// The quick picks above the weekday row. A preset is a named weekday
    /// set; the row stays editable afterwards, at which point no preset is
    /// selected any more.
    enum WeekdayPreset: String, CaseIterable, Equatable {
        case everyDay, weekdays, weekends

        var weekdays: Set<Int> {
            switch self {
            case .everyDay: Set(1...7)
            case .weekdays: Set(2...6)
            case .weekends: [1, 7]
            }
        }

        var label: String {
            switch self {
            case .everyDay: "Every day"
            case .weekdays: "Weekdays"
            case .weekends: "Weekends"
            }
        }

        static func matching(_ weekdays: Set<Int>) -> WeekdayPreset? {
            allCases.first { $0.weekdays == weekdays }
        }
    }

    var name = ""
    var projectID: String?
    var worktreeID: String?
    var targetKind: TargetKind = .thisWorktree
    var scriptKey: String?
    var triggerKind: TriggerKind = .timeOfDay
    var intervalValue = 30
    var intervalUnit: IntervalUnit = .minutes
    var hour = 9
    var minute = 0
    var weekdays: Set<Int> = Set(1...7)
    var missedRunPolicy: RunScheduleMissedRunPolicy = .skip
    var createsWorktree = false
    var branchTemplate = RunScheduleComposition.defaultBranchTemplate
    var agentID: String?
    var modelID: String?
    var prompt = ""
    var sendsPromptAutomatically = true
    var afterExecution: RunScheduleAfterExecution = .keep

    init() {}

    /// Starts a draft for a new schedule aimed at `worktree`.
    init(projectID: String, worktreeID: String, isMainWorktree: Bool) {
        self.projectID = projectID
        self.worktreeID = worktreeID
        self.targetKind = isMainWorktree ? .mainWorktree : .thisWorktree
    }

    init(schedule: RunSchedule) {
        name = schedule.name
        switch schedule.target {
        case .allProjects:
            targetKind = .allProjects
        case .project(let id):
            targetKind = .mainWorktree
            projectID = id
        case let .worktree(projectId, worktreeId):
            targetKind = .thisWorktree
            projectID = projectId
            worktreeID = worktreeId
        }
        scriptKey = schedule.scriptKey
        switch schedule.trigger {
        case .interval(let seconds):
            triggerKind = .interval
            let (value, unit) = Self.intervalComponents(seconds)
            intervalValue = value
            intervalUnit = unit
        case let .timeOfDay(hour, minute, weekdays):
            triggerKind = .timeOfDay
            self.hour = hour
            self.minute = minute
            self.weekdays = weekdays.isEmpty ? Set(1...7) : weekdays
        }
        missedRunPolicy = schedule.missedRunPolicy
        if let composition = schedule.composition {
            createsWorktree = true
            branchTemplate = composition.branchTemplate
            agentID = composition.agentId
            modelID = composition.modelId
            prompt = composition.prompt ?? ""
            sendsPromptAutomatically = composition.sendsPromptAutomatically
            afterExecution = composition.afterExecution
        }
    }

    /// The preset the weekday row currently matches, if any.
    var weekdayPreset: WeekdayPreset? { WeekdayPreset.matching(weekdays) }

    mutating func apply(_ preset: WeekdayPreset) {
        weekdays = preset.weekdays
    }

    mutating func toggleWeekday(_ day: Int) {
        if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) }
    }

    /// When the schedule would first fire if it were saved right now.
    ///
    /// `anchor` has to match what the scheduler will use, or the preview
    /// contradicts the save. `RunScheduler.add` anchors a new schedule on
    /// its creation, which is now; `RunScheduler.update` anchors an edited
    /// trigger on the last fire. Interval occurrences sit on a grid from
    /// that anchor, so an hourly schedule last run 30 minutes ago is next
    /// due in 30 minutes, not in an hour. Time-of-day triggers ignore it.
    ///
    /// Nil while the trigger is not valid.
    func nextFireDate(now: Date, anchor: Date? = nil, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        switch triggerKind {
        case .interval:
            guard intervalValue >= 1 else { return nil }
        case .timeOfDay:
            guard (0...23).contains(hour), (0...59).contains(minute), !weekdays.isEmpty else { return nil }
        }
        return RunSchedulePlanner.nextFireDate(for: trigger, after: now, anchor: anchor ?? now, calendar: calendar)
    }

    static func intervalComponents(_ seconds: TimeInterval) -> (Int, IntervalUnit) {
        let total = Int(seconds.rounded())
        if total % 86_400 == 0 { return (total / 86_400, .days) }
        if total % 3_600 == 0 { return (total / 3_600, .hours) }
        return (max(1, total / 60), .minutes)
    }

    var trigger: RunScheduleTrigger {
        switch triggerKind {
        case .interval:
            return .interval(seconds: Double(max(1, intervalValue)) * intervalUnit.seconds)
        case .timeOfDay:
            let storedWeekdays: Set<Int> = weekdays.count == 7 ? [] : weekdays
            return .timeOfDay(hour: hour, minute: minute, weekdays: storedWeekdays)
        }
    }

    var target: RunScheduleTarget? {
        switch targetKind {
        case .allProjects:
            return .allProjects
        case .mainWorktree:
            guard let projectID else { return nil }
            return .project(id: projectID)
        case .thisWorktree:
            guard let projectID, let worktreeID else { return nil }
            return .worktree(projectId: projectID, worktreeId: worktreeID)
        }
    }

    var composition: RunScheduleComposition? {
        guard createsWorktree else { return nil }
        let template = branchTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return RunScheduleComposition(
            branchTemplate: template.isEmpty ? RunScheduleComposition.defaultBranchTemplate : template,
            agentId: agentID,
            // A model belongs to one agent; "Project default" is resolved at
            // fire time, so a model picked for an earlier explicit choice
            // would be sent to whichever agent that turns out to be.
            modelId: agentID == nil ? nil : modelID,
            prompt: trimmedPrompt.isEmpty ? nil : trimmedPrompt,
            sendsPromptAutomatically: sendsPromptAutomatically,
            afterExecution: afterExecution
        )
    }

    /// The first reason the draft cannot be saved, or nil when it can.
    var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the schedule a name." }
        if target == nil { return "Pick a project and worktree." }
        if scriptKey == nil, !createsWorktree { return "Pick a script, or create a worktree with an agent." }
        switch triggerKind {
        case .interval:
            if intervalValue < 1 { return "Interval must be at least 1." }
            if Double(intervalValue) * intervalUnit.seconds < RunScheduleTrigger.minimumIntervalSeconds {
                return "Interval must be at least one minute."
            }
        case .timeOfDay:
            if !(0...23).contains(hour) || !(0...59).contains(minute) { return "Enter a valid time." }
            if weekdays.isEmpty { return "Pick at least one weekday." }
        }
        if createsWorktree && afterExecution == .reportAndCleanupOnSuccess {
            guard let agentID else { return "Choose an ACP-capable agent for automatic cleanup." }
            guard let spec = ACPLaunchCatalog.spec(for: agentID) else {
                return "Automatic cleanup requires an ACP-capable agent."
            }
            guard case .sessionNew = spec.mcpInjection else {
                return "Automatic cleanup requires an agent that accepts the built-in ACP completion tool."
            }
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Automatic cleanup requires a prompt."
            }
            guard sendsPromptAutomatically else { return "Automatic cleanup requires automatic prompt submission." }
        }
        return nil
    }

    var isValid: Bool { validationError == nil }

    func makeSchedule(id: String = UUID().uuidString, existing: RunSchedule? = nil, now: Date = Date()) -> RunSchedule? {
        guard isValid, let target else { return nil }
        return RunSchedule(
            id: existing?.id ?? id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            target: target,
            scriptKey: scriptKey,
            trigger: trigger,
            missedRunPolicy: missedRunPolicy,
            composition: composition,
            isEnabled: existing?.isEnabled ?? true,
            createdAt: existing?.createdAt ?? now
        )
    }
}
