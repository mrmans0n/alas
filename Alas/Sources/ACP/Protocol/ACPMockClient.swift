import Foundation

final class ACPMockClient: ACPClient, @unchecked Sendable {
    var advertisesTerminalCapability = true
    let providesDurableOperationKeyDeduplication: Bool

    private(set) var sent: [ACPRequest] = []
    private var scripts: [String: (ACPRequest) throws -> Data] = [:]
    private var asyncScripts: [String: (ACPRequest) async throws -> Data] = [:]
    private var responseScripts: [String: (ACPRequest) async throws -> ACPResponse] = [:]
    private let updatesCont: AsyncStream<ACPSessionUpdateParams>.Continuation
    private let permsCont: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>.Continuation
    private let questionsCont: AsyncStream<ACPQuestionRequest>.Continuation
    private let elicitationsCont: AsyncStream<ACPElicitationRequest>.Continuation
    private let completionsCont: AsyncStream<ACPElicitationCompleteParams>.Continuation
    private let filesCont: AsyncStream<ACPFileRequest>.Continuation
    private let terminalsCont: AsyncStream<ACPTerminalRequest>.Continuation
    private let updateCountLock = NSLock()
    private var _yieldedUpdateCount = 0
    private(set) var shutdownCount = 0

    let incomingUpdates: AsyncStream<ACPSessionUpdateParams>
    var yieldedUpdateCount: Int {
        updateCountLock.lock()
        defer { updateCountLock.unlock() }
        return _yieldedUpdateCount
    }
    let permissionRequests: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>
    let questionRequests: AsyncStream<ACPQuestionRequest>
    let elicitationRequests: AsyncStream<ACPElicitationRequest>
    let elicitationCompletions: AsyncStream<ACPElicitationCompleteParams>
    let fileRequests: AsyncStream<ACPFileRequest>
    let terminalRequests: AsyncStream<ACPTerminalRequest>

    var terminalResponses: [JSONRPCID: Result<Data, JSONRPCError>] = [:]

    init(providesDurableOperationKeyDeduplication: Bool = false) {
        self.providesDurableOperationKeyDeduplication =
            providesDurableOperationKeyDeduplication
        var u: AsyncStream<ACPSessionUpdateParams>.Continuation!
        self.incomingUpdates = AsyncStream { u = $0 }
        self.updatesCont = u
        var p: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>.Continuation!
        self.permissionRequests = AsyncStream { p = $0 }
        self.permsCont = p
        var q: AsyncStream<ACPQuestionRequest>.Continuation!
        self.questionRequests = AsyncStream { q = $0 }
        self.questionsCont = q
        var e: AsyncStream<ACPElicitationRequest>.Continuation!
        self.elicitationRequests = AsyncStream { e = $0 }
        self.elicitationsCont = e
        var c: AsyncStream<ACPElicitationCompleteParams>.Continuation!
        self.elicitationCompletions = AsyncStream { c = $0 }
        self.completionsCont = c
        var f: AsyncStream<ACPFileRequest>.Continuation!
        self.fileRequests = AsyncStream { f = $0 }
        self.filesCont = f
        var t: AsyncStream<ACPTerminalRequest>.Continuation!
        self.terminalRequests = AsyncStream { t = $0 }
        self.terminalsCont = t
    }

    func send(_ request: ACPRequest) async throws -> ACPResponse {
        sent.append(request)
        if let script = responseScripts[request.method] {
            return try await script(request)
        }
        if let script = asyncScripts[request.method] {
            return ACPResponse(body: try await script(request))
        }
        guard let script = scripts[request.method] else {
            throw ACPClientError.noScript(method: request.method)
        }
        return ACPResponse(body: try script(request))
    }

    /// Mock notifications just record the call. Tests can inspect
    /// `sent` (which holds both requests and notifications in arrival
    /// order) without needing to script a reply.
    func notify(_ request: ACPRequest) async throws {
        sent.append(request)
    }

    func emit(_ update: ACPSessionUpdateParams) {
        updateCountLock.lock()
        _yieldedUpdateCount += 1
        updateCountLock.unlock()
        updatesCont.yield(update)
    }
    func emitPermission(id: JSONRPCID, params: ACPPermissionRequestParams) { permsCont.yield((id, params)) }
    func emitQuestion(id: JSONRPCID, params: ACPQuestionRequestParams) {
        questionsCont.yield(.init(id: id, params: params))
    }
    func emitElicitation(id: JSONRPCID, params: ACPElicitationRequestParams) {
        elicitationsCont.yield(.init(id: id, params: params))
    }
    func emitElicitationComplete(elicitationId: String) {
        completionsCont.yield(.init(elicitationId: elicitationId))
    }
    func emitFile(_ req: ACPFileRequest) { filesCont.yield(req) }
    func emitTerminal(_ req: ACPTerminalRequest) { terminalsCont.yield(req) }

    var permissionResponses: [JSONRPCID: ACPPermissionResponse] = [:]
    func respondToPermission(id: JSONRPCID, response: ACPPermissionResponse) {
        permissionResponses[id] = response
    }
    var questionResponses: [JSONRPCID: ACPQuestionResponse] = [:]
    func respondToQuestion(id: JSONRPCID, response: ACPQuestionResponse) {
        questionResponses[id] = response
    }
    var elicitationResponses: [JSONRPCID: Result<ACPElicitationResponse, JSONRPCError>] = [:]
    func respondToElicitation(
        id: JSONRPCID,
        result: Result<ACPElicitationResponse, JSONRPCError>
    ) {
        elicitationResponses[id] = result
    }
    var fileResponses: [JSONRPCID: Result<Data, JSONRPCError>] = [:]
    func respondToFileRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>) {
        fileResponses[id] = result
    }
    func respondToTerminalRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>) {
        terminalResponses[id] = result
    }

    func script(method: String, _ handler: @escaping (ACPRequest) throws -> Data) {
        scripts[method] = handler
    }

    func scriptResponse(method: String, _ handler: @escaping (ACPRequest) async throws -> ACPResponse) {
        responseScripts[method] = handler
    }

    func scriptAsync(method: String, _ handler: @escaping (ACPRequest) async throws -> Data) {
        asyncScripts[method] = handler
    }

    func shutdown() async {
        shutdownCount += 1
        updatesCont.finish()
        permsCont.finish()
        questionsCont.finish()
        elicitationsCont.finish()
        completionsCont.finish()
        filesCont.finish()
        terminalsCont.finish()
    }
}
