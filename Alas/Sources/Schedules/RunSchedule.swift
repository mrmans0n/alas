import Foundation

/// Where a schedule's script runs. Resolved against live projects/worktrees
/// at fire time, so a schedule outlives worktree churn and reports when its
/// target has gone away instead of silently doing nothing.
enum RunScheduleTarget: Codable, Equatable, Hashable, Sendable {
    /// The main worktree of every project.
    case allProjects
    /// A project's main worktree.
    case project(id: String)
    /// One specific worktree.
    case worktree(projectId: String, worktreeId: String)

    var projectID: String? {
        switch self {
        case .allProjects: nil
        case .project(let id): id
        case .worktree(let projectId, _): projectId
        }
    }
}

enum RunScheduleTrigger: Codable, Equatable, Hashable, Sendable {
    /// Fires `seconds` after the previous fire (or after creation).
    case interval(seconds: TimeInterval)
    /// Fires at a local wall-clock time on the given weekdays
    /// (`Calendar` numbering: 1 = Sunday … 7 = Saturday). An empty set means
    /// every day.
    case timeOfDay(hour: Int, minute: Int, weekdays: Set<Int>)

    static let minimumIntervalSeconds: TimeInterval = 60
}

/// What happens when occurrences were missed because the app was quit, the
/// machine was asleep, or the schedule was otherwise not evaluated in time.
/// Why a schedule is running right now. A per-project pause silences the
/// clock but not an explicit Run Now, the same way it does for a schedule
/// that names one project.
enum RunScheduleInvocation: Equatable, Sendable {
    case scheduled
    case manual

    var honorsProjectPauses: Bool { self == .scheduled }
}

enum RunScheduleMissedRunPolicy: String, Codable, CaseIterable, Sendable {
    /// Drop every missed occurrence and wait for the next one.
    case skip
    /// Run once now for the latest missed occurrence; never one per miss.
    case runLatest
}

/// Optional "new worktree + agent" step. The worktree is created through the
/// standard creation path (worktree-create script included), the script runs
/// inside it, and the agent is launched in a terminal on it afterwards.
struct RunScheduleComposition: Codable, Equatable, Hashable, Sendable {
    /// Branch name template. Supports `{name}`, `{date}` and `{time}`.
    var branchTemplate: String
    /// Explicit agent, or nil for the project/repo/global default.
    var agentId: String?

    static let defaultBranchTemplate = "scheduled/{name}-{date}-{time}"

    init(branchTemplate: String = RunScheduleComposition.defaultBranchTemplate, agentId: String? = nil) {
        self.branchTemplate = branchTemplate
        self.agentId = agentId
    }
}

struct RunSchedule: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: String
    var name: String
    var target: RunScheduleTarget
    /// `RunScript.key` (`repo:file` / `global:file`). Nil is only valid when
    /// `composition` is set: the schedule then just opens a worktree with an
    /// agent.
    var scriptKey: String?
    var trigger: RunScheduleTrigger
    var missedRunPolicy: RunScheduleMissedRunPolicy
    var composition: RunScheduleComposition?
    var isEnabled: Bool
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        target: RunScheduleTarget,
        scriptKey: String?,
        trigger: RunScheduleTrigger,
        missedRunPolicy: RunScheduleMissedRunPolicy = .skip,
        composition: RunScheduleComposition? = nil,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.target = target
        self.scriptKey = scriptKey
        self.trigger = trigger
        self.missedRunPolicy = missedRunPolicy
        self.composition = composition
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    /// A schedule has to do *something*: run a script, open a worktree with
    /// an agent, or both.
    var hasAction: Bool { scriptKey != nil || composition != nil }
}

/// The result of one scheduled firing, as remembered on the schedule row.
/// Script outcomes mirror `RunOutcome`; the extra cases cover the steps that
/// happen before or after the script itself.
enum RunScheduleOutcome: Codable, Equatable, Hashable, Sendable {
    case succeeded
    case failed(exitCode: Int32)
    case stopped
    case unknown
    /// Nothing ran, and the reason is benign (already running, target gone).
    case skipped(reason: String)
    /// Worktree creation, script launch, or agent launch did not happen.
    case launchFailed(String)

    init(_ outcome: RunOutcome) {
        switch outcome {
        case .succeeded: self = .succeeded
        case .failed(let exitCode): self = .failed(exitCode: exitCode)
        case .stopped: self = .stopped
        case .unknown: self = .unknown
        }
    }

