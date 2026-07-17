import Foundation
import Testing
@testable import Alas

@MainActor
struct ACPBrokerClientTests {
    @Test func startOpensAndAttachesBroker() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [])
        let client = makeClient(
            service: service,
            initialAcknowledgedCursor: ACPBrokerEventCursor(rawValue: 4)
        )

        let opened = try await client.start()

        #expect(opened.adopted == false)
        let openParams = try await #require(service.opened.first)
        #expect(openParams.brokerId == ACPBrokerID(rawValue: "broker-1"))
        #expect(openParams.sessionId == "local-session-1")
        #expect(openParams.command == "codex-acp")
        let attachParams = try await #require(service.attached.first)
        #expect(attachParams.acknowledgedCursor == ACPBrokerEventCursor(rawValue: 4))
    }

    @Test func startPublishesDurableStateFromBrokerSnapshots() async throws {
        let service = MockBrokerService()
        let stateSink = DurableStateSink()
        await service.enqueueAttach(events: [])
        let client = makeClient(service: service) { state in
            Task { await stateSink.append(state) }
        }

        try await client.start()

        try await waitUntil { await stateSink.recordCount() >= 2 }
        let last = try await #require(stateSink.lastRecord())
        #expect(last.brokerId == ACPBrokerID(rawValue: "broker-1"))
        #expect(last.generation == ACPBrokerGeneration(rawValue: 7))
        #expect(last.acknowledgedCursor == ACPBrokerEventCursor(rawValue: 0))
    }

    @Test func startResetsInitialCursorWhenBrokerGenerationChanges() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [])
        let client = makeClient(
            service: service,
            initialBrokerGeneration: ACPBrokerGeneration(rawValue: 6),
            initialAcknowledgedCursor: ACPBrokerEventCursor(rawValue: 4)
        )

        try await client.start()

        let attachParams = try await #require(service.attached.first)
        #expect(attachParams.acknowledgedCursor == ACPBrokerEventCursor(rawValue: 0))
    }

    @Test func sendUsesBrokerOperationAndReturnsResult() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [])
        await service.enqueueAttach(events: [])
        await service.enqueueSendResult(ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: 4),
            replayed: false,
            result: .object(["stopReason": .string("end_turn")]),
            pending: nil
        ))
        let client = makeClient(service: service)
        try await client.start()

        let response = try await client.send(ACPRequest(
            method: "session/prompt",
            params: ACPSessionPromptParams(sessionId: "remote-1", prompt: [.text("hi")])
        ))

        let body = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(body["stopReason"] as? String == "end_turn")
        let sent = try await #require(service.sent.first)
        #expect(sent.operationKey == ACPBrokerOperationKey(rawValue: "op-prefix:1:session/prompt"))
        #expect(sent.method == "session/prompt")
        #expect(sent.params == .object([
            "sessionId": .string("remote-1"),
            "prompt": .array([.object([
                "type": .string("text"),
                "text": .string("hi")
            ])])
        ]))
    }

    @Test func sendUsesExplicitBrokerOperationKeyWhenProvided() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [])
        await service.enqueueAttach(events: [])
        await service.enqueueSendResult(ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: 4),
            replayed: false,
            result: .object(["stopReason": .string("end_turn")]),
            pending: nil
        ))
        let client = makeClient(service: service)
        try await client.start()

        _ = try await client.send(ACPRequest(
            method: "session/prompt",
            params: ACPSessionPromptParams(sessionId: "remote-1", prompt: [.text("queued")]),
            brokerOperationKey: "queued-prompt:item-1:0:session/prompt"
        ))

        let sent = try await #require(service.sent.first)
        #expect(sent.operationKey == ACPBrokerOperationKey(rawValue: "queued-prompt:item-1:0:session/prompt"))
    }

    @Test func adoptedHandshakeAndRemoteSessionResultsAreReplayedFromSnapshot() async throws {
        let service = MockBrokerService()
        await service.setSnapshotResults(
            initializeResult: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([
                    "loadSession": .bool(true),
                    "sessionCapabilities": .object(["load": .object([:])])
                ]),
                "authMethods": .array([])
            ]),
            remoteSessionResult: .object(["sessionId": .string("remote-restored")])
        )
        await service.enqueueAttach(events: [])
        let client = makeClient(service: service)
        try await client.start()

        let initialize = try await client.send(ACPRequest(method: "initialize"))
        let initialized = try JSONDecoder().decode(ACPInitializeResult.self, from: initialize.body)
        #expect(initialized.protocolVersion == 1)

        let session = try await client.send(ACPRequest(
            method: "session/load",
            params: ACPSessionLoadParams(cwd: "/repo", sessionId: "remote-old", mcpServers: [])
        ))
        let loaded = try JSONDecoder().decode(ACPSessionNewResult.self, from: session.body)
        #expect(loaded.sessionId == "remote-restored")
        #expect(await service.sent.isEmpty)
    }

    @Test func replayedSessionUpdateIsYieldedAndAckedAfterDurableConsumption() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [])
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 3),
                kind: .adapterNotification(
                    method: "session/update",
                    params: .object([
                        "sessionId": .string("remote-1"),
                        "update": .object([
                            "sessionUpdate": .string("agent_message_chunk"),
                            "content": .object([
                                "type": .string("text"),
                                "text": .string("hello")
                            ])
                        ])
                    ])
                )
            )
        ])
        await service.enqueueSendResult(ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: 4),
            replayed: false,
            result: .object(["stopReason": .string("end_turn")]),
            pending: nil
        ))
        let client = makeClient(service: service)
        try await client.start()

        let updateTask = Task { try await nextUpdate(from: client.incomingUpdates) }
        _ = try await client.send(ACPRequest(
            method: "session/prompt",
            params: ACPSessionPromptParams(sessionId: "remote-1", prompt: [.text("hi")])
        ))

        let update = try await updateTask.value
        #expect(client.yieldedUpdateCount == 1)
        if case .agentMessageChunk(let chunk) = update.update {
            #expect(chunk.content == .text("hello"))
        } else {
            Issue.record("expected agent message chunk")
        }
        #expect(await service.acks.isEmpty)
        update.durableConsumptionAcknowledgement?()
        try await waitUntil { await service.acks.map(\.cursor) == [ACPBrokerEventCursor(rawValue: 3)] }
    }

    @Test func durableConsumptionReportsAdvancedCursorAfterBrokerAck() async throws {
        let service = MockBrokerService()
        let stateSink = DurableStateSink()
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 5),
                kind: .adapterNotification(
                    method: "session/update",
                    params: .object([
                        "sessionId": .string("remote-1"),
                        "update": .object([
                            "sessionUpdate": .string("agent_message_chunk"),
                            "content": .object([
                                "type": .string("text"),
                                "text": .string("hello")
                            ])
                        ])
                    ])
                )
            )
        ])
        let client = makeClient(service: service) { state in
            Task { await stateSink.append(state) }
        }
        let updateTask = Task { try await nextUpdate(from: client.incomingUpdates) }
        try await client.start()

        let update = try await updateTask.value
        let snapshotStateCount = await stateSink.recordCount()
        update.durableConsumptionAcknowledgement?()

        let expectedState = ACPBrokerDurableState(
            brokerId: ACPBrokerID(rawValue: "broker-1"),
            generation: ACPBrokerGeneration(rawValue: 7),
            acknowledgedCursor: ACPBrokerEventCursor(rawValue: 5)
        )
        try await waitUntil {
            await stateSink.hasLastRecord(after: snapshotStateCount, matching: expectedState)
        }
    }

    @Test func pendingPermissionResponseUsesBrokerRespondAndAcksRequestCursor() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .pendingRequest(ACPBrokerPendingRequest(
                    requestId: "99",
                    adapterRequestId: .number(99),
                    kind: .permission,
                    payload: .object([
                        "sessionId": .string("remote-1"),
                        "toolCall": .object(["toolCallId": .string("tool-1")]),
                        "options": .array([
                            .object([
                                "optionId": .string("allow"),
                                "name": .string("Allow"),
                                "kind": .string("allow_once")
                            ])
                        ])
                    ])
                ))
            )
        ])
        let client = makeClient(service: service)
        let permissionTask = Task { try await nextPermission(from: client.permissionRequests) }
        try await client.start()

        let permission = try await permissionTask.value
        #expect(permission.id == .number(99))
        #expect(permission.params.toolCall.toolCallId == "tool-1")
        client.respondToPermission(id: permission.id, response: .init(outcome: .selected(optionId: "allow")))

        try await waitUntil { await service.responded.count == 1 }
        let response = try await #require(service.responded.first)
        #expect(response.requestId == .number(99))
        #expect(response.operationKey == ACPBrokerOperationKey(rawValue: "op-prefix:1:respond"))
        #expect(await service.acks.map(\.cursor) == [ACPBrokerEventCursor(rawValue: 2)])
    }

    @Test func pendingPermissionResponsePreservesStringRequestId() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .pendingRequest(ACPBrokerPendingRequest(
                    requestId: "req-alpha",
                    adapterRequestId: .string("req-alpha"),
                    kind: .permission,
                    payload: .object([
                        "method": .string("session/request_permission"),
                        "params": .object([
                            "sessionId": .string("remote-1"),
                            "toolCall": .object(["toolCallId": .string("tool-1")]),
                            "options": .array([
                                .object([
                                    "optionId": .string("allow"),
                                    "name": .string("Allow"),
                                    "kind": .string("allow_once")
                                ])
                            ])
                        ])
                    ])
                ))
            )
        ])
        let client = makeClient(service: service)
        let permissionTask = Task { try await nextPermission(from: client.permissionRequests) }
        try await client.start()

        let permission = try await permissionTask.value
        #expect(permission.id == .string("req-alpha"))
        client.respondToPermission(id: permission.id, response: .init(outcome: .selected(optionId: "allow")))

        try await waitUntil { await service.responded.count == 1 }
        let response = try await #require(service.responded.first)
        #expect(response.requestId == .string("req-alpha"))
        #expect(await service.acks.map(\.cursor) == [ACPBrokerEventCursor(rawValue: 2)])
    }

    @Test func pendingRequestAckWaitsForEarlierStreamedUpdateAck() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .adapterNotification(
                    method: "session/update",
                    params: .object([
                        "sessionId": .string("remote-1"),
                        "update": .object([
                            "sessionUpdate": .string("agent_message_chunk"),
                            "content": .object([
                                "type": .string("text"),
                                "text": .string("hello")
                            ])
                        ])
                    ])
                )
            ),
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 3),
                kind: .pendingRequest(ACPBrokerPendingRequest(
                    requestId: "99",
                    adapterRequestId: .number(99),
                    kind: .permission,
                    payload: .object([
                        "sessionId": .string("remote-1"),
                        "toolCall": .object(["toolCallId": .string("tool-1")]),
                        "options": .array([])
                    ])
                ))
            )
        ])
        let client = makeClient(service: service)
        let updateTask = Task { try await nextUpdate(from: client.incomingUpdates) }
        let permissionTask = Task { try await nextPermission(from: client.permissionRequests) }
        try await client.start()

        let update = try await updateTask.value
        let permission = try await permissionTask.value
        client.respondToPermission(id: permission.id, response: .init(outcome: .selected(optionId: "allow")))

        try await waitUntil { await service.responded.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await service.acks.isEmpty)

        update.durableConsumptionAcknowledgement?()
        try await waitUntil {
            await service.acks.map(\.cursor) == [
                ACPBrokerEventCursor(rawValue: 2),
                ACPBrokerEventCursor(rawValue: 3)
            ]
        }
    }

    @Test func promptResponseAckWaitsForEarlierStreamedUpdateAck() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [])
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .adapterNotification(
                    method: "session/update",
                    params: .object([
                        "sessionId": .string("remote-1"),
                        "update": .object([
                            "sessionUpdate": .string("agent_message_chunk"),
                            "content": .object([
                                "type": .string("text"),
                                "text": .string("hello")
                            ])
                        ])
                    ])
                )
            ),
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 3),
                kind: .operationCompleted(
                    operationKey: ACPBrokerOperationKey(rawValue: "op-prefix:1:session/prompt"),
                    outcome: ACPBrokerRPCOutcome(
                        result: .object(["stopReason": .string("end_turn")]),
                        error: nil
                    )
                )
            )
        ])
        await service.enqueueSendResult(ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: 4),
            replayed: false,
            result: .object(["stopReason": .string("end_turn")])
        ))
        let client = makeClient(service: service)
        let updateTask = Task { try await nextUpdate(from: client.incomingUpdates) }
        try await client.start()

        let response = try await client.send(ACPRequest(
            method: "session/prompt",
            params: ACPSessionPromptParams(sessionId: "remote-1", prompt: [.text("hi")])
        ))
        let update = try await updateTask.value

        response.acknowledgeDurableConsumption()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await service.acks.isEmpty)

        update.durableConsumptionAcknowledgement?()
        try await waitUntil {
            await service.acks.map(\.cursor) == [
                ACPBrokerEventCursor(rawValue: 2),
                ACPBrokerEventCursor(rawValue: 3)
            ]
        }
    }

    @Test func sendWaitsAcrossPendingResultAndReplaysPendingRequest() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [])
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .pendingRequest(ACPBrokerPendingRequest(
                    requestId: "99",
                    adapterRequestId: .number(99),
                    kind: .permission,
                    payload: .object([
                        "sessionId": .string("remote-1"),
                        "toolCall": .object(["toolCallId": .string("tool-1")]),
                        "options": .array([])
                    ])
                ))
            )
        ])
        await service.enqueueSendResult(ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: 4),
            replayed: false,
            pending: true
        ))
        await service.enqueueSendResult(ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: 4),
            replayed: true,
            result: .object(["stopReason": .string("end_turn")])
        ))
        let client = makeClient(service: service)
        try await client.start()

        let response = try await client.send(ACPRequest(
            method: "session/prompt",
            params: ACPSessionPromptParams(sessionId: "remote-1", prompt: [.text("hi")])
        ))

        let body = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(body["stopReason"] as? String == "end_turn")
        #expect(await service.sent.count == 2)
        #expect(await service.attached.count == 3)
    }

    @Test func replayedResolvedPendingRequestIsNotYieldedAgain() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .pendingRequest(ACPBrokerPendingRequest(
                    requestId: "99",
                    adapterRequestId: .number(99),
                    kind: .permission,
                    payload: .object([
                        "sessionId": .string("remote-1"),
                        "toolCall": .object(["toolCallId": .string("tool-1")]),
                        "options": .array([])
                    ])
                ))
            ),
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 3),
                kind: .pendingRequestResolved(
                    requestId: "99",
                    response: ACPBrokerRPCOutcome(result: .object(["outcome": .string("approved")]), error: nil)
                )
            )
        ])
        let client = makeClient(service: service)

        try await client.start()

        #expect(client.hasPendingOutboundRequest(id: .number(99)) == false)
    }

    @Test func notifyUsesBrokerNotificationPath() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [])
        await service.enqueueAttach(events: [])
        let client = makeClient(service: service)
        try await client.start()

        try await client.notify(ACPRequest(
            method: "session/cancel",
            params: ACPSessionCancelParams(sessionId: "remote-1")
        ))

        let notified = try await #require(service.notified.first)
        #expect(notified.method == "session/cancel")
        #expect(notified.params == .object(["sessionId": .string("remote-1")]))
        #expect(await service.attached.count == 2)
    }

    private func makeClient(
        service: MockBrokerService,
        initialBrokerGeneration: ACPBrokerGeneration? = nil,
        initialAcknowledgedCursor: ACPBrokerEventCursor = ACPBrokerEventCursor(rawValue: 0),
        onDurableStateChanged: (@Sendable (ACPBrokerDurableState) -> Void)? = nil
    ) -> ACPBrokerClient {
        ACPBrokerClient(
            service: service,
            brokerId: ACPBrokerID(rawValue: "broker-1"),
            sessionId: "local-session-1",
            command: "codex-acp",
            args: ["--stdio"],
            cwd: "/repo",
            env: ["PATH": "/bin"],
            operationKeyPrefix: "op-prefix",
            initialBrokerGeneration: initialBrokerGeneration,
            initialAcknowledgedCursor: initialAcknowledgedCursor,
            onDurableStateChanged: onDurableStateChanged
        )
    }

    private func nextUpdate(from stream: AsyncStream<ACPSessionUpdateParams>) async throws -> ACPSessionUpdateParams {
        var iterator = stream.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    private func nextPermission(
        from stream: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)>
    ) async throws -> (id: JSONRPCID, params: ACPPermissionRequestParams) {
        var iterator = stream.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping @MainActor () async -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !(await predicate()) {
            if ContinuousClock.now - start > timeout {
                throw ACPBrokerClientTestTimeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct ACPBrokerClientTestTimeout: Error {}

private actor DurableStateSink {
    private var records: [ACPBrokerDurableState] = []

    func append(_ state: ACPBrokerDurableState) {
        records.append(state)
    }

    func recordCount() -> Int {
        records.count
    }

    func lastRecord() -> ACPBrokerDurableState? {
        records.last
    }

    func hasLastRecord(after count: Int, matching expected: ACPBrokerDurableState) -> Bool {
        records.count == count + 1 && records.last == expected
    }
}

private actor MockBrokerService: ACPBrokerServicing {
    var opened: [ACPBrokerOpenParams] = []
    var attached: [ACPBrokerAttachParams] = []
    var sent: [ACPBrokerSendParams] = []
    var notified: [ACPBrokerNotifyParams] = []
    var responded: [ACPBrokerRespondParams] = []
    var acks: [ACPBrokerAckParams] = []
    var detached: [ACPBrokerDetachParams] = []
    var closed: [ACPBrokerCloseParams] = []
    var attachEvents: [[ACPBrokerEvent]] = []
    var sendResults: [ACPBrokerSendResult] = []
    var snapshotInitializeResult: ACPBrokerJSONValue?
    var snapshotRemoteSessionResult: ACPBrokerJSONValue?

    func enqueueAttach(events: [ACPBrokerEvent]) {
        attachEvents.append(events)
    }

    func enqueueSendResult(_ result: ACPBrokerSendResult) {
        sendResults.append(result)
    }

    func setSnapshotResults(
        initializeResult: ACPBrokerJSONValue?,
        remoteSessionResult: ACPBrokerJSONValue?
    ) {
        snapshotInitializeResult = initializeResult
        snapshotRemoteSessionResult = remoteSessionResult
    }

    func open(_ params: ACPBrokerOpenParams) async throws -> ACPBrokerOpenResult {
        opened.append(params)
        return ACPBrokerOpenResult(snapshot: snapshot(journalTail: 0), adopted: false)
    }

    func attach(_ params: ACPBrokerAttachParams) async throws -> ACPBrokerAttachResult {
        attached.append(params)
        let events = attachEvents.isEmpty ? [] : attachEvents.removeFirst()
        let tail = events.map(\.cursor).max() ?? params.acknowledgedCursor
        return ACPBrokerAttachResult(
            snapshot: snapshot(
                journalTail: tail.rawValue,
                pendingRequests: pendingRequests(from: events)
            ),
            events: events
        )
    }

    func send(_ params: ACPBrokerSendParams) async throws -> ACPBrokerSendResult {
        sent.append(params)
        return sendResults.isEmpty
            ? ACPBrokerSendResult(
                requestId: ACPBrokerAdapterRequestID(rawValue: 1),
                replayed: false,
                result: .object([:]),
                pending: nil
            )
            : sendResults.removeFirst()
    }

    func notify(_ params: ACPBrokerNotifyParams) async throws -> ACPBrokerSimpleOK {
        notified.append(params)
        return ACPBrokerSimpleOK(ok: true)
    }

    func respond(_ params: ACPBrokerRespondParams) async throws -> ACPBrokerSimpleOK {
        responded.append(params)
        return ACPBrokerSimpleOK(ok: true)
    }

    func ack(_ params: ACPBrokerAckParams) async throws -> ACPBrokerSimpleOK {
        acks.append(params)
        return ACPBrokerSimpleOK(ok: true)
    }

    func detach(_ params: ACPBrokerDetachParams) async throws -> ACPBrokerSimpleOK {
        detached.append(params)
        return ACPBrokerSimpleOK(ok: true)
    }

    func close(_ params: ACPBrokerCloseParams) async throws -> ACPBrokerSimpleOK {
        closed.append(params)
        return ACPBrokerSimpleOK(ok: true)
    }

    private func snapshot(
        journalTail: UInt64,
        pendingRequests: [ACPBrokerPendingRequest] = []
    ) -> ACPBrokerSnapshot {
        ACPBrokerSnapshot(
            metadata: ACPBrokerMetadata(
                brokerId: ACPBrokerID(rawValue: "broker-1"),
                generation: ACPBrokerGeneration(rawValue: 7),
                alasSessionId: "local-session-1",
                adapterProgram: "codex-acp",
                adapterArgs: ["--stdio"],
                cwd: "/repo",
                envKeys: ["PATH"],
                createdAtMillis: 10
            ),
            initializeResult: snapshotInitializeResult,
            remoteSessionResult: snapshotRemoteSessionResult,
            turnState: .idle,
            acknowledgedCursor: ACPBrokerEventCursor(rawValue: 0),
            journalTail: ACPBrokerEventCursor(rawValue: journalTail),
            pendingRequests: pendingRequests,
            operations: []
        )
    }

    private func pendingRequests(from events: [ACPBrokerEvent]) -> [ACPBrokerPendingRequest] {
        var pending: [String: ACPBrokerPendingRequest] = [:]
        for event in events {
            switch event.kind {
            case .pendingRequest(let request):
                pending[request.requestId] = request
            case .pendingRequestResolved(let requestId, _):
                pending.removeValue(forKey: requestId)
            default:
                break
            }
        }
        return Array(pending.values)
    }
}
