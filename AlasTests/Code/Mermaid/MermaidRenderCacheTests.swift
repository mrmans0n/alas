import Testing
@testable import Alas

@MainActor
@Suite("Mermaid render cache")
struct MermaidRenderCacheTests {
    @Test("cache evicts least-recently-used entries by count")
    func evictsByCount() {
        var cache = MermaidRenderCache(countLimit: 2, costLimit: 100)
        cache.insert(.failed(.empty), for: TestMermaid.key(source: "a"))
        cache.insert(.failed(.empty), for: TestMermaid.key(source: "b"))
        _ = cache.value(for: TestMermaid.key(source: "a"))
        cache.insert(.failed(.empty), for: TestMermaid.key(source: "c"))

        #expect(cache.value(for: TestMermaid.key(source: "a")) != nil)
        #expect(cache.value(for: TestMermaid.key(source: "b")) == nil)
    }

    @Test("cache evicts least-recently-used entries by total cost")
    func evictsByCost() {
        var cache = MermaidRenderCache(countLimit: 10, costLimit: 3)
        cache.insert(.failed(.empty), for: TestMermaid.key(source: "a"))
        cache.insert(.failed(.empty), for: TestMermaid.key(source: "b"))
        cache.insert(.failed(.empty), for: TestMermaid.key(source: "c"))
        _ = cache.value(for: TestMermaid.key(source: "a"))
        cache.insert(.failed(.empty), for: TestMermaid.key(source: "d"))

        #expect(cache.value(for: TestMermaid.key(source: "b")) == nil)
        #expect(cache.totalCost == 3)
    }
}
