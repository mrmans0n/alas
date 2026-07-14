import Foundation

final class ACPStdioClient: ACPClient, @unchecked Sendable {
    private let transport: JSONRPCStdioTransporting
    private let updatesCont: AsyncStream<ACPSessionUpdateParams>.Continuation
    private let permsCont: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>.Continuation
    private let questionsCont: AsyncStream<ACPQuestionRequest>.Continuation
    private let elicitationsCont: AsyncStream<ACPElicitationRequest>.Continuation
    private let elicitationCompletionsCont: AsyncStream<ACPElicitationCompleteParams>.Continuation
    private let filesCont: AsyncStream<ACPFileRequest>.Continuation
    private let terminalsCont: AsyncStream<ACPTerminalRequest>.Continuation
    private let stderrCont: AsyncStream<Data>.Continuation

    let incomingUpdates: AsyncStream<ACPSessionUpdateParams>
    var yieldedUpdateCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _yieldedUpdateCount
    }
    let permissionRequests: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>
    let questionRequests: AsyncStream<ACPQuestionRequest>
    let elicitationRequests: AsyncStream<ACPElicitationRequest>
    let elicitationCompletions: AsyncStream<ACPElicitationCompleteParams>
    let fileRequests: AsyncStream<ACPFileRequest>
    let terminalRequests: AsyncStream<ACPTerminalRequest>
    let incomingStderr: AsyncStream<Data>

    private let stateLock = NSLock()
    private var nextId: Int = 0
    private var _yieldedUpdateCount = 0
    private var pending: [JSONRPCID: CheckedContinuation<Data, Error>] = [:]
    private var didDrainPending = false
    private var dispatchTask: Task<Void, Never>?

    init(executable: URL, arguments: [String], environment: [String: String]?) throws {
        self.transport = JSONRPCStdioTransport(
            executable: executable,
            arguments: arguments,
            environment: environment,
            framing: .newline,
            // ACPProcessEnvironment.sanitizedForACP has already produced the
            // full env with Claude-specific markers scrubbed. Tell the transport not
            // to re-overlay against the parent process's env (which would
            // re-introduce CLAUDECODE).
            replaceEnv: true
        )

        var uC: AsyncStream<ACPSessionUpdateParams>.Continuation!
        self.incomingUpdates = AsyncStream { uC = $0 }
        self.updatesCont = uC

        var pC: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>.Continuation!
        self.permissionRequests = AsyncStream { pC = $0 }
        self.permsCont = pC

        var qC: AsyncStream<ACPQuestionRequest>.Continuation!
        self.questionRequests = AsyncStream { qC = $0 }
        self.questionsCont = qC

        var elC: AsyncStream<ACPElicitationRequest>.Continuation!
        self.elicitationRequests = AsyncStream { elC = $0 }
        self.elicitationsCont = elC

        var ecC: AsyncStream<ACPElicitationCompleteParams>.Continuation!
        self.elicitationCompletions = AsyncStream { ecC = $0 }
        self.elicitationCompletionsCont = ecC

        var fC: AsyncStream<ACPFileRequest>.Continuation!
        self.fileRequests = AsyncStream { fC = $0 }
        self.filesCont = fC

        var tC: AsyncStream<ACPTerminalRequest>.Continuation!
        self.terminalRequests = AsyncStream { tC = $0 }
        self.terminalsCont = tC

        var eC: AsyncStream<Data>.Continuation!
        self.incomingStderr = AsyncStream { eC = $0 }
        self.stderrCont = eC
    }

    /// Test-only initialiser: accepts a pre-built transport directly,
    /// skipping the real-subprocess setup.
    init(transport: JSONRPCStdioTransporting) {
        self.transport = transport

        var uC: AsyncStream<ACPSessionUpdateParams>.Continuation!
        self.incomingUpdates = AsyncStream { uC = $0 }
        self.updatesCont = uC

        var pC: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>.Continuation!
        self.permissionRequests = AsyncStream { pC = $0 }
        self.permsCont = pC

        var qC: AsyncStream<ACPQuestionRequest>.Continuation!
        self.questionRequests = AsyncStream { qC = $0 }
        self.questionsCont = qC

        var elC: AsyncStream<ACPElicitationRequest>.Continuation!
        self.elicitationRequests = AsyncStream { elC = $0 }
        self.elicitationsCont = elC

        var ecC: AsyncStream<ACPElicitationCompleteParams>.Continuation!
        self.elicitationCompletions = AsyncStream { ecC = $0 }
        self.elicitationCompletionsCont = ecC

        var fC: AsyncStream<ACPFileRequest>.Continuation!
        self.fileRequests = AsyncStream { fC = $0 }
        self.filesCont = fC

        var tC: AsyncStream<ACPTerminalRequest>.Continuation!
        self.terminalRequests = AsyncStream { tC = $0 }
        self.terminalsCont = tC

        var eC: AsyncStream<Data>.Continuation!
        self.incomingStderr = AsyncStream { eC = $0 }
        self.stderrCont = eC
    }

    /// Convenience factory for tests — wraps `init(transport:)`.
    static func makeForTesting(transport: JSONRPCStdioTransporting) -> ACPStdioClient {
        ACPStdioClient(transport: transport)
    }

    func start() throws {
        try transport.start()
        dispatchTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.transport.incoming {
                self.handle(event)
            }
        }
    }

    private func handle(_ event: JSONRPCStdioTransport.Incoming) {
        switch event {
        case .frame(let data, let onConsumed):
            handleFrame(data, onConsumed: onConsumed)
        case .stderr(let data):
            stderrCont.yield(data)
        case .exited:
            drainPending(with: ACPClientError.notRunning)
            updatesCont.finish()
            permsCont.finish()
            questionsCont.finish()
            elicitationsCont.finish()
            elicitationCompletionsCont.finish()
            filesCont.finish()
            terminalsCont.finish()
            stderrCont.finish()
        }
    }

    private struct AnyEnvelopeHead: Decodable {
        let id: JSONRPCID?
        let method: String?
    }

    private func handleFrame(_ data: Data, onConsumed: (@Sendable () -> Void)?) {
        var acknowledgeAfterDispatch = true
        defer {
            if acknowledgeAfterDispatch {
                onConsumed?()
            }
        }
        guard let head = try? JSONDecoder().decode(AnyEnvelopeHead.self, from: data) else { return }
        if let id = head.id, head.method == nil {
            stateLock.lock()
            let cont = pending.removeValue(forKey: id)
            stateLock.unlock()
            guard let cont else { return }
            if let env = try? JSONDecoder().decode(JSONRPCErrorEnvelope.self, from: data),
               let err = env.error {
                cont.resume(throwing: ACPClientError.jsonrpc(err))
                return
            }
            if let raw = Self.extractResultBytes(from: data) {
                cont.resume(returning: raw)
            } else {
                cont.resume(throwing: ACPClientError.decoding("no result/error in response"))
            }
            return
        }
        guard let method = head.method else { return }
        switch method {
        case "session/update":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPSessionUpdateParams>.self, from: data),
               let p = env.params {
                stateLock.lock()
                _yieldedUpdateCount += 1
                stateLock.unlock()
                acknowledgeAfterDispatch = false
                updatesCont.yield(.init(
                    sessionId: p.sessionId,
                    update: p.update,
                    durableConsumptionAcknowledgement: onConsumed
                ))
            }
        case "session/request_permission":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPPermissionRequestParams>.self, from: data),
               let id = env.id, let p = env.params { permsCont.yield((id, p)) }
        case "cursor/ask_question":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPQuestionRequestParams>.self, from: data),
               let id = env.id, let p = env.params { questionsCont.yield(.init(id: id, params: p)) }
        case "elicitation/create":
            if let env = try? JSONDecoder().decode(
                JSONRPCEnvelope<ACPElicitationRequestParams>.self,
                from: data
            ), let id = env.id, let p = env.params {
                elicitationsCont.yield(.init(id: id, params: p))
            }
        case "elicitation/complete":
            if let env = try? JSONDecoder().decode(
                JSONRPCEnvelope<ACPElicitationCompleteParams>.self,
                from: data
            ), let p = env.params {
                elicitationCompletionsCont.yield(p)
            }
        case "fs/read_text_file":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPFsReadParams>.self, from: data),
               let id = env.id, let p = env.params { filesCont.yield(.read(id: id, params: p)) }
        case "fs/write_text_file":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPFsWriteParams>.self, from: data),
               let id = env.id, let p = env.params { filesCont.yield(.write(id: id, params: p)) }
        case "terminal/create":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPTerminalCreateParams>.self, from: data),
               let id = env.id, let p = env.params { terminalsCont.yield(.create(id: id, params: p)) }
        case "terminal/output":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPTerminalOutputParams>.self, from: data),
               let id = env.id, let p = env.params { terminalsCont.yield(.output(id: id, params: p)) }
        case "terminal/wait_for_exit":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPTerminalIdParams>.self, from: data),
               let id = env.id, let p = env.params { terminalsCont.yield(.waitForExit(id: id, params: p)) }
        case "terminal/kill":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPTerminalIdParams>.self, from: data),
               let id = env.id, let p = env.params { terminalsCont.yield(.kill(id: id, params: p)) }
        case "terminal/release":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPTerminalIdParams>.self, from: data),
               let id = env.id, let p = env.params { terminalsCont.yield(.release(id: id, params: p)) }
        default:
            break
        }
    }

    /// Extracts the raw JSON bytes of the `result` field from a full envelope.
    private static func extractResultBytes(from envelope: Data) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any],
              let result = obj["result"]
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
    }

    // MARK: - Outbound

    func send(_ request: ACPRequest) async throws -> ACPResponse {
        stateLock.lock()
        nextId += 1
        let id = JSONRPCID.number(nextId)
        stateLock.unlock()

        let body = try Self.encode(envelopeFor: request, id: id)
        let data: Data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            stateLock.lock()
            if didDrainPending {
                stateLock.unlock()
                cont.resume(throwing: ACPClientError.notRunning)
                return
            }
            pending[id] = cont
            stateLock.unlock()
            do {
                try transport.send(body)
            } catch {
                stateLock.lock()
                // If a concurrent drainPending (shutdown()/`.exited`) already
                // removed and resumed this entry, `removeValue` returns nil
                // here — in that case `cont` has already been resumed and we
                // must not resume it again (that would trap).
                let stillPending = pending.removeValue(forKey: id) != nil
                stateLock.unlock()
                if stillPending { cont.resume(throwing: error) }
            }
        }
        return ACPResponse(body: data)
    }

    private static func encode(envelopeFor request: ACPRequest, id: JSONRPCID) throws -> Data {
        var dict: [String: Any] = ["jsonrpc": "2.0", "id": id.asJSON, "method": request.method]
        if let p = request.params {
            let pData = try JSONEncoder().encode(AnyEncodableBox(p))
            dict["params"] = try JSONSerialization.jsonObject(with: pData)
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    /// JSON-RPC notification envelope — no `id` field, so no response
    /// is expected and the caller doesn't suspend on a continuation.
    func notify(_ request: ACPRequest) async throws {
        var dict: [String: Any] = ["jsonrpc": "2.0", "method": request.method]
        if let p = request.params {
            let pData = try JSONEncoder().encode(AnyEncodableBox(p))
            dict["params"] = try JSONSerialization.jsonObject(with: pData)
        }
        let body = try JSONSerialization.data(withJSONObject: dict)
        try transport.send(body)
    }

    func respondToPermission(id: JSONRPCID, response: ACPPermissionResponse) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let body = try JSONEncoder().encode(response)
                try self.respond(id: id, body: body)
            } catch {
                // Best-effort; caller side has no error path for this.
            }
        }
    }

    func respondToQuestion(id: JSONRPCID, response: ACPQuestionResponse) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let body = try JSONEncoder().encode(response)
                try self.respond(id: id, body: body)
            } catch {
                // Best-effort; caller side has no error path for this.
            }
        }
    }

    func respondToElicitation(
        id: JSONRPCID,
        result: Result<ACPElicitationResponse, JSONRPCError>
    ) {
        Task { [weak self] in
            guard let self else { return }
            switch result {
            case .success(let response):
                do {
                    try self.respond(id: id, body: JSONEncoder().encode(response))
                } catch {}
            case .failure(let error):
                self.respondFile(id: id, result: .failure(error))
            }
        }
    }

    func respondToFileRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>) {
        Task { [weak self] in
            guard let self else { return }
            self.respondFile(id: id, result: result)
        }
    }

    func respondToTerminalRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>) {
        Task { [weak self] in
            guard let self else { return }
            self.respondFile(id: id, result: result)
        }
    }

    func hasPendingOutboundRequest(id: JSONRPCID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pending[id] != nil
    }

    private func respond(id: JSONRPCID, body: Data) throws {
        var dict: [String: Any] = ["jsonrpc": "2.0", "id": id.asJSON]
        dict["result"] = try JSONSerialization.jsonObject(with: body)
        let payload = try JSONSerialization.data(withJSONObject: dict)
        try transport.send(payload)
    }

    private func respondFile(id: JSONRPCID, result: Result<Data, JSONRPCError>) {
        do {
            var dict: [String: Any] = ["jsonrpc": "2.0", "id": id.asJSON]
            switch result {
            case .success(let data):
                // Allow top-level `null` (the ACP spec for
                // `fs/write_text_file`'s success result) by passing
                // `.fragmentsAllowed`. Without it Foundation throws,
                // the surrounding catch swallows the error, and we
                // never send back any reply — leaving the agent
                // waiting on a successful write.
                dict["result"] = try JSONSerialization.jsonObject(
                    with: data, options: [.fragmentsAllowed]
                )
            case .failure(let err):
                dict["error"] = ["code": err.code, "message": err.message]
            }
            try transport.send(try JSONSerialization.data(withJSONObject: dict))
        } catch {}
    }

    /// Resumes and clears every pending outbound continuation exactly once.
    /// Safe to call from both `shutdown()` and the `.exited` handler; the
    /// second caller is a no-op (double-resuming a CheckedContinuation traps).
    /// This can also race a concurrent `send(_:)` whose `transport.send`
    /// subsequently throws for the same `id`; `send(_:)` guards against
    /// double-resuming in that case by only resuming if its own
    /// `pending.removeValue` still found the entry.
    private func drainPending(with error: Error) {
        stateLock.lock()
        if didDrainPending {
            stateLock.unlock()
            return
        }
        didDrainPending = true
        let snapshot = pending
        pending.removeAll()
        stateLock.unlock()
        for (_, cont) in snapshot { cont.resume(throwing: error) }
    }

    func shutdown() async {
        drainPending(with: ACPClientError.notRunning)
        transport.terminate()
        dispatchTask?.cancel()
    }
}

// MARK: - Private helpers

private struct JSONRPCErrorEnvelope: Decodable {
    let error: JSONRPCError?
}

private struct AnyEncodableBox: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

private extension JSONRPCID {
    var asJSON: Any {
        switch self {
        case .number(let n): return n
        case .string(let s): return s
        }
    }
}
