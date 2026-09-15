import Foundation
import Testing
@testable import Alas

@MainActor
struct InlayHintsFeatureTests {
    @Test func freshResponseCancelsRetainedPresentationExpiry() async throws {
        var cleared = 0
        var applied = 0
        let feature = InlayHintsFeature(request: { _ in [] }, apply: { _ in applied += 1 }, clear: { cleared += 1 })
        defer { feature.stop() }
        feature.invalidate(preservingPresentation: true)
        feature.refresh(range: NSRange(location: 0, length: 1), debounce: .zero)
        for _ in 0..<100 where applied == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(applied == 1)
        try await Task.sleep(for: .milliseconds(2200))
        #expect(cleared == 0)
    }

    @Test func retainedPresentationExpiresIfNoFreshResponseArrives() async throws {
        var cleared = 0
        let feature = InlayHintsFeature(request: { _ in nil }, apply: { _ in }, clear: { cleared += 1 })
        defer { feature.stop() }
        feature.invalidate(preservingPresentation: true)
        #expect(cleared == 0)
        for _ in 0..<300 where cleared == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cleared == 1)
    }

    @Test func twoViewportOwnersKeepIndependentLatestRequests() async throws {
        var requestsA: [NSRange] = [], requestsB: [NSRange] = []
        var repliesA: [CheckedContinuation<[LSPInlayHint]?, Never>] = [], repliesB: [CheckedContinuation<[LSPInlayHint]?, Never>] = []
        var appliedA = 0, appliedB = 0
        let a = InlayHintsFeature(request: { range in requestsA.append(range)
        return await withCheckedContinuation { repliesA.append($0) } }, apply: { _ in appliedA += 1 }, clear: {})
        let b = InlayHintsFeature(request: { range in requestsB.append(range)
        return await withCheckedContinuation { repliesB.append($0) } }, apply: { _ in appliedB += 1 }, clear: {})
        defer { a.stop()
        b.stop() }
        a.refresh(range: NSRange(location: 0, length: 10), debounce: .zero)
        b.refresh(range: NSRange(location: 100, length: 10), debounce: .zero)
        for _ in 0..<100 where repliesA.isEmpty || repliesB.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        a.refresh(range: NSRange(location: 10, length: 10), debounce: .zero)
        a.refresh(range: NSRange(location: 20, length: 10), debounce: .zero)
        b.refresh(range: NSRange(location: 110, length: 10), debounce: .zero)
        #expect(requestsA == [NSRange(location: 0, length: 10)])
        #expect(requestsB == [NSRange(location: 100, length: 10)])
        let firstA = try #require(repliesA.first), firstB = try #require(repliesB.first)
        firstA.resume(returning: [])
        firstB.resume(returning: [])
        for _ in 0..<100 where repliesA.count < 2 || repliesB.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(requestsA == [NSRange(location: 0, length: 10), NSRange(location: 20, length: 10)])
        #expect(requestsB == [NSRange(location: 100, length: 10), NSRange(location: 110, length: 10)])
        let lastA = try #require(repliesA.last), lastB = try #require(repliesB.last)
        lastA.resume(returning: [])
        lastB.resume(returning: [])
        for _ in 0..<100 where appliedA == 0 || appliedB == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(appliedA == 1)
        #expect(appliedB == 1)
    }

    @Test func labelsPaddingAndOpaqueDataSurviveResolution() throws {
        let raw = try LSPJSONValue.decode(from: Data(#"{"position":{"line":1,"character":2},"label":[{"value":": ","tooltip":{"kind":"markdown","value":"Type"}},{"value":"Int","location":{"uri":"file:///tmp/types.swift","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}}},"command":{"title":"Inspect","command":"inspect","arguments":[9007199254740993]}}],"paddingLeft":true,"paddingRight":false,"data":{"token":9007199254740993}}"#.utf8))
        let hint = try LSPInlayHint(wireValue: raw)
        #expect(hint.label == ": Int")
        #expect(hint.parts.count == 2)
        #expect(hint.paddingLeft && !hint.paddingRight)
        #expect(hint.wireValue == raw)
        let resolved = try hint.mergingResolved(.init(wireValue: .object([
            "position": raw["position"]!,
            "label": .array([.object(["value": .string(": ")]), .object(["value": .string("Int"), "tooltip": .string("Integer")])]),
            "tooltip": .string("Resolved"),
        ])))
        #expect(resolved.wireValue["data"]?["token"] == .number("9007199254740993"))
        #expect(resolved.parts[1].location?.uri == "file:///tmp/types.swift")
        #expect(resolved.parts[1].command?.arguments == [.number("9007199254740993")])
        #expect(resolved.parts[0].tooltip == .object(["kind": .string("markdown"), "value": .string("Type")]))
        #expect(resolved.parts[1].tooltip == .string("Integer"))
    }

    @Test func refreshCoalescesPendingAndInvalidationRejectsActiveResponse() async throws {
        var requests: [NSRange] = []
        var completions: [CheckedContinuation<[LSPInlayHint]?, Never>] = []
        var applied = 0
        var cleared = 0
        let feature = InlayHintsFeature(request: { range in
            requests.append(range)
            return await withCheckedContinuation { completions.append($0) }
        }, apply: { _ in applied += 1 }, clear: { cleared += 1 })
        let first = NSRange(location: 0, length: 3), last = NSRange(location: 10, length: 4)
        feature.refresh(range: first, debounce: .zero)
        for _ in 0..<100 where completions.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        feature.refresh(range: NSRange(location: 4, length: 2), debounce: .zero)
        feature.refresh(range: last, debounce: .zero)
        #expect(requests == [first])
        let firstCompletion = try #require(completions.first)
        completions.removeFirst()
        firstCompletion.resume(returning: [])
        for _ in 0..<100 where completions.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(requests == [first, last])
        #expect(applied == 0)
        feature.invalidate()
        let lastCompletion = try #require(completions.first)
        completions.removeFirst()
        lastCompletion.resume(returning: [])
        for _ in 0..<50 { await Task.yield() }
        #expect(applied == 0)
        #expect(cleared > 0)
        feature.stop()
    }

    @Test func rangeWireRequestAndRefreshAcknowledgement() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            guard let request = try? LSPJSONValue.decode(from: Data(sent.utf8)), let id = request["id"], let method = request["method"]?.stringValue else { return }
            let result: LSPJSONValue = method == "initialize" ? .object(["capabilities": .object(["inlayHintProvider": .object(["resolveProvider": .bool(true)])])]) : .array([])
            transport.deliverFrame(String(decoding: try! LSPJSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).encodedData(), as: UTF8.self))
        }
        try await client.initialize()
        let initialize = try LSPJSONValue.decode(from: Data(try #require(transport.sent.first).utf8))
        #expect(initialize["params"]?["capabilities"]?["workspace"]?["inlayHint"]?["refreshSupport"] == .bool(true))
        #expect(initialize["params"]?["capabilities"]?["textDocument"]?["inlayHint"]?["resolveSupport"]?["properties"] == .array(["tooltip", "textEdits", "label.tooltip", "label.location", "label.command"].map(LSPJSONValue.string)))
        let range = LSPRange(start: .init(line: 2, character: 0), end: .init(line: 5, character: 0))
        #expect(try await client.inlayHints(uri: "file:///tmp/a", range: range).isEmpty)
        let wire = try LSPJSONValue.decode(from: Data(try #require(transport.sent.last).utf8))
        #expect(wire["method"] == .string("textDocument/inlayHint"))
        #expect(wire["params"]?["range"]?["start"]?["line"] == .number("2"))
        let refreshes = await client.subscribeInlayRefreshes()
        transport.deliverFrame(#"{"jsonrpc":"2.0","id":"inlays","method":"workspace/inlayHint/refresh"}"#)
        for await _ in refreshes {
            let reply = try LSPJSONValue.decode(from: Data(try #require(transport.sent.last).utf8))
            #expect(reply["id"] == .string("inlays"))
            #expect(reply["result"] == .null)
            break
        }
    }

    @Test func cancellingActiveHintRequestSendsProtocolCancellation() async throws {
        let transport = FakeTransport()
        defer { transport.finish() }
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            guard let request = try? LSPJSONValue.decode(from: Data(sent.utf8)), request["method"] == .string("initialize"), let id = request["id"] else { return }
            transport.deliverFrame(String(decoding: try! LSPJSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": .object(["capabilities": .object(["inlayHintProvider": .bool(true)])])]).encodedData(), as: UTF8.self))
        }
        try await client.initialize()
        let task = Task { try await client.inlayHints(uri: "file:///tmp/a", range: .init(start: .init(line: 0, character: 0), end: .init(line: 1, character: 0))) }
        for _ in 0..<100 where !transport.sent.contains(where: { $0.contains("textDocument/inlayHint") }) { try await Task.sleep(for: .milliseconds(5)) }
        let request = try LSPJSONValue.decode(from: Data(try #require(transport.sent.last).utf8))
        task.cancel()
        do { _ = try await task.value
        Issue.record("Cancelled request returned hints") } catch { #expect(error is CancellationError) }
        for _ in 0..<100 where !transport.sent.contains(where: { $0.contains("$/cancelRequest") }) { try await Task.sleep(for: .milliseconds(5)) }
        let cancellation = try LSPJSONValue.decode(from: Data(try #require(transport.sent.last).utf8))
        #expect(cancellation["method"] == .string("$/cancelRequest"))
        #expect(cancellation["params"]?["id"] == request["id"])
    }
}
