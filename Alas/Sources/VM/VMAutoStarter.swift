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
/// for it up to `timeout` on the injected clock and then gives up on its own, leaving the start
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

    /// How long a call waits for the start.
    static let defaultTimeout: Duration = .seconds(100)
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
    @ObservationIgnored private var slotAnswers: [String: CheckedContinuation<VMSlotChoice?, Never>] = [:]
    /// What each waiting call ends with, once it is settled.
    @ObservationIgnored private var settled: [UUID: AutoStartResult] = [:]

    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let start: (String, VMGuestOS) async throws -> VMStartOutcome
    @ObservationIgnored private let startPausing: (String, String) async throws -> Void
    @ObservationIgnored private let helperAnswers: (String, VMGuestOS) async -> Bool
    @ObservationIgnored private let candidateName: (String) -> String
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant

    /// `start` and `startPausing` are `WorktreeVMManager.startVM`'s two forms. `helperAnswers`
    /// is true once the guest helper says hello, or once the VM no longer runs here.
    init(
        timeout: Duration = defaultTimeout,
        pollInterval: Duration = .milliseconds(250),
        start: @escaping (String, VMGuestOS) async throws -> VMStartOutcome,
        startPausing: @escaping (String, String) async throws -> Void,
        helperAnswers: @escaping (String, VMGuestOS) async -> Bool,
        candidateName: @escaping (String) -> String,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) {
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.start = start
        self.startPausing = startPausing
        self.helperAnswers = helperAnswers
        self.candidateName = candidateName
        self.sleep = sleep
        self.now = now
    }

    /// Whether `sessionID` has a call waiting on a VM that is booting.
    func isWaitingOnBoot(sessionID: String) -> Bool {
        waiters.values.contains { $0.sessionID == sessionID && phases[$0.recordID] == .booting }
    }

    /// Starts the worktree's VM of `guest`, or joins the start under way, and waits for it.
    func autoStart(worktreeID: String, guest: VMGuestOS, sessionID: String) async -> AutoStartResult {
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
        _ = await GuestSetupSteps.waitUntil(timeout: timeout, interval: pollInterval, sleep: sleep, now: now) {
            self.settled[id] != nil
        }
        if let result = settled[id] { return result }
        if case .slotPending = phases[recordID] { return .slotPending }
        return .starting
    }

    /// The user answered a slot card; it and every other card for that VM go away.
    func answer(requestID: UUID, choice: VMSlotChoice) {
        guard let request = slotRequests.first(where: { $0.id == requestID }) else { return }
        slotRequests.removeAll { $0.recordID == request.recordID }
        slotAnswers.removeValue(forKey: request.recordID)?.resume(returning: choice)
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
            slotAnswers.removeValue(forKey: recordID)?.resume(returning: nil)
        }
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
            switch try await start(worktreeID, guest) {
            case .running:
                break
            case .runningElsewhere(let label):
                return .failed("it is running in \(label).")
            case .needsUserChoice(let candidates):
                // No VM of this process to pause: the tab says the same.
                guard !candidates.isEmpty else { return .failed("both VM slots are in use by another Alas.") }
                phases[recordID] = .slotPending(candidates: candidates)
                raiseSlotRequests(recordID)
                let choice = await withCheckedContinuation { slotAnswers[recordID] = $0 }
                guard case .pause(let other) = choice else { return .declined }
                phases[recordID] = .booting
                try await startPausing(worktreeID, other)
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

    /// One card per session waiting on `recordID`'s start, while it needs a slot.
    private func raiseSlotRequests(_ recordID: String) {
        guard case .slotPending(let candidates) = phases[recordID] else { return }
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
