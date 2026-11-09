import Foundation
import AlasModel
import AlasACP

/// One session's request to its agent for the predicted follow-up prompt of
/// its latest prompt, and the wait for the answer. The runner records the
/// request when the prompt is sent and the matching answer when it arrives;
/// the agent engine waits for it once the turn completed. Answers and prompt
/// responses arrive on separate streams, so either can come first. Runtime
/// only: a new connection starts empty.
@MainActor
public final class NextPromptAgentPrediction {
    private var pending: (promptID: Int, requestID: String)?
    private var answered: (promptID: Int, text: String?)?
    private var waiters: [UUID: (promptID: Int, continuation: CheckedContinuation<String?, Never>)] = [:]

    public init() {}

    /// Prompt `promptID` asked for its turn's prediction under `requestID`.
    /// An earlier prompt's prediction is spent.
    public func expect(promptID: Int, requestID: String) {
        pending = (promptID, requestID)
        answered = nil
        finishWaiters { $0 != promptID }
    }

    /// A prompt that asked for nothing, a new connection, or the session's
    /// end: nothing predicted so far is current.
    public func reset() {
        pending = nil
        answered = nil
        finishWaiters { _ in true }
    }

    /// Records the agent's answer. Returns false for an answer to a request
    /// this session no longer waits for: an earlier prompt's, or a redelivery.
    @discardableResult
    public func receive(_ answer: ACPPredictedPrompt.Answer) -> Bool {
        guard let pending, pending.requestID == answer.id else { return false }
        self.pending = nil
        answered = (pending.promptID, answer.text)
        for (key, waiter) in waiters where waiter.promptID == pending.promptID {
            waiters[key] = nil
            waiter.continuation.resume(returning: answer.text)
        }
        return true
    }

    /// The prediction of prompt `promptID`'s turn, waiting for it while it is
    /// still due. Nil when the agent predicted nothing, when the prompt asked
    /// for nothing, once a newer prompt asked, or when the task is cancelled.
    public func answer(for promptID: Int) async -> String? {
        if let answered, answered.promptID == promptID { return answered.text }
        guard let pending, pending.promptID == promptID, !Task.isCancelled else { return nil }
        let key = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[key] = (promptID, continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: key)?.continuation.resume(returning: nil)
            }
        }
    }

    private func finishWaiters(where shouldFinish: (Int) -> Bool) {
        for (key, waiter) in waiters where shouldFinish(waiter.promptID) {
            waiters[key] = nil
            waiter.continuation.resume(returning: nil)
        }
    }
}

/// The agent as a next-prompt source: it generates nothing itself, it waits
/// for the prediction the session's adapter sends for the turn.
public struct NextPromptAgentEngine: NextPromptGenerating {
    private let prediction: @MainActor @Sendable (NextPromptRequestID) -> NextPromptAgentPrediction?

    public init(prediction: @escaping @MainActor @Sendable (NextPromptRequestID) -> NextPromptAgentPrediction?) {
        self.prediction = prediction
    }

    public func generate(_ request: NextPromptRequest) async throws -> String? {
        guard let prediction = await prediction(request.id),
              let text = await prediction.answer(for: request.id.promptID) else { return nil }
        return NextPromptPolicy.acceptAgentPrediction(text, turns: request.turns)
    }

    /// Cancelling the generation task ends the wait.
    public func cancel() async {}
    public func cancelAndUnload() async {}
    public func retryAfterFailure() async {}
}

/// Hands each request to the engine of its source, and the cancellation of
/// the work in flight back to the engine that did it, so a turn served by
/// the agent never touches the local model's state.
public actor NextPromptSourceRouter: NextPromptGenerating {
    private let onDevice: any NextPromptGenerating
    private let agent: any NextPromptGenerating
    private var lastSource: NextPromptSource?

    public init(onDevice: any NextPromptGenerating, agent: any NextPromptGenerating) {
        self.onDevice = onDevice
        self.agent = agent
    }

    public func generate(_ request: NextPromptRequest) async throws -> String? {
        lastSource = request.id.source
        return try await engine(request.id.source).generate(request)
    }

    public func cancel() async {
        guard let source = lastSource else { return }
        lastSource = nil
        await engine(source).cancel()
    }

    public func cancelAndUnload() async {
        lastSource = nil
        await onDevice.cancelAndUnload()
    }

    public func retryAfterFailure() async {
        await onDevice.retryAfterFailure()
    }

    private func engine(_ source: NextPromptSource) -> any NextPromptGenerating {
        source == .agent ? agent : onDevice
    }
}
