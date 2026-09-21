import Foundation
import Testing
@testable import Alas

struct RunSchedulePlannerTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func schedule(
        trigger: RunScheduleTrigger,
        policy: RunScheduleMissedRunPolicy = .skip,
        createdAt: Date
    ) -> RunSchedule {
        RunSchedule(
            id: "s",
            name: "Test",
            target: .allProjects,
            scriptKey: "repo:test.sh",
            trigger: trigger,
            missedRunPolicy: policy,
            createdAt: createdAt
        )
    }

    // MARK: - Next fire

    @Test func intervalSnapsToTheGridAfterTheAnchor() {
        let anchor = date(2026, 9, 20, 10, 0)
        let trigger = RunScheduleTrigger.interval(seconds: 1_800)
        #expect(
            RunSchedulePlanner.nextFireDate(for: trigger, after: anchor, anchor: anchor, calendar: calendar)
                == date(2026, 9, 20, 10, 30)
        )
        // Evaluated late: skips forward to the first grid point after "now".
        #expect(
            RunSchedulePlanner.nextFireDate(for: trigger, after: date(2026, 9, 20, 11, 5), anchor: anchor, calendar: calendar)
                == date(2026, 9, 20, 11, 30)
        )
    }

    @Test func intervalsShorterThanAMinuteAreClamped() {
        let anchor = date(2026, 9, 20, 10, 0)
        let next = RunSchedulePlanner.nextFireDate(
            for: .interval(seconds: 5), after: anchor, anchor: anchor, calendar: calendar
        )
        #expect(next == anchor.addingTimeInterval(60))
    }

    @Test func timeOfDayFiresLaterTodayOrTomorrow() {
        let trigger = RunScheduleTrigger.timeOfDay(hour: 9, minute: 30, weekdays: [])
        #expect(
            RunSchedulePlanner.nextFireDate(for: trigger, after: date(2026, 9, 20, 8, 0), anchor: .distantPast, calendar: calendar)
                == date(2026, 9, 20, 9, 30)
        )
        #expect(
            RunSchedulePlanner.nextFireDate(for: trigger, after: date(2026, 9, 20, 9, 30), anchor: .distantPast, calendar: calendar)
                == date(2026, 9, 21, 9, 30)
        )
    }

    @Test func timeOfDayHonorsWeekdays() {
        // 2026-09-20 is a Sunday. Weekdays only → Monday.
        let trigger = RunScheduleTrigger.timeOfDay(hour: 9, minute: 0, weekdays: Set(2...6))
        #expect(
            RunSchedulePlanner.nextFireDate(for: trigger, after: date(2026, 9, 20, 8, 0), anchor: .distantPast, calendar: calendar)
                == date(2026, 9, 21, 9, 0)
        )
        // Friday evening → next Monday, across the weekend.
        #expect(
            RunSchedulePlanner.nextFireDate(for: trigger, after: date(2026, 9, 25, 18, 0), anchor: .distantPast, calendar: calendar)
                == date(2026, 9, 28, 9, 0)
        )
    }

    @Test func timeOfDaySurvivesADaylightSavingTransition() {
        // Europe/Madrid falls back on 2026-10-25 at 03:00 → 02:00.
        let trigger = RunScheduleTrigger.timeOfDay(hour: 9, minute: 0, weekdays: [])
        let next = RunSchedulePlanner.nextFireDate(
            for: trigger, after: date(2026, 10, 24, 12, 0), anchor: .distantPast, calendar: calendar
        )
        #expect(next == date(2026, 10, 25, 9, 0))
        #expect(calendar.component(.hour, from: next) == 9)
    }

    // MARK: - Decisions

    @Test func notDueWaits() {
        let created = date(2026, 9, 20, 10, 0)
        let decision = RunSchedulePlanner.decide(
            schedule: schedule(trigger: .interval(seconds: 3_600), createdAt: created),
            state: RunScheduleState(),
            now: date(2026, 9, 20, 10, 30),
            calendar: calendar
        )
        #expect(decision == .wait(next: date(2026, 9, 20, 11, 0)))
    }

    @Test func dueWithinGraceFiresAndReanchors() {
        let created = date(2026, 9, 20, 10, 0)
        let decision = RunSchedulePlanner.decide(
            schedule: schedule(trigger: .interval(seconds: 3_600), createdAt: created),
            state: RunScheduleState(nextFireAt: date(2026, 9, 20, 11, 0)),
            now: date(2026, 9, 20, 11, 0).addingTimeInterval(20),
            calendar: calendar
        )
        guard case let .fire(next, missed) = decision else {
            Issue.record("Expected fire, got \(decision)")
            return
        }
        #expect(missed == 0)
        // Interval re-anchors on the fire time, not the original grid.
        #expect(next == date(2026, 9, 20, 12, 0).addingTimeInterval(20))
    }

    @Test func skipPolicyDropsEveryMissedOccurrenceAndNeverFires() {
        let created = date(2026, 9, 20, 10, 0)
        // Asleep from 10:30 to 14:10 with a 30-minute interval: 11:00 … 14:00 missed.
        let decision = RunSchedulePlanner.decide(
            schedule: schedule(trigger: .interval(seconds: 1_800), policy: .skip, createdAt: created),
            state: RunScheduleState(nextFireAt: date(2026, 9, 20, 11, 0)),
            now: date(2026, 9, 20, 14, 10),
            calendar: calendar
        )
        #expect(decision == .skip(next: date(2026, 9, 20, 14, 30), missed: 7))
    }

    @Test func runLatestPolicyFiresExactlyOnceForABacklog() {
        let created = date(2026, 9, 20, 10, 0)
        let decision = RunSchedulePlanner.decide(
            schedule: schedule(trigger: .interval(seconds: 1_800), policy: .runLatest, createdAt: created),
            state: RunScheduleState(nextFireAt: date(2026, 9, 20, 11, 0)),
            now: date(2026, 9, 20, 14, 10),
            calendar: calendar
        )
        guard case let .fire(next, missed) = decision else {
            Issue.record("Expected fire, got \(decision)")
            return
        }
        #expect(missed == 6)
        #expect(next == date(2026, 9, 20, 14, 40))
        #expect(next > date(2026, 9, 20, 14, 10))
    }

    @Test func timeOfDayBacklogCountsCalendarOccurrences() {
        let created = date(2026, 9, 1, 8, 0)
        // App quit for four days with a daily 09:00 schedule.
        let decision = RunSchedulePlanner.decide(
            schedule: schedule(trigger: .timeOfDay(hour: 9, minute: 0, weekdays: []), policy: .skip, createdAt: created),
            state: RunScheduleState(nextFireAt: date(2026, 9, 16, 9, 0)),
            now: date(2026, 9, 20, 12, 0),
            calendar: calendar
        )
        #expect(decision == .skip(next: date(2026, 9, 21, 9, 0), missed: 5))
    }

    @Test func aNewScheduleDerivesItsFirstDueTimeFromCreation() {
        let created = date(2026, 9, 20, 10, 0)
        let decision = RunSchedulePlanner.decide(
            schedule: schedule(trigger: .interval(seconds: 600), createdAt: created),
            state: RunScheduleState(),
            now: date(2026, 9, 20, 10, 10).addingTimeInterval(5),
            calendar: calendar
        )
        guard case .fire = decision else {
            Issue.record("Expected first occurrence to fire, got \(decision)")
            return
        }
    }

    // MARK: - Branch rendering

    @Test func branchTemplateExpandsAndSanitizes() {
        let now = date(2026, 9, 20, 9, 5)
        let branch = RunSchedulePlanner.renderBranch(
            template: "scheduled/{name}-{date}-{time}",
            name: "Morning Tests!",
            now: now,
            calendar: calendar
        )
        #expect(branch == "scheduled/morning-tests-20260920-0905")
    }

    @Test func branchTemplateRejectsInvalidRefCharacters() {
        let now = date(2026, 9, 20, 9, 5)
        let branch = RunSchedulePlanner.renderBranch(template: "..//weird name~^:{date}", name: "x", now: now, calendar: calendar)
        #expect(!branch.hasPrefix("."))
        #expect(!branch.contains(".."))
        #expect(!branch.contains("//"))
        #expect(!branch.contains(" "))
        #expect(!branch.contains("~"))
        #expect(branch.hasSuffix("20260920"))
    }

    @Test func emptyTemplateFallsBackToAUsableName() {
        let branch = RunSchedulePlanner.renderBranch(template: "   ", name: "", now: date(2026, 9, 20, 9, 5), calendar: calendar)
        #expect(branch == "scheduled-20260920-0905")
    }

    /// Whatever the user types, the rendered branch has to be something git
    /// will actually accept — a schedule that renders an invalid ref would
    /// fail on every single firing.
    @Test func renderedBranchesAlwaysPassTheGitValidator() {
        let now = date(2026, 9, 20, 9, 5)
        let templates = [
            "release/.nightly",
            "fix.lock",
            "nightly.LOCK/{date}",
            "{name}/../escape",
            "trailing./{time}",
            "-leading/{name}",
            "weird ~^:?*[ chars/{date}",
            "a//b/{name}",
            "...",
            "@",
            "feature/{name}-{date}-{time}",
        ]
        for template in templates {
            let branch = RunSchedulePlanner.renderBranch(
                template: template, name: "Nightly Tests", now: now, calendar: calendar
            )
            #expect(!branch.isEmpty, "empty branch for \(template)")
            #expect(
                GitNameValidator.validateBranchName(branch) == .valid,
                "git rejected \(branch) rendered from \(template)"
            )
        }
    }

    @Test func sanitizerRepairsTheComponentsGitRejects() {
        let now = date(2026, 9, 20, 9, 5)
        func render(_ template: String) -> String {
            RunSchedulePlanner.renderBranch(template: template, name: "x", now: now, calendar: calendar)
        }
        #expect(render("release/.nightly") == "release/nightly")
        #expect(render("fix.lock") == "fix")
        #expect(render("a//b") == "a/b")
        #expect(render("trailing.") == "trailing")
    }
}
