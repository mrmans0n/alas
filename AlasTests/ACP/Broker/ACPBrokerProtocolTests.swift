import Foundation
import Testing
@testable import Alas

@MainActor
struct ACPBrokerProtocolTests {
    @Test func brokerIdentifiersEncodeAsWireScalars() throws {
        let params = ACPBrokerSendParams(
            brokerId: ACPBrokerID(rawValue: "broker-1"),
            generation: ACPBrokerGeneration(rawValue: 9),
            operationKey: ACPBrokerOperationKey(rawValue: "queue-1"),
            method: "session/prompt",
            params: .object(["prompt": .string("hi")])
        )

        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any])
        #expect(object["brokerId"] as? String == "broker-1")
        #expect(object["generation"] as? Int == 9)
        #expect(object["operationKey"] as? String == "queue-1")
        #expect(object["method"] as? String == "session/prompt")
        #expect((object["params"] as? [String: Any])?["prompt"] as? String == "hi")
    }

    @Test func unknownTurnStateDecodesForwardCompatibly() throws {
        let data = Data(#"""
        {
          "metadata": {
            "brokerId": "broker-1",
            "generation": 1,
            "alasSessionId": "session-1",
            "adapterProgram": "codex-acp",
            "adapterArgs": [],
            "cwd": "/repo",
            "envKeys": [],
            "createdAtMillis": 10
          },
          "initializeResult": null,
          "remoteSessionResult": null,
          "turnState": "waitingForSomethingNew",
          "acknowledgedCursor": 0,
          "journalTail": 0,
          "pendingRequests": [],
          "operations": []
        }
        """#.utf8)

        let snapshot = try JSONDecoder().decode(ACPBrokerSnapshot.self, from: data)
        #expect(snapshot.turnState == .unknown("waitingForSomethingNew"))
    }

    @Test func eventKindDecodesOperationCompletedWireShape() throws {
        let data = Data(#"""
        {
          "cursor": 12,
          "kind": {
            "type": "operationCompleted",
            "operationKey": "prompt-1",
            "outcome": { "result": { "stopReason": "end_turn" } }
          }
        }
        """#.utf8)

        let event = try JSONDecoder().decode(ACPBrokerEvent.self, from: data)
        #expect(event.cursor == ACPBrokerEventCursor(rawValue: 12))
        #expect(event.kind == .operationCompleted(
            operationKey: ACPBrokerOperationKey(rawValue: "prompt-1"),
            outcome: ACPBrokerRPCOutcome(
                result: .object(["stopReason": .string("end_turn")]),
                error: nil
            )
        ))
    }

    @Test func respondParamsPreserveStringRequestIdsAndErrorShape() throws {
        let params = ACPBrokerRespondParams(
            brokerId: ACPBrokerID(rawValue: "broker-1"),
            generation: ACPBrokerGeneration(rawValue: 1),
            requestId: .string("req-alpha"),
            operationKey: ACPBrokerOperationKey(rawValue: "respond-1"),
            error: JSONRPCError(code: -32001, message: "denied", data: nil)
        )

        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any])
        #expect(object["requestId"] as? String == "req-alpha")
        #expect(object["result"] == nil)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32001)
        #expect(error["message"] as? String == "denied")
    }

    @Test func unknownEventKindPreservesPayloadWhenReencoded() throws {
        let data = Data(#"""
        {
          "cursor": 13,
          "kind": {
            "type": "futureEvent",
            "extra": { "value": 2 }
          }
        }
        """#.utf8)

        let event = try JSONDecoder().decode(ACPBrokerEvent.self, from: data)
        #expect(event.kind == .unknown(
            type: "futureEvent",
            payload: [
                "type": .string("futureEvent"),
                "extra": .object(["value": .number(2)])
            ]
        ))

        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        let kind = try #require(object["kind"] as? [String: Any])
        #expect(kind["type"] as? String == "futureEvent")
        #expect((kind["extra"] as? [String: Any])?["value"] as? Int == 2)
    }

    @Test func remoteHelperEncodesBrokerOpenAndSendMethods() async throws {
        let transport = FakeJSONRPCTransport()
        let client = RemoteHelperClient(
            host: "local",
            idleShutdownNanoseconds: 0,
            transportFactory: { transport }
        )

        let open = Task {
            try await client.openACPBroker(ACPBrokerOpenParams(
                brokerId: ACPBrokerID(rawValue: "broker-1"),
                sessionId: "session-1",
                command: "codex-acp",
                args: ["--stdio"],
                cwd: "/repo",
                env: ["PATH": "/bin"]
            ))
        }
        try await waitUntil { transport.sentFrames.count == 1 }
        var request = try #require(JSONSerialization.jsonObject(with: transport.sentFrames[0]) as? [String: Any])
        #expect(request["method"] as? String == "acp/open")
        var params = try #require(request["params"] as? [String: Any])
        #expect(params["brokerId"] as? String == "broker-1")
        #expect(params["sessionId"] as? String == "session-1")
        transport.send(frame: Data(#"""
        {"jsonrpc":"2.0","id":1,"result":{
          "adopted": false,
          "snapshot": {
            "metadata": {
              "brokerId": "broker-1",
              "generation": 1,
              "alasSessionId": "session-1",
              "adapterProgram": "codex-acp",
              "adapterArgs": ["--stdio"],
              "cwd": "/repo",
              "envKeys": ["PATH"],
              "createdAtMillis": 10
            },
            "initializeResult": null,
            "remoteSessionResult": null,
            "turnState": "idle",
            "acknowledgedCursor": 0,
            "journalTail": 0,
            "pendingRequests": [],
            "operations": []
          }
        }}
        """#.utf8))
        #expect(try await open.value.adopted == false)

        let send = Task {
            try await client.sendACPBroker(ACPBrokerSendParams(
                brokerId: ACPBrokerID(rawValue: "broker-1"),
                generation: ACPBrokerGeneration(rawValue: 1),
                operationKey: ACPBrokerOperationKey(rawValue: "prompt-1"),
                method: "session/prompt",
                params: .object(["prompt": .string("hi")])
            ))
        }
        try await waitUntil { transport.sentFrames.count == 2 }
        request = try #require(JSONSerialization.jsonObject(with: transport.sentFrames[1]) as? [String: Any])
        #expect(request["method"] as? String == "acp/send")
        params = try #require(request["params"] as? [String: Any])
        #expect(params["operationKey"] as? String == "prompt-1")
        #expect(params["generation"] as? Int == 1)
        transport.send(frame: Data(#"""
        {"jsonrpc":"2.0","id":2,"result":{
          "requestId": 3,
          "replayed": true,
          "result": { "stopReason": "end_turn" },
          "pending": null
        }}
        """#.utf8))
        #expect(try await send.value.result == .object(["stopReason": .string("end_turn")]))
    }

    @Test func localBrokerServiceRejectsHelperWithoutACPCapability() async throws {
        let transport = FakeJSONRPCTransport()
        let client = RemoteHelperClient(
            host: "local",
            idleShutdownNanoseconds: 0,
            transportFactory: { transport }
        )
        let service = LocalACPBrokerService(client: client)

        let list = Task {
            try await service.list()
        }
        try await waitUntil { transport.sentFrames.count == 1 }
        transport.send(frame: Data(#"""
        {"jsonrpc":"2.0","id":1,"result":{
          "name":"alas-helper",
          "protocolVersion":1,
          "binaryVersion":"0.5.0",
          "capabilities":{
            "watchKinds":[],
            "fs":{"read":true,"write":true,"stat":true},
            "ping":true,
            "proc":true
          }
        }}
        """#.utf8))

        await #expect(throws: LocalACPBrokerServiceError.helperDoesNotSupportACP) {
            try await list.value
        }
    }

    @Test func localHelperResolutionUsesBundledMacArchitecture() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alas-helper-test-\(UUID().uuidString)")
        let helper = root
            .appendingPathComponent("alas-helper")
            .appendingPathComponent("macos-\(RemoteHelperInstaller.localArch)")
            .appendingPathComponent("alas-helper")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: helper.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        #expect(try LocalACPBrokerService.resolveBundledHelper(resourceURL: root) == helper)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !predicate() {
            if ContinuousClock.now - start > timeout {
                throw ACPBrokerProtocolTestTimeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct ACPBrokerProtocolTestTimeout: Error {}
