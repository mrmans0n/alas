import Foundation
import AlasFoundation
import AlasACP
import AlasSessions

/// One unattended review turn: the prompt a reviewer agent answers in a
/// hidden read-only session of `parentSessionID`.
public struct ACPReviewTurnRequest: Sendable {
    public var parentSessionID: ACPSession.ID
    /// The reviewer of an earlier round, reused while it is live and idle.
    public var reuseSessionID: ACPSession.ID?
    public var agentID: String
    public var modelID: String?
    public var title: String
    public var prompt: String
    public var timeout: Duration

    public init(
        parentSessionID: ACPSession.ID,
        reuseSessionID: ACPSession.ID?,
        agentID: String,
        modelID: String?,
        title: String,
        prompt: String,
        timeout: Duration
    ) {
        self.parentSessionID = parentSessionID
        self.reuseSessionID = reuseSessionID
        self.agentID = agentID
        self.modelID = modelID
        self.title = title
        self.prompt = prompt
        self.timeout = timeout
    }
}

public enum ACPReviewTurnFailure: Error, Equatable, Sendable {
    case attachFailed(String), cannotRunReadOnly, notAccepted, timedOut, turnFailed(String)
}

public enum ACPReviewTurnOutcome: Equatable, Sendable {
    case finished(sessionID: ACPSession.ID, finalText: String)
    case failed(sessionID: ACPSession.ID?, ACPReviewTurnFailure)
}

/// How a review turn's wait ended.
enum ACPReviewTurnSettlement: Sendable {
    case completed(ACPTurnCompletion)
    case failed(ACPReviewTurnFailure)
}

/// A review turn's wait, resumed once by whichever ends it first: the turn's
/// completion, its timeout, a cancelled caller, or the end of its session.
/// Whoever removes it from `reviewTurnWaiters` resumes it.
struct ACPReviewTurnWaiter {
    let token: UUID
    let continuation: CheckedContinuation<ACPReviewTurnSettlement, Never>
    var timeout: Task<Void, Never>?
    /// Holds a finished turn until its last messages are in the transcript.
    var drain: ChangeSubscription?
}

extension ACPSessionManager {
    /// Runs one turn of `request.prompt` in an unattended read-only reviewer
    /// session and returns the turn's whole final message. An agent whose
    /// read-only mode Alas can't rely on is refused before any session
    /// starts. A session that can't attach or enter a read-only mode is
    /// discarded; any other session is kept for the next round, and
    /// `discardReviewSession(id:)` ends it.
    public func runReviewTurn(_ request: ACPReviewTurnRequest) async -> ACPReviewTurnOutcome {
        // Nobody watches this session: tools the agent runs without asking
        // could edit the worktree.
        guard ACPSideQuestionSupportPolicy.enforcesReadOnly(agentId: request.agentID) else {
            return .failed(sessionID: nil, .cannotRunReadOnly)
        }
        let session = await reviewSession(for: request)
        let id = session.id
        guard sessions[id] === session, session.agentState == .ready else {
            let failure = Self.attachFailure(session.agentState)
            await discardReviewSession(id: id)
            return .failed(sessionID: id, failure)
        }
        // A mode Alas relies on, or no review.
        guard await enterReadOnlyMode(session), sessions[id] === session else {
            await discardReviewSession(id: id)
            return .failed(sessionID: id, .cannotRunReadOnly)
        }
        let settlement = await awaitReviewTurn(in: session, prompt: request.prompt, timeout: request.timeout)
        switch settlement {
        case .failed(let failure):
            return .failed(sessionID: id, failure)
        case .completed(let completion):
            guard let reason = Self.turnFailure(completion.result) else {
                return .finished(sessionID: id, finalText: Self.reviewFinalText(session.transcript.messages))
            }
            return .failed(sessionID: id, .turnFailed(reason))
        }
    }

    /// Closes a reviewer session and deletes it with its transcript. A turn
    /// still waiting in it fails. Ignores any session that isn't a reviewer.
    public func discardReviewSession(id: ACPSession.ID) async {
        guard sessions[id]?.unattendedReview
            ?? (cachedPersistedSessionRow(id: id)?.ephemeralParentId != nil)
        else { return }
        await discardSideSession(id: id)
    }

    /// The runner's report of `sessionId`'s finished turn. A turn reported
    /// ahead of its output boundary waits for it: the boundary applies the
    /// turn's last buffered messages, then idles the transcript.
    func reviewTurnCompleted(_ completion: ACPTurnCompletion, sessionId: ACPSession.ID) {
        guard let waiter = reviewTurnWaiters[sessionId], waiter.drain == nil else { return }
        let token = waiter.token
        guard completion.result == .completed,
              let session = sessions[sessionId],
              !session.settlesAtResult,
              session.transcript.streamingState != .idle
        else {
            settleReviewTurn(sessionId, token: token, with: .completed(completion))
            return
        }
        reviewTurnWaiters[sessionId]?.drain = session.transcript.$streamingState.signal.observe { [weak self] state in
            guard state == .idle else { return }
            self?.settleReviewTurn(sessionId, token: token, with: .completed(completion))
        }
    }

