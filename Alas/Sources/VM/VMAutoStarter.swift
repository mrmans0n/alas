import AlasComputerUseKit
import AlasCore
import Foundation
import Observation

/// How an agent call that found its worktree VM stopped ended its wait for the VM.
enum AutoStartResult: Equatable {
    /// The VM runs here and its helper answered, or stopped trying to: the call goes on.
    case ready
    /// The VM is still booting at the call's deadline; the boot carries on.
    case starting
    /// The slot card is still unanswered at the call's deadline; the card stays.
    case slotPending
    /// The user chose not to start the VM.
    case declined
    /// The user stopped the session, or it ended, while the call waited.
    case stopped
    /// The start failed, with why.
    case failed(String)

    /// The error the agent gets; nil when the call goes on. Main actor: the stopped message is.
    @MainActor var refusal: String? {
        switch self {
        case .ready: nil
        case .starting: VMAutoStartMessages.starting
        case .slotPending: VMAutoStartMessages.slotPending
        case .declined: VMAutoStartMessages.userDeclined
        case .stopped: ComputerUseCoordinator.stoppedMessage
        case .failed(let reason): "computer_vm_stopped: Couldn't start this worktree's VM: \(reason)"
        }
    }
}

/// The agent call an auto-start waits for, and the budget its client gives it.
enum VMAutoStartCall: Equatable {
    /// A `computer_*` call; its client waits 120 s.
    case computer
    /// A `vm_run`; its client waits `timeoutSeconds` + 30 s.
    case vmRun(timeoutSeconds: Int)

    /// How long the call waits for its VM to start.
    var waitBudget: Duration {
        switch self {
        case .computer: VMAutoStarter.defaultTimeout
        // Past 25 s a ready VM could no longer fit the command in its client's budget.
        case .vmRun: .seconds(25)
        }
    }

    /// Whether a call whose VM became ready `elapsed` after the call began still runs. Otherwise
    /// it answers `starting`, so the agent retries rather than its client timing out mid-call: a
    /// computer call needs 35 s of its budget left, a `vm_run` its whole command timeout.
    static func proceeds(_ call: VMAutoStartCall, elapsed: Duration) -> Bool {
        switch call {
        case .computer: elapsed <= .seconds(85)
        // Its client's budget is the timeout + 30 s: ready by 25 s, the whole timeout still fits.
        case .vmRun: elapsed <= .seconds(25)
        }
    }
}

/// The user's answer to a slot card.
enum VMSlotChoice: Equatable {
    /// Pause the VM with this registry id, which runs here, and start the card's VM.
    case pause(recordID: String)
    case decline
}

/// One session's card asking which VM to pause so its worktree's VM can start.
struct VMSlotRequest: Identifiable, Equatable {
    struct Candidate: Equatable {
        let recordID: String
        let name: String
    }

    let id: UUID
    let sessionID: String
    let recordID: String
    let candidates: [Candidate]
}

/// Starts a stopped worktree VM for agent calls. Calls for one VM share one start; each waits
/// for it up to its call's budget on the injected clock and then gives up on its own, leaving the start
/// running. A start that needs a free macOS slot asks every waiting session with a card, once
/// per (session, VM); the first answer wins.
/// Main actor: it holds the observable card state the session views read.
@MainActor
@Observable
final class VMAutoStarter {
    enum Phase: Equatable {
        case booting
        case slotPending(candidates: [String])
    }

    struct Waiter: Equatable {
        let sessionID: String
        let recordID: String
    }

    /// How a start's wait for its slot card ended.
    private enum SlotOutcome {
        case answered(VMSlotChoice)
        /// The sessions with a card stopped or ended, or the VM was deleted.
        case dismissed
        /// The VM started another way while the card waited.
        case startedElsewhere
    }

    /// The longest a call waits for the start.
    nonisolated static let defaultTimeout: Duration = .seconds(100)
    /// How long a start waits for the helper of a booted VM, as the VM tab's check does.
    static let helperTimeout: Duration = .seconds(120)

    /// Starts in progress, by registry id.
    private(set) var phases: [String: Phase] = [:]
    private(set) var slotRequests: [VMSlotRequest] = []
    /// Calls waiting on a start.
    private(set) var waiters: [UUID: Waiter] = [:]

    /// The registry ids of the VMs booting for agent calls.
    var starting: Set<String> { Set(phases.filter { $0.value == .booting }.keys) }

