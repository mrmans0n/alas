import Foundation
import Testing
@testable import Alas

@Suite("Code actions", .serialized)
struct CodeActionsFeatureTests {
    @Test func retainsDisabledActionReason() throws {
        let action = try JSONDecoder().decode(LSPCodeAction.self, from: Data(#"{"title":"Extract method","disabled":{"reason":"Select an expression"}}"#.utf8))
        #expect(action.disabled?.reason == "Select an expression")
    }

    @Test func preservesUnionAndOpaqueData() throws {
        let raw = Data(#"[{"title":"Run","command":"server.run","arguments":[90071992547409931234567890]},{"title":"Fix","kind":"quickfix","isPreferred":true,"diagnostics":[{"message":"m","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"data":{"key":1e1000}}],"data":{"token":90071992547409931234567890,"null":null}}]"#.utf8)
        let actions = try LSPCodeAction.decodeList(raw)
        #expect(actions[0].isCommand)
        #expect(actions[0].command?.command == "server.run")
        #expect(!actions[1].isCommand)
        #expect(actions[1].isPreferred == true)
        #expect(try actions[1].wireValue.encodedData().contains(Data("90071992547409931234567890".utf8)))
        #expect(try actions[1].wireValue.encodedData().contains(Data("1e1000".utf8)))
    }

    @Test func resolvePreservesOpaqueTokens() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        let action = try #require(LSPCodeAction.decodeList(Data(#"[{"title":"Fix","data":{"token":1e1000}}]"#.utf8)).first)
        transport.onSend = { sent in
            #expect(sent.contains("1e1000"))
            transport.deliverFrame(#"{"id":1,"result":{"title":"Fix","data":{"token":1e1000}}}"#)
        }
        let resolved = try await client.resolveCodeAction(action)
        #expect(resolved.data == action.data)
    }

    @Test @MainActor func cancelledEditPreventsCommand() async throws {
        let action = try #require(LSPCodeAction.decodeList(Data(#"[{"title":"Fix","edit":{"changes":{}},"command":{"title":"Run","command":"run"}}]"#.utf8)).first)
        var ran = false
        let result = try await CodeActionsFeature.perform(action, isCurrent: { true }, apply: { _ in .init(applied: false, failureReason: "Cancelled") }, execute: { _ in ran = true })
        #expect(!result.applied)
        #expect(!ran)
    }

    @Test @MainActor func editPrecedesCommandAndStaleContextStopsIt() async throws {
        let action = try #require(LSPCodeAction.decodeList(Data(#"[{"title":"Fix","edit":{"changes":{}},"command":{"title":"Run","command":"run","arguments":[null,1e1000]}}]"#.utf8)).first)
        var events: [String] = []
        let result = try await CodeActionsFeature.perform(action, isCurrent: { true }, apply: { _ in
            events.append("edit")
            return .init(applied: true)
        }, execute: { _ in events.append("command") })
        #expect(result.applied)
        #expect(events == ["edit", "command"])
        var current = true
        events = []
        let stale = try await CodeActionsFeature.perform(action, isCurrent: { current }, apply: { _ in
            current = false
            return .init(applied: true)
        }, execute: { _ in events.append("command") })
        #expect(!stale.applied)
        #expect(events.isEmpty)
    }

    @Test func diagnosticMetadataSurvivesPublishAndActionRequest() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        let stream = await client.subscribeDiagnostics()
        // Fail promptly if the typed diagnostic decoder still rejects opaque numeric values.
        let fixture = Data(#"{"message":"m","data":{"token":1e1000},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}"#.utf8)
        _ = try #require(try? JSONDecoder().decode(LSPDiagnostic.self, from: fixture))
        transport.deliverFrame(#"{"method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/a","diagnostics":[{"message":"m","code":12,"tags":[1],"data":{"token":1e1000},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}]}}"#)
        var iterator = stream.makeAsyncIterator()
        let batch = try #require(await iterator.next())
        transport.onSend = { sent in
            #expect(sent.contains(#""code":12"#))
            #expect(sent.contains("1e1000"))
            #expect(sent.contains("source.organizeImports"))
            transport.deliverFrame(#"{"id":1,"result":[]}"#)
        }
        _ = try await client.codeActions(uri: batch.uri, range: batch.diagnostics[0].range, diagnostics: batch.diagnostics, only: ["source.organizeImports"])
    }

    @Test @MainActor func closingPreviewCancelsItsApplicationTask() async throws {
        let fixture = try WorkspaceEditFixture()
        defer { fixture.remove() }
        let started = AsyncStream<Void>.makeStream()
        let model = WorkspaceEditPreviewModel(plan: fixture.plan) { _ in
            started.continuation.yield(())
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { return .recovered("Cancelled") }
            Issue.record("Application did not receive cancellation")
            return .applied(UUID())
        }
        let task = Task { await model.apply() }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        model.cancel()
        #expect(await task.value == false)
        #expect(!model.didApply)
        #expect(await model.apply() == false)
        started.continuation.finish()
    }
}
