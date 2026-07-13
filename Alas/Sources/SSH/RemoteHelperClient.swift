import Foundation

struct RemoteHelperInvocation: Equatable {
    let executable: String
    let args: [String]
}

private struct ActiveRemoteHelperSubscription {
    let params: RemoteHelperWatchSubscribeParams
    var helperSubscriptionId: String
    var helperGeneration: Int
}

enum RemoteHelperClientError: Error, Equatable {
    case notRunning
    case unavailable(String)
    case jsonrpc(JSONRPCError)
    case decoding(String)

    var shouldFallbackToRemoteExec: Bool {
        switch self {
        case .notRunning, .unavailable:
            return true
        case .jsonrpc, .decoding:
            return false
        }
    }
}

actor RemoteHelperClient {
    typealias TransportFactory = @Sendable () -> JSONRPCStdioTransporting

    static let defaultIdleShutdownNanoseconds: UInt64 = 600_000_000_000

    nonisolated let host: String
    nonisolated let watchEvents: AsyncStream<RemoteHelperWatchEvent>

    private let transportFactory: TransportFactory
    private let idleShutdownNanoseconds: UInt64
    private let watchEventsCont: AsyncStream<RemoteHelperWatchEvent>.Continuation
    private var transport: JSONRPCStdioTransporting?
    private var dispatchTask: Task<Void, Never>?
    private var idleShutdownTask: Task<Void, Never>?
    private var generation = 0
    private var nextId = 0
    private var nextClientSubscriptionId = 0
    private var pending: [JSONRPCID: CheckedContinuation<Data, Error>] = [:]
    private var activeSubscriptions: [String: ActiveRemoteHelperSubscription] = [:]
    private var subscriptionReplayTask: Task<Void, Error>?
    private var subscriptionsNeedReplay = false
    private var lastExitStatus: Int32?

    init(
        host: String,
        idleShutdownNanoseconds: UInt64 = RemoteHelperClient.defaultIdleShutdownNanoseconds,
        transportFactory: TransportFactory? = nil
    ) {
        self.host = host
        self.idleShutdownNanoseconds = idleShutdownNanoseconds
        self.transportFactory = transportFactory ?? {
            Self.makeTransport(host: host)
        }
        var eventsCont: AsyncStream<RemoteHelperWatchEvent>.Continuation!
        self.watchEvents = AsyncStream { eventsCont = $0 }
        self.watchEventsCont = eventsCont
    }

    static func invocation(host: String) -> RemoteHelperInvocation {
        let ssh = SSHCommand(host: host, mode: .batch)
        let script = SSHCommand.remoteScript(command: "exec \"$HOME/.alas/bin/alas-helper\" serve")
        return RemoteHelperInvocation(
            executable: SSHCommand.executable,
            args: ssh.argv(remoteScript: script)
        )
    }

    private static func makeTransport(host: String) -> JSONRPCStdioTransporting {
        let invocation = invocation(host: host)
        return JSONRPCStdioTransport(
            executable: URL(fileURLWithPath: invocation.executable),
            arguments: invocation.args,
            environment: nil,
            framing: .newline
        )
    }

    func hello(_ params: RemoteHelperHelloParams = .init()) async throws -> RemoteHelperHelloResult {
        try await request(method: "hello", params: params)
    }

    func ping() async throws -> RemoteHelperPingResult {
        try await request(method: "ping", params: RemoteHelperNoParams())
    }

    func subscribe(
        root: String,
        kinds: [RemoteHelperWatchKind]
    ) async throws -> RemoteHelperWatchSubscribeResult {
        let helperResult: RemoteHelperWatchSubscribeResult = try await request(
            method: "watch/subscribe",
            params: RemoteHelperWatchSubscribeParams(root: root, kinds: kinds)
        )
        let params = RemoteHelperWatchSubscribeParams(root: root, kinds: kinds)
        let clientSubscriptionId = makeClientSubscriptionId(avoiding: helperResult.subscriptionId)
        activeSubscriptions[clientSubscriptionId] = ActiveRemoteHelperSubscription(
            params: params,
            helperSubscriptionId: helperResult.subscriptionId,
            helperGeneration: generation
        )
        return RemoteHelperWatchSubscribeResult(subscriptionId: clientSubscriptionId)
    }

    func unsubscribe(subscriptionId: String) async throws -> RemoteHelperWatchUnsubscribeResult {
        let helperSubscriptionId = activeSubscriptions[subscriptionId]?.helperSubscriptionId ?? subscriptionId
        guard transport != nil else {
            activeSubscriptions.removeValue(forKey: subscriptionId)
            scheduleIdleShutdownIfPossible()
            return RemoteHelperWatchUnsubscribeResult(ok: true)
        }

        let result: RemoteHelperWatchUnsubscribeResult
        do {
            result = try await request(
                method: "watch/unsubscribe",
                params: RemoteHelperWatchUnsubscribeParams(subscriptionId: helperSubscriptionId),
                replaySubscriptionsOnStart: false
            )
        } catch RemoteHelperClientError.notRunning {
            activeSubscriptions.removeValue(forKey: subscriptionId)
            scheduleIdleShutdownIfPossible()
            return RemoteHelperWatchUnsubscribeResult(ok: true)
        }
        activeSubscriptions.removeValue(forKey: subscriptionId)
        scheduleIdleShutdownIfPossible()
        return result
    }

    func read(path: String, offset: UInt64? = nil) async throws -> RemoteHelperFSReadResult {
        try await request(method: "fs/read", params: RemoteHelperFSReadParams(path: path, offset: offset))
    }

    func write(path: String, content: String, expectedMtime: Double? = nil) async throws -> RemoteHelperFSWriteResult {
        try await request(
            method: "fs/write",
            params: RemoteHelperFSWriteParams(path: path, content: content, expectedMtime: expectedMtime)
        )
    }

    func stat(paths: [String]) async throws -> RemoteHelperFSStatResult {
        try await request(method: "fs/stat", params: RemoteHelperFSStatParams(paths: paths))
    }

    func shutdown() {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        subscriptionReplayTask?.cancel()
        subscriptionReplayTask = nil
        subscriptionsNeedReplay = false
        activeSubscriptions.removeAll()
        drainPending(with: RemoteHelperClientError.notRunning)
        dispatchTask?.cancel()
        dispatchTask = nil
        transport?.terminate()
        transport = nil
    }

    func lastObservedExitStatus() -> Int32? {
        lastExitStatus
    }

    private func request<Params: Encodable, Result: Decodable>(
        method: String,
        params: Params,
        replaySubscriptionsOnStart: Bool = true
    ) async throws -> Result {
        let didStart = try ensureStarted()
        if replaySubscriptionsOnStart {
            if didStart, !activeSubscriptions.isEmpty {
                subscriptionsNeedReplay = true
            }
            if subscriptionsNeedReplay {
                startSubscriptionReplayIfNeeded()
            }
            if let subscriptionReplayTask {
                try await subscriptionReplayTask.value
            }
        }
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        defer {
            scheduleIdleShutdownIfPossible()
        }

        nextId += 1
        let id = JSONRPCID.number(nextId)
        let body = try Self.encodeRequest(method: method, params: params, id: id)

        let data: Data
        do {
            data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                pending[id] = cont
                do {
                    guard let transport else {
                        pending.removeValue(forKey: id)
                        cont.resume(throwing: RemoteHelperClientError.notRunning)
                        return
                    }
                    try transport.send(body)
                } catch {
                    let stillPending = pending.removeValue(forKey: id) != nil
                    if stillPending { cont.resume(throwing: error) }
                }
            }
        } catch {
            if Self.responseErrorIndicatesLiveHost(error) {
                await reportHostSuccess()
            }
            throw error
        }
        await reportHostSuccess()
        do {
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            throw RemoteHelperClientError.decoding(error.localizedDescription)
        }
    }

    private func ensureStarted() throws -> Bool {
        if transport != nil {
            return false
        }
        let nextTransport = transportFactory()
        try nextTransport.start()
        generation += 1
        let transportGeneration = generation
        transport = nextTransport
        lastExitStatus = nil
        dispatchTask = Task { [weak self] in
            for await event in nextTransport.incoming {
                await self?.handle(event, generation: transportGeneration)
            }
        }
        return true
    }

    private func startSubscriptionReplayIfNeeded() {
        guard subscriptionReplayTask == nil, !activeSubscriptions.isEmpty else { return }
        subscriptionReplayTask = Task { [weak self] in
            guard let self else { return }
            try await self.replayActiveSubscriptions()
        }
    }

    private func makeClientSubscriptionId(avoiding helperSubscriptionId: String) -> String {
        while true {
            nextClientSubscriptionId += 1
            let candidate = "client-\(nextClientSubscriptionId)"
            guard candidate != helperSubscriptionId,
                  activeSubscriptions[candidate] == nil,
                  !activeSubscriptions.values.contains(where: { $0.helperSubscriptionId == candidate })
            else {
                continue
            }
            return candidate
        }
    }

    private func replayActiveSubscriptions() async throws {
        defer {
            subscriptionReplayTask = nil
        }
        var restartCount = 0
        while true {
            _ = try ensureStarted()
            let replayGeneration = generation
            let subscriptions = activeSubscriptions
            guard !subscriptions.isEmpty else {
                subscriptionsNeedReplay = false
                return
            }

            var shouldRestartReplay = false
            for (clientSubscriptionId, subscription) in subscriptions {
                guard subscription.helperGeneration != replayGeneration else {
                    continue
                }
                guard transport != nil, generation == replayGeneration else {
                    shouldRestartReplay = true
                    break
                }

                let result: RemoteHelperWatchSubscribeResult
                do {
                    result = try await request(
                        method: "watch/subscribe",
                        params: subscription.params,
                        replaySubscriptionsOnStart: false
                    )
                } catch RemoteHelperClientError.notRunning where transport == nil || generation != replayGeneration {
                    shouldRestartReplay = true
                    break
                }

                guard transport != nil, generation == replayGeneration else {
                    shouldRestartReplay = true
                    break
                }
                guard activeSubscriptions[clientSubscriptionId]?.params == subscription.params else {
                    let _: RemoteHelperWatchUnsubscribeResult? = try? await request(
                        method: "watch/unsubscribe",
                        params: RemoteHelperWatchUnsubscribeParams(subscriptionId: result.subscriptionId),
                        replaySubscriptionsOnStart: false
                    )
                    continue
                }
                activeSubscriptions[clientSubscriptionId] = ActiveRemoteHelperSubscription(
                    params: subscription.params,
                    helperSubscriptionId: result.subscriptionId,
                    helperGeneration: replayGeneration
                )
            }

            guard shouldRestartReplay else {
                subscriptionsNeedReplay = false
                return
            }
            restartCount += 1
            guard restartCount <= subscriptions.count + 1 else {
                throw RemoteHelperClientError.notRunning
            }
        }
    }

    private func handle(_ event: JSONRPCStdioTransport.Incoming, generation eventGeneration: Int) {
        guard eventGeneration == generation else { return }
        switch event {
        case .frame(let data):
            handleFrame(data)
        case .stderr:
            break
        case .exited(let status):
            handleExit(status)
        }
    }

    private struct AnyEnvelopeHead: Decodable {
        let id: JSONRPCID?
        let method: String?
    }

    private func handleFrame(_ data: Data) {
        guard let head = try? JSONDecoder().decode(AnyEnvelopeHead.self, from: data) else {
            return
        }

        if let id = head.id, head.method == nil {
            let cont = pending.removeValue(forKey: id)
            guard let cont else { return }
            if let env = try? JSONDecoder().decode(RemoteHelperJSONRPCErrorEnvelope.self, from: data),
               let error = env.error {
                cont.resume(throwing: RemoteHelperClientError.jsonrpc(error))
                return
            }
            guard let result = Self.extractResultBytes(from: data) else {
                cont.resume(throwing: RemoteHelperClientError.decoding("no result/error in response"))
                return
            }
            cont.resume(returning: result)
            return
        }

        guard head.method == "watch/event",
              let env = try? JSONDecoder().decode(JSONRPCEnvelope<RemoteHelperWatchEvent>.self, from: data),
              let event = env.params
        else {
            return
        }
        watchEventsCont.yield(event)
    }

    private func handleExit(_ status: Int32) {
        lastExitStatus = status
        transport = nil
        dispatchTask = nil
        subscriptionsNeedReplay = !activeSubscriptions.isEmpty
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        drainPending(with: RemoteHelperClientError.notRunning)
        if RemoteExec.isConnectionFailure(exitCode: status) {
            Task { @MainActor [host] in
                RemoteHostStatusStore.shared.reportConnectionFailure(host: host)
            }
        }
    }

    private func drainPending(with error: Error) {
        let snapshot = pending
        pending.removeAll()
        for (_, cont) in snapshot {
            cont.resume(throwing: error)
        }
    }

    private func scheduleIdleShutdownIfPossible() {
        guard idleShutdownNanoseconds > 0, pending.isEmpty, activeSubscriptions.isEmpty, transport != nil else { return }
        idleShutdownTask?.cancel()
        let delay = idleShutdownNanoseconds
        idleShutdownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            await self?.shutdownIfIdle()
        }
    }

    private func shutdownIfIdle() {
        guard pending.isEmpty, activeSubscriptions.isEmpty else { return }
        shutdown()
    }

    @MainActor
    private func reportHostSuccess() {
        RemoteHostStatusStore.shared.reportSuccess(host: host)
    }

    private static func encodeRequest<Params: Encodable>(
        method: String,
        params: Params,
        id: JSONRPCID
    ) throws -> Data {
        var dict: [String: Any] = ["jsonrpc": "2.0", "id": id.asJSON, "method": method]
        let paramsData = try JSONEncoder().encode(RemoteHelperAnyEncodableBox(params))
        dict["params"] = try JSONSerialization.jsonObject(with: paramsData)
        return try JSONSerialization.data(withJSONObject: dict)
    }

    private static func responseErrorIndicatesLiveHost(_ error: Error) -> Bool {
        guard let error = error as? RemoteHelperClientError else { return false }
        switch error {
        case .jsonrpc, .decoding:
            return true
        case .notRunning, .unavailable:
            return false
        }
    }

    private static func extractResultBytes(from envelope: Data) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any],
              let result = obj["result"]
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
    }
}

actor RemoteHelperClientPool {
    static let shared = RemoteHelperClientPool()

    private var clients: [String: RemoteHelperClient] = [:]

    func client(for host: String) -> RemoteHelperClient {
        if let client = clients[host] {
            return client
        }
        let client = RemoteHelperClient(host: host)
        clients[host] = client
        return client
    }

    func shutdown(host: String) {
        guard let client = clients.removeValue(forKey: host) else { return }
        Task {
            await client.shutdown()
        }
    }

    func shutdownAll() {
        let snapshot = clients
        clients.removeAll()
        for (_, client) in snapshot {
            Task {
                await client.shutdown()
            }
        }
    }
}

private struct RemoteHelperNoParams: Encodable {}

private struct RemoteHelperJSONRPCErrorEnvelope: Decodable {
    let error: JSONRPCError?
}

private struct RemoteHelperAnyEncodableBox: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

private extension JSONRPCID {
    var asJSON: Any {
        switch self {
        case .number(let value): return value
        case .string(let value): return value
        }
    }
}
