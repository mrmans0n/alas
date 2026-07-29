actor MermaidRenderLimiter {
    private var permits = 2
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
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
    private var inFlight: [MermaidRenderKey: Task<MermaidRenderOutcome, Never>] = [:]

    init(backend: any MermaidRenderingBackend) {
        self.backend = backend
    }

    func render(key: MermaidRenderKey) async -> MermaidRenderOutcome {
        if let cached = cache.value(for: key) {
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task { [backend, limiter] in
            await limiter.acquire()
            let outcome = await backend.render(key: key)
            await limiter.release()
            return outcome
        }
        inFlight[key] = task

        let outcome = await task.value
        inFlight.removeValue(forKey: key)
        cache.insert(outcome, for: key)
        return outcome
    }
}
