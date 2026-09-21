import Foundation

/// Pure label formatting for schedule rows. Kept out of the views so the
/// wording is testable and consistent between the list and the editor.
enum RunSchedulePresentation {
    static let notRunningNotice = "Schedules only fire while Alas is running. Nothing runs while the app is quit."

    static func triggerLabel(_ trigger: RunScheduleTrigger, calendar: Calendar = .autoupdatingCurrent) -> String {
        switch trigger {
        case .interval(let seconds):
            return "Every \(intervalLabel(seconds))"
        case let .timeOfDay(hour, minute, weekdays):
            let time = String(format: "%02d:%02d", hour, minute)
            let allowed = weekdays.isEmpty ? Set(1...7) : weekdays
            if allowed.count == 7 { return "Daily at \(time)" }
            if allowed == Set(2...6) { return "Weekdays at \(time)" }
            if allowed == [1, 7] { return "Weekends at \(time)" }
            let symbols = calendar.shortWeekdaySymbols
            let names = allowed.sorted().compactMap { day -> String? in
                guard (1...7).contains(day) else { return nil }
                return symbols[day - 1]
            }
            return "\(names.joined(separator: ", ")) at \(time)"
        }
    }

    static func intervalLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total % 86_400 == 0 { return plural(total / 86_400, "day") }
        if total % 3_600 == 0 { return plural(total / 3_600, "hour") }
        if total % 60 == 0 { return plural(total / 60, "minute") }
        return plural(total, "second")
    }

    static func outcomeLabel(_ outcome: RunScheduleOutcome) -> String {
        switch outcome {
        case .succeeded: "Succeeded"
        case .failed(let exitCode): "Failed (exit \(exitCode))"
        case .stopped: "Stopped"
        case .unknown: "Outcome unknown"
        case .skipped(let reason): "Skipped: \(reason)"
        case .launchFailed(let message): "Launch failed: \(message)"
        }
    }

    /// Heading for the history disclosure. Carries the count so the row says
    /// how much there is to open before it is opened. A schedule with no
    /// firings shows no disclosure at all; "Never run" already says that.
    static func historyLabel(_ firings: [RunScheduleFiring]) -> String {
        "History (\(firings.count))"
    }

    /// When a firing happened, and how long it took. The outcome is rendered
    /// separately so the two can be coloured differently.
    static func firingTimeLabel(
        _ firing: RunScheduleFiring,
        formatter: DateFormatter = defaultDateFormatter
    ) -> String {
        var label = formatter.string(from: firing.firedAt)
        if let duration = durationLabel(firing.duration) {
            label += " · \(duration)"
        }
        if firing.wasManual {
            label += " · Run Now"
        }
        return label
    }

    /// Nil under a second: a skip and an instant launch failure both settle
    /// immediately, and "0.0s" would suggest something was measured.
    static func durationLabel(_ duration: TimeInterval) -> String? {
        guard duration >= 1 else { return nil }
        if duration < 60 { return String(format: "%.1fs", duration) }
        if duration < 3_600 { return plural(Int(duration / 60), "minute") }
        return plural(Int(duration / 3_600), "hour")
    }

    /// What a firing's linked run was, for the button that opens its report.
    static func firingRunLabel(_ run: RunScheduleFiring.RunReference) -> String {
        "\(run.scriptName) in \(run.branch)"
    }

    static func missedLabel(_ missed: RunScheduleMissedOccurrences) -> String {
        let count = plural(missed.count, "occurrence")
        switch missed.policy {
        case .skip: return "\(count) missed and skipped"
        case .runLatest: return "\(count) missed, ran the latest"
        }
    }

    static func gapLabel(_ gap: RunScheduleGap, formatter: DateFormatter = defaultDateFormatter) -> String {
        let span = "from \(formatter.string(from: gap.start)) to \(formatter.string(from: gap.end))"
        switch gap.reason {
        case .asleep: return "The machine was asleep \(span). Missed occurrences followed each schedule's policy."
        case .appNotRunning: return "Alas was not running \(span). Missed occurrences followed each schedule's policy."
        }
    }

    static func targetLabel(
        _ target: RunScheduleTarget,
        projectName: (String) -> String?,
        worktreeBranch: (String) -> String?
    ) -> String {
        switch target {
        case .allProjects:
            return "All projects (main worktree)"
        case .project(let id):
            return "\(projectName(id) ?? "Missing project") (main worktree)"
        case let .worktree(projectId, worktreeId):
            let project = projectName(projectId) ?? "Missing project"
            let branch = worktreeBranch(worktreeId) ?? "missing worktree"
            return "\(project) / \(branch)"
        }
    }

    static func hostLabel(_ host: String?) -> String {
        host ?? "This Mac"
    }

    static func nextFireLabel(_ next: Date?, now: Date, isEnabled: Bool, isPaused: Bool, formatter: DateFormatter = defaultDateFormatter) -> String {
        if !isEnabled { return "Disabled" }
        if isPaused { return "Paused" }
        guard let next else { return "Not scheduled" }
        let delta = next.timeIntervalSince(now)
        if delta <= 0 { return "Due now" }
        if delta < 60 { return "In under a minute" }
        if delta < 3_600 { return "In \(plural(Int(delta / 60), "minute"))" }
        if delta < 86_400 { return "In \(plural(Int(delta / 3_600), "hour")) (\(formatter.string(from: next)))" }
        return formatter.string(from: next)
    }

    /// `repo:build.sh` → `build.sh (repo)`. Schedules store the key, not the
    /// script, so the row can still name it after the file is gone.
    static func scriptDisplayName(_ key: String) -> String {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return key }
        let scope = RunScriptScope(rawValue: parts[0])?.sectionTitle.lowercased() ?? parts[0]
        return "\(parts[1]) (\(scope))"
    }

    static func actionLabel(scriptName: String?, composition: RunScheduleComposition?, agentName: String?) -> String {
        var parts: [String] = []
        if composition != nil { parts.append("New worktree") }
        if let scriptName { parts.append("Run \(scriptName)") }
        if composition != nil { parts.append("Launch \(agentName ?? "default agent")") }
        return parts.joined(separator: " → ")
    }

    /// Which schedules the Run tab shows for a worktree. A project's main
    /// worktree acts as the project's schedule overview (including "all
    /// projects" schedules and ones aimed at worktrees that may since have
    /// been deleted); any other worktree shows only schedules aimed at it.
    static func visibleSchedules(
        _ schedules: [RunSchedule],
        worktreeID: String,
        projectID: String,
        isMainWorktree: Bool
    ) -> [RunSchedule] {
        schedules.filter { schedule in
            switch schedule.target {
            case .allProjects:
                return isMainWorktree
            case .project(let id):
                return isMainWorktree && id == projectID
            case let .worktree(targetProjectID, targetWorktreeID):
                if targetWorktreeID == worktreeID { return true }
                return isMainWorktree && targetProjectID == projectID
            }
        }
    }

    static let defaultDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func plural(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}
