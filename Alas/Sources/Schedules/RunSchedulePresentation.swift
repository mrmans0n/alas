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

    /// One run of the editor's live summary line. Emphasised segments are the
    /// values the user just picked; the rest is connective text.
    struct SummarySegment: Equatable {
        let text: String
        let isEmphasized: Bool
    }

    /// "Runs *weekdays* at *09:00*" / "Runs *every 2 hours* while Alas is
    /// open", as segments so the view can weight them differently.
    static func triggerSummarySegments(_ trigger: RunScheduleTrigger, calendar: Calendar = .autoupdatingCurrent) -> [SummarySegment] {
        switch trigger {
        case .interval(let seconds):
            return [
                SummarySegment(text: "Runs ", isEmphasized: false),
                SummarySegment(text: "every \(intervalLabel(seconds))", isEmphasized: true),
                SummarySegment(text: " while Alas is open", isEmphasized: false),
            ]
        case let .timeOfDay(hour, minute, weekdays):
            return [
                SummarySegment(text: "Runs ", isEmphasized: false),
                SummarySegment(text: weekdaysLabel(weekdays, calendar: calendar), isEmphasized: true),
                SummarySegment(text: " at ", isEmphasized: false),
                SummarySegment(text: String(format: "%02d:%02d", hour, minute), isEmphasized: true),
            ]
        }
    }

    /// Lower-case so it can sit mid-sentence: "every day", "weekdays",
    /// "weekends", "Mon, Wed", or "never" for an empty set (an empty set is
    /// stored as "every day" on a saved schedule, but the editor shows what
    /// is actually ticked).
    static func weekdaysLabel(_ weekdays: Set<Int>, calendar: Calendar = .autoupdatingCurrent) -> String {
        if weekdays.isEmpty { return "never" }
        if weekdays.count == 7 { return "every day" }
        if weekdays == Set(2...6) { return "weekdays" }
        if weekdays == [1, 7] { return "weekends" }
        let symbols = calendar.shortWeekdaySymbols
        return weekdays.sorted().compactMap { day -> String? in
            guard (1...7).contains(day) else { return nil }
            return symbols[day - 1]
        }.joined(separator: ", ")
    }

    /// "Next: Today, 09:00" for the editor, where the schedule does not exist
    /// yet and there is no state to read a next fire from. Empty when the
    /// draft has no valid trigger.
    static func nextFirePreviewLabel(_ next: Date?, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        guard let next else { return "" }
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        let day: String
        if calendar.isDate(next, inSameDayAs: now) {
            day = "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(next, inSameDayAs: tomorrow) {
            day = "Tomorrow"
        } else {
            // Fixed order, localized names: "Sat 26 Sep" wherever you are.
            let date = DateFormatter()
            date.calendar = calendar
            date.timeZone = calendar.timeZone
            date.locale = calendar.locale ?? Locale(identifier: "en_US_POSIX")
            date.dateFormat = "EEE d MMM"
            day = date.string(from: next)
        }
        return "Next: \(day), \(time.string(from: next))"
    }

    /// Whether a scheduled prompt can be delivered to an agent on `host`.
    ///
    /// Only to agents on this Mac. A prompt is typed into the agent's
    /// terminal and is sent only once the harness detector confirms the
    /// agent owns that terminal, but a remote terminal runs `ssh` locally
    /// and the detector classifies that local process. The agent itself
    /// lives in the remote PTY, out of its reach, so readiness could never
    /// be confirmed and every firing would wait out the timeout.
    static func deliversPrompt(host: String?) -> Bool {
        host == nil
    }

    /// Why a remote schedule's prompt was not sent. Said once per firing,
    /// because the user configured a prompt that is not going to arrive.
    static func remotePromptSkippedMessage(scheduleName: String, host: String) -> String {
        "\(scheduleName): the agent runs on \(host), where Alas cannot tell when it is ready, so the prompt was not sent."
    }

    /// What ticking "send automatically" changes, in one line under it.
    static func promptDeliveryHint(sendsAutomatically: Bool) -> String {
        sendsAutomatically
            ? "The agent starts working without waiting for you."
            : "The prompt is pre-filled in the terminal; you press Enter to send it."
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
        if let composition {
            let launch = "Launch \(agentName ?? "default agent")"
            parts.append(composition.prompt == nil ? launch : "\(launch) with a prompt")
        }
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
