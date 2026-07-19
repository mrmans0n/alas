import Foundation

protocol ACPBrokerServicing: Sendable {
    func open(_ params: ACPBrokerOpenParams) async throws -> ACPBrokerOpenResult
    func attach(_ params: ACPBrokerAttachParams) async throws -> ACPBrokerAttachResult
    func send(_ params: ACPBrokerSendParams) async throws -> ACPBrokerSendResult
    func notify(_ params: ACPBrokerNotifyParams) async throws -> ACPBrokerSimpleOK
    func respond(_ params: ACPBrokerRespondParams) async throws -> ACPBrokerSimpleOK
    func ack(_ params: ACPBrokerAckParams) async throws -> ACPBrokerSimpleOK
    func detach(_ params: ACPBrokerDetachParams) async throws -> ACPBrokerSimpleOK
    func close(_ params: ACPBrokerCloseParams) async throws -> ACPBrokerSimpleOK
}

extension LocalACPBrokerService: ACPBrokerServicing {}

struct ACPBrokerDurableState: Equatable, Sendable {
    let brokerId: ACPBrokerID
    let generation: ACPBrokerGeneration
    let acknowledgedCursor: ACPBrokerEventCursor
}

final class ACPBrokerClient: ACPClient, @unchecked Sendable {
    private let service: ACPBrokerServicing
    private let brokerId: ACPBrokerID
    private let sessionId: String
    private let command: String
    private let args: [String]
    private let cwd: String
    private let env: [String: String]
    private let operationKeyPrefix: String
    private let initialBrokerGeneration: ACPBrokerGeneration?
    private let onDurableStateChanged: (@Sendable (ACPBrokerDurableState) -> Void)?
    private let onTurnStateChanged: (@Sendable (ACPBrokerTurnState) -> Void)?

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
    private var initializeResult: ACPBrokerJSONValue?
    private var remoteSessionResult: ACPBrokerJSONValue?
    private var nextOperationIndex = 0
    private var _yieldedUpdateCount = 0
    private var pendingInboundCursors: [JSONRPCID: ACPBrokerEventCursor] = [:]
    private var pendingOutboundRequestIds: Set<JSONRPCID> = []
    private var operationCompletionCursors: [ACPBrokerOperationKey: ACPBrokerEventCursor] = [:]
    private var unacknowledgedDurableEventCursors: Set<ACPBrokerEventCursor> = []
    private var deferredOrderedAckCursors: Set<ACPBrokerEventCursor> = []
    private var dispatchedEventCursors: Set<ACPBrokerEventCursor> = []
    private var turnState: ACPBrokerTurnState = .idle
    private var isTerminated = false
    private var backgroundPollingTask: Task<Void, Never>?
    private let backgroundPollActiveIntervalNanoseconds: UInt64
    private let backgroundPollIdleIntervalNanoseconds: UInt64
    private var lastQueuedDurableState: ACPBrokerDurableState?
    private var pendingDurableStates: [ACPBrokerDurableState] = []
    private var isDrainingDurableStates = false

    /// Interval used while `turnState` needs active polling (sending,
    /// streaming, awaiting input, cancelling).
    static let defaultBackgroundPollActiveIntervalNanoseconds: UInt64 = 50_000_000
    /// Interval used otherwise. The broker is pull-only: `attachAndReplay`
    /// only runs from `start()`, from `send()`/`notify()`, and from this
    /// background loop. A turn the agent resumes on its own — an SDK-queued
    /// follow-up message, a stop-hook continuation, a `/loop`-style wakeup —
    /// produces events with nobody pulling them, because nothing in Alas
    /// issued the RPC that would trigger a pull. Without this idle-rate
    /// poll, those events sit in the broker's durable log until the next
    /// user prompt replays the whole backlog at once — the transcript
    /// looks frozen for however long the agent kept going on its own.
    static let defaultBackgroundPollIdleIntervalNanoseconds: UInt64 = 2_000_000_000

