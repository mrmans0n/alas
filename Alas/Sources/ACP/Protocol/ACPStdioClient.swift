import Foundation

final class ACPStdioClient: ACPClient, @unchecked Sendable {
    private let transport: JSONRPCStdioTransporting
    private let updatesCont: AsyncStream<ACPSessionUpdateParams>.Continuation
    private let permsCont: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>.Continuation
    private let filesCont: AsyncStream<ACPFileRequest>.Continuation
    private let stderrCont: AsyncStream<Data>.Continuation

    let incomingUpdates: AsyncStream<ACPSessionUpdateParams>
    let permissionRequests: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>
    let fileRequests: AsyncStream<ACPFileRequest>
    let incomingStderr: AsyncStream<Data>

    private let stateLock = NSLock()
    private var nextId: Int = 0
    private var pending: [JSONRPCID: CheckedContinuation<Data, Error>] = [:]
    private var dispatchTask: Task<Void, Never>?

    init(executable: URL, arguments: [String], environment: [String: String]?) throws {
        self.transport = JSONRPCStdioTransport(
            executable: executable,
            arguments: arguments,
            environment: environment,
            framing: .newline,
            // ACPSessionManager.mergeEnv has already produced the full env
            // with Claude-specific markers scrubbed. Tell the transport not
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

        var fC: AsyncStream<ACPFileRequest>.Continuation!
        self.fileRequests = AsyncStream { fC = $0 }
        self.filesCont = fC

        var eC: AsyncStream<Data>.Continuation!
        self.incomingStderr = AsyncStream { eC = $0 }
        self.stderrCont = eC
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
        case .frame(let data):
            handleFrame(data)
        case .stderr(let data):
            stderrCont.yield(data)
        case .exited:
            stateLock.lock()
            let snapshot = pending
            pending.removeAll()
            stateLock.unlock()
            for (_, cont) in snapshot { cont.resume(throwing: ACPClientError.notRunning) }
            updatesCont.finish()
            permsCont.finish()
            filesCont.finish()
            stderrCont.finish()
        }
    }

    private struct AnyEnvelopeHead: Decodable {
        let id: JSONRPCID?
        let method: String?
    }

    private func handleFrame(_ data: Data) {
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
               let p = env.params { updatesCont.yield(p) }
        case "session/request_permission":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPPermissionRequestParams>.self, from: data),
               let id = env.id, let p = env.params { permsCont.yield((id, p)) }
        case "fs/read_text_file":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPFsReadParams>.self, from: data),
               let id = env.id, let p = env.params { filesCont.yield(.read(id: id, params: p)) }
        case "fs/write_text_file":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPFsWriteParams>.self, from: data),
               let id = env.id, let p = env.params { filesCont.yield(.write(id: id, params: p)) }
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
            pending[id] = cont
            stateLock.unlock()
            do {
                try transport.send(body)
            } catch {
                stateLock.lock()
                pending.removeValue(forKey: id)
                stateLock.unlock()
                cont.resume(throwing: error)
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

    func respondToFileRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>) {
        Task { [weak self] in
            guard let self else { return }
            self.respondFile(id: id, result: result)
        }
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
                dict["result"] = try JSONSerialization.jsonObject(with: data)
            case .failure(let err):
                dict["error"] = ["code": err.code, "message": err.message]
            }
            try transport.send(try JSONSerialization.data(withJSONObject: dict))
        } catch {}
    }

    func shutdown() async {
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
