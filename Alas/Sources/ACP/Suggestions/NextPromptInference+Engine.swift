import Foundation

/// The initializers that run the MLX-backed engine stay in the app, so the
/// inference actor itself depends only on `LocalTextGenerating`.
extension NextPromptInference {
    nonisolated static func isSupported() -> Bool { LocalTextInferenceEngine.isSupported() }

    init(store: LocalTextModelStore) {
        self.init(
            engine: LocalTextInferenceEngine(store: store),
            supported: LocalTextInferenceEngine.isSupported,
            verifyAvailability: {
                let lease = try await store.acquireVerifiedLease()
                lease.close()
            }
        )
    }

    init(acquireLease: @escaping @Sendable () async throws -> LocalTextModelLease,
         load: @escaping @Sendable (URL) async throws -> Evaluation,
         supported: @escaping @Sendable () -> Bool = { true }, clock: Clock = Clock(),
         scheduleCancellation: @escaping CancellationScheduler = { action in _ = Task { await action() } }) {
        self.init(
            engine: LocalTextInferenceEngine(
                acquireLease: acquireLease,
                load: { directory in
                    let evaluation = try await load(directory)
                    return { request in
                        return .init(text: try await evaluation(request) ?? "", selectedCandidateIndex: 0)
                    }
                },
                supported: supported,
                clock: clock,
                observeMemoryPressure: false
            ),
            supported: supported,
            verifyAvailability: {
                let lease = try await acquireLease()
                lease.close()
            },
            clock: clock,
            scheduleCancellation: scheduleCancellation
        )
    }
}
