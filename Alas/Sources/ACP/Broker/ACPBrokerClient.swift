import Foundation

protocol ACPBrokerServicing: Sendable {
    func open(_ params: ACPBrokerOpenParams) async throws -> ACPBrokerOpenResult
    func attach(_ params: ACPBrokerAttachParams) async throws -> ACPBrokerAttachResult
    func send(_ params: ACPBrokerSendParams) async throws -> ACPBrokerSendResult
    func respond(_ params: ACPBrokerRespondParams) async throws -> ACPBrokerSimpleOK
    func ack(_ params: ACPBrokerAckParams) async throws -> ACPBrokerSimpleOK
    func detach(_ params: ACPBrokerDetachParams) async throws -> ACPBrokerSimpleOK
    func close(_ params: ACPBrokerCloseParams) async throws -> ACPBrokerSimpleOK
}

extension LocalACPBrokerService: ACPBrokerServicing {}

final class ACPBrokerClient: ACPClient, @unchecked Sendable {
    private let service: ACPBrokerServicing
    private let brokerId: ACPBrokerID
    private let sessionId: String
    private let command: String
    private let args: [String]
    private let cwd: String
    private let env: [String: String]
    private let operationKeyPrefix: String

    private let updatesCont: AsyncStream<ACPSessionUpdateParams>.Continuation
    private let permsCont: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>.Continuation
    private let questionsCont: AsyncStream<ACPQuestionRequest>.Continuation
    private let elicitationsCont: AsyncStream<ACPElicitationRequest>.Continuation
    private let elicitationCompletionsCont: AsyncStream<ACPElicitationCompleteParams>.Continuation
    private let filesCont: AsyncStream<ACPFileRequest>.Continuation
    private let terminalsCont: AsyncStream<ACPTerminalRequest>.Continuation

    let incomingUpdates: AsyncStream<ACPSessionUpdateParams>
    let permissionRequests: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>
    let questionRequests: AsyncStream<ACPQuestionRequest>
    let elicitationRequests: AsyncStream<ACPElicitationRequest>
    let elicitationCompletions: AsyncStream<ACPElicitationCompleteParams>
    let fileRequests: AsyncStream<ACPFileRequest>
    let terminalRequests: AsyncStream<ACPTerminalRequest>

    private let stateLock = NSLock()
    private var generation: ACPBrokerGeneration?
    private var acknowledgedCursor = ACPBrokerEventCursor(rawValue: 0)
    private var latestCursor = ACPBrokerEventCursor(rawValue: 0)
    private var nextOperationIndex = 0
    private var _yieldedUpdateCount = 0
    private var pendingInboundCursors: [JSONRPCID: ACPBrokerEventCursor] = [:]

