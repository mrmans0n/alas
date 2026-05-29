import Foundation
import Testing
@testable import Alas

@Suite("ACPAdapterUpdateStore")
struct ACPAdapterUpdateStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-acp-updates-\(UUID().uuidString).json")
    }

    @Test("write then read returns the same state when fresh")
    func writeReadFresh() async {
        let store = ACPAdapterUpdateStore(
            fileURL: tempFile(),
            successTTL: 60, failureTTL: 60,
            now: { Date() })
        await store.write(agentID: "claude", state: .available(current: "1", latest: "2"))
        let r = await store.read(agentID: "claude")
        #expect(r == .available(current: "1", latest: "2"))
    }

    @Test("read past success TTL returns nil")
    func successTtlExpires() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = ACPAdapterUpdateStore(
            fileURL: tempFile(),
            successTTL: 10, failureTTL: 5,
            now: { clock })
        await store.write(agentID: "claude", state: .upToDate)
        clock = clock.addingTimeInterval(11)
        let r = await store.read(agentID: "claude")
        #expect(r == nil)
    }

    @Test("failure TTL is shorter than success TTL")
    func failureTtlIsShorter() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = ACPAdapterUpdateStore(
            fileURL: tempFile(),
            successTTL: 10, failureTTL: 5,
            now: { clock })
        await store.write(agentID: "claude", state: .unknown)
        clock = clock.addingTimeInterval(6)
        let r = await store.read(agentID: "claude")
        #expect(r == nil)
    }

    @Test("isDismissed matches only the exact latest version")
    func dismissExactMatch() async {
        let store = ACPAdapterUpdateStore(
            fileURL: tempFile(),
            successTTL: 60, failureTTL: 60,
            now: { Date() })
        await store.dismiss(agentID: "claude", latest: "1.1.0")
        #expect(await store.isDismissed(agentID: "claude", latest: "1.1.0"))
        #expect(await store.isDismissed(agentID: "claude", latest: "1.2.0") == false)
    }

    @Test("clear removes cache and dismissal for one agent only")
    func clearIsolated() async {
        let store = ACPAdapterUpdateStore(
            fileURL: tempFile(),
            successTTL: 60, failureTTL: 60,
            now: { Date() })
        await store.write(agentID: "claude", state: .upToDate)
        await store.dismiss(agentID: "claude", latest: "1.0.0")
        await store.write(agentID: "codex", state: .upToDate)

        await store.clear(agentID: "claude")

        #expect(await store.read(agentID: "claude") == nil)
        #expect(await store.isDismissed(agentID: "claude", latest: "1.0.0") == false)
        #expect(await store.read(agentID: "codex") == .upToDate)
    }

    @Test("checkOrCompute returns cached result without invoking the closure")
    func checkOrComputeUsesCache() async {
        let store = ACPAdapterUpdateStore(
            fileURL: tempFile(),
            successTTL: 60, failureTTL: 60,
            now: { Date() })
        await store.write(agentID: "claude", state: .upToDate)
        var calls = 0
        let r = await store.checkOrCompute(agentID: "claude") {
            calls += 1
            return .available(current: "1", latest: "2")
        }
        #expect(r == .upToDate)
        #expect(calls == 0)
    }

    @Test("checkOrCompute coalesces concurrent in-flight checks for the same agent")
    func checkOrComputeCoalesces() async {
        let store = ACPAdapterUpdateStore(
            fileURL: tempFile(),
            successTTL: 60, failureTTL: 60,
            now: { Date() })

        actor Counter { var n = 0
        func inc() { n += 1 }
        func value() -> Int { n } }
        let counter = Counter()

        async let a = store.checkOrCompute(agentID: "claude") {
            await counter.inc()
            try? await Task.sleep(for: .milliseconds(50))
            return .available(current: "1", latest: "2")
        }
        async let b = store.checkOrCompute(agentID: "claude") {
            await counter.inc()
            try? await Task.sleep(for: .milliseconds(50))
            return .available(current: "1", latest: "2")
        }
        _ = await (a, b)
        #expect(await counter.value() == 1)
    }

    @Test("corrupt on-disk JSON is treated as missing, not fatal")
    func corruptFileIsRecovered() async throws {
        let url = tempFile()
        try "not json {{".data(using: .utf8)!.write(to: url)

        let store = ACPAdapterUpdateStore(
            fileURL: url,
            successTTL: 60, failureTTL: 60,
            now: { Date() })
        #expect(await store.read(agentID: "claude") == nil)

        // Subsequent writes succeed and produce a valid file.
        await store.write(agentID: "claude", state: .upToDate)
        #expect(await store.read(agentID: "claude") == .upToDate)
    }

    @Test("state persists across store instances")
    func persistsAcrossInstances() async {
        let url = tempFile()
        let now = { Date() }
        let a = ACPAdapterUpdateStore(fileURL: url, successTTL: 60, failureTTL: 60, now: now)
        await a.write(agentID: "claude", state: .available(current: "1", latest: "2"))
        await a.dismiss(agentID: "claude", latest: "2")

        let b = ACPAdapterUpdateStore(fileURL: url, successTTL: 60, failureTTL: 60, now: now)
        #expect(await b.read(agentID: "claude") == .available(current: "1", latest: "2"))
        #expect(await b.isDismissed(agentID: "claude", latest: "2"))
    }
}
