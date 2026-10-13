import Foundation
import Observation
import os

private let shepherdLogger = Logger(subsystem: "io.nlopez.alas", category: "ReviewShepherd")

/// The shepherd's records on disk, at `Paths.reviewShepherdsFile`. Decoded
/// per record, like `RunSchedulesFile`: one record written by a newer build
/// (an unknown phase, say) must not read as "no records" and then be
/// persisted over the ones that still decode.
public struct ReviewShepherdsFile: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var records: [ShepherdRecord] = []

    public enum CodingKeys: String, CodingKey, Sendable {
        case version, records
    }

    public init(records: [ShepherdRecord] = []) {
        self.records = records
    }

    private struct LenientRecord: Decodable {
        let record: ShepherdRecord?

        init(from decoder: Decoder) throws {
            record = try? ShepherdRecord(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        records = ((try? c.decode([LenientRecord].self, forKey: .records)) ?? []).compactMap(\.record)
    }
}

extension Paths {
    public static var reviewShepherdsFile: URL {
        appSupportRoot.appendingPathComponent("review-shepherds.json")
    }
}

/// How long merged and closed records stay, so the toolbar button and the
/// Changes drawer can still show the outcome.
public enum ShepherdRecordRetention {
    public static let finishedLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// Drops finished records older than `finishedLifetime`, counted from
    /// `finishedAt` (`updatedAt` for one finished without it). Records still
    /// being shepherded are kept however old they are.
    public static func prune(_ records: [ShepherdRecord], now: Date) -> [ShepherdRecord] {
        records.filter { record in
            guard record.phase.isTerminal else { return true }
            return now.timeIntervalSince(record.finishedAt ?? record.updatedAt) < finishedLifetime
        }
    }
}

/// Watches every bound pull or merge request while Alas runs. It owns the
/// records, their timing and the provider fetches; `ShepherdPolicy` decides
/// what each fetch means, and `effects` (installed by AppState) reach the
/// sessions, notifications, panes and the archive path. Same split as
/// `RunScheduler`, and like it nothing here runs while the app is quit.
///
/// One 30 s timer starts whichever records are due, at most
/// `ShepherdSchedule.maxConcurrentFetches` at a time. `start()` and waking
/// the machine make every active record due at once. Due times and failure
/// counts live in memory only.
@MainActor
@Observable
public final class ReviewShepherd {
    public struct WorktreeContext: Equatable, Sendable {
        public let worktreeID: String
        public let projectID: String
        public let path: URL
        /// The base the Changes pane reviews against. Informational: each
        /// record keeps the base of its own request, which the branch lookup
        /// filters on.
        public let baseBranch: String
        /// A local worktree outside every Workspace checkout.
        public let isEligible: Bool

        public init(worktreeID: String, projectID: String, path: URL, baseBranch: String, isEligible: Bool) {
            self.worktreeID = worktreeID
            self.projectID = projectID
            self.path = path
            self.baseBranch = baseBranch
            self.isEligible = isEligible
        }
    }

    /// What the app turns into notifications and attention.
    public enum Event: Equatable, Sendable {
        case ready(ShepherdRecord, title: String)
        case merged(ShepherdRecord, title: String)
        case queued(ShepherdRecord, title: String)
        case closed(ShepherdRecord, title: String)
        case escalated(ShepherdRecord, ShepherdEscalation, title: String?)
    }

    /// How a prompt delivery ended.
    public enum Delivery: Equatable, Sendable {
        case delivered
        /// The prompt could not be queued on the session.
        case failed
        /// `isStillWanted` turned false before the prompt was queued: the
        /// record was stopped, rebound or changed meanwhile. Nothing was sent.
        case superseded
    }

    public struct Effects {
        /// Nil when the worktree is gone or archived; its records are dropped.
        public var worktreeContext: @MainActor (_ worktreeID: String) -> WorktreeContext?
        public var sessionState: @MainActor (_ sessionID: String, _ worktreeID: String) async -> ShepherdSessionState
        /// Queues `text` on the session. `isStillWanted` is checked right
        /// before the session's queue changes, after any suspension.
        public var deliverPrompt: @MainActor (
            _ sessionID: String,
            _ worktreeID: String,
            _ text: String,
            _ isStillWanted: @escaping @MainActor () -> Bool
        ) async -> Delivery
        public var rules: @MainActor (_ worktreeID: String) -> ShepherdRules
        public var notify: @MainActor (Event) -> Void
        public var refreshPaneIfCached: @MainActor (_ worktreeID: String) -> Void
        /// Checks the archive-after-merge setting and the finished record's
        /// owner session (`sessionID`) itself.
        public var archiveWorktreeIfAllowed: @MainActor (_ worktreeID: String, _ sessionID: String) async -> Void

        public init(
            worktreeContext: @escaping @MainActor (_ worktreeID: String) -> WorktreeContext?,
            sessionState: @escaping @MainActor (_ sessionID: String, _ worktreeID: String) async -> ShepherdSessionState,
            deliverPrompt: @escaping @MainActor (
                _ sessionID: String,
                _ worktreeID: String,
                _ text: String,
                _ isStillWanted: @escaping @MainActor () -> Bool
            ) async -> Delivery,
            rules: @escaping @MainActor (_ worktreeID: String) -> ShepherdRules,
            notify: @escaping @MainActor (Event) -> Void,
            refreshPaneIfCached: @escaping @MainActor (_ worktreeID: String) -> Void,
            archiveWorktreeIfAllowed: @escaping @MainActor (_ worktreeID: String, _ sessionID: String) async -> Void
        ) {
            self.worktreeContext = worktreeContext
            self.sessionState = sessionState
            self.deliverPrompt = deliverPrompt
            self.rules = rules
            self.notify = notify
            self.refreshPaneIfCached = refreshPaneIfCached
            self.archiveWorktreeIfAllowed = archiveWorktreeIfAllowed
        }
    }

    /// Posted when the machine wakes, so every active record is evaluated at
    /// once. Nil leaves wake-ups to the next timer tick.
    public static var wakeNotification: (center: NotificationCenter, name: Notification.Name)?

    @ObservationIgnored public var effects: Effects?
    public private(set) var records: [ShepherdRecordID: ShepherdRecord] = [:]
    /// The latest successful fetch per record, for the toolbar and drawer.
    public private(set) var snapshots: [ShepherdRecordID: ReviewLoopSnapshot] = [:]

    @ObservationIgnored private let store: any PersistenceStoreProtocol
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let providerRegistry: CodeHostProviderRegistry
    @ObservationIgnored private let localProbe: ReviewLoopLocalProbe
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// One headless review loop per record, reused across polls.
    @ObservationIgnored private var loops: [ShepherdRecordID: ReviewLoopState] = [:]
    @ObservationIgnored private var dueAt: [ShepherdRecordID: Date] = [:]
    @ObservationIgnored private var failureCounts: [ShepherdRecordID: Int] = [:]
    @ObservationIgnored private var inFlight: Set<ShepherdRecordID> = []
    /// Bumped by every change made outside an evaluation and by every
    /// committed decision. An action that suspends (delivery, merge) goes on
    /// only while its record keeps the generation captured when the decision
    /// was committed, so a stop, rebind or toggle made meanwhile wins. Values
    /// never repeat, so a deleted and rebound record can't match a stale one.
    @ObservationIgnored private var generations: [ShepherdRecordID: Int] = [:]
    @ObservationIgnored private var lastGeneration = 0

    public init(
        store: any PersistenceStoreProtocol,
        fileURL: URL = Paths.reviewShepherdsFile,
        providerRegistry: CodeHostProviderRegistry = .live(),
        localProbe: ReviewLoopLocalProbe = .live,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.store = store
        self.fileURL = fileURL
        self.providerRegistry = providerRegistry
        self.localProbe = localProbe
        self.now = now
        load()
    }

    // MARK: - Lifecycle

    public func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: ShepherdSchedule.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pump()
            }
        }
        timer.tolerance = ShepherdSchedule.tick / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        makeAllDue()
        guard let wake = Self.wakeNotification else { return }
        wakeObserver = wake.center.addObserver(
            forName: wake.name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.makeAllDue()
            }
        }
    }

    /// Stops the clock. Evaluations in flight finish; records are persisted
    /// on every change, so there is nothing to flush.
    public func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver, let wake = Self.wakeNotification {
            wake.center.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    // MARK: - Queries

    /// The session's newest record still being shepherded, else its newest
    /// finished one.
    public func record(forSession sessionID: String) -> ShepherdRecord? {
        Self.preferred(records.values.filter { $0.sessionID == sessionID })
    }

    public func record(forWorktree worktreeID: String) -> ShepherdRecord? {
        Self.preferred(records.values.filter { $0.id.worktreeID == worktreeID })
    }

    private static func preferred(_ candidates: [ShepherdRecord]) -> ShepherdRecord? {
        let newestFirst = candidates.sorted { $0.updatedAt > $1.updatedAt }
        return newestFirst.first { !$0.phase.isTerminal } ?? newestFirst.first
    }

    // MARK: - Binding and controls

    /// Binds `request` to `sessionID`, creating the record or moving an
    /// existing one. The owner starts fresh: phase `watching`, no attempts,
    /// no dispatched fingerprint, so its current problems are dispatched to
    /// it on the next idle poll. A session works on the branch its worktree
    /// has checked out, so it owns at most one live record: its others are
    /// deleted (their requests are untouched). No other session's record moves.
    @discardableResult
    public func bind(
        sessionID: String,
        worktreeID: String,
        request: ReviewRequest,
        baseBranch: String,
        autoFix: Bool,
        autoMerge: Bool,
        sendContext: Bool
    ) async -> ShepherdRecord {
        let id = ShepherdRecordID(worktreeID: worktreeID, request: request)
        let now = self.now()
        for other in records.values where other.id != id && other.sessionID == sessionID && !other.phase.isTerminal {
            remove(other.id)
        }
        var record = records[id].flatMap { $0.phase.isTerminal ? nil : $0 }
            ?? ShepherdRecord(
                id: id,
                sessionID: sessionID,
                remote: request.remote,
                branch: request.headRefName,
                baseBranch: baseBranch,
                autoFix: autoFix,
                autoMerge: autoMerge,
                now: now
            )
        if record.sessionID != sessionID {
            // The new owner has not seen the replies its predecessor made, so
            // every actionable trusted thread is its to answer.
            record.handledThreadRevisions = nil
        }
        record.sessionID = sessionID
        record.remote = request.remote
        record.branch = request.headRefName
        record.baseBranch = baseBranch
        record.autoFix = autoFix
        record.autoMerge = autoMerge
        record.phase = .watching
        record.fixAttempts = 0
        record.lastDispatchedFingerprint = nil
        record.viewerCommentIDsAtDispatch = nil
        record.updatedAt = now
        put(record)
        let generation = bumpGeneration(id)
        failureCounts[id] = nil
        dueAt[id] = now
        if sendContext, let effects {
            let prompt = ShepherdPromptBuilder.bindPrompt(
                request: request,
                fix: ShepherdPolicy.problems(in: request, handled: record.handledThreadRevisions ?? []),
                rules: effects.rules(worktreeID)
            )
            let delivery = await effects.deliverPrompt(sessionID, worktreeID, prompt) { [weak self] in
                self?.isCurrent(id, generation, before: "the bind delivery") ?? false
            }
            if delivery == .failed, isCurrent(id, generation, before: "the bind delivery escalation") {
                escalate(id, .deliveryFailed, title: request.title)
            }
        }
        pump()
        return records[id] ?? record
    }

    public func setAutoFix(_ on: Bool, for id: ShepherdRecordID) {
        update(id) { $0.autoFix = on }
    }

    public func setAutoMerge(_ on: Bool, for id: ShepherdRecordID) {
        update(id) { $0.autoMerge = on }
    }

    /// Escalated or paused back to watching with a full attempt budget. The
    /// dispatched fingerprint is cleared too: a no-progress escalation leaves
    /// the same problems as the last prompt, which the policy would otherwise
    /// keep waiting on.
    public func resume(_ id: ShepherdRecordID) {
        guard let record = records[id] else { return }
        switch record.phase {
        case .escalated, .paused:
            break
        default:
            return
        }
        failureCounts[id] = nil
        update(id) {
            $0.phase = .watching
            $0.fixAttempts = 0
            $0.lastDispatchedFingerprint = nil
            $0.viewerCommentIDsAtDispatch = nil
        }
    }

    /// Deletes the record. The request itself is left alone.
    public func stopShepherding(_ id: ShepherdRecordID) {
        guard records[id] != nil else { return }
        remove(id)
    }

    /// A turn of `sessionID` ended. Any fix it was working on now waits for
    /// the push to show up on the provider, starting with the next poll.
    public func turnCompleted(sessionID: String) {
        let now = self.now()
        for record in records.values where record.sessionID == sessionID {
            guard case .fixing = record.phase else { continue }
            var next = record
            next.phase = .awaitingPush(turnEndedAt: now, pollsWithoutProgress: 0)
            next.updatedAt = now
            put(next)
            bumpGeneration(record.id)
            dueAt[record.id] = now
        }
        pump()
    }

    // MARK: - Fetching

    /// Fetches, decides and acts for one record now, ignoring its due time
    /// and the concurrency cap. A record already being evaluated is skipped;
    /// that evaluation is just as fresh.
    public func evaluateNow(_ id: ShepherdRecordID) async {
        guard records[id] != nil, !inFlight.contains(id) else { return }
        inFlight.insert(id)
        await evaluate(id)
        inFlight.remove(id)
        pump()
    }

    /// A fresh provider fetch for any worktree, bypassing every throttle.
    /// Nil when the worktree's git state cannot be read.
    public func fetchSnapshot(worktreePath: URL, baseBranch: String) async -> ReviewLoopSnapshot? {
        guard let probed = try? await localProbe.probe(worktreePath, baseBranch) else { return nil }
        let loop = ReviewLoopState(worktreePath: worktreePath, baseBranch: baseBranch, providerRegistry: providerRegistry)
        await loop.refresh(local: probed.local, remotes: probed.remotes)
        return loop.snapshot
    }

    /// A fresh fetch of the record's own request, for `pr_status`. Read-only:
    /// no policy, no record change, no scheduling. The branch lookup is used
    /// when it finds this record's request; otherwise (the worktree moved to
    /// another branch, or the request is merged or closed) the request and
    /// its checks are read by number on the record's remote. A missing or
    /// signed-out provider CLI clears the matching provider flag; any other
    /// failure sets `errorMessage`. Either way the request is left out. Nil
    /// when the record or its worktree is gone or the worktree's git state
    /// cannot be read.
    public func statusSnapshot(for id: ShepherdRecordID) async -> ReviewLoopSnapshot? {
        guard let record = records[id],
              let context = effects?.worktreeContext(id.worktreeID),
              context.isEligible,
              let snapshot = await fetchSnapshot(worktreePath: context.path, baseBranch: record.baseBranch)
        else { return nil }
        if let request = snapshot.reviewRequest,
           ShepherdRecordID(worktreeID: id.worktreeID, request: request) == id {
            return snapshot
        }
        func onRecordRemote(
            _ request: ReviewRequest?,
            available: Bool = true,
            authenticated: Bool = true,
            capabilities: CodeHostProviderCapabilities = .readOnly,
            error: String? = nil
        ) -> ReviewLoopSnapshot {
            ReviewLoopSnapshot(
                local: snapshot.local,
                remote: record.remote,
                reviewRequest: request,
                providerAvailable: available,
                providerAuthenticated: authenticated,
                providerCapabilities: capabilities,
                errorMessage: error
            )
        }
        guard let provider = providerRegistry.provider(for: id.providerKind) else {
            return onRecordRemote(
                nil, available: false, authenticated: false,
                error: CodeHostProviderError.unsupportedProvider(id.providerKind).localizedDescription
            )
        }
        do {
            let request = try await requestByNumber(record, provider: provider, worktreePath: context.path)
            return onRecordRemote(request, capabilities: provider.capabilities)
        } catch CodeHostProviderError.cliMissing(let message) {
            return onRecordRemote(nil, available: false, authenticated: false, error: message)
        } catch CodeHostProviderError.unauthenticated(let message) {
            return onRecordRemote(nil, authenticated: false, error: message)
        } catch {
            return onRecordRemote(nil, capabilities: provider.capabilities, error: error.localizedDescription)
        }
    }

    /// The record's request read by number on its own remote, with its checks,
    /// as `ReviewLoopState` loads a branch's request. A checks failure fails
    /// the read, as it fails a review loop refresh.
    private func requestByNumber(
        _ record: ShepherdRecord,
        provider: any CodeHostProvider,
        worktreePath: URL
    ) async throws -> ReviewRequest {
        let request = try await provider.reviewRequest(remote: record.remote, number: record.id.requestNumber, cwd: worktreePath)
        let checks = try await provider.checks(remote: record.remote, request: request, cwd: worktreePath)
        return request.withChecks(checks)
    }

    /// Lowercased logins that reviewed the request's current head. Nil when
    /// the provider could not say, which keeps a required-reviewer gate closed.
    public func headReviewers(for snapshot: ReviewLoopSnapshot, worktreePath: URL) async -> Set<String>? {
        guard let remote = snapshot.remote,
              let request = snapshot.reviewRequest,
              let provider = providerRegistry.provider(for: remote.kind)
        else { return nil }
        return try? await provider.reviewersOnHead(remote: remote, request: request, cwd: worktreePath)
    }

    // MARK: - Scheduling

    private func makeAllDue() {
        let now = self.now()
        for record in records.values where !record.phase.isTerminal {
            dueAt[record.id] = now
        }
        pump()
    }

    /// Starts due evaluations, earliest due first, while fewer than
    /// `ShepherdSchedule.maxConcurrentFetches` are in flight.
    private func pump() {
        guard timer != nil, effects != nil else { return }
        let now = self.now()
        let due = records.values
            .filter { !$0.phase.isTerminal && !inFlight.contains($0.id) && (dueAt[$0.id] ?? now) <= now }
            .sorted { (dueAt[$0.id] ?? now) < (dueAt[$1.id] ?? now) }
        for record in due.prefix(max(0, ShepherdSchedule.maxConcurrentFetches - inFlight.count)) {
            let id = record.id
            inFlight.insert(id)
            Task { @MainActor [weak self] in
                await self?.evaluate(id)
                self?.inFlight.remove(id)
                self?.pump()
            }
        }
    }

    private func scheduleNext(_ record: ShepherdRecord, checksPending: Bool) {
        dueAt[record.id] = ShepherdSchedule.interval(for: record, checksPending: checksPending)
            .map { now().addingTimeInterval($0) }
    }

    private func noteFailure(_ id: ShepherdRecordID, _ message: String) {
        let count = (failureCounts[id] ?? 0) + 1
        failureCounts[id] = count
        dueAt[id] = now().addingTimeInterval(ShepherdSchedule.backoff(afterFailures: count))
        shepherdLogger.notice(
            "PR shepherd fetch for \(id.storageKey, privacy: .private) failed (\(count, privacy: .public) in a row): \(message, privacy: .public)"
        )
    }

    // MARK: - Evaluation

    private func evaluate(_ id: ShepherdRecordID) async {
        guard let effects, let record = records[id], !record.phase.isTerminal else { return }
        // A floor, so no early exit below can make the record due again at once.
        dueAt[id] = now().addingTimeInterval(ShepherdSchedule.tick)
        guard let context = effects.worktreeContext(id.worktreeID), context.isEligible else {
            shepherdLogger.notice("Dropping PR shepherd record \(id.storageKey, privacy: .private): its worktree is gone or not eligible")
            remove(id)
            return
        }
        let probed: (local: ReviewLoopLocalState, remotes: [GitRemote])
        do {
            probed = try await localProbe.probe(context.path, record.baseBranch)
        } catch {
            noteFailure(id, String(describing: error))
            return
        }
        let loop = reviewLoop(for: record, path: context.path)
        await loop.refresh(local: probed.local, remotes: probed.remotes)
        guard records[id] != nil else { return }
        guard let snapshot = loop.snapshot else {
            noteFailure(id, "The review loop produced no snapshot.")
            return
        }
        if let message = snapshot.errorMessage {
            noteFailure(id, message)
            return
        }
        guard snapshot.remote != nil else {
            noteFailure(id, "The worktree has no GitHub or GitLab remote.")
            return
        }
        guard snapshot.providerAvailable, snapshot.providerAuthenticated else {
            pauseForAuth(id)
            return
        }
        endAuthPause(id)
        guard let observed = await snapshotCarryingRequest(id, from: snapshot, worktreePath: context.path) else { return }
        let rules = effects.rules(id.worktreeID)
        let reviewers: Set<String>?
        if rules.requiredReviewers.isEmpty || observed.reviewRequest?.state != .open {
            reviewers = nil
        } else {
            reviewers = await headReviewers(for: observed, worktreePath: context.path)
        }
        guard let owner = records[id]?.sessionID else { return }
        let session = await effects.sessionState(owner, id.worktreeID)
        // Toggles, a rebind or a finished turn may have changed the record
        // while this evaluation waited: decide on the current one, and not at
        // all when it now belongs to another session.
        guard let current = records[id], current.sessionID == owner, !current.phase.isTerminal else { return }
        failureCounts[id] = nil
        snapshots[id] = observed
        let decision = ShepherdPolicy.decide(current, ShepherdObservation(
            snapshot: observed,
            headReviewers: reviewers,
            session: session,
            rules: rules,
            now: now()
        ))
        var next = decision.record
        if next.phase.isTerminal, next.finishedAt == nil {
            next.finishedAt = now()
        }
        if next != current {
            next.updatedAt = now()
            put(next)
        }
        let generation = bumpGeneration(id)
        await execute(decision.action, for: id, generation: generation, before: current, snapshot: observed, rules: rules, context: context)
        if let latest = records[id] {
            scheduleNext(latest, checksPending: observed.reviewRequest?.checks.contains { $0.bucket == .pending } ?? false)
        }
        effects.refreshPaneIfCached(id.worktreeID)
    }

    /// The snapshot to decide on, carrying this record's request. The branch
    /// lookup only finds open requests on the worktree's current branch, so
    /// when it returns another request or none, the request is read by
    /// number on the record's remote. Merged or closed there is decided on
    /// (the policy finishes the record before looking at checks, so they are
    /// not read and a checks failure can't keep it from finishing). Still
    /// open means the worktree moved to another branch or the request was
    /// retargeted: nothing is decided until the branch lookup finds it again,
    /// and a new base is adopted so it can.
    private func snapshotCarryingRequest(
        _ id: ShepherdRecordID,
        from snapshot: ReviewLoopSnapshot,
        worktreePath: URL
    ) async -> ReviewLoopSnapshot? {
        if let request = snapshot.reviewRequest,
           ShepherdRecordID(worktreeID: id.worktreeID, request: request) == id {
            return snapshot
        }
        guard let record = records[id], let provider = providerRegistry.provider(for: id.providerKind) else { return nil }
        let request: ReviewRequest
        do {
            request = try await provider.reviewRequest(remote: record.remote, number: id.requestNumber, cwd: worktreePath)
        } catch {
            noteFailure(id, String(describing: error))
            return nil
        }
        guard request.state == .open else {
            return ReviewLoopSnapshot(
                local: snapshot.local,
                remote: record.remote,
                reviewRequest: request,
                providerAvailable: true,
                providerAuthenticated: true,
                providerCapabilities: provider.capabilities,
                errorMessage: nil
            )
        }
        guard var current = records[id] else { return nil }
        failureCounts[id] = nil
        if request.baseRefName != current.baseBranch {
            current.baseBranch = request.baseRefName
            current.updatedAt = now()
            put(current)
            dueAt[id] = now()
        } else {
            scheduleNext(current, checksPending: false)
        }
        return nil
    }

    private func execute(
        _ action: ShepherdAction,
        for id: ShepherdRecordID,
        generation: Int,
        before: ShepherdRecord,
        snapshot: ReviewLoopSnapshot,
        rules: ShepherdRules,
        context: WorktreeContext
    ) async {
        guard let effects, let record = records[id], let request = snapshot.reviewRequest else { return }
        switch action {
        case .wait:
            return
        case .dispatchFix(let fix):
            let logs = await checkLogs(for: fix, request: request, remote: record.remote, worktreePath: context.path)
            guard isCurrent(id, generation, before: "fix delivery") else { return }
            let prompt = ShepherdPromptBuilder.fixPrompt(request: request, fix: fix, logs: logs, rules: rules)
            let delivery = await effects.deliverPrompt(record.sessionID, id.worktreeID, prompt) { [weak self] in
                self?.isCurrent(id, generation, before: "fix delivery") ?? false
            }
            // A superseded delivery sent nothing and its record changed; the
            // next poll decides again on the current one.
            guard delivery == .failed, isCurrent(id, generation, before: "the delivery rollback"),
                  var failed = records[id]
            else { return }
            // The prompt never reached the session, so it is not an attempt:
            // after Resume the same problems are dispatched again.
            failed.fixAttempts = before.fixAttempts
            failed.lastDispatchedFingerprint = before.lastDispatchedFingerprint
            failed.viewerCommentIDsAtDispatch = before.viewerCommentIDsAtDispatch
            put(failed)
            escalate(id, .deliveryFailed, title: request.title)
        case .merge:
            let attempt = await merge(id, generation: generation, snapshot: snapshot, worktreePath: context.path)
            let outcome: ReviewMergeOutcome?
            switch attempt {
            case .abandoned:
                return
            case .redecided(let decision, let previous, let fresh, let freshRules):
                // The fresh observation no longer says merge. Commit what the
                // policy said instead and act on it like any poll's decision.
                var next = decision.record
                if next.phase.isTerminal, next.finishedAt == nil {
                    next.finishedAt = now()
                }
                if next != previous {
                    next.updatedAt = now()
                    put(next)
                }
                snapshots[id] = fresh
                let redecided = bumpGeneration(id)
                await execute(
                    decision.action, for: id, generation: redecided, before: previous,
                    snapshot: fresh, rules: freshRules, context: context
                )
                return
            case .finished(let result):
                outcome = result
            }
            guard let latest = records[id] else { return }
            // A merge or queue entry happened whatever changed meanwhile, so
            // it is recorded on the current record. "Not merged" only puts
            // the record back to watching when nothing changed it.
            guard outcome != nil || generations[id] == generation else {
                shepherdLogger.debug("PR shepherd \(id.storageKey, privacy: .private) changed during a merge that did not happen")
                return
            }
            var next = ShepherdPolicy.applyMergeOutcome(outcome, to: latest, now: now())
            if next.phase.isTerminal, next.finishedAt == nil {
                next.finishedAt = now()
            }
            next.updatedAt = now()
            put(next)
            switch next.phase {
            case .merged:
                effects.notify(.merged(next, title: request.title))
                loops[id] = nil
                await effects.archiveWorktreeIfAllowed(id.worktreeID, next.sessionID)
            case .queued:
                effects.notify(.queued(next, title: request.title))
            default:
                let reason = loops[id]?.lastError ?? "the merge gate closed before merging"
                shepherdLogger.notice("PR shepherd did not merge \(id.storageKey, privacy: .private): \(reason, privacy: .public)")
            }
        case .notifyReady:
            effects.notify(.ready(record, title: request.title))
        case .finish(let outcome):
            loops[id] = nil
            switch outcome {
            case .merged:
                effects.notify(.merged(record, title: request.title))
                await effects.archiveWorktreeIfAllowed(id.worktreeID, record.sessionID)
            case .closed:
                effects.notify(.closed(record, title: request.title))
            }
        case .escalate(let reason):
            effects.notify(.escalated(record, reason, title: request.title))
        }
    }

    private enum MergeAttempt {
        /// The record was stopped, rebound or toggled while git was read:
        /// nothing was merged and nothing is recorded.
        case abandoned
        /// The policy, run again on fresh data, decided something other than
        /// merging. Nothing was merged; the decision is still to be committed.
        /// Never carries `.merge`.
        case redecided(ShepherdDecision, before: ShepherdRecord, snapshot: ReviewLoopSnapshot, rules: ShepherdRules)
        /// Nil when the final checks or the provider declined the merge.
        case finished(ReviewMergeOutcome?)
    }

    /// Reads git again right before merging, as `RightPaneState.performMerge`
    /// does, so a commit or edit made since the probe can't slip through.
    /// Then fetches the request again and asks the policy once more on that
    /// fresh data (rules, reviewers on the head, the owner's state), since
    /// any of it may have changed since the decision; only a fresh `.merge`
    /// merges. `ReviewLoopState.merge` then re-reads the provider and re-runs
    /// the readiness gate.
    private func merge(
        _ id: ShepherdRecordID,
        generation: Int,
        snapshot: ReviewLoopSnapshot,
        worktreePath: URL
    ) async -> MergeAttempt {
        guard let loop = loops[id], let reviewedHead = snapshot.reviewRequest?.headSHA else { return .finished(nil) }
        let fresh = try? await localProbe.probe(worktreePath, snapshot.local.baseBranch)
        guard mayStillMerge(id, generation) else { return .abandoned }
        guard let fresh,
              fresh.local.branchName == snapshot.local.branchName,
              fresh.local.headSHA == reviewedHead,
              !fresh.local.hasWorkingTreeChanges,
              !fresh.local.hasStagedChanges,
              !fresh.local.needsPush
        else { return .finished(nil) }
        await loop.refresh(local: fresh.local, remotes: fresh.remotes)
        guard mayStillMerge(id, generation) else { return .abandoned }
        guard let effects,
              let latest = loop.snapshot,
              latest.errorMessage == nil,
              latest.providerAvailable,
              latest.providerAuthenticated,
              let request = latest.reviewRequest,
              ShepherdRecordID(worktreeID: id.worktreeID, request: request) == id
        else { return .finished(nil) }
        let rules = effects.rules(id.worktreeID)
        let reviewers = rules.requiredReviewers.isEmpty || request.state != .open
            ? nil
            : await headReviewers(for: latest, worktreePath: worktreePath)
        guard mayStillMerge(id, generation), let owner = records[id]?.sessionID else { return .abandoned }
        let session = await effects.sessionState(owner, id.worktreeID)
        guard mayStillMerge(id, generation), let record = records[id] else { return .abandoned }
        // `decide` moves a `.merging` record back to watching before running
        // the rules, so it can return `.merge` again for this record.
        let decision = ShepherdPolicy.decide(record, ShepherdObservation(
            snapshot: latest,
            headReviewers: reviewers,
            session: session,
            rules: rules,
            now: now()
        ))
        guard decision.action == .merge else {
            return .redecided(decision, before: record, snapshot: latest, rules: rules)
        }
        if decision.record != record {
            put(decision.record)
        }
        snapshots[id] = latest
        return .finished(await loop.merge(snapshot: latest) { [weak self] in
            self?.mayStillMerge(id, generation) ?? false
        })
    }

    /// The decision to merge still stands: same generation, still merging,
    /// auto-merge still on.
    private func mayStillMerge(_ id: ShepherdRecordID, _ generation: Int) -> Bool {
        guard isCurrent(id, generation, before: "merge"), let record = records[id] else { return false }
        return record.phase == .merging && record.autoMerge
    }

    /// Logs for at most `ShepherdPromptBuilder.maxCheckLogs` failing checks.
    /// A check whose log can't be read is left to the prompt's list of names.
    private func checkLogs(
        for fix: ShepherdFixRequest,
        request: ReviewRequest,
        remote: CodeHostRemote,
        worktreePath: URL
    ) async -> [ShepherdCheckLog] {
        guard !fix.failingChecks.isEmpty,
              let provider = providerRegistry.provider(for: remote.kind),
              let items = try? await provider.failedCheckEvidence(remote: remote, request: request, cwd: worktreePath)
        else { return [] }
        var logs: [ShepherdCheckLog] = []
        for check in fix.failingChecks.prefix(ShepherdPromptBuilder.maxCheckLogs) {
            // CI evidence items carry their check's id.
            guard let item = items.first(where: { $0.id == check.id }),
                  let detail = try? await provider.checkEvidenceDetail(
                      remote: remote, request: request, item: item, cwd: worktreePath
                  )
            else { continue }
            logs.append(ShepherdCheckLog(
                checkID: check.id,
                body: detail.body,
                isTruncated: detail.isTruncated,
                url: check.detailURL ?? item.providerURL
            ))
        }
        return logs
    }

    // MARK: - Transitions outside the policy

    private func escalate(_ id: ShepherdRecordID, _ reason: ShepherdEscalation, title: String?) {
        guard var record = records[id] else { return }
        record.phase = .escalated(reason)
        record.updatedAt = now()
        put(record)
        effects?.notify(.escalated(record, reason, title: title))
    }

    /// The provider answered signed in, so a sign-in pause is over, even when
    /// this poll decides nothing (the worktree is on another branch, say).
    /// An escalated record keeps waiting for Resume.
    private func endAuthPause(_ id: ShepherdRecordID) {
        guard var record = records[id], record.phase == .paused else { return }
        record.phase = .watching
        record.updatedAt = now()
        put(record)
    }

    /// The provider CLI is missing or signed out. Pauses once, with one
    /// escalation; `endAuthPause` resumes the record on the next good fetch. An
    /// escalated record keeps waiting for Resume instead.
    private func pauseForAuth(_ id: ShepherdRecordID) {
        guard var record = records[id] else { return }
        failureCounts[id] = nil
        if case .escalated = record.phase {
            scheduleNext(record, checksPending: false)
            return
        }
        if record.phase != .paused {
            record.phase = .paused
            record.updatedAt = now()
            put(record)
            effects?.notify(.escalated(record, .authFailed, title: snapshots[id]?.reviewRequest?.title))
        }
        scheduleNext(record, checksPending: false)
    }

    private func update(_ id: ShepherdRecordID, _ change: (inout ShepherdRecord) -> Void) {
        guard var record = records[id], !record.phase.isTerminal else { return }
        change(&record)
        guard record != records[id] else { return }
        record.updatedAt = now()
        put(record)
        bumpGeneration(id)
        dueAt[id] = now()
        pump()
    }

    @discardableResult
    private func bumpGeneration(_ id: ShepherdRecordID) -> Int {
        lastGeneration += 1
        generations[id] = lastGeneration
        return lastGeneration
    }

    /// Whether an action captured at `generation` may still run. Logs at
    /// debug when it may not; the next poll re-evaluates the record.
    private func isCurrent(_ id: ShepherdRecordID, _ generation: Int, before step: String) -> Bool {
        guard records[id] != nil, generations[id] == generation else {
            shepherdLogger.debug("Abandoning \(step, privacy: .public) for PR shepherd \(id.storageKey, privacy: .private): the record changed")
            return false
        }
        return true
    }

    // MARK: - Storage

    private func reviewLoop(for record: ShepherdRecord, path: URL) -> ReviewLoopState {
        if let loop = loops[record.id], loop.currentBaseBranch == record.baseBranch {
            return loop
        }
        let loop = ReviewLoopState(worktreePath: path, baseBranch: record.baseBranch, providerRegistry: providerRegistry)
        loops[record.id] = loop
        return loop
    }

    private func put(_ record: ShepherdRecord) {
        records[record.id] = record
        persist()
    }

    private func remove(_ id: ShepherdRecordID) {
        records[id] = nil
        snapshots[id] = nil
        loops[id] = nil
        dueAt[id] = nil
        failureCounts[id] = nil
        generations[id] = nil
        persist()
    }

    private func load() {
        do {
            let result = try store.readIfExistsReportingRecovery(ReviewShepherdsFile.self, from: fileURL)
            if let recoveryError = result.recoveryError {
                // The store has already moved the unreadable file aside
                // (`review-shepherds.json.broken-<time>`) so it can be inspected.
                shepherdLogger.error(
                    "PR shepherd records were unreadable and were set aside: \(String(describing: recoveryError), privacy: .public)"
                )
            }
            guard let file = result.value else { return }
            let kept = ShepherdRecordRetention.prune(file.records, now: now())
            records = Dictionary(kept.map { ($0.id, $0) }) { lhs, rhs in lhs.updatedAt >= rhs.updatedAt ? lhs : rhs }
            if kept.count != file.records.count {
                persist()
            }
        } catch {
            shepherdLogger.error("Could not read PR shepherd records: \(String(describing: error), privacy: .public)")
        }
    }

    private func persist() {
        let file = ReviewShepherdsFile(records: records.values.sorted { $0.createdAt < $1.createdAt })
        do {
            try store.write(file, to: fileURL)
        } catch {
            shepherdLogger.error("Could not save PR shepherd records: \(String(describing: error), privacy: .public)")
        }
    }
}
