import Foundation

@MainActor
final class RemoteHelperWatchSession {
    var onEvent: ((RemoteHelperWatchEvent) -> Void)?
    var onAvailabilityChanged: ((Bool) -> Void)?

    private(set) var isAvailable = false

    private let host: String
    private let root: String
    private let kinds: [RemoteHelperWatchKind]
    private let retryInterval: TimeInterval
    private var connectionTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var client: RemoteHelperClient?
    private var handle: RemoteHelperWatchHandle?
    private var lastAttemptAt: Date?
    private var generation = 0

    init(
        host: String,
        root: String,
        kinds: [RemoteHelperWatchKind],
        retryInterval: TimeInterval = 5 * 60
    ) {
        self.host = host
        self.root = root
        self.kinds = kinds
        self.retryInterval = retryInterval
    }

    func start() {
        guard connectionTask == nil, handle == nil else { return }
        beginConnection()
    }

    func stop() {
        generation &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        retryTask?.cancel()
        retryTask = nil
        let client = client
        let subscriptionId = handle?.subscriptionId
        self.client = nil
        handle = nil
        isAvailable = false
        if let client, let subscriptionId {
            Task {
                _ = try? await client.unsubscribe(subscriptionId: subscriptionId)
            }
        }
    }

    func retryIfNeeded(now: Date = Date()) {
        guard !isAvailable, retryTask == nil else { return }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < retryInterval {
            return
        }
        lastAttemptAt = now
        guard let client, handle != nil else {
            guard connectionTask == nil else { return }
            beginConnection(attemptDate: now)
            return
        }
        retryTask = Task { [weak self] in
            _ = try? await client.ping()
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
        }
    }

    private func beginConnection(attemptDate: Date = Date()) {
        lastAttemptAt = attemptDate
        generation &+= 1
        let attemptGeneration = generation
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = await RemoteHelperClientPool.shared.client(for: host)
                let hello = try await client.hello()
                guard kinds.allSatisfy({ hello.capabilities.watchKinds.contains($0) }) else {
                    await client.shutdown()
                    throw RemoteHelperClientError.unavailable("helper does not support requested watch kinds")
                }
                let handle = try await client.subscribeWithUpdates(root: root, kinds: kinds)
                guard !Task.isCancelled, generation == attemptGeneration else {
                    _ = try? await client.unsubscribe(subscriptionId: handle.subscriptionId)
                    return
                }
                self.client = client
                self.handle = handle
                setAvailable(true)

                for await update in handle.updates {
                    guard !Task.isCancelled, generation == attemptGeneration else { return }
                    switch update {
                    case .available:
                        setAvailable(true)
                    case .unavailable:
                        setAvailable(false)
                    case .event(let event):
                        onEvent?(event)
                    }
                }
            } catch {
                guard !Task.isCancelled, generation == attemptGeneration else { return }
                setAvailable(false)
            }
            guard generation == attemptGeneration else { return }
            self.client = nil
            self.handle = nil
            self.connectionTask = nil
            setAvailable(false)
        }
    }

    private func setAvailable(_ available: Bool) {
        guard isAvailable != available else { return }
        isAvailable = available
        onAvailabilityChanged?(available)
    }
}
