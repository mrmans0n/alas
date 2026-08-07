import Foundation
import Testing
@testable import Alas

private actor LoadCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

struct GGStackCacheTests {
    private func stack(name: String) -> GGStack {
        GGStack(
            name: name,
            base: "main",
            totalCommits: 1,
            syncedCommits: 0,
            currentPosition: 1,
            behindBase: 0,
            entries: [GGStackEntry(position: 1, sha: "abc1234", title: "first", ggId: "c-abc1234")]
        )
    }

    @Test func secondCallReusesTheCachedStack() async throws {
        let cache = GGStackCache()
        let counter = LoadCounter()
        let path = URL(fileURLWithPath: "/tmp/wt")

        let first = try await cache.stack(at: path) { await counter.increment(); return self.stack(name: "s") }
        let second = try await cache.stack(at: path) { await counter.increment(); return self.stack(name: "s") }

        #expect(first?.name == "s")
        #expect(second?.name == "s")
        #expect(await counter.count == 1)
    }

    @Test func differentWorktreesLoadIndependently() async throws {
        let cache = GGStackCache()
        let counter = LoadCounter()

        _ = try await cache.stack(at: URL(fileURLWithPath: "/tmp/a")) {
            await counter.increment(); return self.stack(name: "a")
        }
        _ = try await cache.stack(at: URL(fileURLWithPath: "/tmp/b")) {
            await counter.increment(); return self.stack(name: "b")
        }

        #expect(await counter.count == 2)
    }

    @Test func invalidateForcesAReload() async throws {
        let cache = GGStackCache()
        let counter = LoadCounter()
        let path = URL(fileURLWithPath: "/tmp/wt")

        _ = try await cache.stack(at: path) { await counter.increment(); return self.stack(name: "s") }
        await cache.invalidate()
        _ = try await cache.stack(at: path) { await counter.increment(); return self.stack(name: "s") }

        #expect(await counter.count == 2)
    }

    @Test func failuresAreNotCached() async throws {
        struct Boom: Error {}
        let cache = GGStackCache()
        let counter = LoadCounter()
        let path = URL(fileURLWithPath: "/tmp/wt")

        await #expect(throws: Boom.self) {
            try await cache.stack(at: path) { await counter.increment(); throw Boom() }
        }
        _ = try await cache.stack(at: path) { await counter.increment(); return self.stack(name: "s") }

        #expect(await counter.count == 2)
    }

    @Test func concurrentCallersShareOneLoad() async throws {
        let cache = GGStackCache()
        let counter = LoadCounter()
        let path = URL(fileURLWithPath: "/tmp/wt")

        async let a = cache.stack(at: path) {
            await counter.increment()
            try await Task.sleep(nanoseconds: 20_000_000)
            return self.stack(name: "s")
        }
        async let b = cache.stack(at: path) {
            await counter.increment()
            try await Task.sleep(nanoseconds: 20_000_000)
            return self.stack(name: "s")
        }

        _ = try await [a, b]
        #expect(await counter.count == 1)
    }
}
