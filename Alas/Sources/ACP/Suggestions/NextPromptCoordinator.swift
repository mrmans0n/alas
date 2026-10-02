import Combine
import Foundation

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
        var hasPendingInput = false
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
        guard environment.isEnabled, environment.hasVerifiedModel, environment.isRuntimeAvailable,
              environment.isAppActive, environment.isActiveVisibleWriter, environment.hasComposerFocus,
              !environment.hasPendingInput, !environment.hasSelection, !environment.hasMarkedText,
              !environment.isDictating, !environment.isPickerPresented,
              !environment.hasPromptWork, !environment.hasForkOrDelegationWork,
              session.id == turn.sessionID, session.incarnation == turn.incarnation,
              session.nextPromptID == turn.promptID + 1,
              transcript.messagesGeneration == turn.transcriptRevision,
              session.agentState == .ready, session.hydrationState == .ready,
              session.nextPromptWorkCount == 0, !session.hasPendingDelegatedMessages,
              !session.subagents.values.contains(where: { $0.isRunning }),
              session.composerDraft.isEmpty, session.queue.isEmpty,
              session.pendingQueuePersistenceCount == 0,
              transcript.streamingState == .idle,
              transcript.pendingPermission == nil, transcript.pendingQuestion == nil,
              transcript.pendingPlan == nil, transcript.pendingUserInputs.isEmpty,
              transcript.urlElicitationWaits.isEmpty,
              session.retryStatus == nil, session.connectionRecoveryState == nil,
              session.contextRestoreWarning == nil,
              session.contextRecoveryStatus == nil || session.contextRecoveryStatus == .restored,
              session.forkRecord?.phase != .negotiatingNative,
              session.forkRecord?.contextDeliveryPending != true,
              !session.autoRunEnabled,
              let turns = NextPromptContext.snapshot(session: session, completedUserID: turn.userMessageID)
        else { return nil }
        return .init(id: .init(sessionID: session.id, incarnation: session.incarnation, promptID: turn.promptID,
                              transcriptRevision: transcript.messagesGeneration,
                              draftRevision: session.composerDraftRevision,
                              composerEpoch: environment.composerEpoch,
                              settingsGeneration: environment.settingsGeneration,
                              modelGeneration: environment.modelGeneration),
                     turns: turns, isEligible: true)
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
        guard turn.promptID > consumedPromptIDs[turn.incarnation, default: -1] else { return }
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
    func invalidate(incarnation: UUID) {
        guard let opportunity = opportunities[incarnation] else {
            if activeIncarnation == incarnation { deactivateActive() }
            return
        }
        consumedPromptIDs[incarnation] = max(
            consumedPromptIDs[incarnation, default: -1],
            opportunity.turn.promptID
        )
        opportunities[incarnation] = nil
        if activeIncarnation == incarnation { deactivateActive() }
    }

    /// Permanently consumes a prompt even when its completion has not arrived yet.
    func invalidate(incarnation: UUID, throughPromptID promptID: Int) {
        invalidate(incarnation: incarnation)
        consumedPromptIDs[incarnation] = max(
            consumedPromptIDs[incarnation, default: -1],
            promptID
        )
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
                  self.activeIncarnation == turn.incarnation else { return }
            self.generationTask = nil
            self.deadlineTask?.cancel()
            self.deadlineTask = nil
            guard !Task.isCancelled, clock.now() < deadline,
                  self.matchingSnapshot(for: turn)?.id == request.id else {
                self.invalidate(incarnation: turn.incarnation)
                return
            }
            switch result {
            case .success(let text?):
                self.consumedPromptIDs[turn.incarnation] = max(
                    self.consumedPromptIDs[turn.incarnation, default: -1],
                    turn.promptID
                )
                self.opportunities[turn.incarnation]?.state = .offered(request.id, text)
                self.offer = text
                // @Published stores after notifying; a subscriber may have invalidated this value.
                if self.epoch != capturedEpoch { self.offer = nil }
            case .success(nil), .failure:
                self.invalidate(incarnation: turn.incarnation)
            }
        }
        deadlineTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(deadline)
                try Task.checkCancellation()
                guard let self, self.epoch == capturedEpoch else { return }
                self.invalidate(incarnation: turn.incarnation)
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
