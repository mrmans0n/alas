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

    @Test func detachDuringOpenSuppressesLateStartupCallbacks() async throws {
        let service = GatedOpenBrokerService()
        await service.base.setOpenSnapshotTurnState(.sending)
        let durableStates = DurableStateRecorder()
        let turnStates = SyncTurnStateRecorder()
        let client = makeClient(
            service: service,
            onTurnStateChanged: { turnStates.append($0) },
            onDurableStateChanged: { durableStates.append($0) }
        )
        let startup = Task { try await client.start() }

        try await waitUntil { await service.openGate.hasEntered }
        await client.detach()
        await service.openGate.release()
        do {
            _ = try await startup.value
            Issue.record("Detached startup unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: no late snapshot or callback may revive a detached client.
        }

        #expect(await service.detached.map(\.generation) == [ACPBrokerGeneration(rawValue: 7)])
        #expect(durableStates.records().isEmpty)
        #expect(turnStates.records().isEmpty)
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

    @Test func adoptedLegacyBrokerWithoutTodoSnapshotIsRestarted() async throws {
        let service = MockBrokerService()
        await service.setOpenAdopted(true)
        await service.setOpenSnapshotCursorTodosByToolCallId(nil)
        await service.enqueueAttach(events: [])
        let client = makeClient(
            service: service,
            initialAcknowledgedCursor: ACPBrokerEventCursor(rawValue: 4)
        )

        let opened = try await client.start()

        #expect(opened.adopted == false)
        #expect(await service.opened.count == 2)
        #expect(await service.closed.map(\.generation) == [ACPBrokerGeneration(rawValue: 7)])
        let attachParams = try await #require(service.attached.first)
        #expect(attachParams.acknowledgedCursor == ACPBrokerEventCursor(rawValue: 0))
    }

    /// Two clients can race to restart the same legacy broker: both see the
    /// same missing-snapshot generation and both try to close it. The loser
    /// reaches the helper after the winner already closed that generation
    /// and opened its replacement, so the helper rejects the loser's
    /// stale-generation close with -32075. `start()` must adopt the
    /// winner's replacement rather than fail the whole connection.
    @Test func adoptedLegacyBrokerRestartRaceAdoptsWinnersReplacement() async throws {
        let service = MockBrokerService()
        await service.setOpenAdopted(true)
        await service.setOpenSnapshotCursorTodosByToolCallId(nil)
        await service.setCloseShouldThrowGenerationMismatch(true)
        await service.enqueueAttach(events: [])
        let client = makeClient(
            service: service,
            initialAcknowledgedCursor: ACPBrokerEventCursor(rawValue: 4)
        )

        let opened = try await client.start()

        #expect(opened.adopted == true)
        #expect(opened.snapshot.cursorTodosByToolCallId != nil)
        #expect(await service.opened.count == 2)
        #expect(await service.closed.map(\.generation) == [ACPBrokerGeneration(rawValue: 7)])
        let attachParams = try await #require(service.attached.first)
        #expect(attachParams.acknowledgedCursor == ACPBrokerEventCursor(rawValue: 0))
    }

    /// A raced close on a legacy broker can fail in more shapes than a clean
    /// -32075: the loser's connection might never even be accepted before
    /// the old supervisor's listener drops, surfacing as a generic
    /// transport error with no recognizable code at all. `start()` treats
    /// closing the legacy broker as best-effort — any close failure, not
    /// just a recognized one, still falls through to reopen, the same way
    /// `shutdown()` already treats its own close as advisory.
    ///
    /// That tolerance only holds because the reopen actually landed on a
    /// current-build broker (see the race test above, where the mock
    /// updates its state as if a concurrent racing client had won). If the
    /// close failed because it never reached the broker at all — leaving it
    /// alive, unchanged, still legacy — the reopen below just re-adopts the
    /// exact same broker `start()` was trying to get rid of. Silently
    /// proceeding from there would replay without todo history: the data
    /// loss this whole restart exists to prevent, reached by a different
    /// path than the one it already guards against. `start()` must fail
    /// loudly instead of guessing.
    @Test func adoptedLegacyBrokerRestartFailsWhenReopenIsStillLegacy() async throws {
        let service = MockBrokerService()
        await service.setOpenAdopted(true)
        await service.setOpenSnapshotCursorTodosByToolCallId(nil)
        await service.setCloseShouldThrow(MockBrokerServiceError.injected)
        let client = makeClient(
            service: service,
            initialAcknowledgedCursor: ACPBrokerEventCursor(rawValue: 4)
        )

        // The mock's thrown close leaves the broker's adopted/legacy state
        // untouched (unlike the generation-mismatch case above), so the
        // reopen sees the same still-legacy snapshot.
        await #expect(throws: ACPBrokerLegacyRestartFailedError.self) {
            try await client.start()
        }
        #expect(await service.opened.count == 2)
        #expect(await service.closed.map(\.generation) == [ACPBrokerGeneration(rawValue: 7)])
    }

    /// The best-effort close above must not paper over a genuinely broken
    /// helper: if the *reopen* itself fails, `start()` still throws.
    @Test func adoptedLegacyBrokerRestartStillFailsWhenReopenFails() async throws {
        let service = MockBrokerService()
        await service.setOpenAdopted(true)
        await service.setOpenSnapshotCursorTodosByToolCallId(nil)
        await service.setCloseShouldThrow(MockBrokerServiceError.injected)
        await service.setOpenShouldThrowAfter(callCount: 1, error: MockBrokerServiceError.injected)
        let client = makeClient(service: service)

        await #expect(throws: MockBrokerServiceError.self) {
            try await client.start()
        }
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

    @Test func sendWaitsForDispatchProvenanceBeforeBrokerHandoff() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [])
        let client = makeClient(service: service)
        try await client.start()

        let provenanceWrite = BrokerTestGate()
        let sendTask = Task {
            try await client.send(
                ACPRequest(method: "session/prompt", params: ACPSessionPromptParams(
                    sessionId: "remote-1", prompt: [.text("queued")]
                )),
                beforeRequestHandoff: { generation in
                    #expect(generation == ACPBrokerGeneration(rawValue: 7))
                    await provenanceWrite.wait()
                },
                onRequestHandoff: {}
            )
        }

        try await waitUntil { await provenanceWrite.hasEntered }
        #expect(await service.sent.isEmpty)
        await provenanceWrite.release()
        _ = try await sendTask.value

        #expect(await service.sent.count == 1)
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

    // Regression (code review on #1380): dispatchAdapterNotification had no
    // case for $/cancel_request, so the primary local-session path (broker,
    // not the raw stdio client) silently dropped OpenCode's cancellation —
    // the permission prompt stayed parked forever for real sessions.
    @Test func cancelRequestNotificationIsForwardedFromBroker() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .adapterNotification(
                    method: "$/cancel_request",
                    params: .object(["id": .number(7)])
                )
            )
        ])
        let client = makeClient(service: service)
        let cancelTask = Task {
            var iterator = client.cancelRequests.makeAsyncIterator()
            return await iterator.next()
        }

        try await client.start()

        #expect(try await #require(cancelTask.value) == .number(7))
    }

    @Test func authStatusUpdateNotificationIsYielded() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 3),
                kind: .adapterNotification(
                    method: "_auth/status_update",
                    params: .object([
                        "authStatus": .object([
                            "kind": .string("none"),
                            "label": .string("Not logged in")
                        ])
                    ])
                )
            )
        ])
        let client = makeClient(service: service)
        let statusTask = Task {
            var iterator = client.authStatusUpdates.makeAsyncIterator()
            return try #require(await iterator.next())
        }

        try await client.start()

        let event = try await statusTask.value
        #expect(event.status.kind == .none)
        #expect(event.status.label == "Not logged in")

        #expect(await service.acks.isEmpty)
        event.durableConsumptionAcknowledgement?()
        try await waitUntil { await service.acks.map(\.cursor) == [ACPBrokerEventCursor(rawValue: 3)] }
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

    /// An adapter that asked for something must be answered even when the
    /// answer cannot be delivered.
    ///
    /// The payload for `fs/read_text_file` is a whole file, so delivery can
    /// fail on size where nothing else would. Dropping that failure — which is
    /// what this used to do — leaves the adapter waiting on a request that will
    /// never be answered and the turn stalled with no sign of why. Every
    /// objection raised against bounding the broker's memory rested on this
    /// clause, so it is the part worth pinning.
    @Test func undeliverableFileResponseIsReportedToTheAdapter() async throws {
        let service = MockBrokerService()
        let client = makeClient(service: service)
        try await client.start()
        await service.failNextResponds(1)

        client.respondToFileRequest(id: .number(42), result: .success(Data("{}".utf8)))

        // Two: the attempt that failed, and the error sent in its place.
        try await waitUntil { await service.responded.count == 2 }
        let fallback = try await #require(service.responded.last)
        #expect(fallback.requestId == .number(42))
        #expect(fallback.result == nil)
        #expect(fallback.error != nil, "the adapter must be told, not left waiting")
    }

    @Test func brokerDispatchesCursorPlanAndReturnsApproval() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .pendingRequest(ACPBrokerPendingRequest(
                    requestId: "plan-1",
                    adapterRequestId: .string("plan-1"),
                    kind: .plan,
                    payload: cursorPlanPayload()
                ))
            )
        ])
        let client = makeClient(service: service)
        var iterator = client.planRequests.makeAsyncIterator()

        try await client.start()

        let request = try #require(await iterator.next())
        #expect(request.id == .string("plan-1"))
        #expect(request.params.name == "Fix ACP")
        client.respondToPlan(
            id: request.id,
            response: .init(outcome: .accepted(planUri: "alas://plans/plan-call"))
        )

        try await waitUntil { await service.responded.count == 1 }
        let response = try await #require(service.responded.first)
        #expect(response.requestId == .string("plan-1"))
        #expect(response.result == .object([
            "outcome": .object([
                "outcome": .string("accepted"),
                "planUri": .string("alas://plans/plan-call")
            ])
        ]))
    }

    @Test func brokerAcknowledgesCursorExtensionRequests() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .pendingRequest(ACPBrokerPendingRequest(
                    requestId: "todo-1",
                    adapterRequestId: .string("todo-1"),
                    kind: .cursorExtension,
                    payload: .object([
                        "method": .string("cursor/update_todos"),
                        "params": .object([
                            "toolCallId": .string("todo-call"),
                            "todos": .array([.object([
                                "id": .string("todo"),
                                "content": .string("Implement"),
                                "status": .string("pending")
                            ])]),
                            "merge": .bool(true)
                        ])
                    ])
                ))
            ),
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 3),
                kind: .pendingRequest(ACPBrokerPendingRequest(
                    requestId: "task-1",
                    adapterRequestId: .string("task-1"),
                    kind: .cursorExtension,
                    payload: .object([
                        "method": .string("cursor/task"),
                        "params": .object([
                            "toolCallId": .string("task-call"),
                            "agentId": .string("agent-1"),
                            "durationMs": .number(42)
                        ])
                    ])
                ))
            ),
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 4),
                kind: .pendingRequest(ACPBrokerPendingRequest(
                    requestId: "image-1",
                    adapterRequestId: .string("image-1"),
                    kind: .cursorExtension,
                    payload: .object([
                        "method": .string("cursor/generate_image"),
                        "params": .object([
                            "toolCallId": .string("image-call"),
                            "filePath": .string("/tmp/image.png")
                        ])
                    ])
                ))
            )
        ])
        let client = makeClient(service: service)

        try await client.start()

        // A raw count is a weak proxy for readiness here: it can be
        // satisfied without every expected id present. Wait for the
        // specific three instead of just their tally.
        let expectedIds: [ACPBrokerJSONValue] = [.string("todo-1"), .string("task-1"), .string("image-1")]
        try await waitUntil {
            let ids = await service.responded.map(\.requestId)
            return expectedIds.allSatisfy { ids.contains($0) }
        }
        let responses = await service.responded
        let todo = try #require(responses.first { $0.requestId == .string("todo-1") })
        #expect(todo.result == .object([
            "outcome": .object([
                "outcome": .string("accepted"),
                "todos": .array([.object([
                    "id": .string("todo"),
                    "content": .string("Implement"),
                    "status": .string("pending")
                ])])
            ])
        ]))
        let task = try #require(responses.first { $0.requestId == .string("task-1") })
        #expect(task.result == .object([
            "outcome": .object([
                "outcome": .string("completed"),
                "agentId": .string("agent-1"),
                "durationMs": .number(42)
            ])
        ]))
        let image = try #require(responses.first { $0.requestId == .string("image-1") })
        #expect(image.result == nil)
        #expect(image.error == .init(
            code: -32000,
            message: "cursor/generate_image is not supported",
            data: nil
        ))
    }

    @Test func brokerMergesCursorTodoUpdatesByToolCall() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .pendingRequest(ACPBrokerPendingRequest(
                    requestId: "todo-1",
                    adapterRequestId: .string("todo-1"),
                    kind: .cursorExtension,
                    payload: .object([
                        "method": .string("cursor/update_todos"),
                        "params": .object([
                            "toolCallId": .string("todo-call"),
                            "todos": .array([
                                .object([
                                    "id": .string("todo-1"),
                                    "content": .string("Implement"),
                                    "status": .string("pending")
                                ]),
                                .object([
                                    "id": .string("todo-2"),
                                    "content": .string("Verify"),
                                    "status": .string("pending")
                                ])
                            ]),
                            "merge": .bool(false)
                        ])
                    ])
                ))
            ),
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 3),
                kind: .pendingRequest(ACPBrokerPendingRequest(
                    requestId: "todo-2",
                    adapterRequestId: .string("todo-2"),
                    kind: .cursorExtension,
                    payload: .object([
                        "method": .string("cursor/update_todos"),
                        "params": .object([
                            "toolCallId": .string("todo-call"),
                            "todos": .array([.object([
                                "id": .string("todo-2"),
                                "content": .string("Verify"),
                                "status": .string("completed")
                            ])]),
                            "merge": .bool(true)
                        ])
                    ])
                ))
            )
        ])
        let client = makeClient(service: service)

        try await client.start()

        try await waitUntil { await service.responded.count >= 2 }
        let response = try await #require(service.responded.first { $0.requestId == .string("todo-2") })
        #expect(response.result == .object([
            "outcome": .object([
                "outcome": .string("accepted"),
                "todos": .array([
                    .object([
                        "id": .string("todo-1"),
                        "content": .string("Implement"),
                        "status": .string("pending")
                    ]),
                    .object([
                        "id": .string("todo-2"),
                        "content": .string("Verify"),
                        "status": .string("completed")
                    ])
                ])
            ])
        ]))
    }

    @Test func brokerMergesCursorTodoUpdatesFromAdoptedSnapshot() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(
            events: [
                ACPBrokerEvent(
                    cursor: ACPBrokerEventCursor(rawValue: 4),
                    kind: .pendingRequest(ACPBrokerPendingRequest(
                        requestId: "todo-2",
                        adapterRequestId: .string("todo-2"),
                        kind: .cursorExtension,
                        payload: .object([
                            "method": .string("cursor/update_todos"),
                            "params": .object([
                                "toolCallId": .string("todo-call"),
                                "todos": .array([.object([
                                    "id": .string("todo-2"),
                                    "content": .string("Verify"),
                                    "status": .string("completed")
                                ])]),
                                "merge": .bool(true)
                            ])
                        ])
                    ))
                )
            ],
            snapshotCursorTodosByToolCallId: [
                "todo-call": [
                    .init(id: "todo-1", content: "Implement", status: "pending"),
                    .init(id: "todo-2", content: "Verify", status: "pending")
                ]
            ]
        )
        let client = makeClient(service: service)

        try await client.start()

        try await waitUntil { await service.responded.count >= 1 }
        let response = try await #require(service.responded.first { $0.requestId == .string("todo-2") })
        #expect(response.result == .object([
            "outcome": .object([
                "outcome": .string("accepted"),
                "todos": .array([
                    .object([
                        "id": .string("todo-1"),
                        "content": .string("Implement"),
                        "status": .string("pending")
                    ]),
                    .object([
                        "id": .string("todo-2"),
                        "content": .string("Verify"),
                        "status": .string("completed")
                    ])
                ])
            ])
        ]))
    }

    @Test func failedCursorExtensionResponseReportsErrorToAdapter() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .pendingRequest(ACPBrokerPendingRequest(
                    requestId: "todo-1",
                    adapterRequestId: .string("todo-1"),
                    kind: .cursorExtension,
                    payload: .object([
                        "method": .string("cursor/update_todos"),
                        "params": .object([
                            "toolCallId": .string("todo-call"),
                            "todos": .array([]),
                            "merge": .bool(true)
                        ])
                    ])
                ))
            )
        ])
        let client = makeClient(service: service)
        await service.failNextResponds(1)
        try await client.start()

        try await waitUntil { await service.responded.count == 2 }
        let fallback = try await #require(service.responded.last)
        #expect(fallback.requestId == .string("todo-1"))
        #expect(fallback.result == nil)
        #expect(fallback.error != nil)
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

    // Regression (issue #1388): `dispatch()` used to mark an event's cursor
    // as dispatched and drop `stateLock` *before* the per-method handler
    // re-acquired it to protect that cursor from premature acknowledgement.
    // The background poller and a foreground broker RPC replay overlapping
    // ranges, so one call could sit in that window while the other saw the
    // cursor as "already dispatched", skipped it, and went on to deliver a
    // later event — whose acknowledgement then advanced the broker's
    // acknowledged cursor past an event nobody had consumed yet.
    //
    // `onEventDispatchedForTesting` fires at exactly that instant: the point
    // from which a concurrent duplicate dispatch starts skipping the cursor.
    // Acking an already-delivered later cursor from inside it stands in for
    // the concurrent call that raced ahead; that ack must defer behind the
    // event still being dispatched, not go through.
    @Test func laterAckDefersWhileAnEarlierEventIsStillMidDispatch() async throws {
        let service = MockBrokerService()
        let earlierCursor = ACPBrokerEventCursor(rawValue: 6)
        let laterCursor = ACPBrokerEventCursor(rawValue: 7)
        await service.enqueueAttach(events: [
            sessionUpdateEvent(cursor: laterCursor, text: "later chunk")
        ])
        await service.enqueueAttach(events: [
            sessionUpdateEvent(cursor: earlierCursor, text: "earlier chunk")
        ])
        let laterAck = PendingAcknowledgementBox()
        let client = makeClient(
            service: service,
            onEventDispatchedForTesting: { cursor in
                guard cursor == earlierCursor else { return }
                laterAck.invoke()
            }
        )

        try await client.start()
        let laterUpdate = try await nextUpdate(from: client.incomingUpdates)
        laterAck.store(laterUpdate.durableConsumptionAcknowledgement)

        // Replays the earlier cursor; the seam acks the later one from
        // inside that dispatch.
        try await client.notify(ACPRequest(
            method: "session/cancel",
            params: ACPSessionCancelParams(sessionId: "remote-1")
        ))

        let earlierUpdate = try await nextUpdate(from: client.incomingUpdates)
        #expect(await service.acks.isEmpty)

        earlierUpdate.durableConsumptionAcknowledgement?()
        try await waitUntil {
            await service.acks.map(\.cursor) == [earlierCursor, laterCursor]
        }
    }

    // `dispatch()` claims durable protection for every notification method
    // that *can* hand out an acknowledgement, before the payload has been
    // looked at (see the test above for why it can't wait). Notifications
    // that turn out to carry nothing to deliver — an undecodable payload, or
    // an OpenCode child update that normalizes to zero updates — never reach
    // a consumer, so nothing would ever release them: they must drop their
    // claim themselves, or every later ack defers forever.
    @Test func undeliverableDurableNotificationsDoNotBlockLaterAcks() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .adapterNotification(
                    method: "session/update",
                    params: .object(["sessionId": .string("remote-1")])
                )
            ),
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 3),
                kind: .adapterNotification(
                    method: ACPOpenCodeChildUpdate.method,
                    params: .object(["rootSessionId": .string("remote-1")])
                )
            ),
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 4),
                kind: .adapterNotification(
                    method: "_auth/status_update",
                    params: .object(["authStatus": .string("not-an-object")])
                )
            ),
            sessionUpdateEvent(cursor: ACPBrokerEventCursor(rawValue: 5), text: "hello")
        ])
        let client = makeClient(service: service)

        try await client.start()
        let update = try await nextUpdate(from: client.incomingUpdates)
        #expect(client.yieldedUpdateCount == 1)

        update.durableConsumptionAcknowledgement?()
        try await waitUntil {
            await service.acks.map(\.cursor) == [ACPBrokerEventCursor(rawValue: 5)]
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

    // Regression (code review on #853, two rounds): `shutdown()`/`detach()`
    // first tried marking the poller cancelled and moving on immediately,
    // which let an in-flight, non-cancellation-aware `attachAndReplay()`
    // dispatch a stale result after teardown. The next fix made
    // `shutdown()`/`detach()` await that in-flight iteration before
    // returning — but the underlying helper RPC has no read timeout, so a
    // wedged helper/broker would hang teardown forever and the close/detach
    // RPC would never even be attempted. The actual fix is
    // `attachAndReplay()`'s `isConnectionTerminated()` guard: mark the
    // connection terminated immediately (before cancelling or awaiting
    // anything), so a stale in-flight response is safely dropped whenever
    // it eventually resolves, and `shutdown()`/`detach()` never need to
    // wait for it. This proves both halves: shutdown() returns promptly
    // (doesn't block out the in-flight delay), and the stale response is
    // never dispatched even after it does resolve.
    @Test func shutdownReturnsPromptlyAndDropsStaleInFlightPollResult() async throws {
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

        let shutdownStart = ContinuousClock.now
        await client.shutdown()
        let shutdownElapsed = ContinuousClock.now - shutdownStart

        // Must not have blocked out anywhere near the in-flight delay.
        #expect(shutdownElapsed < .milliseconds(100))
        #expect(recorder.records().isEmpty)

        // Outlast the delayed attach's resolution and confirm its stale
        // `.streaming` never gets applied post-termination.
        try await Task.sleep(for: .milliseconds(150))
        #expect(recorder.records().isEmpty)
    }

    // Regression (code review on #853): a foreground send()/notify() can
    // observe adapter/exit and cancel the background poller while the
    // poller's OWN attach() call is already independently in flight. The
    // cancel doesn't stop that non-cancellation-aware call from resolving
    // later with a stale, pre-exit snapshot; without a termination gate on
    // applying it, that stale snapshot would fire onTurnStateChanged after
    // the connection is already torn down.
    @Test func staleInFlightPollResultIsDroppedAfterConcurrentExit() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [], turnState: .idle)
        await service.enqueueAttach(
            events: [],
            turnState: .streaming,
            delayNanoseconds: 200_000_000
        )
        await service.enqueueSendResult(ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: 4),
            replayed: false,
            result: .object(["stopReason": .string("end_turn")]),
            pending: nil
        ))
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 3),
                kind: .adapterNotification(
                    method: "adapter/exit",
                    params: .object(["unexpected": .bool(true)])
                )
            )
        ])
        let recorder = SyncTurnStateRecorder()
        let client = makeClient(
            service: service,
            backgroundPollIdleIntervalNanoseconds: 20_000_000,
            onTurnStateChanged: { state in recorder.append(state) }
        )

        try await client.start()
        // Let the poller's second attach() begin and enter its 200ms delay
        // before the foreground send() observes the exit.
        try await Task.sleep(for: .milliseconds(60))
        _ = try await client.send(ACPRequest(
            method: "session/prompt",
            params: ACPSessionPromptParams(sessionId: "remote-1", prompt: [.text("hi")])
        ))
        // Outlast the poller's delayed response (resolves ~200ms after it
        // started, i.e. ~220ms after start()).
        try await Task.sleep(for: .milliseconds(250))

        #expect(recorder.records().isEmpty)
    }

    @Test func snapshotTurnStateCallbackIsDroppedAfterTerminationDuringDurableCallback() async throws {
        let service = MockBrokerService()
        await service.setOpenSnapshotTurnState(.streaming)
        let clientReference = ACPBrokerClientReference()
        let detachFinished = DispatchSemaphore(value: 0)
        let terminationCompleted = SyncBooleanRecorder()
        let turnStates = SyncTurnStateRecorder()
        let client = makeClient(
            service: service,
            onTurnStateChanged: { state in turnStates.append(state) },
            onDurableStateChanged: { _ in
                Task.detached(priority: .userInitiated) {
                    await clientReference.detach()
                    detachFinished.signal()
                }
                terminationCompleted.set(detachFinished.wait(timeout: .now() + 2) == .success)
            }
        )
        clientReference.store(client)

        do {
            _ = try await client.start()
            Issue.record("Startup unexpectedly succeeded after the snapshot callback detached its client")
        } catch is CancellationError {
            // Expected: startup stops before attaching after termination.
        }

        #expect(terminationCompleted.value)
        #expect(turnStates.records().isEmpty)
        #expect(await service.attached.isEmpty)
    }

    // Regression (code review on #853, P1): with the background poller now
    // running continuously, it can dispatch an operation's
    // `operationCompleted` event on its OWN independent attach() call,
    // completely decoupled from the `send()` call actually waiting on that
    // operation. Before this fix, the completion's cursor wasn't protected
    // from `ackAfterEarlierDurableEvents` until `send()`'s own retry loop
    // caught up — so a later durable event (e.g. the next streamed chunk,
    // dispatched by that same poller) could be acked immediately in the
    // meantime, advancing past the completion's cursor before `send()`
    // ever got the chance to hand its result back. Reproduces exactly
    // that: `send()` is already running (registered, mid pending-retry
    // sleep) when the poller's own, independent attach() delivers both the
    // completion and the next chunk.
    @Test func operationCompletionIsProtectedWhileSendIsMidRetry() async throws {
        let service = MockBrokerService()
        let operationKey = "queued-prompt:test:0:session/prompt"
        await service.enqueueAttach(events: [], turnState: .idle)
        await service.enqueueSendResult(ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: 9),
            replayed: false,
            pending: true
        ))
        // send()'s own attachAndReplay right after that pending result.
        await service.enqueueAttach(events: [], turnState: .idle)
        // The background poller's next scheduled attach, landing while
        // send() is asleep in its (fixed, 50ms) pending-retry wait.
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .operationCompleted(
                    operationKey: ACPBrokerOperationKey(rawValue: operationKey),
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
                                "text": .string("next chunk")
                            ])
                        ])
                    ])
                )
            )
        ], turnState: .idle)
        // send()'s second service.send() call, after its retry sleep.
        await service.enqueueSendResult(ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: 9),
            replayed: true,
            result: .object(["stopReason": .string("end_turn")]),
            pending: false
        ))
        await service.enqueueAttach(events: [], turnState: .idle)
        let client = makeClient(
            service: service,
            backgroundPollIdleIntervalNanoseconds: 20_000_000
        )
        let updateTask = Task { try await nextUpdate(from: client.incomingUpdates) }

        try await client.start()
        let sendTask = Task {
            try await client.send(ACPRequest(
                method: "session/prompt",
                params: ACPSessionPromptParams(sessionId: "remote-1", prompt: [.text("hi")]),
                brokerOperationKey: operationKey
            ))
        }

        let update = try await updateTask.value
        update.durableConsumptionAcknowledgement?()

        // send() is still asleep in its fixed 50ms pending-retry wait; the
        // completion it registered interest in at entry must still be
        // protected, so this ack has to defer rather than go through.
        try await Task.sleep(for: .milliseconds(30))
        #expect(await service.acks.isEmpty)

        let response = try await sendTask.value
        response.acknowledgeDurableConsumption()

        try await waitUntil {
            await service.acks.map(\.cursor) == [
                ACPBrokerEventCursor(rawValue: 2),
                ACPBrokerEventCursor(rawValue: 3)
            ]
        }
    }

    // Regression (code review on #853, P1, second finding): protecting
    // every operationCompleted cursor unconditionally (the first version of
    // the fix above) broke on an adopted broker's replay, or any queued
    // retry the caller abandoned — nothing in this process will ever call
    // send() again for that operationKey, so the cursor would stay
    // "unacknowledged" forever with no call left to release it, and every
    // later ack would defer permanently. Only a completion a live send()
    // call actually registered interest in may be protected.
    @Test func unclaimedOperationCompletionDoesNotBlockLaterAcks() async throws {
        let service = MockBrokerService()
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .operationCompleted(
                    operationKey: ACPBrokerOperationKey(rawValue: "abandoned-operation"),
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
                                "text": .string("hello")
                            ])
                        ])
                    ])
                )
            )
        ])
        let client = makeClient(service: service)
        let updateTask = Task { try await nextUpdate(from: client.incomingUpdates) }

        try await client.start()
        let update = try await updateTask.value
        update.durableConsumptionAcknowledgement?()

        // Must not be stuck deferring behind a completion nobody will ever
        // claim.
        try await waitUntil {
            await service.acks.map(\.cursor) == [ACPBrokerEventCursor(rawValue: 3)]
        }
    }

    // Regression (code review on #853, P1, third finding): a queued prompt
    // that was `.sending` when the app last quit gets reset to `.pending`
    // on restore but reuses the same `brokerOperationKey` — the broker may
    // have already completed it before the crash. `start()`'s own initial
    // replay can reveal that completion before the queue flusher (which
    // only runs once `start()` returns and the runner registers) ever
    // calls `send()` for it again, so with no live call yet, the "only
    // protect if awaited" fix above would leave it unprotected — exactly
    // like the abandoned-operation case, but this one WILL be retried.
    // `preRegisterAwaitedOperationKeys` closes that gap by registering
    // interest before `start()` runs at all.
    @Test func preRegisteredOperationKeyProtectsCompletionReplayedDuringStart() async throws {
        let service = MockBrokerService()
        let operationKey = "queued-prompt:test-uuid:0:session/prompt"
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .operationCompleted(
                    operationKey: ACPBrokerOperationKey(rawValue: operationKey),
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
                                "text": .string("hello")
                            ])
                        ])
                    ])
                )
            )
        ])
        let client = makeClient(service: service)
        client.preRegisterAwaitedOperationKeys([operationKey])
        let updateTask = Task { try await nextUpdate(from: client.incomingUpdates) }

        try await client.start()
        let update = try await updateTask.value
        update.durableConsumptionAcknowledgement?()

        // Must defer: pre-registration protects this completion even
        // though no live send() call has run in this process yet.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await service.acks.isEmpty)

        // The queue flusher's retry finally catches up.
        await service.enqueueSendResult(ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: 9),
            replayed: false,
            result: .object(["stopReason": .string("end_turn")]),
            pending: false
        ))
        await service.enqueueAttach(events: [], turnState: .idle)
        let response = try await client.send(ACPRequest(
            method: "session/prompt",
            params: ACPSessionPromptParams(sessionId: "remote-1", prompt: [.text("hi")]),
            brokerOperationKey: operationKey
        ))
        response.acknowledgeDurableConsumption()

        try await waitUntil {
            await service.acks.map(\.cursor) == [
                ACPBrokerEventCursor(rawValue: 2),
                ACPBrokerEventCursor(rawValue: 3)
            ]
        }
    }

    // Regression (code review on #853, P1, fourth finding): send()'s
    // defer used to force-ack the completion cursor whenever the call
    // exited without handing a response to its caller. But the operation
    // can have genuinely succeeded at the broker while THIS call still
    // fails for an unrelated reason — e.g. the attachAndReplay() right
    // after a successful/replayed service.send() throws on its own
    // transient hiccup. Acking there tells the broker it may prune the
    // completed operation even though the caller never got the result, and
    // the queued-send retry path reuses the same operationKey on
    // non-JSONRPC failures — so the retry would be treated as a fresh
    // prompt instead of replaying the already-completed one. Confirms no
    // ack happens when send() throws this way, and that a subsequent
    // successful retry for the same key still acks correctly once the
    // caller actually consumes it.
    @Test func sendDoesNotAckCompletionWhenFollowUpAttachFails() async throws {
        let service = MockBrokerService()
        let operationKey = "queued-prompt:test:0:session/prompt"
        // The completion is already known before send() ever runs — e.g.
        // via pre-registration + start()'s own replay, matching the
        // restored-queue scenario above.
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .operationCompleted(
                    operationKey: ACPBrokerOperationKey(rawValue: operationKey),
                    outcome: ACPBrokerRPCOutcome(
                        result: .object(["stopReason": .string("end_turn")]),
                        error: nil
                    )
                )
            )
        ])
        // service.send() itself succeeds (replaying the already-completed
        // operation)...
        await service.enqueueSendResult(ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: 9),
            replayed: true,
            result: .object(["stopReason": .string("end_turn")]),
            pending: false
        ))
        // ...but the attachAndReplay() immediately after it throws.
        await service.enqueueAttach(events: [], shouldThrow: true)
        let client = makeClient(service: service)
        client.preRegisterAwaitedOperationKeys([operationKey])

        try await client.start()
        await #expect(throws: (any Error).self) {
            _ = try await client.send(ACPRequest(
                method: "session/prompt",
                params: ACPSessionPromptParams(sessionId: "remote-1", prompt: [.text("hi")]),
                brokerOperationKey: operationKey
            ))
        }

        // The already-known completion must NOT have been acked away just
        // because this call failed for an unrelated reason.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await service.acks.isEmpty)

        // A later retry for the same operationKey succeeds normally and
        // still acks it correctly once actually consumed.
        await service.enqueueSendResult(ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: 9),
            replayed: true,
            result: .object(["stopReason": .string("end_turn")]),
            pending: false
        ))
        await service.enqueueAttach(events: [], turnState: .idle)
        let response = try await client.send(ACPRequest(
            method: "session/prompt",
            params: ACPSessionPromptParams(sessionId: "remote-1", prompt: [.text("hi")]),
            brokerOperationKey: operationKey
        ))
        response.acknowledgeDurableConsumption()

        try await waitUntil {
            await service.acks.map(\.cursor) == [ACPBrokerEventCursor(rawValue: 2)]
        }
    }

    // Regression (code review on #853, P1, fifth finding): the flip side
    // of the fix above. A terminal JSON-RPC error (`result.error`) IS this
    // operationKey's final, authoritative outcome — unlike an incidental
    // local failure elsewhere in the call, no retry with the same key is
    // coming back to ack it. `attachAndReplay()` right before the error
    // check can have already dispatched (and, since this call registered
    // interest first, protected) that exact completion's cursor; if send()
    // just throws without acking it, it stays "unacknowledged" forever and
    // every later durable event defers behind it, so the broker cursor
    // never advances again after this failure.
    @Test func sendAcksCompletionOnTerminalJSONRPCError() async throws {
        let service = MockBrokerService()
        let operationKey = "queued-prompt:test:0:session/prompt"
        await service.enqueueAttach(events: [])
        await service.enqueueSendResult(ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: 9),
            replayed: false,
            error: JSONRPCError(code: -32000, message: "boom", data: nil)
        ))
        await service.enqueueAttach(events: [
            ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: 2),
                kind: .operationCompleted(
                    operationKey: ACPBrokerOperationKey(rawValue: operationKey),
                    outcome: ACPBrokerRPCOutcome(
                        result: nil,
                        error: JSONRPCError(code: -32000, message: "boom", data: nil)
                    )
                )
            )
        ])
        let client = makeClient(service: service)

        try await client.start()
        await #expect(throws: (any Error).self) {
            _ = try await client.send(ACPRequest(
                method: "session/prompt",
                params: ACPSessionPromptParams(sessionId: "remote-1", prompt: [.text("hi")]),
                brokerOperationKey: operationKey
            ))
        }

        // Must not be stuck deferring behind an errored operation nobody
        // is coming back for.
        try await waitUntil {
            await service.acks.map(\.cursor) == [ACPBrokerEventCursor(rawValue: 2)]
        }
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

    private func cursorPlanPayload() -> ACPBrokerJSONValue {
        .object([
            "method": .string("cursor/create_plan"),
            "params": .object([
                "toolCallId": .string("plan-call"),
                "name": .string("Fix ACP"),
                "overview": .string("Keep requests moving"),
                "plan": .string("# Plan"),
                "todos": .array([.object([
                    "id": .string("todo-1"),
                    "content": .string("Implement"),
                    "status": .string("pending")
                ])]),
                "isProject": .bool(false),
                "phases": .array([])
            ])
        ])
    }

    private func sessionUpdateEvent(cursor: ACPBrokerEventCursor, text: String) -> ACPBrokerEvent {
        ACPBrokerEvent(
            cursor: cursor,
            kind: .adapterNotification(
                method: "session/update",
                params: .object([
                    "sessionId": .string("remote-1"),
                    "update": .object([
                        "sessionUpdate": .string("agent_message_chunk"),
                        "content": .object([
                            "type": .string("text"),
                            "text": .string(text)
                        ])
                    ])
                ])
            )
        )
    }

    private func makeClient(
        service: any ACPBrokerServicing,
        initialBrokerGeneration: ACPBrokerGeneration? = nil,
        initialAcknowledgedCursor: ACPBrokerEventCursor = ACPBrokerEventCursor(rawValue: 0),
        backgroundPollIdleIntervalNanoseconds: UInt64 = ACPBrokerClient.defaultBackgroundPollIdleIntervalNanoseconds,
        onTurnStateChanged: (@Sendable (ACPBrokerTurnState) -> Void)? = nil,
        onDurableStateChanged: (@Sendable (ACPBrokerDurableState) -> Void)? = nil,
        onEventDispatchedForTesting: (@Sendable (ACPBrokerEventCursor) -> Void)? = nil
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
            onTurnStateChanged: onTurnStateChanged,
            onEventDispatchedForTesting: onEventDispatchedForTesting
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

private final class ACPBrokerClientReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var client: ACPBrokerClient?

    func store(_ client: ACPBrokerClient) {
        lock.lock()
        self.client = client
        lock.unlock()
    }

    func detach() async {
        await referencedClient()?.detach()
    }

    private func referencedClient() -> ACPBrokerClient? {
        lock.lock()
        defer { lock.unlock() }
        return client
    }
}

