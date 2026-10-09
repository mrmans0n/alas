import Combine
import Foundation
import os

struct NextPromptEligibilitySnapshot {
    let id: NextPromptRequestID
    let turns: [NextPromptTurn]
    let isEligible: Bool

    /// Facts owned outside the session. Defaults deny an offer until the live UI/runtime supplies them.
    struct Environment: Equatable {
        var isEnabled = false
        var hasVerifiedModel = false
        var isRuntimeAvailable = false
        var isAppActive = false
        var isActiveVisibleWriter = false
        var hasComposerFocus = false
        var hasKeyWindow = false
        /// Input the user made after the turn; it consumes the turn's suggestion.
        var hasPendingInput = false
        /// The composer cannot take a suggestion right now (a submit awaiting its turn,
        /// an inactive tab, setup). Blocks presentation without consuming the turn.
        var isInputBlocked = false
        /// The user's own submit is awaiting its turn. What its clear reports (a stale
        /// caret, a dismissal) is not input after the turn, so it must not consume it.
        var hasSubmitInFlight = false
        var hasSelection = false
        var hasMarkedText = false
        var isDictating = false
        var isPickerPresented = false
        var hasPromptWork = false
        var hasForkOrDelegationWork = false
        var composerEpoch: UInt64 = 0
        var settingsGeneration: UInt64 = 0
        var modelGeneration: UInt64 = 0
    }

    @MainActor
    static func live(session: ACPSession, turn: NextPromptCompletedTurn,
                     environment: Environment) -> Self? {
        let transcript = session.transcript
        if let failed = firstFailedCheck(session: session, turn: turn, environment: environment) {
            NextPromptIneligibility.log(turn, failed)
            return nil
        }
        guard let turns = NextPromptContext.snapshot(session: session, completedUserID: turn.userMessageID) else {
            NextPromptIneligibility.log(turn, "no usable context")
            return nil
        }
        return .init(id: .init(sessionID: session.id, incarnation: session.incarnation, promptID: turn.promptID,
                              transcriptRevision: transcript.messagesGeneration,
                              draftRevision: session.composerDraftRevision,
                              composerEpoch: environment.composerEpoch,
                              settingsGeneration: environment.settingsGeneration,
                              modelGeneration: environment.modelGeneration),
                     turns: turns, isEligible: true)
    }
    /// Names the first live gate that blocks an offer, so diagnostics can say why none appeared.
    @MainActor
    private static func firstFailedCheck(session: ACPSession, turn: NextPromptCompletedTurn,
                                         environment: Environment) -> String? {
        let transcript = session.transcript
        guard environment.isEnabled else { return "disabled" }
        guard environment.hasVerifiedModel else { return "model not verified" }
        guard environment.isRuntimeAvailable else { return "runtime unavailable" }
        guard environment.isAppActive else { return "app inactive" }
        guard environment.isActiveVisibleWriter else { return "not the active visible writer" }
        guard environment.hasComposerFocus else { return "composer unfocused" }
        guard !environment.hasPendingInput else { return "pending input" }
        guard !environment.isInputBlocked else { return "input blocked" }
        guard !environment.hasSelection else { return "selection" }
        guard !environment.hasMarkedText else { return "marked text" }
        guard !environment.isDictating else { return "dictating" }
        guard !environment.isPickerPresented else { return "picker presented" }
        guard !environment.hasPromptWork else { return "prompt work" }
        guard !environment.hasForkOrDelegationWork else { return "fork or delegation work" }
        guard session.id == turn.sessionID, session.incarnation == turn.incarnation else { return "other session" }
        guard session.nextPromptID == turn.promptID + 1 else { return "newer prompt" }
        guard transcript.messagesGeneration == turn.transcriptRevision else { return "transcript changed" }
        guard session.agentState == .ready else { return "agent not ready" }
        guard session.hydrationState == .ready else { return "not hydrated" }
        guard session.nextPromptWorkCount == 0 else { return "session work" }
        guard !session.hasPendingDelegatedMessages else { return "delegated messages" }
        guard !session.subagents.values.contains(where: { $0.isRunning }) else { return "running subagents" }
        guard session.composerDraft.isEmpty else { return "draft" }
        guard session.queue.isEmpty, session.pendingQueuePersistenceCount == 0 else { return "queue" }
        guard transcript.streamingState == .idle else { return "streaming" }
        guard transcript.pendingPermission == nil, transcript.pendingQuestion == nil,
              transcript.pendingPlan == nil, transcript.pendingUserInputs.isEmpty,
              transcript.urlElicitationWaits.isEmpty else { return "pending request" }
        guard session.retryStatus == nil, session.connectionRecoveryState == nil,
              session.contextRestoreWarning == nil,
              session.contextRecoveryStatus == nil || session.contextRecoveryStatus == .restored
        else { return "retry or recovery" }
        guard session.forkRecord?.phase != .negotiatingNative,
              session.forkRecord?.contextDeliveryPending != true else { return "fork negotiation" }
        guard !session.autoRunEnabled else { return "auto-run" }
        return nil
    }
}

