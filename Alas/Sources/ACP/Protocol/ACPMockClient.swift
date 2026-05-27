import Foundation

final class ACPMockClient: ACPClient, @unchecked Sendable {
    private(set) var sent: [ACPRequest] = []
    private var scripts: [String: (ACPRequest) throws -> Data] = [:]
    private let updatesCont: AsyncStream<ACPSessionUpdateParams>.Continuation
    private let permsCont: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>.Continuation
    private let filesCont: AsyncStream<ACPFileRequest>.Continuation

    let incomingUpdates: AsyncStream<ACPSessionUpdateParams>
    let permissionRequests: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>
    let fileRequests: AsyncStream<ACPFileRequest>

    init() {
        var u: AsyncStream<ACPSessionUpdateParams>.Continuation!
        self.incomingUpdates = AsyncStream { u = $0 }
        self.updatesCont = u
        var p: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>.Continuation!
        self.permissionRequests = AsyncStream { p = $0 }
        self.permsCont = p
        var f: AsyncStream<ACPFileRequest>.Continuation!
        self.fileRequests = AsyncStream { f = $0 }
        self.filesCont = f
    }

    func send(_ request: ACPRequest) async throws -> ACPResponse {
        sent.append(request)
        guard let script = scripts[request.method] else {
            throw ACPClientError.noScript(method: request.method)
        }
        return ACPResponse(body: try script(request))
    }

    func emit(_ update: ACPSessionUpdateParams) { updatesCont.yield(update) }
    func emitPermission(id: JSONRPCID, params: ACPPermissionRequestParams) { permsCont.yield((id, params)) }
    func emitFile(_ req: ACPFileRequest) { filesCont.yield(req) }

    var permissionResponses: [JSONRPCID: ACPPermissionResponse] = [:]
    func respondToPermission(id: JSONRPCID, response: ACPPermissionResponse) {
        permissionResponses[id] = response
    }
    var fileResponses: [JSONRPCID: Result<Data, JSONRPCError>] = [:]
    func respondToFileRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>) {
        fileResponses[id] = result
    }

    func script(method: String, _ handler: @escaping (ACPRequest) throws -> Data) {
        scripts[method] = handler
    }

    func shutdown() async {
        updatesCont.finish(); permsCont.finish(); filesCont.finish()
    }
}