private final class SyncBooleanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordedValue
    }

    func set(_ value: Bool) {
        lock.lock()
        recordedValue = value
        lock.unlock()
    }
}

/// Holds the durable acknowledgement of an already-delivered event so a
/// dispatch seam can fire it from inside a later dispatch, on whatever
/// thread that dispatch happens to run on.
private final class PendingAcknowledgementBox: @unchecked Sendable {
    private let lock = NSLock()
    private var acknowledgement: ACPDurableConsumptionAcknowledgement?

    func store(_ acknowledgement: ACPDurableConsumptionAcknowledgement?) {
        lock.lock()
        self.acknowledgement = acknowledgement
        lock.unlock()
    }

    /// Fires at most once, so a replay that dispatches the same cursor twice
    /// can't turn one ack into two.
    func invoke() {
        lock.lock()
        let acknowledgement = self.acknowledgement
        self.acknowledgement = nil
        lock.unlock()
        acknowledgement?()
    }
}

private enum MockBrokerFailure: Error {
    case rejected
}

private actor BrokerTestGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    var hasEntered: Bool { entered }

    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor GatedOpenBrokerService: ACPBrokerServicing {
    let openGate = BrokerTestGate()
    let base = MockBrokerService()
    private(set) var detached: [ACPBrokerDetachParams] = []

    func open(_ params: ACPBrokerOpenParams) async throws -> ACPBrokerOpenResult {
        await openGate.wait()
        return try await base.open(params)
    }

    func attach(_ params: ACPBrokerAttachParams) async throws -> ACPBrokerAttachResult {
        try await base.attach(params)
    }

    func send(_ params: ACPBrokerSendParams) async throws -> ACPBrokerSendResult {
        try await base.send(params)
    }

    func notify(_ params: ACPBrokerNotifyParams) async throws -> ACPBrokerSimpleOK {
        try await base.notify(params)
    }

    func respond(_ params: ACPBrokerRespondParams) async throws -> ACPBrokerSimpleOK {
        try await base.respond(params)
    }

    func ack(_ params: ACPBrokerAckParams) async throws -> ACPBrokerSimpleOK {
        try await base.ack(params)
    }

    func detach(_ params: ACPBrokerDetachParams) async throws -> ACPBrokerSimpleOK {
        detached.append(params)
        return try await base.detach(params)
    }

    func close(_ params: ACPBrokerCloseParams) async throws -> ACPBrokerSimpleOK {
        try await base.close(params)
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
    var openSnapshotTurnState: ACPBrokerTurnState = .idle
    var openAdopted = false
    var openSnapshotCursorTodosByToolCallId: [String: [ACPCursorTodo]]? = [:]
    private var respondFailuresRemaining = 0
    private var closeShouldThrowGenerationMismatch = false
    private var closeShouldThrowError: (any Error)?
    private var openShouldThrowAfter: (callCount: Int, error: any Error)?

    func enqueueAttach(
        events: [ACPBrokerEvent],
        snapshotPendingRequests: [ACPBrokerPendingRequest]? = nil,
        snapshotJournalTail: ACPBrokerEventCursor? = nil,
        snapshotOperations: [ACPBrokerOperationSnapshot] = [],
        snapshotCursorTodosByToolCallId: [String: [ACPCursorTodo]]? = [:],
        turnState: ACPBrokerTurnState = .idle,
        delayNanoseconds: UInt64 = 0,
        shouldThrow: Bool = false
    ) {
        attachReplies.append(AttachReply(
            events: events,
            snapshotPendingRequests: snapshotPendingRequests,
            snapshotJournalTail: snapshotJournalTail,
            snapshotOperations: snapshotOperations,
            snapshotCursorTodosByToolCallId: snapshotCursorTodosByToolCallId,
            turnState: turnState,
            delayNanoseconds: delayNanoseconds,
            shouldThrow: shouldThrow
        ))
    }

    func enqueueSendResult(_ result: ACPBrokerSendResult) {
        sendResults.append(result)
    }

    func setOpenAdopted(_ adopted: Bool) {
        openAdopted = adopted
    }

    func setOpenSnapshotCursorTodosByToolCallId(_ todos: [String: [ACPCursorTodo]]?) {
        openSnapshotCursorTodosByToolCallId = todos
    }

    func setCloseShouldThrowGenerationMismatch(_ value: Bool) {
        closeShouldThrowGenerationMismatch = value
    }

    func setCloseShouldThrow(_ error: any Error) {
        closeShouldThrowError = error
    }

    /// Makes `open()` throw once its call count exceeds `callCount` — e.g.
    /// `callCount: 1` lets the first `open()` succeed and every one after
    /// it fail, modeling a reopen-after-close that hits a genuinely broken
    /// helper rather than a race.
    func setOpenShouldThrowAfter(callCount: Int, error: any Error) {
        openShouldThrowAfter = (callCount, error)
    }

    func setSnapshotResults(
        initializeResult: ACPBrokerJSONValue?,
        remoteSessionResult: ACPBrokerJSONValue?
    ) {
        snapshotInitializeResult = initializeResult
        snapshotRemoteSessionResult = remoteSessionResult
    }

    func setOpenSnapshotTurnState(_ turnState: ACPBrokerTurnState) {
        openSnapshotTurnState = turnState
    }

    func open(_ params: ACPBrokerOpenParams) async throws -> ACPBrokerOpenResult {
        opened.append(params)
        if let openShouldThrowAfter, opened.count > openShouldThrowAfter.callCount {
            throw openShouldThrowAfter.error
        }
        return ACPBrokerOpenResult(
            snapshot: snapshot(
                journalTail: 0,
                turnState: openSnapshotTurnState,
                cursorTodosByToolCallId: openSnapshotCursorTodosByToolCallId
            ),
            adopted: openAdopted
        )
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
        if reply.shouldThrow {
            throw MockBrokerServiceError.injected
        }
        let events = reply.events
        let tail = reply.snapshotJournalTail ?? events.map(\.cursor).max() ?? params.acknowledgedCursor
        return ACPBrokerAttachResult(
            snapshot: snapshot(
                journalTail: tail.rawValue,
                acknowledgedCursor: params.acknowledgedCursor,
                pendingRequests: reply.snapshotPendingRequests ?? pendingRequests(from: events),
                operations: reply.snapshotOperations,
                turnState: reply.turnState,
                cursorTodosByToolCallId: reply.snapshotCursorTodosByToolCallId
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

    func failNextResponds(_ count: Int) {
        respondFailuresRemaining = count
    }

    func respond(_ params: ACPBrokerRespondParams) async throws -> ACPBrokerSimpleOK {
        responded.append(params)
        if respondFailuresRemaining > 0 {
            respondFailuresRemaining -= 1
            throw MockBrokerFailure.rejected
        }
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
        if let closeShouldThrowError {
            self.closeShouldThrowError = nil
            throw closeShouldThrowError
        }
        if closeShouldThrowGenerationMismatch {
            closeShouldThrowGenerationMismatch = false
            // Model another client having won the same restart race: it
            // already closed this generation and opened a current-build
            // replacement, which is what a retried `open()` should now find.
            openAdopted = true
            openSnapshotCursorTodosByToolCallId = [:]
            throw RemoteHelperClientError.jsonrpc(
                JSONRPCError(code: -32075, message: "broker generation mismatch", data: nil)
            )
        }
        openAdopted = false
        openSnapshotCursorTodosByToolCallId = [:]
        return ACPBrokerSimpleOK(ok: true)
    }

    private func snapshot(
        journalTail: UInt64,
        acknowledgedCursor: ACPBrokerEventCursor = ACPBrokerEventCursor(rawValue: 0),
        pendingRequests: [ACPBrokerPendingRequest] = [],
        operations: [ACPBrokerOperationSnapshot] = [],
        turnState: ACPBrokerTurnState = .idle,
        cursorTodosByToolCallId: [String: [ACPCursorTodo]]? = [:]
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
            operations: operations,
            cursorTodosByToolCallId: cursorTodosByToolCallId
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
        let snapshotCursorTodosByToolCallId: [String: [ACPCursorTodo]]?
        let snapshotOperations: [ACPBrokerOperationSnapshot]
        let turnState: ACPBrokerTurnState
        let delayNanoseconds: UInt64
        let shouldThrow: Bool

        init(
            events: [ACPBrokerEvent],
            snapshotPendingRequests: [ACPBrokerPendingRequest]? = nil,
            snapshotJournalTail: ACPBrokerEventCursor? = nil,
            snapshotOperations: [ACPBrokerOperationSnapshot] = [],
            snapshotCursorTodosByToolCallId: [String: [ACPCursorTodo]]? = [:],
            turnState: ACPBrokerTurnState = .idle,
            delayNanoseconds: UInt64 = 0,
            shouldThrow: Bool = false
        ) {
            self.events = events
            self.snapshotPendingRequests = snapshotPendingRequests
            self.snapshotJournalTail = snapshotJournalTail
            self.snapshotOperations = snapshotOperations
            self.snapshotCursorTodosByToolCallId = snapshotCursorTodosByToolCallId
            self.turnState = turnState
            self.delayNanoseconds = delayNanoseconds
            self.shouldThrow = shouldThrow
        }
    }
}

private enum MockBrokerServiceError: Error {
    case injected
}
