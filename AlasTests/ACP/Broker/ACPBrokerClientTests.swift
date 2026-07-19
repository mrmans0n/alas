import Foundation
import Testing
@testable import Alas

@MainActor
struct ACPBrokerClientTests {
    // Regression: `JSONSerialization` returns every JSON number as an
    // `NSNumber`, and bridging an `NSNumber` to `Bool` succeeds for any value
    // equal to 0 or 1. The broker re-encoded outgoing request params through
    // that bridge, so `initialize`'s `protocolVersion: 1` was rewritten to
    // `true` and every ACP agent rejected the attach with -32602 Invalid params.
    @Test func encodableIntegerParamsSurviveAsNumbers() throws {
        struct Payload: Encodable { let protocolVersion: Int }

        #expect(try ACPBrokerJSONValue(encodable: Payload(protocolVersion: 1))
            == .object(["protocolVersion": .number(1)]))
        #expect(try ACPBrokerJSONValue(encodable: Payload(protocolVersion: 0))
            == .object(["protocolVersion": .number(0)]))
        #expect(try ACPBrokerJSONValue(encodable: Payload(protocolVersion: 2))
            == .object(["protocolVersion": .number(2)]))
    }

    // Guard the fix from over-correcting: genuine JSON booleans must stay bool.
    @Test func encodableBooleansStayBooleans() throws {
        struct Payload: Encodable {
            let enabled: Bool
            let disabled: Bool
        }

        #expect(try ACPBrokerJSONValue(encodable: Payload(enabled: true, disabled: false))
            == .object(["enabled": .bool(true), "disabled": .bool(false)]))
    }

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

    @Test func identicalStartupSnapshotsPublishDurableStateOnce() async throws {
        let service = MockBrokerService()
        let recorder = DurableStateRecorder()
        await service.enqueueAttach(events: [])
        let client = makeClient(service: service, onDurableStateChanged: { state in
            recorder.append(state)
        })

        try await client.start()

        #expect(recorder.records() == [
            ACPBrokerDurableState(
                brokerId: ACPBrokerID(rawValue: "broker-1"),
                generation: ACPBrokerGeneration(rawValue: 7),
                acknowledgedCursor: ACPBrokerEventCursor(rawValue: 0)
            )
        ])
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
        let client = makeClient(service: service, onDurableStateChanged: { state in
            Task { await stateSink.append(state) }
        })
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

    @Test func adapterExitNotificationFinishesUpdateStream() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .adapterNotification(
                    method: "adapter/exit",
                    params: .object(["unexpected": .bool(true)])
                )
            )
        ])
        let client = makeClient(service: service)
        let finishedTask = Task {
            var iterator = client.incomingUpdates.makeAsyncIterator()
            return await iterator.next() == nil
        }

        try await client.start()

        #expect(await finishedTask.value == true)
    }

    // Regression (code review on #853): `start()` called `startBackgroundPolling()`
    // unconditionally after its initial `attachAndReplay()`, even when that
    // same replay already delivered `adapter/exit` and finished the streams.
    // The exit handler's own `cancelBackgroundPolling()` had nothing to
    // cancel yet at that point (the poller didn't exist), so the very next
    // line created a fresh poller for an already-dead connection — leaking
    // it and its idle-rate `attach` traffic forever, since nothing else was
    // going to call `shutdown()`/`detach()` on a connection that failed
    // before ever being handed to a runner.
    @Test func startupExitDoesNotLeaveBackgroundPollerRunning() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .adapterNotification(
                    method: "adapter/exit",
                    params: .object(["unexpected": .bool(true)])
                )
            )
        ])
        let client = makeClient(service: service, backgroundPollIdleIntervalNanoseconds: 20_000_000)

        try await client.start()
        try await Task.sleep(for: .milliseconds(80))

        #expect(await service.attached.count == 1)
    }

    @Test func shutdownClosesBrokerGeneration() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [])
        let client = makeClient(service: service)
        try await client.start()

        await client.shutdown()

        let close = try await #require(service.closed.first)
        #expect(close.brokerId == ACPBrokerID(rawValue: "broker-1"))
        #expect(close.generation == ACPBrokerGeneration(rawValue: 7))
        #expect(await service.detached.isEmpty)
    }

    @Test func detachDoesNotCloseBrokerGeneration() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [])
        let client = makeClient(service: service)
        try await client.start()

        await client.detach()

        let detach = try await #require(service.detached.first)
        #expect(detach.brokerId == ACPBrokerID(rawValue: "broker-1"))
        #expect(detach.generation == ACPBrokerGeneration(rawValue: 7))
        #expect(await service.closed.isEmpty)
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

    @Test func snapshotPendingRequestIsYieldedWhenEventIsAlreadyAcknowledged() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(
            events: [],
            snapshotPendingRequests: [
                ACPBrokerPendingRequest(
                    requestId: "99",
                    adapterRequestId: .number(99),
                    kind: .permission,
                    payload: .object([
                        "method": .string("session/request_permission"),
                        "params": .object([
                            "sessionId": .string("remote-1"),
                            "toolCall": .object(["toolCallId": .string("tool-1")]),
                            "options": .array([])
                        ])
                    ])
                )
            ],
            snapshotJournalTail: ACPBrokerEventCursor(rawValue: 8)
        )
        let client = makeClient(
            service: service,
            initialAcknowledgedCursor: ACPBrokerEventCursor(rawValue: 5)
        )
        let permissionTask = Task { try await nextPermission(from: client.permissionRequests) }

        try await client.start()

        let permission = try await permissionTask.value
        #expect(permission.id == .number(99))
        client.respondToPermission(id: permission.id, response: .init(outcome: .selected(optionId: "allow")))

        try await waitUntil { await service.responded.count == 1 }
        let response = try await #require(service.responded.first)
        #expect(response.requestId == .number(99))
        #expect(await service.acks.map(\.cursor) == [ACPBrokerEventCursor(rawValue: 5)])
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

    @Test func laterStreamedUpdateAckWaitsForDeferredPromptResponseAck() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [])
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .operationCompleted(
                    operationKey: ACPBrokerOperationKey(rawValue: "op-prefix:1:session/prompt"),
                    outcome: ACPBrokerRPCOutcome(
                        result: .object(["stopReason": .string("end_turn")]),
                        error: nil
                    )
                )
            ),
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
                                "text": .string("after-completion")
                            ])
                        ])
                    ])
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

        update.durableConsumptionAcknowledgement?()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await service.acks.isEmpty)

        response.acknowledgeDurableConsumption()
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

    @Test func pendingBrokerSendTracksOutboundRequestIdForScopedElicitations() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [])
        await service.enqueueAttach(events: [])
        await service.enqueueAttach(events: [])
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

        let sendTask = Task {
            try await client.send(ACPRequest(
                method: "session/prompt",
                params: ACPSessionPromptParams(sessionId: "remote-1", prompt: [.text("hi")])
            ))
        }

        try await waitUntil { client.hasPendingOutboundRequest(id: .number(4)) }
        _ = try await sendTask.value
        #expect(client.hasPendingOutboundRequest(id: .number(4)) == false)
    }

    @Test func restoredActiveOperationTracksOutboundRequestId() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(
            events: [],
            snapshotOperations: [
                ACPBrokerOperationSnapshot(
                    operationKey: ACPBrokerOperationKey(rawValue: "queued-prompt:item:0:session/prompt"),
                    adapterRequestId: ACPBrokerAdapterRequestID(rawValue: 7),
                    method: "session/prompt",
                    params: .object(["prompt": .string("hi")]),
                    terminalOutcome: nil
                )
            ]
        )
        let client = makeClient(service: service)

        try await client.start()

        #expect(client.hasPendingOutboundRequest(id: .number(7)) == true)
    }

    @Test func adoptedActiveTurnPollsForLaterEventsAfterStart() async throws {
        let service = MockBrokerService()
        await service.setOpenAdopted(true)
        await service.enqueueAttach(events: [], turnState: .streaming)
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
            )
        ], turnState: .streaming)
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 3),
                kind: .operationCompleted(
                    operationKey: ACPBrokerOperationKey(rawValue: "queued-prompt:item:0:session/prompt"),
                    outcome: ACPBrokerRPCOutcome(
                        result: .object(["stopReason": .string("end_turn")]),
                        error: nil
                    )
                )
            )
        ], turnState: .completed)
        let turnStateSink = TurnStateSink()
        let client = makeClient(
            service: service,
            onTurnStateChanged: { state in
                Task { await turnStateSink.append(state) }
            }
        )
        let updateTask = Task { try await nextUpdate(from: client.incomingUpdates) }

        try await client.start()

        let update = try await updateTask.value
        if case .agentMessageChunk(let chunk) = update.update {
            #expect(chunk.content == .text("hello"))
        } else {
            Issue.record("expected agent message chunk")
        }
        try await waitUntil { await service.attached.count == 3 }
        try await waitUntil { await turnStateSink.records() == [.streaming, .completed] }
        // Background polling never stops outright once the turn completes
        // (see `backgroundPollingDiscoversSelfContinuedTurnWithoutAnySend`),
        // but it drops to the idle-rate interval, which comfortably outlasts
        // this window — so no further attach call lands within it.
        try await Task.sleep(for: .milliseconds(120))
        #expect(await service.attached.count == 3)
        await client.shutdown()
    }

    // Regression: the broker is pull-only, and until this fix
    // `startActiveTurnPollingIfNeeded` only ever ran once, from an
    // *adopted* `start()`. A freshly-opened session (the common case) that
    // goes idle after its first exchange had nothing left pulling —  an SDK
    // that resumed itself (queued follow-up, stop-hook continuation, a
    // `/loop`-style wakeup) with no further `send()`/`notify()` from Alas
    // would stream events into the broker's durable log with nobody
    // watching, and the transcript looked frozen until the next user
    // prompt replayed the whole backlog. This exercises the idle-rate
    // background poll picking up that self-started turn on its own.
    @Test func backgroundPollingDiscoversSelfContinuedTurnWithoutAnySend() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [], turnState: .idle)
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
                                "text": .string("still working")
                            ])
                        ])
                    ])
                )
            )
        ], turnState: .streaming)
        let turnStateSink = TurnStateSink()
        let client = makeClient(
            service: service,
            // Small override so the test doesn't wait out the production
            // 2s idle interval; still comfortably below the default 50ms
            // active interval the client switches to once it observes
            // `.streaming`, so there's no race with a follow-up poll.
            backgroundPollIdleIntervalNanoseconds: 20_000_000,
            onTurnStateChanged: { state in
                Task { await turnStateSink.append(state) }
            }
        )
        let updateTask = Task { try await nextUpdate(from: client.incomingUpdates) }

        try await client.start()

        let update = try await updateTask.value
        if case .agentMessageChunk(let chunk) = update.update {
            #expect(chunk.content == .text("still working"))
        } else {
            Issue.record("expected agent message chunk")
        }
        try await waitUntil { await turnStateSink.records() == [.streaming] }
        await client.shutdown()
    }

    // Regression (code review on #853): `shutdown()`/`detach()` only marked
    // the background poller's task cancelled without waiting for it to
    // unwind. `Task.cancel()` doesn't abort an in-flight, non-cancellation-
    // aware RPC await, so a poll iteration already inside `attachAndReplay()`
    // ran to completion and dispatched its results — including firing
    // `onTurnStateChanged`, a plain closure unaffected by `finishStreams()` —
    // after `shutdown()` had already returned to its caller, who by then
    // believes the connection is fully torn down. `shutdown()`/`detach()`
    // must not return before that in-flight dispatch has landed.
    @Test func shutdownAwaitsInFlightPollBeforeReturning() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [], turnState: .idle)
        await service.enqueueAttach(
            events: [],
            turnState: .streaming,
            // Stands in for a slow, non-cancellation-aware helper RPC that's
            // still in flight when shutdown() fires.
            delayNanoseconds: 150_000_000
        )
        let recorder = SyncTurnStateRecorder()
        let client = makeClient(
            service: service,
            backgroundPollIdleIntervalNanoseconds: 20_000_000,
            onTurnStateChanged: { state in recorder.append(state) }
        )

        try await client.start()
        // The idle-rate poll's second attach() call should be in flight
        // (sleeping inside the mock) by now, but not yet resolved.
        try await Task.sleep(for: .milliseconds(60))
        #expect(recorder.records().isEmpty)

        await client.shutdown()

        // If shutdown() returned before the in-flight iteration's dispatch
        // landed, this would still be empty here.
        #expect(recorder.records() == [.streaming])
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
        backgroundPollIdleIntervalNanoseconds: UInt64 = ACPBrokerClient.defaultBackgroundPollIdleIntervalNanoseconds,
        onTurnStateChanged: (@Sendable (ACPBrokerTurnState) -> Void)? = nil,
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
            backgroundPollIdleIntervalNanoseconds: backgroundPollIdleIntervalNanoseconds,
            onDurableStateChanged: onDurableStateChanged,
            onTurnStateChanged: onTurnStateChanged
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

