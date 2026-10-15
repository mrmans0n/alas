import Foundation
import os

private let sessionSummaryLogger = Logger(subsystem: "io.nlopez.alas", category: "session-summary")

/// Who asked for a summary: the popover (`manual`) or the automatic recap card,
/// which fails silently.
public enum SessionSummaryRequestMode: Sendable {
    case manual
    case recap
}

@MainActor
public final class SessionSummaryCoordinator: ChangeTracking {
    nonisolated(unsafe) public let willChange = ChangeSignal<Void>()
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case result(SessionSummary)
        case failed(String, previous: SessionSummary?)
    }

    @Tracked public private(set) var phase: Phase = .idle
    @Tracked public private(set) var presentationGeneration: UInt64 = 0
    /// The mode of the request the card presents; nil means no card.
    @Tracked public private(set) var cardMode: SessionSummaryRequestMode?
    /// Incarnation of the bound session. Views gate the card on it so two
    /// mounted tabs never both render this coordinator's card.
    @Tracked public private(set) var boundSessionIncarnation: UUID?
    /// Per-session store lookup; manager-owned persistence differs per worktree.
    public var storeProvider: (@MainActor (ACPSession) -> (any SessionSummaryStoring)?)?

    private struct CacheEntry {
        let summary: SessionSummary
        let inputHash: String
    }

    private let engine: any LocalTextGenerating
    private let modelID: String
    private var cache: [UUID: CacheEntry] = [:]
    private var cacheTeardownObservations: [UUID: ChangeSubscription] = [:]
    private var generationTask: Task<Void, Never>?
    private var cancellationBarrier: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0
    private var currentIncarnation: UUID?
    private weak var boundSession: ACPSession?
    private var observations: Set<ChangeSubscription> = []

    public init(engine: any LocalTextGenerating, modelID: String) {
        self.engine = engine
        self.modelID = modelID
    }

    deinit {
        generationTask?.cancel()
        guard let incarnation = currentIncarnation else { return }
        let engine = engine
        let previous = cancellationBarrier
        Task {
            await previous?.value
            await engine.cancel(caller: .sessionSummary(incarnation))
        }
    }

    public func bind(to session: ACPSession) {
        guard boundSession !== session else { return }

        observations.removeAll()
        if boundSession != nil {
            requestGeneration &+= 1
            cancelCurrentGeneration()
            clearCard()
            phase = .idle
        }
        boundSession = session
        boundSessionIncarnation = session.incarnation

        session.nextPromptActivity
            .observe { [weak self, weak session] in
                guard let self, let session, self.boundSession === session else { return }
                self.handleActivity(session)
            }
            .store(in: &observations)
        session.nextPromptTeardown
            .observe { [weak self, weak session] in
                guard let self, let session, self.boundSession === session else { return }
                self.endSession(session)
            }
            .store(in: &observations)
    }

    public func summary(for session: ACPSession, mode: SessionSummaryRequestMode = .manual) async {
        await Self.wait(for: startGeneration(for: session, mode: mode, bypassingCache: false))
    }

    public func refresh(_ session: ACPSession, mode: SessionSummaryRequestMode = .manual) async {
        await Self.wait(for: startGeneration(for: session, mode: mode, bypassingCache: true))
    }

    public func cancelPresentation() {
        clearCard()
        guard generationTask != nil else { return }
        requestGeneration &+= 1
        cancelCurrentGeneration()
        phase = .idle
    }

    public func dismissCard() {
        cancelPresentation()
    }

    public func invalidate(_ session: ACPSession) {
        evictCache(for: session.incarnation)
        guard boundSession === session else { return }
        requestGeneration &+= 1
        cancelCurrentGeneration()
        clearCard()
        phase = .idle
        presentationGeneration &+= 1
    }

    /// Drops in-memory state only. Persisted summaries survive; see
    /// `clearPersistedSummaries(in:)`.
    public func teardown() {
        requestGeneration &+= 1
        cancelCurrentGeneration()
        observations.removeAll()
        boundSession = nil
        boundSessionIncarnation = nil
        cache.removeAll()
        cacheTeardownObservations.removeAll()
        clearCard()
        phase = .idle
        presentationGeneration &+= 1
    }

    /// Deletes every persisted summary. Only for turning summaries off.
    public func clearPersistedSummaries(in stores: [any SessionSummaryStoring]) async {
        for store in stores {
            do {
                try await store.deleteAllSessionSummaries()
            } catch {
                sessionSummaryLogger.error("clearing persisted summaries failed: \(String(describing: error))")
            }
        }
    }

    /// Background job; does not touch `phase` or `cardMode`. Returns true when a valid summary now exists.
    public func precompute(
        sessionId: String,
        context: SessionSummaryContext,
        store: any SessionSummaryStoring
    ) async -> Bool {
        let inputHash = context.inputHash(modelID: modelID)
        do {
            if try await store.loadSessionSummary(sessionId: sessionId, inputHash: inputHash, modelID: modelID) != nil {
                return true
            }
            let raw = try await engine.generate(
                Self.request(for: context),
                caller: .sessionRecapPrecompute(sessionId),
                priority: .background
            )
            guard let summary = Self.parse(raw, context: context) else { return false }
            try await store.saveSessionSummary(sessionId: sessionId, .init(
                inputHash: inputHash,
                modelID: modelID,
                summary: summary,
                createdAt: Int64(Date().timeIntervalSince1970)
            ))
            return true
        } catch {
            sessionSummaryLogger.debug("recap precompute ended without a summary: \(String(describing: error))")
            return false
        }
    }

    public func cancelPrecompute(sessionId: String) async {
        await engine.cancel(caller: .sessionRecapPrecompute(sessionId))
    }

    private func startGeneration(
        for session: ACPSession,
        mode: SessionSummaryRequestMode,
        bypassingCache: Bool
    ) -> Task<Void, Never>? {
        if boundSession !== session { bind(to: session) }
        if cardMode != mode { cardMode = mode }

        // The idle check comes before any lookup; the hash needs the snapshot anyway.
        let context = SessionSummaryContext.snapshot(session: session)
            .flatMap { $0.revision?.idleFacts.isIdle == true ? $0 : nil }
        let inputHash = context?.inputHash(modelID: modelID)
        if !bypassingCache, let inputHash, let cached = cache[session.incarnation], cached.inputHash == inputHash {
            _ = publishPhase(.result(cached.summary), generation: requestGeneration, session: session)
            return nil
        }

        requestGeneration &+= 1
        cancelCurrentGeneration()
        let generation = requestGeneration
        let previous = cache[session.incarnation]?.summary
        guard let context, let inputHash else {
            publishFailure(
                "There is not enough idle session context to summarize.",
                previous: previous,
                mode: mode,
                generation: generation,
                session: session
            )
            return nil
        }

        let incarnation = session.incarnation
        let sessionId = session.id
        let modelID = modelID
        let request = Self.request(for: context)
        let store = storeProvider?(session)
        let barrier = cancellationBarrier
        let engine = engine
        currentIncarnation = incarnation
        guard publishPhase(
            .loading,
            generation: generation,
            session: session,
            currentIncarnation: incarnation
        ) else { return nil }

        let task = Task { @MainActor [weak self, weak session] in
            if let barrier { await barrier.value }
            guard let session,
                  !Task.isCancelled,
                  self?.requestIsCurrent(generation, session: session) == true else { return }
            if !bypassingCache, let store {
                let stored: SessionSummary?
                do {
                    stored = try await store.loadSessionSummary(
                        sessionId: sessionId,
                        inputHash: inputHash,
                        modelID: modelID
                    )
                } catch {
                    sessionSummaryLogger.error("loading a persisted summary failed: \(String(describing: error))")
                    stored = nil
                }
                guard let self else { return }
                if let stored {
                    self.publishStored(
                        stored,
                        context: context,
                        inputHash: inputHash,
                        mode: mode,
                        session: session,
                        generation: generation
                    )
                    return
                }
                guard self.requestIsCurrent(generation, session: session) else { return }
            }
            do {
                let raw = try await engine.generate(
                    request,
                    caller: .sessionSummary(incarnation),
                    priority: .userInitiated
                )
                guard let self else { return }
                self.publish(
                    raw,
                    context: context,
                    inputHash: inputHash,
                    store: store,
                    previous: previous,
                    mode: mode,
                    session: session,
                    generation: generation
                )
            } catch {
                guard let self else { return }
                self.publishFailure(
                    error,
                    context: context,
                    previous: previous,
                    mode: mode,
                    session: session,
                    generation: generation
                )
            }
        }
        generationTask = task
        return task
    }

    private nonisolated static func wait(for task: Task<Void, Never>?) async {
        await task?.value
    }

    private static func request(for context: SessionSummaryContext) -> LocalTextGenerationRequest {
        LocalTextGenerationRequest(
            messageCandidates: context.messageCandidates(),
            inputTokenLimit: SessionSummaryContext.tokenLimit,
            maxTokens: 512,
            temperature: 0,
            prefillStepSize: 512,
            timeout: .seconds(30)
        )
    }

    private static func parse(_ raw: LocalTextGenerationResult, context: SessionSummaryContext) -> SessionSummary? {
        SessionSummaryPolicy.parse(
            Data(raw.text.utf8),
            isPartial: context.omittedOlderTurns || raw.selectedCandidateIndex > 0
        )
    }

    /// The summary still describes the session only when the revision it was
    /// requested against is unchanged.
    private func isCurrent(_ generation: UInt64, context: SessionSummaryContext, session: ACPSession) -> Bool {
        requestIsCurrent(generation, session: session)
            && SessionSummaryContext.snapshot(session: session)?.revision == context.revision
    }

    private func publishStored(
        _ summary: SessionSummary,
        context: SessionSummaryContext,
        inputHash: String,
        mode: SessionSummaryRequestMode,
        session: ACPSession,
        generation: UInt64
    ) {
        guard isCurrent(generation, context: context, session: session) else {
            finishStaleRequest(generation, mode: mode)
            return
        }
        publishResult(summary, inputHash: inputHash, store: nil, session: session, generation: generation)
    }

    private func publish(
        _ raw: LocalTextGenerationResult,
        context: SessionSummaryContext,
        inputHash: String,
        store: (any SessionSummaryStoring)?,
        previous: SessionSummary?,
        mode: SessionSummaryRequestMode,
        session: ACPSession,
        generation: UInt64
    ) {
        guard isCurrent(generation, context: context, session: session) else {
            finishStaleRequest(generation, mode: mode)
            return
        }
        guard let summary = Self.parse(raw, context: context) else {
            publishFailure(
                "Alas could not produce a usable session summary.",
                previous: previous,
                mode: mode,
                generation: generation,
                session: session,
                currentIncarnation: session.incarnation
            )
            return
        }
        publishResult(summary, inputHash: inputHash, store: store, session: session, generation: generation)
    }

    private func publishResult(
        _ summary: SessionSummary,
        inputHash: String,
        store: (any SessionSummaryStoring)?,
        session: ACPSession,
        generation: UInt64
    ) {
        storeCache(summary, inputHash: inputHash, for: session)
        if let store {
            let sessionId = session.id
            let stored = StoredSessionSummary(
                inputHash: inputHash,
                modelID: modelID,
                summary: summary,
                createdAt: Int64(Date().timeIntervalSince1970)
            )
            Task {
                do {
                    try await store.saveSessionSummary(sessionId: sessionId, stored)
                } catch {
                    sessionSummaryLogger.error("saving a session summary failed: \(String(describing: error))")
                }
            }
        }
        guard publishPhase(
            .result(summary),
            generation: generation,
            session: session,
            currentIncarnation: session.incarnation
        ) else { return }
        finishRequest(generation)
    }

    private func publishFailure(
        _ error: Error,
        context: SessionSummaryContext,
        previous: SessionSummary?,
        mode: SessionSummaryRequestMode,
        session: ACPSession,
        generation: UInt64
    ) {
        guard isCurrent(generation, context: context, session: session) else {
            finishStaleRequest(generation, mode: mode)
            return
        }
        publishFailure(
            Self.message(for: error),
            previous: previous,
            mode: mode,
            generation: generation,
            session: session,
            currentIncarnation: session.incarnation
        )
    }

    /// Manual requests show the error; recap requests hide the card silently.
    private func publishFailure(
        _ message: String,
        previous: SessionSummary?,
        mode: SessionSummaryRequestMode,
        generation: UInt64,
        session: ACPSession,
        currentIncarnation: UUID? = nil
    ) {
        switch mode {
        case .manual:
            guard publishPhase(
                .failed(message, previous: previous),
                generation: generation,
                session: session,
                currentIncarnation: currentIncarnation
            ) else { return }
        case .recap:
            guard requestGeneration == generation,
                  boundSession === session,
                  currentIncarnation == nil || self.currentIncarnation == currentIncarnation else { return }
            clearCard()
            phase = .idle
        }
        finishRequest(generation)
    }

    @discardableResult
    private func publishPhase(
        _ newPhase: Phase,
        generation: UInt64,
        session: ACPSession,
        currentIncarnation: UUID? = nil
    ) -> Bool {
        phase = newPhase
        guard requestGeneration == generation,
              boundSession === session,
              currentIncarnation == nil || self.currentIncarnation == currentIncarnation else {
            phase = .idle
            return false
        }
        return true
    }

    private func requestIsCurrent(_ generation: UInt64, session: ACPSession) -> Bool {
        !Task.isCancelled
            && requestGeneration == generation
            && currentIncarnation == session.incarnation
            && boundSession === session
    }

    private func finishStaleRequest(_ generation: UInt64, mode: SessionSummaryRequestMode) {
        guard requestGeneration == generation else { return }
        if mode == .recap { clearCard() }
        phase = .idle
        finishRequest(generation)
    }

    private func finishRequest(_ generation: UInt64) {
        guard requestGeneration == generation else { return }
        generationTask = nil
        currentIncarnation = nil
    }

    private func handleActivity(_ session: ACPSession) {
        requestGeneration &+= 1
        cancelCurrentGeneration()
        phase = .idle
        clearCard()
        presentationGeneration &+= 1
    }

    private func endSession(_ session: ACPSession) {
        evictCache(for: session.incarnation)
        requestGeneration &+= 1
        cancelCurrentGeneration()
        clearCard()
        phase = .idle
        presentationGeneration &+= 1
        observations.removeAll()
        boundSession = nil
        boundSessionIncarnation = nil
    }

    private func clearCard() {
        if cardMode != nil { cardMode = nil }
    }

    private func storeCache(
        _ summary: SessionSummary,
        inputHash: String,
        for session: ACPSession
    ) {
        let incarnation = session.incarnation
        cache[incarnation] = .init(summary: summary, inputHash: inputHash)
        guard cacheTeardownObservations[incarnation] == nil else { return }
        cacheTeardownObservations[incarnation] = session.nextPromptTeardown.observe { [weak self] in
            self?.evictCache(for: incarnation)
        }
    }

    private func evictCache(for incarnation: UUID) {
        cache[incarnation] = nil
        cacheTeardownObservations[incarnation] = nil
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