    var yieldedUpdateCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _yieldedUpdateCount
    }

    init(
        service: ACPBrokerServicing,
        brokerId: ACPBrokerID,
        sessionId: String,
        command: String,
        args: [String],
        cwd: String,
        env: [String: String],
        operationKeyPrefix: String
    ) {
        self.service = service
        self.brokerId = brokerId
        self.sessionId = sessionId
        self.command = command
        self.args = args
        self.cwd = cwd
        self.env = env
        self.operationKeyPrefix = operationKeyPrefix

        var u: AsyncStream<ACPSessionUpdateParams>.Continuation!
        incomingUpdates = AsyncStream { u = $0 }
        updatesCont = u

        var p: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>.Continuation!
        permissionRequests = AsyncStream { p = $0 }
        permsCont = p

        var q: AsyncStream<ACPQuestionRequest>.Continuation!
        questionRequests = AsyncStream { q = $0 }
        questionsCont = q

        var e: AsyncStream<ACPElicitationRequest>.Continuation!
        elicitationRequests = AsyncStream { e = $0 }
        elicitationsCont = e

        var ec: AsyncStream<ACPElicitationCompleteParams>.Continuation!
        elicitationCompletions = AsyncStream { ec = $0 }
        elicitationCompletionsCont = ec

        var f: AsyncStream<ACPFileRequest>.Continuation!
        fileRequests = AsyncStream { f = $0 }
        filesCont = f

        var t: AsyncStream<ACPTerminalRequest>.Continuation!
        terminalRequests = AsyncStream { t = $0 }
        terminalsCont = t
    }

    @discardableResult
    func start() async throws -> ACPBrokerOpenResult {
        let opened = try await service.open(ACPBrokerOpenParams(
            brokerId: brokerId,
            sessionId: sessionId,
            command: command,
            args: args,
            cwd: cwd,
            env: env
        ))
        setSnapshot(opened.snapshot)
        try await attachAndReplay()
        return opened
    }

    func send(_ request: ACPRequest) async throws -> ACPResponse {
        let generation = try currentGeneration()
        let result = try await service.send(ACPBrokerSendParams(
            brokerId: brokerId,
            generation: generation,
            operationKey: nextOperationKey(method: request.method),
            method: request.method,
            params: try ACPBrokerJSONValue(encodable: request.params)
        ))
        try await attachAndReplay()
        let cursor = currentLatestCursor()
        return ACPResponse(
            body: try (result.result ?? .null).data,
            durableConsumptionAcknowledgement: { [weak self] in
                self?.ack(cursor: cursor)
            }
        )
    }

    func notify(_ request: ACPRequest) async throws {
        throw ACPClientError.decoding("Broker-backed ACP notifications are not supported yet: \(request.method)")
    }

    func respondToPermission(id: JSONRPCID, response: ACPPermissionResponse) {
        respond(id: id, value: response)
    }

    func respondToQuestion(id: JSONRPCID, response: ACPQuestionResponse) {
        respond(id: id, value: response)
    }

    func respondToElicitation(
        id: JSONRPCID,
        result: Result<ACPElicitationResponse, JSONRPCError>
    ) {
        switch result {
        case .success(let response):
            respond(id: id, value: response)
        case .failure(let error):
            respond(id: id, value: JSONRPCFailureResult(error: error))
        }
    }

    func respondToFileRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>) {
        respondToRawResult(id: id, result: result)
    }

    func respondToTerminalRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>) {
        respondToRawResult(id: id, result: result)
    }

    func hasPendingOutboundRequest(id: JSONRPCID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pendingInboundCursors[id] != nil
    }

    func shutdown() async {
        if let generation = try? currentGeneration() {
            _ = try? await service.detach(ACPBrokerDetachParams(brokerId: brokerId, generation: generation))
        }
        updatesCont.finish()
        permsCont.finish()
        questionsCont.finish()
        elicitationsCont.finish()
        elicitationCompletionsCont.finish()
        filesCont.finish()
        terminalsCont.finish()
    }

    private func attachAndReplay() async throws {
        let generation = try currentGeneration()
        let cursor = currentAcknowledgedCursor()
        let attached = try await service.attach(ACPBrokerAttachParams(
            brokerId: brokerId,
            generation: generation,
            acknowledgedCursor: cursor
        ))
        setSnapshot(attached.snapshot)
        for event in attached.events {
            dispatch(event)
        }
    }

    private func dispatch(_ event: ACPBrokerEvent) {
        stateLock.lock()
        latestCursor = max(latestCursor, event.cursor)
        stateLock.unlock()

        switch event.kind {
        case .adapterNotification(let method, let params):
            dispatchAdapterNotification(method: method, params: params, cursor: event.cursor)
        case .pendingRequest(let request):
            dispatchPendingRequest(request, cursor: event.cursor)
        default:
            break
        }
    }

    private func dispatchAdapterNotification(
        method: String,
        params: ACPBrokerJSONValue,
        cursor: ACPBrokerEventCursor
    ) {
        switch method {
        case "session/update":
            guard let decoded = try? JSONDecoder().decode(ACPSessionUpdateParams.self, from: params.data) else {
                return
            }
            stateLock.lock()
            _yieldedUpdateCount += 1
            stateLock.unlock()
            updatesCont.yield(.init(
                sessionId: decoded.sessionId,
                update: decoded.update,
                durableConsumptionAcknowledgement: { [weak self] in
                    self?.ack(cursor: cursor)
                }
            ))
        case "elicitation/complete":
            if let decoded = try? JSONDecoder().decode(ACPElicitationCompleteParams.self, from: params.data) {
                elicitationCompletionsCont.yield(decoded)
            }
        default:
            break
        }
    }

    private func dispatchPendingRequest(_ request: ACPBrokerPendingRequest, cursor: ACPBrokerEventCursor) {
        guard let id = request.adapterRequestId.jsonRPCID else { return }
        stateLock.lock()
        pendingInboundCursors[id] = cursor
        stateLock.unlock()

        switch request.kind {
        case .permission:
            if let params = try? JSONDecoder().decode(ACPPermissionRequestParams.self, from: request.payload.data) {
                permsCont.yield((id, params))
            }
        case .question:
            if let params = try? JSONDecoder().decode(ACPQuestionRequestParams.self, from: request.payload.data) {
                questionsCont.yield(.init(id: id, params: params))
            }
        case .elicitation:
            if let params = try? JSONDecoder().decode(ACPElicitationRequestParams.self, from: request.payload.data) {
                elicitationsCont.yield(.init(id: id, params: params))
            }
        case .file:
            dispatchFileRequest(id: id, payload: request.payload)
        case .terminal:
            dispatchTerminalRequest(id: id, payload: request.payload)
        }
    }

    private func dispatchFileRequest(id: JSONRPCID, payload: ACPBrokerJSONValue) {
        guard
            case .object(let object) = payload,
            case .string(let method)? = object["method"],
            let params = object["params"]
        else { return }
        switch method {
        case "fs/read_text_file":
            if let decoded = try? JSONDecoder().decode(ACPFsReadParams.self, from: params.data) {
                filesCont.yield(.read(id: id, params: decoded))
            }
        case "fs/write_text_file":
            if let decoded = try? JSONDecoder().decode(ACPFsWriteParams.self, from: params.data) {
                filesCont.yield(.write(id: id, params: decoded))
            }
        default:
            break
        }
    }

    private func dispatchTerminalRequest(id: JSONRPCID, payload: ACPBrokerJSONValue) {
        guard
            case .object(let object) = payload,
            case .string(let method)? = object["method"],
            let params = object["params"]
        else { return }
        switch method {
        case "terminal/create":
            if let decoded = try? JSONDecoder().decode(ACPTerminalCreateParams.self, from: params.data) {
                terminalsCont.yield(.create(id: id, params: decoded))
            }
        case "terminal/output":
            if let decoded = try? JSONDecoder().decode(ACPTerminalOutputParams.self, from: params.data) {
                terminalsCont.yield(.output(id: id, params: decoded))
            }
        case "terminal/wait_for_exit":
            if let decoded = try? JSONDecoder().decode(ACPTerminalIdParams.self, from: params.data) {
                terminalsCont.yield(.waitForExit(id: id, params: decoded))
            }
        case "terminal/kill":
            if let decoded = try? JSONDecoder().decode(ACPTerminalIdParams.self, from: params.data) {
                terminalsCont.yield(.kill(id: id, params: decoded))
            }
        case "terminal/release":
            if let decoded = try? JSONDecoder().decode(ACPTerminalIdParams.self, from: params.data) {
                terminalsCont.yield(.release(id: id, params: decoded))
            }
        default:
            break
        }
    }

    private func respond<T: Encodable>(id: JSONRPCID, value: T) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.respond(id: id, result: ACPBrokerJSONValue(encodable: value))
            } catch {}
        }
    }

    private func respondToRawResult(id: JSONRPCID, result: Result<Data, JSONRPCError>) {
        Task { [weak self] in
            guard let self else { return }
            do {
                switch result {
                case .success(let data):
                    try await self.respond(id: id, result: ACPBrokerJSONValue(data: data))
                case .failure(let error):
                    try await self.respond(id: id, result: ACPBrokerJSONValue(encodable: JSONRPCFailureResult(error: error)))
                }
            } catch {}
        }
    }

    private func respond(id: JSONRPCID, result: ACPBrokerJSONValue) async throws {
        let generation = try currentGeneration()
        guard let requestId = ACPBrokerAdapterRequestID(jsonRPCID: id) else { return }
        _ = try await service.respond(ACPBrokerRespondParams(
            brokerId: brokerId,
            generation: generation,
            requestId: requestId,
            operationKey: nextOperationKey(method: "respond"),
            result: result
        ))
        stateLock.lock()
        let cursor = pendingInboundCursors.removeValue(forKey: id)
        stateLock.unlock()
        if let cursor {
            ack(cursor: cursor)
        }
    }

    private func ack(cursor: ACPBrokerEventCursor) {
        Task { [weak self] in
            guard let self, let generation = try? self.currentGeneration() else { return }
            _ = try? await self.service.ack(ACPBrokerAckParams(
                brokerId: self.brokerId,
                generation: generation,
                cursor: cursor
            ))
            self.stateLock.lock()
            self.acknowledgedCursor = max(self.acknowledgedCursor, cursor)
            self.stateLock.unlock()
        }
    }

    private func setSnapshot(_ snapshot: ACPBrokerSnapshot) {
        stateLock.lock()
        generation = snapshot.metadata.generation
        acknowledgedCursor = max(acknowledgedCursor, snapshot.acknowledgedCursor)
        latestCursor = max(latestCursor, snapshot.journalTail)
        stateLock.unlock()
    }

    private func currentGeneration() throws -> ACPBrokerGeneration {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let generation else { throw ACPClientError.notRunning }
        return generation
    }

    private func currentAcknowledgedCursor() -> ACPBrokerEventCursor {
        stateLock.lock()
        defer { stateLock.unlock() }
        return acknowledgedCursor
    }

    private func currentLatestCursor() -> ACPBrokerEventCursor {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestCursor
    }

    private func nextOperationKey(method: String) -> ACPBrokerOperationKey {
        stateLock.lock()
        defer { stateLock.unlock() }
        nextOperationIndex += 1
        return ACPBrokerOperationKey(rawValue: "\(operationKeyPrefix):\(nextOperationIndex):\(method)")
    }
}

