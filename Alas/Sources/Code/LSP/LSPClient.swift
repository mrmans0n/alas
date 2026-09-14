import Foundation

actor LSPClient {
    enum State { case starting, initializing, ready, dead }
    enum TextDocumentSyncKind: Int { case none = 0, full = 1, incremental = 2 }

    private struct InitializeParams: Encodable, Sendable {
        let processId: Int
        let rootUri: String
    }
    private static let shutdownTimeoutNanoseconds: UInt64 = 2_000_000_000

    let language: String
    let rootURI: String
    private let transport: LSPTransporting
    private(set) var state: State = .starting
    private var nextId: Int = 0
    private var pending: [LSPID: CheckedContinuation<Data?, Error>] = [:]
    private var serverRequests = LSPServerRequests()
    private struct InboundRequest {
        let generation: UUID
        let method: String
        let task: Task<Void, Never>
    }
    private var inbound: [LSPID: InboundRequest] = [:]
    private var commandSession: UUID?
    private var commandEditFailure: String?
    private(set) var supportsCodeActionResolve = false
    private var textDocumentSyncKind: TextDocumentSyncKind = .full
    private(set) var capabilities: LSPCapabilities = .empty
    private(set) var supportsDocumentFormatting: Bool = false
    private(set) var supportsPrepareRename = false
    private(set) var supportsPullDiagnostics: Bool = false
    private(set) var completionTriggerCharacters: [String] = []
    private(set) var supportsCompletionResolve = false
    private(set) var signatureHelpTriggerCharacters: [String] = []
    private(set) var signatureHelpRetriggerCharacters: [String] = []
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
        let params = InitializeParams(
            processId: Int(ProcessInfo.processInfo.processIdentifier),
            rootUri: rootURI
        )
        let rawResult = try await sendRequest(method: "initialize", params: params)
        let caps = Self.decodeCapabilities(from: rawResult)
        guard caps.positionEncoding == nil || caps.positionEncoding?.lowercased() == "utf-16" else {
            throw LSPError.unsupportedPositionEncoding(caps.positionEncoding ?? "unknown")
        }
        textDocumentSyncKind = caps.syncKind
        capabilities = LSPCapabilities.fromInitializeResult(rawResult)
        if let rawResult, let value = try? LSPJSONValue.decode(from: rawResult) {
            supportsCodeActionResolve = value["capabilities"]?["codeActionProvider"]?["resolveProvider"] == .bool(true)
        }
        supportsDocumentFormatting = capabilities.supports(.formatDocument)
        if let rawResult,
           let result = try? JSONSerialization.jsonObject(with: rawResult) as? [String: Any],
           let providers = result["capabilities"] as? [String: Any],
           let rename = providers["renameProvider"] as? [String: Any] {
            supportsPrepareRename = rename["prepareProvider"] as? Bool == true
        }
        supportsPullDiagnostics = caps.supportsPullDiagnostics
        completionTriggerCharacters = caps.completionTriggerCharacters
        if let rawResult,
           let result = try? LSPJSONValue.decode(from: rawResult) {
            supportsCompletionResolve = result["capabilities"]?["completionProvider"]?["resolveProvider"] == .bool(true)
        }
        signatureHelpTriggerCharacters = caps.signatureHelpTriggerCharacters
        signatureHelpRetriggerCharacters = caps.signatureHelpRetriggerCharacters
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
        try await locations(method: "textDocument/definition", uri: uri, position: position)
    }

    func typeDefinition(uri: String, position: LSPPosition) async throws -> [LSPLocation] {
        try await locations(method: "textDocument/typeDefinition", uri: uri, position: position)
    }

    func implementation(uri: String, position: LSPPosition) async throws -> [LSPLocation] {
        try await locations(method: "textDocument/implementation", uri: uri, position: position)
    }

    func references(uri: String, position: LSPPosition, includeDeclaration: Bool) async throws -> [LSPLocation] {
        let raw = try await sendRequest(method: "textDocument/references", params: [
            "textDocument": ["uri": uri],
            "position": ["line": position.line, "character": position.character],
            "context": ["includeDeclaration": includeDeclaration]
        ])
        return Self.decodeLocations(raw)
    }

    private func locations(method: String, uri: String, position: LSPPosition) async throws -> [LSPLocation] {
        let raw = try await sendRequest(method: method, params: [
            "textDocument": ["uri": uri],
            "position": ["line": position.line, "character": position.character]
        ])
        return Self.decodeLocations(raw)
    }

    private static func decodeLocations(_ raw: Data?) -> [LSPLocation] {
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

    func completion(uri: String, position: LSPPosition, context: LSPCompletionContext?) async throws -> LSPCompletionResult {
        let params = LSPCompletionParams(
            textDocument: LSPTextDocumentIdentifier(uri: uri),
            position: position,
            context: context
        )
        let raw = try await sendRequest(method: "textDocument/completion", params: params)
        guard let raw, raw.count > 4 else {
            return LSPCompletionResult(isIncomplete: false, items: [])
        }
        return try LSPCompletionResult(wireValue: LSPJSONValue.decode(from: raw))
    }

    func resolveCompletion(_ item: LSPCompletionItem) async throws -> LSPCompletionItem {
        guard let raw = try await sendRequest(method: "completionItem/resolve", params: item.wireValue, timeoutNanoseconds: 2_000_000_000) else { throw LSPError.invalidPayload }
        return try item.mergingResolved(LSPCompletionItem(wireValue: LSPJSONValue.decode(from: raw)))
    }

    func signatureHelp(uri: String, position: LSPPosition, context: LSPSignatureHelpContext?) async throws -> LSPSignatureHelp? {
        let params = LSPSignatureHelpParams(
            textDocument: LSPTextDocumentIdentifier(uri: uri),
            position: position,
            context: context
        )
        let raw = try await sendRequest(method: "textDocument/signatureHelp", params: params)
        guard let raw, raw != Data("null".utf8) else { return nil }
        return try JSONDecoder().decode(LSPSignatureHelp.self, from: raw)
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

    func prepareRename(uri: String, position: LSPPosition) async throws -> LSPPrepareRenameResult? {
        let raw = try await sendRequest(method: "textDocument/prepareRename", params: [
            "textDocument": ["uri": uri], "position": ["line": position.line, "character": position.character]
        ])
        guard let raw, raw != Data("null".utf8) else { return nil }
        return try JSONDecoder().decode(LSPPrepareRenameResult.self, from: raw)
    }

    func rename(uri: String, position: LSPPosition, newName: String) async throws -> LSPWorkspaceEdit? {
        let raw = try await sendRequest(method: "textDocument/rename", params: [
            "textDocument": ["uri": uri], "position": ["line": position.line, "character": position.character],
            "newName": newName
        ])
        guard let raw, raw != Data("null".utf8) else { return nil }
        return try JSONDecoder().decode(LSPWorkspaceEdit.self, from: raw)
    }

    func codeActions(uri: String, range: LSPRange, diagnostics: [LSPDiagnostic], only: [String]? = nil) async throws -> [LSPCodeAction] {
        var context: [String: LSPJSONValue] = ["diagnostics": .array(try diagnostics.map {
            if let original = $0.wireValue { return original }
            return try LSPJSONValue.decode(from: JSONEncoder().encode($0))
        }), "triggerKind": .number("1")]
        if let only { context["only"] = .array(only.map(LSPJSONValue.string)) }
        let params = LSPJSONValue.object([
            "textDocument": .object(["uri": .string(uri)]),
            "range": try LSPJSONValue.decode(from: JSONEncoder().encode(range)), "context": .object(context)
        ])
        return try await LSPCodeAction.decodeList(sendRequest(method: "textDocument/codeAction", params: params))
    }

    func resolveCodeAction(_ action: LSPCodeAction) async throws -> LSPCodeAction {
        guard !action.isCommand else { return action }
        guard let raw = try await sendRequest(method: "codeAction/resolve", params: action.wireValue) else { throw LSPError.invalidPayload }
        return try LSPCodeAction(wireValue: LSPJSONValue.decode(from: raw))
    }

    func executeCommand(_ command: LSPCommand) async throws {
        var params: [String: LSPJSONValue] = ["command": .string(command.command)]
        if let arguments = command.arguments { params["arguments"] = .array(arguments) }
        _ = try await sendRequest(method: "workspace/executeCommand", params: LSPJSONValue.object(params), timeoutNanoseconds: 60_000_000_000)
    }

    func setConfigurationHandler(_ handler: @escaping LSPServerRequests.Configuration) {
        serverRequests.configuration = handler
    }

    func beginCommandSession(applyEdit: @escaping LSPServerRequests.EditHandler) throws -> UUID {
        guard commandSession == nil else { throw LSPError.commandAlreadyRunning }
        let id = UUID()
        commandSession = id
        commandEditFailure = nil
        serverRequests.applyEdit = applyEdit
        return id
    }

    func endCommandSession(_ id: UUID) {
        guard commandSession == id else { return }
        commandSession = nil
        serverRequests.applyEdit = nil
        cancelInboundRequests()
    }

    func finishCommandSession(_ id: UUID) async throws {
        guard commandSession == id else { return }
        serverRequests.applyEdit = nil
        let edits = inbound.values.filter { $0.method == "workspace/applyEdit" }.map(\.task)
        await withTaskCancellationHandler {
            for task in edits { await task.value }
        } onCancel: {
            Task { await self.endCommandSession(id) }
        }
        let failure = commandEditFailure
        endCommandSession(id)
        if let failure { throw LSPError.responseError(.init(code: -32800, message: failure)) }
    }

    func rangeFormatting(uri: String, range: LSPRange, options: LSPFormattingOptions) async throws -> [LSPTextEdit] {
        struct Params: Encodable {
            let textDocument: LSPTextDocumentIdentifier
            let range: LSPRange
            let options: LSPFormattingOptions
        }
        let raw = try await sendRequest(method: "textDocument/rangeFormatting", params: Params(
            textDocument: .init(uri: uri), range: range, options: options
        ))
        guard let raw, raw != Data("null".utf8) else { return [] }
        return try JSONDecoder().decode([LSPTextEdit].self, from: raw)
    }

    /// Sends `textDocument/diagnostic` (LSP 3.17 pull diagnostics).
    /// Returns diagnostics on a full report, `nil` on unchanged (caller
    /// reuses cached diagnostics), or throws on error.
    func requestDiagnostics(uri: String, previousResultId: String?) async throws -> [LSPDiagnostic]? {
        guard supportsPullDiagnostics else { return nil }
        var params: [String: Any] = [
            "textDocument": ["uri": uri]
        ]
        if let previousResultId {
            params["previousResultId"] = previousResultId
        }
        let raw = try await sendRequest(method: "textDocument/diagnostic", params: params)
        guard let raw, raw.count > 4 else { return nil }
        let value = try LSPJSONValue.decode(from: raw)
        if value["kind"] == .string("unchanged") { return nil }
        if case .array(let items) = value["items"] { return try LSPDiagnostic.decodeWire(items) }
        if case .array(let items) = value { return try LSPDiagnostic.decodeWire(items) }
        return nil
    }

    func shutdown() async {
        cancelInboundRequests()
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
        let data: Data
        if method == "initialize", let initializeParams = params as? InitializeParams {
            data = try Self.encodeInitializeRequest(id: id, params: initializeParams)
        } else if let params = params as? LSPJSONValue {
            data = try LSPJSONValue.object([
                "jsonrpc": .string("2.0"), "id": .number(String(nextId)), "method": .string(method), "params": params
            ]).encodedData()
        } else {
            data = try Self.outgoingJSONEncoder().encode(req)
        }
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
                guard !Task.isCancelled else { cont.resume(throwing: CancellationError())
                return }
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
            try? sendNotification(method: "$/cancelRequest", params: ["id": AnyEncodable(id)])
            cont.resume(throwing: error)
        }
    }

    private static func decodeCapabilities(from data: Data?) -> (
        syncKind: TextDocumentSyncKind,
        supportsFormatting: Bool,
        supportsPullDiagnostics: Bool,
        completionTriggerCharacters: [String],
        signatureHelpTriggerCharacters: [String],
        signatureHelpRetriggerCharacters: [String],
        positionEncoding: String?
    ) {
        guard let data else { return (.full, false, false, [], [], [], nil) }
        struct InitializeResult: Decodable {
            let capabilities: ServerCapabilities
        }
        struct ServerCapabilities: Decodable {
            let textDocumentSync: TextDocumentSync?
            let documentFormattingProvider: DocumentFormattingProvider?
            let diagnosticProvider: DiagnosticProvider?
            let completionProvider: CompletionProvider?
            let signatureHelpProvider: SignatureHelpProvider?
            let positionEncoding: String?
        }
        struct DiagnosticProvider: Decodable {
            let identifier: String?
            let interFileDependencies: Bool?
            let workspaceDiagnostics: Bool?
        }
        struct CompletionProvider: Decodable {
            let triggerCharacters: [String]?
        }
        struct SignatureHelpProvider: Decodable {
            let triggerCharacters: [String]?
            let retriggerCharacters: [String]?
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
            return (.full, false, false, [], [], [], nil)
        }
        let syncKind: TextDocumentSyncKind = {
            guard let sync = result.capabilities.textDocumentSync else { return .full }
            switch sync {
            case .kind(let kind): return kind
            }
        }()
        let supportsFormatting = result.capabilities.documentFormattingProvider?.isSupported ?? false
        let supportsPullDiagnostics = result.capabilities.diagnosticProvider != nil
        let triggerCharacters = result.capabilities.completionProvider?.triggerCharacters ?? []
        let signatureTriggers = result.capabilities.signatureHelpProvider?.triggerCharacters ?? []
        let signatureRetriggers = result.capabilities.signatureHelpProvider?.retriggerCharacters ?? []
        return (syncKind, supportsFormatting, supportsPullDiagnostics, triggerCharacters, signatureTriggers, signatureRetriggers, result.capabilities.positionEncoding)
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
        let data = try Self.outgoingJSONEncoder().encode(note)
        try transport.send(data)
    }

    private nonisolated static func outgoingJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return encoder
    }

    private nonisolated static func encodeInitializeRequest(id: LSPID, params: InitializeParams) throws -> Data {
        let idString: String
        switch id {
        case .int(let value):
            idString = String(value)
        case .string(let value):
            idString = try jsonString(value)
        }
        let rootUri = try jsonString(params.rootUri)
        let json = """
        {"jsonrpc":"2.0","id":\(idString),"method":"initialize","params":{"processId":\(params.processId),"rootUri":\(rootUri),"capabilities":{"general":{"positionEncodings":["utf-16"]},"textDocument":{"hover":{"contentFormat":["markdown","plaintext"]},"definition":{},"documentSymbol":{"hierarchicalDocumentSymbolSupport":true},"publishDiagnostics":{},"formatting":{"dynamicRegistration":false},"rangeFormatting":{"dynamicRegistration":false},"rename":{"dynamicRegistration":false,"prepareSupport":true,"prepareSupportDefaultBehavior":1},"completion":{"dynamicRegistration":false,"completionItem":{"documentationFormat":["markdown","plaintext"],"snippetSupport":true,"insertReplaceSupport":true,"insertTextModeSupport":{"valueSet":[1]},"resolveSupport":{"properties":["documentation","detail","additionalTextEdits","command"]}},"contextSupport":true,"completionList":{"itemDefaults":["commitCharacters","editRange","insertTextFormat","insertTextMode","data"]}},"signatureHelp":{"dynamicRegistration":false,"contextSupport":true,"signatureInformation":{"documentationFormat":["markdown","plaintext"],"activeParameterSupport":true,"parameterInformation":{"labelOffsetSupport":true}}}}}}}
        """
        let workspace = #""workspace":{"applyEdit":true,"configuration":true,"workspaceEdit":{"documentChanges":true,"resourceOperations":["create","rename","delete"],"changeAnnotationSupport":{"groupsOnLabel":false}},"executeCommand":{"dynamicRegistration":false}},"#
        let actions = #""codeAction":{"dynamicRegistration":false,"codeActionLiteralSupport":{"codeActionKind":{"valueSet":["quickfix","refactor","source","source.organizeImports"]}},"isPreferredSupport":true,"disabledSupport":true,"dataSupport":true,"resolveSupport":{"properties":["edit","command"]}},"#
        return Data(json.replacingOccurrences(of: #""textDocument":{"#,
                                              with: workspace + #""textDocument":{"# + actions).utf8)
    }

    private nonisolated static func jsonString(_ value: String) throws -> String {
        let data = try outgoingJSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func consume() async {
        defer {
            cancelInboundRequests()
            state = .dead
            for continuation in pending.values { continuation.resume(throwing: LSPError.transportClosed) }
            pending.removeAll()
            for continuation in diagnosticsSubscribers.values { continuation.finish() }
            diagnosticsSubscribers.removeAll()
        }
        for await event in transport.incoming {
            switch event {
            case .frame(let data):
                handle(frame: data)
            case .stderr:
                continue
            case .exited:
                cancelInboundRequests()
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
            guard let id = env.id, let value = try? LSPJSONValue.decode(from: frame) else { return }
            if let cont = pending.removeValue(forKey: id) {
                if let rawError = try? value["error"]?.encodedData(),
                   let err = try? JSONDecoder().decode(LSPResponseError.self, from: rawError) {
                    cont.resume(throwing: LSPError.responseError(err))
                } else {
                    // Keep opaque numbers intact; the general response decoder normalizes them.
                    cont.resume(returning: try? value["result"]?.encodedData())
                }
            }
            return
        }

        guard let method = env.method else { return }

        if env.id == nil {
            // Server-initiated notification.
            guard let value = try? LSPJSONValue.decode(from: frame) else { return }
            if method == "textDocument/publishDiagnostics", let params = value["params"],
               let uri = params["uri"]?.stringValue, case .array(let values) = params["diagnostics"],
               let diagnostics = try? LSPDiagnostic.decodeWire(values) {
                let batch = LSPPublishDiagnosticsParams(uri: uri, diagnostics: diagnostics)
                for (_, cont) in diagnosticsSubscribers { cont.yield(batch) }
            }
            if method == "$/cancelRequest", let value = try? LSPJSONValue.decode(from: frame),
               let rawID = try? value["params"]?["id"]?.encodedData(), let id = try? JSONDecoder().decode(LSPID.self, from: rawID) {
                cancelInboundRequest(id)
            }
            return
        }

        guard let id = env.id else { return }
        guard inbound[id] == nil else { return }
        let params = (try? LSPJSONValue.decode(from: frame))?["params"] ?? .null
        let handler = serverRequests
        let generation = UUID()
        let task = Task {
            let reply = await handler.handle(method: method, params: params)
            guard self.inbound[id]?.generation == generation else { return }
            self.completeInbound(id: id, reply: reply)
        }
        inbound[id] = InboundRequest(generation: generation, method: method, task: task)
    }

    private func cancelInboundRequests() {
        for id in Array(inbound.keys) { cancelInboundRequest(id) }
    }

    private func cancelInboundRequest(_ id: LSPID) {
        guard let request = inbound[id] else { return }
        request.task.cancel()
        completeInbound(id: id, reply: request.method == "workspace/applyEdit"
            ? .init(result: LSPApplyEditResult.cancelled.wireValue)
            : .init(error: .init(code: -32800, message: "Request cancelled")))
    }

    private func completeInbound(id: LSPID, reply: LSPServerRequests.Reply) {
        guard let request = inbound.removeValue(forKey: id) else { return }
        if request.method == "workspace/applyEdit", commandSession != nil,
           reply.result?["applied"] == .bool(false) {
            commandEditFailure = reply.result?["failureReason"]?.stringValue ?? "Workspace edit was not applied."
        }
        if let error = reply.error {
            try? sendErrorResponse(id: id, code: error.code, message: error.message)
        } else {
            let idValue: LSPJSONValue
            switch id { case .int(let value): idValue = .number(String(value))
            case .string(let value): idValue = .string(value) }
            if let data = try? LSPJSONValue.object(["jsonrpc": .string("2.0"), "id": idValue, "result": reply.result ?? .null]).encodedData() {
                try? transport.send(data)
            }
        }
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
    case invalidPayload
    case commandAlreadyRunning
    case transportClosed
    case responseError(LSPResponseError)
    case requestTimedOut
    case unsupportedPositionEncoding(String)
}
