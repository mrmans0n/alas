import Foundation
import Observation
import AlasFoundation
import AlasModel
import AlasPlatform

private let shipReviewLogger = Logger(subsystem: "io.nlopez.alas", category: "ShipReviewer")

/// The ship reviews on disk, at `Paths.shipReviewsFile`. Decoded per record,
/// like `ReviewShepherdsFile`: one record a newer build wrote must not read
/// as "no records" and then be persisted over the ones that still decode.
public struct ShipReviewsFile: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var records: [ShipReviewRecord] = []

    public enum CodingKeys: String, CodingKey, Sendable {
        case version, records
    }

    public init(records: [ShipReviewRecord] = []) {
        self.records = records
    }

    private struct LenientRecord: Decodable {
        let record: ShipReviewRecord?

        init(from decoder: Decoder) throws {
            record = try? ShipReviewRecord(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        records = ((try? c.decode([LenientRecord].self, forKey: .records)) ?? []).compactMap(\.record)
    }
}

/// The git reads a review round makes. `live` runs git in the worktree, over
/// ssh for a remote one.
public struct ShipReviewGit: Sendable {
    public var headSHA: @Sendable (_ path: URL) async throws -> String
    public var mergeBase: @Sendable (_ path: URL, _ base: String, _ head: String) async throws -> String
    /// `git diff --no-color base...head`.
    public var diff: @Sendable (_ path: URL, _ base: String, _ head: String) async throws -> String

    public init(
        headSHA: @escaping @Sendable (_ path: URL) async throws -> String,
        mergeBase: @escaping @Sendable (_ path: URL, _ base: String, _ head: String) async throws -> String,
        diff: @escaping @Sendable (_ path: URL, _ base: String, _ head: String) async throws -> String
    ) {
        self.headSHA = headSHA
        self.mergeBase = mergeBase
        self.diff = diff
    }

    public static let live = ShipReviewGit(
        headSHA: { path in
            try await firstLine(of: ["rev-parse", "--verify", "HEAD^{commit}"], in: path, op: "rev-parse")
        },
        mergeBase: { path, base, head in
            try await firstLine(of: ["merge-base", base, head], in: path, op: "merge-base")
        },
        diff: { path, base, head in
            let result = try await Process.git(["diff", "--no-color", "\(base)...\(head)"], cwd: path, timeout: 120)
            try GitService.assertSuccess(result, op: "diff")
            return result.stdout
        }
    )

    private static func firstLine(of args: [String], in path: URL, op: String) async throws -> String {
        let result = try await Process.git(args, cwd: path)
        try GitService.assertSuccess(result, op: op)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Review before push. Owns one `ShipReviewRecord` per owning session,
/// persisted in `ship-reviews.json`, and runs its rounds: a read-only
/// reviewer session reviews the local commits, findings go to the owning
/// session, and a clean or allowed head is pushed through `Effects.push`.
/// `ShipReviewPolicy` decides; `effects` (installed by `AlasCoreContext`)
/// reach git, the reviewer, the review pane and the publish path.
@MainActor
@Observable
public final class ShipReviewer {
    /// What a round needs from the worktree.
    public struct Context: Sendable {
        public let worktreePath: URL
        public let branch: String
        /// The base the review diffs against when the push names none.
        public let baseBranch: String
        /// "GitHub", for the review line.
        public let providerName: String
        public let projectSettings: ProjectCodeReviewSettings?

        public init(
            worktreePath: URL, branch: String, baseBranch: String, providerName: String,
            projectSettings: ProjectCodeReviewSettings?
        ) {
            self.worktreePath = worktreePath
            self.branch = branch
            self.baseBranch = baseBranch
            self.providerName = providerName
            self.projectSettings = projectSettings
        }
    }

    /// One reviewer turn. `reuseSessionID` is the reviewer of this push's
    /// earlier rounds, which remembers their findings.
    public struct ReviewerRun: Sendable {
        public let id: ShipReviewID
        public let reviewer: ResolvedReviewer
        public let reuseSessionID: String?
        public let prompt: String

        public init(id: ShipReviewID, reviewer: ResolvedReviewer, reuseSessionID: String?, prompt: String) {
            self.id = id
            self.reviewer = reviewer
            self.reuseSessionID = reuseSessionID
            self.prompt = prompt
        }
    }

    /// How a reviewer turn ended. `reason` reads after "Review didn't finish: ".
    public enum ReviewerOutcome: Equatable, Sendable {
        case finished(sessionID: String, finalText: String)
        case failed(sessionID: String?, reason: String)

        public var sessionID: String? {
            switch self {
            case let .finished(sessionID, _): sessionID
            case let .failed(sessionID, _): sessionID
            }
        }
    }

    /// A round's result, filed in the review pane on `target`.
    public struct Filing: Sendable {
        public let id: ShipReviewID
        public let round: Int
        public let baseSHA: String
        public let headSHA: String
        /// `base...head`, pinned to the reviewed SHA.
        public let target: ReviewSessionTarget
        public let reviewerLabel: String
        public let result: CodeReviewResult
        /// The comment id for each of `result.findings`, in order.
        public let findingIDs: [String]
        /// This push's earlier rounds: `result.resolvedIDs` are resolved in
        /// them, and on a clean result every finding still open there.
        public let earlierRoundSessionIDs: [ReviewSessionID]

        public init(
            id: ShipReviewID, round: Int, baseSHA: String, headSHA: String, target: ReviewSessionTarget,
            reviewerLabel: String, result: CodeReviewResult, findingIDs: [String], earlierRoundSessionIDs: [ReviewSessionID]
        ) {
            self.id = id
            self.round = round
            self.baseSHA = baseSHA
            self.headSHA = headSHA
            self.target = target
            self.reviewerLabel = reviewerLabel
            self.result = result
            self.findingIDs = findingIDs
            self.earlierRoundSessionIDs = earlierRoundSessionIDs
        }
    }

    public struct Effects {
        /// Nil when the worktree is gone.
        public var context: @MainActor (_ worktreeID: String) -> Context?
        public var settings: @MainActor () -> (review: CodeReviewSettings, defaults: ShepherdDefaults)
        public var ownerAgentID: @MainActor (_ id: ShipReviewID) -> String?
        /// Nil when the agent isn't installed, enabled or ACP-capable; else
        /// "Codex · gpt-5.2", or "Codex" for its default model.
        public var agentLabel: @MainActor (_ reviewer: ResolvedReviewer) -> String?
        public var git: ShipReviewGit
        /// Throws when a file exists but can't be read.
        public var instructions: @MainActor (_ path: URL, _ project: String?) async throws -> CodeReviewInstructions
        public var runReviewer: @MainActor (ReviewerRun) async -> ReviewerOutcome
        public var discardReviewer: @MainActor (_ id: ShipReviewID, _ sessionID: String) async -> Void
        public var earlierFindings: @MainActor (_ reviewSessionIDs: [ReviewSessionID]) -> [CodeReviewEarlierFinding]
        /// Findings still active in the review session; nil when it can't be read.
        public var openFindingCount: @MainActor (_ reviewSessionID: ReviewSessionID) -> Int?
        /// Files the round and returns its review session.
        public var fileRound: @MainActor (Filing) throws -> ReviewSessionID
        public var deliverFindings: @MainActor (_ id: ShipReviewID, _ prompt: ShepherdPrompt) async -> ReviewShepherd.Delivery
        /// Nil on success, else why the push failed.
        public var push: @MainActor (_ id: ShipReviewID, _ target: ShipReviewTarget, _ headSHA: String) async -> String?
        public var autoFix: @MainActor (_ id: ShipReviewID) -> Bool
        /// HEAD when it is ahead of the bound request's remote head branch, else nil.
        public var localCommitsToPush: @MainActor (_ id: ShipReviewID) async -> String?
        public var notify: @MainActor (_ id: ShipReviewID, _ stop: ShipReviewStop) -> Void
        /// The head the pending push would ship now, which a round's result
        /// must still describe: HEAD, or for a stack the top entry its plan
        /// publishes. Defaults to HEAD.
        public var shipHead: @MainActor (_ id: ShipReviewID, _ target: ShipReviewTarget?) async throws -> String

        public init(
            context: @escaping @MainActor (_ worktreeID: String) -> Context?,
            settings: @escaping @MainActor () -> (review: CodeReviewSettings, defaults: ShepherdDefaults),
            ownerAgentID: @escaping @MainActor (_ id: ShipReviewID) -> String?,
            agentLabel: @escaping @MainActor (_ reviewer: ResolvedReviewer) -> String?,
            git: ShipReviewGit,
            instructions: @escaping @MainActor (_ path: URL, _ project: String?) async throws -> CodeReviewInstructions,
            runReviewer: @escaping @MainActor (ReviewerRun) async -> ReviewerOutcome,
            discardReviewer: @escaping @MainActor (_ id: ShipReviewID, _ sessionID: String) async -> Void,
            earlierFindings: @escaping @MainActor (_ reviewSessionIDs: [ReviewSessionID]) -> [CodeReviewEarlierFinding],
            openFindingCount: @escaping @MainActor (_ reviewSessionID: ReviewSessionID) -> Int?,
            fileRound: @escaping @MainActor (Filing) throws -> ReviewSessionID,
            deliverFindings: @escaping @MainActor (_ id: ShipReviewID, _ prompt: ShepherdPrompt) async -> ReviewShepherd.Delivery,
            push: @escaping @MainActor (_ id: ShipReviewID, _ target: ShipReviewTarget, _ headSHA: String) async -> String?,
            autoFix: @escaping @MainActor (_ id: ShipReviewID) -> Bool,
            localCommitsToPush: @escaping @MainActor (_ id: ShipReviewID) async -> String?,
            notify: @escaping @MainActor (_ id: ShipReviewID, _ stop: ShipReviewStop) -> Void,
            shipHead: (@MainActor (_ id: ShipReviewID, _ target: ShipReviewTarget?) async throws -> String)? = nil
        ) {
            self.context = context
            self.settings = settings
            self.ownerAgentID = ownerAgentID
            self.agentLabel = agentLabel
            self.git = git
            self.instructions = instructions
            self.runReviewer = runReviewer
            self.discardReviewer = discardReviewer
            self.earlierFindings = earlierFindings
            self.openFindingCount = openFindingCount
            self.fileRound = fileRound
            self.deliverFindings = deliverFindings
            self.push = push
            self.autoFix = autoFix
            self.localCommitsToPush = localCommitsToPush
            self.notify = notify
            self.shipHead = shipHead ?? { id, _ in
                guard let path = context(id.worktreeID)?.worktreePath else { throw ShipReviewFailure.reviewer("the worktree is gone") }
                return try await git.headSHA(path)
            }
        }
    }

    /// What a push request may do now.
    public enum Gate: Equatable, Sendable {
        /// The caller pushes: the lever is off or the head passed.
        case push
        /// Held back; Alas pushes once the review passes.
        case reviewing(ShipReviewRecord)
    }

    /// Idle records with nothing pending are dropped this long after their last change.
    public static let idleLifetime: TimeInterval = 30 * 24 * 60 * 60

    @ObservationIgnored public var effects: Effects?
    public private(set) var records: [ShipReviewID: ShipReviewRecord] = [:]

    @ObservationIgnored private let store: any PersistenceStoreProtocol
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var started = false
    /// Bumped by every round started and every stop. A round's result counts
    /// only while its record keeps the generation it started with.
    @ObservationIgnored private var generations: [ShipReviewID: Int] = [:]
    @ObservationIgnored private var lastGeneration = 0
    @ObservationIgnored private var roundTasks: [ShipReviewID: Task<Void, Never>] = [:]
    /// Rounds, pushes and deliveries in flight, for `settle()`.
    @ObservationIgnored private var inFlight: [UUID: Task<Void, Never>] = [:]
    /// A turn the owner ends while its findings are still on their way is
    /// not the fix turn.
    @ObservationIgnored private var deliveringFindings: Set<ShipReviewID> = []
    @ObservationIgnored private var checkingPushedHead: Set<ShipReviewID> = []

    public init(
        store: any PersistenceStoreProtocol,
        fileURL: URL = Paths.shipReviewsFile,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.store = store
        self.fileURL = fileURL
        self.now = now
        load()
    }

    // MARK: - Lifecycle

    /// Restarts each round that was running when Alas quit, with a fresh
    /// reviewer and uncounted, and retries an interrupted push. Once per run.
    public func start() {
        guard !started else { return }
        started = true
        for record in records.values.sorted(by: { $0.createdAt < $1.createdAt }) {
            let (next, action) = ShipReviewPolicy.relaunched(record, now: now())
            if next != record { put(next) }
            execute(action, for: record.id)
        }
    }

    /// Ends the running reviewer turns. Their records stay as they are, so
    /// the next `start()` restarts them; pushes underway finish.
    public func stop() {
        started = false
        for id in Array(roundTasks.keys) {
            endRound(id)
        }
    }

    /// Waits for the rounds, pushes and deliveries in flight, and for any
    /// they start.
    public func settle() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    // MARK: - Queries

    public func record(for id: ShipReviewID) -> ShipReviewRecord? {
        records[id]
    }

    /// The shepherd's view of the session's review; nil when the lever is off.
    public func reviewGate(worktreeID: String, sessionID: String) -> ShepherdReviewGate? {
        guard let record = records[ShipReviewID(worktreeID: worktreeID, sessionID: sessionID)], record.enabled else { return nil }
        let reviewing = switch record.phase {
        case .reviewing, .awaitingFix: true
        case .idle, .pushing, .stopped: false
        }
        return ShepherdReviewGate(passedSHAs: Set(record.passedSHAs), reviewing: reviewing)
    }

    /// The `review` object `pr_create` and `pr_status` report; nil when the lever is off.
    public func wire(for id: ShipReviewID) -> ShipReviewWire? {
        guard let record = records[id], record.enabled else { return nil }
        let reviewer = resolvedReviewer(record).map { resolved in
            resolved.modelID.map { "\(resolved.agentID)/\($0)" } ?? resolved.agentID
        }
        return ShipReviewWire(record: record, reviewer: reviewer ?? "", openFindings: openFindings(record))
    }

    // MARK: - Requests and controls

    /// A push Alas is about to make. Seeds a missing record from the Settings
    /// defaults. Starts or keeps a round, or says to push now; this call never
    /// pushes. A request made while a round runs on the same head only
    /// updates the pending push.
    public func requestPush(_ id: ShipReviewID, target: ShipReviewTarget, headSHA: String) -> Gate {
        guard let current = records[id] ?? seededRecord(id) else { return .push }
        let (next, action) = ShipReviewPolicy.requestPush(current, target: target, headSHA: headSHA, now: now())
        put(next)
        if case .push = action { return .push }
        execute(action, for: id)
        return .reviewing(records[id] ?? next)
    }

    /// The Ship popover's choice for this ship, stored before the create prompt goes out.
    public func prepare(_ id: ShipReviewID, enabled: Bool, reviewer: ReviewerChoice?) {
        update(id) {
            $0.enabled = enabled
            $0.reviewer = reviewer
        }
    }

    public func setEnabled(_ on: Bool, for id: ShipReviewID) {
        update(id) { $0.enabled = on }
    }

    public func setReviewer(_ choice: ReviewerChoice?, for id: ShipReviewID) {
        update(id) { $0.reviewer = choice }
    }

    /// The owning session's turn ended. Findings it was sent: a new commit
    /// starts the next round, none pushes only if every finding was resolved.
    /// With nothing under review, fix commits ahead of the request's remote
    /// branch are reviewed and pushed by Alas.
    public func ownerTurnCompleted(sessionID: String) {
        for record in records.values where record.id.sessionID == sessionID && !deliveringFindings.contains(record.id) {
            let id = record.id
            switch record.phase {
            case .awaitingFix:
                spawn { [weak self] in await self?.ownerTurnEnded(id) }
            case .idle where record.enabled:
                spawn { [weak self] in await self?.pickUpLocalCommits(id) }
            case .idle, .reviewing, .pushing, .stopped:
                break
            }
        }
    }

    /// "Ship anyway", "Ship without review" and "Allow": `headSHA` passes,
    /// and a pending push goes out.
    public func allow(_ id: ShipReviewID, headSHA: String) {
        guard let record = records[id] else { return }
        if record.pending != nil { endRound(id) }
        let (next, action) = ShipReviewPolicy.allow(record, headSHA: headSHA, now: now())
        put(next)
        execute(action, for: id)
    }

    /// Reviews HEAD again after a stop, or retries a failed push of a head that passed.
    public func retry(_ id: ShipReviewID) {
        guard let record = records[id], case .stopped = record.phase else { return }
        spawn { [weak self] in
            guard let self, let head = await localHead(id),
                  let current = records[id], case .stopped = current.phase
            else { return }
            reviewOrPush(id, target: current.pending ?? .pushedHead, headSHA: head)
        }
    }

    /// "Stop": the review ends and nothing is pushed.
    public func cancel(_ id: ShipReviewID) {
        guard var record = records[id] else { return }
        halt(&record)
        put(record)
    }

    /// "Send to session" after a stop: the current round's open findings go
    /// to the owning session, which then fixes them as in an auto-fix round.
    public func sendFindings(_ id: ShipReviewID) {
        guard let record = records[id], case .stopped = record.phase,
              let round = record.currentRound, round.reviewedAt != nil, let reviewSessionID = round.reviewSessionID
        else { return }
        let generation = bumpGeneration(id)
        deliveringFindings.insert(id)
        spawn { [weak self] in
            guard let self else { return }
            guard let prompt = await resentFindingsPrompt(record, round: round, reviewSessionID: reviewSessionID),
                  isCurrent(id, generation), var current = records[id], case .stopped = current.phase
            else {
                deliveringFindings.remove(id)
                return
            }
            current.phase = .awaitingFix(headSHA: round.headSHA)
            current.updatedAt = now()
            put(current)
            await deliverFindings(id, prompt: prompt, headSHA: round.headSHA, generation: generation)
        }
    }

    /// The findings prompt for `round`, rebuilt from its findings still open in the pane.
    private func resentFindingsPrompt(
        _ record: ShipReviewRecord,
        round: ShipReviewRound,
        reviewSessionID: ReviewSessionID
    ) async -> ShepherdPrompt? {
        guard let effects, let context = effects.context(record.id.worktreeID) else { return nil }
        let open = effects.earlierFindings([reviewSessionID])
        guard !open.isEmpty else { return nil }
        let base = record.pending?.reviewBase ?? context.baseBranch
        var forkPoint = try? await effects.git.mergeBase(context.worktreePath, "origin/\(base)", round.headSHA)
        if forkPoint == nil {
            forkPoint = try? await effects.git.mergeBase(context.worktreePath, base, round.headSHA)
        }
        guard let forkPoint else { return nil }
        let result = CodeReviewResult(
            verdict: round.verdict ?? .requestChanges,
            summary: round.summary ?? "",
            findings: open.map { finding in
                CodeReviewFinding(
                    path: finding.path,
                    anchor: finding.line.map { .line(start: $0, end: $0) } ?? .file,
                    body: finding.body
                )
            },
            resolvedIDs: []
        )
        return ShipReviewPromptBuilder.findings(
            result: result, findingIDs: open.map(\.id), reviewerLabel: round.reviewerLabel,
            branch: context.branch, base: base, headSHA: round.headSHA,
            round: round.number, maxRounds: record.maxRounds,
            target: .branch(
                worktreeID: record.id.worktreeID,
                repositoryPath: context.worktreePath,
                base: forkPoint,
                head: round.headSHA,
                title: "Review before push · round \(round.number)"
            )
        )
    }

    /// The bound request's head isn't clean or allowed and no review runs.
    /// Local HEAD on that head is reviewed like a fix; any other head is
    /// recorded as reaching the remote without a review, and local HEAD is
    /// compared again on the next check while the head stays unpassed.
    public func reviewPushedHead(_ id: ShipReviewID, headSHA: String) {
        guard let record = records[id], record.enabled, record.phase == .idle,
              !record.passedSHAs.contains(headSHA), !checkingPushedHead.contains(id)
        else { return }
        checkingPushedHead.insert(id)
        spawn { [weak self] in
            guard let self else { return }
            defer { checkingPushedHead.remove(id) }
            let local = await localHead(id)
            guard var record = records[id], record.enabled, record.phase == .idle,
                  !record.passedSHAs.contains(headSHA)
            else { return }
            if local == headSHA {
                _ = requestPush(id, target: .pushedHead, headSHA: headSHA)
            } else if record.unreviewedRemoteHead != headSHA {
                record.unreviewedRemoteHead = headSHA
                record.updatedAt = now()
                put(record)
            }
        }
    }

    /// A request `pr_create` adopted with nothing to push. Seeds a missing
    /// record from the Settings defaults, so the merge gate is closed before
    /// the bind and `reviewPushedHead` reviews the adopted head.
    public func seedRecord(_ id: ShipReviewID) {
        guard records[id] == nil, let seeded = seededRecord(id) else { return }
        put(seeded)
    }

    // MARK: - Actions

    private func execute(_ action: ShipReviewAction, for id: ShipReviewID) {
        switch action {
        case .none:
            break
        case let .startRound(headSHA):
            startRound(id, headSHA: headSHA)
        case let .push(headSHA):
            guard let target = records[id]?.pending else { return }
            spawn { [weak self] in await self?.push(id, target: target, headSHA: headSHA) }
        case .sendFindings:
            // Only `reviewFinished` asks for it; `runRound` sends them with the round's result.
            break
        case let .stop(stop):
            // Nothing goes out until the user acts; a retry starts a fresh reviewer.
            if var record = records[id], record.reviewerSessionID != nil {
                dropReviewer(&record)
                put(record)
            }
            effects?.notify(id, stop)
        }
    }

    /// `requestPush` made by Alas itself, which then also pushes a head that already passed.
    private func reviewOrPush(_ id: ShipReviewID, target: ShipReviewTarget, headSHA: String) {
        guard requestPush(id, target: target, headSHA: headSHA) == .push,
              var record = records[id], let pending = record.pending
        else { return }
        record.phase = .pushing(headSHA: headSHA)
        record.updatedAt = now()
        put(record)
        spawn { [weak self] in await self?.push(id, target: pending, headSHA: headSHA) }
    }

    private func push(_ id: ShipReviewID, target: ShipReviewTarget, headSHA: String) async {
        guard let effects else { return }
        let error = await effects.push(id, target, headSHA)
        guard let record = records[id] else { return }
        // A request that started a round meanwhile (HEAD moved) owns the phase now.
        let settles = record.phase == .pushing(headSHA: headSHA)
        var next = ShipReviewPolicy.pushFinished(record, headSHA: headSHA, error: error, now: now())
        if settles {
            // This push is done with its reviewer either way.
            dropReviewer(&next)
            // The remote head is the pushed SHA now.
            if error == nil { next.unreviewedRemoteHead = nil }
        }
        put(next)
        if let error, settles {
            effects.notify(id, .pushFailed(error))
        }
    }

    private func ownerTurnEnded(_ id: ShipReviewID) async {
        guard let effects, let current = records[id] else { return }
        let head: String
        do {
            head = try await effects.shipHead(id, current.pending)
        } catch {
            // Left awaiting the fix, the push would wait forever.
            guard var record = records[id], case .awaitingFix = record.phase, !deliveringFindings.contains(id) else { return }
            let stop = ShipReviewStop.reviewerFailed("couldn't read the branch: \(error.localizedDescription)")
            record.phase = .stopped(stop)
            record.updatedAt = now()
            put(record)
            execute(.stop(stop), for: id)
            return
        }
        guard let record = records[id], case .awaitingFix = record.phase, !deliveringFindings.contains(id) else { return }
        let (next, action) = ShipReviewPolicy.ownerTurnEnded(record, headSHA: head, openFindings: openFindings(record), now: now())
        put(next)
        execute(action, for: id)
    }

    private func pickUpLocalCommits(_ id: ShipReviewID) async {
        guard let effects, let head = await effects.localCommitsToPush(id),
              let record = records[id], record.enabled, record.phase == .idle
        else { return }
        reviewOrPush(id, target: .pullRequest(PendingPRPush(title: "", body: "", draft: false, base: nil)), headSHA: head)
    }

    // MARK: - Rounds

    /// What a round sends the reviewer, and what filing its result needs.
    private struct PreparedRound {
        let context: Context
        let reviewer: ResolvedReviewer
        let label: String
        let base: String
        let forkPointSHA: String
        let diff: CodeReviewDiff
        let prompt: String
        let round: Int
        let earlierRoundSessionIDs: [ReviewSessionID]
    }

    private func startRound(_ id: ShipReviewID, headSHA: String) {
        roundTasks[id]?.cancel()
        let generation = bumpGeneration(id)
        roundTasks[id] = spawn { [weak self] in
            await self?.runRound(id, headSHA: headSHA, generation: generation)
        }
    }

    /// Cancels the running round; its result, should one still arrive, is ignored.
    private func endRound(_ id: ShipReviewID) {
        roundTasks[id]?.cancel()
        roundTasks[id] = nil
        bumpGeneration(id)
    }

    private func runRound(_ id: ShipReviewID, headSHA: String, generation: Int) async {
        guard let effects, let record = records[id], record.phase.reviews(headSHA) else { return }
        let prepared: PreparedRound
        switch await prepareRound(record, headSHA: headSHA, effects: effects) {
        case let .failure(failure):
            guard isCurrent(id, generation), let current = records[id] else { return }
            decide(id, generation: generation, record: current, headSHA: headSHA, currentHead: headSHA, outcome: .failure(failure), prepared: nil)
            return
        case let .success(value):
            prepared = value
        }
        guard isCurrent(id, generation), var current = records[id] else { return }
        if let index = current.rounds.indices.last, current.rounds[index].headSHA == headSHA {
            current.rounds[index].reviewerLabel = prepared.label
            put(current)
        }

        let outcome = await effects.runReviewer(ReviewerRun(
            id: id, reviewer: prepared.reviewer, reuseSessionID: current.reviewerSessionID, prompt: prepared.prompt
        ))
        guard isCurrent(id, generation), var reviewed = records[id] else {
            // A newer round or a stop took over. Its reviewer is the record's;
            // a session this turn created is nobody's.
            if let sessionID = outcome.sessionID, sessionID != records[id]?.reviewerSessionID {
                await effects.discardReviewer(id, sessionID)
            }
            return
        }
        if let sessionID = outcome.sessionID, sessionID != reviewed.reviewerSessionID {
            reviewed.reviewerSessionID = sessionID
            put(reviewed)
        }
        var parsed: Result<CodeReviewResult, ShipReviewFailure>
        switch outcome {
        case let .finished(_, finalText):
            parsed = CodeReviewResultParser.parse(finalText, diff: prepared.diff).mapError { _ in ShipReviewFailure.noResult }
        case let .failed(_, reason):
            parsed = .failure(.reviewer(reason))
        }
        var currentHead = headSHA
        do {
            currentHead = try await effects.shipHead(id, records[id]?.pending ?? record.pending)
        } catch {
            parsed = .failure(.reviewer("couldn't read HEAD: \(error.localizedDescription)"))
        }
        guard isCurrent(id, generation), let latest = records[id] else { return }
        decide(id, generation: generation, record: latest, headSHA: headSHA, currentHead: currentHead, outcome: parsed, prepared: prepared)
    }

    /// Files a result that still describes HEAD, applies the policy and acts on it.
    private func decide(
        _ id: ShipReviewID,
        generation: Int,
        record: ShipReviewRecord,
        headSHA: String,
        currentHead: String,
        outcome: Result<CodeReviewResult, ShipReviewFailure>,
        prepared: PreparedRound?
    ) {
        guard let effects else { return }
        var outcome = outcome
        var filed: (sessionID: ReviewSessionID, findingIDs: [String], target: ReviewSessionTarget)?
        if let prepared, currentHead == headSHA, case let .success(result) = outcome {
            let target = ReviewSessionTarget.branch(
                worktreeID: id.worktreeID,
                repositoryPath: prepared.context.worktreePath,
                base: prepared.forkPointSHA,
                head: headSHA,
                title: "Review before push · round \(prepared.round)"
            )
            let findingIDs = result.findings.map { _ in UUID().uuidString }
            do {
                let sessionID = try effects.fileRound(Filing(
                    id: id, round: prepared.round, baseSHA: prepared.forkPointSHA, headSHA: headSHA, target: target,
                    reviewerLabel: prepared.label, result: result, findingIDs: findingIDs,
                    earlierRoundSessionIDs: prepared.earlierRoundSessionIDs
                ))
                filed = (sessionID, findingIDs, target)
            } catch {
                // Unfiled findings can't be resolved, so they must not reach the owner.
                outcome = .failure(.reviewer("couldn't file the findings: \(error.localizedDescription)"))
            }
        }
        let (decided, action) = ShipReviewPolicy.reviewFinished(
            record, reviewedSHA: headSHA, currentHeadSHA: currentHead, outcome: outcome,
            autoFix: effects.autoFix(id), now: now()
        )
        var next = decided
        if let filed, let prepared,
           let index = next.rounds.lastIndex(where: { $0.number == prepared.round && $0.headSHA == headSHA }) {
            next.rounds[index].reviewSessionID = filed.sessionID
            next.rounds[index].openFindingIDs = filed.findingIDs
            next.rounds[index].reviewerLabel = prepared.label
        }
        put(next)
        guard case let .sendFindings(round) = action else {
            execute(action, for: id)
            return
        }
        guard let filed, let prepared, case let .success(result) = outcome else { return }
        let prompt = ShipReviewPromptBuilder.findings(
            result: result, findingIDs: filed.findingIDs, reviewerLabel: prepared.label,
            branch: prepared.context.branch, base: prepared.base, headSHA: headSHA,
            round: round, maxRounds: next.maxRounds, target: filed.target
        )
        deliveringFindings.insert(id)
        spawn { [weak self] in
            await self?.deliverFindings(id, prompt: prompt, headSHA: headSHA, generation: generation)
        }
    }

    private func deliverFindings(_ id: ShipReviewID, prompt: ShepherdPrompt, headSHA: String, generation: Int) async {
        guard let effects else {
            deliveringFindings.remove(id)
            return
        }
        let delivery = await effects.deliverFindings(id, prompt)
        deliveringFindings.remove(id)
        guard delivery == .failed, isCurrent(id, generation), var record = records[id],
              record.phase == .awaitingFix(headSHA: headSHA)
        else { return }
        let stop = ShipReviewStop.reviewerFailed("couldn't reach the session")
        record.phase = .stopped(stop)
        record.updatedAt = now()
        dropReviewer(&record)
        put(record)
        effects.notify(id, stop)
    }

    /// Everything a round reads before the reviewer runs. Each failure stops
    /// the round without counting it.
    private func prepareRound(
        _ record: ShipReviewRecord,
        headSHA: String,
        effects: Effects
    ) async -> Result<PreparedRound, ShipReviewFailure> {
        let id = record.id
        guard let context = effects.context(id.worktreeID) else { return .failure(.reviewer("the worktree is gone")) }
        guard let reviewer = resolvedReviewer(record) else { return .failure(.reviewer("the session's agent is unknown")) }
        guard let label = effects.agentLabel(reviewer) else {
            return .failure(.reviewer("\(reviewer.agentID) isn't available"))
        }
        let instructions: CodeReviewInstructions
        do {
            instructions = try await effects.instructions(context.worktreePath, context.projectSettings?.instructions)
        } catch {
            return .failure(.instructions(Self.unreadableInstructions(error)))
        }
        let base = record.pending?.reviewBase ?? context.baseBranch
        var forkPoint = try? await effects.git.mergeBase(context.worktreePath, "origin/\(base)", headSHA)
        if forkPoint == nil {
            forkPoint = try? await effects.git.mergeBase(context.worktreePath, base, headSHA)
        }
        guard let forkPoint else {
            return .failure(.reviewer("couldn't find where \(context.branch) forks from \(base)"))
        }
        let rawDiff: String
        do {
            rawDiff = try await effects.git.diff(context.worktreePath, forkPoint, headSHA)
        } catch {
            return .failure(.reviewer("couldn't read the diff: \(error.localizedDescription)"))
        }
        // This push's reviews with findings, oldest first; the running round is unreviewed.
        let earlier = record.rounds.filter { $0.reviewedAt != nil }.suffix(record.roundsThisPush)
        let earlierSessionIDs = earlier.compactMap(\.reviewSessionID)
        let earlierFindings = earlierSessionIDs.isEmpty ? [] : effects.earlierFindings(earlierSessionIDs)
        let round = record.currentRound?.number ?? 1
        let diff = CodeReviewDiff(rawDiff: rawDiff)
        let prompt = CodeReviewPromptBuilder.build(CodeReviewPromptInput(
            globalPrompt: effects.settings().review.prompt,
            instructions: instructions,
            branch: context.branch,
            base: base,
            headSHA: headSHA,
            round: round,
            maxRounds: record.maxRounds,
            diff: diff,
            earlierFindings: earlierFindings
        ))
        return .success(PreparedRound(
            context: context, reviewer: reviewer, label: label, base: base, forkPointSHA: forkPoint,
            diff: diff, prompt: prompt, round: round, earlierRoundSessionIDs: earlierSessionIDs
        ))
    }

    /// "<file>: <detail>" for a rules-style read error, so the stop reads
    /// "Couldn't read .alas/code-review.md: <detail>".
    private static func unreadableInstructions(_ error: Error) -> String {
        guard let readError = error as? ShepherdRulesReadError else {
            return "the review instructions: \(error.localizedDescription)"
        }
        let file = readError.file.contains("/") ? readError.file : ".alas/\(readError.file)"
        let detail = readError.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? file : "\(file): \(detail)"
    }

    // MARK: - Helpers

    /// The record's reviewer: ship choice, else project, else global; nil
    /// when it is the session's own agent and that is unknown.
    private func resolvedReviewer(_ record: ShipReviewRecord) -> ResolvedReviewer? {
        guard let effects else { return nil }
        let resolved = ReviewerResolver.resolve(
            ship: record.reviewer,
            project: effects.context(record.id.worktreeID)?.projectSettings,
            global: effects.settings().review,
            ownerAgentID: effects.ownerAgentID(record.id) ?? ""
        )
        return resolved.agentID.isEmpty ? nil : resolved
    }

    /// This push's findings still open in the pane, across all its rounds:
    /// a later round need not report an earlier one's findings fixed. A
    /// round whose session can't be read counts its own findings, at least
    /// one, so a read failure never passes a head.
    private func openFindings(_ record: ShipReviewRecord) -> Int {
        let rounds = record.rounds.filter { $0.reviewedAt != nil }.suffix(record.roundsThisPush)
        var counted: Set<ReviewSessionID> = []
        return rounds.reduce(0) { total, round in
            guard let reviewSessionID = round.reviewSessionID else { return total + round.openFindingIDs.count }
            guard counted.insert(reviewSessionID).inserted else { return total }
            guard let open = effects?.openFindingCount(reviewSessionID) else {
                return total + max(round.openFindingIDs.count, 1)
            }
            return total + open
        }
    }

    private func localHead(_ id: ShipReviewID) async -> String? {
        guard let effects else { return nil }
        return try? await effects.shipHead(id, records[id]?.pending)
    }

    /// A new record with the Settings defaults; nil when they leave the lever off.
    private func seededRecord(_ id: ShipReviewID) -> ShipReviewRecord? {
        guard let defaults = effects?.settings().defaults, defaults.reviewBeforePush else { return nil }
        return ShipReviewRecord(id: id, enabled: true, reviewer: nil, maxRounds: defaults.maxReviewRounds, now: now())
    }

    /// Changes the record, creating it from the defaults' round cap. Turning
    /// the lever off stops a running review.
    private func update(_ id: ShipReviewID, _ change: (inout ShipReviewRecord) -> Void) {
        let maxRounds = effects?.settings().defaults.maxReviewRounds ?? ShepherdDefaults.defaultMaxReviewRounds
        var record = records[id] ?? ShipReviewRecord(id: id, enabled: false, reviewer: nil, maxRounds: maxRounds, now: now())
        change(&record)
        record.updatedAt = now()
        if !record.enabled { halt(&record) }
        put(record)
    }

    /// Back to idle with nothing pending; the reviewer is discarded. A push
    /// already underway settles on its own.
    private func halt(_ record: inout ShipReviewRecord) {
        if case .pushing = record.phase { return }
        let id = record.id
        endRound(id)
        if let last = record.rounds.last, last.reviewedAt == nil {
            record.rounds.removeLast()
        }
        record.phase = .idle
        record.pending = nil
        record.roundsThisPush = 0
        record.updatedAt = now()
        dropReviewer(&record)
    }

    /// Discards this push's reviewer session.
    private func dropReviewer(_ record: inout ShipReviewRecord) {
        guard let sessionID = record.reviewerSessionID else { return }
        record.reviewerSessionID = nil
        let id = record.id
        spawn { [weak self] in await self?.effects?.discardReviewer(id, sessionID) }
    }

    @discardableResult
    private func bumpGeneration(_ id: ShipReviewID) -> Int {
        lastGeneration += 1
        generations[id] = lastGeneration
        return lastGeneration
    }

    private func isCurrent(_ id: ShipReviewID, _ generation: Int) -> Bool {
        records[id] != nil && generations[id] == generation
    }

    /// Runs `body` on the main actor, tracked until it ends.
    @discardableResult
    private func spawn(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await body()
            self?.inFlight[token] = nil
        }
        inFlight[token] = task
        return task
    }

    // MARK: - Storage

    private func put(_ record: ShipReviewRecord) {
        records[record.id] = record
        persist()
    }

    private func load() {
        do {
            let result = try store.readIfExistsReportingRecovery(ShipReviewsFile.self, from: fileURL)
            if let recoveryError = result.recoveryError {
                shipReviewLogger.error(
                    "Ship review records were unreadable and were set aside: \(String(describing: recoveryError), privacy: .public)"
                )
            }
            guard let file = result.value else { return }
            let current = now()
            let kept = file.records.filter { record in
                record.phase != .idle || record.pending != nil || current.timeIntervalSince(record.updatedAt) < Self.idleLifetime
            }
            records = Dictionary(kept.map { ($0.id, $0) }) { lhs, rhs in lhs.updatedAt >= rhs.updatedAt ? lhs : rhs }
            if kept.count != file.records.count {
                persist()
            }
        } catch {
            shipReviewLogger.error("Could not read ship review records: \(String(describing: error), privacy: .public)")
        }
    }

    private func persist() {
        let file = ShipReviewsFile(records: records.values.sorted { $0.createdAt < $1.createdAt })
        do {
            try store.write(file, to: fileURL)
        } catch {
            shipReviewLogger.error("Could not save ship review records: \(String(describing: error), privacy: .public)")
        }
    }
}

private extension ShipReviewPhase {
    func reviews(_ headSHA: String) -> Bool {
        if case let .reviewing(reviewing, _) = self { return reviewing == headSHA }
        return false
    }
}

private extension ShipReviewTarget {
    /// The base `pr_create` named or the gg stack's, if known.
    var reviewBase: String? {
        switch self {
        case let .pullRequest(push): push.base
        case let .stack(_, base): base
        case .pushedHead: nil
        }
    }
}

/// The turn that sends a round's findings to the owning session.
enum ShipReviewPromptBuilder {
    static func findings(
        result: CodeReviewResult,
        findingIDs: [String],
        reviewerLabel: String,
        branch: String,
        base: String,
        headSHA: String,
        round: Int,
        maxRounds: Int,
        target: ReviewSessionTarget
    ) -> ShepherdPrompt {
        let shortSHA = String(headSHA.prefix(7))
        let count = result.findings.count
        let found = switch count {
        case 0: "found problems outside the diff, listed below"
        case 1: "found 1 problem"
        default: "found \(count) problems"
        }
        var sections = [
            "Alas review before push · branch \(branch) → \(base) · head \(shortSHA)",
            "\(reviewerLabel) reviewed your commits and \(found). Nothing was pushed. Fix each one and commit. "
                + "Resolve each finding with review_resolve and a one-line reply saying what changed, "
                + "or reply with review_reply if you disagree. "
                + "Don't push: when your turn ends, Alas reviews the new commits and pushes them.",
        ]
        let findings = Array(zip(findingIDs, result.findings))
        if !findings.isEmpty {
            sections.append(findings.map { id, finding in
                let body = finding.body.replacingOccurrences(of: "\n", with: "\n  ")
                return "- [\(id)] \(finding.path):\(lineText(finding.anchor)): \(body)"
            }.joined(separator: "\n"))
        }
        let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { sections.append(summary) }

        let items = findings.map { id, finding in
            ACPPromptCard.Item(location: location(finding), bodyMarkdown: finding.body, reviewCommentID: id)
        }
        let card = ACPPromptCard(
            origin: .shepherd,
            title: "Review before push · \(count == 1 ? "1 finding" : "\(count) findings")",
            facts: [
                .init(kind: .other, text: reviewerLabel),
                .init(kind: .other, text: "round \(round) of \(maxRounds)"),
                .init(kind: .revision, text: shortSHA),
            ],
            sections: items.isEmpty ? [] : [.init(title: nil, items: items)],
            action: .reviewSession(target)
        )
        return ShepherdPrompt(text: sections.joined(separator: "\n\n"), card: card)
    }

    private static func lineText(_ anchor: CodeReviewFinding.Anchor) -> String {
        switch anchor {
        case let .line(start, end): start == end ? "\(start)" : "\(start)-\(end)"
        case .file: "file"
        }
    }

    private static func location(_ finding: CodeReviewFinding) -> ACPPromptCard.Location {
        switch finding.anchor {
        case let .line(start, end): .init(path: finding.path, startLine: start, endLine: end, side: "new")
        case .file: .init(path: finding.path)
        }
    }
}
