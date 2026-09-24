import Foundation
import Testing
@testable import Alas

@MainActor
struct InlayHintsFeatureTests {
    @Test func visitedChunksAndEmptyResponsesAreCachedUntilInvalidation() async throws {
        let first = NSRange(location: 0, length: 256), second = NSRange(location: 256, length: 256)
        let hint = try LSPInlayHint(wireValue: LSPJSONValue.decode(from: Data(#"{"position":{"line":0,"character":1},"label":": Int"}"#.utf8)))
        var requests: [NSRange] = []
        var presentations: [[LSPInlayHint]] = []
        var outstandingCalls: [[NSRange]] = []
        let feature = InlayHintsFeature(request: { range in
            requests.append(range)
            return range == first ? [hint] : []
        }, apply: { hints, outstanding in presentations.append(hints)
        outstandingCalls.append(outstanding) }, clear: {})
        defer { feature.stop() }
        feature.refresh(ranges: [first, second])
        for _ in 0..<100 where presentations.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(presentations.count == 2)
        #expect(presentations.last?.map(\.label) == [": Int"])
        // `first` answers before `second`, so only `second` is still
        // outstanding at that point; once `second` also answers — with an
        // empty result — nothing is outstanding any more. An empty result is
        // still an answer: it must not be mistaken for "not yet answered" and
        // kept outstanding, or a hint the server has since dropped from that
        // range would linger under the old decoration forever.
        #expect(outstandingCalls == [[second], []])
        feature.refresh(ranges: [second, first])
        for _ in 0..<20 { await Task.yield() }
        #expect(requests == [first, second])
        feature.invalidate()
        feature.refresh(ranges: [first])
        for _ in 0..<100 where requests.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(requests == [first, second, first])
    }

    @Test func chunkRequestsStayStableWithinViewportAndPrefetchNeighbors() {
        let starts = Array(stride(from: 0, through: 10000, by: 10))
        let first = InlayHintsFeature.requestRanges(visibleRange: .init(location: 0, length: 200), lineStarts: starts, sourceLength: 10000)
        #expect(first == [.init(location: 0, length: 2560), .init(location: 2560, length: 2560)])
        #expect(InlayHintsFeature.requestRanges(visibleRange: .init(location: 100, length: 200), lineStarts: starts, sourceLength: 10000) == first)
        #expect(InlayHintsFeature.requestRanges(visibleRange: .init(location: 3000, length: 200), lineStarts: starts, sourceLength: 10000) == [
            .init(location: 2560, length: 2560), .init(location: 5120, length: 2560), .init(location: 0, length: 2560)
        ])
        #expect(InlayHintsFeature.requestRanges(visibleRange: .init(location: 10000, length: 0), lineStarts: starts, sourceLength: 10000).first == .init(location: 7680, length: 2320))
        #expect(InlayHintsFeature.requestRanges(visibleRange: .init(location: 0, length: 0), lineStarts: [0], sourceLength: 0) == [.init(location: 0, length: 0)])
        #expect(InlayHintsFeature.requestRanges(visibleRange: .init(location: 2560, length: 0), lineStarts: Array(stride(from: 0, through: 2560, by: 10)), sourceLength: 2560) == [.init(location: 0, length: 2560)])
    }

    @Test func failedPrefetchDoesNotRemoveCachedPresentation() async throws {
        var requests = 0, applied = 0, cleared = 0
        let feature = InlayHintsFeature(request: { _ in
            requests += 1
            return requests == 1 ? [] : nil
        }, apply: { _, _ in applied += 1 }, clear: { cleared += 1 })
        defer { feature.stop() }
        feature.refresh(ranges: [.init(location: 0, length: 10), .init(location: 10, length: 10)])
        for _ in 0..<100 where requests < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(requests == 2)
        #expect(applied == 1)
        #expect(cleared == 0)
    }

    @Test func awaitingRequestsIncludesDebounceAndActiveResponse() async throws {
        let started = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish() }
        var response: CheckedContinuation<[LSPInlayHint]?, Never>?
        var debounceWaitFinished = false
        var retiredWaitFinished = false
        let feature = InlayHintsFeature(request: { _ in
            await withCheckedContinuation {
                response = $0
                started.continuation.yield(())
            }
        }, apply: { _, _ in }, clear: {})
        defer {
            feature.stop()
            response?.resume(returning: nil)
        }

        feature.refresh(range: NSRange(location: 0, length: 1), debounce: .milliseconds(20))
        let debounceWaiter = Task {
            await feature.awaitRequestsForTesting()
            debounceWaitFinished = true
        }
        await Task.yield()
        #expect(!debounceWaitFinished)
        let requestStarted = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = started.stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        guard requestStarted else {
            feature.stop()
            Issue.record("Inlay request did not start before the liveness deadline")
            return
        }
        #expect(!debounceWaitFinished)
        feature.stop()
        let retiredWaiter = Task {
            await feature.awaitRequestsForTesting()
            retiredWaitFinished = true
        }
        await Task.yield()
        #expect(!retiredWaitFinished)
        let continuation = try #require(response)
        response = nil
        continuation.resume(returning: [])
        await debounceWaiter.value
        await retiredWaiter.value
        #expect(debounceWaitFinished)
        #expect(retiredWaitFinished)
    }

