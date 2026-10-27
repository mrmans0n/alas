import Foundation
import Testing
import AlasCore
@testable import AlasACP

struct ACPBrokerRawClientTests {
    @Test func rawReplayRequiresExplicitOrderedConsumptionAndFencesDetachedCallbacks() async throws {
        let service = RawBrokerFixture()
        let client = makeClient(service)
        _ = try await client.start()
        var updates = client.incomingV2Updates.makeAsyncIterator()
        let first = try #require(await updates.next())
        let second = try #require(await updates.next())
        #expect(first.frame == RawBrokerFixture.first)
        #expect(first.brokerProvenance?.cursor.rawValue == 1)
        #expect(client.currentTurnState == .unknown("unknown"))
        second.acknowledgeDurableConsumption()
        try await client.replayRawBrokerEvents()
        #expect(await service.acks.isEmpty)
        first.acknowledgeDurableConsumption()
        try await client.replayRawBrokerEvents()
        #expect(await service.acks.last == 2)
        await client.detach()
        first.acknowledgeDurableConsumption()
        try await client.replayRawBrokerEvents()
        #expect(await service.acks == [2])
    }

    @Test(arguments: [ACPBrokerWireContext.legacyV1, .rawV2])
    func mismatchedOpenCannotCloseOrAcknowledgeAnotherContext(context: ACPBrokerWireContext) async throws {
        let service = RawBrokerFixture(context: context == .rawV2 ? .legacyV1 : .rawV2)
        let client = makeClient(service, context: context)
        await #expect(throws: (any Error).self) { try await client.start() }
        #expect(await service.closeCount == 0)
        #expect(await service.acks.isEmpty)
        await client.shutdown()
        #expect(await service.closeCount == 0)
    }

    @Test(arguments: [false, true])
    func operationOutcomesRetainSourceAndDoNotCompleteOrConsumeTheTurn(isError: Bool) async throws {
        let service = RawBrokerFixture(isError: isError)
        let client = makeClient(service)
        _ = try await client.start()
        let request = ACPRequest(method: "session/prompt", brokerOperationKey: "key")
        if isError {
            do { _ = try await client.send(request)
            Issue.record("Expected raw error") }
            catch let error as ACPBrokerRawRPCError {
                #expect(error.frame.bytes == RawBrokerFixture.error)
                #expect(error.rpcError?.message == "rejected")
                #expect(ACPCodexHookReviewError.classify(error) == .required)
                error.acknowledgeDurableConsumption()
                error.acknowledgeDurableConsumption()
            }
        } else {
            let result = try await client.send(request)
            #expect(result.body == Data("null".utf8))
            #expect(await service.acks.isEmpty)
            result.acknowledgeDurableConsumption()
            result.acknowledgeDurableConsumption()
        }
        try await client.replayRawBrokerEvents()
        #expect(await service.acks.isEmpty) // Earlier raw updates still block this outcome.
        #expect(client.currentTurnState == .unknown("unknown"))
        await client.detach()
    }

    @Test func pendingSnapshotRetainsItsRealOriginWithoutDuplicateAuthority() async throws {
        let service = RawBrokerFixture(pending: true)
        let client = makeClient(service)
        _ = try await client.start()
        try await client.replayRawBrokerEvents()
        #expect(await service.acks.isEmpty)
        await client.detach()
        var deliveries: [ACPBrokerRawFrameDelivery] = []
        for await frame in client.incomingRawFrames { deliveries.append(frame) }
        let delivery = try #require(deliveries.first)
        #expect(deliveries.count == 1)
        #expect(delivery.provenance.cursor.rawValue == 1)
        #expect(delivery.provenance.origin == .pendingSnapshot)
        #expect(delivery.pendingRequestID == "p")
        delivery.acknowledgeDurableConsumption()
        try await client.replayRawBrokerEvents()
        #expect(await service.acks.isEmpty)
    }

    @Test(arguments: [false, true])
    func lateOpenCleanupRequiresValidatedContext(mismatch: Bool) async throws {
        let service = RawBrokerFixture(context: mismatch ? .legacyV1 : .rawV2, delayOpen: true)
        let client = makeClient(service)
        let opening = Task { try await client.start() }
        try await eventually { await service.openCount == 1 }
        await client.shutdown()
        await service.releaseOpen()
        do { _ = try await opening.value
        Issue.record("Expected cancelled open") } catch {}
        #expect(await service.closeCount == (mismatch ? 0 : 1))
    }