private struct JSONRPCFailureResult: Encodable {
    let error: JSONRPCError
}

private struct AnyEncodableBrokerBox: Encodable {
    let value: Encodable

    init(_ value: Encodable) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

private extension ACPBrokerJSONValue {
    init(encodable value: Encodable?) throws {
        guard let value else {
            self = .null
            return
        }
        let data = try JSONEncoder().encode(AnyEncodableBrokerBox(value))
        try self.init(data: data)
    }

    init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        try self.init(jsonObject: object)
    }

    init(jsonObject: Any) throws {
        switch jsonObject {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .number(Double(value))
        case let value as UInt:
            self = .number(Double(value))
        case let value as Double:
            self = .number(value)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map { try ACPBrokerJSONValue(jsonObject: $0) })
        case let value as [String: Any]:
            self = .object(try value.mapValues { try ACPBrokerJSONValue(jsonObject: $0) })
        default:
            throw ACPClientError.decoding("Unsupported broker JSON value: \(type(of: jsonObject))")
        }
    }

    var jsonRPCID: JSONRPCID? {
        switch self {
        case .number(let value):
            return .number(Int(value))
        case .string(let value):
            return .string(value)
        default:
            return nil
        }
    }
}

private extension ACPBrokerAdapterRequestID {
    init?(jsonRPCID: JSONRPCID) {
        switch jsonRPCID {
        case .number(let value):
            guard value >= 0 else { return nil }
            self.init(rawValue: UInt64(value))
        case .string(let value):
            guard let parsed = UInt64(value) else { return nil }
            self.init(rawValue: parsed)
        }
    }
}
