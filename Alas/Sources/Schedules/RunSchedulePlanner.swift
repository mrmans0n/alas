import Foundation

/// Pure firing arithmetic. Everything the scheduler decides about *when* goes
/// through here so the semantics can be tested with a fixed clock and no
/// timers: next occurrence, whether a schedule is due, and how many
/// occurrences were missed.
enum RunSchedulePlanner {
    /// A due occurrence older than this is treated as missed rather than
    /// merely late. Comfortably above the tick interval so a slow tick never
    /// looks like a sleep.
    static let defaultGrace: TimeInterval = 120

    /// Occurrence counting stops here. A schedule asleep for a year does not
    /// need an exact count, just "many".
    static let maximumCountedOccurrences = 10_000

    enum Decision: Equatable {
        case wait(next: Date)
        case fire(next: Date, missed: Int)
        case skip(next: Date, missed: Int)
    }

    /// The first occurrence strictly after `reference`.
    ///
    /// For interval triggers, occurrences sit on a grid starting at `anchor`
    /// (creation or the last fire), so a late evaluation snaps forward
    /// instead of drifting. For time-of-day triggers `anchor` is ignored.
    static func nextFireDate(
        for trigger: RunScheduleTrigger,
        after reference: Date,
        anchor: Date,
        calendar: Calendar
    ) -> Date {
        switch trigger {
        case .interval(let seconds):
            let interval = max(RunScheduleTrigger.minimumIntervalSeconds, seconds)
            guard reference >= anchor else { return anchor.addingTimeInterval(interval) }
            let elapsed = reference.timeIntervalSince(anchor)
            let steps = floor(elapsed / interval) + 1
            return anchor.addingTimeInterval(steps * interval)
        case let .timeOfDay(hour, minute, weekdays):
            let allowed = weekdays.isEmpty ? Set(1...7) : weekdays
            var day = calendar.startOfDay(for: reference)
            // Eight days covers any single allowed weekday plus a same-day
            // time that already passed.
            for _ in 0..<8 {
                if let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                   calendar.isDate(candidate, inSameDayAs: day),
                   candidate > reference,
                   allowed.contains(calendar.component(.weekday, from: candidate)) {
                    return candidate
                }
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = nextDay
            }
            return reference.addingTimeInterval(24 * 60 * 60)
        }
    }

    /// Occurrences in `[due, now]` inclusive of `due`, capped.
    static func occurrenceCount(
        for trigger: RunScheduleTrigger,
        from due: Date,
        through now: Date,
        anchor: Date,
        calendar: Calendar
    ) -> Int {
        guard due <= now else { return 0 }
        switch trigger {
        case .interval(let seconds):
            let interval = max(RunScheduleTrigger.minimumIntervalSeconds, seconds)
            let count = Int(floor(now.timeIntervalSince(due) / interval)) + 1
            return min(count, maximumCountedOccurrences)
        case .timeOfDay:
            var count = 1
            var cursor = due
            while count < maximumCountedOccurrences {
                cursor = nextFireDate(for: trigger, after: cursor, anchor: anchor, calendar: calendar)
                guard cursor <= now else { break }
                count += 1
            }
            return count
        }
    }

    /// Decides what one evaluation should do for a schedule. Whatever the
    /// answer, `next` is strictly after `now`, so one evaluation never
    /// produces more than one run and the following evaluation cannot see
    /// the same occurrence again.
    static func decide(
        schedule: RunSchedule,
        state: RunScheduleState,
        now: Date,
        grace: TimeInterval = defaultGrace,
        calendar: Calendar
    ) -> Decision {
        let anchor = state.lastFiredAt ?? schedule.createdAt
        let due = state.nextFireAt
            ?? nextFireDate(for: schedule.trigger, after: anchor, anchor: anchor, calendar: calendar)
        guard due <= now else { return .wait(next: due) }
        let lateness = now.timeIntervalSince(due)
        if lateness <= grace {
            let next = nextFireDate(for: schedule.trigger, after: now, anchor: now, calendar: calendar)
            return .fire(next: next, missed: 0)
        }
        let missed = occurrenceCount(for: schedule.trigger, from: due, through: now, anchor: anchor, calendar: calendar)
        switch schedule.missedRunPolicy {
        case .runLatest:
            let next = nextFireDate(for: schedule.trigger, after: now, anchor: now, calendar: calendar)
            return .fire(next: next, missed: max(0, missed - 1))
        case .skip:
            let next = nextFireDate(for: schedule.trigger, after: now, anchor: anchor, calendar: calendar)
            return .skip(next: next, missed: missed)
        }
    }

    /// Expands `{name}`, `{date}` and `{time}` and sanitizes the result into
    /// something git accepts as a branch name.
    static func renderBranch(template: String, name: String, now: Date, calendar: Calendar = .current) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyyMMdd"
        let timeFormatter = DateFormatter()
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HHmm"
        let expanded = template
            .replacingOccurrences(of: "{name}", with: slug(name))
            .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: now))
            .replacingOccurrences(of: "{time}", with: timeFormatter.string(from: now))
        let cleaned = sanitizeBranch(expanded)
        return cleaned.isEmpty ? "scheduled-\(dateFormatter.string(from: now))-\(timeFormatter.string(from: now))" : cleaned
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var result = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    private static func sanitizeBranch(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for character in text {
            let scalarOK = character.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_./".unicodeScalars.contains(scalar))
            }
            guard scalarOK else {
                if previous != "-" {
                    result.append("-")
                    previous = "-"
                }
                continue
            }
            // git refuses "..", "//", leading dots and trailing slashes.
            if (character == "." && previous == ".") || (character == "/" && previous == "/") { continue }
            if result.isEmpty, character == "." || character == "/" || character == "-" { continue }
            result.append(character)
            previous = character
        }
        while let last = result.last, last == "/" || last == "." || last == "-" { result.removeLast() }
        return result
    }
}
