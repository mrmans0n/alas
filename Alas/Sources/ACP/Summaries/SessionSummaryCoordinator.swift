import Combine
import Foundation

@MainActor
final class SessionSummaryCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case result(SessionSummary)
        case failed(String, previous: SessionSummary?)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var presentationGeneration: UInt64 = 0

    private let engine: any LocalTextGenerating
    private var cache: [UUID: SessionSummary] = [:]
    private var generationTask: Task<Void, Never>?
    private var cancellationBarrier: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0
    private var currentIncarnation: UUID?
    private weak var boundSession: ACPSession?
    private var observations: Set<AnyCancellable> = []

    init(engine: any LocalTextGenerating) {
        self.engine = engine
    }

    func bind(to session: ACPSession) {
        guard boundSession !== session else { return }

        observations.removeAll()
        if boundSession != nil {
            requestGeneration &+= 1
            cancelCurrentGeneration()
            phase = .idle
        }
        boundSession = session

        session.nextPromptActivity
            .sink { [weak self, weak session] in
                guard let self, let session, self.boundSession === session else { return }
                self.invalidateForActivity(session)
            }
            .store(in: &observations)
        session.nextPromptTeardown
            .sink { [weak self, weak session] in
                guard let self, let session, self.boundSession === session else { return }
                self.endSession(session)
            }
            .store(in: &observations)
    }

    func summary(for session: ACPSession) async {
        await generate(for: session, bypassingCache: false)
    }

    func refresh(_ session: ACPSession) async {
        await generate(for: session, bypassingCache: true)
    }

    func cancelPresentation() {
        guard generationTask != nil else { return }
        requestGeneration &+= 1
        cancelCurrentGeneration()
        phase = .idle
    }

    func invalidate(_ session: ACPSession) {
        cache[session.incarnation] = nil
        guard boundSession === session else { return }
        requestGeneration &+= 1
        cancelCurrentGeneration()
        phase = .idle
        presentationGeneration &+= 1
    }

    func teardown() {
        requestGeneration &+= 1
        cancelCurrentGeneration()
        observations.removeAll()
        boundSession = nil
        cache.removeAll()
        phase = .idle
        presentationGeneration &+= 1
    }

    private func generate(for session: ACPSession, bypassingCache: Bool) async {
        if boundSession !== session { bind(to: session) }
        if !bypassingCache, let cached = cache[session.incarnation] {
            phase = .result(cached)
            return
        }

        requestGeneration &+= 1
        cancelCurrentGeneration()
        let generation = requestGeneration
        let previous = cache[session.incarnation]
        guard let context = SessionSummaryContext.snapshot(session: session),
              context.revision.idleFacts.isIdle else {
            phase = .failed("There is not enough idle session context to summarize.", previous: previous)
            return
        }

        let incarnation = session.incarnation
        let request = LocalTextGenerationRequest(
            messageCandidates: context.messageCandidates(),
            inputTokenLimit: SessionSummaryContext.tokenLimit,
            maxTokens: 512,
            temperature: 0,
            prefillStepSize: 512,
            timeout: .seconds(30)
        )
        let barrier = cancellationBarrier
        let engine = engine
        phase = .loading
        currentIncarnation = incarnation

        let task = Task { @MainActor [weak self, weak session] in
            if let barrier { await barrier.value }
            guard let self, let session,
                  !Task.isCancelled,
                  self.requestGeneration == generation,
                  self.currentIncarnation == incarnation else { return }
            do {
                let raw = try await engine.generate(
                    request,
                    caller: .sessionSummary(incarnation),
                    priority: .userInitiated
                )
                self.publish(
                    raw,
                    context: context,
                    previous: previous,
                    session: session,
                    generation: generation
                )
            } catch {
                self.publishFailure(
                    error,
                    context: context,
                    previous: previous,
                    session: session,
                    generation: generation
                )
            }
        }
        generationTask = task
        await task.value
    }

    private func publish(
        _ raw: LocalTextGenerationResult,
        context: SessionSummaryContext,
        previous: SessionSummary?,
        session: ACPSession,
        generation: UInt64
    ) {
        guard requestIsCurrent(generation, session: session),
              SessionSummaryContext.snapshot(session: session)?.revision == context.revision else {
            finishStaleRequest(generation)
            return
        }
        guard let summary = SessionSummaryPolicy.parse(
            Data(raw.text.utf8),
            isPartial: context.omittedOlderTurns || raw.selectedCandidateIndex > 0
        ) else {
            phase = .failed("Alas could not produce a usable session summary.", previous: previous)
            finishRequest(generation)
            return
        }

        cache[session.incarnation] = summary
        phase = .result(summary)
        finishRequest(generation)
    }

    private func publishFailure(
        _ error: Error,
        context: SessionSummaryContext,
        previous: SessionSummary?,
        session: ACPSession,
        generation: UInt64
    ) {
        guard requestIsCurrent(generation, session: session),
              SessionSummaryContext.snapshot(session: session)?.revision == context.revision else {
            finishStaleRequest(generation)
            return
        }
        phase = .failed(Self.message(for: error), previous: previous)
        finishRequest(generation)
    }

    private func requestIsCurrent(_ generation: UInt64, session: ACPSession) -> Bool {
        !Task.isCancelled
            && requestGeneration == generation
            && currentIncarnation == session.incarnation
            && boundSession === session
    }

    private func finishStaleRequest(_ generation: UInt64) {
        guard requestGeneration == generation else { return }
        phase = .idle
        finishRequest(generation)
    }

    private func finishRequest(_ generation: UInt64) {
        guard requestGeneration == generation else { return }
        generationTask = nil
        currentIncarnation = nil
    }

    private func invalidateForActivity(_ session: ACPSession) {
        requestGeneration &+= 1
        cancelCurrentGeneration()
        cache[session.incarnation] = nil
        phase = .idle
        presentationGeneration &+= 1
    }

    private func endSession(_ session: ACPSession) {
        invalidateForActivity(session)
        observations.removeAll()
        boundSession = nil
    }

    private func cancelCurrentGeneration() {
        guard let incarnation = currentIncarnation else {
            generationTask = nil
            return
        }
        generationTask?.cancel()
        generationTask = nil
        currentIncarnation = nil
        let previous = cancellationBarrier
        let engine = engine
        cancellationBarrier = Task {
            if let previous { await previous.value }
            await engine.cancel(caller: .sessionSummary(incarnation))
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? LocalTextInferenceFailure {
        case .unsupported:
            "Session summaries are not supported on this Mac."
        case .unavailable:
            "The on-device model is unavailable."
        case .inputTooLarge:
            "This session is too large to summarize."
        case .timedOut:
            "The summary took too long. Try again."
        case .cancelled, .preempted:
            "The summary was interrupted. Try again."
        case .generationFailed, .none:
            "Alas could not generate a session summary."
        }
    }
}
