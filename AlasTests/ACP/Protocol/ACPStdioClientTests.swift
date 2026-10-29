import Foundation
import Synchronization
import Testing
@testable import Alas

@Suite("ACPStdioClient")
struct ACPStdioClientTests {
    /// The fake agent script reads one Content-Length framed request from stdin
    /// and writes back a canned response + one session/update notification.
    private func fakeAgentScript() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("fake-acp-agent-\(UUID()).sh")
        let body = #"""
        #!/bin/bash
        # ACP uses newline-delimited JSON. Read one request line, then write
        # the response + a notification as separate lines.
        IFS= read -r line
        echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"authMethods":[]}}'
        echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}}'
        sleep 1
        """#
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("request/response round-trip + receiving a notification")
    func roundtrip() async throws {
        let script = try fakeAgentScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let client = try ACPStdioClient(executable: URL(fileURLWithPath: "/bin/bash"),
                                        arguments: [script.path],
                                        environment: nil)
        try client.start()

        let resp = try await client.send(ACPRequest(
            method: "initialize",
            params: ACPInitializeParams(
                protocolVersion: 1,
                clientCapabilities: .init(
                    fs: .init(readTextFile: true, writeTextFile: true),
                    terminal: true))
        ))
        let init_ = try JSONDecoder().decode(ACPInitializeResult.self, from: resp.body)
        #expect(init_.protocolVersion == 1)

        // First incoming update
        let firstUpdate = await { () async -> ACPSessionUpdate? in
            for await u in client.incomingUpdates { return u.update }
            return nil
        }()
        if case .agentMessageChunk(let chunk) = firstUpdate, case .text(let t) = chunk.content {
            #expect(t == "hi")
        } else { Issue.record("expected agent_message_chunk 'hi'") }
        await client.shutdown()
    }

    @Test("send reports handoff after writing the JSON-RPC frame")
    func sendReportsHandoffAfterTransportWrite() async throws {
        let transport = FakeJSONRPCTransport()
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try client.start()
        let handoffFrameCount = ResultBox<Int>()
        let requestTask = Task {
            try await client.send(
                ACPRequest(method: "session/prompt"),
                onRequestHandoff: { handoffFrameCount.set(transport.sentFrames.count) }
            )
        }

        let observedFrameCount = await boundedResult {
            while !Task.isCancelled {
                if let count = handoffFrameCount.get() { return count }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return -1
        }
        #expect(observedFrameCount == 1)
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8))
        let response = try await requestTask.value
        #expect(response.body == Data("null".utf8))
        await client.shutdown()
    }

    @Test("session update defers frame consumption until durable acknowledgement")
    func sessionUpdateDefersFrameConsumption() async throws {
        let transport = FakeJSONRPCTransport()
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try client.start()
        let consumed = ResultBox<Bool>()

        transport.send(frame: Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}}"#.utf8)) {
            consumed.set(true)
        }

        var iterator = client.incomingUpdates.makeAsyncIterator()
        let update = try #require(await iterator.next())
        #expect(consumed.get() == nil)

        update.durableConsumptionAcknowledgement?()
        #expect(consumed.get() == true)
        await client.shutdown()
    }

    @Test("response defers frame consumption until the caller acknowledges handling")
    func responseDefersFrameConsumption() async throws {
        let transport = FakeJSONRPCTransport()
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try client.start()
        let consumed = ResultBox<Bool>()
        let responseTask = Task {
            try await client.send(ACPRequest(method: "initialize"))
        }
        try await Task.sleep(for: .milliseconds(20))

        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#.utf8)) {
            consumed.set(true)
        }

        let response = try await responseTask.value
        #expect(consumed.get() == nil)
        response.acknowledgeDurableConsumption()
        #expect(consumed.get() == true)
        await client.shutdown()
    }

    @Test("routes _auth/status_update notifications to authStatusUpdates")
    func routesAuthStatusUpdateNotification() async throws {
        let transport = FakeJSONRPCTransport()
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try client.start()
        let consumed = ResultBox<Bool>()

        transport.send(frame: Data(#"""
        {"jsonrpc":"2.0","method":"_auth/status_update","params":{"authStatus":{"kind":"none","label":"Not logged in"}}}
        """#.utf8)) {
            consumed.set(true)
        }

        var iterator = client.authStatusUpdates.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event.status.kind == .none)
        #expect(event.status.label == "Not logged in")
        #expect(consumed.get() == nil)

        event.durableConsumptionAcknowledgement?()
        #expect(consumed.get() == true)
        await client.shutdown()
    }

    @Test("routes _session/list/changes rows with their session index fields")
    func routesSessionListChanges() async throws {
        let transport = FakeJSONRPCTransport()
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try client.start()

        // A malformed row field drops that field, not the row or the notification.
        transport.send(frame: Data(#"""
        {"jsonrpc":"2.0","method":"_session/list/changes","params":{"subscriptionId":"sub-1","sessions":[
         {"sessionId":"s","cwd":"/repo-wt","title":"T","updatedAt":"2026-10-16T09:00:00Z",
          "_meta":{"sessionIndex":{"archived":false,"state":"reviewing","model":7,"agentWorktree":true}}}],"removed":["gone"]}}
        """#.utf8)) {}

        var iterator = client.sessionListChanges.makeAsyncIterator()
        let changes = try #require(await iterator.next())
        #expect(changes.subscriptionId == "sub-1")
        #expect(changes.removed == ["gone"])
        #expect(changes.sessions.map(\.cwd) == ["/repo-wt"])
        #expect(changes.sessions.first?.index == .init(archived: false, agentWorktree: true, state: "reviewing"))
        await client.shutdown()
    }

    @Test("transport request ID prefix namespaces outbound requests")
    func requestIDPrefixNamespacesOutboundRequests() async throws {
        let transport = FakeJSONRPCTransport()
        transport.requestIDPrefix = "attachment-1"
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try client.start()
        let responseTask = Task {
            try await client.send(ACPRequest(method: "initialize"))
        }
        try await Task.sleep(for: .milliseconds(20))

        let frame = try #require(transport.sentFrames.first)
        let request = try #require(JSONSerialization.jsonObject(with: frame) as? [String: Any])
        #expect(request["id"] as? String == "attachment-1:1")
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":"attachment-1:1","result":{"ok":true}}"#.utf8))

        let response = try await responseTask.value
        response.acknowledgeDurableConsumption()
        await client.shutdown()
    }

    @Test("inbound request defers frame consumption until its response is sent")
    func inboundRequestDefersFrameConsumption() async throws {
        let transport = FakeJSONRPCTransport()
        transport.deferWriteCompletions = true
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try client.start()
        let consumed = ResultBox<Bool>()

        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":7,"method":"fs/read_text_file","params":{"sessionId":"s","path":"/tmp/a","line":null,"limit":null}}"#.utf8)) {
            consumed.set(true)
        }

        var iterator = client.fileRequests.makeAsyncIterator()
        guard case .read(let id, _) = try #require(await iterator.next()) else {
            Issue.record("expected read request")
            return
        }
        #expect(consumed.get() == nil)
        client.respondToFileRequest(
            id: id,
            result: .success(try JSONEncoder().encode(ACPFsReadResult(content: "ok")))
        )
        try await Task.sleep(for: .milliseconds(20))
        #expect(consumed.get() == nil)
        transport.completePendingWrites()
        #expect(consumed.get() == true)
        await client.shutdown()
    }

    @Test("session response remains unconsumed until persisted state is acknowledged")
    func sessionResponseWaitsForPersistenceAcknowledgement() async throws {
        let transport = FakeJSONRPCTransport()
        let client = ACPStdioClient.makeForTesting(transport: transport)
        let connection = ACPConnection(client: client)
        try client.start()
        let consumed = ResultBox<Bool>()
        let responseTask = Task {
            try await connection.newSession(cwd: "/tmp", mcpServers: [])
        }
        try await Task.sleep(for: .milliseconds(20))

        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"result":{"sessionId":"remote-1"}}"#.utf8)) {
            consumed.set(true)
        }

        let result = try await responseTask.value
        #expect(result.sessionId == "remote-1")
        #expect(consumed.get() == nil)
        connection.acknowledgeDurableSessionResponses()
        #expect(consumed.get() == true)
        await connection.shutdown()
    }

    @Test func v2FramesReachTheOwnerInOrderWithoutV1Normalization() async throws {
        let transport = FakeJSONRPCTransport()
        defer { transport.terminate() }
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let frames = [
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"t","rawInput":{"n":1e999}}}}"#,
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message","messageId":"a"}}}"#,
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"state_update","state":"running"}}}"#,
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"subagent_update","sessionId":"child","state":{"state":"running"}}}}"#,
            #"{"jsonrpc":"2.0","method":"session/update","id":1e999,"params":null}"#,
        ].map { Data($0.utf8) }
        let consumed = Mutex(Array(repeating: 0, count: frames.count))
        for (index, frame) in frames.enumerated() {
            transport.send(frame: frame) { consumed.withLock { $0[index] += 1 } }
        }
        let received = await boundedResult {
            var iterator = client.incomingV2Updates.makeAsyncIterator()
            var deliveries: [ACPV2SessionUpdateDelivery] = []
            for _ in frames {
                guard let delivery = await iterator.next() else { break }
                deliveries.append(delivery)
            }
            return deliveries
        }
        let deliveries = try #require(received)
        #expect(deliveries.count == frames.count)
        #expect(client.yieldedUpdateCount == frames.count)
        #expect(await boundedResult {
            var iterator = client.incomingUpdates.makeAsyncIterator()
            return await iterator.next() == nil
        } == true)
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: client.updateConnectionID)
        var owner = ACPV2SessionState(context: context)
        for (index, delivery) in deliveries.enumerated() {
            #expect(delivery.frame == frames[index])
            #expect(delivery.connectionID == context.connectionID)
            if index == 4 {
                #expect(throws: DecodingError.self) { try delivery.decode() }
            } else {
                _ = try owner.apply(delivery.decode(), source: .live, context: context)
            }
        }
        #expect(owner.order == [.toolCall("t"), .message(.init(kind: .agent, messageID: "a"))])
        #expect(owner.activity.toolCall(id: "t")?.rawInput == .object(["n": .number("1e999")]))
        #expect(owner.lifecycle.foreground == .running)
        #expect(consumed.withLock { $0 } == [0, 0, 0, 0, 0])
        deliveries.first?.acknowledgeDurableConsumption()
        #expect(consumed.withLock { $0 } == [1, 0, 0, 0, 0])
        await client.shutdown()
    }

    @Test(arguments: [
        #"{"jsonrpc":"2.0","method":"session/update","params":null,"x":0,"x":1}"#,
        #"{"jsonrpc":"2.0","method":"session/update","id":1e999,"params":null,"x":"#
            + String(repeating: "[", count: 129) + "0" + String(repeating: "]", count: 129) + "}",
    ])
    func v2ParserRejectionsRemainRawAndUnconsumedBeforeAndAfterExit(frame: String) async throws {
        let transport = FakeJSONRPCTransport()
        defer { transport.terminate() }
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let bytes = Data(frame.utf8)
        let consumed = Mutex(0)
        let barrier = AsyncStream<Void>.makeStream()
        transport.send(frame: bytes) { consumed.withLock { $0 += 1 } }
        transport.send(frame: Data(#"{"jsonrpc":"2.0","method":"_test/barrier"}"#.utf8)) { barrier.continuation.yield(()) }
        #expect(await boundedResult {
            var iterator = barrier.stream.makeAsyncIterator()
            return await iterator.next() != nil
        } == true)
        #expect(client.yieldedUpdateCount == 1)
        #expect(consumed.withLock { $0 } == 0)
        let received = await boundedResult {
            var iterator = client.incomingV2Updates.makeAsyncIterator()
            return await iterator.next()
        }
        let result = try #require(received)
        let delivery = try #require(result)
        #expect(delivery.frame == bytes)
        #expect(throws: (any Error).self) { try delivery.decode() }
        transport.send(exitStatus: 0, finish: false)
        transport.send(frame: bytes) { consumed.withLock { $0 += 1 } }
        transport.send(frame: Data(#"{"jsonrpc":"2.0","method":"_test/barrier"}"#.utf8)) { barrier.continuation.yield(()) }
        #expect(await boundedResult {
            var iterator = barrier.stream.makeAsyncIterator()
            return await iterator.next() != nil
        } == true)
        #expect(client.yieldedUpdateCount == 1)
        #expect(consumed.withLock { $0 } == 0)
        await client.shutdown()
    }

    @Test func defaultV1FanOutRetainsItsLastUpdateConsumptionBoundary() async throws {
        let transport = FakeJSONRPCTransport()
        defer { transport.terminate() }
        let client = ACPStdioClient(transport: transport)
        try client.start()
        let consumed = Mutex(0)
        transport.send(frame: Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"sessionUpdate":"subagent_update","sessionId":"child","state":{"state":"running"}}}}"#.utf8)) { consumed.withLock { $0 += 1 } }
        let received = await boundedResult {
            var iterator = client.incomingUpdates.makeAsyncIterator()
            var updates: [ACPSessionUpdateParams] = []
            for _ in 0..<2 {
                if let update = await iterator.next() { updates.append(update) }
            }
            return updates
        }
        let updates = try #require(received)
        #expect(updates.count == 2)
        #expect(client.yieldedUpdateCount == 2)
        #expect(updates.first?.durableConsumptionAcknowledgement == nil)
        #expect(consumed.withLock { $0 } == 0)
        updates.last?.durableConsumptionAcknowledgement?()
        #expect(consumed.withLock { $0 } == 1)
        #expect(await boundedResult {
            var iterator = client.incomingV2Updates.makeAsyncIterator()
            return await iterator.next() == nil
        } == true)
        await client.shutdown()
    }

    @Test(arguments: [#"{"n":1e999,"big":123456789012345678901234567890}"#, "[1e999,1.00e2]", "1e999", "true", #""text""#, "null"])
    func successfulResultsKeepExactValuesAndDeferredConsumption(result: String) async throws {
        let consumed = Mutex(0)
        let transport = FakeJSONRPCTransport(responseForRequest: { _ in
            .frame(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(result)}".utf8), onConsumed: { consumed.withLock { $0 += 1 } })
        })
        let client = ACPStdioClient(transport: transport)
        try client.start()
        let request = Task { try await client.send(ACPRequest(method: "test")) }
        let outcome = await boundedResult { await request.result }
        await client.shutdown()
        let response = try #require(outcome).get()
        #expect(try LSPJSONValue.decode(from: response.body) == LSPJSONValue.decode(from: Data(result.utf8)))
        #expect(consumed.withLock { $0 } == 0)
        response.acknowledgeDurableConsumption()
        #expect(consumed.withLock { $0 } == 1)
    }

    @Test(arguments: ["{}", #"{"error":{"code":-32601,"message":"No method"},"result":null}"#])
    func resultExtractionRetainsMissingResultAndErrorSemantics(fields: String) async throws {
        let suffix = String(fields.dropFirst().dropLast())
        let transport = FakeJSONRPCTransport(responseForRequest: { _ in
            .frame(Data("{\"jsonrpc\":\"2.0\",\"id\":1\(suffix.isEmpty ? "" : "," + suffix)}".utf8))
        })
        let client = ACPStdioClient(transport: transport)
        try client.start()
        let request = Task { try await client.send(ACPRequest(method: "test")) }
        let outcome = await boundedResult { await request.result }
        await client.shutdown()
        let completed = try #require(outcome)
        do {
            _ = try completed.get()
            Issue.record("Expected a response error")
        } catch ACPClientError.jsonrpc(let error) {
            #expect(fields != "{}")
            #expect(error.code == -32601)
        } catch ACPClientError.decoding {
            #expect(fields == "{}")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: [false, true])
    func v2TerminationFinishesWithoutConsumingOutstandingOrLateFrames(exit: Bool) async throws {
        let transport = FakeJSONRPCTransport()
        transport.emitExitOnTerminate = false
        defer { transport.terminate() }
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let frame = Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message","messageId":"m"}}}"#.utf8)
        let consumed = Mutex(0), late = Mutex(0)
        transport.send(frame: frame) { consumed.withLock { $0 += 1 } }
        let received = await boundedResult {
            var iterator = client.incomingV2Updates.makeAsyncIterator()
            return await iterator.next()
        }
        let result = try #require(received)
        let delivery = try #require(result)
        if exit {
            let barrier = AsyncStream<Void>.makeStream()
            transport.send(exitStatus: 0, finish: false)
            transport.send(frame: frame) { late.withLock { $0 += 1 } }
            transport.send(frame: Data(#"{"jsonrpc":"2.0","method":"_test/barrier"}"#.utf8)) { barrier.continuation.yield(()) }
            #expect(await boundedResult {
                var iterator = barrier.stream.makeAsyncIterator()
                return await iterator.next() != nil
            } == true)
        } else {
            await client.shutdown()
            transport.send(frame: frame) { late.withLock { $0 += 1 } }
        }
        #expect(await boundedResult {
            var iterator = client.incomingV2Updates.makeAsyncIterator()
            return await iterator.next() == nil
        } == true)
        #expect(client.yieldedUpdateCount == 1)
        #expect(consumed.withLock { $0 } == 0)
        #expect(late.withLock { $0 } == 0)
        let replacement = ACPStdioClient(transport: FakeJSONRPCTransport(), sessionUpdateProtocolVersion: .v2)
        #expect(replacement.updateConnectionID != delivery.connectionID)
        let old = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: delivery.connectionID)
        var owner = ACPV2SessionState(context: .init(sessionID: "s", connectionID: replacement.updateConnectionID))
        #expect(try owner.apply(delivery.decode(), source: .live, context: old).disposition == .staleContext)
        delivery.acknowledgeDurableConsumption()
        #expect(consumed.withLock { $0 } == 1)
        await client.shutdown()
    }

    @Test(arguments: ["null", #"{"n":1e999,"big":123456789012345678901234567890}"#, "error"])
    func v2RPCViewsRetainFullSourceWithoutImplicitConsumption(result: String) async throws {
        let fields = result == "error" ? #""error":{"code":-32044,"message":"changed","data":{"kind":"codex_hook_changed","n":1e999}}"# : "\"result\":\(result)"
        let bytes = Data(" {\"jsonrpc\":\"2.0\",\"id\":1, \(fields)}\n".utf8)
        let count = Mutex(0)
        let transport = FakeJSONRPCTransport(responseForRequest: { _ in .frame(bytes, onConsumed: { count.withLock { $0 += 1 } }) })
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        defer { Task { await client.shutdown() } }
        do {
            let response = try await client.send(.init(method: "session/prompt"))
            #expect(result != "error")
            let delivery = try #require(response.rawDelivery)
            #expect(delivery.source == .stdio(requestID: .number(1), method: "session/prompt"))
            #expect(delivery.frame == bytes)
            #expect(delivery.connectionID == client.updateConnectionID)
            #expect(count.withLock { $0 } == 0)
            response.durableConsumptionAcknowledgement?()
            delivery.acknowledgeDurableConsumption()
        } catch let error as ACPRawRPCError {
            #expect(result == "error")
            #expect(error.delivery.frame == bytes)
            #expect(ACPCodexHookReviewError.classify(error) == .changed)
            #expect(count.withLock { $0 } == 0)
            error.acknowledgeDurableConsumption()
            error.delivery.acknowledgeDurableConsumption()
        }
        #expect(count.withLock { $0 } == 1)
        await client.shutdown()
    }

    @Test(arguments: [
        #"{"jsonrpc":"1.0","id":1,"result":null}"#,
        #"{"jsonrpc":"2.0","id":1,"result":null,"error":{"code":1,"message":"bad"}}"#,
        #"{"jsonrpc":"2.0","id":1,"error":{"code":1e999,"message":"bad"}}"#,
        #"{"jsonrpc":"2.0","id":1}"#,
    ])
    func v2BoundMalformedResponseRetainsUnconsumedFailure(frame: String) async throws {
        let bytes = Data(frame.utf8)
        let count = Mutex(0)
        let transport = FakeJSONRPCTransport(responseForRequest: { _ in .frame(bytes, onConsumed: { count.withLock { $0 += 1 } }) })
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        do {
            _ = try await client.send(.init(method: "m"))
            Issue.record("Malformed v2 response became success")
        } catch let error as ACPRawRPCError {
            #expect(error.rpcError == nil)
            #expect(error.delivery.frame == bytes)
            #expect(count.withLock { $0 } == 0)
            error.acknowledgeDurableConsumption()
            #expect(count.withLock { $0 } == 1)
        }
        await client.shutdown()
    }

    @Test(arguments: [false, true])
    func v2ReversedResponsesKeepExactRequestBindings(prefixed: Bool) async throws {
        let transport = FakeJSONRPCTransport()
        if prefixed { transport.requestIDPrefix = "ns" }
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let first = Task { try await client.send(.init(method: "first")) }
        #expect(await boundedResult { while transport.sentFrames.count < 1, !Task.isCancelled { await Task.yield() }
        return transport.sentFrames.count >= 1 } == true)
        let second = Task { try await client.send(.init(method: "second")) }
        #expect(await boundedResult { while transport.sentFrames.count < 2, !Task.isCancelled { await Task.yield() }
        return transport.sentFrames.count >= 2 } == true)
        let secondID = prefixed ? #""ns:2""# : "2"
        let firstID = prefixed ? #""ns:1""# : "1"
        transport.send(frame: Data("{\"jsonrpc\":\"2.0\",\"id\":\(secondID),\"result\":\"second\"}".utf8))
        transport.send(frame: Data("{\"jsonrpc\":\"2.0\",\"id\":\(firstID),\"result\":\"first\"}".utf8))
        let a = try await first.value
        let b = try await second.value
        #expect(a.body == Data(#""first""#.utf8))
        #expect(b.body == Data(#""second""#.utf8))
        #expect(a.rawDelivery?.source == .stdio(requestID: prefixed ? .string("ns:1") : .number(1), method: "first"))
        #expect(b.rawDelivery?.source == .stdio(requestID: prefixed ? .string("ns:2") : .number(2), method: "second"))
        await client.shutdown()
    }

    @Test(arguments: [
        Data(#"{"jsonrpc":"2.0","id":99,"result":null}"#.utf8),
        Data(#"{"jsonrpc":"2.0","id":null,"result":null}"#.utf8),
        Data(#"{"jsonrpc":"2.0","id":1,"id":1,"result":null}"#.utf8),
        Data(#"{"jsonrpc":"2.0","id":1,"method":"fs/read_text_file","result":null}"#.utf8),
        Data(#"{"jsonrpc":"2.0","id":1,"method":null,"result":null}"#.utf8),
        Data(#"{"jsonrpc":"2.0","id":null,"method":"fs/read_text_file","params":{}}"#.utf8),
        Data(#"{"jsonrpc":"2.0","id":1e999,"method":"peer/request","params":{}}"#.utf8),
        Data([255, 0]),
    ])
    func v2AmbiguousEvidenceCannotSettleAPendingRequestOrConsume(frame: Data) async throws {
        let transport = FakeJSONRPCTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        defer { transport.terminate() }
        let settled = Mutex(false)
        let request = Task { () -> ACPResponse? in
            defer { settled.withLock { $0 = true } }
            return try? await client.send(.init(method: "m"))
        }
        #expect(await boundedResult { while transport.sentFrames.isEmpty, !Task.isCancelled { await Task.yield() }
        return !transport.sentFrames.isEmpty } == true)
        let consumed = Mutex(0)
        transport.send(frame: frame) { consumed.withLock { $0 += 1 } }
        let captured = await boundedResult {
            var diagnostics = client.incomingRawRPCDiagnostics.makeAsyncIterator()
            return await diagnostics.next()
        }
        let delivered = try #require(captured)
        let evidence = try #require(delivered)
        #expect(evidence.frame == frame)
        #expect(evidence.source == .diagnostic)
        #expect(evidence.brokerProvenance == nil)
        #expect(!settled.withLock { $0 })
        #expect(consumed.withLock { $0 } == 0)
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"result":"matched"}"#.utf8))
        #expect(await request.value?.body == Data(#""matched""#.utf8))
        evidence.acknowledgeDurableConsumption()
        #expect(consumed.withLock { $0 } == 1)
        await client.shutdown()
    }

    @Test func v2InboundRequestCanReuseAnOutgoingIDWithoutSettlingIt() async throws {
        let transport = FakeJSONRPCTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let settled = Mutex(false)
        let request = Task { () -> ACPResponse? in
            defer { settled.withLock { $0 = true } }
            return try? await client.send(.init(method: "m"))
        }
        #expect(await boundedResult { while transport.sentFrames.isEmpty, !Task.isCancelled { await Task.yield() }
        return !transport.sentFrames.isEmpty } == true)
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"method":"fs/read_text_file","params":{"sessionId":"s","path":"/tmp/a"}}"#.utf8))
        var files = client.fileRequests.makeAsyncIterator()
        guard case .read(let id, _) = try #require(await files.next()) else { Issue.record("Expected inbound read")
        return }
        #expect(id == .number(1))
        #expect(!settled.withLock { $0 })
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8))
        #expect(await request.value?.rawDelivery?.source == .stdio(requestID: .number(1), method: "m"))
        await client.shutdown()
    }

    @Test func v2ShutdownCannotConsumeReturnedOrBufferedRPCHandles() async throws {
        let consumed = Mutex(0)
        let transport = FakeJSONRPCTransport(responseForRequest: { _ in
            .frame(Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8), onConsumed: { consumed.withLock { $0 += 1 } })
        })
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        try client.start()
        let response = try await client.send(.init(method: "m"))
        transport.send(frame: Data(#"{"jsonrpc":"2.0","id":99,"result":null}"#.utf8)) { consumed.withLock { $0 += 1 } }
        var diagnostics = client.incomingRawRPCDiagnostics.makeAsyncIterator()
        let evidence = try #require(await diagnostics.next())
        await client.shutdown()
        response.acknowledgeDurableConsumption()
        evidence.acknowledgeDurableConsumption()
        #expect(consumed.withLock { $0 } == 0)
    }

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ v: T) {
            lock.lock()
            value = v
            lock.unlock()
        }

        func get() -> T? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Runs `work` in a detached task and returns its result, or nil if it
    /// does not finish within roughly `steps * step`. A work item that never
    /// completes (e.g. a parked continuation on a regressed drain) is
    /// abandoned rather than awaited, so a regression surfaces as a bounded
    /// nil result instead of hanging the whole test run.
    private func boundedResult<T: Sendable>(
        steps: Int = 150,
        step: Duration = .milliseconds(20),
        _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        let box = ResultBox<T>()
        let task = Task.detached { box.set(await work()) }
        for _ in 0..<steps {
            if let v = box.get() { return v }
            try? await Task.sleep(for: step)
        }
        task.cancel()
        return box.get()
    }

    @Test("shutdown resumes an in-flight request even when the transport never emits .exited")
    func shutdownDrainsPendingWithoutExit() async {
        let transport = FakeJSONRPCTransport()
        transport.emitExitOnTerminate = false // real-transport behaviour: no synchronous .exited
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try? client.start()

        // Fire a request the fake never answers; shutdown must unblock it.
        async let threw = boundedResult { () -> Bool in
            do {
                _ = try await client.send(ACPRequest(
                    method: "session/prompt",
                    params: ACPSessionPromptParams(sessionId: "s", prompt: [])))
                return false
            } catch {
                return true
            }
        }
        try? await Task.sleep(for: .milliseconds(100)) // let send() register in `pending`
        await client.shutdown()

        #expect(await threw == true)
    }

    @Test("shutdown drain is idempotent with a transport that also emits .exited")
    func shutdownDrainIsIdempotent() async {
        let transport = FakeJSONRPCTransport() // emitExitOnTerminate defaults to true
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try? client.start()

        async let threw = boundedResult { () -> Bool in
            do {
                _ = try await client.send(ACPRequest(
                    method: "session/prompt",
                    params: ACPSessionPromptParams(sessionId: "s", prompt: [])))
                return false
            } catch { return true }
        }
        try? await Task.sleep(for: .milliseconds(100))
        await client.shutdown()
        // If the .exited handler re-resumed the same continuation the process
        // would have already trapped; reaching this line means it did not.
        #expect(await threw == true)
    }

    @Test("ACPConnection.shutdown unwinds an in-flight prompt")
    func connectionShutdownUnwindsPrompt() async {
        let transport = FakeJSONRPCTransport()
        transport.emitExitOnTerminate = false
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try? client.start()
        let connection = ACPConnection(client: client)

        async let threw = boundedResult { () -> Bool in
            do {
                try await connection.prompt(sessionId: "s", blocks: [])
                return false
            } catch {
                return true
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        await connection.shutdown()
        #expect(await threw == true)
    }
}
