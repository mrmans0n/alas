import Foundation
import Synchronization
import Testing
import AlasCore
@testable import AlasACP

struct ACPBrokerRawClientTests {
    @Test func brokerExitWithoutAdapterFrameSurfacesItsRecoveryDiagnostic() async throws {
        let diagnostic = "Bun runtime is unsupported. Please upgrade: bun upgrade"
        let rpc = JSONRPCError(code: -32074, message: "adapter stdout closed before a response was observed",
            data: AnyCodable(["stderr": diagnostic]))
        let service = RawBrokerFixture()
        await service.failWithoutSource(rpc)
        let client = makeClient(service)
        _ = try await client.start()
        do {
            _ = try await client.send(ACPRequest(method: "initialize", brokerOperationKey: "key"))
            Issue.record("Expected startup failure")
        } catch ACPClientError.jsonrpc(let error) {
            #expect(error == rpc)
        } catch {
            Issue.record("Startup diagnostics were replaced by \(error)")
        }
        await client.detach()
        var frames: [ACPBrokerRawFrameDelivery] = []
        for await frame in client.incomingRawFrames { frames.append(frame) }
        #expect(frames.allSatisfy { $0.frame == RawBrokerFixture.first })
    }

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
                let raw = try #require(error.rawDelivery)
                #expect(raw.frame == error.frame.bytes)
                #expect(raw.connectionID == client.updateConnectionID)
                #expect(raw.source == .brokerOperation(operationKey: .init(rawValue: "key"), requestID: .init(rawValue: 9), method: "session/prompt"))
                #expect(raw.brokerProvenance?.cursor.rawValue == 3)
                #expect(error.rpcError?.message == "rejected")
                #expect(ACPCodexHookReviewError.classify(error) == .required)
                error.acknowledgeDurableConsumption()
                raw.acknowledgeDurableConsumption()
                error.acknowledgeDurableConsumption()
            }
        } else {
            let result = try await client.send(request)
            #expect(result.body == Data("null".utf8))
            let raw = try #require(result.rawDelivery)
            #expect(raw.frame == Data(#"{"jsonrpc":"2.0","id":9,"result":null}"#.utf8))
            #expect(raw.connectionID == client.updateConnectionID)
            #expect(raw.source == .brokerOperation(operationKey: .init(rawValue: "key"), requestID: .init(rawValue: 9), method: "session/prompt"))
            #expect(raw.brokerProvenance?.cursor.rawValue == 3)
            #expect(await service.acks.isEmpty)
            result.acknowledgeDurableConsumption()
            raw.acknowledgeDurableConsumption()
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
        #expect(delivery.inboundDelivery.source == .broker(provenance: delivery.provenance, pendingRequestID: "p"))
        #expect(delivery.inboundDelivery.frame == delivery.frame)
        #expect(try delivery.inboundDelivery.decodeHeader().method == "test/request")
        delivery.inboundDelivery.acknowledgeDurableConsumption()
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

    @Test(arguments: [false, true])
    func cachedResponsesKeepOpaqueNumbersWithoutMintingConsumptionAuthority(isError: Bool) async throws {
        let service = RawBrokerFixture(isError: isError, cached: true)
        let client = makeClient(service)
        _ = try await client.start()
        let raw: ACPRawRPCDelivery
        if isError {
            do {
                _ = try await client.send(ACPRequest(method: "initialize"))
                Issue.record("Expected cached RPC error")
                await client.detach()
                return
            } catch let error as ACPBrokerRawRPCError {
                raw = try #require(error.rawDelivery)
                #expect(error.frame.bytes == RawBrokerFixture.error)
                #expect(ACPCodexHookReviewError.classify(error) == .required)
                error.acknowledgeDurableConsumption()
            }
        } else {
            let response = try await client.send(ACPRequest(method: "initialize"))
            #expect(response.body == Data(#"{"n":1e999}"#.utf8))
            #expect(response.durableConsumptionAcknowledgement == nil)
            raw = try #require(response.rawDelivery)
        }
        #expect(raw.source == .brokerSnapshotCache)
        #expect(raw.brokerProvenance == nil)
        #expect(try raw.decode().id == .number(isError ? "9" : "42"))
        raw.acknowledgeDurableConsumption()
        #expect(await service.acks.isEmpty)
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
        catch let error as ACPBrokerRawRPCError {
            let raw = try #require(error.rawDelivery)
            #expect(raw.brokerProvenance?.cursor.rawValue == 3)
            raw.acknowledgeDurableConsumption()
            error.acknowledgeDurableConsumption()
        }
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
        catch let error as ACPBrokerRawRPCError {
            let raw = try #require(error.rawDelivery)
            #expect(raw.brokerProvenance?.cursor.rawValue == 3)
            raw.acknowledgeDurableConsumption()
            error.acknowledgeDurableConsumption()
        }
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
            #expect(frame.inboundDelivery.source == .broker(provenance: frame.provenance, pendingRequestID: "p"))
            #expect(frame.inboundDelivery.receiptID != request.inboundDelivery.receiptID)
            frame.inboundDelivery.acknowledgeDurableConsumption()
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

    @MainActor
    @Test func orderedOwnerCanBindTheBrokerStreamBeforeReceivingAndDurablyConsumeIt() async throws {
        let bytes = Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"upstream","update":{"sessionUpdate":"agent_message_chunk","messageId":"m","content":{"type":"text","text":"x"}}}}"#.utf8)
        let service = RawBrokerFixture(rawBytes: bytes)
        let client = makeClient(service)
        let opened = try await client.start()
        let connectionID = try #require(client.updateConnectionID)
        let persistence = ACPSessionPersistence(path: FileManager.default.temporaryDirectory.appendingPathComponent("alas-v2-broker-owner-\(UUID()).sqlite").path)
        var row = ACPSessionRow(id: "s", agentId: "fixture", title: "Broker owner", autoRun: false, createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false)
        row.acpBrokerId = "raw"
        row.acpBrokerGeneration = 7
        row.acpBrokerWireContextJSON = try ACPBrokerWireContext.rawV2.persistedJSON()
        try await persistence.upsertSession(row)
        _ = try await persistence.seizeLease(sessionId: "s", instanceId: "A", pid: 1, now: 1, leaseToken: "owner")
        let owner = ACPV2SessionUpdateOwner(sessionId: "s", upstreamSessionId: "upstream",
            attachment: try .init(brokerConnectionID: connectionID, opened: opened),
            fence: .init(sessionId: "s", ownerInstance: "A", token: "owner"), journal: persistence, isCurrent: { true })
        #expect(await service.acks.isEmpty)
        _ = owner.start(client.incomingV2Updates)
        try await eventually { await MainActor.run { owner.lastAppliedOrdinal == 2 } }
        try await client.replayRawBrokerEvents()
        try await eventually { await service.acks.last == 2 }
        owner.stop()
        await client.detach()
        await owner.waitUntilFinished()
        #expect(owner.state.transcript.messages.first?.content.count == 2)
        #expect(owner.latestApplication?.source == .snapshot)
        let stream = try #require(owner.stream)
        #expect(try await persistence.loadV2UpdateJournalPage(stream: stream).records.map(\.frame) == [bytes, bytes])
    }

    @Test func preparedBrokerPromptPersistsItsExplicitKeyBeforeSending() async throws {
        let service = RawBrokerFixture()
        let client = makeClient(service)
        _ = try await client.start()
        defer { Task { await client.detach() } }
        let entered = Mutex<ACPV2PreparedPrompt?>(nil)
        let release = AsyncStream<Void>.makeStream()
        let sending = Task {
            try await client.sendV2Prompt(.init(sessionId: "upstream", prompt: [.text("x")]), operationKey: .init(rawValue: "explicit"), gate: .init()) { value in
                entered.withLock { $0 = value }
                for await _ in release.stream { break }
            }
        }
        defer { release.continuation.finish()
        sending.cancel() }
        try await eventually { entered.withLock { $0 != nil } }
        let value = try #require(entered.withLock { $0 })
        #expect(value.binding == .broker(operationKey: .init(rawValue: "explicit")))
        #expect(value.endpoint == .broker(connectionID: try #require(client.updateConnectionID), id: .init(rawValue: "raw"), generation: .init(rawValue: 7)))
        #expect(await service.sentRequests.isEmpty)
        release.continuation.yield(())
        let response = try await sending.value
        #expect(await service.sentRequests.map(\.operationKey.rawValue) == ["explicit"])
        #expect(response.rawDelivery?.source == .brokerOperation(operationKey: .init(rawValue: "explicit"), requestID: .init(rawValue: 9), method: "session/prompt"))
        await client.detach()
    }

    @MainActor
    @Test func concreteBrokerSubmissionCommitsAcceptanceBeforeItsCompletionAck() async throws {
        let update = Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"upstream","update":{"sessionUpdate":"state_update","state":"idle"}}}"#.utf8)
        let service = RawBrokerFixture(rawBytes: update, acceptedMessageID: "accepted")
        let client = makeClient(service)
        let opened = try await client.start()
        defer { Task { await client.detach() } }
        let connection = try #require(client.updateConnectionID)
        let persistence = ACPSessionPersistence(path: FileManager.default.temporaryDirectory.appendingPathComponent("alas-broker-submission-\(UUID()).sqlite").path)
        try await persistence.upsertSession(.init(id: "s", agentId: "fixture", title: "Broker", autoRun: false,
            acpBrokerId: "raw", acpBrokerGeneration: 7, acpBrokerWireContextJSON: try ACPBrokerWireContext.rawV2.persistedJSON(),
            createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false))
        _ = try await persistence.seizeLease(sessionId: "s", instanceId: "A", pid: 1, now: 1, leaseToken: "owner")
        let owner = ACPV2SessionUpdateOwner(sessionId: "s", upstreamSessionId: "upstream",
            attachment: try .init(brokerConnectionID: connection, opened: opened), fence: .init(sessionId: "s", ownerInstance: "A", token: "owner"),
            journal: persistence, submissions: .init(sender: client, journal: persistence), isCurrent: { true })
        _ = owner.start(client.incomingV2Updates)
        defer { owner.stop() }
        try await eventually { await MainActor.run { owner.status == .live } }
        let id = UUID()
        let record = try await owner.submit(id: id, localRowID: UUID(), params: .init(sessionId: "upstream", prompt: [.text("x")]), operationKey: .init(rawValue: "owned"))
        #expect(record.outcome?.source == .brokerOperation(operationKey: .init(rawValue: "owned"), requestID: .init(rawValue: 9), method: "session/prompt"))
        #expect(try await persistence.loadV2Submission(id: id) == record)
        #expect(owner.state.lifecycle.submission(record.registration.sequence) == .accepted(messageID: "accepted"))
        try await eventually { await service.acks.last == 3 }
        #expect(owner.state.lifecycle.lastForegroundCompletion == nil)
        await client.detach()
    }

    @Test(arguments: ["cancel", "detach", "invalidate"])
    func brokerPreparationInvalidationCannotDispatch(action: String) async throws {
        let service = RawBrokerFixture()
        let client = makeClient(service)
        _ = try await client.start()
        defer { Task { await client.detach() } }
        let entered = Mutex(false)
        let release = AsyncStream<Void>.makeStream()
        let gate = ACPV2PromptHandoffGate()
        let sending = Task {
            try await client.sendV2Prompt(.init(sessionId: "upstream", prompt: []), operationKey: .init(rawValue: "unused"), gate: gate) { _ in
                entered.withLock { $0 = true }
                for await _ in release.stream { break }
            }
        }
        defer { release.continuation.finish()
        sending.cancel() }
        try await eventually { entered.withLock { $0 } }
        if action == "cancel" { sending.cancel() }
        if action == "detach" { await client.detach() }
        if action == "invalidate" { gate.invalidate() }
        release.continuation.yield(())
        if case .success = await sending.result { Issue.record("Invalidated broker prompt dispatched") }
        #expect(await service.sentRequests.isEmpty)
    }

    @Test func brokerFacadeAndCommonViewShareOneReceiptAcrossConcurrencyAndReentry() async throws {
        let count = Mutex(0)
        let retained = Mutex<ACPBrokerRawFrameDelivery?>(nil)
        let provenance = ACPBrokerFrameProvenance(brokerID: .init(rawValue: "raw"), generation: .init(rawValue: 7), cursor: .init(rawValue: 3), origin: .journal)
        let bytes = Data(#"{"jsonrpc":"2.0","id":-7,"method":"peer/request","params":{"n":1e999}}"#.utf8)
        let facade = ACPBrokerRawFrameDelivery(frame: bytes, connectionID: UUID(), provenance: provenance, pendingRequestID: "opaque-helper-key",
            acknowledgement: { count.withLock { $0 += 1 }
            retained.withLock { $0 }?.acknowledgeDurableConsumption() })
        let common = facade.inboundDelivery
        retained.withLock { $0 = facade }
        #expect(common.receiptID == facade.inboundDelivery.receiptID)
        #expect(common.frame == facade.frame)
        #expect(common.connectionID == facade.connectionID)
        #expect(common.source == .broker(provenance: provenance, pendingRequestID: "opaque-helper-key"))
        #expect(try common.decodeHeader().id == .number(-7))
        #expect(facade.pendingRequestID == "opaque-helper-key")
        #expect(count.withLock { $0 } == 0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { facade.acknowledgeDurableConsumption() }
                group.addTask { common.acknowledgeDurableConsumption() }
            }
        }
        #expect(count.withLock { $0 } == 1)
        retained.withLock { $0 = nil }
    }

    @Test(arguments: [
        #"{"jsonrpc":"2.0","id":-7,"method":"peer/request","params":{"n":1e999}}"#,
        #"{"jsonrpc":"2.0","id":99,"result":{"n":1e999}}"#,
    ])
    func brokerRawEvidenceWithoutPendingMetadataCannotMintHelperIdentity(json: String) async throws {
        let bytes = Data(json.utf8)
        let service = RawBrokerFixture(rawBytes: bytes)
        let client = makeClient(service)
        _ = try await client.start()
        await client.detach()
        var frames: [ACPBrokerRawFrameDelivery] = []
        for await frame in client.incomingRawFrames { frames.append(frame) }
        #expect(frames.count == 2)
        #expect(frames.map(\.frame) == [bytes, bytes])
        #expect(frames.map(\.provenance.cursor.rawValue) == [1, 2])
        let first = try #require(frames.first)
        let last = try #require(frames.last)
        #expect(first.inboundDelivery.receiptID != last.inboundDelivery.receiptID)
        #expect(first.inboundDelivery.source == .broker(provenance: first.provenance, pendingRequestID: nil))
        if json.contains("method") { #expect(try first.inboundDelivery.decodeHeader().id == .number(-7)) }
        else { #expect(throws: (any Error).self) { try first.inboundDelivery.decodeHeader() } }
        #expect(await service.sentResponses.isEmpty)
    }

    @MainActor
    @Test func inboundReceiptOwnerUsesTheFacadeStreamAndRestoresWithoutReplyAuthority() async throws {
        let service = RawBrokerFixture(pending: true)
        let client = makeClient(service)
        let opened = try await client.start()
        defer { Task { await client.detach() } }
        let persistence = ACPSessionPersistence(path: FileManager.default.temporaryDirectory.appendingPathComponent("alas-broker-inbound-owner-\(UUID()).sqlite").path)
        try await persistence.upsertSession(.init(id: "s", agentId: "fixture", title: "Inbound", autoRun: false,
            acpBrokerId: "raw", acpBrokerGeneration: 7, acpBrokerWireContextJSON: try ACPBrokerWireContext.rawV2.persistedJSON(),
            createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false))
        let fence = ACPSessionLeaseFence(sessionId: "s", ownerInstance: "A", token: "owner")
        _ = try await persistence.seizeLease(sessionId: "s", instanceId: "A", pid: 1, now: 1, leaseToken: "owner")
        let owner = ACPV2InboundReceiptOwner(sessionId: "s", upstreamSessionId: "upstream", attachment: try .init(brokerClient: client, opened: opened),
            fence: fence, journal: persistence, isCurrent: { true })
        defer { owner.stop() }
        #expect(owner.start(client.incomingRawFrames))
        try await eventually { await MainActor.run { owner.lastRetainedOrdinal == 1 } }
        let stream = try #require(owner.stream)
        let original = try #require(try await persistence.loadV2InboundLedgerPage(stream: stream).records.first)
        #expect(owner.latestReceipt?.record == original)
        #expect(owner.latestReceipt?.origin == .inserted)
        try await client.replayRawBrokerEvents()
        try await eventually { await service.acks.last == 1 }
        owner.stop()
        await client.detach()
        await owner.waitUntilFinished()
        #expect(await service.closeCount == 0)
        #expect(await service.sentResponses.isEmpty)

        let restored = ACPBrokerClient(service: service, brokerId: .init(rawValue: "raw"), sessionId: "s", command: "fixture", args: [], cwd: "/tmp", env: [:],
            operationKeyPrefix: "restored", initialBrokerGeneration: .init(rawValue: 7), initialAcknowledgedCursor: .init(rawValue: 1), wireContext: .rawV2)
        let reopened = try await restored.start()
        defer { Task { await restored.detach() } }
        let successor = ACPV2InboundReceiptOwner(sessionId: "s", upstreamSessionId: "upstream", attachment: try .init(brokerClient: restored, opened: reopened),
            fence: fence, journal: persistence, isCurrent: { true })
        defer { successor.stop() }
        #expect(successor.start(restored.incomingRawFrames))
        try await eventually { await MainActor.run { successor.latestReceipt?.origin == .duplicate } }
        #expect(successor.lastRetainedOrdinal == 1)
        #expect(successor.latestReceipt?.record == original)
        #expect(original.connectionID != restored.updateConnectionID)
        try await restored.replayRawBrokerEvents()
        #expect(await service.acks == [1])
        #expect(await service.sentResponses.isEmpty)
        successor.stop()
        await restored.detach()
        await successor.waitUntilFinished()
        #expect(await service.closeCount == 0)
    }

    @MainActor
    @Test(arguments: ["context", "broker", "generation", "tail", "ack", "local", "v1"])
    func inboundOwnerRejectsMismatchedBrokerAttachmentMetadata(reason: String) async throws {
        let service = RawBrokerFixture()
        let client = makeClient(service)
        _ = try await client.start()
        defer { Task { await client.detach() } }
        var metadata = ACPBrokerMetadata(brokerId: .init(rawValue: reason == "broker" ? "other" : "raw"), generation: .init(rawValue: reason == "generation" ? 8 : 7),
            alasSessionId: reason == "local" ? "other" : "s", adapterProgram: "fixture", adapterArgs: [], cwd: "/tmp", envKeys: [], createdAtMillis: 0)
        metadata.wireContext = reason == "context" ? .legacyV1 : .rawV2
        let opened = ACPBrokerOpenResult(snapshot: .init(metadata: metadata, initializeResult: nil, remoteSessionResult: nil,
            turnState: .unknown("unknown"), acknowledgedCursor: .init(rawValue: reason == "ack" ? 3 : 0),
            journalTail: .init(rawValue: reason == "tail" ? .max : 2), pendingRequests: [], operations: []), adopted: true)
        if reason == "local" {
            let owner = ACPV2InboundReceiptOwner(sessionId: "s", upstreamSessionId: "upstream", attachment: try .init(brokerClient: client, opened: opened),
                fence: .init(sessionId: "s", ownerInstance: "A", token: "owner"),
                journal: ACPSessionPersistence(path: FileManager.default.temporaryDirectory.appendingPathComponent("alas-invalid-owner-\(UUID()).sqlite").path), isCurrent: { true })
            let input = AsyncStream<ACPBrokerRawFrameDelivery>.makeStream()
            input.continuation.finish()
            _ = owner.start(input.stream)
            await owner.waitUntilFinished()
            #expect(owner.status == .blocked(.invalidAttachment))
            #expect(owner.stream == nil)
        } else {
            let selected = reason == "v1" ? makeClient(service, context: .legacyV1) : client
            #expect(throws: ACPV2InboundReceiptOwner.Failure.invalidAttachment) {
                try ACPV2InboundReceiptOwner.Attachment(brokerClient: selected, opened: opened)
            }
        }
        #expect(await service.acks.isEmpty)
        #expect(await service.sentResponses.isEmpty)
        await client.detach()
    }

    @MainActor
    @Test func inboundOwnerRejectsCanonicalEquivalentPendingMetadataInCommittedProof() async throws {
        let service = RawBrokerFixture()
        let client = makeClient(service)
        let opened = try await client.start()
        defer { Task { await client.detach() } }
        let persistence = ACPSessionPersistence(path: FileManager.default.temporaryDirectory.appendingPathComponent("alas-inbound-proof-\(UUID()).sqlite").path)
        try await persistence.upsertSession(.init(id: "s", agentId: "fixture", title: "Proof", autoRun: false,
            acpBrokerId: "raw", acpBrokerGeneration: 7, acpBrokerWireContextJSON: try ACPBrokerWireContext.rawV2.persistedJSON(),
            createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false))
        let fence = ACPSessionLeaseFence(sessionId: "s", ownerInstance: "A", token: "owner")
        _ = try await persistence.seizeLease(sessionId: "s", instanceId: "A", pid: 1, now: 1, leaseToken: "owner")
        let owner = ACPV2InboundReceiptOwner(sessionId: "s", upstreamSessionId: "upstream", attachment: try .init(brokerClient: client, opened: opened),
            fence: fence, journal: InboundJournalGate(base: persistence, fault: .pending), isCurrent: { true })
        let consumed = Mutex(0)
        let input = AsyncStream<ACPBrokerRawFrameDelivery>.makeStream()
        input.continuation.yield(.init(frame: Data(), connectionID: try #require(client.updateConnectionID),
            provenance: .init(brokerID: .init(rawValue: "raw"), generation: .init(rawValue: 7), cursor: .init(rawValue: 3), origin: .journal),
            pendingRequestID: "\u{e9}", acknowledgement: { consumed.withLock { $0 += 1 } }))
        input.continuation.finish()
        _ = owner.start(input.stream)
        await owner.waitUntilFinished()
        #expect(owner.status == .blocked(.invalidProof))
        #expect(owner.lastRetainedOrdinal == 0)
        #expect(consumed.withLock { $0 } == 0)
        await client.detach()
    }

    @Test(arguments: ["written", "uncertain", "foreign", "proof", "invalid", "cancel", "legacy"])
    func exactReplyHandoffKeepsExplicitOriginAndUncertainOutcomes(reason: String) async throws {
        let service = RawBrokerFixture(context: reason == "legacy" ? .legacyV1 : .rawV2)
        let client = makeClient(service, context: reason == "legacy" ? .legacyV1 : .rawV2)
        if reason != "legacy" { _ = try await client.start() }
        defer { Task { await client.detach() } }
        await service.configureReply(fail: reason == "uncertain", wrongProof: reason == "proof")
        let params = ACPBrokerRespondExactParams(brokerId: .init(rawValue: "raw"), generation: .init(rawValue: 7),
            pendingRequestId: "p", originCursor: .init(rawValue: 1), operationKey: .init(rawValue: "explicit"),
            frame: .init(bytes: Data((reason == "invalid" ? "{}" : #" {"jsonrpc":"2.0","id":"wire","result":{"n":1e999}} "#).utf8)))
        let expected = reason == "foreign" || reason == "legacy" ? UUID() : try #require(client.updateConnectionID)
        let worker = Task {
            if reason == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
            return try await client.respondToRawRequestExact(expectedConnectionID: expected, params: params)
        }
        if reason == "written" {
            #expect(try await worker.value.status == .written)
        } else {
            do { _ = try await worker.value
            Issue.record("Expected reply handoff to fail") }
            catch let error as ACPBrokerRawReplyError {
                if reason == "uncertain" || reason == "proof" { if case .uncertain = error {} else { Issue.record("Write outcome lost its uncertainty") } }
            }
        }
        let requests = await service.exactReplies
        #expect(requests.count == (["written", "uncertain", "proof"].contains(reason) ? 1 : 0))
        if let sent = requests.first { #expect(sent.frame.bytes == params.frame.bytes)
        #expect(sent.operationKey == params.operationKey) }
        #expect(await service.sentResponses.isEmpty)
        await #expect(throws: ACPBrokerRawReplyError.rejected(.unavailable)) {
            try await client.respondToRawRequest(id: .string("wire"), result: .null)
        }
        await client.detach()
    }

    @Test(arguments: ["cancel", "detach"])
    func replyResultAfterHandoffCannotReviveInvalidatedAttachment(action: String) async throws {
        let service = RawBrokerFixture()
        let client = makeClient(service)
        _ = try await client.start()
        defer { Task { await client.detach() } }
        await service.holdReply()
        let params = ACPBrokerRespondExactParams(brokerId: .init(rawValue: "raw"), generation: .init(rawValue: 7), pendingRequestId: "p",
            originCursor: .init(rawValue: 1), operationKey: .init(rawValue: "reply"), frame: .init(bytes: Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8)))
        let connection = try #require(client.updateConnectionID)
        let worker = Task { try await client.respondToRawRequestExact(expectedConnectionID: connection, params: params) }
        defer { worker.cancel() }
        try await eventually { await service.exactReplies.count == 1 }
        if action == "cancel" { worker.cancel() } else { await client.detach() }
        await service.releaseReply()
        do { _ = try await worker.value
        Issue.record("Invalidated attachment published reply success") }
        catch let error as ACPBrokerRawReplyError { if case .uncertain = error {} else { Issue.record("Handoff became a pre-write rejection") } }
        #expect(await service.exactReplies.count == 1)
        await client.detach()
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
    let acceptedMessageID: String?
    let replaceHookDuringSend: Bool
    let rawBytes: Data
    let cached: Bool
    let delayOpen: Bool
    var exactReplies: [ACPBrokerRespondExactParams] = []
    private var shouldHoldReply = false
    private let replyRelease = AsyncStream<Void>.makeStream()
    func holdReply() { shouldHoldReply = true }
    func releaseReply() { replyRelease.continuation.yield(()) }
    private var failReply = false
    private var wrongReplyProof = false
    func configureReply(fail: Bool, wrongProof: Bool) { failReply = fail
    wrongReplyProof = wrongProof }
    func respondExact(_ params: ACPBrokerRespondExactParams) async throws -> ACPBrokerRawReplyResult {
        exactReplies.append(params)
        if shouldHoldReply { for await _ in replyRelease.stream { break } }
        if failReply { throw ACPClientError.notRunning }
        let proof = wrongReplyProof ? ACPBrokerRespondExactParams(brokerId: params.brokerId, generation: params.generation,
            pendingRequestId: params.pendingRequestId, originCursor: .init(rawValue: 99), operationKey: params.operationKey, frame: params.frame) : params
        return .init(params: proof, status: .written)
    }
    var sentResponses: [ACPBrokerRespondParams] = []
    var sentRequests: [ACPBrokerSendParams] = []
    private var lastOperationKey = ACPBrokerOperationKey(rawValue: "key")
    var openCount = 0
    private let openGate = AsyncStream<Void>.makeStream()
    func releaseOpen() { openGate.continuation.yield(()) }
    let pending: Bool
    let isError: Bool
    var completionCursor: UInt64 = 3
    func preloadOutcome(_ value: ACPBrokerRPCOutcome, cursor: UInt64) { outcome = value
    completionCursor = cursor }
    var outcome: ACPBrokerRPCOutcome?
    private var syntheticFailure: JSONRPCError?
    func failWithoutSource(_ error: JSONRPCError) { syntheticFailure = error }
    let context: ACPBrokerWireContext
    var acks: [UInt64] = []
    var closeCount = 0
    init(context: ACPBrokerWireContext = .rawV2, isError: Bool = false, pending: Bool = false, cached: Bool = false, delayOpen: Bool = false, rawBytes: Data = RawBrokerFixture.first, replaceHookDuringSend: Bool = false, acceptedMessageID: String? = nil) {
        self.acceptedMessageID = acceptedMessageID
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
            var op = ACPBrokerOperationSnapshot(operationKey: lastOperationKey, adapterRequestId: .init(rawValue: 9), method: "session/prompt", terminalOutcome: outcome)
            op.completedCursor = .init(rawValue: completionCursor)
            snapshot = ACPBrokerSnapshot(metadata: metadata, initializeResult: nil, remoteSessionResult: nil,
                turnState: .unknown("unknown"), acknowledgedCursor: snapshot.acknowledgedCursor,
                journalTail: snapshot.journalTail, pendingRequests: snapshot.pendingRequests, operations: [op])
        }
        if cached { snapshot.initializeRawResponse = .init(bytes: isError ? Self.error : Data(#"{"jsonrpc":"2.0","id":42,"result":{"n":1e999}}"#.utf8)) }
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
            events.append(.init(cursor: .init(rawValue: completionCursor), kind: .operationCompleted(operationKey: lastOperationKey, outcome: outcome)))
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
        sentRequests.append(params)
        lastOperationKey = params.operationKey
        if let syntheticFailure {
            outcome = .init(result: nil, error: syntheticFailure)
            return .init(requestId: .init(rawValue: 9), replayed: true, error: syntheticFailure)
        }
        var value = ACPBrokerRPCOutcome(result: nil, error: isError ? JSONRPCError(code: -32044, message: "rejected", data: AnyCodable(["kind": "codex_hook_review_required"])) : nil)
        value.rawFrame = .init(bytes: isError ? Self.error : Data(#"{"jsonrpc":"2.0","id":9,"result":null}"#.utf8))
        if let acceptedMessageID {
            value.rawFrame = .init(bytes: Data("{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{\"messageId\":\"\(acceptedMessageID)\"}}".utf8))
        }
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
    func respond(_ params: ACPBrokerRespondParams) -> ACPBrokerSimpleOK { sentResponses.append(params)
    return .init(ok: true) }
    func ack(_ params: ACPBrokerAckParams) -> ACPBrokerSimpleOK { acks.append(params.cursor.rawValue)
    return .init(ok: true) }
    func detach(_ params: ACPBrokerDetachParams) -> ACPBrokerSimpleOK { .init(ok: true) }
    func close(_ params: ACPBrokerCloseParams) -> ACPBrokerSimpleOK { closeCount += 1
    return .init(ok: true) }
}

struct ACPBrokerRawHelperTests {
    @Test func helperObservationEndCannotLeaveAnRPCWaitingOrInventAnExitCode() async throws {
        let transport = RawHelperTransport(supported: true, holdAck: true)
        let client = RemoteHelperClient(host: "local", idleShutdownNanoseconds: 0, transportFactory: { transport })
        _ = try await client.hello()
        let settled = Mutex(false)
        let sending = Task {
            defer { settled.withLock { $0 = true } }
            var params = ACPBrokerAckParams(brokerId: .init(rawValue: "b"), generation: .init(rawValue: 1), cursor: .init(rawValue: 1))
            params.wireContext = .rawV2
            do { _ = try await client.ackACPBroker(params)
            return false } catch { return true }
        }
        defer { sending.cancel()
        Task { await client.shutdown() } }
        try await eventually { transport.methods.contains("acp/raw/ack") }
        transport.terminate()
        try await eventually { settled.withLock { $0 } }
        #expect(await sending.value)
        #expect(await client.lastObservedExitStatus() == nil)
        await client.shutdown()
    }

    @Test(arguments: ["cancel", "replacement"])
    func capabilityWaitCannotHandoffAReplyAfterInvalidation(action: String) async throws {
        let transport = RawHelperTransport(supported: true, replies: true, holdHello: true)
        let client = RemoteHelperClient(host: "local", idleShutdownNanoseconds: 0, transportFactory: { transport })
        _ = try await client.ping()
        let params = ACPBrokerRespondExactParams(brokerId: .init(rawValue: "b"), generation: .init(rawValue: 1), pendingRequestId: "p",
            originCursor: .init(rawValue: 1), operationKey: .init(rawValue: "answer"), frame: .init(bytes: Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8)))
        let worker = Task { try await client.respondExactACPBroker(params) }
        defer { worker.cancel() }
        try await eventually { transport.methods.contains("hello") }
        if action == "cancel" { worker.cancel() } else { await client.reconnectAfterUpgrade() }
        transport.releaseHello()
        await #expect(throws: ACPBrokerRawReplyError.rejected(.unavailable)) { try await worker.value }
        #expect(transport.methods == ["ping", "hello"])
        await client.shutdown()
    }

    @Test(arguments: [false, true])
    func exactRepliesRequireTheirOwnCapabilityBeforeHandoff(supported: Bool) async throws {
        let transport = RawHelperTransport(supported: true, replies: supported)
        let client = RemoteHelperClient(host: "local", idleShutdownNanoseconds: 0, transportFactory: { transport })
        _ = try await client.hello()
        let params = ACPBrokerRespondExactParams(brokerId: .init(rawValue: "b"), generation: .init(rawValue: 1), pendingRequestId: "p",
            originCursor: .init(rawValue: 1), operationKey: .init(rawValue: "answer"), frame: .init(bytes: Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8)))
        if supported {
            #expect(try await client.respondExactACPBroker(params).status == .written)
            #expect(transport.methods == ["hello", "acp/raw/respondExact"])
        } else {
            await #expect(throws: ACPBrokerRawReplyError.rejected(.unavailable)) { try await client.respondExactACPBroker(params) }
            #expect(transport.methods == ["hello"])
        }
        await client.shutdown()
    }

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
    private let replies: Bool
    private let holdAck: Bool
    private let holdHello: Bool
    private let heldHello = Mutex<Data?>(nil)
    func releaseHello() { if let data = heldHello.withLock({ value in let data = value
    value = nil
    return data }) { continuation.yield(.frame(data)) } }
    var methods: [String] { lock.lock()
    defer { lock.unlock() }
    return sent }
    init(supported: Bool, replies: Bool = false, holdHello: Bool = false, holdAck: Bool = false) {
        self.holdAck = holdAck
        self.holdHello = holdHello
        self.replies = replies
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
        if holdAck, method == "acp/raw/ack" { return }
        let result: [String: Any]
        if method == "hello" {
            var capabilities: [String: Any] = ["watchKinds": [], "fs": ["read": true, "write": true, "stat": true], "ping": true]
            if supported { capabilities["acpRawFrames"] = 1 }
            if replies { capabilities["acpRawReplies"] = 1 }
            result = ["name": "fixture", "protocolVersion": 1, "binaryVersion": "fixture", "capabilities": capabilities]
        } else if method == "acp/raw/respondExact" {
            let params = try JSONDecoder().decode(ACPBrokerRespondExactParams.self, from: JSONSerialization.data(withJSONObject: object["params"]!))
            result = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ACPBrokerRawReplyResult(params: params, status: .written))) as? [String: Any])
        } else { result = ["ok": true] }
        let response = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": object["id"]!, "result": result])
        if method == "hello", holdHello { heldHello.withLock { $0 = response } }
        else { continuation.yield(.frame(response)) }
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
