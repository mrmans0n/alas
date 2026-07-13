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

    @Test("checkOrCompute coalesces the same target and agent key")
    func targetAwareCheckOrComputeCoalesces() async {
        let store = ACPAdapterUpdateStore(
            fileURL: tempFile(),
            successTTL: 60, failureTTL: 60,
            now: { Date() })
        let key = ACPAdapterUpdateKey(target: .ssh(host: "build-a"), agentID: "codex")

        actor Counter {
            var n = 0
            func inc() { n += 1 }
            func value() -> Int { n }
        }
        let counter = Counter()

        async let a = store.checkOrCompute(key: key) {
            await counter.inc()
            try? await Task.sleep(for: .milliseconds(50))
            return .upToDate
        }
        async let b = store.checkOrCompute(key: key) {
            await counter.inc()
            try? await Task.sleep(for: .milliseconds(50))
            return .upToDate
        }

        let results = await (a, b)
        #expect(results.0 == .upToDate)
        #expect(results.1 == .upToDate)
        #expect(await counter.value() == 1)
    }

    @Test("checkOrCompute runs independently for the same agent on two SSH hosts")
    func targetAwareCheckOrComputeIsIndependent() async {
        let store = ACPAdapterUpdateStore(
            fileURL: tempFile(),
            successTTL: 60, failureTTL: 60,
            now: { Date() })
        let hostA = ACPAdapterUpdateKey(target: .ssh(host: "build-a"), agentID: "codex")
        let hostB = ACPAdapterUpdateKey(target: .ssh(host: "build-b"), agentID: "codex")

        actor Counter {
            var n = 0
            func inc() { n += 1 }
            func value() -> Int { n }
        }
        let counter = Counter()

        async let a = store.checkOrCompute(key: hostA) {
            await counter.inc()
            try? await Task.sleep(for: .milliseconds(50))
            return .upToDate
        }
        async let b = store.checkOrCompute(key: hostB) {
            await counter.inc()
            try? await Task.sleep(for: .milliseconds(50))
            return .available(current: "1", latest: "2")
        }

        let results = await (a, b)
        #expect(results.0 == .upToDate)
        #expect(results.1 == .available(current: "1", latest: "2"))
        #expect(await counter.value() == 2)
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

    @Test("remote target state persists across store instances")
    func remoteStatePersistsAcrossInstances() async {
        let url = tempFile()
        let now = { Date() }
        let key = ACPAdapterUpdateKey(target: .ssh(host: "dev.user@host:22"), agentID: "codex")
        let a = ACPAdapterUpdateStore(fileURL: url, successTTL: 60, failureTTL: 60, now: now)
        await a.write(key: key, state: .available(current: "1", latest: "2"))
        await a.dismiss(key: key, latest: "2")

        let b = ACPAdapterUpdateStore(fileURL: url, successTTL: 60, failureTTL: 60, now: now)
        #expect(await b.read(key: key) == .available(current: "1", latest: "2"))
        #expect(await b.isDismissed(key: key, latest: "2"))
        #expect(await b.read(key: .init(target: .local, agentID: "codex")) == nil)
    }

    @Test("cache entries are isolated by target")
    func cacheIsTargetIsolated() async {
        let store = ACPAdapterUpdateStore(
            fileURL: tempFile(),
            successTTL: 60, failureTTL: 60,
            now: { Date() })
        let local = ACPAdapterUpdateKey(target: .local, agentID: "codex")
        let hostA = ACPAdapterUpdateKey(target: .ssh(host: "host-a"), agentID: "codex")
        let hostB = ACPAdapterUpdateKey(target: .ssh(host: "host-b"), agentID: "codex")

        await store.write(key: local, state: .upToDate)
        await store.write(key: hostA, state: .available(current: "1", latest: "2"))

        #expect(await store.read(key: local) == .upToDate)
        #expect(await store.read(key: hostA) == .available(current: "1", latest: "2"))
        #expect(await store.read(key: hostB) == nil)
    }

    @Test("dismissals are isolated by target")
    func dismissalsAreTargetIsolated() async {
        let store = ACPAdapterUpdateStore(
            fileURL: tempFile(),
            successTTL: 60, failureTTL: 60,
            now: { Date() })
        let local = ACPAdapterUpdateKey(target: .local, agentID: "codex")
        let remote = ACPAdapterUpdateKey(target: .ssh(host: "dev@host:22"), agentID: "codex")

        await store.dismiss(key: remote, latest: "1.2.3")

        #expect(await store.isDismissed(key: remote, latest: "1.2.3"))
        #expect(await store.isDismissed(key: local, latest: "1.2.3") == false)
    }

    @Test("TTL timestamps are independent by target")
    func ttlIsTargetIsolated() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = ACPAdapterUpdateStore(
            fileURL: tempFile(),
            successTTL: 10, failureTTL: 5,
            now: { clock })
        let hostA = ACPAdapterUpdateKey(target: .ssh(host: "host-a"), agentID: "codex")
        let hostB = ACPAdapterUpdateKey(target: .ssh(host: "host-b"), agentID: "codex")

        await store.write(key: hostA, state: .upToDate)
        clock = clock.addingTimeInterval(6)
        await store.write(key: hostB, state: .upToDate)
        clock = clock.addingTimeInterval(5)

        #expect(await store.read(key: hostA) == nil)
        #expect(await store.read(key: hostB) == .upToDate)
    }

    @Test("existing agent-only local entries remain readable and preserve dismissal state")
    func readsLegacyLocalEntry() async throws {
        let url = tempFile()
        let checkedAt = Date(timeIntervalSince1970: 1_000)
        let legacyJSON = """
        {
          "entries" : {
            "codex" : {
              "checkedAt" : "1970-01-01T00:16:40Z",
              "dismissedLatest" : "2.0.0",
              "state" : { "kind" : "upToDate" }
            }
          }
        }
        """
        try #require(legacyJSON.data(using: .utf8)).write(to: url)
        let store = ACPAdapterUpdateStore(
            fileURL: url,
            successTTL: 60, failureTTL: 60,
            now: { checkedAt })
        let local = ACPAdapterUpdateKey(target: .local, agentID: "codex")
        let remote = ACPAdapterUpdateKey(target: .ssh(host: "host-a"), agentID: "codex")

        #expect(await store.read(key: local) == .upToDate)
        #expect(await store.isDismissed(key: local, latest: "2.0.0"))
        #expect(await store.read(key: remote) == nil)

        await store.write(key: local, state: .available(current: "1", latest: "2"))
        #expect(await store.isDismissed(key: local, latest: "2.0.0"))

        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let entries = persisted?["entries"] as? [String: Any]
        #expect(entries?[local.storageKey] != nil)
    }
}
