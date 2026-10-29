import Foundation
import Synchronization
import AlasFoundation
import AlasPlatform
import AlasCode

public struct ACPBrokerFrameProvenance: Equatable, Sendable {
    public enum Origin: String, Sendable { case journal, pendingSnapshot }
    public let brokerID: ACPBrokerID
    public let generation: ACPBrokerGeneration
    public let cursor: ACPBrokerEventCursor
    public let origin: Origin

    public init(brokerID: ACPBrokerID, generation: ACPBrokerGeneration, cursor: ACPBrokerEventCursor, origin: Origin) {
        self.brokerID = brokerID
        self.generation = generation
        self.cursor = cursor
        self.origin = origin
    }
}

/// Opaque inbound evidence. Receipt and request resolution are independent of consumption.
public struct ACPBrokerRawFrameDelivery: Sendable {
    public let frame: Data
    public let connectionID: UUID
    public let provenance: ACPBrokerFrameProvenance
    public let pendingRequestID: String?
    private let consumption: ACPV2SessionUpdateDelivery

    init(frame: Data, connectionID: UUID, provenance: ACPBrokerFrameProvenance,
         pendingRequestID: String? = nil, acknowledgement: ACPDurableConsumptionAcknowledgement?) {
        self.frame = frame
        self.connectionID = connectionID
        self.provenance = provenance
        self.pendingRequestID = pendingRequestID
        consumption = .init(frame: frame, connectionID: connectionID, durableConsumptionAcknowledgement: acknowledgement)
    }
    public func acknowledgeDurableConsumption() { consumption.acknowledgeDurableConsumption() }
}

