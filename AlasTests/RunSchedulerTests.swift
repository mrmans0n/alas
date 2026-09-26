import Foundation
import Testing
@testable import Alas

@MainActor
struct RunSchedulerTests {
    /// In-memory persistence shared between "relaunches" of a scheduler.
    private final class MemoryStore: PersistenceStoreProtocol {
        var files: [URL: Data] = [:]
        var writeCount = 0
        private let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return encoder
        }()
        private let decoder: JSONDecoder = {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }()

        func write<T: Encodable>(_ value: T, to url: URL) throws {
            files[url] = try encoder.encode(value)
            writeCount += 1
        }

        func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
            guard let data = files[url] else { return nil }
            return try decoder.decode(T.self, from: data)
        }
    }

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private final class RunLog {
        var fired: [String] = []
        var invocations: [RunScheduleInvocation] = []
        var outcome: RunScheduleOutcome = .succeeded
        var runs: [RunScheduleFiring.RunReference] = []
        var gate: CheckedContinuation<Void, Never>?
        var holdsRuns = false
        var firingIDs: [String] = []
    }

    private let fileURL = URL(fileURLWithPath: "/memory/run-schedules.json")
    private let calendar = Calendar(identifier: .gregorian)

    private func makeScheduler(
        store: MemoryStore,
        clock: Clock,
        log: RunLog = RunLog(),
        calendar: Calendar? = nil
    ) -> (RunScheduler, RunLog) {
        let scheduler = RunScheduler(
            store: store,
            fileURL: fileURL,
            now: { clock.now },
            calendar: calendar ?? self.calendar,
            tickInterval: 30,
            grace: 120
        )
        scheduler.runner = { schedule, invocation, firingID in
            log.fired.append(schedule.id)
            log.firingIDs.append(firingID)
            log.invocations.append(invocation)
            if log.holdsRuns {
                await withCheckedContinuation { continuation in
                    log.gate = continuation
                }
            }
            return RunScheduleRunReport(outcome: log.outcome, runs: log.runs)
        }
        return (scheduler, log)
    }

    private func interval(_ id: String, seconds: TimeInterval, policy: RunScheduleMissedRunPolicy = .skip, at createdAt: Date, target: RunScheduleTarget = .allProjects) -> RunSchedule {
        RunSchedule(
            id: id,
            name: id,
            target: target,
            scriptKey: "repo:test.sh",
            trigger: .interval(seconds: seconds),
            missedRunPolicy: policy,
            createdAt: createdAt
        )
    }

    // MARK: - Persistence

    @Test func schedulesAndStateSurviveRelaunch() async throws {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (first, log) = makeScheduler(store: store, clock: clock)
        var schedule = interval("a", seconds: 600, at: clock.now)
        schedule.composition = RunScheduleComposition(branchTemplate: "sched/{date}", agentId: "claude")
        first.add(schedule)
        first.setProjectPaused(true, projectID: "p1")
        clock.advance(605)
        first.evaluate()
        await first.waitForRunsForTesting()

        let (second, _) = makeScheduler(store: store, clock: clock)
        #expect(second.schedules == [schedule])
        #expect(second.pausedProjectIDs == ["p1"])
        let state = second.state(for: "a")
        #expect(state.lastOutcome == .succeeded)
        #expect(state.lastFiredAt != nil)
        #expect(state.firings.first?.id == log.firingIDs.first)
        #expect(state.nextFireAt != nil)
    }

    /// A single entry a newer build wrote must not read as "no schedules" and
    /// then be persisted over everything that still decodes.
    @Test func oneUndecodableScheduleDoesNotDiscardTheRest() throws {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (first, _) = makeScheduler(store: store, clock: clock)
        first.add(interval("keep-1", seconds: 600, at: clock.now))
        first.add(interval("keep-2", seconds: 900, at: clock.now))

        // Corrupt one entry the way an unknown trigger case would read.
        let persisted = try #require(store.files[fileURL])
        var object = try #require(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        var schedules = try #require(object["schedules"] as? [[String: Any]])
        schedules.insert(["id": "broken", "name": "Broken"], at: 1)
        object["schedules"] = schedules
        store.files[fileURL] = try JSONSerialization.data(withJSONObject: object)

        let (second, _) = makeScheduler(store: store, clock: clock)
        #expect(second.schedules.map(\.id) == ["keep-1", "keep-2"])
    }

    /// Losing every remembered `nextFireAt` would re-anchor schedules on
    /// their creation date, which makes a `runLatest` schedule think it has a
    /// backlog and fire the moment the app starts.
    @Test func oneUndecodableStateDoesNotDiscardTheOthers() async throws {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (first, _) = makeScheduler(store: store, clock: clock)
        first.add(interval("a", seconds: 600, at: clock.now))
        first.add(interval("b", seconds: 600, at: clock.now))
        clock.advance(605)
        first.evaluate()
        await first.waitForRunsForTesting()

        let persisted = try #require(store.files[fileURL])
        var object = try #require(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        var states = try #require(object["states"] as? [String: Any])
        states["b"] = ["lastFiredAt": "not-a-date"]
        object["states"] = states
        store.files[fileURL] = try JSONSerialization.data(withJSONObject: object)

        let (second, log) = makeScheduler(store: store, clock: clock)
        #expect(second.state(for: "a").nextFireAt != nil)
        #expect(second.state(for: "a").lastOutcome == .succeeded)

        // The surviving schedule keeps its schedule, so a fresh evaluation
        // right away fires nothing.
        second.evaluate()
        await second.waitForRunsForTesting()
        #expect(!log.fired.contains("a"))
    }

    /// A time-of-day trigger is a wall-clock time. Carrying the laptop to
    /// another zone must move it, not fire it at the old zone's hour and then
    /// again at the new one's.
    @Test func changingTimeZoneRetimesAWallClockSchedule() async throws {
        func zoned(_ identifier: String) -> Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: identifier)!
            return calendar
        }
        let madrid = zoned("Europe/Madrid")
        let newYork = zoned("America/New_York")
        // 2026-09-21 07:00 in Madrid, before that day's 09:00 occurrence.
        let start = madrid.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 7))!
        let store = MemoryStore()
        let clock = Clock(start)
        let (first, _) = makeScheduler(store: store, clock: clock, calendar: madrid)
        let schedule = RunSchedule(
            id: "morning",
            name: "Morning",
            target: .allProjects,
            scriptKey: "repo:test.sh",
            trigger: .timeOfDay(hour: 9, minute: 0, weekdays: []),
            createdAt: start
        )
        first.add(schedule)
        first.evaluate()
        #expect(first.state(for: "morning").nextFireAt == madrid.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 9)))

        // Same instant, now read in New York: 01:00 local, so the next 09:00
        // is today in New York, not the stored Madrid instant.
        let (second, log) = makeScheduler(store: store, clock: clock, calendar: newYork)
        second.evaluate()
        await second.waitForRunsForTesting()
        let retimed = try #require(second.state(for: "morning").nextFireAt)
        #expect(retimed == newYork.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 9)))
        #expect(log.fired.isEmpty)

        // Advancing to the old zone's instant must not fire it early.
        clock.now = madrid.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 9))!
        second.evaluate()
        await second.waitForRunsForTesting()
        #expect(log.fired.isEmpty)

        clock.now = retimed
        second.evaluate()
        await second.waitForRunsForTesting()
        #expect(log.fired == ["morning"])
    }

    /// Moving zones after the new zone's hour has already passed must not
    /// manufacture a missed occurrence: that local 09:00 was never skipped,
    /// it simply never existed here.
    @Test func retimingDoesNotInventAPastOccurrence() async throws {
        func zoned(_ identifier: String) -> Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: identifier)!
            return calendar
        }
        let madrid = zoned("Europe/Madrid")
        let tokyo = zoned("Asia/Tokyo")
        let start = madrid.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 7))!
        let store = MemoryStore()
        let clock = Clock(start)
        let (first, _) = makeScheduler(store: store, clock: clock, calendar: madrid)
        first.add(RunSchedule(
            id: "morning",
            name: "Morning",
            target: .allProjects,
            scriptKey: "repo:test.sh",
            trigger: .timeOfDay(hour: 9, minute: 0, weekdays: []),
            missedRunPolicy: .runLatest,
            createdAt: start
        ))
        first.evaluate()

        // In Tokyo the same instant is 14:00, so today's 09:00 is already
        // behind us. It must wait for tomorrow rather than fire now.
        let (second, log) = makeScheduler(store: store, clock: clock, calendar: tokyo)
        second.evaluate()
        await second.waitForRunsForTesting()

        #expect(log.fired.isEmpty)
        #expect(second.state(for: "morning").lastMissed == nil)
        let next = try #require(second.state(for: "morning").nextFireAt)
        #expect(next > clock.now)
        #expect(next == tokyo.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 9)))
    }

    @Test func schedulesWithoutAnActionAreDroppedOnLoad() throws {
        let store = MemoryStore()
        var file = RunSchedulesFile()
        file.schedules = [
            RunSchedule(id: "empty", name: "Empty", target: .allProjects, scriptKey: nil, trigger: .interval(seconds: 60)),
            RunSchedule(id: "ok", name: "OK", target: .allProjects, scriptKey: "repo:x", trigger: .interval(seconds: 60)),
        ]
        try store.write(file, to: fileURL)
        let (scheduler, _) = makeScheduler(store: store, clock: Clock(Date()))
        #expect(scheduler.schedules.map(\.id) == ["ok"])
    }

    // MARK: - Firing

    @Test func aDueScheduleFiresOnceAndRecordsItsOutcome() async {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (scheduler, log) = makeScheduler(store: store, clock: clock)
        log.outcome = .failed(exitCode: 3)
        scheduler.add(interval("a", seconds: 600, at: clock.now))

        clock.advance(300)
        scheduler.evaluate()
        #expect(log.fired.isEmpty)

        clock.advance(310)
        scheduler.evaluate()
        await scheduler.waitForRunsForTesting()
        #expect(log.fired == ["a"])
        let state = scheduler.state(for: "a")
        #expect(state.lastOutcome == .failed(exitCode: 3))
        #expect(state.lastOutcomeAt == clock.now)
        #expect(state.nextFireAt == clock.now.addingTimeInterval(600))

        // The same occurrence is never seen twice.
        scheduler.evaluate()
        await scheduler.waitForRunsForTesting()
        #expect(log.fired == ["a"])
    }

    @Test func disabledAndPausedSchedulesDoNotFireButKeepNextHonest() async {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (scheduler, log) = makeScheduler(store: store, clock: clock)
        scheduler.add(interval("disabled", seconds: 600, at: clock.now))
        scheduler.add(interval("project", seconds: 600, at: clock.now, target: .project(id: "p1")))
        scheduler.add(interval("global", seconds: 600, at: clock.now))
        scheduler.setEnabled(false, id: "disabled")
        scheduler.setProjectPaused(true, projectID: "p1")

        clock.advance(605)
        scheduler.evaluate()
        await scheduler.waitForRunsForTesting()
        #expect(log.fired == ["global"])
        #expect(scheduler.state(for: "disabled").nextFireAt! > clock.now)
        #expect(scheduler.state(for: "project").nextFireAt! > clock.now)
        #expect(scheduler.state(for: "disabled").lastMissed == nil)

        scheduler.setPausedGlobally(true)
        clock.advance(600)
        scheduler.evaluate()
        await scheduler.waitForRunsForTesting()
        #expect(log.fired == ["global"])
    }

    @Test func reEnablingStartsFreshInsteadOfCatchingUp() async {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (scheduler, log) = makeScheduler(store: store, clock: clock)
        scheduler.add(interval("a", seconds: 600, policy: .runLatest, at: clock.now))
        scheduler.setEnabled(false, id: "a")
        clock.advance(5_000)
        scheduler.setEnabled(true, id: "a")
        scheduler.evaluate()
        await scheduler.waitForRunsForTesting()
        #expect(log.fired.isEmpty)
        #expect(scheduler.state(for: "a").nextFireAt == clock.now.addingTimeInterval(600))
    }

    @Test func runNowIgnoresTriggerAndPause() async {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (scheduler, log) = makeScheduler(store: store, clock: clock)
        scheduler.add(interval("a", seconds: 3_600, at: clock.now))
        scheduler.setPausedGlobally(true)
        scheduler.runNow(id: "a")
        await scheduler.waitForRunsForTesting()
        #expect(log.fired == ["a"])
        // Run Now is explicit, so it is marked as bypassing pauses; the
        // timer's own firings are not.
        #expect(log.invocations == [.manual])
        #expect(scheduler.state(for: "a").lastOutcome == .succeeded)
    }

    @Test func timerFiringsAreMarkedAsScheduled() async {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (scheduler, log) = makeScheduler(store: store, clock: clock)
        scheduler.add(interval("a", seconds: 600, at: clock.now))
        clock.advance(605)
        scheduler.evaluate()
        await scheduler.waitForRunsForTesting()
        #expect(log.invocations == [.scheduled])
    }

    @Test func projectPauseIsQueryableForFanOutTargets() {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (scheduler, _) = makeScheduler(store: store, clock: clock)
        scheduler.setProjectPaused(true, projectID: "p1")

        #expect(scheduler.isProjectPaused("p1"))
        #expect(!scheduler.isProjectPaused("p2"))
        // An all-projects schedule names no project, so the whole-schedule
        // pause check cannot see a per-project pause. The fan-out applies it.
        let all = interval("all", seconds: 600, at: clock.now)
        #expect(!scheduler.isPaused(all))
    }

    @Test func anInFlightRunIsNeverDoubled() async {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (scheduler, log) = makeScheduler(store: store, clock: clock)
        log.holdsRuns = true
        scheduler.add(interval("a", seconds: 60, at: clock.now))

        clock.advance(65)
        scheduler.evaluate()
        // Let the runner task reach its gate before the next evaluation.
        var yields = 0
        while log.gate == nil, yields < 1_000 {
            await Task.yield()
            yields += 1
        }
        #expect(log.gate != nil)
        #expect(scheduler.isRunning(scheduler.schedule(id: "a")!))

        clock.advance(60)
        scheduler.evaluate()
        #expect(log.fired == ["a"])
        #expect(scheduler.state(for: "a").lastOutcome == .skipped(reason: "The previous run is still in progress."))
        // A collision is an event too, and is the explanation for an
        // occurrence that otherwise looks like it simply never happened.
        #expect(
            scheduler.firings(for: "a").map(\.outcome)
                == [.skipped(reason: "The previous run is still in progress.")]
        )

        log.holdsRuns = false
        log.gate?.resume()
        await scheduler.waitForRunsForTesting()
        #expect(scheduler.isRunning(scheduler.schedule(id: "a")!) == false)
        #expect(scheduler.state(for: "a").lastOutcome == .succeeded)
        // Newest first: the run that finished, then the one it refused.
        #expect(
            scheduler.firings(for: "a").map(\.outcome)
                == [.succeeded, .skipped(reason: "The previous run is still in progress.")]
        )
    }

    // MARK: - Missed occurrences and gaps

    @Test func relaunchAfterALongQuitFollowsThePolicyAndRecordsTheGap() async {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (first, _) = makeScheduler(store: store, clock: clock)
        first.add(interval("skip", seconds: 600, policy: .skip, at: clock.now))
        first.add(interval("latest", seconds: 600, policy: .runLatest, at: clock.now))
        first.evaluate()
        let quitAt = clock.now

        // Six hours later: 36 occurrences each were missed.
        clock.advance(6 * 3_600)
        let (second, log) = makeScheduler(store: store, clock: clock)
        second.evaluate()
        await second.waitForRunsForTesting()

        #expect(log.fired == ["latest"])
        #expect(second.state(for: "skip").lastMissed?.count == 36)
        #expect(second.state(for: "skip").lastMissed?.policy == .skip)
        #expect(second.state(for: "latest").lastMissed?.count == 35)
        #expect(second.state(for: "latest").lastMissed?.policy == .runLatest)
        #expect(second.state(for: "skip").nextFireAt! > clock.now)
        #expect(second.state(for: "latest").nextFireAt == clock.now.addingTimeInterval(600))
        let gap = second.lastGap
        #expect(gap?.reason == .appNotRunning)
        #expect(gap?.start == quitAt)
        #expect(gap?.end == clock.now)
    }

    @Test func aLongPauseBetweenTicksIsReportedAsSleep() async {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (scheduler, log) = makeScheduler(store: store, clock: clock)
        scheduler.add(interval("a", seconds: 600, policy: .skip, at: clock.now))
        scheduler.evaluate()
        #expect(scheduler.lastGap == nil)

        clock.advance(30)
        scheduler.evaluate()
        #expect(scheduler.lastGap == nil)

        let sleptAt = clock.now
        clock.advance(2 * 3_600)
        scheduler.evaluate()
        await scheduler.waitForRunsForTesting()
        #expect(scheduler.lastGap?.reason == .asleep)
        #expect(scheduler.lastGap?.start == sleptAt)
        #expect(log.fired.isEmpty)
        #expect(scheduler.state(for: "a").lastMissed?.count == 12)
    }

    @Test func removingAProjectPrunesItsSchedules() {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (scheduler, _) = makeScheduler(store: store, clock: clock)
        scheduler.add(interval("p1", seconds: 600, at: clock.now, target: .project(id: "p1")))
        scheduler.add(interval("wt", seconds: 600, at: clock.now, target: .worktree(projectId: "p1", worktreeId: "w")))
        scheduler.add(interval("p2", seconds: 600, at: clock.now, target: .project(id: "p2")))
        scheduler.add(interval("all", seconds: 600, at: clock.now))
        scheduler.setProjectPaused(true, projectID: "p1")
        scheduler.pruneSchedules(missingProjectIDs: ["p1"])
        #expect(scheduler.schedules.map(\.id) == ["p2", "all"])
        #expect(scheduler.pausedProjectIDs.isEmpty)
    }

    // MARK: - History

    @Test func everyFiringIsRecordedNewestFirstWithItsRuns() async throws {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (scheduler, log) = makeScheduler(store: store, clock: clock)
        log.runs = [.init(worktreeID: "wt-1", branch: "main", runID: "run-1", scriptName: "test.sh")]
        scheduler.add(interval("a", seconds: 600, at: clock.now))

        clock.advance(605)
        scheduler.evaluate()
        await scheduler.waitForRunsForTesting()
        log.outcome = .failed(exitCode: 2)
        log.runs = [.init(worktreeID: "wt-1", branch: "main", runID: "run-2", scriptName: "test.sh")]
        clock.advance(600)
        scheduler.evaluate()
        await scheduler.waitForRunsForTesting()

        let firings = scheduler.firings(for: "a")
        #expect(firings.count == 2)
        #expect(firings.map(\.outcome) == [.failed(exitCode: 2), .succeeded])
        #expect(firings.first?.runs.map(\.runID) == ["run-2"])
        #expect(firings.last?.runs.map(\.runID) == ["run-1"])
        #expect(firings.allSatisfy { !$0.wasManual })
    }

    /// A Run Now is marked as one, because an entry that does not line up with
    /// the trigger is otherwise unexplainable.
    @Test func aManualRunIsRecordedAsManual() async throws {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (scheduler, _) = makeScheduler(store: store, clock: clock)
        scheduler.add(interval("a", seconds: 600, at: clock.now))
        scheduler.runNow(id: "a")
        await scheduler.waitForRunsForTesting()

        #expect(scheduler.firings(for: "a").map(\.wasManual) == [true])
    }

    /// The list is a short history, not an audit log: the file is rewritten
    /// whole on every persist, so it has to stop growing.
    @Test func historyIsBoundedAndDropsTheOldest() async throws {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (scheduler, _) = makeScheduler(store: store, clock: clock)
        scheduler.add(interval("a", seconds: 600, at: clock.now))
        let total = RunScheduleState.maximumRememberedFirings + 5
        for _ in 0..<total {
            clock.advance(605)
            scheduler.evaluate()
            await scheduler.waitForRunsForTesting()
        }

        let firings = scheduler.firings(for: "a")
        #expect(firings.count == RunScheduleState.maximumRememberedFirings)
        // Newest first, so the survivors are the tail of the run, and the
        // oldest firing is gone rather than the newest.
        let firedAt = firings.map(\.firedAt)
        #expect(firedAt == firedAt.sorted(by: >))
    }

    /// "Nothing ran last night" is an answer, and the history has to give it
    /// rather than leave a hole the user has to interpret.
    @Test func aSkippedBatchOfMissedOccurrencesIsRecorded() async throws {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (scheduler, log) = makeScheduler(store: store, clock: clock)
        scheduler.add(interval("a", seconds: 600, policy: .skip, at: clock.now))

        // Three occurrences pass unobserved, well beyond the grace period.
        clock.advance(1_900)
        scheduler.evaluate()
        await scheduler.waitForRunsForTesting()

        #expect(log.fired.isEmpty)
        let firing = try #require(scheduler.firings(for: "a").first)
        #expect(firing.outcome == .skipped(reason: "3 occurrences were missed and skipped."))
        #expect(!firing.wasManual)
        #expect(firing.runs.isEmpty)
        // Nothing ran, so the row's status still describes the last run that
        // did — here, none at all.
        #expect(scheduler.state(for: "a").lastOutcome == nil)
    }

    @Test func historySurvivesRelaunch() async throws {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (first, log) = makeScheduler(store: store, clock: clock)
        log.runs = [.init(worktreeID: "wt-1", branch: "main", runID: "run-1", scriptName: "test.sh")]
        first.add(interval("a", seconds: 600, at: clock.now))
        clock.advance(605)
        first.evaluate()
        await first.waitForRunsForTesting()

        let (second, _) = makeScheduler(store: store, clock: clock)
        let firings = second.firings(for: "a")
        #expect(firings.count == 1)
        #expect(firings.first?.outcome == .succeeded)
        #expect(firings.first?.runs.first?.runID == "run-1")
        #expect(firings.first?.runs.first?.scriptName == "test.sh")
    }

    /// `firings` arrived after the first release. A file written before it
    /// has no such key, and treating that as a decode failure would drop the
    /// whole state — `nextFireAt` included, which re-anchors the schedule.
    @Test func aStateWrittenBeforeHistoryExistedStillDecodes() async throws {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (first, _) = makeScheduler(store: store, clock: clock)
        first.add(interval("a", seconds: 600, at: clock.now))
        clock.advance(605)
        first.evaluate()
        await first.waitForRunsForTesting()
        let expectedNextFire = try #require(first.state(for: "a").nextFireAt)

        let persisted = try #require(store.files[fileURL])
        var object = try #require(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        var states = try #require(object["states"] as? [String: Any])
        var state = try #require(states["a"] as? [String: Any])
        state.removeValue(forKey: "firings")
        states["a"] = state
        object["states"] = states
        store.files[fileURL] = try JSONSerialization.data(withJSONObject: object)

        let (second, log) = makeScheduler(store: store, clock: clock)
        #expect(second.state(for: "a").nextFireAt == expectedNextFire)
        #expect(second.state(for: "a").lastOutcome == .succeeded)
        #expect(second.firings(for: "a").isEmpty)
        // And the recovered timing still holds it back from an instant re-fire.
        second.evaluate()
        await second.waitForRunsForTesting()
        #expect(log.fired.isEmpty)
    }

    /// History is the least important field in the state. One entry a newer
    /// build wrote must cost at most itself, never the timing around it.
    @Test func oneUndecodableFiringDoesNotDiscardTheState() async throws {
        let store = MemoryStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let (first, _) = makeScheduler(store: store, clock: clock)
        first.add(interval("a", seconds: 600, at: clock.now))
        clock.advance(605)
        first.evaluate()
        await first.waitForRunsForTesting()
        let expectedNextFire = try #require(first.state(for: "a").nextFireAt)

        let persisted = try #require(store.files[fileURL])
        var object = try #require(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        var states = try #require(object["states"] as? [String: Any])
        var state = try #require(states["a"] as? [String: Any])
        var firings = try #require(state["firings"] as? [[String: Any]])
        firings.insert(["id": "broken"], at: 0)
        state["firings"] = firings
        states["a"] = state
        object["states"] = states
        store.files[fileURL] = try JSONSerialization.data(withJSONObject: object)

        let (second, _) = makeScheduler(store: store, clock: clock)
        #expect(second.state(for: "a").nextFireAt == expectedNextFire)
        #expect(second.firings(for: "a").map(\.outcome) == [.succeeded])
    }
}
