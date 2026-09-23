import AppKit
import Testing
@testable import Alas

@MainActor
struct SemanticTokensSchedulingTests {
    @Test func debouncesToLatestRange() async throws {
        var requested: [NSRange] = []
        let feature = SemanticTokensFeature(request: { range in requested.append(range)
        return nil }, apply: { _, _ in }, clear: {})
        defer { feature.stop() }
        feature.refresh(range: NSRange(location: 0, length: 1), debounce: .milliseconds(100))
        try await Task.sleep(for: .milliseconds(10))
        feature.refresh(range: NSRange(location: 4, length: 1), debounce: .milliseconds(100))
        try await Task.sleep(for: .milliseconds(25))
        #expect(requested.isEmpty)
        for _ in 0..<100 where requested.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(requested == [NSRange(location: 4, length: 1)])
    }

    @Test func coalescesPendingRangesAndDiscardsResultInvalidatedByEdit() async throws {
        let context = EditorRequestContext(document: .init(host: nil, worktreeID: "w", uri: "file:///a"), version: 1,
                                           serverGeneration: UUID(), range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 1)))
        var requested: [NSRange] = []
        var applied: [[HighlightSpan]] = []
        var completions: [CheckedContinuation<SemanticTokensFeature.Result?, Never>] = []
        let feature = SemanticTokensFeature(request: { range in
            requested.append(range)
            return await withCheckedContinuation { completions.append($0) }
        }, apply: { spans, _ in applied.append(spans) }, clear: {})
        let a = NSRange(location: 0, length: 1)
        let b = NSRange(location: 2, length: 1)
        let c = NSRange(location: 4, length: 1)
        feature.refresh(range: a, debounce: .zero)
        for _ in 0..<100 where requested.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(requested == [a])
        feature.invalidate()
        feature.refresh(range: b, debounce: .zero)
        feature.refresh(range: c, debounce: .zero)
        #expect(requested == [a])
        let first = try #require(completions.first)
        first.resume(returning: .init(spans: [.init(range: a, capture: .function)], context: context))
        for _ in 0..<100 where requested.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(requested == [a, c])
        #expect(applied.isEmpty)
        let last = try #require(completions.last)
        last.resume(returning: .init(spans: [.init(range: c, capture: .type)], context: context))
        for _ in 0..<100 where applied.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(applied == [[.init(range: c, capture: .type)]])
        feature.stop()
    }

    @Test func editInvalidationCanPreserveCurrentPresentation() {
        var clears = 0
        let feature = SemanticTokensFeature(request: { _ in nil }, apply: { _, _ in }, clear: { clears += 1 })

        feature.invalidate(preservingPresentation: true)
        #expect(clears == 0)
        feature.invalidate()
        #expect(clears == 1)
    }

    @Test func failedLatestRequestClearsPresentationButStaleFailureDoesNot() async throws {
        var clears = 0
        var requests = 0
        var completions: [CheckedContinuation<SemanticTokensFeature.Result?, Never>] = []
        let feature = SemanticTokensFeature(request: { _ in
            requests += 1
            return await withCheckedContinuation { completions.append($0) }
        }, apply: { _, _ in }, clear: { clears += 1 })
        defer { feature.stop() }

        feature.refresh(range: NSRange(location: 0, length: 1), debounce: .zero)
        for _ in 0..<100 where requests < 1 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(requests == 1)
        feature.invalidate(preservingPresentation: true)
        feature.refresh(range: NSRange(location: 1, length: 1), debounce: .zero)
        completions[0].resume(returning: nil)
        for _ in 0..<100 where requests < 2 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(requests == 2)
        #expect(clears == 0)

        completions[1].resume(returning: nil)
        for _ in 0..<100 where clears == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(clears == 1)
    }
}
