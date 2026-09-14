import Foundation
import Testing
@testable import Alas

@Suite("LSP server requests", .serialized)
struct LSPServerRequestsTests {
    @Test func suspendedResponseDoesNotWriteAfterShutdown() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let started = AsyncStream<Void>.makeStream()
        let permission = AsyncStream<Void>.makeStream()
        let shutdownIDs = AsyncStream<LSPJSONValue>.makeStream()
        defer {
            started.continuation.finish()
            permission.continuation.finish()
            shutdownIDs.continuation.finish()
        }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        await client.setConfigurationHandler { _, _ in
            started.continuation.yield(())
            var iterator = permission.stream.makeAsyncIterator()
            _ = await iterator.next()
            return .null
        }
        transport.onSend = { sent in
            guard let frame = try? LSPJSONValue.decode(from: Data(sent.utf8)), let id = frame["id"] else { return }
            if frame["method"] == .string("initialize") {
                transport.deliverFrame(String(decoding: try! LSPJSONValue.object(["id": id, "result": .object(["capabilities": .object([:])])]).encodedData(), as: UTF8.self))
            } else if frame["method"] == .string("shutdown") {
                transport.deliverFrame(#"{"id":"suspended","method":"workspace/configuration","params":{"items":[{}]}}"#)
                shutdownIDs.continuation.yield(id)
            }
        }
        try await client.initialize()
        let shutdown = Task { await client.shutdown() }
        var startedIterator = started.stream.makeAsyncIterator()
        _ = await startedIterator.next()
        let processing = try #require(await client.inbound[.string("suspended")]?.task)
        var ids = shutdownIDs.stream.makeAsyncIterator()
        let id = try #require(await ids.next())
        transport.deliverFrame(String(decoding: try LSPJSONValue.object(["id": id, "result": .null]).encodedData(), as: UTF8.self))
        await shutdown.value
        #expect(await client.state == .dead)
        let count = transport.sent.count
        permission.continuation.yield(())
        await processing.value
        #expect(transport.sent.count == count)
    }