/// Owns only the raw transport journal, never ACP session semantics.
actor ACPRawBrokerTransport {
    struct Summary {
        var generation: ACPBrokerGeneration?
        var count = 0
        var adopted = false
        var sessionCached = false
        var consumed: Set<ACPBrokerEventCursor> = []
        var registered: Set<ACPBrokerOperationKey> = []
        var outcomes: [ACPBrokerOperationKey: (ACPBrokerRPCOutcome, ACPBrokerEventCursor?)] = [:]
    }
    final class SharedSummary: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Summary()
        func withLock<T>(_ body: (inout Summary) throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body(&storage)
        }
    }
    nonisolated static func consume(_ cursor: ACPBrokerEventCursor, state: inout Summary) {
        guard state.consumed.insert(cursor).inserted else { return }
        let matches = state.outcomes.filter { $0.value.1 == cursor }
        for (key, value) in matches {
            state.outcomes.removeValue(forKey: key)
            if value.0.error.flatMap({ ACPCodexHookReviewError.classify($0) }) == nil {
                state.registered.remove(key)
            }
        }
    }

    nonisolated let summary = SharedSummary()
    nonisolated let updates: AsyncStream<ACPV2SessionUpdateDelivery>
    nonisolated let frames: AsyncStream<ACPBrokerRawFrameDelivery>
    private let updatesCont: AsyncStream<ACPV2SessionUpdateDelivery>.Continuation
    private let framesCont: AsyncStream<ACPBrokerRawFrameDelivery>.Continuation
    nonisolated let connectionID = UUID()
    private let service: ACPBrokerServicing
    private var openParams: ACPBrokerOpenParams
    private let prefix: String
    private var generation: ACPBrokerGeneration?
    private var acknowledged: ACPBrokerEventCursor
    private var replayCursor: ACPBrokerEventCursor
    private var seen: Set<ACPBrokerEventCursor> = []
    private var protected: Set<ACPBrokerEventCursor> = []
    private var completions: [ACPBrokerOperationKey: [(outcome: ACPBrokerRPCOutcome, cursor: ACPBrokerEventCursor)]] = [:]
    private var awaiting: [ACPBrokerOperationKey: Int] = [:]
    private var initializeCache: ACPBrokerRawJSONPayload?
    private var sessionCache: ACPBrokerRawJSONPayload?
    private var terminated = false
    private var requestedClose: Bool?
    private var started = false
    private var replayTask: Task<Void, Error>?
    private var replaySequence: UInt64 = 0
    private var acknowledging = false
    private var poll: Task<Void, Never>?
    private var operationIndex = 0
    private let pollInterval: UInt64
    private let durable: (@Sendable (ACPBrokerDurableState) -> Void)?
    private let onReplayJoinedForTesting: (@Sendable () -> Void)?

    init(service: ACPBrokerServicing, params: ACPBrokerOpenParams, prefix: String,
         acknowledged: ACPBrokerEventCursor, pollInterval: UInt64,
         durable: (@Sendable (ACPBrokerDurableState) -> Void)?,
         onReplayJoinedForTesting: (@Sendable () -> Void)? = nil) {
        self.service = service
        openParams = params
        self.prefix = prefix
        self.acknowledged = acknowledged
        replayCursor = acknowledged
        self.pollInterval = pollInterval
        self.durable = durable
        self.onReplayJoinedForTesting = onReplayJoinedForTesting
        let u = AsyncStream<ACPV2SessionUpdateDelivery>.makeStream()
        updates = u.stream
        updatesCont = u.continuation
        let f = AsyncStream<ACPBrokerRawFrameDelivery>.makeStream()
        frames = f.stream
        framesCont = f.continuation
    }

    private func validate(_ snapshot: ACPBrokerSnapshot, expected: ACPBrokerGeneration?) throws {
        guard snapshot.metadata.wireContext == .rawV2,
              snapshot.metadata.brokerId == openParams.brokerId,
              expected == nil || expected == snapshot.metadata.generation,
              snapshot.initializeResult == nil, snapshot.remoteSessionResult == nil,
              snapshot.turnState == .unknown("unknown") else {
            throw ACPClientError.decoding("Raw broker context or generation mismatch; observation lost")
        }
        if let frame = snapshot.initializeRawResponse { _ = try ACPBrokerRawResponse.decode(frame) }
        if let frame = snapshot.remoteSessionRawResponse { _ = try ACPBrokerRawResponse.decode(frame) }
        for request in snapshot.pendingRequests {
            guard request.rawFrame != nil, let origin = request.originCursor,
                  origin <= snapshot.journalTail else { throw ACPClientError.decoding("Missing raw request origin") }
        }
    }

    func start() async throws -> ACPBrokerOpenResult {
        guard !terminated, !started else { throw ACPClientError.notRunning }
        started = true
        let opened = try await service.open(openParams)
        try validate(opened.snapshot, expected: openParams.expectedGeneration)
        guard !terminated else {
            await endAttachment(generation: opened.snapshot.metadata.generation, close: requestedClose ?? false)
            throw CancellationError()
        }
        generation = opened.snapshot.metadata.generation
        summary.withLock { $0.generation = generation
        $0.adopted = opened.adopted }
        durable?(.init(brokerId: openParams.brokerId, generation: opened.snapshot.metadata.generation,
            acknowledgedCursor: acknowledged, wireContext: .rawV2))
        try apply(opened.snapshot)
        try await replay()
        poll = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: pollInterval) } catch { return }
                guard let self else { return }
                do { try await self.replay() } catch { await self.loseObservation()
                return }
            }
        }
        return opened
    }

    private func apply(_ snapshot: ACPBrokerSnapshot) throws {
        try validate(snapshot, expected: generation)
        initializeCache = snapshot.initializeRawResponse
        sessionCache = snapshot.remoteSessionRawResponse
        // A later send may replay a consumed operation still retained by the
        // helper behind an earlier receipt. Borrow its source only while that
        // send needs correlation; never restore its consumed recovery authority.
        for operation in snapshot.operations where awaiting[operation.operationKey] != nil {
            if let outcome = operation.terminalOutcome, let cursor = operation.completedCursor,
               completions[operation.operationKey]?.contains(where: { $0.cursor == cursor }) != true {
                completions[operation.operationKey, default: []].append((outcome, cursor))
            }
        }
        summary.withLock { state in
            state.sessionCached = sessionCache != nil
            for op in snapshot.operations where op.terminalOutcome != nil {
                if let cursor = op.completedCursor, !state.consumed.contains(cursor) {
                    state.outcomes[op.operationKey] = (op.terminalOutcome!, cursor)
                }
            }
        }
        for pending in snapshot.pendingRequests {
            guard let frame = pending.rawFrame, let cursor = pending.originCursor,
                  !seen.contains(cursor) else { continue }
            // Snapshot receipt alone cannot consume anything. Reuse the actual journal identity.
            publish(frame, cursor: cursor, origin: .pendingSnapshot, pendingID: pending.requestId)
        }
    }

    func replay(requireFresh: Bool = false) async throws {
        if let task = replayTask {
            let joinedSequence = replaySequence
            onReplayJoinedForTesting?()
            try await task.value
            guard requireFresh else { return }
            // A terminal response cannot use a page captured before it arrived
            // as evidence that its completion provenance is missing.
            if replaySequence != joinedSequence {
                try await replay()
                return
            }
            replayTask = nil
        }
        replaySequence &+= 1
        let sequence = replaySequence
        let task = Task { try await self.performReplay() }
        replayTask = task
        defer {
            // The older poll's waiter may resume after a fresh replay starts.
            if replaySequence == sequence { replayTask = nil }
        }
        try await task.value
    }

    private func performReplay() async throws {
        try await flushAcknowledgements()
        guard !terminated, let generation else { return }
        while !terminated {
            var params = ACPBrokerAttachParams(brokerId: openParams.brokerId, generation: generation,
                acknowledgedCursor: acknowledged, replayAfterCursor: replayCursor, maxReplayBytes: 4 * 1024 * 1024,
                snapshotOnLastPageOnly: false)
            params.wireContext = .rawV2
            let page = try await service.attach(params)
            guard !terminated else { return }
            // Require the context fence on every page before publishing any event.
            guard let snapshot = page.snapshot else { throw ACPClientError.decoding("Raw replay missing context snapshot") }
            try validate(snapshot, expected: generation)
            for event in page.events.sorted(by: { $0.cursor < $1.cursor }) where event.cursor > acknowledged {
                if !seen.contains(event.cursor) { try dispatch(event) }
                replayCursor = max(replayCursor, event.cursor)
            }
            try apply(snapshot)
            try await flushAcknowledgements()
            if page.hasMoreEvents != true { return }
            guard !page.events.isEmpty else { throw ACPClientError.decoding("Raw replay made no progress") }
        }
    }

    private func dispatch(_ event: ACPBrokerEvent) throws {
        switch event.kind {
        case .rawFrame(let frame): publish(frame, cursor: event.cursor, origin: .journal)
        case .pendingRequest(let request):
            guard let frame = request.rawFrame, request.originCursor == event.cursor else {
                throw ACPClientError.decoding("Contradictory raw pending request")
            }
            publish(frame, cursor: event.cursor, origin: .journal, pendingID: request.requestId)
        case .operationCompleted(let key, let outcome):
            seen.insert(event.cursor)
            protected.insert(event.cursor)
            completions[key, default: []].append((outcome, event.cursor))
            summary.withLock { state in
                if !state.consumed.contains(event.cursor) { state.outcomes[key] = (outcome, event.cursor) }
            }
            if let frame = outcome.rawFrame {
                let registered = summary.withLock { $0.registered.contains(key) }
                if awaiting[key] == nil, !registered {
                    publish(frame, cursor: event.cursor, origin: .journal)
                }
            }
        case .adapterNotification(let method, _):
            // Factual helper status is not an adapter frame and grants no source authority.
            seen.insert(event.cursor)
            summary.withLock { $0.consumed.insert(event.cursor) }
            if method == "adapter/stdoutClosed" { updatesCont.finish()
            framesCont.finish() }
        case .operationStarted, .pendingRequestResolved:
            seen.insert(event.cursor)
            summary.withLock { $0.consumed.insert(event.cursor) }
        default: throw ACPClientError.decoding("Legacy event in raw broker journal")
        }
    }

    private struct MethodHead: Decodable { let method: String? }
    private func publish(_ frame: ACPBrokerRawJSONPayload, cursor: ACPBrokerEventCursor,
                         origin: ACPBrokerFrameProvenance.Origin, pendingID: String? = nil) {
        guard !terminated, let generation else { return }
        seen.insert(cursor)
        // A restored unresolved request may already have a durable receipt.
        // Restore its resolution identity without protecting or consuming it again.
        if cursor > acknowledged { protected.insert(cursor) }
        let provenance = ACPBrokerFrameProvenance(brokerID: openParams.brokerId, generation: generation, cursor: cursor, origin: origin)
        let ack = cursor > acknowledged ? acknowledgement(cursor) : nil
        let method: String?
        if case .object(let fields) = try? LSPJSONValue.decode(from: frame.bytes), case .string(let value)? = fields["method"] {
            method = value
        } else { method = (try? JSONDecoder().decode(MethodHead.self, from: frame.bytes))?.method }
        if method == "session/update" {
            summary.withLock { $0.count += 1 }
            updatesCont.yield(.init(frame: frame.bytes, connectionID: connectionID, brokerProvenance: provenance,
                durableConsumptionAcknowledgement: ack))
        } else {
            framesCont.yield(.init(frame: frame.bytes, connectionID: connectionID, provenance: provenance,
                pendingRequestID: pendingID, acknowledgement: ack))
        }
    }

    private func acknowledgement(_ cursor: ACPBrokerEventCursor) -> ACPDurableConsumptionAcknowledgement {
        let state = summary
        return { [weak self] in
            state.withLock { Self.consume(cursor, state: &$0) }
            Task { try? await self?.flushAcknowledgements() }
        }
    }

    private func pruneConsumedCompletions() {
        let consumed = summary.withLock { $0.consumed }
        for key in Array(completions.keys) where awaiting[key] == nil {
            completions[key]?.removeAll { consumed.contains($0.cursor) }
            if completions[key]?.isEmpty == true { completions.removeValue(forKey: key) }
        }
    }

    private func flushAcknowledgements() async throws {
        pruneConsumedCompletions()
        guard !terminated, let generation, !acknowledging else { return }
        acknowledging = true
        defer { acknowledging = false }
        while !terminated {
        let consumed = summary.withLock { $0.consumed }
        protected.subtract(consumed)
        let limit = protected.min().map { $0.rawValue - 1 } ?? replayCursor.rawValue
        let target = ACPBrokerEventCursor(rawValue: min(limit, replayCursor.rawValue))
        guard target > acknowledged else { return }
        var params = ACPBrokerAckParams(brokerId: openParams.brokerId, generation: generation, cursor: target)
        params.wireContext = .rawV2
        _ = try await service.ack(params)
        guard !terminated, self.generation == generation else { return }
        acknowledged = max(acknowledged, target)
        durable?(.init(brokerId: openParams.brokerId, generation: generation, acknowledgedCursor: acknowledged, wireContext: .rawV2))
        }
    }

    func send(method: String, params: ACPBrokerJSONValue, operationKey: String?,
              before: @Sendable (ACPBrokerGeneration?) async throws -> Void,
              handoff: @Sendable () throws -> Void) async throws -> ACPResponse {
        guard !terminated, let generation else { throw ACPClientError.notRunning }
        try await before(generation)
        guard !terminated else { throw CancellationError() }
        try handoff()
        if let cache = method == "initialize" ? initializeCache : (["session/new", "session/load", "session/resume"].contains(method) ? sessionCache : nil) {
            let decoded = try ACPBrokerRawResponse.decode(cache)
            if let error = decoded.error { throw ACPBrokerRawRPCError(frame: cache, rpcError: error) }
            return .init(body: try requireResult(decoded))
        }
        operationIndex += 1
        let key = ACPBrokerOperationKey(rawValue: operationKey ?? "\(prefix):raw:\(operationIndex):\(method)")
        awaiting[key, default: 0] += 1
        defer {
            if awaiting[key] == 1 { awaiting.removeValue(forKey: key) }
            else { awaiting[key, default: 1] -= 1 }
            pruneConsumedCompletions()
        }
        var request = ACPBrokerSendParams(brokerId: openParams.brokerId, generation: generation,
            operationKey: key, method: method, params: params)
        request.wireContext = .rawV2
        while !terminated {
            let result = try await service.send(request)
            guard !terminated else { throw CancellationError() }
            try await replay(requireFresh: result.pending != true)
            if result.pending == true { try await Task.sleep(for: .milliseconds(50))
            continue }
            // A broker-generated exit has no adapter response bytes. Preserve
            // its diagnostic without inventing a raw adapter frame.
            if result.rawFrame == nil, result.result == nil,
               let error = result.error, error.code == -32074 {
                throw ACPClientError.jsonrpc(error)
            }
            guard result.result == nil, let frame = result.rawFrame else {
                throw ACPClientError.decoding("Raw broker operation has no source response; observation lost")
            }
            let matching = completions[key]?.last { $0.outcome.rawFrame == frame && $0.outcome.error == result.error }
            let snapshotCursor = summary.withLock { state -> ACPBrokerEventCursor? in
                guard let (outcome, cursor) = state.outcomes[key], outcome.rawFrame == frame,
                      outcome.error == result.error else { return nil }
                return cursor
            }
            guard let cursor = matching?.cursor ?? snapshotCursor else {
                throw ACPClientError.decoding("Raw completion missing journal origin")
            }
            protected.insert(cursor)
            let ack = acknowledgement(cursor)
            do {
                let decoded = try ACPBrokerRawResponse.decode(frame, expectedID: result.requestId.rawValue, projectedError: result.error)
                if let error = decoded.error { throw ACPBrokerRawRPCError(frame: frame, rpcError: error, acknowledgement: ack) }
                return .init(body: try requireResult(decoded), durableConsumptionAcknowledgement: ack)
            } catch let error as ACPBrokerRawRPCError { throw error }
            catch { throw ACPBrokerRawRPCError(frame: frame, rpcError: nil, acknowledgement: ack) }
        }
        throw CancellationError()
    }
    private func requireResult(_ decoded: ACPBrokerRawResponse) throws -> Data {
        guard let result = decoded.result else { throw ACPClientError.decoding("Missing raw result") }
        return result
    }
    func notify(method: String, params: ACPBrokerJSONValue) async throws {
        guard !terminated, let generation else { throw ACPClientError.notRunning }
        var request = ACPBrokerNotifyParams(brokerId: openParams.brokerId, generation: generation, method: method, params: params)
        request.wireContext = .rawV2
        _ = try await service.notify(request)
        try await replay()
    }
    func respond(id: ACPBrokerJSONValue, result: ACPBrokerJSONValue?, error: JSONRPCError?) async throws {
        guard !terminated, let generation else { throw ACPClientError.notRunning }
        operationIndex += 1
        var request = ACPBrokerRespondParams(brokerId: openParams.brokerId, generation: generation, requestId: id,
            operationKey: .init(rawValue: "\(prefix):respond:\(operationIndex)"), result: result, error: error)
        request.wireContext = .rawV2
        _ = try await service.respond(request)
    }
    func stop(close: Bool) async {
        guard !terminated else { return }
        requestedClose = close
        loseObservation()
        guard let generation else { return }
        await endAttachment(generation: generation, close: close)
    }
    private func endAttachment(generation: ACPBrokerGeneration, close: Bool) async {
        if close {
            var params = ACPBrokerCloseParams(brokerId: openParams.brokerId, generation: generation)
            params.wireContext = .rawV2
            _ = try? await service.close(params)
        } else {
            var params = ACPBrokerDetachParams(brokerId: openParams.brokerId, generation: generation)
            params.wireContext = .rawV2
            _ = try? await service.detach(params)
        }
    }
    private func loseObservation() {
        terminated = true
        poll?.cancel()
        poll = nil
        updatesCont.finish()
        framesCont.finish()
    }
}
