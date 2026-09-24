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
/// inside it, and the agent is launched on it afterwards: as an ACP chat
/// session when the agent speaks ACP, otherwise in a terminal.
enum RunScheduleAfterExecution: String, Codable, CaseIterable, Hashable, Sendable {
    case keep
    case reportAndCleanupOnSuccess
}

struct RunScheduleComposition: Codable, Equatable, Hashable, Sendable {
    /// Branch name template. Supports `{name}`, `{date}` and `{time}`.
    var branchTemplate: String
    /// Explicit agent, or nil for the project/repo/global default.
    var agentId: String?
    /// Model the chat session is switched to before the prompt goes out, or
    /// nil for the agent's own default. Only meaningful for an ACP-capable
    /// agent; a terminal launch has no channel to ask for one.
    var modelId: String?
    /// Handed to the agent once it is up: queued as the first message of a
    /// chat session, or typed into the terminal. Nil means the agent just
    /// opens and waits.
    var prompt: String?
    /// Whether the prompt is submitted as soon as it is delivered, or left in
    /// the agent's input for the user to send. Meaningless without `prompt`.
    var sendsPromptAutomatically: Bool
    /// Whether this schedule retains its execution resources or requests
    /// report-backed cleanup after an explicitly successful ACP completion.
    var afterExecution: RunScheduleAfterExecution

    static let defaultBranchTemplate = "scheduled/{name}-{date}-{time}"

    init(
        branchTemplate: String = RunScheduleComposition.defaultBranchTemplate,
        agentId: String? = nil,
        modelId: String? = nil,
        prompt: String? = nil,
        sendsPromptAutomatically: Bool = true,
        afterExecution: RunScheduleAfterExecution = .keep
    ) {
        self.branchTemplate = branchTemplate
        self.agentId = agentId
        self.modelId = modelId
        self.prompt = prompt
        self.sendsPromptAutomatically = sendsPromptAutomatically
        self.afterExecution = afterExecution
    }

    /// The prompt as keystrokes for the agent's terminal.
    ///
    /// Line breaks become spaces: typed into a TUI a newline is Enter, which
    /// would split the prompt into several messages, or submit half of one.
    ///
    /// Every other control character is dropped, and a tab becomes a space.
    /// These bytes go straight to the PTY, where they are input rather than
    /// text: a tab triggers completion, and an escape can leave the input
    /// altogether and turn what follows into key bindings. A prompt that is
    /// then submitted automatically would be sending something other than
    /// what was written.
    static func terminalText(for prompt: String) -> String {
        prompt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { line in
                let scalars = line.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
                    if scalar == "\t" { return " " }
                    return scalar.properties.generalCategory == .control ? nil : scalar
                }
                return String(String.UnicodeScalarView(scalars))
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case branchTemplate, agentId, modelId, prompt, sendsPromptAutomatically, afterExecution
    }

    /// Hand-written because fields are added after the first release. An older
    /// file must decode or the lenient per-schedule decoder drops the schedule.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        branchTemplate = try c.decodeIfPresent(String.self, forKey: .branchTemplate) ?? Self.defaultBranchTemplate
        agentId = try c.decodeIfPresent(String.self, forKey: .agentId)
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        sendsPromptAutomatically = try c.decodeIfPresent(Bool.self, forKey: .sendsPromptAutomatically) ?? true
        afterExecution = try c.decodeIfPresent(RunScheduleAfterExecution.self, forKey: .afterExecution) ?? .keep
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

    /// Reason text for the history entry a skipped batch leaves behind, so
    /// "nothing ran last night" reads as a recorded decision rather than a
    /// hole in the list.
    var skippedReason: String {
        count == 1
            ? "1 occurrence was missed and skipped."
            : "\(count) occurrences were missed and skipped."
    }
}

/// One entry in a schedule's history: an occurrence that was dispatched, or
/// one that was deliberately not.
///
/// Transcripts are deliberately absent. A firing that started a script points
/// at that run instead, because `RunHistoryStore` already owns the durable
/// output and already bounds and purges it per worktree; duplicating it here
/// would mean two copies with two different retention rules.
struct RunScheduleFiring: Codable, Identifiable, Equatable, Hashable, Sendable {
    /// Where a run this firing started can be found. Branch and script name
    /// are copied because the row has to stay readable after the worktree or
    /// the script file is gone, even though the report itself is then absent.
    struct RunReference: Codable, Equatable, Hashable, Sendable {
        let worktreeID: String
        let branch: String
        let runID: String
        let scriptName: String
    }

    let id: String
    /// When the occurrence was dispatched, not when it settled.
    let firedAt: Date
    let finishedAt: Date
    /// A Run Now rather than the clock. Kept because a manual run explains an
    /// entry that does not line up with the trigger.
    let wasManual: Bool
    let outcome: RunScheduleOutcome
    let runs: [RunReference]
    /// Durable scheduled-agent reports. Unlike script run references, these
    /// remain openable after their execution worktree has been removed.
    let reportIDs: [String]