@MainActor
final class NextPromptCoordinator: ObservableObject {
    @Published private(set) var offer: String?
    private(set) var generationTask: Task<Void, Never>?
    private let engine: any NextPromptGenerating
    private let snapshot: @MainActor (NextPromptCompletedTurn) -> NextPromptEligibilitySnapshot?
    private let clock: NextPromptInference.Clock
    private var opportunities: [UUID: Opportunity] = [:]
    private var activeIncarnation: UUID?
    private var requestID: NextPromptRequestID?
    private var epoch: UInt64 = 0
    private var consumedPromptIDs: [UUID: Int] = [:]
    private var deadlineTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var hasUsedEngine = false

    private struct Opportunity {
        let turn: NextPromptCompletedTurn
        var state: State

        enum State {
            case pending
            case generating(NextPromptRequestID)
            case offered(NextPromptRequestID, String)
        }
    }

    init(engine: any NextPromptGenerating,
         clock: NextPromptInference.Clock = .init(),
         snapshot: @escaping @MainActor (NextPromptCompletedTurn) -> NextPromptEligibilitySnapshot?) {
        self.engine = engine
        self.clock = clock
        self.snapshot = snapshot
    }

    deinit {
        generationTask?.cancel()
        deadlineTask?.cancel()
        if hasUsedEngine {
            let engine = engine, previous = drainTask
            Task {
                await previous?.value
                await engine.cancel()
            }
        }
    }

    func completed(_ turn: NextPromptCompletedTurn) {
        nextPromptLogger.notice("prompt \(turn.promptID) completed")
        guard turn.promptID > consumedPromptIDs[turn.incarnation, default: -1] else {
            nextPromptLogger.notice("prompt \(turn.promptID) skipped: already consumed")
            return
        }
        if let current = opportunities[turn.incarnation] {
            guard turn.promptID >= current.turn.promptID else { return }
            if turn.promptID == current.turn.promptID {
                reconsider(incarnation: turn.incarnation)
                return
            }
            invalidate(incarnation: turn.incarnation)
            guard opportunities[turn.incarnation] == nil else { return }
        }
        opportunities[turn.incarnation] = Opportunity(turn: turn, state: .pending)
        reconsider(incarnation: turn.incarnation)
    }

    /// Rechecks a retained live turn after temporary presentation blockers clear.
    func reconsider(incarnation: UUID) {
        guard let opportunity = opportunities[incarnation],
              let current = matchingSnapshot(for: opportunity.turn) else { return }
        switch opportunity.state {
        case .generating:
            return
        case .offered(let id, let text):
            guard current.id == id else {
                invalidate(incarnation: incarnation)
                return
            }
            if activeIncarnation != incarnation {
                suspendActive()
            }
            activeIncarnation = incarnation
            requestID = id
            offer = text
        case .pending:
            if activeIncarnation != incarnation {
                suspendActive()
            }
            startGeneration(opportunity.turn, snapshot: current)
        }
    }

    /// Hides presentation and cancels in-flight work without consuming the live turn.
    func suspend(incarnation: UUID) {
        guard activeIncarnation == incarnation else { return }
        suspendActive()
    }

    /// Permanently consumes the retained opportunity for one live session.
    func invalidate(incarnation: UUID, reason: String = "invalidated") {
        guard let opportunity = opportunities[incarnation] else {
            if activeIncarnation == incarnation { deactivateActive() }
            return
        }
        nextPromptLogger.notice("prompt \(opportunity.turn.promptID) dropped: \(reason, privacy: .public)")
        consumedPromptIDs[incarnation] = max(
            consumedPromptIDs[incarnation, default: -1],
            opportunity.turn.promptID
        )
        opportunities[incarnation] = nil
        if activeIncarnation == incarnation { deactivateActive() }
    }

    /// Permanently consumes a prompt even when its completion has not arrived yet.
    func invalidate(incarnation: UUID, throughPromptID promptID: Int, reason: String = "invalidated") {
        invalidate(incarnation: incarnation, reason: reason)
        guard promptID > consumedPromptIDs[incarnation, default: -1] else { return }
        nextPromptLogger.notice("prompts through \(promptID) consumed: \(reason, privacy: .public)")
        consumedPromptIDs[incarnation] = promptID
    }
    func invalidate(sessionID: String) {
        let incarnations = opportunities.values
            .filter { $0.turn.sessionID == sessionID }
            .map(\.turn.incarnation)
        for incarnation in incarnations {
            invalidate(incarnation: incarnation)
        }
    }

    /// Permanently consumes the currently presented or generating opportunity.
    func invalidate() {
        guard let activeIncarnation else { return }
        invalidate(incarnation: activeIncarnation)
    }

