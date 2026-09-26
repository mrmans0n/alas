import Darwin
import Dispatch
import Foundation
import Metal
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

actor LocalTextInferenceEngine: LocalTextGenerating {
    typealias LoadedEvaluation = @Sendable (LocalTextGenerationRequest) async throws -> LocalTextGenerationResult

    struct Clock: Sendable {
        var now: @Sendable () -> ContinuousClock.Instant = { .now }
        var sleep: @Sendable (ContinuousClock.Instant) async throws -> Void = {
            try await ContinuousClock().sleep(until: $0)
        }
    }

    private struct LoadedModel: Sendable {
        let tokenCount: @Sendable ([LocalTextMessage]) async throws -> Int
        let evaluate: LoadedEvaluation
    }

    private struct Job {
        let id: UInt64
        let caller: LocalTextCaller
        let priority: LocalTextJobPriority
        let task: Task<Result<LocalTextGenerationResult, LocalTextInferenceFailure>, Never>
        var deadline: Task<Void, Never>?
    }

    private let acquireLease: @Sendable () async throws -> LocalTextModelLease
    private let load: @Sendable (URL) async throws -> LoadedModel
    private let supported: @Sendable () -> Bool
    private let clock: Clock
    private var lease: LocalTextModelLease?
    private var evaluation: LoadedModel?
    private var active: Job?
    private var cancellationReasons: [UInt64: LocalTextInferenceFailure] = [:]
    private var generation: UInt64 = 0
    private var idleTask: Task<Void, Never>?
    private var pressure: DispatchSourceMemoryPressure?

    init(store: LocalTextModelStore) {
        acquireLease = { try await store.acquireVerifiedLease() }
        load = Self.loadNative
        supported = Self.isSupported
        clock = Clock()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure = source
        source.setEventHandler { [weak self] in Task { await self?.cancelAndUnload() } }
        source.resume()
    }

    init(acquireLease: @escaping @Sendable () async throws -> LocalTextModelLease,
         load: @escaping @Sendable (URL) async throws -> LoadedEvaluation,
         tokenCount: @escaping @Sendable ([LocalTextMessage]) async throws -> Int = { _ in 0 },
         supported: @escaping @Sendable () -> Bool = { true },
         clock: Clock = Clock(), observeMemoryPressure: Bool = true) {
        self.acquireLease = acquireLease
        self.load = { directory in
            .init(tokenCount: tokenCount, evaluate: try await load(directory))
        }
        self.supported = supported
        self.clock = clock
        if observeMemoryPressure {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            pressure = source
            source.setEventHandler { [weak self] in Task { await self?.cancelAndUnload() } }
            source.resume()
        }
    }

    deinit {
        pressure?.cancel()
        idleTask?.cancel()
        active?.deadline?.cancel()
        active?.task.cancel()
        evaluation = nil
        lease?.close()
    }

    func generate(_ request: LocalTextGenerationRequest, caller: LocalTextCaller,
                  priority: LocalTextJobPriority) async throws -> LocalTextGenerationResult {
        try validate(request)
        guard supported() else { throw LocalTextInferenceFailure.unsupported }

        idleTask?.cancel()
        idleTask = nil
        let previous = active
        if let previous {
            guard !(priority == .automatic && previous.priority == .userInitiated) else {
                throw LocalTextInferenceFailure.preempted
            }
            cancellationReasons[previous.id] = priority.rawValue > previous.priority.rawValue ? .preempted : .cancelled
            previous.deadline?.cancel()
            previous.task.cancel()
        }

        generation &+= 1
        let id = generation
        let deadline = clock.now().advanced(by: request.timeout)
        let task: Task<Result<LocalTextGenerationResult, LocalTextInferenceFailure>, Never> = Task.detached { [weak self] in
            _ = await previous?.task.value
            guard let self else { return .failure(.cancelled) }
            return await self.run(request, id: id, deadline: deadline)
        }
        active = Job(id: id, caller: caller, priority: priority, task: task, deadline: nil)
        let timer = Task { [weak self, clock] in
            do {
                try await clock.sleep(deadline)
                try Task.checkCancellation()
                await self?.expire(id)
            } catch {}
        }
        if active?.id == id { active?.deadline = timer }

        var result = await withTaskCancellationHandler { await task.value } onCancel: {
            Task { await self.cancel(id: id, reason: .cancelled) }
        }
        if Task.isCancelled { result = .failure(.cancelled) }
        finish(id: id, result: result)
        return try result.get()
    }

    func cancel(caller: LocalTextCaller) async {
        guard let job = active, job.caller == caller else { return }
        cancel(id: job.id, reason: .cancelled)
        _ = await job.task.value
        guard active?.id == job.id else { return }
        job.deadline?.cancel()
        active = nil
        cancellationReasons[job.id] = nil
        unload()
    }

    func cancelAndUnload() async {
        idleTask?.cancel()
        idleTask = nil
        guard let job = active else {
            unload()
            return
        }
        cancel(id: job.id, reason: .cancelled)
        _ = await job.task.value
        guard active?.id == job.id else { return }
        job.deadline?.cancel()
        active = nil
        cancellationReasons[job.id] = nil
        unload()
    }

    private func run(_ request: LocalTextGenerationRequest, id: UInt64,
                     deadline: ContinuousClock.Instant) async -> Result<LocalTextGenerationResult, LocalTextInferenceFailure> {
        do {
            if let reason = cancellationReasons[id] { throw reason }
            guard clock.now() < deadline else { throw LocalTextInferenceFailure.timedOut }
            if evaluation == nil {
                lease = try await acquireLease()
                if let reason = cancellationReasons[id] { throw reason }
                try Task.checkCancellation()
                let directory = lease!.directory
                let loader = Task.detached { [load] in try await load(directory) }
                evaluation = try await withTaskCancellationHandler { try await loader.value } onCancel: {
                    loader.cancel()
                }
            }
            if let reason = cancellationReasons[id] { throw reason }
            guard clock.now() < deadline else { throw LocalTextInferenceFailure.timedOut }
            guard let evaluation else { throw LocalTextInferenceFailure.unavailable }
            let (selectedRequest, selectedCandidateIndex) = try await fittedRequest(
                request, tokenCount: evaluation.tokenCount
            )
            let worker = Task.detached { try await evaluation.evaluate(selectedRequest) }
            let result = try await withTaskCancellationHandler {
                do { return try await worker.value }
                catch {
                    worker.cancel()
                    _ = await worker.result
                    throw error
                }
            } onCancel: { worker.cancel() }
            if let reason = cancellationReasons[id] { throw reason }
            guard clock.now() < deadline else { throw LocalTextInferenceFailure.timedOut }
            try Task.checkCancellation()
            return .success(.init(text: result.text, selectedCandidateIndex: selectedCandidateIndex))
        } catch let failure as LocalTextInferenceFailure {
            return .failure(failure)
        } catch is CancellationError {
            return .failure(cancellationReasons[id] ?? .cancelled)
        } catch {
            let failure: LocalTextInferenceFailure = lease == nil ? .unavailable : .generationFailed
            unload()
            return .failure(failure)
        }
    }

    private func finish(id: UInt64, result: Result<LocalTextGenerationResult, LocalTextInferenceFailure>) {
        cancellationReasons[id] = nil
        guard active?.id == id else { return }
        active?.deadline?.cancel()
        active = nil
        switch result {
        case .success:
            scheduleIdleUnload(id)
        case .failure(.timedOut), .failure(.cancelled):
            unload()
        case .failure(.unsupported), .failure(.unavailable), .failure(.generationFailed):
            unload()
        case .failure(.inputTooLarge), .failure(.preempted):
            if evaluation != nil { scheduleIdleUnload(id) }
        }
    }

    private func validate(_ request: LocalTextGenerationRequest) throws {
        guard !request.messageCandidates.isEmpty,
              request.messageCandidates.allSatisfy({ !$0.isEmpty }),
              request.inputTokenLimit > 0, request.inputTokenLimit <= 8_192,
              request.maxTokens > 0, request.maxTokens <= 512,
              request.prefillStepSize > 0, request.timeout > .zero else {
            throw LocalTextInferenceFailure.inputTooLarge
        }
    }

    private func fittedRequest(
        _ request: LocalTextGenerationRequest,
        tokenCount: @Sendable ([LocalTextMessage]) async throws -> Int
    ) async throws -> (LocalTextGenerationRequest, Int) {
        for (index, messages) in request.messageCandidates.enumerated() {
            try Task.checkCancellation()
            if try await tokenCount(messages) <= request.inputTokenLimit {
                return (
                    .init(
                        messageCandidates: [messages],
                        inputTokenLimit: request.inputTokenLimit,
                        maxTokens: request.maxTokens,
                        temperature: request.temperature,
                        prefillStepSize: request.prefillStepSize,
                        timeout: request.timeout
                    ),
                    index
                )
            }
        }
        throw LocalTextInferenceFailure.inputTooLarge
    }

    private func cancel(id: UInt64, reason: LocalTextInferenceFailure) {
        guard let job = active, job.id == id else { return }
        if cancellationReasons[id] == nil { cancellationReasons[id] = reason }
        job.deadline?.cancel()
        job.task.cancel()
    }

    private func expire(_ id: UInt64) {
        cancel(id: id, reason: .timedOut)
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
        guard generation == id, active == nil else { return }
        unload()
    }

    private func unload() {
        idleTask?.cancel()
        idleTask = nil
        evaluation = nil
        lease?.close()
        lease = nil
    }

    nonisolated static func isSupported() -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "AlasBuildConfiguration") as? String == "Debug",
              machineIdentifier().hasPrefix("arm64") else { return false }
        return MTLCreateSystemDefaultDevice()?.supportsFamily(.apple7) == true
    }

    private nonisolated static func machineIdentifier() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "" }
        var machine = info.machine
        let capacity = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: &machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    private static func loadNative(_ directory: URL) async throws -> LoadedModel {
        try Task.checkCancellation()
        defer { MLX.Stream().synchronize() }
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: #huggingFaceTokenizerLoader()
        )
        try Task.checkCancellation()
        return .init(
            tokenCount: { messages in
                try await container.perform { context in
                    let native: [MLXLMCommon.Message] = messages.map {
                        ["role": $0.role.rawValue, "content": $0.content]
                    }
                    return try context.tokenizer.applyChatTemplate(messages: native).count
                }
            },
            evaluate: { request in
                let parameters = GenerateParameters(
                    maxTokens: request.maxTokens,
                    temperature: request.temperature,
                    prefillStepSize: request.prefillStepSize
                )
                return try await container.perform { context in
                    defer { MLX.Stream().synchronize() }
                    try Task.checkCancellation()
                    guard let messages = request.messageCandidates.first else {
                        throw LocalTextInferenceFailure.inputTooLarge
                    }
                    let native: [MLXLMCommon.Message] = messages.map {
                        ["role": $0.role.rawValue, "content": $0.content]
                    }
                    let input = try await context.processor.prepare(input: UserInput(prompt: .messages(native)))
                    try Task.checkCancellation()
                    guard input.text.tokens.size <= request.inputTokenLimit else {
                        throw LocalTextInferenceFailure.inputTooLarge
                    }
                    var remaining = input.text
                    let cache = context.model.newCache(parameters: parameters)
                    while remaining.tokens.size > parameters.prefillStepSize {
                        try Task.checkCancellation()
                        _ = context.model(
                            remaining[.newAxis, ..<parameters.prefillStepSize], cache: cache, state: nil
                        )
                        eval(cache)
                        MLX.Stream().synchronize()
                        remaining = remaining[parameters.prefillStepSize...]
                    }
                    try Task.checkCancellation()
                    let (stream, worker) = try MLXLMCommon.generateTokensTask(
                        input: LMInput(text: remaining), cache: cache, parameters: parameters, context: context
                    )
                    return try await withTaskCancellationHandler {
                        do {
                            var tokens: [Int] = []
                            var completion: GenerateCompletionInfo?
                            for await event in stream {
                                try Task.checkCancellation()
                                switch event {
                                case .token(let token):
                                    guard tokens.count < (parameters.maxTokens ?? 0) else {
                                        throw IncompleteOutput()
                                    }
                                    tokens.append(token)
                                case .info(let info):
                                    completion = info
                                }
                            }
                            await worker.value
                            try Task.checkCancellation()
                            guard let completion, case .stop = completion.stopReason else {
                                return .init(text: "", selectedCandidateIndex: 0)
                            }
                            let text = context.tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
                            guard !text.contains("<tool_call>"), !text.contains("</tool_call>") else {
                                return .init(text: "", selectedCandidateIndex: 0)
                            }
                            return .init(text: text, selectedCandidateIndex: 0)
                        } catch {
                            worker.cancel()
                            await worker.value
                            if error is IncompleteOutput {
                                return .init(text: "", selectedCandidateIndex: 0)
                            }
                            throw error
                        }
                    } onCancel: { worker.cancel() }
                }
            }
        )
    }

    private struct IncompleteOutput: Error {}
}
