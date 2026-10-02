import Foundation
import FoundationModels

/// Uses Apple Intelligence first, then the shared local text engine. Both
/// backends receive the same bounded request and pass through the same parser,
/// so invalid Apple output falls through to MLX instead of reaching the caller.
struct LocalTextAppleFirstRouter {
    typealias AppleGenerator = @MainActor @Sendable (LocalTextGenerationRequest) async -> String?

    let engine: any LocalTextGenerating
    let isAppleIntelligenceAvailable: @MainActor @Sendable () -> Bool
    let generateWithAppleIntelligence: AppleGenerator
    let isMLXAvailable: @MainActor @Sendable () -> Bool

    @MainActor
    func generate<Output>(
        _ request: LocalTextGenerationRequest,
        caller: LocalTextCaller,
        priority: LocalTextJobPriority,
        parse: (String) -> Output?
    ) async -> Output? {
        if isAppleIntelligenceAvailable() {
            let output = await generateAppleIntelligenceWithTimeout(request)
            guard !Task.isCancelled else { return nil }
            if isAppleIntelligenceAvailable(), let output, let parsed = parse(output) {
                return parsed
            }
        }

        guard !Task.isCancelled, isMLXAvailable() else { return nil }
        guard let result = try? await engine.generate(request, caller: caller, priority: priority),
              !Task.isCancelled, isMLXAvailable() else { return nil }
        return parse(result.text)
    }

    @MainActor
    private func generateAppleIntelligenceWithTimeout(_ request: LocalTextGenerationRequest) async -> String? {
        let race = AppleGenerationRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.start(
                    request: request,
                    generator: generateWithAppleIntelligence,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor in race.finish(nil) }
        }
    }
}

@MainActor
private final class AppleGenerationRace {
    private var continuation: CheckedContinuation<String?, Never>?
    private var generationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    func start(
        request: LocalTextGenerationRequest,
        generator: @escaping LocalTextAppleFirstRouter.AppleGenerator,
        continuation: CheckedContinuation<String?, Never>
    ) {
        guard !finished else {
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        generationTask = Task { [weak self] in
            let output = await generator(request)
            self?.finish(output)
        }
        timeoutTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(for: request.timeout)
                self?.finish(nil)
            } catch {}
        }
    }

    func finish(_ output: String?) {
        guard !finished else { return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        generationTask?.cancel()
        timeoutTask?.cancel()
        generationTask = nil
        timeoutTask = nil
        continuation?.resume(returning: output)
    }
}

enum LocalTextAppleIntelligence {
    @MainActor
    static var isAvailable: Bool {
        LocalTextAppleAvailability.current().isAvailable
    }

    @MainActor
    static func generate(_ request: LocalTextGenerationRequest) async -> String? {
        guard #available(macOS 26.0, *) else { return nil }
        let model = SystemLanguageModel.default
        guard model.isAvailable, model.supportsLocale(Locale.current) else { return nil }

        // Foundation Models doesn't expose token counting on this SDK. UTF-8
        // bytes are a conservative upper bound, so choose the most detailed
        // shared candidate that stays within the same input budget.
        guard let messages = request.messageCandidates.first(where: { messages in
            messages.reduce(0) { $0 + $1.content.utf8.count } <= request.inputTokenLimit
        }),
              let instructions = messages.first(where: { $0.role == .system })?.content,
              let prompt = messages.first(where: { $0.role == .user })?.content
        else { return nil }

        let session = LanguageModelSession(model: model, tools: [], instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(
                    temperature: Double(request.temperature),
                    maximumResponseTokens: request.maxTokens
                )
            )
            guard !Task.isCancelled else { return nil }
            return response.content
        } catch {
            return nil
        }
    }
}