    func invalidateAll() {
        let retained = opportunities.values.map(\.turn)
        for turn in retained { nextPromptLogger.notice("prompt \(turn.promptID) dropped: invalidate all") }
        opportunities.removeAll()
        for turn in retained {
            consumedPromptIDs[turn.incarnation] = max(
                consumedPromptIDs[turn.incarnation, default: -1],
                turn.promptID
            )
        }
        deactivateActive()
    }

    func shutdown() async {
        invalidateAll()
        await drainTask?.value
    }

    /// Called when the live session object is removed, not when its tab loses focus.
    func sessionEnded(incarnation: UUID) {
        opportunities[incarnation] = nil
        if activeIncarnation == incarnation { deactivateActive() }
        consumedPromptIDs[incarnation] = nil
    }

    func takeOffer() -> String? {
        guard let incarnation = activeIncarnation,
              let opportunity = opportunities[incarnation],
              case .offered(let id, let text) = opportunity.state,
              requestID == id,
              matchingSnapshot(for: opportunity.turn)?.id == id
        else {
            invalidate()
            return nil
        }
        consumedPromptIDs[incarnation] = max(
            consumedPromptIDs[incarnation, default: -1],
            opportunity.turn.promptID
        )
        opportunities[incarnation] = nil
        requestID = nil
        activeIncarnation = nil
        offer = nil
        return text
    }

    private func startGeneration(
        _ turn: NextPromptCompletedTurn,
        snapshot current: NextPromptEligibilitySnapshot
    ) {
        activeIncarnation = turn.incarnation
        requestID = current.id
        opportunities[turn.incarnation]?.state = .generating(current.id)
        let request = NextPromptRequest(id: current.id, turns: current.turns)
        let capturedEpoch = epoch
        let deadline = clock.now().advanced(by: .seconds(15))
        let previousDrain = drainTask
        hasUsedEngine = true
        nextPromptLogger.notice("prompt \(turn.promptID) generating from \(current.turns.count) turns")
        generationTask = Task { [weak self, engine, clock] in
            await previousDrain?.value
            guard !Task.isCancelled, clock.now() < deadline else { return }
            let result: Result<String?, Error>
            do {
                result = .success(try await engine.generate(request))
            } catch {
                result = .failure(error)
            }
            guard let self, self.epoch == capturedEpoch, self.requestID == request.id,
                  self.activeIncarnation == turn.incarnation else {
                nextPromptLogger.notice("prompt \(turn.promptID) result discarded: superseded")
                return
            }
            self.generationTask = nil
            self.deadlineTask?.cancel()
            self.deadlineTask = nil
            guard !Task.isCancelled, clock.now() < deadline,
                  self.matchingSnapshot(for: turn)?.id == request.id else {
                self.invalidate(incarnation: turn.incarnation, reason: "stale after generation")
                return
            }
            switch result {
            case .success(let text?):
                self.consumedPromptIDs[turn.incarnation] = max(
                    self.consumedPromptIDs[turn.incarnation, default: -1],
                    turn.promptID
                )
                nextPromptLogger.notice("prompt \(turn.promptID) offered \(text.count) characters")
                self.opportunities[turn.incarnation]?.state = .offered(request.id, text)
                self.offer = text
                // @Published stores after notifying; a subscriber may have invalidated this value.
                if self.epoch != capturedEpoch { self.offer = nil }
            case .success(nil):
                self.invalidate(incarnation: turn.incarnation, reason: "model abstained")
            case .failure(let error):
                self.invalidate(incarnation: turn.incarnation,
                                reason: "generation failed: \(String(describing: type(of: error)))")
            }
        }
        deadlineTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(deadline)
                try Task.checkCancellation()
                guard let self, self.epoch == capturedEpoch else { return }
                self.invalidate(incarnation: turn.incarnation, reason: "deadline")
            } catch {}
        }
    }

    private func suspendActive() {
        if let incarnation = activeIncarnation,
           case .generating = opportunities[incarnation]?.state {
            opportunities[incarnation]?.state = .pending
        }
        deactivateActive()
    }

    private func deactivateActive() {
        requestID = nil
        activeIncarnation = nil
        epoch &+= 1
        let oldDeadline = deadlineTask
        let oldGeneration = generationTask
        deadlineTask = nil
        generationTask = nil
        if hasUsedEngine {
            hasUsedEngine = false
            let previous = drainTask
            drainTask = Task { [engine] in
                await previous?.value
                await engine.cancel()
            }
        }
        offer = nil
        oldDeadline?.cancel()
        oldGeneration?.cancel()
    }

    private func matchingSnapshot(for turn: NextPromptCompletedTurn) -> NextPromptEligibilitySnapshot? {
        guard let current = snapshot(turn), current.isEligible,
              current.id.sessionID == turn.sessionID,
              current.id.incarnation == turn.incarnation,
              current.id.promptID == turn.promptID,
              current.id.transcriptRevision == turn.transcriptRevision else { return nil }
        return current
    }
}