    @ObservationIgnored private var starts: [String: Task<AutoStartResult, Never>] = [:]
    @ObservationIgnored private var slotAnswers: [String: CheckedContinuation<SlotOutcome, Never>] = [:]
    /// What each waiting call ends with, once it is settled.
    @ObservationIgnored private var settled: [UUID: AutoStartResult] = [:]

    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let start: (String, VMGuestOS) async throws -> VMStartOutcome
    @ObservationIgnored private let startPausing: (String, String) async throws -> Void
    @ObservationIgnored private let isStarting: (String) -> Bool
    @ObservationIgnored private let isRunning: (String, VMGuestOS) -> Bool
    @ObservationIgnored private let helperAnswers: (String, VMGuestOS) async -> Bool
    @ObservationIgnored private let candidateName: (String) -> String
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant

    /// `start` and `startPausing` are `WorktreeVMManager.startVM`'s two forms. `isStarting` is
    /// whether a VM, by registry id, boots here already; `isRunning` whether a worktree's VM runs
    /// here. `helperAnswers` is true once the guest helper says hello, or once the VM no longer
    /// runs here.
    init(
        pollInterval: Duration = .milliseconds(250),
        start: @escaping (String, VMGuestOS) async throws -> VMStartOutcome,
        startPausing: @escaping (String, String) async throws -> Void,
        isStarting: @escaping (String) -> Bool,
        isRunning: @escaping (String, VMGuestOS) -> Bool,
        helperAnswers: @escaping (String, VMGuestOS) async -> Bool,
        candidateName: @escaping (String) -> String,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) {
        self.pollInterval = pollInterval
        self.start = start
        self.startPausing = startPausing
        self.isStarting = isStarting
        self.isRunning = isRunning
        self.helperAnswers = helperAnswers
        self.candidateName = candidateName
        self.sleep = sleep
        self.now = now
    }

    /// Whether `sessionID` has a call waiting on a VM that is booting.
    func isWaitingOnBoot(sessionID: String) -> Bool {
        waiters.values.contains { $0.sessionID == sessionID && phases[$0.recordID] == .booting }
    }

    /// Starts the worktree's VM of `guest`, or joins the start under way, and waits for it within
    /// `call`'s budget.
    func autoStart(
        worktreeID: String, guest: VMGuestOS, sessionID: String, call: VMAutoStartCall
    ) async -> AutoStartResult {
        let began = now()
        let recordID = VMIdentity.recordID(worktree: worktreeID, guest: guest)
        let id = UUID()
        // Registered before any suspension, so a session stop from here on settles it.
        waiters[id] = Waiter(sessionID: sessionID, recordID: recordID)
        defer {
            waiters[id] = nil
            settled[id] = nil
        }
        if starts[recordID] == nil { begin(worktreeID: worktreeID, guest: guest, recordID: recordID) }
        raiseSlotRequests(recordID)
        _ = await GuestSetupSteps.waitUntil(timeout: call.waitBudget, interval: pollInterval, sleep: sleep, now: now) {
            self.settled[id] != nil
        }
        if let result = settled[id] {
            return result == .ready && !VMAutoStartCall.proceeds(call, elapsed: now() - began) ? .starting : result
        }
        if case .slotPending = phases[recordID] { return .slotPending }
        return .starting
    }

    /// The user answered a slot card; it and every other card for that VM go away.
    func answer(requestID: UUID, choice: VMSlotChoice) {
        guard let request = slotRequests.first(where: { $0.id == requestID }) else { return }
        slotRequests.removeAll { $0.recordID == request.recordID }
        // Booting from here on, so a call joining before the start resumes gets no dead card.
        if case .pause = choice { phases[request.recordID] = .booting }
        slotAnswers.removeValue(forKey: request.recordID)?.resume(returning: .answered(choice))
    }

    /// The session was stopped or ended: its cards go away and its waiting calls end stopped.
    /// A start left with no card to answer ends, so the next call asks again.
    func dismiss(sessionID: String) {
        for (id, waiter) in waiters where waiter.sessionID == sessionID && settled[id] == nil {
            settled[id] = .stopped
        }
        let records = Set(slotRequests.filter { $0.sessionID == sessionID }.map(\.recordID))
        slotRequests.removeAll { $0.sessionID == sessionID }
        for recordID in records where !slotRequests.contains(where: { $0.recordID == recordID }) {
            slotAnswers.removeValue(forKey: recordID)?.resume(returning: .dismissed)
        }
    }

    /// VM `recordID` was deleted: its cards go away, a start waiting on one ends, and the calls
    /// waiting on it fail.
    func dismiss(recordID: String) {
        for (id, waiter) in waiters where waiter.recordID == recordID && settled[id] == nil {
            settled[id] = .failed("it was deleted.")
        }
        slotRequests.removeAll { $0.recordID == recordID }
        slotAnswers.removeValue(forKey: recordID)?.resume(returning: .dismissed)
    }

    private func begin(worktreeID: String, guest: VMGuestOS, recordID: String) {
        phases[recordID] = .booting
        starts[recordID] = Task {
            let result = await run(worktreeID: worktreeID, guest: guest, recordID: recordID)
            finish(recordID, result)
            return result
        }
    }

