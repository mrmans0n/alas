import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public final class ACPStdioClient: ACPClient, ACPV2PromptSending, @unchecked Sendable {
    private let transport: JSONRPCStdioTransporting
    private let v2Replies = ACPV2StdioReplyState()
    private let v2InboundCont: AsyncStream<ACPV2InboundDelivery>.Continuation
    private let rawRPCDiagnosticsCont: AsyncStream<ACPRawRPCDelivery>.Continuation
    private let v2UpdatesCont: AsyncStream<ACPV2SessionUpdateDelivery>.Continuation
    private let updatesCont: AsyncStream<ACPSessionUpdateParams>.Continuation
    private let permsCont: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>.Continuation
    private let cancelRequestsCont: AsyncStream<JSONRPCID>.Continuation
    private let questionsCont: AsyncStream<ACPQuestionRequest>.Continuation
    private let plansCont: AsyncStream<ACPCursorPlanRequest>.Continuation
    private let elicitationsCont: AsyncStream<ACPElicitationRequest>.Continuation
    private let elicitationCompletionsCont: AsyncStream<ACPElicitationCompleteParams>.Continuation
    private let filesCont: AsyncStream<ACPFileRequest>.Continuation
    private let terminalsCont: AsyncStream<ACPTerminalRequest>.Continuation
    private let stderrCont: AsyncStream<Data>.Continuation
    private let authStatusCont: AsyncStream<ACPAuthStatusEvent>.Continuation
    private let sessionListChangesCont: AsyncStream<ACPSessionListChanges>.Continuation

    public let sessionUpdateProtocolVersion: ACPProtocolVersion
    public let updateConnectionID = UUID()
    public let incomingV2Inbound: AsyncStream<ACPV2InboundDelivery>
    public let incomingRawRPCDiagnostics: AsyncStream<ACPRawRPCDelivery>
    public let incomingV2Updates: AsyncStream<ACPV2SessionUpdateDelivery>
    public let incomingUpdates: AsyncStream<ACPSessionUpdateParams>
    public var yieldedUpdateCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _yieldedUpdateCount
    }
    public let permissionRequests: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>
    public let cancelRequests: AsyncStream<JSONRPCID>
    public let questionRequests: AsyncStream<ACPQuestionRequest>
    public let planRequests: AsyncStream<ACPCursorPlanRequest>
    public let elicitationRequests: AsyncStream<ACPElicitationRequest>
    public let elicitationCompletions: AsyncStream<ACPElicitationCompleteParams>
    public let fileRequests: AsyncStream<ACPFileRequest>
    public let terminalRequests: AsyncStream<ACPTerminalRequest>
    public let incomingStderr: AsyncStream<Data>
    public let authStatusUpdates: AsyncStream<ACPAuthStatusEvent>
    public let sessionListChanges: AsyncStream<ACPSessionListChanges>

    private let stateLock = NSLock()
    private var nextId: Int = 0
    private var _yieldedUpdateCount = 0
    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<ACPResponse, Error>
    }
    private var pending: [JSONRPCID: Pending] = [:]
    private var pendingInboundConsumptions: [JSONRPCID: ACPDurableConsumptionAcknowledgement] = [:]
    private var cursorTodosByToolCallId: [String: [ACPCursorTodo]] = [:]
    private var didDrainPending = false
    private var dispatchTask: Task<Void, Never>?

    public init(executable: URL, arguments: [String], environment: [String: String]?,
                sessionUpdateProtocolVersion: ACPProtocolVersion = .v1) throws {
        self.sessionUpdateProtocolVersion = sessionUpdateProtocolVersion
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

        let inbound = AsyncStream<ACPV2InboundDelivery>.makeStream()
        self.incomingV2Inbound = inbound.stream
        self.v2InboundCont = inbound.continuation
        if sessionUpdateProtocolVersion == .v1 { inbound.continuation.finish() }

        let diagnostics = AsyncStream<ACPRawRPCDelivery>.makeStream()
        self.incomingRawRPCDiagnostics = diagnostics.stream
        self.rawRPCDiagnosticsCont = diagnostics.continuation
        if sessionUpdateProtocolVersion == .v1 { diagnostics.continuation.finish() }

        let v2 = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        self.incomingV2Updates = v2.stream
        self.v2UpdatesCont = v2.continuation
        if sessionUpdateProtocolVersion == .v1 { v2.continuation.finish() }
        else { uC.finish() }

        var pC: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>.Continuation!
        self.permissionRequests = AsyncStream { pC = $0 }
        self.permsCont = pC

        var cC: AsyncStream<JSONRPCID>.Continuation!
        self.cancelRequests = AsyncStream { cC = $0 }
        self.cancelRequestsCont = cC

        var qC: AsyncStream<ACPQuestionRequest>.Continuation!
        self.questionRequests = AsyncStream { qC = $0 }
        self.questionsCont = qC

        var planC: AsyncStream<ACPCursorPlanRequest>.Continuation!
        self.planRequests = AsyncStream { planC = $0 }
        self.plansCont = planC

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

        var asC: AsyncStream<ACPAuthStatusEvent>.Continuation!
        self.authStatusUpdates = AsyncStream { asC = $0 }
        self.authStatusCont = asC

        var slC: AsyncStream<ACPSessionListChanges>.Continuation!
        self.sessionListChanges = AsyncStream { slC = $0 }
        self.sessionListChangesCont = slC
        if sessionUpdateProtocolVersion == .v2 { finishLegacyMethodStreams() }
    }

    /// Accepts a pre-built transport directly, skipping the local
    /// subprocess setup (remote channels and tests).
    public init(transport: JSONRPCStdioTransporting, sessionUpdateProtocolVersion: ACPProtocolVersion = .v1) {
        self.sessionUpdateProtocolVersion = sessionUpdateProtocolVersion
        self.transport = transport

        var uC: AsyncStream<ACPSessionUpdateParams>.Continuation!
        self.incomingUpdates = AsyncStream { uC = $0 }
        self.updatesCont = uC

        let inbound = AsyncStream<ACPV2InboundDelivery>.makeStream()
        self.incomingV2Inbound = inbound.stream
        self.v2InboundCont = inbound.continuation
        if sessionUpdateProtocolVersion == .v1 { inbound.continuation.finish() }

        let diagnostics = AsyncStream<ACPRawRPCDelivery>.makeStream()
        self.incomingRawRPCDiagnostics = diagnostics.stream
        self.rawRPCDiagnosticsCont = diagnostics.continuation
        if sessionUpdateProtocolVersion == .v1 { diagnostics.continuation.finish() }

        let v2 = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        self.incomingV2Updates = v2.stream
        self.v2UpdatesCont = v2.continuation
        if sessionUpdateProtocolVersion == .v1 { v2.continuation.finish() }
        else { uC.finish() }

        var pC: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>.Continuation!
        self.permissionRequests = AsyncStream { pC = $0 }
        self.permsCont = pC

        var cC: AsyncStream<JSONRPCID>.Continuation!
        self.cancelRequests = AsyncStream { cC = $0 }
        self.cancelRequestsCont = cC

        var qC: AsyncStream<ACPQuestionRequest>.Continuation!
        self.questionRequests = AsyncStream { qC = $0 }
        self.questionsCont = qC

        var planC: AsyncStream<ACPCursorPlanRequest>.Continuation!
        self.planRequests = AsyncStream { planC = $0 }
        self.plansCont = planC

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

        var asC: AsyncStream<ACPAuthStatusEvent>.Continuation!
        self.authStatusUpdates = AsyncStream { asC = $0 }
        self.authStatusCont = asC

        var slC: AsyncStream<ACPSessionListChanges>.Continuation!
        self.sessionListChanges = AsyncStream { slC = $0 }
        self.sessionListChangesCont = slC
        if sessionUpdateProtocolVersion == .v2 { finishLegacyMethodStreams() }
    }

    /// Convenience factory for tests — wraps `init(transport:)`.
    public static func makeForTesting(transport: JSONRPCStdioTransporting) -> ACPStdioClient {
        ACPStdioClient(transport: transport)
    }

    public func start() throws {
        try transport.start()
        dispatchTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.transport.incoming {
                self.handle(event)
            }
            self.finishObservation()
        }
    }

    private func handle(_ event: JSONRPCStdioTransport.Incoming) {
        switch event {
        case .frame(let data, let onConsumed):
            handleFrame(data, onConsumed: onConsumed)
        case .stderr(let data):
            stderrCont.yield(data)
        case .exited:
            finishObservation()
        }
    }

    private func finishObservation() {
        drainPending(with: ACPClientError.notRunning)
        updatesCont.finish()
        finishLegacyMethodStreams()
        stderrCont.finish()
    }

    private struct AnyEnvelopeHead: Decodable {
        let id: JSONRPCID?
        let method: String?

        public init(id: JSONRPCID?, method: String?) {
            self.id = id
            self.method = method
        }
    }

    private struct MethodHead: Decodable {
        let method: String?
    }

    private static func isSessionUpdateFrame(_ data: Data) -> Bool {
        if case .object(let fields) = try? LSPJSONValue.decode(from: data) {
            return fields["method"] == .string("session/update")
        }
        // Duplicate keys or excessive nesting can reject the exact envelope
        // while its method remains readable. Identify only the method here;
        // retain the original frame for explicit decode failure by the owner.
        return (try? JSONDecoder().decode(MethodHead.self, from: data))?.method == "session/update"
    }

    private func handleFrame(_ data: Data, onConsumed: (@Sendable () -> Void)?) {
        if sessionUpdateProtocolVersion == .v2, handleV2Frame(data, onConsumed: onConsumed) { return }
        var acknowledgeAfterDispatch = true
        defer {
            if acknowledgeAfterDispatch {
                onConsumed?()
            }
        }
        guard let head = try? JSONDecoder().decode(AnyEnvelopeHead.self, from: data) else { return }
        if let id = head.id, head.method == nil {
            stateLock.lock()
            let cont = pending.removeValue(forKey: id)?.continuation
            stateLock.unlock()
            guard let cont else { return }
            if let env = try? JSONDecoder().decode(JSONRPCErrorEnvelope.self, from: data),
               let err = env.error {
                cont.resume(throwing: ACPClientError.jsonrpc(err))
                return
            }
            if let raw = Self.extractResultBytes(from: data) {
                acknowledgeAfterDispatch = false
                cont.resume(returning: ACPResponse(
                    body: raw,
                    durableConsumptionAcknowledgement: onConsumed
                ))
            } else {
                cont.resume(throwing: ACPClientError.decoding("no result/error in response"))
            }
            return
        }
        guard let method = head.method else { return }
        switch method {
        case "session/update":
            guard sessionUpdateProtocolVersion == .v1 else {
                acknowledgeAfterDispatch = false
                return
            }
            // One frame is usually one update; the revised subagent form can
            // normalize to several, and the durable acknowledgement belongs
            // to the LAST one, as for OpenCode's child updates below.
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPSessionUpdateFrame>.self, from: data),
               let frame = env.params, !frame.updates.isEmpty {
                stateLock.lock()
                _yieldedUpdateCount += frame.updates.count
                stateLock.unlock()
                acknowledgeAfterDispatch = false
                for (offset, p) in frame.updates.enumerated() {
                    let isLast = offset == frame.updates.count - 1
                    updatesCont.yield(.init(
                        sessionId: p.sessionId,
                        update: p.update,
                        durableConsumptionAcknowledgement: isLast ? onConsumed : nil
                    ))
                }
            }
        case ACPOpenCodeChildUpdate.method:
            guard sessionUpdateProtocolVersion == .v1 else { break }
            // One notification normalizes to several standard updates; the
            // durable acknowledgement belongs to the LAST one, so the frame
            // is only acked once the whole batch has been applied.
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<AnyCodable>.self, from: data),
               let raw = env.params,
               let payload = try? JSONEncoder().encode(raw) {
                let normalized = ACPOpenCodeChildUpdate.normalize(params: payload)
                guard !normalized.isEmpty else { break }
                stateLock.lock()
                _yieldedUpdateCount += normalized.count
                stateLock.unlock()
                acknowledgeAfterDispatch = false
                for (offset, update) in normalized.enumerated() {
                    let isLast = offset == normalized.count - 1
                    updatesCont.yield(.init(
                        sessionId: update.sessionId,
                        update: update.update,
                        durableConsumptionAcknowledgement: isLast ? onConsumed : nil
                    ))
                }
            }
        case "session/request_permission":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPPermissionRequestParams>.self, from: data),
               let id = env.id, let p = env.params {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                permsCont.yield((id, p))
            }
        case "$/cancel_request":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPCancelRequestParams>.self, from: data),
               let p = env.params {
                cancelRequestsCont.yield(p.id)
            }
        case "cursor/ask_question":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPQuestionRequestParams>.self, from: data),
               let id = env.id, let p = env.params {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                questionsCont.yield(.init(id: id, params: p))
            }
        case "elicitation/create":
            if let env = try? JSONDecoder().decode(
                JSONRPCEnvelope<ACPElicitationRequestParams>.self,
                from: data
            ), let id = env.id, let p = env.params {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                elicitationsCont.yield(.init(id: id, params: p))
            }
        case "elicitation/complete":
            if let env = try? JSONDecoder().decode(
                JSONRPCEnvelope<ACPElicitationCompleteParams>.self,
                from: data
            ), let p = env.params {
                elicitationCompletionsCont.yield(p)
            }
        case "_auth/status_update":
            if let env = try? JSONDecoder().decode(
                JSONRPCEnvelope<ACPAuthStatusUpdateParams>.self,
                from: data
            ), let p = env.params {
                acknowledgeAfterDispatch = false
                authStatusCont.yield(.init(
                    status: p.authStatus,
                    durableConsumptionAcknowledgement: onConsumed
                ))
            }
        case "_session/list/changes":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPSessionListChanges>.self, from: data),
               let p = env.params {
                sessionListChangesCont.yield(p)
            }
        case "fs/read_text_file":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPFsReadParams>.self, from: data),
               let id = env.id, let p = env.params {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                filesCont.yield(.read(id: id, params: p))
            }
        case "fs/write_text_file":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPFsWriteParams>.self, from: data),
               let id = env.id, let p = env.params {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                filesCont.yield(.write(id: id, params: p))
            }
        case "terminal/create":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPTerminalCreateParams>.self, from: data),
               let id = env.id, let p = env.params {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                terminalsCont.yield(.create(id: id, params: p))
            }
        case "terminal/output":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPTerminalOutputParams>.self, from: data),
               let id = env.id, let p = env.params {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                terminalsCont.yield(.output(id: id, params: p))
            }
        case "terminal/wait_for_exit":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPTerminalIdParams>.self, from: data),
               let id = env.id, let p = env.params {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                terminalsCont.yield(.waitForExit(id: id, params: p))
            }
        case "terminal/kill":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPTerminalIdParams>.self, from: data),
               let id = env.id, let p = env.params {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                terminalsCont.yield(.kill(id: id, params: p))
            }
        case "terminal/release":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPTerminalIdParams>.self, from: data),
               let id = env.id, let p = env.params {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                terminalsCont.yield(.release(id: id, params: p))
            }
        case "cursor/create_plan":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPCursorCreatePlanParams>.self, from: data),
               let id = env.id, let params = env.params {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                plansCont.yield(.init(id: id, params: params))
            } else if let id = head.id {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                respondFile(id: id, result: .failure(.init(code: -32602, message: "Invalid params", data: nil)))
            }
        case "cursor/update_todos":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPCursorUpdateTodosParams>.self, from: data),
               let id = env.id, let params = env.params {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                respondToCursorUpdateTodos(id: id, params: params)
            } else if let id = head.id {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                respondFile(id: id, result: .failure(.init(code: -32602, message: "Invalid params", data: nil)))
            }
        case "cursor/task":
            if let env = try? JSONDecoder().decode(JSONRPCEnvelope<ACPCursorTaskParams>.self, from: data),
               let id = env.id, let params = env.params {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                respondToCursorTask(id: id, params: params)
            } else if let id = head.id {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                respondFile(id: id, result: .failure(.init(code: -32602, message: "Invalid params", data: nil)))
            }
        case "cursor/generate_image":
            if let id = head.id {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                respondFile(
                    id: id,
                    result: .failure(.init(
                        code: -32000,
                        message: "cursor/generate_image is not supported",
                        data: nil
                    ))
                )
            }
        default:
            if let id = head.id {
                acknowledgeAfterDispatch = false
                deferInboundConsumption(id: id, acknowledgement: onConsumed)
                respondFile(
                    id: id,
                    result: .failure(.init(code: -32601, message: "Method not found", data: nil))
                )
            }
        }
    }

    /// Selected-v2 evidence never enters legacy typed method dispatch.
    private func handleV2Frame(_ data: Data, onConsumed: ACPDurableConsumptionAcknowledgement?) -> Bool {
        guard case .object(let fields) = try? LSPJSONValue.decode(from: data) else {
            // Existing raw session/update evidence remains exclusive, including
            // parser rejection. A fallback header must never bind a response ID.
            if Self.isSessionUpdateFrame(data) { publishV2Update(data, onConsumed: onConsumed) }
            else { publishRPCDiagnostic(data, onConsumed: onConsumed) }
            return true
        }
        if fields["method"] != nil, fields["result"] != nil || fields["error"] != nil {
            publishRPCDiagnostic(data, onConsumed: onConsumed)
            return true
        }
        if fields["method"] == .string("session/update") {
            publishV2Update(data, onConsumed: onConsumed)
            return true
        }
        if let method = fields["method"] {
            let supportedID = fields["id"].map { ACPRawRPCDelivery.stdioID($0) != nil } ?? true
            if case .string = method, fields["jsonrpc"] == .string("2.0"), supportedID {
                publishV2Inbound(data, requestID: fields["id"].flatMap(ACPRawRPCDelivery.stdioID), onConsumed: onConsumed)
                return true
            }
            publishRPCDiagnostic(data, onConsumed: onConsumed)
            return true
        }
        guard let rawID = fields["id"], let id = ACPRawRPCDelivery.stdioID(rawID) else {
            publishRPCDiagnostic(data, onConsumed: onConsumed)
            return true
        }
        stateLock.lock()
        let request = pending.removeValue(forKey: id)
        stateLock.unlock()
        guard let request else {
            publishRPCDiagnostic(data, onConsumed: onConsumed)
            return true
        }
        let delivery = rpcDelivery(data, source: .stdio(requestID: id, method: request.method), onConsumed: onConsumed)
        do {
            let decoded = try delivery.decode()
            if let error = decoded.error {
                request.continuation.resume(throwing: ACPRawRPCError(delivery: delivery, rpcError: error))
            } else if let result = decoded.result {
                request.continuation.resume(returning: ACPResponse(body: result, rawDelivery: delivery))
            } else {
                request.continuation.resume(throwing: ACPRawRPCError(delivery: delivery, rpcError: nil))
            }
        } catch {
            request.continuation.resume(throwing: ACPRawRPCError(delivery: delivery, rpcError: nil))
        }
        return true
    }

    private func publishV2Update(_ data: Data, onConsumed: ACPDurableConsumptionAcknowledgement?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !didDrainPending else { return }
        _yieldedUpdateCount += 1
        v2UpdatesCont.yield(.init(frame: data, connectionID: updateConnectionID, durableConsumptionAcknowledgement: onConsumed))
    }

    private func publishRPCDiagnostic(_ data: Data, onConsumed: ACPDurableConsumptionAcknowledgement?) {
        rawRPCDiagnosticsCont.yield(rpcDelivery(data, source: .diagnostic, onConsumed: onConsumed))
    }

    private func finishLegacyMethodStreams() {
        permsCont.finish()
        cancelRequestsCont.finish()
        questionsCont.finish()
        plansCont.finish()
        elicitationsCont.finish()
        elicitationCompletionsCont.finish()
        filesCont.finish()
        terminalsCont.finish()
        authStatusCont.finish()
        sessionListChangesCont.finish()
    }

    private func publishV2Inbound(_ data: Data, requestID: JSONRPCID?, onConsumed: ACPDurableConsumptionAcknowledgement?) {
        let acknowledgement = connectionAcknowledgement(onConsumed)
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !didDrainPending else { return }
        let delivery = ACPV2InboundDelivery(frame: data, connectionID: updateConnectionID, source: .stdio,
            durableConsumptionAcknowledgement: acknowledgement)
        if let requestID { v2Replies.register(delivery, id: requestID) }
        v2InboundCont.yield(delivery)
    }

    private func rpcDelivery(_ data: Data, source: ACPRawRPCDelivery.Source,
        onConsumed: ACPDurableConsumptionAcknowledgement?) -> ACPRawRPCDelivery {
        .init(frame: data, connectionID: updateConnectionID, source: source,
            durableConsumptionAcknowledgement: connectionAcknowledgement(onConsumed))
    }

    private func connectionAcknowledgement(_ onConsumed: ACPDurableConsumptionAcknowledgement?) -> ACPDurableConsumptionAcknowledgement? {
        guard let onConsumed else { return nil }
        return { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let active = !self.didDrainPending
            self.stateLock.unlock()
            if active { onConsumed() }
        }
    }

    /// Extracts the raw JSON bytes of the `result` field from a full envelope.
    private static func extractResultBytes(from envelope: Data) -> Data? {
        guard case .object(let fields) = try? LSPJSONValue.decode(from: envelope),
              let result = fields["result"] else { return nil }
        return try? result.encodedData()
    }

    // MARK: - Outbound

    public func send(_ request: ACPRequest) async throws -> ACPResponse {
        try await send(request, onRequestHandoff: {})
    }

    public func send(
        _ request: ACPRequest,
        onRequestHandoff: @Sendable () -> Void
    ) async throws -> ACPResponse {
        let id = nextRequestID()

        let body = try Self.encode(envelopeFor: request, id: id)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ACPResponse, Error>) in
            stateLock.lock()
            if didDrainPending {
                stateLock.unlock()
                onRequestHandoff()
                cont.resume(throwing: ACPClientError.notRunning)
                return
            }
            pending[id] = Pending(method: request.method, continuation: cont)
            stateLock.unlock()
            do {
                try transport.send(body)
                onRequestHandoff()
            } catch {
                stateLock.lock()
                // If a concurrent drainPending (shutdown()/`.exited`) already
                // removed and resumed this entry, `removeValue` returns nil
                // here — in that case `cont` has already been resumed and we
                // must not resume it again (that would trap).
                let stillPending = pending.removeValue(forKey: id) != nil
                stateLock.unlock()
                if stillPending { cont.resume(throwing: error) }
                onRequestHandoff()
            }
        }
    }

    public func respondToV2Request(_ delivery: ACPV2InboundDelivery, expectedConnectionID: UUID,
        operationKey: ACPV2ReplyOperationKey, frame: Data) async throws -> ACPV2StdioReplyResult {
        guard sessionUpdateProtocolVersion == .v2, let writer = transport as? any JSONRPCFrameWriting else {
            throw ACPV2StdioReplyError.unsupported
        }
        guard expectedConnectionID == updateConnectionID, delivery.connectionID == updateConnectionID,
              case .stdio = delivery.source else { throw ACPV2StdioReplyError.invalidOrigin }
        return try await v2Replies.reply(delivery, key: operationKey, frame: frame, writer: writer) { [weak self] in
            self?.drainPending(with: ACPClientError.notRunning)
            self?.transport.terminate()
        }
    }

    public var v2PromptEndpoint: ACPV2PromptEndpoint? {
        sessionUpdateProtocolVersion == .v2 ? .stdio(connectionID: updateConnectionID) : nil
    }

    public func sendV2Prompt(_ params: ACPSessionPromptParams, operationKey: ACPBrokerOperationKey?,
        gate: ACPV2PromptHandoffGate,
        prepare: @escaping @Sendable (ACPV2PreparedPrompt) async throws -> Void) async throws -> ACPResponse {
        guard let endpoint = v2PromptEndpoint else { throw ACPV2PromptDispatchError.unsupported }
        let id = nextRequestID()
        let body = try Self.encode(envelopeFor: ACPRequest(method: "session/prompt", params: params), id: id)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await prepare(.init(endpoint: endpoint, binding: .stdio(requestID: id)))
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                stateLock.lock()
                do {
                    guard !didDrainPending else { throw ACPClientError.notRunning }
                    try Task.checkCancellation()
                    try gate.claim()
                    pending[id] = Pending(method: "session/prompt", continuation: continuation)
                    stateLock.unlock()
                } catch {
                    stateLock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                do { try transport.send(body) }
                catch { cancelPreparedPrompt(id: id, error: error) }
            }
        } onCancel: {
            gate.invalidate()
            self.cancelPreparedPrompt(id: id, error: CancellationError())
        }
    }

    private func cancelPreparedPrompt(id: JSONRPCID, error: any Error) {
        let continuation = stateLock.withLock { pending.removeValue(forKey: id)?.continuation }
        continuation?.resume(throwing: error)
    }

    private func nextRequestID() -> JSONRPCID {
        stateLock.lock()
        defer { stateLock.unlock() }
        nextId += 1
        if let prefix = transport.requestIDPrefix {
            return .string("\(prefix):\(nextId)")
        }
        return .number(nextId)
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
    public func notify(_ request: ACPRequest) async throws {
        var dict: [String: Any] = ["jsonrpc": "2.0", "method": request.method]
        if let p = request.params {
            let pData = try JSONEncoder().encode(AnyEncodableBox(p))
            dict["params"] = try JSONSerialization.jsonObject(with: pData)
        }
        let body = try JSONSerialization.data(withJSONObject: dict)
        try transport.send(body)
    }

    public func respondToPermission(id: JSONRPCID, response: ACPPermissionResponse) {
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

    public func respondToQuestion(id: JSONRPCID, response: ACPQuestionResponse) {
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

    public func respondToPlan(id: JSONRPCID, response: ACPCursorPlanResponse) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try self.respond(id: id, body: JSONEncoder().encode(response))
            } catch {}
        }
    }

    public func respondToElicitation(
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

    private func respondToCursorUpdateTodos(id: JSONRPCID, params: ACPCursorUpdateTodosParams) {
        let todos = mergedCursorTodos(for: params)
        respondCursorExtension(
            id: id,
            response: ACPCursorUpdateTodosResponse(outcome: .init(todos: todos))
        )
    }

    private func mergedCursorTodos(for params: ACPCursorUpdateTodosParams) -> [ACPCursorTodo] {
        stateLock.lock()
        defer { stateLock.unlock() }
        let todos = params.mergedTodos(with: cursorTodosByToolCallId[params.toolCallId] ?? [])
        cursorTodosByToolCallId[params.toolCallId] = todos
        return todos
    }

    private func respondToCursorTask(id: JSONRPCID, params: ACPCursorTaskParams) {
        respondCursorExtension(
            id: id,
            response: ACPCursorTaskResponse(
                outcome: .init(agentId: params.agentId, durationMs: params.durationMs)
            )
        )
    }

    private func respondCursorExtension<Response: Encodable>(id: JSONRPCID, response: Response) {
        guard let body = try? JSONEncoder().encode(response) else { return }
        try? respond(id: id, body: body)
    }

    public func respondToFileRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>) {
        Task { [weak self] in
            guard let self else { return }
            self.respondFile(id: id, result: result)
        }
    }

    public func respondToTerminalRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>) {
        Task { [weak self] in
            guard let self else { return }
            self.respondFile(id: id, result: result)
        }
    }

    public func hasPendingOutboundRequest(id: JSONRPCID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pending[id] != nil
    }

    private func respond(id: JSONRPCID, body: Data) throws {
        guard sessionUpdateProtocolVersion == .v1 else { throw ACPV2StdioReplyError.unsupported }
        var dict: [String: Any] = ["jsonrpc": "2.0", "id": id.asJSON]
        dict["result"] = try JSONSerialization.jsonObject(with: body)
        let payload = try JSONSerialization.data(withJSONObject: dict)
        try transport.send(payload, onWritten: { [weak self] in
            self?.acknowledgeInboundConsumption(id: id)
        })
    }

    private func respondFile(id: JSONRPCID, result: Result<Data, JSONRPCError>) {
        guard sessionUpdateProtocolVersion == .v1 else { return }
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
            let payload = try JSONSerialization.data(withJSONObject: dict)
            try transport.send(payload, onWritten: { [weak self] in
                self?.acknowledgeInboundConsumption(id: id)
            })
        } catch {}
    }

    private func deferInboundConsumption(
        id: JSONRPCID,
        acknowledgement: ACPDurableConsumptionAcknowledgement?
    ) {
        guard let acknowledgement else { return }
        stateLock.lock()
        if pendingInboundConsumptions[id] == nil {
            pendingInboundConsumptions[id] = acknowledgement
        }
        stateLock.unlock()
    }

    private func acknowledgeInboundConsumption(id: JSONRPCID) {
        stateLock.lock()
        let acknowledgement = pendingInboundConsumptions.removeValue(forKey: id)
        stateLock.unlock()
        acknowledgement?()
    }

    /// Resumes and clears every pending outbound continuation exactly once.
    /// Safe to call from both `shutdown()` and the `.exited` handler; the
    /// second caller is a no-op (double-resuming a CheckedContinuation traps).
    /// This can also race a concurrent `send(_:)` whose `transport.send`
    /// subsequently throws for the same `id`; `send(_:)` guards against
    /// double-resuming in that case by only resuming if its own
    /// `pending.removeValue` still found the entry.
    private func drainPending(with error: Error) {
        v2Replies.stop()
        stateLock.lock()
        if didDrainPending {
            stateLock.unlock()
            return
        }
        didDrainPending = true
        v2UpdatesCont.finish()
        rawRPCDiagnosticsCont.finish()
        v2InboundCont.finish()
        let snapshot = pending
        pending.removeAll()
        stateLock.unlock()
        for (_, request) in snapshot { request.continuation.resume(throwing: error) }
    }

    public func shutdown() async {
        drainPending(with: ACPClientError.notRunning)
        transport.terminate()
        dispatchTask?.cancel()
        discardPendingInboundConsumptions()
    }

    private func discardPendingInboundConsumptions() {
        stateLock.lock()
        defer { stateLock.unlock() }
        pendingInboundConsumptions.removeAll()
    }
}

// MARK: - Private helpers

private struct JSONRPCErrorEnvelope: Decodable {
    let error: JSONRPCError?

    public init(error: JSONRPCError?) {
        self.error = error
    }
}

private struct AnyEncodableBox: Encodable {
    let value: Encodable
    package init(_ value: Encodable) { self.value = value }
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
