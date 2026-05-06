import Foundation

actor LSPClient {
    enum State { case starting, initializing, ready, dead }

    let language: String
    let rootURI: String
    private let transport: LSPTransporting
    private(set) var state: State = .starting
    private var nextId: Int = 0
    private var pending: [LSPID: CheckedContinuation<Data?, Error>] = [:]
    // `AsyncStream` is single-consumer — values are delivered to whichever
    // iterator races to read first, not broadcast. Multiple coordinators
    // sharing one client (two tabs in the same worktree/language) used to
    // start their own `for await diagnosticsStream` loops and steal each
    // other's batches, leaving one tab without squiggles. We now keep a
    // dictionary of active subscribers and yield each batch to all of them.
    private var diagnosticsSubscribers: [Int: AsyncStream<LSPPublishDiagnosticsParams>.Continuation] = [:]
    private var nextDiagnosticsSubscriberId: Int = 0

    var isReady: Bool { state == .ready }

    init(transport: LSPTransporting, language: String, rootURI: String) {
        self.transport = transport
        self.language = language
        self.rootURI = rootURI
        Task { await self.consume() }
    }

    /// Returns a fresh `AsyncStream` that receives every diagnostics batch
    /// the server publishes. Each subscriber gets its own iterator;
    /// terminate by breaking out of the `for await` (or cancelling the
    /// enclosing Task) and the subscription is reaped automatically.
    func subscribeDiagnostics() -> AsyncStream<LSPPublishDiagnosticsParams> {
        let id = nextDiagnosticsSubscriberId
        nextDiagnosticsSubscriberId += 1
        return AsyncStream { cont in
            self.diagnosticsSubscribers[id] = cont
            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeDiagnosticsSubscriber(id: id) }
            }
        }
    }

    private func removeDiagnosticsSubscriber(id: Int) {
        diagnosticsSubscribers.removeValue(forKey: id)
    }

    func initialize() async throws {
        try transport.start()
        state = .initializing
        let params: [String: Any] = [
            "processId": Int(ProcessInfo.processInfo.processIdentifier),
            "rootUri": rootURI,
            "capabilities": [
                "textDocument": [
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "definition": [:],
                    "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
                    "publishDiagnostics": [:]
                ]
            ] as [String: Any]
        ]
        _ = try await sendRequest(method: "initialize", params: params)
        try sendNotification(method: "initialized", params: [String: Any]())
        state = .ready
    }

    func didOpen(uri: String, languageId: String, version: Int, text: String) throws {
        try sendNotification(method: "textDocument/didOpen", params: [
            "textDocument": [
                "uri": uri, "languageId": languageId, "version": version, "text": text
            ]
        ])
    }

    func didClose(uri: String) throws {
        try sendNotification(method: "textDocument/didClose", params: [
            "textDocument": ["uri": uri]
        ])
    }

    /// Full-document content sync. We don't keep a local edit history, so
    /// every change is sent as a single replacement of the whole document.
    /// Caller is responsible for monotonic version numbers per URI.
    func didChange(uri: String, version: Int, text: String) throws {
        try sendNotification(method: "textDocument/didChange", params: [
            "textDocument": ["uri": uri, "version": version],
            "contentChanges": [["text": text]]
        ])
    }

    func hover(uri: String, position: LSPPosition) async throws -> LSPHoverResult? {
        let raw = try await sendRequest(method: "textDocument/hover", params: [
            "textDocument": ["uri": uri],
            "position": ["line": position.line, "character": position.character]
        ])
        guard let raw, raw.count > 4 else { return nil }
        return try? JSONDecoder().decode(LSPHoverResult.self, from: raw)
    }

    func definition(uri: String, position: LSPPosition) async throws -> [LSPLocation] {
        let raw = try await sendRequest(method: "textDocument/definition", params: [
            "textDocument": ["uri": uri],
            "position": ["line": position.line, "character": position.character]
        ])
        guard let raw, raw.count > 4 else { return [] }
        if let single = try? JSONDecoder().decode(LSPLocation.self, from: raw) { return [single] }
        if let many = try? JSONDecoder().decode([LSPLocation].self, from: raw) { return many }
        if let links = try? JSONDecoder().decode([LSPLocationLink].self, from: raw) {
            return links.map { LSPLocation(uri: $0.targetUri, range: $0.targetSelectionRange) }
        }
        return []
    }

    func documentSymbol(uri: String) async throws -> [LSPDocumentSymbol] {
        let raw = try await sendRequest(method: "textDocument/documentSymbol", params: [
            "textDocument": ["uri": uri]
        ])
        guard let raw, raw.count > 4 else { return [] }
        return (try? JSONDecoder().decode([LSPDocumentSymbol].self, from: raw)) ?? []
    }

    func shutdown() async {
        // Send the polite handshake only if we ever reached `.ready`. For
        // clients that died during `initialize()` (or never started), the
        // request would be pointless or hang — but we still need to kill
        // the transport so the LSP server process doesn't leak.
        if state == .ready {
            _ = try? await sendRequest(method: "shutdown", params: nil)
            try? sendNotification(method: "exit", params: nil)
        }
        transport.terminate()
        state = .dead
    }

    // MARK: - Plumbing

    private func sendRequest(method: String, params: Any?) async throws -> Data? {
        nextId += 1
        let id = LSPID.int(nextId)
        let req = LSPRequest(
            id: id,
            method: method,
            params: params.map { AnyEncodable($0) }
        )
        let data = try JSONEncoder().encode(req)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            pending[id] = cont
            do {
                try transport.send(data)
            } catch {
                pending.removeValue(forKey: id)
                cont.resume(throwing: error)
            }
        }
    }

    private nonisolated func sendNotification(method: String, params: Any?) throws {
        let note = LSPNotification(method: method, params: params.map { AnyEncodable($0) })
        let data = try JSONEncoder().encode(note)
        try transport.send(data)
    }

    private func consume() async {
        for await event in transport.incoming {
            switch event {
            case .frame(let data):
                handle(frame: data)
            case .stderr:
                continue
            case .exited:
                state = .dead
                for (_, cont) in pending {
                    cont.resume(throwing: LSPError.transportClosed)
                }
                pending.removeAll()
                for (_, cont) in diagnosticsSubscribers { cont.finish() }
                diagnosticsSubscribers.removeAll()
            }
        }
    }

    private func handle(frame: Data) {
        // Classify by `(id, method)` rather than blindly trying `LSPResponse`
        // first — server-initiated requests carry both `id` *and* `method`,
        // and `LSPResponse`'s `result`/`error` are optional, so a naive
        // `decode(LSPResponse...)` would happily classify them as responses
        // and (worse) resume any pending continuation whose id collides with
        // the server's request id by nil.
        struct Envelope: Decodable {
            let id: LSPID?
            let method: String?
        }
        let env = (try? JSONDecoder().decode(Envelope.self, from: frame)) ?? Envelope(id: nil, method: nil)

        if env.method == nil, env.id != nil {
            // Pure response.
            guard let resp = try? JSONDecoder().decode(LSPResponse.self, from: frame) else { return }
            if let cont = pending.removeValue(forKey: resp.id) {
                if let err = resp.error {
                    cont.resume(throwing: LSPError.responseError(err))
                } else {
                    cont.resume(returning: resp.result)
                }
            }
            return
        }

        guard let method = env.method else { return }

        if env.id == nil {
            // Server-initiated notification.
            struct Note: Decodable { let params: JSONValue? }
            guard let note = try? JSONDecoder().decode(Note.self, from: frame) else { return }
            if method == "textDocument/publishDiagnostics",
               let raw = note.params,
               let data = try? JSONEncoder().encode(raw),
               let parsed = try? JSONDecoder().decode(LSPPublishDiagnosticsParams.self, from: data) {
                for (_, cont) in diagnosticsSubscribers { cont.yield(parsed) }
            }
            return
        }

        // Server-initiated request. We don't implement any of these yet
        // (`workspace/configuration`, `client/registerCapability`, …) but we
        // owe the server a response per JSON-RPC, otherwise it can stall
        // waiting on us. Reply with method-not-found (-32601).
        guard let id = env.id else { return }
        try? sendErrorResponse(id: id, code: -32601, message: "method not implemented: \(method)")
    }

    private nonisolated func sendErrorResponse(id: LSPID, code: Int, message: String) throws {
        let idValue: Any
        switch id {
        case .int(let i):    idValue = i
        case .string(let s): idValue = s
        }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": idValue,
            "error": ["code": code, "message": message] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try transport.send(data)
    }
}

enum LSPError: Error {
    case transportClosed
    case responseError(LSPResponseError)
}
