import Foundation

protocol NextPromptGenerating: Sendable {
    func generate(_ request: NextPromptRequest) async throws -> String?
    func cancelAndUnload() async
    func retryAfterFailure() async
}

protocol NextPromptRuntime: NextPromptGenerating {
    var state: NextPromptInferenceState { get async }
    func states() async -> AsyncStream<NextPromptInferenceState>
}

enum NextPromptInferenceState: Equatable, Sendable {
    case ready, running, unloading, unavailable, failed, retryRequired
}

actor NextPromptInference: NextPromptRuntime {
    typealias Evaluation = @Sendable (LocalTextGenerationRequest) async throws -> String?
    typealias Clock = LocalTextInferenceEngine.Clock

    private(set) var state: NextPromptInferenceState = .ready
    private let engine: any LocalTextGenerating
    private let supported: @Sendable () -> Bool
    private var failures = 0
    private var observers: [UUID: AsyncStream<NextPromptInferenceState>.Continuation] = [:]

    nonisolated static func isSupported() -> Bool { LocalTextInferenceEngine.isSupported() }

    init(store: LocalTextModelStore) {
        engine = LocalTextInferenceEngine(store: store)
        supported = LocalTextInferenceEngine.isSupported
    }

    init(engine: any LocalTextGenerating, supported: @escaping @Sendable () -> Bool = { true }) {
        self.engine = engine
        self.supported = supported
    }

    init(acquireLease: @escaping @Sendable () async throws -> LocalTextModelLease,
         load: @escaping @Sendable (URL) async throws -> Evaluation,
         supported: @escaping @Sendable () -> Bool = { true }, clock: Clock = Clock()) {
        engine = LocalTextInferenceEngine(
            acquireLease: acquireLease,
            load: { directory in
                let evaluation = try await load(directory)
                return { request in
                    .init(text: try await evaluation(request) ?? "", selectedCandidateIndex: 0)
                }
            },
            supported: supported,
            clock: clock,
            observeMemoryPressure: false
        )
        self.supported = supported
    }

    deinit {
        for observer in observers.values { observer.finish() }
    }

    func states() -> AsyncStream<NextPromptInferenceState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<NextPromptInferenceState>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        observers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    func generate(_ request: NextPromptRequest) async throws -> String? {
        guard failures < 2 else { return nil }
        guard supported() else {
            publish(.unavailable)
            return nil
        }
        guard request.turns.reduce(0, { $0 + $1.user.utf8.count + $1.assistant.utf8.count })
                <= NextPromptContext.sourceLimit,
              NextPromptPolicy.permitsInput(request.turns) else {
            publish(.ready)
            return nil
        }

        publish(.running)
        do {
            let result = try await engine.generate(
                generationRequest(for: request), caller: .nextPrompt, priority: .automatic
            )
            failures = 0
            publish(.ready)
            guard let candidate = NextPromptPolicy.parse(Data(result.text.utf8)),
                  NextPromptPolicy.permitsOutput(candidate, turns: request.turns) else { return nil }
            return candidate
        } catch let failure as LocalTextInferenceFailure {
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
        } catch {
            failures += 1
            publish(restingState)
            return nil
        }
    }

    func cancelAndUnload() async {
        publish(.unloading)
        await engine.cancelAndUnload()
        publish(restingState)
    }

    func retryAfterFailure() async {
        publish(.unloading)
        await engine.cancelAndUnload()
        failures = 0
        publish(supported() ? .ready : .unavailable)
    }

    private var restingState: NextPromptInferenceState {
        if failures >= 2 { return .retryRequired }
        return failures == 0 ? .ready : .failed
    }

    private func generationRequest(for request: NextPromptRequest) -> LocalTextGenerationRequest {
        let candidates = request.turns.indices.map { first in
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

    private func publish(_ value: NextPromptInferenceState) {
        state = value
        for observer in observers.values { observer.yield(value) }
    }
}