    @Test func freshResponseCancelsRetainedPresentationExpiry() async throws {
        var cleared = 0
        var applied = 0
        let feature = InlayHintsFeature(request: { _ in [] }, apply: { _, _ in applied += 1 }, clear: { cleared += 1 })
        defer { feature.stop() }
        feature.invalidate(preservingPresentation: true)
        feature.refresh(range: NSRange(location: 0, length: 1), debounce: .zero)
        for _ in 0..<100 where applied == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(applied == 1)
        try await Task.sleep(for: .milliseconds(2200))
        #expect(cleared == 0)
    }

    /// A success on one chunk must not disarm the watchdog while a sibling
    /// chunk keeps failing — its carried-over presentation (see
    /// `EditorInlayLayout`'s `covering`) would otherwise sit stale forever
    /// with nothing left to clear it.
    /// A chunk that already answered is confirmed, current data. The
    /// watchdog firing while a sibling chunk keeps failing must not wipe it
    /// out — `apply` never gets called again for an already-cached range, so
    /// a `clear()` here would make those valid hints vanish for good.
    @Test func presentationExpiryReappliesConfirmedHintsInsteadOfClearingThemWhileASiblingChunkKeepsFailing() async throws {
        var cleared = 0
        var applications: [[NSRange]] = []
        let hint = try LSPInlayHint(wireValue: LSPJSONValue.decode(from: Data(#"{"position":{"line":0,"character":1},"label":": Int"}"#.utf8)))
        let succeeding = NSRange(location: 0, length: 10), failing = NSRange(location: 10, length: 10)
        let feature = InlayHintsFeature(request: { range in range == succeeding ? [hint] : nil },
                                        apply: { hints, outstanding in applications.append(outstanding)
                                        #expect(hints.map(\.label) == [": Int"]) }, clear: { cleared += 1 })
        defer { feature.stop() }
        feature.invalidate(preservingPresentation: true)
        feature.refresh(ranges: [succeeding, failing], debounce: .zero)
        for _ in 0..<100 where applications.count < 1 { try await Task.sleep(for: .milliseconds(10)) }
        // The succeeding chunk already answered, so it is not outstanding —
        // only the still-failing sibling is, and only until the watchdog
        // gives up on it.
        #expect(applications.last == [failing])
        // The watchdog reapplies the confirmed chunk once the failing
        // sibling's retry window has been open long enough with nothing else
        // to wait on, instead of clearing everything — and gives up on the
        // failing chunk for good rather than reporting it outstanding again.
        for _ in 0..<300 where applications.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(applications.count == 2)
        #expect(applications.last == [])
        #expect(cleared == 0)
    }

    @Test func retainedPresentationExpiresIfNoFreshResponseArrives() async throws {
        var cleared = 0
        let feature = InlayHintsFeature(request: { _ in nil }, apply: { _, _ in }, clear: { cleared += 1 })
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
        return await withCheckedContinuation { repliesA.append($0) } }, apply: { _, _ in appliedA += 1 }, clear: {})
        let b = InlayHintsFeature(request: { range in requestsB.append(range)
        return await withCheckedContinuation { repliesB.append($0) } }, apply: { _, _ in appliedB += 1 }, clear: {})
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
        for _ in 0..<100 where appliedA < 2 || appliedB < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(appliedA == 2)
        #expect(appliedB == 2)
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
        }, apply: { _, _ in applied += 1 }, clear: { cleared += 1 })
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
        #expect(applied == 1) // Scrolling does not stale the active source revision.
        feature.invalidate()
        let lastCompletion = try #require(completions.first)
        completions.removeFirst()
        lastCompletion.resume(returning: [])
        for _ in 0..<50 { await Task.yield() }
        #expect(applied == 1)
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