    init(
        id: String = UUID().uuidString,
        firedAt: Date,
        finishedAt: Date,
        wasManual: Bool,
        outcome: RunScheduleOutcome,
        runs: [RunReference] = [],
        reportIDs: [String] = []
    ) {
        self.id = id
        self.firedAt = firedAt
        self.finishedAt = finishedAt
        self.wasManual = wasManual
        self.outcome = outcome
        self.runs = runs
        self.reportIDs = reportIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, firedAt, finishedAt, wasManual, outcome, runs, reportIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        firedAt = try c.decode(Date.self, forKey: .firedAt)
        finishedAt = try c.decode(Date.self, forKey: .finishedAt)
        wasManual = try c.decode(Bool.self, forKey: .wasManual)
        outcome = try c.decode(RunScheduleOutcome.self, forKey: .outcome)
        runs = try c.decodeIfPresent([RunReference].self, forKey: .runs) ?? []
        reportIDs = try c.decodeIfPresent([String].self, forKey: .reportIDs) ?? []
    }

    var duration: TimeInterval { finishedAt.timeIntervalSince(firedAt) }
}

/// What one firing produced. The outcome is what the row shows; the runs and
/// report IDs are what its history entry links to.
struct RunScheduleRunReport: Equatable, Sendable {
    var outcome: RunScheduleOutcome
    var runs: [RunScheduleFiring.RunReference]
    var reportIDs: [String]

    init(
        outcome: RunScheduleOutcome,
        runs: [RunScheduleFiring.RunReference] = [],
        reportIDs: [String] = []
    ) {
        self.outcome = outcome
        self.runs = runs
        self.reportIDs = reportIDs
    }
}


struct RunScheduleState: Codable, Equatable, Hashable, Sendable {
    /// How many firings one schedule remembers. A short history, not an audit
    /// log: this file is rewritten whole on every persist, and the durable
    /// per-run record lives in `RunHistoryStore`.
    static let maximumRememberedFirings = 20

    var lastFiredAt: Date?
    var nextFireAt: Date?
    var lastOutcome: RunScheduleOutcome?
    var lastOutcomeAt: Date?
    var lastMissed: RunScheduleMissedOccurrences?
    /// The zone `nextFireAt` was computed in. A time-of-day trigger is a
    /// wall-clock time, so the stored instant stops meaning "09:00" once the
    /// user changes time zone and has to be recomputed.
    var timeZoneIdentifier: String?
    /// Most recently settled first, bounded by `maximumRememberedFirings`.
    /// Settlement rather than dispatch, because a long run that started
    /// before a later occurrence was refused still finishes after it.
    var firings: [RunScheduleFiring]

    init(
        lastFiredAt: Date? = nil,
        nextFireAt: Date? = nil,
        lastOutcome: RunScheduleOutcome? = nil,
        lastOutcomeAt: Date? = nil,
        lastMissed: RunScheduleMissedOccurrences? = nil,
        timeZoneIdentifier: String? = nil,
        firings: [RunScheduleFiring] = []
    ) {
        self.lastFiredAt = lastFiredAt
        self.nextFireAt = nextFireAt
        self.lastOutcome = lastOutcome
        self.lastOutcomeAt = lastOutcomeAt
        self.lastMissed = lastMissed
        self.timeZoneIdentifier = timeZoneIdentifier
        self.firings = firings
    }

    /// Prepends a firing and drops the oldest beyond the cap.
    mutating func record(_ firing: RunScheduleFiring) {
        firings.insert(firing, at: 0)
        if firings.count > Self.maximumRememberedFirings {
            firings.removeLast(firings.count - Self.maximumRememberedFirings)
        }
    }

    enum CodingKeys: String, CodingKey {
        case lastFiredAt, nextFireAt, lastOutcome, lastOutcomeAt, lastMissed, timeZoneIdentifier, firings
    }

    /// Decodes one firing without letting its failure sink the array.
    private struct LenientFiring: Decodable {
        let firing: RunScheduleFiring?

        init(from decoder: Decoder) throws {
            firing = try? RunScheduleFiring(from: decoder)
        }
    }

    /// Written by hand because `firings` arrived after the first release and
    /// synthesized decoding ignores property defaults: an older file has no
    /// such key, and treating that as a decode failure would drop the whole
    /// state — including `nextFireAt`, whose loss re-anchors the schedule.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastFiredAt = try c.decodeIfPresent(Date.self, forKey: .lastFiredAt)
        nextFireAt = try c.decodeIfPresent(Date.self, forKey: .nextFireAt)
        lastOutcome = try c.decodeIfPresent(RunScheduleOutcome.self, forKey: .lastOutcome)
        lastOutcomeAt = try c.decodeIfPresent(Date.self, forKey: .lastOutcomeAt)
        lastMissed = try c.decodeIfPresent(RunScheduleMissedOccurrences.self, forKey: .lastMissed)
        timeZoneIdentifier = try c.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        // Per entry, and never fatal: history is the least important thing in
        // this struct and must not cost the timing fields around it.
        firings = ((try? c.decode([LenientFiring].self, forKey: .firings)) ?? [])
            .compactMap(\.firing)
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