private final class DurableStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStates: [ACPBrokerDurableState] = []

    func append(_ state: ACPBrokerDurableState) {
        lock.lock()
        recordedStates.append(state)
        lock.unlock()
    }

    func records() -> [ACPBrokerDurableState] {
        lock.lock()
        defer { lock.unlock() }
        return recordedStates
    }
}

private actor TurnStateSink {
    private var recordedStates: [ACPBrokerTurnState] = []

    func append(_ state: ACPBrokerTurnState) {
        recordedStates.append(state)
    }

    func records() -> [ACPBrokerTurnState] {
        recordedStates
    }
}

/// Records synchronously, unlike `TurnStateSink` (an actor, so callers hop
/// through a detached `Task` to append — fine for `waitUntil`-style polling,
/// but useless for proving something happened-before a specific instant, since
/// the detached `Task` may not have run yet even after that instant passes).
/// `onTurnStateChanged` is invoked synchronously from within the broker
/// client's own async context, so a plain lock-protected recorder lets a test
/// assert exactly what's landed by the time a specific `await` returns.
private final class SyncTurnStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStates: [ACPBrokerTurnState] = []

    func append(_ state: ACPBrokerTurnState) {
        lock.lock()
        recordedStates.append(state)
        lock.unlock()
    }

    func records() -> [ACPBrokerTurnState] {
        lock.lock()
        defer { lock.unlock() }
        return recordedStates
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
    private var attachReplies: [AttachReply] = []
    var sendResults: [ACPBrokerSendResult] = []
    var snapshotInitializeResult: ACPBrokerJSONValue?
    var snapshotRemoteSessionResult: ACPBrokerJSONValue?
    var openAdopted = false

    func enqueueAttach(
        events: [ACPBrokerEvent],
        snapshotPendingRequests: [ACPBrokerPendingRequest]? = nil,
        snapshotJournalTail: ACPBrokerEventCursor? = nil,
        snapshotOperations: [ACPBrokerOperationSnapshot] = [],
        turnState: ACPBrokerTurnState = .idle,
        delayNanoseconds: UInt64 = 0
    ) {
        attachReplies.append(AttachReply(
            events: events,
            snapshotPendingRequests: snapshotPendingRequests,
            snapshotJournalTail: snapshotJournalTail,
            snapshotOperations: snapshotOperations,
            turnState: turnState,
            delayNanoseconds: delayNanoseconds
        ))
    }

    func enqueueSendResult(_ result: ACPBrokerSendResult) {
        sendResults.append(result)
    }

    func setOpenAdopted(_ adopted: Bool) {
        openAdopted = adopted
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
        return ACPBrokerOpenResult(snapshot: snapshot(journalTail: 0), adopted: openAdopted)
    }

    func attach(_ params: ACPBrokerAttachParams) async throws -> ACPBrokerAttachResult {
        attached.append(params)
        let reply = attachReplies.isEmpty ? AttachReply(events: []) : attachReplies.removeFirst()
        if reply.delayNanoseconds > 0 {
            // `Task.sleep` honors cooperative cancellation, which would
            // defeat the point of this delay: it exists to stand in for a
            // real helper RPC (`withCheckedThrowingContinuation`-based, not
            // cancellation-aware), so the caller's task being cancelled
            // must NOT cut this short — a `DispatchQueue` timer behind a
            // raw continuation genuinely can't be cancelled from here.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .nanoseconds(Int(reply.delayNanoseconds))
                ) {
                    continuation.resume()
                }
            }
        }
        let events = reply.events
        let tail = reply.snapshotJournalTail ?? events.map(\.cursor).max() ?? params.acknowledgedCursor
        return ACPBrokerAttachResult(
            snapshot: snapshot(
                journalTail: tail.rawValue,
                acknowledgedCursor: params.acknowledgedCursor,
                pendingRequests: reply.snapshotPendingRequests ?? pendingRequests(from: events),
                operations: reply.snapshotOperations,
                turnState: reply.turnState
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
        acknowledgedCursor: ACPBrokerEventCursor = ACPBrokerEventCursor(rawValue: 0),
        pendingRequests: [ACPBrokerPendingRequest] = [],
        operations: [ACPBrokerOperationSnapshot] = [],
        turnState: ACPBrokerTurnState = .idle
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
            turnState: turnState,
            acknowledgedCursor: acknowledgedCursor,
            journalTail: ACPBrokerEventCursor(rawValue: journalTail),
            pendingRequests: pendingRequests,
            operations: operations
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

    private struct AttachReply {
        let events: [ACPBrokerEvent]
        let snapshotPendingRequests: [ACPBrokerPendingRequest]?
        let snapshotJournalTail: ACPBrokerEventCursor?
        let snapshotOperations: [ACPBrokerOperationSnapshot]
        let turnState: ACPBrokerTurnState
        let delayNanoseconds: UInt64

        init(
            events: [ACPBrokerEvent],
            snapshotPendingRequests: [ACPBrokerPendingRequest]? = nil,
            snapshotJournalTail: ACPBrokerEventCursor? = nil,
            snapshotOperations: [ACPBrokerOperationSnapshot] = [],
            turnState: ACPBrokerTurnState = .idle,
            delayNanoseconds: UInt64 = 0
        ) {
            self.events = events
            self.snapshotPendingRequests = snapshotPendingRequests
            self.snapshotJournalTail = snapshotJournalTail
            self.snapshotOperations = snapshotOperations
            self.turnState = turnState
            self.delayNanoseconds = delayNanoseconds
        }
    }
}