    @Test func shutdownRejectsLateRefreshAndConfigurationRequests() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            guard let frame = try? LSPJSONValue.decode(from: Data(sent.utf8)), let id = frame["id"] else { return }
            if frame["method"] == .string("initialize") {
                transport.deliverFrame(String(decoding: try! LSPJSONValue.object(["id": id, "result": .object(["capabilities": .object([:])])]).encodedData(), as: UTF8.self))
            } else if frame["method"] == .string("shutdown") {
                transport.deliverFrame(String(decoding: try! LSPJSONValue.object(["id": id, "result": .null]).encodedData(), as: UTF8.self))
            }
        }
        try await client.initialize()
        await client.shutdown()
        let count = transport.sent.count
        for (id, method) in [("semantic", "workspace/semanticTokens/refresh"), ("inlay", "workspace/inlayHint/refresh"), ("configuration", "workspace/configuration")] {
            // Await the same actor-isolated frame handler used by consume().
            // Completion proves each late frame crossed the shutdown guard.
            await client.handle(frame: try LSPJSONValue.object(["id": .string(id), "method": .string(method), "params": .object(["items": .array([])])]).encodedData())
        }
        #expect(transport.sent.count == count)
        #expect(await client.state == .dead)
    }

    @Test func configurationMatchesItemCountAndScope() async throws {
        let requests = LSPServerRequests(configuration: { scope, section in
            scope == "file:///tmp/a" && section == "editor" ? .object(["tabSize": .number("4")]) : .null
        })
        let params = try LSPJSONValue.decode(from: Data(#"{"items":[{"scopeUri":"file:///tmp/a","section":"editor"},{"section":"unknown"},{}]}"#.utf8))
        let result = await requests.handle(method: "workspace/configuration", params: params)
        #expect(result.result == .array([.object(["tabSize": .number("4")]), .null, .null]))
        #expect(await requests.handle(method: "client/registerCapability", params: .null).error?.code == -32601)
    }

    @Test func absentApplyHandlerExplicitlyRejects() async {
        let reply = await LSPServerRequests().handle(method: "workspace/applyEdit", params: .object(["edit": .object([:])]))
        guard case .object(let result) = reply.result else { Issue.record("Missing apply response")
        return }
        #expect(result["applied"] == .bool(false))
        #expect(result["failureReason"] != nil)
    }

    @Test func inboundIDCollisionDoesNotConsumeOutgoingResponse() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            if sent.contains("textDocument/hover") {
                transport.deliverFrame(#"{"id":1,"method":"workspace/configuration","params":{"items":[{}]}}"#)
                transport.deliverFrame(#"{"id":1,"result":{"contents":"correct"}}"#)
            }
        }
        let result = try await client.hover(uri: "file:///tmp/a", position: .init(line: 0, character: 0))
        guard case .plain(let value) = result?.contents else { Issue.record("Inbound request consumed outgoing ID")
        return }
        #expect(value == "correct")
    }

    @Test func suspendedApplyDoesNotBlockResponsesAndCancellationRepliesWithStringID() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let replies = AsyncStream<String>.makeStream()
        defer { replies.continuation.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        let token = try await client.beginCommandSession { _ in
            transport.deliverFrame(#"{"id":1,"result":{"contents":"while preview is open"}}"#)
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return .init(applied: true)
        }
        transport.onSend = { sent in
            if sent.contains("textDocument/hover") {
                transport.deliverFrame(#"{"id":"1","method":"workspace/applyEdit","params":{"edit":{"changes":{}}}}"#)
            } else if sent.contains(#""result""#) { replies.continuation.yield(sent) }
        }
        let hover = try await client.hover(uri: "file:///tmp/a", position: .init(line: 0, character: 0))
        guard case .plain(let value) = hover?.contents else { Issue.record("Missing hover response")
        return }
        #expect(value == "while preview is open")
        transport.deliverFrame(#"{"method":"$/cancelRequest","params":{"id":"1"}}"#)
        var iterator = replies.stream.makeAsyncIterator()
        let reply = try #require(await iterator.next())
        let response = try LSPJSONValue.decode(from: Data(reply.utf8))
        #expect(response["id"] == .string("1"))
        #expect(response["result"]?["applied"] == .bool(false))
        #expect(response["result"]?["failureReason"] != nil)
        await client.endCommandSession(token)
    }

    @Test func initializeAdvertisesImplementedEditsWithoutTransactionalClaim() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            guard sent.contains(#""method":"initialize""#) else { return }
            transport.deliverFrame(#"{"id":1,"result":{"capabilities":{}}}"#)
        }
        try await client.initialize()
        let raw = try #require(transport.sent.first)
        let value = try LSPJSONValue.decode(from: Data(raw.utf8))
        let edits = value["params"]?["capabilities"]?["workspace"]?["workspaceEdit"]
        #expect(edits?["resourceOperations"] == .array([.string("create"), .string("rename"), .string("delete")]))
        #expect(edits?["failureHandling"] == nil)
        #expect(edits?["changeAnnotationSupport"]?["groupsOnLabel"] == .bool(false))
        #expect(value["params"]?["capabilities"]?["textDocument"]?["codeAction"]?["dynamicRegistration"] == .bool(false))
    }

    @Test func commandResponseWaitsForAlreadyRequestedPreview() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let permission = AsyncStream<Void>.makeStream()
        let started = AsyncStream<Void>.makeStream()
        defer { permission.continuation.finish()
        started.continuation.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        let token = try await client.beginCommandSession { _ in
            started.continuation.yield(())
            var iterator = permission.stream.makeAsyncIterator()
            _ = await iterator.next()
            return .init(applied: false, failureReason: "User cancelled preview")
        }
        transport.onSend = { sent in
            guard let request = try? LSPJSONValue.decode(from: Data(sent.utf8)),
                  request["method"] == .string("workspace/executeCommand") else { return }
            transport.deliverFrame(#"{"id":"edit","method":"workspace/applyEdit","params":{"edit":{"changes":{}}}}"#)
            transport.deliverFrame(#"{"id":1,"result":null}"#)
        }
        let command = try LSPCommand(wireValue: .object(["title": .string("Run"), "command": .string("run")]))
        try await client.executeCommand(command)
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        let completion = Task { try await client.finishCommandSession(token) }
        #expect(!transport.sent.contains { $0.contains(#""applied""#) })
        permission.continuation.yield(())
        do { try await completion.value
        Issue.record("Cancelled follow-up edit must fail the command flow") }
        catch LSPError.responseError(let error) { #expect(error.message == "User cancelled preview") }
        #expect(transport.sent.contains { $0.contains(#""applied":false"#) })
    }

    @Test func cancellingOutgoingRequestSendsCancellationAndReleasesContinuation() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let started = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in if sent.contains("textDocument/hover") { started.continuation.yield(()) } }
        let request = Task { try await client.hover(uri: "file:///tmp/a", position: .init(line: 0, character: 0)) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        request.cancel()
        do { _ = try await request.value
        Issue.record("Expected request cancellation") }
        catch is CancellationError {}
        #expect(transport.sent.contains { $0.contains("$/cancelRequest") })
    }
}
