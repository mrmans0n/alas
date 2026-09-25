import Foundation
import Metal
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

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
    typealias Evaluation = @Sendable (NextPromptRequest) async throws -> String?

    struct Clock: Sendable {
        var now: @Sendable () -> ContinuousClock.Instant = { .now }
        var sleep: @Sendable (ContinuousClock.Instant) async throws -> Void = {
            try await ContinuousClock().sleep(until: $0)
        }
    }

    private(set) var state: NextPromptInferenceState = .ready
    private let acquireLease: @Sendable () async throws -> NextPromptModelLease
    private let load: @Sendable (URL) async throws -> Evaluation
    private let supported: @Sendable () -> Bool
    private let clock: Clock
    private var lease: NextPromptModelLease?
    private var evaluation: Evaluation?
    private var operation: Task<String?, Never>?
    private var generation: UInt64 = 0
    private var failures = 0
    private var deadlineTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<NextPromptInferenceState>.Continuation] = [:]

    init(store: NextPromptModelStore) {
        acquireLease = { try await store.acquireVerifiedLease() }
        load = Self.loadNative
        supported = Self.isSupported
        clock = Clock()
    }

    init(acquireLease: @escaping @Sendable () async throws -> NextPromptModelLease,
         load: @escaping @Sendable (URL) async throws -> Evaluation,
         supported: @escaping @Sendable () -> Bool = { true }, clock: Clock = Clock()) {
        self.acquireLease = acquireLease
        self.load = load
        self.supported = supported
        self.clock = clock
    }

    deinit {
        idleTask?.cancel()
        deadlineTask?.cancel()
        operation?.cancel()
        evaluation = nil
        lease?.close()
        for observer in observers.values { observer.finish() }
    }

    func states() -> AsyncStream<NextPromptInferenceState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<NextPromptInferenceState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    private var restingState: NextPromptInferenceState {
        if failures >= 2 { return .retryRequired }
        return failures == 0 ? .ready : .failed
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish(_ value: NextPromptInferenceState) {
        state = value
        for observer in observers.values { observer.yield(value) }
    }

    func generate(_ request: NextPromptRequest) async throws -> String? {
        let deadline = clock.now().advanced(by: .seconds(15))
        guard failures < 2 else { return nil }
        generation &+= 1
        let id = generation
        idleTask?.cancel()
        deadlineTask?.cancel()
        let previous = operation
        previous?.cancel()
        // Install the next handle before yielding. Reentrant requests join this chain.
        let task = Task.detached { [weak self] in
            _ = await previous?.value
            return await self?.run(request, id: id, deadline: deadline)
        }
        operation = task
        deadlineTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(deadline)
                try Task.checkCancellation()
                await self?.expire(id)
            } catch {}
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: {
            task.cancel()
            Task { await self.expire(id) }
        }
        guard generation == id else { return nil }
        deadlineTask?.cancel()
        deadlineTask = nil
        operation = nil
        if evaluation != nil { scheduleIdleUnload(id) }
        if Task.isCancelled {
            await stop(retry: false)
            return nil
        }
        return result
    }

    private func run(_ request: NextPromptRequest, id: UInt64, deadline: ContinuousClock.Instant) async -> String? {
        guard generation == id, !Task.isCancelled, clock.now() < deadline else {
            unload()
            if generation == id { publish(restingState) }
            return nil
        }
        guard failures < 2 else { return nil }
        guard supported() else {
            publish(.unavailable)
            return nil
        }
        guard request.turns.reduce(0, { $0 + $1.user.utf8.count + $1.assistant.utf8.count }) <= NextPromptContext.sourceLimit,
              NextPromptPolicy.permitsInput(request.turns) else {
            publish(.ready)
            return nil
        }
        publish(.running)
        do {
            try Task.checkCancellation()
            if evaluation == nil {
                lease = try await acquireLease()
                try Task.checkCancellation()
                let directory = lease!.directory
                // Loading and tokenization must never execute on the main actor.
                let loader = Task.detached { [load] in try await load(directory) }
                evaluation = try await withTaskCancellationHandler { try await loader.value } onCancel: { loader.cancel() }
                try Task.checkCancellation()
            }
            let text = try await evaluate(request)
            try Task.checkCancellation()
            guard generation == id, clock.now() < deadline else {
                unload()
                if generation == id { publish(restingState) }
                return nil
            }
            failures = 0
            publish(.ready)
            guard let text, let candidate = NextPromptPolicy.parse(Data(text.utf8)),
                  NextPromptPolicy.permitsOutput(candidate, turns: request.turns) else { return nil }
            return candidate
        } catch {
            unload()
            if !(error is CancellationError) && !Task.isCancelled {
                failures += 1
            }
            if generation == id { publish(restingState) }
            return nil
        }
    }

    private func evaluate(_ request: NextPromptRequest) async throws -> String? {
        guard let evaluation else { return nil }
        let worker = Task.detached { try await evaluation(request) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func expire(_ id: UInt64) async {
        guard generation == id, operation != nil else { return }
        await stop(retry: false)
    }

    func cancelAndUnload() async {
        await stop(retry: false)
    }

    func retryAfterFailure() async {
        await stop(retry: true)
    }

    private func stop(retry: Bool) async {
        generation &+= 1
        let id = generation
        idleTask?.cancel()
        idleTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        let previous = operation
        previous?.cancel()
        publish(.unloading)
        let task = Task.detached { [weak self] in
            _ = await previous?.value
            await self?.finishStop(retry: retry, id: id)
            return nil as String?
        }
        operation = task
        _ = await task.value
        if generation == id { operation = nil }
    }

    private func finishStop(retry: Bool, id: UInt64) async {
        unload()
        guard generation == id else { return }
        if retry {
            failures = 0
            guard supported() else {
                publish(.unavailable)
                return
            }
            do {
                let verified = try await acquireLease()
                verified.close()
            } catch {
                if generation == id { failures = 1 }
            }
        }
        if generation == id { publish(restingState) }
    }

    private func scheduleIdleUnload(_ id: UInt64) {
        let deadline = clock.now().advanced(by: .seconds(60))
        idleTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(deadline)
                try Task.checkCancellation()
                await self?.idleUnload(id)
            } catch {}
        }
    }

    private func idleUnload(_ id: UInt64) {
        guard generation == id, operation == nil else { return }
        generation &+= 1
        unload()
        idleTask = nil
    }

    private func unload() {
        // The evaluation closure owns the container. Drop it before unlocking assets.
        evaluation = nil
        lease?.close()
        lease = nil
        // MLX's global allocator cache can belong to other subsystems. Leave it alone.
    }

    nonisolated static func isSupported() -> Bool {
        #if arch(arm64)
        return MTLCreateSystemDefaultDevice()?.supportsFamily(.apple7) == true
        #else
        return false
        #endif
    }

    private static func loadNative(_ directory: URL) async throws -> Evaluation {
        try Task.checkCancellation()
        defer { MLX.Stream().synchronize() }
        let container = try await LLMModelFactory.shared.loadContainer(from: directory, using: #huggingFaceTokenizerLoader())
        try Task.checkCancellation()
        return { request in
            try await container.perform { context in
                defer { MLX.Stream().synchronize() }
                try Task.checkCancellation()
                let fitted = NextPromptContext.fit(request.turns) { messages in
                    guard !Task.isCancelled else { return Int.max }
                    let native: [MLXLMCommon.Message] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
                    return (try? context.tokenizer.applyChatTemplate(messages: native).count) ?? Int.max
                }
                try Task.checkCancellation()
                guard let fitted else { return nil }
                let messages: [MLXLMCommon.Message] = NextPromptPolicy.messages(for: fitted).map {
                    ["role": $0.role.rawValue, "content": $0.content]
                }
                let input = try await context.processor.prepare(input: UserInput(prompt: .messages(messages)))
                try Task.checkCancellation()
                guard input.text.tokens.size <= 8_192 else { return nil }
                let parameters = GenerateParameters(maxTokens: 128, temperature: 0, prefillStepSize: 512)
                var remaining = input.text
                let cache = context.model.newCache(parameters: parameters)
                while remaining.tokens.size > 512 {
                    try Task.checkCancellation()
                    _ = context.model(remaining[.newAxis, ..<512], cache: cache, state: nil)
                    eval(cache)
                    MLX.Stream().synchronize()
                    try Task.checkCancellation()
                    remaining = remaining[512...]
                }
                try Task.checkCancellation()
                let (stream, worker) = try MLXLMCommon.generateTokensTask(
                    input: LMInput(text: remaining), cache: cache, parameters: parameters, context: context)
                return try await withTaskCancellationHandler {
                    do {
                        var tokens: [Int] = []
                        var completion: GenerateCompletionInfo?
                        for await event in stream {
                            try Task.checkCancellation()
                            switch event {
                            case .token(let token):
                                guard tokens.count < 128 else { throw IncompleteOutput() }
                                tokens.append(token)
                            case .info(let info): completion = info
                            }
                        }
                        // .info is emitted before the pinned worker synchronizes Metal.
                        await worker.value
                        try Task.checkCancellation()
                        guard let completion, case .stop = completion.stopReason else { return nil }
                        let text = context.tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
                        guard !text.contains("<tool_call>"), !text.contains("</tool_call>") else { return nil }
                        return text
                    } catch {
                        worker.cancel()
                        await worker.value
                        if error is IncompleteOutput { return nil }
                        throw error
                    }
                } onCancel: { worker.cancel() }
            }
        }
    }

    private struct IncompleteOutput: Error {}
}