    private func run(worktreeID: String, guest: VMGuestOS, recordID: String) async -> AutoStartResult {
        do {
            // Started from its tab, or by a helper update: that boot is the one to wait for.
            if isStarting(recordID) {
                await waitForBoot(recordID)
            } else if let result = try await startOrAsk(worktreeID: worktreeID, guest: guest, recordID: recordID) {
                return result
            }
        } catch {
            return .failed(error.localizedDescription)
        }
        // Past this, the call goes on and its guest path reports a helper that never answered.
        _ = await GuestSetupSteps.waitUntil(
            timeout: Self.helperTimeout, interval: .seconds(1), sleep: sleep, now: now
        ) { await self.helperAnswers(worktreeID, guest) }
        return .ready
    }

    /// Starts the VM, asking which VM to pause when both slots are taken. Nil once it booted here,
    /// whoever started it; otherwise how the start ended.
    private func startOrAsk(worktreeID: String, guest: VMGuestOS, recordID: String) async throws -> AutoStartResult? {
        switch try await start(worktreeID, guest) {
        case .running:
            return nil
        case .runningElsewhere(let label):
            return .failed("it is running in \(label).")
        case .needsUserChoice(let candidates):
            // No VM of this process to pause: the tab says the same.
            guard !candidates.isEmpty else { return .failed("both VM slots are in use by another Alas.") }
            // Every call gave up while the start ran: nobody would see a card, so the next call asks.
            guard waiters.values.contains(where: { $0.recordID == recordID }) else { return .slotPending }
            phases[recordID] = .slotPending(candidates: candidates)
            let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<SlotOutcome, Never>) in
                slotAnswers[recordID] = continuation
                raiseSlotRequests(recordID)
                watchForAnotherStart(worktreeID: worktreeID, guest: guest, recordID: recordID)
            }
            switch outcome {
            case .dismissed, .answered(.decline):
                return .declined
            case .startedElsewhere:
                phases[recordID] = .booting
            case .answered(.pause(let other)):
                phases[recordID] = .booting
                // The user may have started it from its tab meanwhile, and the VM to pause may
                // have stopped: then a plain start has a free slot.
                if isStarting(recordID) || isRunning(worktreeID, guest) { break }
                let paused = VMIdentity.parse(recordID: other)
                if isRunning(paused.worktree, paused.guest) {
                    try await startPausing(worktreeID, other)
                } else {
                    switch try await start(worktreeID, guest) {
                    case .running: break
                    case .runningElsewhere(let label): return .failed("it is running in \(label).")
                    case .needsUserChoice: return .failed("both VM slots are in use.")
                    }
                }
            }
            if isStarting(recordID) { await waitForBoot(recordID) }
            return nil
        }
    }

    /// While the card waits, the user may start the VM another way, from its tab: the start then
    /// goes on without an answer and the cards go away.
    private func watchForAnotherStart(worktreeID: String, guest: VMGuestOS, recordID: String) {
        Task {
            // Polled on the injected clock until the card is answered or dismissed, with no deadline:
            // a card left up after its calls gave up still goes away once the VM starts.
            while slotAnswers[recordID] != nil, !isRunning(worktreeID, guest), !isStarting(recordID) {
                await sleep(pollInterval)
            }
            guard let continuation = slotAnswers.removeValue(forKey: recordID) else { return }
            slotRequests.removeAll { $0.recordID == recordID }
            continuation.resume(returning: .startedElsewhere)
        }
    }

    /// Until a boot here that something else began returns, however it ends.
    private func waitForBoot(_ recordID: String) async {
        _ = await GuestSetupSteps.waitUntil(
            timeout: Self.helperTimeout, interval: .seconds(1), sleep: sleep, now: now
        ) { !self.isStarting(recordID) }
    }

    /// One card per session waiting on `recordID`'s start, while it waits for an answer.
    private func raiseSlotRequests(_ recordID: String) {
        guard case .slotPending(let candidates) = phases[recordID], slotAnswers[recordID] != nil else { return }
        let sessions = Set(waiters.values.filter { $0.recordID == recordID }.map(\.sessionID))
        for sessionID in sessions.sorted()
            where !slotRequests.contains(where: { $0.sessionID == sessionID && $0.recordID == recordID }) {
            slotRequests.append(VMSlotRequest(
                id: UUID(), sessionID: sessionID, recordID: recordID,
                candidates: candidates.map { .init(recordID: $0, name: candidateName($0)) }
            ))
        }
    }

    private func finish(_ recordID: String, _ result: AutoStartResult) {
        starts[recordID] = nil
        phases[recordID] = nil
        slotRequests.removeAll { $0.recordID == recordID }
        for (id, waiter) in waiters where waiter.recordID == recordID && settled[id] == nil {
            settled[id] = result
        }
    }
}
