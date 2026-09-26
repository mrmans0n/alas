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
    private let snapshot: @MainActor () -> NextPromptEligibilitySnapshot?
    private let clock: NextPromptInference.Clock
    private var requestID: NextPromptRequestID?
    private var epoch: UInt64 = 0
    private var consumedPromptIDs: [UUID: Int] = [:]
    private var deadlineTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var hasUsedEngine = false

    init(engine: any NextPromptGenerating,
         clock: NextPromptInference.Clock = .init(),
         snapshot: @escaping @MainActor () -> NextPromptEligibilitySnapshot?) {
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
        consumedPromptIDs[turn.incarnation] = turn.promptID
        let current = snapshot()
        guard current?.id.incarnation == turn.incarnation || requestID?.incarnation == turn.incarnation else { return }
        let nextEpoch = epoch &+ 1
        invalidate()
        guard epoch == nextEpoch, let current, current.isEligible,
              current.id.sessionID == turn.sessionID,
              current.id.incarnation == turn.incarnation,
              current.id.promptID == turn.promptID,
              current.id.transcriptRevision == turn.transcriptRevision else { return }
        requestID = current.id
        let request = NextPromptRequest(id: current.id, turns: current.turns)
        let capturedEpoch = epoch
        let deadline = clock.now().advanced(by: .seconds(15))
        let previousDrain = drainTask
        hasUsedEngine = true
        generationTask = Task { [weak self, engine, clock] in
            await previousDrain?.value
            guard !Task.isCancelled, clock.now() < deadline else { return }
            let text = try? await engine.generate(request)
            guard let self, self.epoch == capturedEpoch, self.requestID == request.id else { return }
            self.generationTask = nil
            self.deadlineTask?.cancel()
            self.deadlineTask = nil
            guard !Task.isCancelled, clock.now() < deadline,
                  self.matchesCurrentSnapshot(request.id) else {
                self.invalidate()
                return
            }
            self.offer = text
            // @Published stores after notifying; a subscriber may have invalidated this value.
            if self.epoch != capturedEpoch { self.offer = nil }
        }
        deadlineTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(deadline)
                try Task.checkCancellation()
                guard let self, self.epoch == capturedEpoch else { return }
                self.invalidate()
            } catch {}
        }
    }

    func invalidate() {
        // Detach old work before publishing; an observer may start a newer completion.
        requestID = nil
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

    func shutdown() async {
        invalidate()
        await drainTask?.value
    }

    /// Called when the live session object is removed, not when its tab loses focus.
    func sessionEnded(incarnation: UUID) {
        consumedPromptIDs[incarnation] = nil
        if requestID?.incarnation == incarnation { invalidate() }
    }

    func takeOffer() -> String? {
        guard let id = requestID else { return nil }
        guard matchesCurrentSnapshot(id), let text = offer else {
            invalidate()
            return nil
        }
        requestID = nil
        offer = nil
        return text
    }

    private func matchesCurrentSnapshot(_ id: NextPromptRequestID) -> Bool {
        guard let current = snapshot() else { return false }
        return current.isEligible && current.id == id
    }
}
