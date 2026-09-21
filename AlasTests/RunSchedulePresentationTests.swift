import Foundation
import Testing
@testable import Alas

struct RunSchedulePresentationTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    @Test func triggerLabels() {
        #expect(RunSchedulePresentation.triggerLabel(.interval(seconds: 1_800)) == "Every 30 minutes")
        #expect(RunSchedulePresentation.triggerLabel(.interval(seconds: 3_600)) == "Every 1 hour")
        #expect(RunSchedulePresentation.triggerLabel(.interval(seconds: 2 * 86_400)) == "Every 2 days")
        #expect(RunSchedulePresentation.triggerLabel(.timeOfDay(hour: 9, minute: 5, weekdays: []), calendar: calendar) == "Daily at 09:05")
        #expect(RunSchedulePresentation.triggerLabel(.timeOfDay(hour: 9, minute: 5, weekdays: Set(2...6)), calendar: calendar) == "Weekdays at 09:05")
        #expect(RunSchedulePresentation.triggerLabel(.timeOfDay(hour: 22, minute: 0, weekdays: [1, 7]), calendar: calendar) == "Weekends at 22:00")
        #expect(RunSchedulePresentation.triggerLabel(.timeOfDay(hour: 7, minute: 30, weekdays: [2, 4]), calendar: calendar) == "Mon, Wed at 07:30")
    }

    @Test func outcomeLabels() {
        #expect(RunSchedulePresentation.outcomeLabel(.succeeded) == "Succeeded")
        #expect(RunSchedulePresentation.outcomeLabel(.failed(exitCode: 2)) == "Failed (exit 2)")
        #expect(RunSchedulePresentation.outcomeLabel(.skipped(reason: "busy")) == "Skipped: busy")
        #expect(RunSchedulePresentation.outcomeLabel(.launchFailed("no agent")) == "Launch failed: no agent")
        #expect(RunSchedulePresentation.outcomeLabel(.unknown) == "Outcome unknown")
    }

    @Test func missedAndGapLabels() {
        let missed = RunScheduleMissedOccurrences(count: 3, policy: .runLatest, observedAt: Date())
        #expect(RunSchedulePresentation.missedLabel(missed) == "3 occurrences missed, ran the latest")
        let single = RunScheduleMissedOccurrences(count: 1, policy: .skip, observedAt: Date())
        #expect(RunSchedulePresentation.missedLabel(single) == "1 occurrence missed and skipped")

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let gap = RunScheduleGap(
            start: Date(timeIntervalSince1970: 3_600),
            end: Date(timeIntervalSince1970: 7_200),
            reason: .appNotRunning
        )
        #expect(RunSchedulePresentation.gapLabel(gap, formatter: formatter).hasPrefix("Alas was not running from 01:00 to 02:00"))
        let asleep = RunScheduleGap(start: gap.start, end: gap.end, reason: .asleep)
        #expect(RunSchedulePresentation.gapLabel(asleep, formatter: formatter).hasPrefix("The machine was asleep"))
    }

    @Test func targetAndHostLabels() {
        let names = ["p1": "Alas", "p2": "Other"]
        let branches = ["w1": "feature/x"]
        func label(_ target: RunScheduleTarget) -> String {
            RunSchedulePresentation.targetLabel(target, projectName: { names[$0] }, worktreeBranch: { branches[$0] })
        }
        #expect(label(.allProjects) == "All projects (main worktree)")
        #expect(label(.project(id: "p1")) == "Alas (main worktree)")
        #expect(label(.worktree(projectId: "p1", worktreeId: "w1")) == "Alas / feature/x")
        #expect(label(.worktree(projectId: "p1", worktreeId: "gone")) == "Alas / missing worktree")
        #expect(label(.project(id: "nope")) == "Missing project (main worktree)")
        #expect(RunSchedulePresentation.hostLabel(nil) == "This Mac")
        #expect(RunSchedulePresentation.hostLabel("devbox") == "devbox")
    }

    @Test func nextFireLabels() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(RunSchedulePresentation.nextFireLabel(now.addingTimeInterval(600), now: now, isEnabled: false, isPaused: false) == "Disabled")
        #expect(RunSchedulePresentation.nextFireLabel(now.addingTimeInterval(600), now: now, isEnabled: true, isPaused: true) == "Paused")
        #expect(RunSchedulePresentation.nextFireLabel(nil, now: now, isEnabled: true, isPaused: false) == "Not scheduled")
        #expect(RunSchedulePresentation.nextFireLabel(now.addingTimeInterval(-5), now: now, isEnabled: true, isPaused: false) == "Due now")
        #expect(RunSchedulePresentation.nextFireLabel(now.addingTimeInterval(30), now: now, isEnabled: true, isPaused: false) == "In under a minute")
        #expect(RunSchedulePresentation.nextFireLabel(now.addingTimeInterval(1_500), now: now, isEnabled: true, isPaused: false) == "In 25 minutes")
        #expect(RunSchedulePresentation.nextFireLabel(now.addingTimeInterval(7_200), now: now, isEnabled: true, isPaused: false).hasPrefix("In 2 hours"))
    }

    @Test func actionLabelsDescribeTheWholeChain() {
        #expect(RunSchedulePresentation.actionLabel(scriptName: "build.sh (repo)", composition: nil, agentName: nil) == "Run build.sh (repo)")
        let composition = RunScheduleComposition()
        #expect(RunSchedulePresentation.actionLabel(scriptName: nil, composition: composition, agentName: "Claude") == "New worktree → Launch Claude")
        #expect(RunSchedulePresentation.actionLabel(scriptName: "setup", composition: composition, agentName: nil) == "New worktree → Run setup → Launch default agent")
        #expect(RunSchedulePresentation.scriptDisplayName("repo:build.sh") == "build.sh (repo)")
        #expect(RunSchedulePresentation.scriptDisplayName("global:lint") == "lint (global)")
        #expect(RunSchedulePresentation.scriptDisplayName("odd") == "odd")
    }

    @Test func visibilityScopesByWorktreeAndMainWorktree() {
        let schedules = [
            RunSchedule(id: "all", name: "all", target: .allProjects, scriptKey: "k", trigger: .interval(seconds: 60)),
            RunSchedule(id: "p1", name: "p1", target: .project(id: "p1"), scriptKey: "k", trigger: .interval(seconds: 60)),
            RunSchedule(id: "p2", name: "p2", target: .project(id: "p2"), scriptKey: "k", trigger: .interval(seconds: 60)),
            RunSchedule(id: "w1", name: "w1", target: .worktree(projectId: "p1", worktreeId: "w1"), scriptKey: "k", trigger: .interval(seconds: 60)),
            RunSchedule(id: "w2", name: "w2", target: .worktree(projectId: "p1", worktreeId: "w2"), scriptKey: "k", trigger: .interval(seconds: 60)),
        ]
        let onFeature = RunSchedulePresentation.visibleSchedules(schedules, worktreeID: "w1", projectID: "p1", isMainWorktree: false)
        #expect(onFeature.map(\.id) == ["w1"])
        let onMain = RunSchedulePresentation.visibleSchedules(schedules, worktreeID: "main", projectID: "p1", isMainWorktree: true)
        #expect(onMain.map(\.id) == ["all", "p1", "w1", "w2"])
        let onOtherMain = RunSchedulePresentation.visibleSchedules(schedules, worktreeID: "main2", projectID: "p2", isMainWorktree: true)
        #expect(onOtherMain.map(\.id) == ["all", "p2"])
    }

    @Test func combinedOutcomePrefersFailuresThenSkips() {
        #expect(RunScheduleOutcome.combined([]) == .skipped(reason: "No targets to run."))
        #expect(RunScheduleOutcome.combined([.succeeded, .succeeded]) == .succeeded)
        #expect(RunScheduleOutcome.combined([.succeeded, .skipped(reason: "x")]) == .skipped(reason: "x"))
        #expect(RunScheduleOutcome.combined([.skipped(reason: "x"), .failed(exitCode: 1), .succeeded]) == .failed(exitCode: 1))
        #expect(RunScheduleOutcome.combined([.succeeded, .launchFailed("boom")]) == .launchFailed("boom"))
    }

    // MARK: - Draft

    @Test func draftRequiresNameTargetAndAnAction() {
        var draft = RunScheduleDraft(projectID: "p1", worktreeID: "w1", isMainWorktree: false)
        #expect(draft.validationError == "Give the schedule a name.")
        draft.name = "Nightly"
        #expect(draft.validationError == "Pick a script, or create a worktree with an agent.")
        draft.createsWorktree = true
        #expect(draft.isValid)
        draft.createsWorktree = false
        draft.scriptKey = "repo:test.sh"
        #expect(draft.isValid)
        draft.targetKind = .thisWorktree
        draft.worktreeID = nil
        #expect(draft.validationError == "Pick a project and worktree.")
        draft.targetKind = .allProjects
        #expect(draft.isValid)
    }

    @Test func draftValidatesTriggers() {
        var draft = RunScheduleDraft(projectID: "p1", worktreeID: "w1", isMainWorktree: true)
        draft.name = "x"
        draft.scriptKey = "repo:t"
        draft.triggerKind = .timeOfDay
        draft.weekdays = []
        #expect(draft.validationError == "Pick at least one weekday.")
        draft.weekdays = [2]
        draft.hour = 24
        #expect(draft.validationError == "Enter a valid time.")
        draft.hour = 9
        #expect(draft.isValid)
        draft.triggerKind = .interval
        draft.intervalValue = 0
        #expect(draft.validationError == "Interval must be at least 1.")
        draft.intervalValue = 45
        draft.intervalUnit = .minutes
        #expect(draft.trigger == .interval(seconds: 2_700))
    }

    @Test func draftRoundTripsThroughASchedule() {
        let original = RunSchedule(
            id: "s1",
            name: "Morning",
            target: .worktree(projectId: "p1", worktreeId: "w1"),
            scriptKey: "repo:test.sh",
            trigger: .timeOfDay(hour: 8, minute: 15, weekdays: Set(2...6)),
            missedRunPolicy: .runLatest,
            composition: RunScheduleComposition(branchTemplate: "sched/{date}", agentId: "claude"),
            isEnabled: false,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        var draft = RunScheduleDraft(schedule: original)
        #expect(draft.targetKind == .thisWorktree)
        #expect(draft.weekdays == Set(2...6))
        #expect(draft.createsWorktree)
        let rebuilt = draft.makeSchedule(existing: original)
        #expect(rebuilt == original)

        // A daily time-of-day schedule stores an empty weekday set.
        draft.weekdays = Set(1...7)
        #expect(draft.trigger == .timeOfDay(hour: 8, minute: 15, weekdays: []))

        let hours = RunScheduleDraft(schedule: RunSchedule(id: "i", name: "i", target: .allProjects, scriptKey: "k", trigger: .interval(seconds: 7_200)))
        #expect(hours.intervalValue == 2)
        #expect(hours.intervalUnit == .hours)
    }

    @Test func draftCarriesThePromptAndDropsABlankOne() {
        let original = RunSchedule(
            id: "s1",
            name: "Morning",
            target: .allProjects,
            scriptKey: nil,
            trigger: .interval(seconds: 3_600),
            composition: RunScheduleComposition(agentId: "claude", prompt: "Run the tests.", sendsPromptAutomatically: false)
        )
        var draft = RunScheduleDraft(schedule: original)
        #expect(draft.prompt == "Run the tests.")
        #expect(!draft.sendsPromptAutomatically)
        #expect(draft.makeSchedule(existing: original) == original)

        // Whitespace is not a prompt; the agent should just open.
        draft.prompt = "  \n"
        #expect(draft.composition?.prompt == nil)
        draft.prompt = "  Fix the build  "
        #expect(draft.composition?.prompt == "Fix the build")

        // Older files predate the prompt fields and still have to decode,
        // or the lenient schedule decoder drops the whole schedule.
        let legacy = Data(#"{"branchTemplate":"nightly","agentId":"claude"}"#.utf8)
        let decoded = try? JSONDecoder().decode(RunScheduleComposition.self, from: legacy)
        #expect(decoded == RunScheduleComposition(branchTemplate: "nightly", agentId: "claude"))
        #expect(decoded?.sendsPromptAutomatically == true)
    }

    @Test func weekdayPresetsNameTheRowAndTogglingLeavesThem() {
        var draft = RunScheduleDraft()
        #expect(draft.weekdayPreset == .everyDay)
        draft.apply(.weekdays)
        #expect(draft.weekdays == Set(2...6))
        #expect(draft.weekdayPreset == .weekdays)
        draft.toggleWeekday(2)
        #expect(draft.weekdayPreset == nil)
        draft.toggleWeekday(2)
        #expect(draft.weekdayPreset == .weekdays)
        draft.apply(.weekends)
        #expect(draft.weekdays == [1, 7])
        #expect(draft.weekdayPreset == .weekends)
    }

    @Test func triggerSummariesReadAsASentence() {
        func plain(_ trigger: RunScheduleTrigger) -> String {
            RunSchedulePresentation.triggerSummarySegments(trigger, calendar: calendar).map(\.text).joined()
        }
        func emphasized(_ trigger: RunScheduleTrigger) -> [String] {
            RunSchedulePresentation.triggerSummarySegments(trigger, calendar: calendar).filter(\.isEmphasized).map(\.text)
        }
        #expect(plain(.timeOfDay(hour: 9, minute: 0, weekdays: Set(2...6))) == "Runs weekdays at 09:00")
        #expect(emphasized(.timeOfDay(hour: 9, minute: 0, weekdays: Set(2...6))) == ["weekdays", "09:00"])
        #expect(plain(.timeOfDay(hour: 22, minute: 30, weekdays: [1, 7])) == "Runs weekends at 22:30")
        #expect(plain(.timeOfDay(hour: 7, minute: 5, weekdays: [2, 4])) == "Runs Mon, Wed at 07:05")
        #expect(plain(.timeOfDay(hour: 7, minute: 5, weekdays: [])) == "Runs never at 07:05")
        #expect(plain(.interval(seconds: 7_200)) == "Runs every 2 hours while Alas is open")
        #expect(emphasized(.interval(seconds: 3_600)) == ["every 1 hour"])
        #expect(RunSchedulePresentation.weekdaysLabel(Set(1...7)) == "every day")
    }

    @Test func nextFirePreviewNamesTodayTomorrowOrTheDay() throws {
        var calendar = self.calendar
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        // Monday 21 September 2026, 20:25.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 20, minute: 25)))
        var draft = RunScheduleDraft()
        draft.triggerKind = .timeOfDay
        draft.hour = 9
        draft.minute = 0
        draft.apply(.weekdays)
        #expect(RunSchedulePresentation.nextFirePreviewLabel(draft.nextFireDate(now: now, calendar: calendar), now: now, calendar: calendar) == "Next: Tomorrow, 09:00")
        draft.hour = 21
        #expect(RunSchedulePresentation.nextFirePreviewLabel(draft.nextFireDate(now: now, calendar: calendar), now: now, calendar: calendar) == "Next: Today, 21:00")
        draft.apply(.weekends)
        #expect(RunSchedulePresentation.nextFirePreviewLabel(draft.nextFireDate(now: now, calendar: calendar), now: now, calendar: calendar) == "Next: Sat 26 Sep, 21:00")
        draft.weekdays = []
        #expect(draft.nextFireDate(now: now, calendar: calendar) == nil)
        #expect(RunSchedulePresentation.nextFirePreviewLabel(nil, now: now, calendar: calendar) == "")

        // An interval schedule is anchored on creation, so its first
        // occurrence is one interval out.
        draft.triggerKind = .interval
        draft.intervalValue = 2
        draft.intervalUnit = .hours
        #expect(RunSchedulePresentation.nextFirePreviewLabel(draft.nextFireDate(now: now, calendar: calendar), now: now, calendar: calendar) == "Next: Today, 22:25")
        draft.intervalValue = 0
        #expect(draft.nextFireDate(now: now, calendar: calendar) == nil)
    }

    @Test func promptHintsAndKeystrokes() {
        #expect(RunSchedulePresentation.promptDeliveryHint(sendsAutomatically: true) == "The agent starts working without waiting for you.")
        #expect(RunSchedulePresentation.promptDeliveryHint(sendsAutomatically: false).contains("press Enter"))
        // Typed into a TUI, a line break is Enter; the prompt has to arrive
        // as one message.
        #expect(RunScheduleComposition.terminalText(for: "Fix the build.\n\nThen open a PR.\r\n") == "Fix the build. Then open a PR.")
        let withPrompt = RunScheduleComposition(agentId: "claude", prompt: "hi")
        #expect(RunSchedulePresentation.actionLabel(scriptName: nil, composition: withPrompt, agentName: "Claude") == "New worktree → Launch Claude with a prompt")
    }

    /// Saving an unchanged trigger keeps the occurrence the scheduler
    /// already holds, so the editor has to show that one. Recomputing from
    /// now would tell an hourly schedule due in five minutes that it runs in
    /// an hour, then contradict itself once the sheet closed.
    @Test func editingAnUnchangedTriggerKeepsTheStoredNextFire() {
        let stored = Date(timeIntervalSince1970: 1_800_000_300)
        let computed = Date(timeIntervalSince1970: 1_800_003_600)
        let trigger = RunScheduleTrigger.interval(seconds: 3_600)

        // Editing a name or prompt leaves the trigger alone.
        #expect(RunSchedulePresentation.editorNextFireDate(
            existingTrigger: trigger, draftTrigger: trigger,
            storedNextFireAt: stored, computedNextFireAt: computed
        ) == stored)

        // Changing the trigger re-anchors, so the fresh one is right.
        #expect(RunSchedulePresentation.editorNextFireDate(
            existingTrigger: trigger, draftTrigger: .interval(seconds: 7_200),
            storedNextFireAt: stored, computedNextFireAt: computed
        ) == computed)

        // A new schedule has nothing stored to preserve.
        #expect(RunSchedulePresentation.editorNextFireDate(
            existingTrigger: nil, draftTrigger: trigger,
            storedNextFireAt: nil, computedNextFireAt: computed
        ) == computed)

        // Deselecting every weekday leaves an invalid draft whose trigger
        // still compares equal to a saved daily one, because both store the
        // empty set. The preview must go blank rather than show the stored
        // date beside "Pick at least one weekday".
        let daily = RunScheduleTrigger.timeOfDay(hour: 9, minute: 0, weekdays: [])
        #expect(RunSchedulePresentation.editorNextFireDate(
            existingTrigger: daily, draftTrigger: daily,
            storedNextFireAt: stored, computedNextFireAt: nil
        ) == nil)
    }

    /// A remote terminal runs `ssh` on this Mac, so the harness detector
    /// classifies `ssh` and never the agent inside the remote PTY. Readiness
    /// cannot be confirmed there, so the prompt is dropped at once rather
    /// than after a two-minute wait that could only ever time out.
    @Test func promptsAreOnlyDeliveredToAgentsOnThisMac() {
        #expect(RunSchedulePresentation.deliversPrompt(host: nil))
        #expect(!RunSchedulePresentation.deliversPrompt(host: "devbox"))
        let message = RunSchedulePresentation.remotePromptSkippedMessage(scheduleName: "Nightly", host: "devbox")
        #expect(message.contains("Nightly"))
        #expect(message.contains("devbox"))
        #expect(message.contains("not sent"))
    }

    // MARK: - History

    @Test func historyHeadingCarriesItsCount() {
        #expect(RunSchedulePresentation.historyLabel([firing(duration: 0)]) == "History (1)")
        #expect(
            RunSchedulePresentation.historyLabel([firing(duration: 0), firing(duration: 2)])
                == "History (2)"
        )
    }

    /// Nothing under a second is timed: a skip and an instant launch failure
    /// both settle immediately, and "0.0s" would suggest a measurement.
    @Test func durationsBelowASecondAreNotReported() {
        #expect(RunSchedulePresentation.durationLabel(0) == nil)
        #expect(RunSchedulePresentation.durationLabel(0.4) == nil)
        #expect(RunSchedulePresentation.durationLabel(3.42) == "3.4s")
        #expect(RunSchedulePresentation.durationLabel(90) == "1 minute")
        #expect(RunSchedulePresentation.durationLabel(7_200) == "2 hours")
    }

    @Test func aFiringLineCarriesItsTimeDurationAndOrigin() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let scheduled = firing(duration: 12)
        #expect(
            RunSchedulePresentation.firingTimeLabel(scheduled, formatter: formatter)
                == "2027-01-15 08:00 · 12.0s"
        )
        // A manual run is marked, because an entry that does not line up with
        // the trigger is otherwise unexplainable.
        let manual = firing(duration: 0, wasManual: true)
        #expect(
            RunSchedulePresentation.firingTimeLabel(manual, formatter: formatter)
                == "2027-01-15 08:00 · Run Now"
        )
    }

    @Test func aLinkedRunIsNamedByScriptAndBranch() {
        let run = RunScheduleFiring.RunReference(
            worktreeID: "wt-1",
            branch: "sched/nightly",
            runID: "run-1",
            scriptName: "build.sh (repo)"
        )
        #expect(RunSchedulePresentation.firingRunLabel(run) == "build.sh (repo) in sched/nightly")
    }

    private func firing(duration: TimeInterval, wasManual: Bool = false) -> RunScheduleFiring {
        // 2027-01-15 08:00 UTC.
        let firedAt = Date(timeIntervalSince1970: 1_800_000_000)
        return RunScheduleFiring(
            firedAt: firedAt,
            finishedAt: firedAt.addingTimeInterval(duration),
            wasManual: wasManual,
            outcome: .succeeded
        )
    }
}
