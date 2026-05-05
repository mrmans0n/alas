import Foundation

actor LSPClient {
    enum State { case starting, initializing, ready, dead }

    let language: String
    let rootURI: String
    private let transport: LSPTransporting
    private(set) var state: State = .starting
    private var nextId: Int = 0
    private var pending: [LSPID: CheckedContinuation<Data?, Error>] = [:]
    private var diagnostics: AsyncStream<LSPPublishDiagnosticsParams>.Continuation?
    let diagnosticsStream: AsyncStream<LSPPublishDiagnosticsParams>

    var isReady: Bool { state == .ready }

    init(transport: LSPTransporting, language: String, rootURI: String) {
        self.transport = transport
        self.language = language
        self.rootURI = rootURI
        var diagCont: AsyncStream<LSPPublishDiagnosticsParams>.Continuation!
        self.diagnosticsStream = AsyncStream { diagCont = $0 }
        self.diagnostics = diagCont
        Task { await self.consume() }
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
        guard state == .ready else { return }
        _ = try? await sendRequest(method: "shutdown", params: nil)
        try? sendNotification(method: "exit", params: nil)
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
                diagnostics?.finish()
            }
        }
    }

    private func handle(frame: Data) {
        // Try response first
        if let resp = try? JSONDecoder().decode(LSPResponse.self, from: frame) {
            if let cont = pending.removeValue(forKey: resp.id) {
                if let err = resp.error {
                    cont.resume(throwing: LSPError.responseError(err))
                } else {
                    cont.resume(returning: resp.result)
                }
                return
            }
        }
        // Otherwise, server-initiated notification
        struct Note: Decodable { let method: String; let params: JSONValue? }
        if let note = try? JSONDecoder().decode(Note.self, from: frame) {
            if note.method == "textDocument/publishDiagnostics",
               let raw = note.params,
               let data = try? JSONEncoder().encode(raw),
               let parsed = try? JSONDecoder().decode(LSPPublishDiagnosticsParams.self, from: data) {
                diagnostics?.yield(parsed)
            }
        }
    }
}

enum LSPError: Error {
    case transportClosed
    case responseError(LSPResponseError)
}
