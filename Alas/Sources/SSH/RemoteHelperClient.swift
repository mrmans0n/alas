import Foundation

struct RemoteHelperInvocation: Equatable {
    let executable: String
    let args: [String]
}

private struct ActiveRemoteHelperSubscription {
    let params: RemoteHelperWatchSubscribeParams
    var helperSubscriptionId: String
    var helperGeneration: Int
    let updates: AsyncStream<RemoteHelperWatchUpdate>
    let updatesContinuation: AsyncStream<RemoteHelperWatchUpdate>.Continuation
}

private struct ActiveRemoteHelperSearch {
    let continuation: AsyncThrowingStream<RemoteHelperSearchEvent, Error>.Continuation
}

private struct ActiveRemoteHelperProcAttachment {
    let continuation: AsyncStream<RemoteHelperProcEvent>.Continuation
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
        case .jsonrpc(let error):
            return error.code == -32601 || error.code == -32021
                || error.code == -32022 || error.code == -32023
        case .decoding:
            return false
        }
    }
}

actor RemoteHelperClient {
    typealias TransportFactory = @Sendable () -> JSONRPCStdioTransporting

    static let defaultIdleShutdownNanoseconds: UInt64 = 600_000_000_000
    static let legacyWatchEventBufferLimit = 64

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
    private var activeSearches: [String: ActiveRemoteHelperSearch] = [:]
    private var earlySearchEvents: [String: [RemoteHelperSearchEvent]] = [:]
    private var activeProcAttachments: [String: ActiveRemoteHelperProcAttachment] = [:]
    private var earlyProcEvents: [String: [RemoteHelperProcEvent]] = [:]
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
        self.watchEvents = AsyncStream(
            bufferingPolicy: .bufferingNewest(Self.legacyWatchEventBufferLimit)
        ) { eventsCont = $0 }
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
        let handle = try await subscribeWithUpdates(root: root, kinds: kinds)
        return RemoteHelperWatchSubscribeResult(subscriptionId: handle.subscriptionId)
    }

    func subscribeWithUpdates(
        root: String,
        kinds: [RemoteHelperWatchKind]
    ) async throws -> RemoteHelperWatchHandle {
        let helperResult: RemoteHelperWatchSubscribeResult = try await request(
            method: "watch/subscribe",
            params: RemoteHelperWatchSubscribeParams(root: root, kinds: kinds)
        )
        let params = RemoteHelperWatchSubscribeParams(root: root, kinds: kinds)
        let clientSubscriptionId = makeClientSubscriptionId(avoiding: helperResult.subscriptionId)
        var updatesContinuation: AsyncStream<RemoteHelperWatchUpdate>.Continuation!
        let updates = AsyncStream<RemoteHelperWatchUpdate> { updatesContinuation = $0 }
        activeSubscriptions[clientSubscriptionId] = ActiveRemoteHelperSubscription(
            params: params,
            helperSubscriptionId: helperResult.subscriptionId,
            helperGeneration: generation,
            updates: updates,
            updatesContinuation: updatesContinuation
        )
        updatesContinuation.yield(.available)
        return RemoteHelperWatchHandle(subscriptionId: clientSubscriptionId, updates: updates)
    }

    func unsubscribe(subscriptionId: String) async throws -> RemoteHelperWatchUnsubscribeResult {
        let subscription = activeSubscriptions[subscriptionId]
        let helperSubscriptionId = subscription?.helperSubscriptionId ?? subscriptionId
        guard transport != nil else {
            activeSubscriptions.removeValue(forKey: subscriptionId)
            subscription?.updatesContinuation.finish()
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
            subscription?.updatesContinuation.finish()
            scheduleIdleShutdownIfPossible()
            return RemoteHelperWatchUnsubscribeResult(ok: true)
        }
        activeSubscriptions.removeValue(forKey: subscriptionId)
        subscription?.updatesContinuation.finish()
        scheduleIdleShutdownIfPossible()
        return result
    }

    func dropLocalSubscription(subscriptionId: String) {
        guard let subscription = activeSubscriptions.removeValue(forKey: subscriptionId) else { return }
        subscription.updatesContinuation.yield(.unavailable)
        subscription.updatesContinuation.finish()
        scheduleIdleShutdownIfPossible()
    }

    func read(path: String, offset: UInt64? = nil) async throws -> RemoteHelperFSReadResult {
        try await request(method: "fs/read", params: RemoteHelperFSReadParams(path: path, offset: offset))
    }

    func write(
        path: String,
        content: String,
        expectedMtime: Double? = nil,
        expectedContent: String? = nil
    ) async throws -> RemoteHelperFSWriteResult {
        try await request(
            method: "fs/write",
            params: RemoteHelperFSWriteParams(
                path: path,
                content: content,
                expectedMtime: expectedMtime,
                expectedContent: expectedContent
            )
        )
    }

    func stat(paths: [String]) async throws -> RemoteHelperFSStatResult {
        try await request(method: "fs/stat", params: RemoteHelperFSStatParams(paths: paths))
    }

    func lineCounts(root: String, paths: [String]) async throws -> RemoteHelperFSLineCountsResult {
        try await request(
            method: "fs/line-counts",
            params: RemoteHelperFSLineCountsParams(root: root, paths: paths)
        )
    }

    func list(path: String) async throws -> RemoteHelperFSListResult {
        try await request(method: "fs/list", params: RemoteHelperFSListParams(path: path))
    }

    func search(
        root: String,
        query: String,
        caseSensitive: Bool,
        wholeWord: Bool,
        regex: Bool
    ) async throws -> RemoteHelperSearchHandle {
        let result: RemoteHelperSearchStartResult = try await request(
            method: "search/start",
            params: RemoteHelperSearchStartParams(
                root: root,
                query: query,
                caseSensitive: caseSensitive,
                wholeWord: wholeWord,
                regex: regex
            )
        )
        var continuation: AsyncThrowingStream<RemoteHelperSearchEvent, Error>.Continuation!
        let events = AsyncThrowingStream<RemoteHelperSearchEvent, Error> { continuation = $0 }
        activeSearches[result.searchId] = ActiveRemoteHelperSearch(
            continuation: continuation
        )
        for event in earlySearchEvents.removeValue(forKey: result.searchId) ?? [] {
            continuation.yield(event)
            if case .complete = event {
                continuation.finish()
                activeSearches.removeValue(forKey: result.searchId)
            }
        }
        return RemoteHelperSearchHandle(searchId: result.searchId, events: events)
    }

    func cancelSearch(searchId: String) async throws {
        let _: RemoteHelperSearchCancelResult = try await request(
            method: "search/cancel",
            params: RemoteHelperSearchCancelParams(searchId: searchId)
        )
    }

    func spawnProc(
        procId: String,
        command: String,
        args: [String],
        cwd: String,
        env: [String: String]
    ) async throws -> RemoteHelperProcStatus {
        try await request(
            method: "proc/spawn",
            params: RemoteHelperProcSpawnParams(
                procId: procId,
                command: command,
                args: args,
                cwd: cwd,
                env: env
            )
        )
    }

    func attachProc(
        procId: String,
        stdoutOffset: UInt64? = nil,
        stderrOffset: UInt64? = nil
    ) async throws -> RemoteHelperProcAttachHandle {
        let result: RemoteHelperProcAttachResult = try await request(
            method: "proc/attach",
            params: RemoteHelperProcAttachParams(
                procId: procId,
                stdoutOffset: stdoutOffset,
                stderrOffset: stderrOffset
            )
        )
        var continuation: AsyncStream<RemoteHelperProcEvent>.Continuation!
        let events = AsyncStream<RemoteHelperProcEvent> { continuation = $0 }
        activeProcAttachments[procId] = ActiveRemoteHelperProcAttachment(continuation: continuation)
        continuation.yield(.available)
        for frame in result.stdoutFrames {
            if let data = Data(base64Encoded: frame.dataBase64) {
                continuation.yield(.stdout(data, offset: frame.offset))
            }
        }
        for chunk in result.stderrChunks {
            if let data = Data(base64Encoded: chunk.dataBase64) {
                continuation.yield(.stderr(data, offset: chunk.offset))
            }
        }
        for event in earlyProcEvents.removeValue(forKey: procId) ?? [] {
            continuation.yield(event)
        }
        if !result.running {
            continuation.yield(.exited(result.exitCode))
        }
        return RemoteHelperProcAttachHandle(procId: procId, events: events)
    }

    func writeProc(procId: String, data: Data) async throws {
        let _: RemoteHelperProcWriteResult = try await request(
            method: "proc/write",
            params: RemoteHelperProcWriteParams(
                procId: procId,
                dataBase64: data.base64EncodedString()
            ),
            replaySubscriptionsOnStart: false
        )
    }

    func killProc(procId: String) async throws {
        let _: RemoteHelperProcKillResult = try await request(
            method: "proc/kill",
            params: RemoteHelperProcKillParams(procId: procId),
            replaySubscriptionsOnStart: false
        )
    }

    func listProcs() async throws -> RemoteHelperProcListResult {
        try await request(method: "proc/list", params: RemoteHelperNoParams())
    }

    func shutdown() {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        subscriptionReplayTask?.cancel()
        subscriptionReplayTask = nil
        subscriptionsNeedReplay = false
        for subscription in activeSubscriptions.values {
            subscription.updatesContinuation.yield(.unavailable)
            subscription.updatesContinuation.finish()
        }
        activeSubscriptions.removeAll()
        for search in activeSearches.values {
            search.continuation.finish(throwing: RemoteHelperClientError.notRunning)
        }
        activeSearches.removeAll()
        earlySearchEvents.removeAll()
        for proc in activeProcAttachments.values {
            proc.continuation.yield(.unavailable)
            proc.continuation.finish()
        }
        activeProcAttachments.removeAll()
        earlyProcEvents.removeAll()
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
                    helperGeneration: replayGeneration,
                    updates: subscription.updates,
                    updatesContinuation: subscription.updatesContinuation
                )
                subscription.updatesContinuation.yield(.available)
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

        if head.method == "search/event",
           let env = try? JSONDecoder().decode(JSONRPCEnvelope<RemoteHelperSearchEventParams>.self, from: data),
           let event = env.params {
            emitSearchEvent(.line(event.line), searchId: event.searchId)
            return
        }
        if head.method == "search/complete",
           let env = try? JSONDecoder().decode(JSONRPCEnvelope<RemoteHelperSearchCompleteParams>.self, from: data),
           let event = env.params {
            emitSearchEvent(
                .complete(exitCode: event.exitCode, stderr: event.stderr, cancelled: event.cancelled),
                searchId: event.searchId
            )
            return
        }
        if head.method == "proc/output",
           let env = try? JSONDecoder().decode(JSONRPCEnvelope<RemoteHelperProcOutputParams>.self, from: data),
           let event = env.params {
            emitProcOutput(event)
            return
        }
        if head.method == "proc/exit",
           let env = try? JSONDecoder().decode(JSONRPCEnvelope<RemoteHelperProcExitParams>.self, from: data),
           let event = env.params {
            emitProcEvent(.exited(event.exitCode), procId: event.procId)
            return
        }

        guard head.method == "watch/event",
              let env = try? JSONDecoder().decode(JSONRPCEnvelope<RemoteHelperWatchEvent>.self, from: data),
              let event = env.params
        else {
            return
        }
        guard let (clientSubscriptionId, subscription) = activeSubscriptions.first(where: {
            $0.value.helperGeneration == generation
                && $0.value.helperSubscriptionId == event.subscriptionId
        }) else {
            watchEventsCont.yield(event)
            return
        }
        let stableEvent = RemoteHelperWatchEvent(
            subscriptionId: clientSubscriptionId,
            root: event.root,
            kind: event.kind,
            paths: event.paths
        )
        watchEventsCont.yield(stableEvent)
        subscription.updatesContinuation.yield(.event(stableEvent))
    }

    private func emitSearchEvent(_ event: RemoteHelperSearchEvent, searchId: String) {
        guard let search = activeSearches[searchId] else {
            earlySearchEvents[searchId, default: []].append(event)
            return
        }
        search.continuation.yield(event)
        if case .complete = event {
            search.continuation.finish()
            activeSearches.removeValue(forKey: searchId)
            scheduleIdleShutdownIfPossible()
        }
    }

    private func emitProcOutput(_ output: RemoteHelperProcOutputParams) {
        guard let data = Data(base64Encoded: output.dataBase64) else { return }
        switch output.stream {
        case "stdout":
            emitProcEvent(.stdout(data, offset: output.offset), procId: output.procId)
        case "stderr":
            emitProcEvent(.stderr(data, offset: output.offset), procId: output.procId)
        default:
            break
        }
    }

    private func emitProcEvent(_ event: RemoteHelperProcEvent, procId: String) {
        guard let attachment = activeProcAttachments[procId] else {
            earlyProcEvents[procId, default: []].append(event)
            return
        }
        attachment.continuation.yield(event)
        if case .exited = event {
            attachment.continuation.finish()
            activeProcAttachments.removeValue(forKey: procId)
            scheduleIdleShutdownIfPossible()
        }
    }

    private func handleExit(_ status: Int32) {
        lastExitStatus = status
        transport = nil
        dispatchTask = nil
        subscriptionsNeedReplay = !activeSubscriptions.isEmpty
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        drainPending(with: RemoteHelperClientError.notRunning)
        for subscription in activeSubscriptions.values {
            subscription.updatesContinuation.yield(.unavailable)
        }
        for search in activeSearches.values {
            search.continuation.finish(throwing: RemoteHelperClientError.notRunning)
        }
        activeSearches.removeAll()
        earlySearchEvents.removeAll()
        for proc in activeProcAttachments.values {
            proc.continuation.yield(.unavailable)
        }
        activeProcAttachments.removeAll()
        earlyProcEvents.removeAll()
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
        guard idleShutdownNanoseconds > 0,
              pending.isEmpty,
              activeSubscriptions.isEmpty,
              activeSearches.isEmpty,
              activeProcAttachments.isEmpty,
              transport != nil else { return }
        idleShutdownTask?.cancel()
        let delay = idleShutdownNanoseconds
        idleShutdownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            await self?.shutdownIfIdle()
        }
    }

    private func shutdownIfIdle() {
        guard pending.isEmpty,
              activeSubscriptions.isEmpty,
              activeSearches.isEmpty,
              activeProcAttachments.isEmpty else { return }
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
