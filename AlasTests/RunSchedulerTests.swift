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
        var gate: CheckedContinuation<Void, Never>?
        var holdsRuns = false
    }

    private let fileURL = URL(fileURLWithPath: "/memory/run-schedules.json")
    private let calendar = Calendar(identifier: .gregorian)

    private func makeScheduler(
        store: MemoryStore,
        clock: Clock,
        log: RunLog = RunLog()
    ) -> (RunScheduler, RunLog) {
        let scheduler = RunScheduler(
            store: store,
            fileURL: fileURL,
            now: { clock.now },
            calendar: calendar,
            tickInterval: 30,
            grace: 120
        )
        scheduler.runner = { schedule, invocation in
            log.fired.append(schedule.id)
            log.invocations.append(invocation)
            if log.holdsRuns {
                await withCheckedContinuation { continuation in
                    log.gate = continuation
                }
            }
            return log.outcome
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
        let (first, _) = makeScheduler(store: store, clock: clock)
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
        var object = try #require(
            JSONSerialization.jsonObject(with: try #require(store.files[fileURL])) as? [String: Any]
        )
        var schedules = try #require(object["schedules"] as? [[String: Any]])
        schedules.insert(["id": "broken", "name": "Broken"], at: 1)
        object["schedules"] = schedules
        store.files[fileURL] = try JSONSerialization.data(withJSONObject: object)

        let (second, _) = makeScheduler(store: store, clock: clock)
        #expect(second.schedules.map(\.id) == ["keep-1", "keep-2"])
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

        log.holdsRuns = false
        log.gate?.resume()
        await scheduler.waitForRunsForTesting()
        #expect(scheduler.isRunning(scheduler.schedule(id: "a")!) == false)
        #expect(scheduler.state(for: "a").lastOutcome == .succeeded)
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
}
