import Foundation
import AlasModel
import AlasACP
import AlasSessions

/// Hands each scheduled chat session's first finished turn to the firing
/// waiting on it. A session is expected before its launch starts, so a turn
/// that ends before anyone waits is kept until someone does; every other
/// session's turns are ignored.
@MainActor
public final class ScheduledAgentTurns {
    private enum Slot {
        case expected
        case finished(ACPTurnCompletion)
        case waiting(CheckedContinuation<ACPTurnCompletion?, Never>)
    }

    private var slots: [ACPSession.ID: Slot] = [:]

    /// How long a firing waits for its chat agent's turn before it stops
    /// waiting, so an agent stuck on a question cannot hold the schedule
    /// forever. The agent itself is left running.
    public static let turnTimeout: Duration = .seconds(4 * 60 * 60)

    /// Only a prompt the schedule sends itself starts a turn worth awaiting.
    public nonisolated static func awaits(_ prompt: String?, sendsAutomatically: Bool) -> Bool {
        sendsAutomatically && !(prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init() {}

    public func expect(_ sessionID: ACPSession.ID) {
        slots[sessionID] = .expected
    }

    public func deliver(_ completion: ACPTurnCompletion) {
        switch slots[completion.sessionId] {
        case .expected:
            slots[completion.sessionId] = .finished(completion)
        case .waiting(let continuation):
            slots[completion.sessionId] = nil
            continuation.resume(returning: completion)
        case .finished, nil:
            break
        }
    }

    /// The session's first finished turn, or nil when the session was never
    /// expected, the timeout passed, or the waiting task was cancelled.
    public func wait(for sessionID: ACPSession.ID, timeout: Duration) async -> ACPTurnCompletion? {
        switch slots[sessionID] {
        case .finished(let completion):
            slots[sessionID] = nil
            return completion
        case .expected:
            break
        case .waiting, nil:
            return nil
        }
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.abandon(sessionID)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { slots[sessionID] = .waiting($0) }
        } onCancel: {
            Task { @MainActor [weak self] in self?.abandon(sessionID) }
        }
    }

    /// A stopped runner reports no turn, so closing a session mid-turn has to
    /// end the wait here, as a stop.
    public func sessionClosed(_ sessionID: ACPSession.ID) {
        deliver(ACPTurnCompletion(
            sessionId: sessionID, startedAt: 0, result: .cancelled, delegatedSource: nil, lastAgentText: nil
        ))
    }

    /// Forgets the session, releasing its waiter with nil.
    public func abandon(_ sessionID: ACPSession.ID) {
        if case .waiting(let continuation) = slots.removeValue(forKey: sessionID) {
            continuation.resume(returning: nil)
        }
    }

    /// The agent's final reply to the scheduled prompt.
    ///
    /// Not `ACPTurnCompletion.lastAgentText`: that is read as the prompt
    /// returns, while the reply's last chunk can still sit in the runner's
    /// coalescing buffer. The runner marks the transcript idle only once that
    /// output is applied, so the reply is read after that — or after a short
    /// bound, rather than holding the firing on a session that never settles.
    /// A prompt the user queued behind it starts only after that output is
    /// applied, so its arrival ends the wait too: the session will not go
    /// idle while it runs.
    public static func reply(in session: ACPSession) async -> String? {
        // The buffer flushes within ~16 ms, so a short poll settles quickly.
        let deadline = ContinuousClock.now + .seconds(5)
        while session.transcript.streamingState != .idle,
              !Self.scheduledTurn(in: session.transcript.messages).successorStarted,
              ContinuousClock.now < deadline {
            guard (try? await Task.sleep(for: .milliseconds(20))) != nil else { break }
        }
        return Self.finalAgentReply(in: Self.scheduledTurn(in: session.transcript.messages).messages)
    }

    /// The messages answering a scheduled session's first prompt, which is
    /// the one the schedule sent, and whether a later prompt has started.
    public static func scheduledTurn(
        in messages: [ACPMessage]
    ) -> (messages: ArraySlice<ACPMessage>, successorStarted: Bool) {
        let isUser: (ACPMessage) -> Bool = { if case .user = $0 { true } else { false } }
        guard let prompt = messages.firstIndex(where: isUser) else { return ([], false) }
        let start = prompt + 1
        let successor = messages[start...].firstIndex(where: isUser)
        return (messages[start..<(successor ?? messages.endIndex)], successor != nil)
    }

    /// The last nonblank agent message, trimmed to the report's bound.
    public static func finalAgentReply(in messages: ArraySlice<ACPMessage>) -> String? {
        messages.reversed().lazy.compactMap { message -> String? in
            guard case .agent(_, _, let text) = message else { return nil }
            let tail = ACPDelegatedOutcomeText.tail(text.value, limit: ACPTurnCompletion.lastAgentTextLimit)
            return tail.isEmpty ? nil : tail
        }.first
    }
}