    var yieldedUpdateCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _yieldedUpdateCount
    }

    var currentTurnState: ACPBrokerTurnState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return turnState
    }

    init(
        service: ACPBrokerServicing,
        brokerId: ACPBrokerID,
        sessionId: String,
        command: String,
        args: [String],
        cwd: String,
        env: [String: String],
        operationKeyPrefix: String,
        initialBrokerGeneration: ACPBrokerGeneration? = nil,
        initialAcknowledgedCursor: ACPBrokerEventCursor = ACPBrokerEventCursor(rawValue: 0),
        backgroundPollActiveIntervalNanoseconds: UInt64 = ACPBrokerClient.defaultBackgroundPollActiveIntervalNanoseconds,
        backgroundPollIdleIntervalNanoseconds: UInt64 = ACPBrokerClient.defaultBackgroundPollIdleIntervalNanoseconds,
        onDurableStateChanged: (@Sendable (ACPBrokerDurableState) -> Void)? = nil,
        onTurnStateChanged: (@Sendable (ACPBrokerTurnState) -> Void)? = nil
    ) {
        self.service = service
        self.brokerId = brokerId
        self.sessionId = sessionId
        self.command = command
        self.args = args
        self.cwd = cwd
        self.env = env
        self.operationKeyPrefix = operationKeyPrefix
        self.initialBrokerGeneration = initialBrokerGeneration
        self.acknowledgedCursor = initialAcknowledgedCursor
        self.backgroundPollActiveIntervalNanoseconds = backgroundPollActiveIntervalNanoseconds
        self.backgroundPollIdleIntervalNanoseconds = backgroundPollIdleIntervalNanoseconds
        self.onDurableStateChanged = onDurableStateChanged
        self.onTurnStateChanged = onTurnStateChanged

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
        if let initialBrokerGeneration,
           initialBrokerGeneration != opened.snapshot.metadata.generation {
            resetAcknowledgedCursor()
        }
        setSnapshot(opened.snapshot)
        _ = try await attachAndReplay()
        startBackgroundPolling()
        return opened
    }

    func send(_ request: ACPRequest) async throws -> ACPResponse {
        if let replayed = cachedResponse(for: request.method) {
            return ACPResponse(body: try replayed.data)
        }
        let generation = try currentGeneration()
        let operationKey = request.brokerOperationKey.map(ACPBrokerOperationKey.init(rawValue:))
            ?? nextOperationKey(method: request.method)
        let params = try ACPBrokerJSONValue(encodable: request.params)
        while true {
            let result = try await service.send(ACPBrokerSendParams(
                brokerId: brokerId,
                generation: generation,
                operationKey: operationKey,
                method: request.method,
                params: params
            ))
            markPendingOutboundRequest(id: result.requestId.jsonRPCID)
            try await attachAndReplay()
            if let error = result.error {
                clearPendingOutboundRequest(id: result.requestId.jsonRPCID)
                throw ACPClientError.jsonrpc(error)
            }
            if result.pending == true && result.result == nil {
                try await Task.sleep(for: .milliseconds(50))
                continue
            }
            clearPendingOutboundRequest(id: result.requestId.jsonRPCID)
            let cursor = currentOperationCompletionCursor(for: operationKey)
            if let cursor {
                trackDeferredResponse(cursor: cursor)
            }
            return ACPResponse(
                body: try (result.result ?? .null).data,
                durableConsumptionAcknowledgement: { [weak self] in
                    if let cursor {
                        self?.ackResponse(cursor: cursor)
                    }
                }
            )
        }
    }

    func notify(_ request: ACPRequest) async throws {
        let generation = try currentGeneration()
        _ = try await service.notify(ACPBrokerNotifyParams(
            brokerId: brokerId,
            generation: generation,
            method: request.method,
            params: try ACPBrokerJSONValue(encodable: request.params)
        ))
        try await attachAndReplay()
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
            respond(id: id, error: error)
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
        return pendingOutboundRequestIds.contains(id)
    }

    func shutdown() async {
        cancelBackgroundPolling()
        if let generation = try? currentGeneration() {
            _ = try? await service.close(ACPBrokerCloseParams(brokerId: brokerId, generation: generation))
        }
        finishStreams()
    }

    func detach() async {
        cancelBackgroundPolling()
        if let generation = try? currentGeneration() {
            _ = try? await service.detach(ACPBrokerDetachParams(brokerId: brokerId, generation: generation))
        }
        finishStreams()
    }

    private func finishStreams() {
        // Marks the connection as permanently done. Every path that ends
        // streaming (explicit shutdown/detach, an `adapter/exit` replayed
        // mid-`attachAndReplay`, or the poll loop's own error handler) routes
        // through here, so this is the one place that reliably knows the
        // connection is dead — including the startup-exit ordering where
        // `attachAndReplay()` inside `start()` replays `adapter/exit` and
        // calls this *before* `start()` reaches `startBackgroundPolling()`.
        // Without this flag, `startBackgroundPolling()` would still create a
        // fresh poller for the already-dead connection, since the exit
        // handler's own `cancelBackgroundPolling()` call has nothing to
        // cancel yet at that point.
        stateLock.lock()
        isTerminated = true
        stateLock.unlock()
        updatesCont.finish()
        permsCont.finish()
        questionsCont.finish()
        elicitationsCont.finish()
        elicitationCompletionsCont.finish()
        filesCont.finish()
        terminalsCont.finish()
    }

    @discardableResult
    private func attachAndReplay() async throws -> ACPBrokerSnapshot {
        let generation = try currentGeneration()
        let cursor = currentAcknowledgedCursor()
        let attached = try await service.attach(ACPBrokerAttachParams(
            brokerId: brokerId,
            generation: generation,
            acknowledgedCursor: cursor
        ))
        setSnapshot(attached.snapshot)
        let pendingRequestIds = Set(attached.snapshot.pendingRequests.map(\.requestId))
        for event in attached.events {
            dispatch(event, pendingRequestIds: pendingRequestIds)
        }
        for request in attached.snapshot.pendingRequests {
            dispatchPendingRequest(request, cursor: attached.snapshot.acknowledgedCursor)
        }
        return attached.snapshot
    }

    /// Runs for the whole connection lifetime (`start()` through
    /// `shutdown()`/`detach()`), not just while a turn is active — see the
    /// doc comment on `defaultBackgroundPollIdleIntervalNanoseconds` for why
    /// a poll-only-while-active loop isn't enough. Idempotent: a second call
    /// while a loop is already running is a no-op.
    private func startBackgroundPolling() {
        stateLock.lock()
        if isTerminated || backgroundPollingTask != nil {
            stateLock.unlock()
            return
        }
        backgroundPollingTask = Task { [weak self] in
            await self?.runBackgroundPolling()
        }
        stateLock.unlock()
    }

    private func runBackgroundPolling() async {
        defer { clearBackgroundPollingTask() }
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: currentBackgroundPollIntervalNanoseconds())
                _ = try await attachAndReplay()
            } catch is CancellationError {
                return
            } catch {
                finishStreams()
                return
            }
        }
    }

    private func currentBackgroundPollIntervalNanoseconds() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return turnState.needsActiveTurnPolling
            ? backgroundPollActiveIntervalNanoseconds
            : backgroundPollIdleIntervalNanoseconds
    }

    private func cancelBackgroundPolling() {
        stateLock.lock()
        let task = backgroundPollingTask
        backgroundPollingTask = nil
        stateLock.unlock()
        task?.cancel()
    }

    private func clearBackgroundPollingTask() {
        stateLock.lock()
        backgroundPollingTask = nil
        stateLock.unlock()
    }

    private func dispatch(_ event: ACPBrokerEvent, pendingRequestIds: Set<String>? = nil) {
        stateLock.lock()
        if dispatchedEventCursors.contains(event.cursor) {
            stateLock.unlock()
            return
        }
        dispatchedEventCursors.insert(event.cursor)
        stateLock.unlock()

        switch event.kind {
        case .adapterNotification(let method, let params):
            dispatchAdapterNotification(method: method, params: params, cursor: event.cursor)
        case .pendingRequest(let request):
            if let pendingRequestIds, !pendingRequestIds.contains(request.requestId) {
                return
            }
            dispatchPendingRequest(request, cursor: event.cursor)
        case .operationCompleted(let operationKey, _):
            stateLock.lock()
            operationCompletionCursors[operationKey] = event.cursor
            stateLock.unlock()
        case .turnStateChanged(let state):
            setTurnState(state)
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
            unacknowledgedDurableEventCursors.insert(cursor)
            stateLock.unlock()
            updatesCont.yield(.init(
                sessionId: decoded.sessionId,
                update: decoded.update,
                durableConsumptionAcknowledgement: { [weak self] in
                    self?.ackDurableEvent(cursor: cursor)
                }
            ))
        case "elicitation/complete":
            if let decoded = try? JSONDecoder().decode(ACPElicitationCompleteParams.self, from: params.data) {
                elicitationCompletionsCont.yield(decoded)
            }
        case "adapter/exit":
            cancelBackgroundPolling()
            finishStreams()
        default:
            break
        }
    }

    private func dispatchPendingRequest(_ request: ACPBrokerPendingRequest, cursor: ACPBrokerEventCursor) {
        guard let id = request.adapterRequestId.jsonRPCID else { return }
        stateLock.lock()
        if pendingInboundCursors[id] != nil {
            stateLock.unlock()
            return
        }
        pendingInboundCursors[id] = cursor
        stateLock.unlock()

        switch request.kind {
        case .permission:
            let payload = pendingRequestParamsPayload(request.payload)
            if let params = try? JSONDecoder().decode(ACPPermissionRequestParams.self, from: payload.data) {
                permsCont.yield((id, params))
            }
        case .question:
            let payload = pendingRequestParamsPayload(request.payload)
            if let params = try? JSONDecoder().decode(ACPQuestionRequestParams.self, from: payload.data) {
                questionsCont.yield(.init(id: id, params: params))
            }
        case .elicitation:
            let payload = pendingRequestParamsPayload(request.payload)
            if let params = try? JSONDecoder().decode(ACPElicitationRequestParams.self, from: payload.data) {
                elicitationsCont.yield(.init(id: id, params: params))
            }
        case .file:
            dispatchFileRequest(id: id, payload: request.payload)
        case .terminal:
            dispatchTerminalRequest(id: id, payload: request.payload)
        }
    }

    private func pendingRequestParamsPayload(_ payload: ACPBrokerJSONValue) -> ACPBrokerJSONValue {
        guard
            case .object(let object) = payload,
            object["method"] != nil,
            let params = object["params"]
        else {
            return payload
        }
        return params
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
                try await self.respond(id: id, result: ACPBrokerJSONValue(encodable: value), error: nil)
            } catch {}
        }
    }

    private func respondToRawResult(id: JSONRPCID, result: Result<Data, JSONRPCError>) {
        Task { [weak self] in
            guard let self else { return }
            do {
                switch result {
                case .success(let data):
                    try await self.respond(id: id, result: ACPBrokerJSONValue(data: data), error: nil)
                case .failure(let error):
                    try await self.respond(id: id, result: nil, error: error)
                }
            } catch {}
        }
    }

    private func respond(id: JSONRPCID, error: JSONRPCError) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.respond(id: id, result: nil, error: error)
            } catch {}
        }
    }

    private func respond(id: JSONRPCID, result: ACPBrokerJSONValue?, error: JSONRPCError?) async throws {
        let generation = try currentGeneration()
        _ = try await service.respond(ACPBrokerRespondParams(
            brokerId: brokerId,
            generation: generation,
            requestId: ACPBrokerJSONValue(jsonRPCID: id),
            operationKey: nextOperationKey(method: "respond"),
            result: result,
            error: error
        ))
        stateLock.lock()
        let cursor = pendingInboundCursors.removeValue(forKey: id)
        stateLock.unlock()
        if let cursor {
            ackAfterEarlierDurableEvents(cursor: cursor)
        }
    }

    private func ack(cursor: ACPBrokerEventCursor) {
        Task { [weak self] in
            guard let self, let generation = try? self.currentGeneration() else { return }
            do {
                _ = try await self.service.ack(ACPBrokerAckParams(
                    brokerId: self.brokerId,
                    generation: generation,
                    cursor: cursor
                ))
            } catch {
                return
            }
            self.stateLock.lock()
            self.acknowledgedCursor = max(self.acknowledgedCursor, cursor)
            let shouldDrainDurableStates = self.enqueueDurableStateLocked()
            self.stateLock.unlock()
            if shouldDrainDurableStates {
                self.drainDurableStateCallbacks()
            }
            self.flushDeferredOrderedAcks()
        }
    }

    private func ackDurableEvent(cursor: ACPBrokerEventCursor) {
        stateLock.lock()
        unacknowledgedDurableEventCursors.remove(cursor)
        stateLock.unlock()
        ackAfterEarlierDurableEvents(cursor: cursor)
    }

    private func ackResponse(cursor: ACPBrokerEventCursor) {
        stateLock.lock()
        unacknowledgedDurableEventCursors.remove(cursor)
        stateLock.unlock()
        ackAfterEarlierDurableEvents(cursor: cursor)
    }

    private func trackDeferredResponse(cursor: ACPBrokerEventCursor) {
        stateLock.lock()
        unacknowledgedDurableEventCursors.insert(cursor)
        stateLock.unlock()
    }

    private func ackAfterEarlierDurableEvents(cursor: ACPBrokerEventCursor) {
        stateLock.lock()
        let shouldDefer = unacknowledgedDurableEventCursors.contains(where: { $0 < cursor })
        if shouldDefer {
            deferredOrderedAckCursors.insert(cursor)
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        ack(cursor: cursor)
    }

    private func flushDeferredOrderedAcks() {
        let ready: [ACPBrokerEventCursor]
        stateLock.lock()
        ready = deferredOrderedAckCursors
            .filter { cursor in !unacknowledgedDurableEventCursors.contains(where: { $0 < cursor }) }
            .sorted()
        for cursor in ready {
            deferredOrderedAckCursors.remove(cursor)
        }
        stateLock.unlock()
        for cursor in ready {
            ack(cursor: cursor)
        }
    }

    private func setSnapshot(_ snapshot: ACPBrokerSnapshot) {
        let changedTurnState: ACPBrokerTurnState?
        stateLock.lock()
        generation = snapshot.metadata.generation
        acknowledgedCursor = max(acknowledgedCursor, snapshot.acknowledgedCursor)
        initializeResult = snapshot.initializeResult ?? initializeResult
        remoteSessionResult = snapshot.remoteSessionResult ?? remoteSessionResult
        for operation in snapshot.operations {
            let id = operation.adapterRequestId.jsonRPCID
            if operation.terminalOutcome == nil {
                pendingOutboundRequestIds.insert(id)
            } else {
                pendingOutboundRequestIds.remove(id)
            }
        }
        if turnState != snapshot.turnState {
            turnState = snapshot.turnState
            changedTurnState = snapshot.turnState
        } else {
            changedTurnState = nil
        }
        let shouldDrainDurableStates = enqueueDurableStateLocked()
        stateLock.unlock()
        if shouldDrainDurableStates {
            drainDurableStateCallbacks()
        }
        if let changedTurnState {
            onTurnStateChanged?(changedTurnState)
        }
    }

    private func setTurnState(_ state: ACPBrokerTurnState) {
        stateLock.lock()
        guard turnState != state else {
            stateLock.unlock()
            return
        }
        turnState = state
        stateLock.unlock()
        onTurnStateChanged?(state)
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

    private func resetAcknowledgedCursor() {
        stateLock.lock()
        acknowledgedCursor = ACPBrokerEventCursor(rawValue: 0)
        stateLock.unlock()
    }

    private func enqueueDurableStateLocked() -> Bool {
        guard let state = durableStateLocked(),
              state != lastQueuedDurableState else {
            return false
        }
        lastQueuedDurableState = state
        pendingDurableStates.append(state)
        guard !isDrainingDurableStates else {
            return false
        }
        isDrainingDurableStates = true
        return true
    }

    private func drainDurableStateCallbacks() {
        while true {
            stateLock.lock()
            guard !pendingDurableStates.isEmpty else {
                isDrainingDurableStates = false
                stateLock.unlock()
                return
            }
            let state = pendingDurableStates.removeFirst()
            stateLock.unlock()
            onDurableStateChanged?(state)
        }
    }

    private func currentOperationCompletionCursor(for operationKey: ACPBrokerOperationKey) -> ACPBrokerEventCursor? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operationCompletionCursors[operationKey]
    }

    private func markPendingOutboundRequest(id: JSONRPCID) {
        stateLock.lock()
        pendingOutboundRequestIds.insert(id)
        stateLock.unlock()
    }

    private func clearPendingOutboundRequest(id: JSONRPCID) {
        stateLock.lock()
        pendingOutboundRequestIds.remove(id)
        stateLock.unlock()
    }

    private func nextOperationKey(method: String) -> ACPBrokerOperationKey {
        stateLock.lock()
        defer { stateLock.unlock() }
        nextOperationIndex += 1
        return ACPBrokerOperationKey(rawValue: "\(operationKeyPrefix):\(nextOperationIndex):\(method)")
    }

    private func cachedResponse(for method: String) -> ACPBrokerJSONValue? {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch method {
        case "initialize":
            return initializeResult
        case "session/new", "session/load", "session/resume":
            return remoteSessionResult
        default:
            return nil
        }
    }

    private func durableStateLocked() -> ACPBrokerDurableState? {
        guard let generation else { return nil }
        return ACPBrokerDurableState(
            brokerId: brokerId,
            generation: generation,
            acknowledgedCursor: acknowledgedCursor
        )
    }
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

private extension ACPBrokerTurnState {
    var needsActiveTurnPolling: Bool {
        switch self {
        case .sending, .streaming, .awaitingInput, .cancelling:
            return true
        case .idle, .completed, .ambiguous, .unknown:
            return false
        }
    }
}

private extension ACPBrokerAdapterRequestID {
    var jsonRPCID: JSONRPCID {
        .number(Int(rawValue))
    }
}

extension ACPBrokerJSONValue {
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
        case let value as NSNumber:
            // `JSONSerialization` boxes every JSON number *and* boolean as an
            // `NSNumber`. Bridging that to `Bool` (`as Bool`) succeeds for any
            // value equal to 0 or 1, so an integer `1` — e.g. `initialize`'s
            // `protocolVersion` — would be misread as `true`. JSON booleans are
            // backed by `CFBoolean`, which has a distinct `CFTypeID`; use it to
            // tell real booleans apart from numbers before mapping.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
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

    init(jsonRPCID: JSONRPCID) {
        switch jsonRPCID {
        case .number(let value):
            self = .number(Double(value))
        case .string(let value):
            self = .string(value)
        }
    }
}