    var isFailure: Bool {
        switch self {
        case .succeeded, .skipped: false
        case .failed, .stopped, .unknown, .launchFailed: true
        }
    }

    /// Worst-of for fan-out targets: any failure beats a skip, which beats
    /// success, so the row never claims more than what actually happened.
    static func combined(_ outcomes: [RunScheduleOutcome]) -> RunScheduleOutcome {
        guard !outcomes.isEmpty else { return .skipped(reason: "No targets to run.") }
        if let failure = outcomes.first(where: \.isFailure) { return failure }
        if let skipped = outcomes.first(where: { if case .skipped = $0 { return true } else { return false } }) {
            return skipped
        }
        return .succeeded
    }
}

/// Occurrences that were due but not run one-by-one, and what was done
/// about them. Kept so the row can say "3 missed, ran the latest" instead of
/// pretending nothing happened.
struct RunScheduleMissedOccurrences: Codable, Equatable, Hashable, Sendable {
    let count: Int
    let policy: RunScheduleMissedRunPolicy
    let observedAt: Date
}

struct RunScheduleState: Codable, Equatable, Hashable, Sendable {
    var lastFiredAt: Date?
    var nextFireAt: Date?
    var lastOutcome: RunScheduleOutcome?
    var lastOutcomeAt: Date?
    var lastMissed: RunScheduleMissedOccurrences?

    init(
        lastFiredAt: Date? = nil,
        nextFireAt: Date? = nil,
        lastOutcome: RunScheduleOutcome? = nil,
        lastOutcomeAt: Date? = nil,
        lastMissed: RunScheduleMissedOccurrences? = nil
    ) {
        self.lastFiredAt = lastFiredAt
        self.nextFireAt = nextFireAt
        self.lastOutcome = lastOutcome
        self.lastOutcomeAt = lastOutcomeAt
        self.lastMissed = lastMissed
    }
}

/// A stretch of time during which no schedule could be evaluated.
struct RunScheduleGap: Codable, Equatable, Hashable, Sendable {
    enum Reason: String, Codable, Sendable {
        /// The process was alive but the machine slept (or the run loop was
        /// otherwise starved long enough that ticks stopped).
        case asleep
        /// Alas was not running at all.
        case appNotRunning
    }

    let start: Date
    let end: Date
    let reason: Reason

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct RunSchedulesFile: Codable, Equatable, Sendable {
    var version: Int = 1
    var schedules: [RunSchedule] = []
    var states: [String: RunScheduleState] = [:]
    var pausedProjectIDs: Set<String> = []
    var isPausedGlobally: Bool = false
    /// Last moment the scheduler looked at its schedules. On the next launch
    /// the distance from here to now is the "Alas was not running" gap.
    var lastEvaluatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case version, schedules, states, pausedProjectIDs, isPausedGlobally, lastEvaluatedAt
    }

    init() {}

    /// Decodes one schedule without letting its failure sink the array.
    private struct LenientSchedule: Decodable {
        let schedule: RunSchedule?

        init(from decoder: Decoder) throws {
            schedule = try? RunSchedule(from: decoder)
        }
    }

    /// Same idea for one schedule's remembered timing and outcome.
    private struct LenientState: Decodable {
        let state: RunScheduleState?

        init(from decoder: Decoder) throws {
            state = try? RunScheduleState(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        // Per entry, not per array: one schedule written by a newer build (an
        // unknown trigger case, say) must not read as "the user has no
        // schedules" and then be persisted over the ones that still decode.
        schedules = ((try? c.decode([LenientSchedule].self, forKey: .schedules)) ?? [])
            .compactMap(\.schedule)
        // Also per entry: losing every schedule's `nextFireAt` would re-anchor
        // them on `createdAt`, which makes a `runLatest` schedule believe it
        // has a huge backlog and fire the moment the app starts.
        states = ((try? c.decode([String: LenientState].self, forKey: .states)) ?? [:])
            .compactMapValues(\.state)
        pausedProjectIDs = (try? c.decode(Set<String>.self, forKey: .pausedProjectIDs)) ?? []
        isPausedGlobally = (try? c.decode(Bool.self, forKey: .isPausedGlobally)) ?? false
        lastEvaluatedAt = try? c.decode(Date.self, forKey: .lastEvaluatedAt)
    }
}

extension Paths {
    static var runSchedulesFile: URL {
        appSupportRoot.appendingPathComponent("run-schedules.json")
    }
}