    @Test func cachedResponsesKeepOpaqueNumbersWithoutMintingConsumptionAuthority() async throws {
        let service = RawBrokerFixture(cached: true)
        let client = makeClient(service)
        _ = try await client.start()
        let response = try await client.send(ACPRequest(method: "initialize"))
        #expect(response.body == Data(#"{"n":1e999}"#.utf8))
        #expect(response.durableConsumptionAcknowledgement == nil)
        #expect(await service.outcome == nil)
        await client.detach()
    }

    @Test(arguments: [Data([255, 0]), Data(#"{"x":0,"x":1}"#.utf8), Data("{unfinished".utf8)])
    func diagnosticFramesRemainExactAndUnconsumed(bytes: Data) async throws {
        let service = RawBrokerFixture(rawBytes: bytes)
        let client = makeClient(service)
        _ = try await client.start()
        await client.detach()
        var frames: [ACPBrokerRawFrameDelivery] = []
        for await frame in client.incomingRawFrames { frames.append(frame) }
        #expect(frames.count == 2)
        #expect(frames.allSatisfy { $0.frame == bytes && $0.provenance.origin == .journal })
        #expect(await service.acks.isEmpty)
    }

    @Test func consumedReplayAuthorityCannotReappearOrRemoveANewerSameKeyOutcome() async throws {
        let service = RawBrokerFixture()
        let initial = rawOutcome(result: "null")
        await service.preloadOutcome(initial, cursor: 3)
        let client = makeClient(service)
        client.preRegisterAwaitedOperationKeys(["key"])
        _ = try await client.start()
        let old = try #require(client.replayedCompletion(forPreRegisteredOperationKey: "key"))
        old.acknowledgeDurableConsumption()
        try await client.replayRawBrokerEvents()
        #expect(client.replayedCompletion(forPreRegisteredOperationKey: "key") == nil)
        #expect(client.terminalOutcome(forPreRegisteredOperationKey: "key") == nil)
        let newer = rawOutcome(result: #"{"new":1e999}"#)
        await service.preloadOutcome(newer, cursor: 4)
        client.preRegisterAwaitedOperationKeys(["key"])
        try await client.replayRawBrokerEvents()
        old.acknowledgeDurableConsumption()
        #expect(client.terminalOutcome(forPreRegisteredOperationKey: "key") == newer)
        await client.detach()
    }

    @Test func hookRejectionIsFactualEvidenceWithoutTerminalRecoveryAuthority() async throws {
        let service = RawBrokerFixture(isError: true)
        var rejection = ACPBrokerRPCOutcome(result: nil, error: JSONRPCError(code: -32044, message: "rejected", data: AnyCodable(["kind": "codex_hook_review_required"])))
        rejection.rawFrame = .init(bytes: RawBrokerFixture.error)
        await service.preloadOutcome(rejection, cursor: 3)
        let client = makeClient(service)
        client.preRegisterAwaitedOperationKeys(["key"])
        _ = try await client.start()
        #expect(client.terminalOutcome(forPreRegisteredOperationKey: "key") == nil)
        #expect(client.replayedCompletion(forPreRegisteredOperationKey: "key") == nil)
        do { _ = try await client.send(ACPRequest(method: "session/prompt", brokerOperationKey: "key")) }
        catch let error as ACPBrokerRawRPCError { error.acknowledgeDurableConsumption() }
        try await client.replayRawBrokerEvents()
        #expect(client.terminalOutcome(forPreRegisteredOperationKey: "key") == nil)
        await client.detach()
    }

    @Test func validatedInitialStateExportsContextWithoutConsumingEvidence() async throws {
        let service = RawBrokerFixture()
        let captured = NSLockState<ACPBrokerDurableState?>(nil)
        let client = ACPBrokerClient(service: service, brokerId: .init(rawValue: "raw"), sessionId: "s",
            command: "fixture", args: [], cwd: "/tmp", env: [:], operationKeyPrefix: "test",
            onDurableStateChanged: { state in captured.update { $0 = state } }, wireContext: .rawV2)
        _ = try await client.start()
        #expect(captured.read()?.generation.rawValue == 7)
        #expect(captured.read()?.wireContext == .rawV2)
        #expect(captured.read()?.acknowledgedCursor.rawValue == 0)
        #expect(await service.acks.isEmpty)
        await client.detach()
    }

    private func rawOutcome(result: String) -> ACPBrokerRPCOutcome {
        var outcome = ACPBrokerRPCOutcome(result: nil, error: nil)
        outcome.rawFrame = .init(bytes: Data((#"{"jsonrpc":"2.0","id":9,"result":"# + result + "}").utf8))
        return outcome
    }

    @Test func oldHookResponseCannotConsumeNewerSameKeyCompletion() async throws {
        let service = RawBrokerFixture(isError: true, replaceHookDuringSend: true)
        var rejection = ACPBrokerRPCOutcome(result: nil, error: JSONRPCError(code: -32044, message: "rejected", data: AnyCodable(["kind": "codex_hook_review_required"])))
        rejection.rawFrame = .init(bytes: RawBrokerFixture.error)
        await service.preloadOutcome(rejection, cursor: 3)
        let client = makeClient(service)
        client.preRegisterAwaitedOperationKeys(["key"])
        _ = try await client.start()
        do { _ = try await client.send(ACPRequest(method: "session/prompt", brokerOperationKey: "key")) }
        catch let error as ACPBrokerRawRPCError { error.acknowledgeDurableConsumption() }
        try await client.replayRawBrokerEvents()
        #expect(client.terminalOutcome(forPreRegisteredOperationKey: "key")?.rawFrame?.bytes == Data(#"{"jsonrpc":"2.0","id":10,"result":null}"#.utf8))
        await client.detach()
    }

    @Test func acknowledgedButUnansweredRequestRestoresWithoutNewConsumptionAuthority() async throws {
        let service = RawBrokerFixture(pending: true)
        let original = makeClient(service)
        _ = try await original.start()
        var requests = original.incomingRawFrames.makeAsyncIterator()
        let request = try #require(await requests.next())
        request.acknowledgeDurableConsumption()
        try await original.replayRawBrokerEvents()
        try await eventually { await service.acks.last == 1 }
        await original.detach()
        let restored = ACPBrokerClient(service: service, brokerId: .init(rawValue: "raw"), sessionId: "s",
            command: "fixture", args: [], cwd: "/tmp", env: [:], operationKeyPrefix: "restored",
            initialBrokerGeneration: .init(rawValue: 7), initialAcknowledgedCursor: .init(rawValue: 1), wireContext: .rawV2)
        _ = try await restored.start()
        try await restored.replayRawBrokerEvents()
        var updates = restored.incomingV2Updates.makeAsyncIterator()
        let update = try #require(await updates.next())
        update.acknowledgeDurableConsumption()
        try await restored.replayRawBrokerEvents()
        try await eventually { await service.acks.last == 2 }
        await restored.detach()
        var recovered: [ACPBrokerRawFrameDelivery] = []
        for await frame in restored.incomingRawFrames { recovered.append(frame) }
        #expect(recovered.count == 1)
        if let frame = recovered.first {
            #expect(frame.frame == request.frame)
            #expect(frame.pendingRequestID == "p")
            #expect(frame.provenance.cursor.rawValue == 1)
            #expect(frame.provenance.origin == .pendingSnapshot)
            frame.acknowledgeDurableConsumption()
        }
        #expect(await service.acks == [1, 2])
    }

    @Test func consumedCompletionReleasesSourceBytesWhileTransportRemainsAlive() async throws {
        let service = RawBrokerFixture()
        let released = NSLockState(false)
        await service.preloadTrackedOutcome { released.update { $0 = true } }
        let client = makeClient(service)
        client.preRegisterAwaitedOperationKeys(["key"])
        _ = try await client.start()
        #expect(!released.read())
        client.replayedCompletion(forPreRegisteredOperationKey: "key")?.acknowledgeDurableConsumption()
        await service.clearOutcome()
        try await client.replayRawBrokerEvents()
        try await eventually(within: .seconds(1)) { released.read() }
        #expect(client.currentBrokerGeneration?.rawValue == 7)
        await client.detach()
    }

    @Test func consumedCompletionCanStillCorrelateALaterBrokerReplay() async throws {
        let service = RawBrokerFixture()
        await service.preloadOutcome(rawOutcome(result: "null"), cursor: 3)
        let client = makeClient(service)
        client.preRegisterAwaitedOperationKeys(["key"])
        _ = try await client.start()
        client.replayedCompletion(forPreRegisteredOperationKey: "key")?.acknowledgeDurableConsumption()
        try await client.replayRawBrokerEvents()
        let replayed = try await client.send(ACPRequest(method: "session/prompt", brokerOperationKey: "key"))
        #expect(replayed.body == Data("null".utf8))
        #expect(client.terminalOutcome(forPreRegisteredOperationKey: "key") == nil)
        #expect(await service.acks.isEmpty)
        await client.detach()
    }

    @Test(arguments: [false, true])
    func terminalResponseReplaysBeyondAnOlderInFlightPoll(isError: Bool) async throws {
        let service = RawBrokerFixture(isError: isError)
        let joined = AsyncStream<Void>.makeStream()
        var params = ACPBrokerOpenParams(brokerId: .init(rawValue: "raw"), sessionId: "s", command: "fixture", args: [], cwd: "/tmp", env: [:])
        params.wireContext = .rawV2
        let transport = ACPRawBrokerTransport(service: service, params: params, prefix: "test",
            acknowledged: .init(rawValue: 0), pollInterval: 60_000_000_000, durable: nil,
            onReplayJoinedForTesting: { joined.continuation.yield(()) })
        _ = try await transport.start()
        await service.holdNextAttach()
        let poll = Task { try await transport.replay() }
        await service.waitForHeldAttach()
        let sending = Task {
            try await transport.send(method: "session/prompt", params: .null, operationKey: "key", before: { _ in }, handoff: {})
        }
        var joins = joined.stream.makeAsyncIterator()
        _ = await joins.next()
        await service.releaseHeldAttach()
        try await poll.value
        do {
            let response = try await sending.value
            #expect(!isError)
            #expect(response.body == Data("null".utf8))
        } catch let error as ACPBrokerRawRPCError {
            #expect(isError)
            #expect(error.frame.bytes == RawBrokerFixture.error)
            #expect(ACPCodexHookReviewError.classify(error) == .required)
        } catch {
            await transport.stop(close: false)
            throw error
        }
        #expect(await service.acks.isEmpty)
        await transport.stop(close: false)
    }

    private func makeClient(_ service: RawBrokerFixture, context: ACPBrokerWireContext = .rawV2) -> ACPBrokerClient {
        ACPBrokerClient(service: service, brokerId: .init(rawValue: "raw"), sessionId: "s",
            command: "fixture", args: [], cwd: "/tmp", env: [:], operationKeyPrefix: "test",
            wireContext: context)
    }
}

private actor RawBrokerFixture: ACPBrokerServicing {
    static let first = Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"opaque":1e999}}"#.utf8)
    static let error = Data(#"{"jsonrpc":"2.0","id":9,"error":{"code":-32044,"message":"rejected","data":{"kind":"codex_hook_review_required","opaque":1e999}}}"#.utf8)
    private var shouldHoldAttach = false
    private let capturedAttach = AsyncStream<Void>.makeStream()
    private let releaseAttach = AsyncStream<Void>.makeStream()
    func holdNextAttach() { shouldHoldAttach = true }
    func waitForHeldAttach() async { var events = capturedAttach.stream.makeAsyncIterator()
    _ = await events.next() }
    func releaseHeldAttach() { releaseAttach.continuation.yield(()) }
    let replaceHookDuringSend: Bool
    let rawBytes: Data
    let cached: Bool
    let delayOpen: Bool
    var openCount = 0
    private let openGate = AsyncStream<Void>.makeStream()
    func releaseOpen() { openGate.continuation.yield(()) }
    let pending: Bool
    let isError: Bool
    var completionCursor: UInt64 = 3
    func preloadOutcome(_ value: ACPBrokerRPCOutcome, cursor: UInt64) { outcome = value
    completionCursor = cursor }
    var outcome: ACPBrokerRPCOutcome?
    let context: ACPBrokerWireContext
    var acks: [UInt64] = []
    var closeCount = 0
    init(context: ACPBrokerWireContext = .rawV2, isError: Bool = false, pending: Bool = false, cached: Bool = false, delayOpen: Bool = false, rawBytes: Data = RawBrokerFixture.first, replaceHookDuringSend: Bool = false) {
        self.context = context
        self.isError = isError
        self.pending = pending
        self.cached = cached
        self.delayOpen = delayOpen
        self.rawBytes = rawBytes
        self.replaceHookDuringSend = replaceHookDuringSend
    }
    func clearOutcome() { outcome = nil }
    func preloadTrackedOutcome(onRelease: @escaping @Sendable () -> Void) {
        let source = Data((#"{"jsonrpc":"2.0","id":9,"result":{"padding":""# + String(repeating: "x", count: 2048) + #""}}"#).utf8)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: source.count, alignment: 1)
        source.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: source.count)
        let bytes = Data(bytesNoCopy: memory, count: source.count, deallocator: .custom { pointer, _ in
            pointer.deallocate()
            onRelease()
        })
        var value = ACPBrokerRPCOutcome(result: nil, error: nil)
        value.rawFrame = .init(bytes: bytes)
        outcome = value
    }
    func pendingRequest() -> ACPBrokerPendingRequest {
        var request = ACPBrokerPendingRequest(requestId: "p", adapterRequestId: .string("p"), kind: .question, payload: .null)
        request.rawFrame = .init(bytes: Data(#"{"jsonrpc":"2.0","id":"p","method":"test/request","params":{"n":1e999}}"#.utf8))
        request.originCursor = .init(rawValue: 1)
        return request
    }
    func snapshot() -> ACPBrokerSnapshot {
        var metadata = ACPBrokerMetadata(brokerId: .init(rawValue: "raw"), generation: .init(rawValue: 7),
            alasSessionId: "s", adapterProgram: "fixture", adapterArgs: [], cwd: "/tmp", envKeys: [], createdAtMillis: 0)
        metadata.wireContext = context
        var snapshot = ACPBrokerSnapshot(metadata: metadata, initializeResult: nil, remoteSessionResult: nil,
            turnState: .unknown("unknown"), acknowledgedCursor: .init(rawValue: acks.last ?? 0),
            journalTail: .init(rawValue: outcome == nil ? 2 : completionCursor), pendingRequests: pending ? [pendingRequest()] : [], operations: [])
        if let outcome {
            var op = ACPBrokerOperationSnapshot(operationKey: .init(rawValue: "key"), adapterRequestId: .init(rawValue: 9), method: "session/prompt", terminalOutcome: outcome)
            op.completedCursor = .init(rawValue: completionCursor)
            snapshot = ACPBrokerSnapshot(metadata: metadata, initializeResult: nil, remoteSessionResult: nil,
                turnState: .unknown("unknown"), acknowledgedCursor: snapshot.acknowledgedCursor,
                journalTail: snapshot.journalTail, pendingRequests: snapshot.pendingRequests, operations: [op])
        }
        if cached { snapshot.initializeRawResponse = .init(bytes: Data(#"{"jsonrpc":"2.0","id":42,"result":{"n":1e999}}"#.utf8)) }
        return snapshot
    }
    func open(_ params: ACPBrokerOpenParams) async throws -> ACPBrokerOpenResult {
        openCount += 1
        if delayOpen { var gate = openGate.stream.makeAsyncIterator()
        _ = await gate.next() }
        #expect(params.wireContext == .rawV2 || params.wireContext == nil)
        return .init(snapshot: snapshot(), adopted: true)
    }
    func attach(_ params: ACPBrokerAttachParams) async -> ACPBrokerAttachResult {
        var events = (1...2).map { ACPBrokerEvent(cursor: .init(rawValue: UInt64($0)), kind: .rawFrame(.init(bytes: rawBytes))) }
            .filter { $0.cursor > (params.replayAfterCursor ?? params.acknowledgedCursor) }
        if pending, let index = events.firstIndex(where: { $0.cursor.rawValue == 1 }) {
            events[index] = .init(cursor: .init(rawValue: 1), kind: .pendingRequest(pendingRequest()))
        }
        if let outcome, (params.replayAfterCursor?.rawValue ?? 0) < completionCursor {
            events.append(.init(cursor: .init(rawValue: completionCursor), kind: .operationCompleted(operationKey: .init(rawValue: "key"), outcome: outcome)))
        }
        let result = ACPBrokerAttachResult(snapshot: snapshot(), events: events)
        if shouldHoldAttach {
            shouldHoldAttach = false
            capturedAttach.continuation.yield(())
            var release = releaseAttach.stream.makeAsyncIterator()
            _ = await release.next()
        }
        return result
    }
    func send(_ params: ACPBrokerSendParams) throws -> ACPBrokerSendResult {
        var value = ACPBrokerRPCOutcome(result: nil, error: isError ? JSONRPCError(code: -32044, message: "rejected", data: AnyCodable(["kind": "codex_hook_review_required"])) : nil)
        value.rawFrame = .init(bytes: isError ? Self.error : Data(#"{"jsonrpc":"2.0","id":9,"result":null}"#.utf8))
        outcome = value
        if replaceHookDuringSend {
            var newer = ACPBrokerRPCOutcome(result: nil, error: nil)
            newer.rawFrame = .init(bytes: Data(#"{"jsonrpc":"2.0","id":10,"result":null}"#.utf8))
            outcome = newer
            completionCursor = 4
        }
        var result = ACPBrokerSendResult(requestId: .init(rawValue: 9), replayed: false, error: value.error)
        result.rawFrame = value.rawFrame
        return result
    }
    func notify(_ params: ACPBrokerNotifyParams) -> ACPBrokerSimpleOK { .init(ok: true) }
    func respond(_ params: ACPBrokerRespondParams) -> ACPBrokerSimpleOK { .init(ok: true) }
    func ack(_ params: ACPBrokerAckParams) -> ACPBrokerSimpleOK { acks.append(params.cursor.rawValue)
    return .init(ok: true) }
    func detach(_ params: ACPBrokerDetachParams) -> ACPBrokerSimpleOK { .init(ok: true) }
    func close(_ params: ACPBrokerCloseParams) -> ACPBrokerSimpleOK { closeCount += 1
    return .init(ok: true) }
}

struct ACPBrokerRawHelperTests {
    @Test(arguments: [false, true])
    func rawNamespaceRequiresCurrentHelperCapability(supported: Bool) async throws {
        let transport = RawHelperTransport(supported: supported)
        let client = RemoteHelperClient(host: "local", idleShutdownNanoseconds: 0, transportFactory: { transport })
        var params = ACPBrokerAckParams(brokerId: .init(rawValue: "b"), generation: .init(rawValue: 1), cursor: .init(rawValue: 2))
        params.wireContext = .rawV2
        if supported {
            #expect(try await client.ackACPBroker(params).ok)
            #expect(transport.methods == ["hello", "acp/raw/ack"])
        } else {
            await #expect(throws: (any Error).self) { try await client.ackACPBroker(params) }
            #expect(transport.methods == ["hello"])
        }
        await client.shutdown()
    }
}

private final class RawHelperTransport: JSONRPCStdioTransporting, @unchecked Sendable {
    let incoming: AsyncStream<JSONRPCStdioTransport.Incoming>
    private let continuation: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation
    private let lock = NSLock()
    private var sent: [String] = []
    private let supported: Bool
    var methods: [String] { lock.lock()
    defer { lock.unlock() }
    return sent }
    init(supported: Bool) {
        self.supported = supported
        let stream = AsyncStream<JSONRPCStdioTransport.Incoming>.makeStream()
        incoming = stream.stream
        continuation = stream.continuation
    }
    func start() throws {}
    func send(_ data: Data) throws {
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let method = try #require(object["method"] as? String)
        lock.lock()
        sent.append(method)
        lock.unlock()
        let result: [String: Any]
        if method == "hello" {
            var capabilities: [String: Any] = ["watchKinds": [], "fs": ["read": true, "write": true, "stat": true], "ping": true]
            if supported { capabilities["acpRawFrames"] = 1 }
            result = ["name": "fixture", "protocolVersion": 1, "binaryVersion": "fixture", "capabilities": capabilities]
        } else { result = ["ok": true] }
        let response = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": object["id"]!, "result": result])
        continuation.yield(.frame(response))
    }
    func terminate() { continuation.finish() }
}

private final class NSLockState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func update(_ body: (inout Value) -> Void) { lock.lock()
    defer { lock.unlock() }
    body(&value) }
    func read() -> Value { lock.lock()
    defer { lock.unlock() }
    return value }
}
