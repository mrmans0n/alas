import Foundation

actor LSPClient {
    enum State { case starting, initializing, ready, dead }
    enum TextDocumentSyncKind: Int { case none = 0, full = 1, incremental = 2 }
    private static let shutdownTimeoutNanoseconds: UInt64 = 2_000_000_000

    let language: String
    let rootURI: String
    private let transport: LSPTransporting
    private(set) var state: State = .starting
    private var nextId: Int = 0
    private var pending: [LSPID: CheckedContinuation<Data?, Error>] = [:]
    private var textDocumentSyncKind: TextDocumentSyncKind = .full
    private(set) var supportsDocumentFormatting: Bool = false
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
                    "publishDiagnostics": [:],
                    "formatting": ["dynamicRegistration": false]
                ]
            ] as [String: Any]
        ]
        let rawResult = try await sendRequest(method: "initialize", params: params)
        let caps = Self.decodeCapabilities(from: rawResult)
        textDocumentSyncKind = caps.syncKind
        supportsDocumentFormatting = caps.supportsFormatting
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

    func didSave(uri: String) throws {
        try sendNotification(method: "textDocument/didSave", params: [
            "textDocument": ["uri": uri]
        ])
    }

    /// Sends content sync using server capabilities. Incremental servers get
    /// the concrete AppKit edit ranges when available; otherwise we fall
    /// back to a single ranged full-document replacement.
    /// Caller is responsible for monotonic version numbers per URI.
    func didChange(uri: String, version: Int, text: String, previousText: String?, edits: [EditorTextEdit]? = nil) throws {
        guard textDocumentSyncKind != .none else { return }
        let changes: [[String: Any]]
        if textDocumentSyncKind == .incremental, let previousText {
            changes = Self.incrementalChanges(edits: edits, previousText: previousText, nextText: text) ?? [[
                "range": Self.fullRange(for: previousText).json,
                "rangeLength": (previousText as NSString).length,
                "text": text
            ]]
        } else {
            changes = [["text": text]]
        }
        try sendNotification(method: "textDocument/didChange", params: [
            "textDocument": ["uri": uri, "version": version],
            "contentChanges": changes
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

    func formatting(uri: String, options: LSPFormattingOptions) async throws -> [LSPTextEdit] {
        guard supportsDocumentFormatting else { return [] }
        let params = LSPDocumentFormattingParams(
            textDocument: LSPTextDocumentIdentifier(uri: uri),
            options: options
        )
        let raw = try await sendRequest(method: "textDocument/formatting", params: params)
        guard let raw, raw.count > 4 else { return [] }
        return (try? JSONDecoder().decode([LSPTextEdit].self, from: raw)) ?? []
    }

    func shutdown() async {
        // Send the polite handshake only if we ever reached `.ready`. For
        // clients that died during `initialize()` (or never started), the
        // request would be pointless or hang — but we still need to kill
        // the transport so the LSP server process doesn't leak.
        defer {
            transport.terminate()
            state = .dead
        }
        guard state == .ready else { return }
        do {
            _ = try await sendRequest(
                method: "shutdown",
                params: nil,
                timeoutNanoseconds: Self.shutdownTimeoutNanoseconds
            )
            try? sendNotification(method: "exit", params: nil)
        } catch LSPError.requestTimedOut {
            try? sendNotification(method: "exit", params: nil)
        } catch {
            return
        }
    }

    // MARK: - Plumbing

    private func sendRequest(method: String, params: Any?, timeoutNanoseconds: UInt64? = nil) async throws -> Data? {
        nextId += 1
        let id = LSPID.int(nextId)
        let req = LSPRequest(
            id: id,
            method: method,
            params: params.map { AnyEncodable($0) }
        )
        let data = try JSONEncoder().encode(req)
        let timeoutTask = timeoutNanoseconds.map { timeoutNanoseconds in
            Task {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    await self.failPendingRequest(id: id, error: LSPError.requestTimedOut)
                } catch {}
            }
        }
        return try await withTaskCancellationHandler {
            defer { timeoutTask?.cancel() }
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
                pending[id] = cont
                do {
                    try transport.send(data)
                } catch {
                    pending.removeValue(forKey: id)
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.failPendingRequest(id: id, error: CancellationError()) }
        }
    }

    private func failPendingRequest(id: LSPID, error: Error) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    private static func decodeCapabilities(from data: Data?) -> (syncKind: TextDocumentSyncKind, supportsFormatting: Bool) {
        guard let data else { return (.full, false) }
        struct InitializeResult: Decodable {
            let capabilities: ServerCapabilities
        }
        struct ServerCapabilities: Decodable {
            let textDocumentSync: TextDocumentSync?
            let documentFormattingProvider: DocumentFormattingProvider?
        }
        enum DocumentFormattingProvider: Decodable {
            case unsupported
            case supported

            var isSupported: Bool {
                switch self {
                case .unsupported: return false
                case .supported: return true
                }
            }

            init(from decoder: Decoder) throws {
                let single = try decoder.singleValueContainer()
                if let value = try? single.decode(Bool.self) {
                    self = value ? .supported : .unsupported
                    return
                }
                _ = try decoder.container(keyedBy: EmptyCodingKeys.self)
                self = .supported
            }

            enum EmptyCodingKeys: CodingKey {}
        }
        enum TextDocumentSync: Decodable {
            case kind(TextDocumentSyncKind)

            init(from decoder: Decoder) throws {
                let single = try decoder.singleValueContainer()
                if let raw = try? single.decode(Int.self) {
                    self = .kind(TextDocumentSyncKind(rawValue: raw) ?? .full)
                    return
                }
                let object = try decoder.container(keyedBy: CodingKeys.self)
                let raw = try object.decodeIfPresent(Int.self, forKey: .change) ?? TextDocumentSyncKind.full.rawValue
                self = .kind(TextDocumentSyncKind(rawValue: raw) ?? .full)
            }

            enum CodingKeys: String, CodingKey { case change }
        }

        guard let result = try? JSONDecoder().decode(InitializeResult.self, from: data) else {
            return (.full, false)
        }
        let syncKind: TextDocumentSyncKind = {
            guard let sync = result.capabilities.textDocumentSync else { return .full }
            switch sync {
            case .kind(let kind): return kind
            }
        }()
        let supportsFormatting = result.capabilities.documentFormattingProvider?.isSupported ?? false
        return (syncKind, supportsFormatting)
    }

    private static func fullRange(for text: String) -> LSPRange {
        let nsText = text as NSString
        let end = TextEditCoordinates.lspPosition(utf16Offset: nsText.length, in: text) ?? LSPPosition(line: 0, character: 0)
        return LSPRange(
            start: LSPPosition(line: 0, character: 0),
            end: end
        )
    }

    private static func incrementalChanges(edits: [EditorTextEdit]?, previousText: String, nextText: String) -> [[String: Any]]? {
        guard let edits, !edits.isEmpty else { return nil }
        var rollingText = previousText
        var changes: [[String: Any]] = []
        for edit in edits {
            guard let range = TextEditCoordinates.lspRange(for: edit.oldRange, in: rollingText),
                  let editedText = TextEditCoordinates.apply(edit, to: rollingText) else {
                return nil
            }
            changes.append([
                "range": range.json,
                "rangeLength": edit.oldLength,
                "text": edit.replacementText
            ])
            rollingText = editedText
        }
        return rollingText == nextText ? changes : nil
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
    case requestTimedOut
}
