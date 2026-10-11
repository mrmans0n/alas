import Foundation
import os

public protocol NextPromptGenerating: Sendable {
    func generate(_ request: NextPromptRequest) async throws -> String?
    func cancel() async
    func cancelAndUnload() async
    func retryAfterFailure() async
}

extension NextPromptGenerating {
    public func cancel() async { await cancelAndUnload() }
}

public protocol NextPromptRuntime: NextPromptGenerating {
    var state: NextPromptInferenceState { get async }
    func states() async -> AsyncStream<NextPromptInferenceState>
}

public enum NextPromptInferenceState: Equatable, Sendable {
    case ready, running, unloading, unavailable, failed, retryRequired
}

public actor NextPromptInference: NextPromptRuntime {
    public typealias Evaluation = @Sendable (LocalTextGenerationRequest) async throws -> String?
    public typealias Clock = LocalTextClock
    public typealias CancellationScheduler = @Sendable (@escaping @Sendable () async -> Void) -> Void

    public private(set) var state: NextPromptInferenceState = .ready
    private let engine: any LocalTextGenerating
    private let supported: @Sendable () -> Bool
    private let verifyAvailability: @Sendable () async throws -> Void
    private let clock: Clock
    private let scheduleCancellation: CancellationScheduler
    private var generation: UInt64 = 0
    private var activeRequestID: UInt64?
    private var failures = 0
    private var observers: [UUID: AsyncStream<NextPromptInferenceState>.Continuation] = [:]

    public init(engine: any LocalTextGenerating,
         supported: @escaping @Sendable () -> Bool = { true },
         verifyAvailability: @escaping @Sendable () async throws -> Void,
         clock: Clock = Clock(),
         scheduleCancellation: @escaping CancellationScheduler = { action in _ = Task { await action() } }) {
        self.engine = engine
        self.supported = supported
        self.verifyAvailability = verifyAvailability
        self.clock = clock
        self.scheduleCancellation = scheduleCancellation
    }

    deinit {
        for observer in observers.values { observer.finish() }
    }

    public func states() -> AsyncStream<NextPromptInferenceState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<NextPromptInferenceState>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        observers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    public func generate(_ request: NextPromptRequest) async throws -> String? {
        generation &+= 1
        let id = generation
        activeRequestID = nil
        guard failures < 2 else {
            nextPromptLogger.notice("inference skipped: retry required after repeated failures")
            await abstain(id: id, state: restingState)
            return nil
        }
        guard supported() else {
            nextPromptLogger.notice("inference skipped: unsupported on this device")
            await abstain(id: id, state: .unavailable)
            return nil
        }
        guard request.turns.reduce(0, { $0 + $1.user.utf8.count + $1.assistant.utf8.count })
                <= NextPromptContext.sourceLimit,
              NextPromptPolicy.permitsInput(request.turns) else {
            nextPromptLogger.notice("inference skipped: context too large or blocked by input policy")
            await abstain(id: id, state: restingState)
            return nil
        }

        activeRequestID = id
        let deadline = clock.now().advanced(by: .seconds(15))
        publish(.running)
        let deadlineTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(deadline)
                try Task.checkCancellation()
                await self?.beginUnloading(id)
            } catch {}
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await engine.generate(
                    generationRequest(for: request), caller: .nextPrompt, priority: .automatic
                )
            } onCancel: {
                scheduleCancellation { await self.beginUnloading(id) }
            }
            deadlineTask.cancel()
            guard generation == id, activeRequestID == id else { return nil }
            try Task.checkCancellation()
            activeRequestID = nil
            failures = 0
            publish(.ready)
            guard let candidate = NextPromptPolicy.parse(Data(result.text.utf8)) else {
                nextPromptLogger.notice("inference returned no suggestion (\(result.text.utf8.count) bytes)")
                return nil
            }
            guard NextPromptPolicy.permitsOutput(candidate, turns: request.turns) else {
                nextPromptLogger.notice("inference suggestion blocked by output policy")
                return nil
            }
            return candidate
        } catch let failure as LocalTextInferenceFailure {
            deadlineTask.cancel()
            nextPromptLogger.notice("inference failed: \(String(describing: failure), privacy: .public)")
            guard finishRequest(id) else { return nil }
            switch failure {
            case .unsupported:
                publish(.unavailable)
            case .unavailable, .generationFailed:
                failures += 1
                publish(restingState)
            case .inputTooLarge, .timedOut, .cancelled, .preempted:
                publish(restingState)
            }
            return nil
        } catch is CancellationError {
            deadlineTask.cancel()
            guard finishRequest(id) else { return nil }
            publish(restingState)
            return nil
        } catch {
            deadlineTask.cancel()
            nextPromptLogger.notice("inference failed: \(String(describing: type(of: error)), privacy: .public)")
            guard finishRequest(id) else { return nil }
            failures += 1
            publish(restingState)
            return nil
        }
    }

    public func cancelAndUnload() async {
        generation &+= 1
        let id = generation
        activeRequestID = nil
        publish(.unloading)
        await engine.cancelAndUnload()
        guard generation == id else { return }
        publish(restingState)
    }

    public func cancel() async {
        generation &+= 1
        let id = generation
        activeRequestID = nil
        publish(.unloading)
        await engine.cancel(caller: .nextPrompt)
        guard generation == id else { return }
        publish(restingState)
    }

    public func retryAfterFailure() async {
        generation &+= 1
        let id = generation
        activeRequestID = nil
        publish(.unloading)
        await engine.cancel(caller: .nextPrompt)
        guard generation == id else { return }
        guard supported() else {
            publish(.unavailable)
            return
        }
        do {
            try await verifyAvailability()
            guard generation == id else { return }
            failures = 0
        } catch {
            guard generation == id else { return }
            failures = 1
        }
        publish(restingState)
    }

    private var restingState: NextPromptInferenceState {
        if failures >= 2 { return .retryRequired }
        return failures == 0 ? .ready : .failed
    }

    private func generationRequest(for request: NextPromptRequest) -> LocalTextGenerationRequest {
        let candidateCount = min(10, request.turns.count)
        let lastTurn = request.turns.count - 1
        let intervalCount = max(1, candidateCount - 1)
        // ponytail: 10 evenly spaced suffixes cap serialization; binary search fitting if context gaps matter.
        let starts = (0..<candidateCount).map { $0 * lastTurn / intervalCount }
        let candidates = starts.map { first in
            NextPromptPolicy.messages(for: Array(request.turns[first...]))
        }
        return .init(
            messageCandidates: candidates,
            inputTokenLimit: NextPromptContext.tokenLimit,
            maxTokens: 128,
            temperature: 0,
            prefillStepSize: 512,
            timeout: .seconds(15)
        )
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func beginUnloading(_ id: UInt64) {
        guard generation == id, activeRequestID == id else { return }
        publish(.unloading)
    }

    private func finishRequest(_ id: UInt64) -> Bool {
        guard generation == id, activeRequestID == id else { return false }
        activeRequestID = nil
        return true
    }

    private func abstain(id: UInt64, state: NextPromptInferenceState) async {
        publish(.unloading)
        await engine.cancel(caller: .nextPrompt)
        guard generation == id else { return }
        publish(state)
    }

    private func publish(_ value: NextPromptInferenceState) {
        state = value
        for observer in observers.values { observer.yield(value) }
    }
}