    /// Fails the turn waiting in `sessionId`, whose runner or session is going away.
    func endReviewTurn(sessionId: ACPSession.ID) {
        settleReviewTurn(sessionId, with: .failed(.turnFailed("the reviewer session ended")))
    }

    func endAllReviewTurns() {
        for id in Array(reviewTurnWaiters.keys) {
            endReviewTurn(sessionId: id)
        }
    }

    /// The earlier round's reviewer when it can take another turn as it is;
    /// otherwise a new reviewer, attached, and the earlier one discarded.
    private func reviewSession(for request: ACPReviewTurnRequest) async -> ACPSession {
        if let previousID = request.reuseSessionID,
           let previous = liveSession(for: previousID),
           previous.unattendedReview {
            if previous.agentId == request.agentID,
               previous.agentState == .ready,
               previous.transcript.streamingState == .idle,
               reviewTurnWaiters[previousID] == nil {
                return previous
            }
            await discardReviewSession(id: previousID)
        }
        let session = createSession(
            id: UUID().uuidString,
            agentId: request.agentID,
            ephemeralParentID: request.parentSessionID,
            ephemeralTitle: request.title
        )
        session.unattendedReview = true
        if let modelID = request.modelID {
            pendingModel[session.id] = modelID
        }
        await attach(to: session.id, freshlyCreated: true)
        return session
    }

    /// Why an attached reviewer isn't ready. Attach enters the read-only mode
    /// itself, and fails the session when it can't.
    private static func attachFailure(_ state: ACPSession.AgentState) -> ACPReviewTurnFailure {
        switch state {
        case .failed(let reason) where reason == ACPSideQuestionError.unsafeMode.localizedDescription:
            .cannotRunReadOnly
        case .failed(let reason):
            .attachFailed(reason)
        case .idle, .spawning, .ready, .disconnected:
            .attachFailed("the reviewer agent didn't start")
        }
    }

    /// Why a turn left no review; nil for a turn that ended normally.
    private static func turnFailure(_ result: ACPTurnCompletion.Result) -> String? {
        switch result {
        case .completed: nil
        case .failed(let message): message
        case .cancelled: "the turn was cancelled"
        case .stopped(let reason): reason.summary
        case .limited: "the reviewer hit a usage limit"
        }
    }

    /// Sends `prompt` and waits for the turn it starts. The waiter is
    /// registered before the prompt goes out, so no completion is missed.
    private func awaitReviewTurn(
        in session: ACPSession,
        prompt: String,
        timeout: Duration
    ) async -> ACPReviewTurnSettlement {
        let id = session.id
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                reviewTurnWaiters[id] = ACPReviewTurnWaiter(token: token, continuation: continuation)
                let accepted = submit(sessionId: id, text: prompt, attachments: [], intent: .auto) { [weak self] sent in
                    // A prompt that never reached the agent reports no turn.
                    if !sent {
                        self?.settleReviewTurn(id, token: token, with: .failed(.notAccepted))
                    }
                }
                guard accepted else {
                    settleReviewTurn(id, token: token, with: .failed(.notAccepted))
                    return
                }
                reviewTurnWaiters[id]?.timeout = Task { [weak self] in
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    await self?.stopReviewTurn(id, token: token, with: .timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.stopReviewTurn(id, token: token, with: .turnFailed("the review was cancelled"))
            }
        }
    }

    /// Cancels the turn, then reports `failure`. The waiter is taken first,
    /// so the cancelled turn's own completion finds none.
    private func stopReviewTurn(_ id: ACPSession.ID, token: UUID, with failure: ACPReviewTurnFailure) async {
        guard let waiter = takeReviewTurnWaiter(id, token: token) else { return }
        await interrupt(for: id)
        waiter.timeout?.cancel()
        waiter.continuation.resume(returning: .failed(failure))
    }

    /// `token` nil settles whichever turn waits in `id`.
    private func settleReviewTurn(_ id: ACPSession.ID, token: UUID? = nil, with settlement: ACPReviewTurnSettlement) {
        guard let waiter = takeReviewTurnWaiter(id, token: token) else { return }
        waiter.timeout?.cancel()
        waiter.continuation.resume(returning: settlement)
    }

    private func takeReviewTurnWaiter(_ id: ACPSession.ID, token: UUID?) -> ACPReviewTurnWaiter? {
        guard let waiter = reviewTurnWaiters[id], token == nil || token == waiter.token else { return nil }
        reviewTurnWaiters[id] = nil
        waiter.drain?.cancel()
        return waiter
    }

    /// The turn's whole last agent message. Only rows after the latest prompt
    /// count, so a reused reviewer's earlier answer never stands in for it.
    private static func reviewFinalText(_ messages: [ACPMessage]) -> String {
        let promptIndex = messages.lastIndex { message in
            if case .user = message { true } else { false }
        }
        let start = promptIndex.map { $0 + 1 } ?? messages.startIndex
        for message in messages[start...].reversed() {
            if let text = ACPSessionTranscriptReader.agentText(message),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return ""
    }
}
