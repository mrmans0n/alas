import Foundation

actor MermaidRenderLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var permits = 2
    private var waiters: [Waiter] = []

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else if permits > 0 {
                    permits -= 1
                    continuation.resume(returning: true)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

actor MermaidRenderService {
    static let shared = MermaidRenderService(backend: BeautifulMermaidBackend())

    private let backend: any MermaidRenderingBackend
    private let limiter = MermaidRenderLimiter()
    private var cache = MermaidRenderCache(
        countLimit: 128,
        costLimit: 64 * 1024 * 1024
    )
    private struct InFlightRender {
        let id: UUID
        let task: Task<MermaidRenderOutcome?, Never>
        var consumerIDs: Set<UUID>
    }

    private var inFlight: [MermaidRenderKey: InFlightRender] = [:]

    init(backend: any MermaidRenderingBackend) {
        self.backend = backend
    }

    func render(key: MermaidRenderKey) async -> MermaidRenderOutcome {
        if let cached = cache.value(for: key) {
            return cached
        }
        let consumerID = UUID()
        if var render = inFlight[key] {
            render.consumerIDs.insert(consumerID)
            inFlight[key] = render
            return await awaitOutcome(
                for: key,
                renderID: render.id,
                consumerID: consumerID,
                task: render.task
            )
        }

        let renderID = UUID()
        let task: Task<MermaidRenderOutcome?, Never> = Task { [backend, limiter] in
            guard await limiter.acquire(), !Task.isCancelled else {
                return nil
            }
            let outcome = await backend.render(key: key)
            await limiter.release()
            return Task.isCancelled ? nil : outcome
        }
        inFlight[key] = InFlightRender(
            id: renderID,
            task: task,
            consumerIDs: [consumerID]
        )

        return await awaitOutcome(
            for: key,
            renderID: renderID,
            consumerID: consumerID,
            task: task
        )
    }

    private func awaitOutcome(
        for key: MermaidRenderKey,
        renderID: UUID,
        consumerID: UUID,
        task: Task<MermaidRenderOutcome?, Never>
    ) async -> MermaidRenderOutcome {
        await withTaskCancellationHandler {
            let outcome = await task.value
            finish(
                outcome,
                for: key,
                renderID: renderID,
                consumerID: consumerID
            )
            return outcome ?? .failed(.renderFailed("Mermaid rendering cancelled"))
        } onCancel: {
            Task {
                await self.cancelConsumer(
                    for: key,
                    renderID: renderID,
                    consumerID: consumerID
                )
            }
        }
    }

    private func finish(
        _ outcome: MermaidRenderOutcome?,
        for key: MermaidRenderKey,
        renderID: UUID,
        consumerID: UUID
    ) {
        guard var render = inFlight[key], render.id == renderID,
              render.consumerIDs.remove(consumerID) != nil
        else { return }
        inFlight.removeValue(forKey: key)
        if let outcome {
            cache.insert(outcome, for: key)
        }
    }

    private func cancelConsumer(
        for key: MermaidRenderKey,
        renderID: UUID,
        consumerID: UUID
    ) {
        guard var render = inFlight[key], render.id == renderID,
              render.consumerIDs.remove(consumerID) != nil
        else { return }

        if render.consumerIDs.isEmpty {
            render.task.cancel()
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = render
        }
    }
}
