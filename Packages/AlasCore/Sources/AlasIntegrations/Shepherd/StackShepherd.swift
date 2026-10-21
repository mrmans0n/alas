import Foundation
import Observation
import os
import AlasFoundation
import AlasModel
import AlasPlatform

private let stackShepherdLogger = Logger(subsystem: "io.nlopez.alas", category: "StackShepherd")

/// The stack shepherd's records on disk, at `Paths.stackShepherdsFile`,
/// decoded per record like `ReviewShepherdsFile`.
public struct StackShepherdsFile: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var records: [StackShepherdRecord] = []

    public enum CodingKeys: String, CodingKey, Sendable {
        case version, records
    }

    public init(records: [StackShepherdRecord] = []) {
        self.records = records
    }

    private struct LenientRecord: Decodable {
        let record: StackShepherdRecord?

        init(from decoder: Decoder) throws {
            record = try? StackShepherdRecord(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        records = ((try? c.decode([LenientRecord].self, forKey: .records)) ?? []).compactMap(\.record)
    }
}

extension Paths {
    public static var stackShepherdsFile: URL {
        appSupportRoot.appendingPathComponent("stack-shepherds.json")
    }
}

/// Watches every pull or merge request of a bound gg stack while Alas runs,
/// the stack counterpart of `ReviewShepherd`. One poll reads the worktree's
/// stack from gg, every open entry's request by number, and hands them to
/// `StackShepherdPolicy`; problems in several entries go to the owner
/// session as one fix turn, bottom-up. It never merges: stacks land through
/// `gg land`, and the shepherd says when every entry is ready.
@MainActor
@Observable
public final class StackShepherd {
    public struct WorktreeContext: Equatable, Sendable {
        public let worktreeID: String
        public let path: URL
        /// The gg stack Alas's stacked-diffs settings put the worktree on;
        /// nil when gg mode is off for it.
        public let stackName: String?
        /// A local worktree outside every Workspace checkout.
        public let isEligible: Bool

        public init(worktreeID: String, path: URL, stackName: String?, isEligible: Bool) {
            self.worktreeID = worktreeID
            self.path = path
            self.stackName = stackName
            self.isEligible = isEligible
        }
    }

    public enum Event: Equatable, Sendable {
        /// Every open entry passes its checks and gate.
        case ready(StackShepherdRecord)
        case finished(StackShepherdRecord, ShepherdOutcome)
        case entryClosed(StackShepherdRecord, StackShepherdEntry, title: String)
        /// One notice per reason, naming every entry it hit.
        case escalated(StackShepherdRecord, [StackShepherdEntry], ShepherdEscalation)
    }

    public struct Effects {
        /// Nil when the worktree is gone or archived; its records are dropped.
        public var worktreeContext: @MainActor (_ worktreeID: String) -> WorktreeContext?
        /// The stack gg reports for the worktree at `path`, nil off-stack.
        public var loadStack: @MainActor (_ path: URL) async throws -> GGStack?
        /// `gg sync` through the guarded path the stack drawer's Sync uses.
        public var syncStack: @MainActor (_ worktreeID: String) async throws -> Void
        public var sessionState: @MainActor (_ sessionID: String, _ worktreeID: String) async -> ShepherdSessionState
        /// Queues `prompt` on the session; `isStillWanted` is checked right
        /// before the session's queue changes.
        public var deliverPrompt: @MainActor (
            _ sessionID: String,
            _ worktreeID: String,
            _ prompt: ShepherdPrompt,
            _ isStillWanted: @escaping @MainActor () -> Bool
        ) async -> ReviewShepherd.Delivery
        public var rules: @MainActor (_ worktreeID: String) async throws -> ShepherdRules
        public var notify: @MainActor (Event) -> Void
        public var archiveWorktreeIfAllowed: @MainActor (
            _ worktreeID: String,
            _ sessionID: String,
            _ isStillWanted: @escaping @MainActor () -> Bool
        ) async -> ReviewShepherd.ArchiveResult

        public init(
            worktreeContext: @escaping @MainActor (_ worktreeID: String) -> WorktreeContext?,
            loadStack: @escaping @MainActor (_ path: URL) async throws -> GGStack?,
            syncStack: @escaping @MainActor (_ worktreeID: String) async throws -> Void,
            sessionState: @escaping @MainActor (_ sessionID: String, _ worktreeID: String) async -> ShepherdSessionState,
            deliverPrompt: @escaping @MainActor (
                _ sessionID: String,
                _ worktreeID: String,
                _ prompt: ShepherdPrompt,
                _ isStillWanted: @escaping @MainActor () -> Bool
            ) async -> ReviewShepherd.Delivery,
            rules: @escaping @MainActor (_ worktreeID: String) async throws -> ShepherdRules,
            notify: @escaping @MainActor (Event) -> Void,
            archiveWorktreeIfAllowed: @escaping @MainActor (
                _ worktreeID: String,
                _ sessionID: String,
                _ isStillWanted: @escaping @MainActor () -> Bool
            ) async -> ReviewShepherd.ArchiveResult
        ) {
            self.worktreeContext = worktreeContext
            self.loadStack = loadStack
            self.syncStack = syncStack
            self.sessionState = sessionState
            self.deliverPrompt = deliverPrompt
            self.rules = rules
            self.notify = notify
            self.archiveWorktreeIfAllowed = archiveWorktreeIfAllowed
        }
    }

    @ObservationIgnored public var effects: Effects?
    public private(set) var records: [StackShepherdRecordID: StackShepherdRecord] = [:]
    /// The latest successful read of each record's open requests, by number.
    public private(set) var requests: [StackShepherdRecordID: [Int: ReviewRequest]] = [:]
    /// `StackShepherdPolicy`'s ready gate from the latest decision per record.
    public private(set) var gatePasses: [StackShepherdRecordID: Bool] = [:]

    @ObservationIgnored private let store: any PersistenceStoreProtocol
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let providerRegistry: CodeHostProviderRegistry
    @ObservationIgnored private let localProbe: ReviewLoopLocalProbe
    @ObservationIgnored private let operationInProgress: @MainActor (_ path: URL) -> Bool
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var dueAt: [StackShepherdRecordID: Date] = [:]
    @ObservationIgnored private var failureCounts: [StackShepherdRecordID: Int] = [:]
    @ObservationIgnored private var inFlight: Set<StackShepherdRecordID> = []
    @ObservationIgnored private var archivesInFlight: Set<StackShepherdRecordID> = []
    /// Bumped by every change made outside an evaluation and by every
    /// committed decision; see `ReviewShepherd`'s generations.
    @ObservationIgnored private var generations: [StackShepherdRecordID: Int] = [:]
    @ObservationIgnored private var lastGeneration = 0
    /// Records whose fix prompt is being prepared or delivered, with the
    /// generation of the dispatch.
    @ObservationIgnored private var deliveringFix: [StackShepherdRecordID: Int] = [:]

    public init(
        store: any PersistenceStoreProtocol,
        fileURL: URL = Paths.stackShepherdsFile,
        providerRegistry: CodeHostProviderRegistry = .live(),
        localProbe: ReviewLoopLocalProbe = .live,
        operationInProgress: @escaping @MainActor (_ path: URL) -> Bool = { GGStackGate.operationInProgress(repoPath: $0.path) },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.store = store
        self.fileURL = fileURL
        self.providerRegistry = providerRegistry
        self.localProbe = localProbe
        self.operationInProgress = operationInProgress
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
        retryPendingArchives { _ in true }
        guard let wake = ReviewShepherd.wakeNotification else { return }
        wakeObserver = wake.center.addObserver(forName: wake.name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.makeAllDue()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver, let wake = ReviewShepherd.wakeNotification {
            wake.center.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    // MARK: - Queries

    /// The session's newest record still being shepherded, else its newest
    /// finished one.
    public func record(forSession sessionID: String) -> StackShepherdRecord? {
        Self.preferred(records.values.filter { $0.sessionID == sessionID })
    }

    public func record(forWorktree worktreeID: String) -> StackShepherdRecord? {
        Self.preferred(records.values.filter { $0.id.worktreeID == worktreeID })
    }

    private static func preferred(_ candidates: [StackShepherdRecord]) -> StackShepherdRecord? {
        let newestFirst = candidates.sorted { $0.updatedAt > $1.updatedAt }
        return newestFirst.first { !$0.isFinished } ?? newestFirst.first
    }

    // MARK: - Binding and controls

    /// Binds every published entry of `stack` to `sessionID`, creating the
    /// record or moving it from another session. A new record or a new owner
    /// starts every entry fresh, as a rebound PR does, and a new owner answers
    /// every trusted thread again. The current owner publishing fixes through
    /// `stack_ship` keeps each entry's phase, attempts and dispatched
    /// fingerprint: resetting them would dispatch a fix again before the
    /// provider reports the push, and a persistently failing entry would
    /// never reach its attempt budget. The session's other live stack records
    /// are dropped. `requests` are the entries' requests, read by the caller;
    /// with `contextRules` the session is sent the context prompt built with
    /// them.
    @discardableResult
    public func bind(
        sessionID: String,
        worktreeID: String,
        stack: GGStack,
        requests: [Int: ReviewRequest],
        remote: CodeHostRemote,
        autoFix: Bool,
        maxFixAttempts: Int,
        contextRules: ShepherdRules?
    ) async -> StackShepherdRecord {
        let id = StackShepherdRecordID(worktreeID: worktreeID, stackName: stack.name)
        let now = self.now()
        for other in records.values where other.id != id && other.sessionID == sessionID && !other.isFinished {
            remove(other.id)
        }
        let existing = records[id].flatMap { $0.isFinished ? nil : $0 }
        var record = existing ?? StackShepherdRecord(
            id: id, sessionID: sessionID, remote: remote, base: stack.base,
            autoFix: autoFix, maxFixAttempts: maxFixAttempts, entries: [], now: now
        )
        let newOwner = record.sessionID != sessionID
        let startsFresh = existing == nil || newOwner
        record.sessionID = sessionID
        record.remote = remote
        record.base = stack.base
        record.autoFix = autoFix
        record.maxFixAttempts = ShepherdDefaults.clampedFixAttempts(maxFixAttempts)
        record.finishedAt = nil
        record = StackShepherdPolicy.reconcile(record, with: stack, now: now)
        for index in record.entries.indices where !record.entries[index].shepherd.phase.isTerminal {
            var shepherd = record.entries[index].shepherd
            shepherd.sessionID = sessionID
            shepherd.autoFix = autoFix
            shepherd.autoMerge = false
            shepherd.maxFixAttempts = record.maxFixAttempts
            if startsFresh {
                if newOwner { shepherd.handledThreadRevisions = nil }
                shepherd.phase = .watching
                shepherd.fixAttempts = 0
                shepherd.lastDispatchedFingerprint = nil
                shepherd.viewerCommentIDsAtDispatch = nil
            }
            record.entries[index].shepherd = shepherd
        }
        record.updatedAt = now
        put(record)
        self.requests[id] = requests
        let generation = bumpGeneration(id)
        deliveringFix[id] = nil
        failureCounts[id] = nil
        dueAt[id] = now
        if let contextRules, let effects {
            let prompt = StackShepherdPromptBuilder.bindPrompt(record: record, requests: requests, rules: contextRules)
            let delivery = await effects.deliverPrompt(sessionID, worktreeID, prompt) { [weak self] in
                self?.isCurrent(id, generation, before: "the bind delivery") ?? false
            }
            if delivery == .failed, isCurrent(id, generation, before: "the bind delivery escalation") {
                escalate(id, entries: record.openEntries, reason: .deliveryFailed)
            }
        }
        pump()
        return records[id] ?? record
    }

    public func setAutoFix(_ on: Bool, for id: StackShepherdRecordID) {
        update(id) { record in
            record.autoFix = on
            for index in record.entries.indices { record.entries[index].shepherd.autoFix = on }
        }
    }

    /// The budget only gates the next dispatch, so a fix prompt already on
    /// its way stays current. Entries the change puts back to watching are
    /// re-evaluated at once.
    public func setMaxFixAttempts(_ budget: Int, for id: StackShepherdRecordID) {
        guard let current = records[id], !current.isFinished else { return }
        var record = current
        record.setFixAttemptBudget(budget)
        guard record != current else { return }
        guard record.entries.map(\.shepherd.phase) == current.entries.map(\.shepherd.phase) else {
            update(id) { $0 = record }
            return
        }
        record.updatedAt = now()
        put(record)
    }

    /// Every escalated or paused entry back to watching with a full attempt
    /// budget.
    public func resume(_ id: StackShepherdRecordID) {
        guard let record = records[id], record.phase.isResumable else { return }
        failureCounts[id] = nil
        update(id) { record in
            for index in record.entries.indices {
                switch record.entries[index].shepherd.phase {
                case .escalated, .paused:
                    record.entries[index].shepherd.phase = .watching
                    record.entries[index].shepherd.fixAttempts = 0
                    record.entries[index].shepherd.lastDispatchedFingerprint = nil
                    record.entries[index].shepherd.viewerCommentIDsAtDispatch = nil
                default:
                    break
                }
            }
        }
    }

    /// Deletes the record. The requests are left alone.
    public func stopShepherding(_ id: StackShepherdRecordID) {
        guard records[id] != nil else { return }
        remove(id)
    }

    /// A turn of `sessionID` ended: entries it was fixing now wait for the
    /// push, unless their fix prompt is still on its way.
    public func turnCompleted(sessionID: String) {
        let now = self.now()
        for record in records.values where record.sessionID == sessionID && !isDeliveringFix(record.id) {
            var next = record
            for index in next.entries.indices {
                guard case .fixing = next.entries[index].shepherd.phase else { continue }
                next.entries[index].shepherd.phase = .awaitingPush(turnEndedAt: now, pollsWithoutProgress: 0)
            }
            guard next != record else { continue }
            next.updatedAt = now
            put(next)
            bumpGeneration(record.id)
            dueAt[record.id] = now
        }
        retryPendingArchives { $0.sessionID == sessionID }
        pump()
    }

    // MARK: - Fetching

    /// Fetches, decides and acts for one record now, ignoring its due time.
    public func evaluateNow(_ id: StackShepherdRecordID) async {
        guard records[id] != nil, !inFlight.contains(id) else { return }
        inFlight.insert(id)
        await evaluate(id)
        inFlight.remove(id)
        pump()
    }

    /// Each request read by number on `remote`, with its checks and threads.
    public func readRequests(numbers: [Int], remote: CodeHostRemote, worktreePath: URL) async throws -> [Int: ReviewRequest] {
        guard let provider = providerRegistry.provider(for: remote.kind) else {
            throw CodeHostProviderError.unsupportedProvider(remote.kind)
        }
        var requests: [Int: ReviewRequest] = [:]
        for number in numbers {
            let request = try await provider.reviewRequest(remote: remote, number: number, cwd: worktreePath)
            let checks = try await provider.checks(remote: remote, request: request, cwd: worktreePath)
            requests[number] = request.withChecks(checks)
        }
        return requests
    }

    /// Lowercased logins that reviewed `request`'s current head, nil when the
    /// provider could not say. See `ReviewShepherd.headReviewers`.
    public func headReviewers(for request: ReviewRequest, worktreePath: URL, notBefore: Date?) async -> Set<String>? {
        guard let provider = providerRegistry.provider(for: request.provider) else { return nil }
        return try? await provider.reviewersOnHead(
            remote: request.remote, request: request, notBefore: notBefore, cwd: worktreePath
        )
    }

    // MARK: - Scheduling

    private func makeAllDue() {
        let now = self.now()
        for record in records.values where !record.isFinished {
            dueAt[record.id] = now
        }
        pump()
    }

    private func pump() {
        guard timer != nil, effects != nil else { return }
        let now = self.now()
        let due = records.values
            .filter { !$0.isFinished && !inFlight.contains($0.id) && (dueAt[$0.id] ?? now) <= now }
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

    private func scheduleNext(_ record: StackShepherdRecord, checksPending: Bool) {
        dueAt[record.id] = ShepherdSchedule.interval(for: record.phase, checksPending: checksPending)
            .map { now().addingTimeInterval($0) }
    }

    private func noteFailure(_ id: StackShepherdRecordID, _ message: String) {
        let count = (failureCounts[id] ?? 0) + 1
        failureCounts[id] = count
        dueAt[id] = now().addingTimeInterval(ShepherdSchedule.backoff(afterFailures: count))
        stackShepherdLogger.notice(
            "Stack shepherd fetch for \(id.storageKey, privacy: .private) failed (\(count, privacy: .public) in a row): \(message, privacy: .public)"
        )
    }

    // MARK: - Evaluation

    private func evaluate(_ id: StackShepherdRecordID) async {
        guard let effects, let record = records[id], !record.isFinished else { return }
        dueAt[id] = now().addingTimeInterval(ShepherdSchedule.tick)
        guard let context = effects.worktreeContext(id.worktreeID), context.isEligible else {
            stackShepherdLogger.notice("Dropping stack shepherd record \(id.storageKey, privacy: .private): its worktree is gone or not eligible")
            remove(id)
            return
        }
        let stack: GGStack?
        do {
            stack = try await effects.loadStack(context.path)
        } catch {
            noteFailure(id, String(describing: error))
            return
        }
        let onStack = stack.flatMap { $0.name == id.stackName ? $0 : nil }
        if let onStack, let current = records[id] {
            let reconciled = StackShepherdPolicy.reconcile(current, with: onStack, now: now())
            if reconciled != current {
                put(reconciled)
                bumpGeneration(id)
            }
        }
        guard let reconciled = records[id] else { return }
        let probed: (local: ReviewLoopLocalState, remotes: [GitRemote])
        do {
            probed = try await localProbe.probe(context.path, reconciled.base)
        } catch {
            noteFailure(id, String(describing: error))
            return
        }
        guard let provider = providerRegistry.provider(for: reconciled.remote.kind) else {
            noteFailure(id, "\(reconciled.remote.kind.displayName) is not supported.")
            return
        }
        let fetched: [Int: ReviewRequest]
        do {
            fetched = try await readRequests(
                numbers: reconciled.openEntries.map(\.requestNumber),
                remote: reconciled.remote,
                worktreePath: context.path
            )
        } catch CodeHostProviderError.cliMissing, CodeHostProviderError.unauthenticated {
            pauseForAuth(id)
            return
        } catch {
            noteFailure(id, String(describing: error))
            return
        }
        endAuthPause(id)
        let rules: ShepherdRules
        do {
            rules = try await effects.rules(id.worktreeID)
        } catch {
            noteFailure(id, "Could not read the shepherd rules: \(error.localizedDescription)")
            return
        }
        var reviewers: [Int: Set<String>] = [:]
        if !rules.requiredReviewers.isEmpty {
            for entry in reconciled.openEntries {
                guard let request = fetched[entry.requestNumber], request.state == .open,
                      let logins = await headReviewers(
                          for: request, worktreePath: context.path,
                          notBefore: records[id]?.entry(number: entry.requestNumber)?.shepherd.headFirstSeenAt(of: request.headSHA)
                      )
                else { continue }
                reviewers[entry.requestNumber] = logins
            }
        }
        guard let owner = records[id]?.sessionID else { return }
        let session = await effects.sessionState(owner, id.worktreeID)
        // A turn may have ended or the record been rebound while this ran:
        // decide on the current record, and not at all for another owner.
        guard let current = records[id], current.sessionID == owner, !current.isFinished else { return }
        failureCounts[id] = nil
        let observation = StackShepherdObservation(
            requests: fetched,
            presentEntryIDs: onStack.map { Set($0.entries.filter { $0.prNumber != nil }.map(\.id)) },
            local: probed.local,
            capabilities: provider.capabilities,
            headReviewers: reviewers,
            session: session,
            canDispatch: onStack != nil && !operationInProgress(context.path),
            rules: rules,
            now: now()
        )
        let decision = StackShepherdPolicy.decide(current, observation)
        requests[id] = fetched
        gatePasses[id] = decision.gatePasses
        if decision.record != current { put(decision.record) }
        let generation = bumpGeneration(id)
        await execute(decision, for: id, generation: generation, before: current, rules: rules, path: context.path)
        if let latest = records[id] {
            scheduleNext(latest, checksPending: fetched.values.contains { $0.checks.contains { $0.bucket == .pending } })
        }
    }

    private func execute(
        _ decision: StackShepherdDecision,
        for id: StackShepherdRecordID,
        generation: Int,
        before: StackShepherdRecord,
        rules: ShepherdRules,
        path: URL
    ) async {
        guard let effects else { return }
        let record = decision.record
        var escalated: [ShepherdEscalation: [StackShepherdEntry]] = [:]
        for event in decision.entryEvents {
            switch event {
            case .escalated(let entry, let reason, _):
                escalated[reason, default: []].append(entry)
            case .closed(let entry, let title):
                effects.notify(.entryClosed(record, entry, title: title))
            }
        }
        for (reason, entries) in escalated.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            effects.notify(.escalated(record, entries, reason))
        }
        if decision.notifyReady {
            effects.notify(.ready(record))
        }
        if let outcome = decision.finished {
            effects.notify(.finished(record, outcome))
            if outcome == .merged { await archiveAfterMerge(id) }
            return
        }
        guard !decision.fixes.isEmpty else { return }
        deliveringFix[id] = generation
        defer {
            if deliveringFix[id] == generation { deliveringFix[id] = nil }
        }
        var logs: [Int: [ShepherdCheckLog]] = [:]
        for fix in decision.fixes {
            logs[fix.entry.requestNumber] = await checkLogs(for: fix, path: path)
        }
        guard isCurrent(id, generation, before: "fix delivery") else { return }
        let prompt = StackShepherdPromptBuilder.fixPrompt(record: record, fixes: decision.fixes, logs: logs, rules: rules)
        let delivery = await effects.deliverPrompt(record.sessionID, id.worktreeID, prompt) { [weak self] in
            self?.isCurrent(id, generation, before: "fix delivery") ?? false
        }
        guard delivery == .failed, isCurrent(id, generation, before: "the delivery rollback"),
              var failed = records[id]
        else { return }
        // The prompt never reached the session: no entry spent an attempt.
        let dispatched = Set(decision.fixes.map(\.entry.requestNumber))
        for index in failed.entries.indices where dispatched.contains(failed.entries[index].requestNumber) {
            guard let previous = before.entry(number: failed.entries[index].requestNumber)?.shepherd else { continue }
            failed.entries[index].shepherd.fixAttempts = previous.fixAttempts
            failed.entries[index].shepherd.lastDispatchedFingerprint = previous.lastDispatchedFingerprint
            failed.entries[index].shepherd.viewerCommentIDsAtDispatch = previous.viewerCommentIDsAtDispatch
        }
        put(failed)
        escalate(id, entries: decision.fixes.map(\.entry), reason: .deliveryFailed)
    }

    /// Logs for at most `ShepherdPromptBuilder.maxCheckLogs` failing checks
    /// of one entry.
    private func checkLogs(for fix: StackShepherdFix, path: URL) async -> [ShepherdCheckLog] {
        let request = fix.request
        guard !fix.problems.failingChecks.isEmpty,
              let provider = providerRegistry.provider(for: request.provider),
              let items = try? await provider.failedCheckEvidence(remote: request.remote, request: request, cwd: path)
        else { return [] }
        var logs: [ShepherdCheckLog] = []
        for check in fix.problems.failingChecks.prefix(ShepherdPromptBuilder.maxCheckLogs) {
            guard let item = items.first(where: { $0.id == check.id }),
                  let detail = try? await provider.checkEvidenceDetail(
                      remote: request.remote, request: request, item: item, cwd: path
                  )
            else { continue }
            logs.append(ShepherdCheckLog(
                checkID: check.id, body: detail.body, isTruncated: detail.isTruncated,
                url: check.detailURL ?? item.providerURL
            ))
        }
        return logs
    }

    // MARK: - Transitions outside the policy

    private func archiveAfterMerge(_ id: StackShepherdRecordID) async {
        guard let effects, let record = records[id], record.phase == .merged,
              !archivesInFlight.contains(id)
        else { return }
        archivesInFlight.insert(id)
        defer { archivesInFlight.remove(id) }
        let generation = generations[id]
        let isStillWanted: @MainActor () -> Bool = { [weak self] in
            guard let self, self.records[id]?.phase == .merged, self.generations[id] == generation else { return false }
            return true
        }
        let result = await effects.archiveWorktreeIfAllowed(id.worktreeID, record.sessionID, isStillWanted)
        guard isStillWanted(), var latest = records[id] else { return }
        let pending: Bool? = result == .deferredBusy ? true : nil
        guard latest.archivePending != pending else { return }
        latest.archivePending = pending
        latest.updatedAt = now()
        put(latest)
    }

    private func retryPendingArchives(where matches: (StackShepherdRecord) -> Bool) {
        guard effects != nil else { return }
        for record in records.values where record.archivePending == true && matches(record) {
            let id = record.id
            Task { @MainActor [weak self] in
                await self?.archiveAfterMerge(id)
            }
        }
    }

    private func escalate(_ id: StackShepherdRecordID, entries: [StackShepherdEntry], reason: ShepherdEscalation) {
        guard var record = records[id] else { return }
        let numbers = Set(entries.map(\.requestNumber))
        for index in record.entries.indices where numbers.contains(record.entries[index].requestNumber) {
            record.entries[index].shepherd.phase = .escalated(reason)
        }
        record.updatedAt = now()
        put(record)
        effects?.notify(.escalated(record, record.entries.filter { numbers.contains($0.requestNumber) }, reason))
    }

    /// The provider answered signed in: entries paused for sign-in resume.
    private func endAuthPause(_ id: StackShepherdRecordID) {
        guard var record = records[id] else { return }
        var changed = false
        for index in record.entries.indices where record.entries[index].shepherd.phase == .paused {
            record.entries[index].shepherd.phase = .watching
            changed = true
        }
        guard changed else { return }
        record.updatedAt = now()
        put(record)
    }

    /// The provider CLI is missing or signed out: pauses the open entries
    /// once, with one escalation. Escalated entries keep waiting for Resume.
    private func pauseForAuth(_ id: StackShepherdRecordID) {
        guard var record = records[id] else { return }
        failureCounts[id] = nil
        var paused: [StackShepherdEntry] = []
        for index in record.entries.indices {
            switch record.entries[index].shepherd.phase {
            case .escalated, .paused, .merged, .closed:
                continue
            default:
                record.entries[index].shepherd.phase = .paused
                paused.append(record.entries[index])
            }
        }
        if !paused.isEmpty {
            record.updatedAt = now()
            put(record)
            effects?.notify(.escalated(record, paused, .authFailed))
        }
        scheduleNext(record, checksPending: false)
    }

    private func update(_ id: StackShepherdRecordID, _ change: (inout StackShepherdRecord) -> Void) {
        guard var record = records[id], !record.isFinished else { return }
        change(&record)
        guard record != records[id] else { return }
        record.updatedAt = now()
        put(record)
        bumpGeneration(id)
        dueAt[id] = now()
        pump()
    }

    @discardableResult
    private func bumpGeneration(_ id: StackShepherdRecordID) -> Int {
        lastGeneration += 1
        generations[id] = lastGeneration
        return lastGeneration
    }

    private func isCurrent(_ id: StackShepherdRecordID, _ generation: Int, before step: String) -> Bool {
        guard records[id] != nil, generations[id] == generation else {
            stackShepherdLogger.debug("Abandoning \(step, privacy: .public) for stack shepherd \(id.storageKey, privacy: .private): the record changed")
            return false
        }
        return true
    }

    private func isDeliveringFix(_ id: StackShepherdRecordID) -> Bool {
        guard let generation = deliveringFix[id] else { return false }
        return generations[id] == generation
    }

    // MARK: - Storage

    private func put(_ record: StackShepherdRecord) {
        records[record.id] = record
        persist()
    }

    private func remove(_ id: StackShepherdRecordID) {
        records[id] = nil
        requests[id] = nil
        gatePasses[id] = nil
        dueAt[id] = nil
        failureCounts[id] = nil
        generations[id] = nil
        deliveringFix[id] = nil
        persist()
    }

    private func load() {
        do {
            let result = try store.readIfExistsReportingRecovery(StackShepherdsFile.self, from: fileURL)
            if let recoveryError = result.recoveryError {
                stackShepherdLogger.error(
                    "Stack shepherd records were unreadable and were set aside: \(String(describing: recoveryError), privacy: .public)"
                )
            }
            guard let file = result.value else { return }
            let now = self.now()
            let kept = file.records.filter { record in
                guard record.isFinished else { return true }
                return now.timeIntervalSince(record.finishedAt ?? record.updatedAt) < ShepherdRecordRetention.finishedLifetime
            }
            records = Dictionary(kept.map { ($0.id, $0) }) { lhs, rhs in lhs.updatedAt >= rhs.updatedAt ? lhs : rhs }
            if kept.count != file.records.count {
                persist()
            }
        } catch {
            stackShepherdLogger.error("Could not read stack shepherd records: \(String(describing: error), privacy: .public)")
        }
    }

    private func persist() {
        let file = StackShepherdsFile(records: records.values.sorted { $0.createdAt < $1.createdAt })
        do {
            try store.write(file, to: fileURL)
        } catch {
            stackShepherdLogger.error("Could not save stack shepherd records: \(String(describing: error), privacy: .public)")
        }
    }
}
