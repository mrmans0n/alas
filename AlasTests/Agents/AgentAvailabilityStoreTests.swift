import Testing
@testable import Alas

@MainActor
struct AgentAvailabilityStoreTests {
    @Test func remoteLoadPublishesFilteredCatalogInCatalogOrder() async {
        let store = AgentAvailabilityStore { _, _, _ in
            ProcessResult(exitCode: 0, stdout: "1\n0\n", stderr: "")
        }
        let candidates = [
            TestAgents.custom(id: "one", binary: "one"),
            TestAgents.custom(id: "two", binary: "two")
        ]

        await store.load(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)

        #expect(store.state(target: .ssh(host: "dev"), worktreePath: "/srv/repo", localAgents: []).agents.map(\.id) == ["one", "two"])
    }

    @Test func hostsDoNotShareAvailability() async {
        let store = AgentAvailabilityStore { host, _, _ in
            ProcessResult(exitCode: 0, stdout: host == "dev-a" ? "0\n" : "1\n", stderr: "")
        }
        let candidates = [
            TestAgents.custom(id: "one", binary: "one"),
            TestAgents.custom(id: "two", binary: "two")
        ]

        await store.load(target: .ssh(host: "dev-a"), worktreePath: "/srv/repo", candidates: candidates)
        await store.load(target: .ssh(host: "dev-b"), worktreePath: "/srv/repo", candidates: candidates)

        #expect(store.state(target: .ssh(host: "dev-a"), worktreePath: "/srv/repo", localAgents: []).agents.map(\.id) == ["one"])
        #expect(store.state(target: .ssh(host: "dev-b"), worktreePath: "/srv/repo", localAgents: []).agents.map(\.id) == ["two"])
    }

    @Test func relativeExecutablesSeparateWorktreeCacheKeys() async {
        let store = AgentAvailabilityStore { _, path, _ in
            ProcessResult(exitCode: 0, stdout: path == "/srv/one" ? "0\n" : "", stderr: "")
        }
        let candidates = [TestAgents.custom(id: "repo-agent", binary: "tools/agent")]

        await store.load(target: .ssh(host: "dev"), worktreePath: "/srv/one", candidates: candidates)
        await store.load(target: .ssh(host: "dev"), worktreePath: "/srv/two", candidates: candidates)

        #expect(store.state(target: .ssh(host: "dev"), worktreePath: "/srv/one", localAgents: []).agents.map(\.id) == ["repo-agent"])
        #expect(store.state(target: .ssh(host: "dev"), worktreePath: "/srv/two", localAgents: []).agents.isEmpty)
    }

    @Test func concurrentLoadsShareOneInFlightProbe() async {
        let counter = ProbeCounter()
        let store = AgentAvailabilityStore { _, _, _ in
            await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return ProcessResult(exitCode: 0, stdout: "0\n", stderr: "")
        }
        let candidates = [TestAgents.custom(id: "one", binary: "one")]

        async let first: Void = store.load(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)
        async let second: Void = store.load(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)
        _ = await (first, second)

        #expect(await counter.value == 1)
    }

    @Test func connectionFailureIsVisibleAndRetryReplacesIt() async {
        let counter = ProbeCounter()
        let store = AgentAvailabilityStore { _, _, _ in
            let attempt = await counter.increment()
            return attempt == 1
                ? ProcessResult(exitCode: 255, stdout: "", stderr: "offline")
                : ProcessResult(exitCode: 0, stdout: "0\n", stderr: "")
        }
        let candidates = [TestAgents.custom(id: "one", binary: "one")]

        await store.load(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)
        #expect(store.state(target: .ssh(host: "dev"), worktreePath: "/srv/repo", localAgents: []) == .failed("Could not check agents on dev."))

        await store.retry(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)

        #expect(store.state(target: .ssh(host: "dev"), worktreePath: "/srv/repo", localAgents: []).agents.map(\.id) == ["one"])
    }

    @Test func localStateReturnsLocalAgentsWithoutProbe() {
        let local = [TestAgents.custom(id: "local", binary: "local")]
        let store = AgentAvailabilityStore { _, _, _ in
            Issue.record("local state must not probe")
            return ProcessResult(exitCode: 1, stdout: "", stderr: "")
        }

        #expect(store.state(target: .local, worktreePath: "/tmp/repo", localAgents: local).agents.map(\.id) == ["local"])
    }

    @Test func invalidationRemovesOnlyTheMatchingHost() async {
        let store = AgentAvailabilityStore { _, _, _ in
            ProcessResult(exitCode: 0, stdout: "0\n", stderr: "")
        }
        let candidates = [TestAgents.custom(id: "one", binary: "one")]

        await store.load(target: .ssh(host: "dev-a"), worktreePath: "/srv/repo", candidates: candidates)
        await store.load(target: .ssh(host: "dev-b"), worktreePath: "/srv/repo", candidates: candidates)
        store.invalidate(target: .ssh(host: "dev-a"), worktreePath: "/srv/repo")

        #expect(store.state(target: .ssh(host: "dev-a"), worktreePath: "/srv/repo", localAgents: []) == .loading)
        #expect(store.state(target: .ssh(host: "dev-b"), worktreePath: "/srv/repo", localAgents: []).agents.map(\.id) == ["one"])
    }

    @Test func invalidationClearsEveryWorktreeCacheKeyForTheHost() async {
        let store = AgentAvailabilityStore { _, _, _ in
            ProcessResult(exitCode: 0, stdout: "0\n", stderr: "")
        }
        let candidates = [TestAgents.custom(id: "repo-agent", binary: "tools/agent")]

        await store.load(target: .ssh(host: "dev"), worktreePath: "/srv/one", candidates: candidates)
        await store.load(target: .ssh(host: "dev"), worktreePath: "/srv/two", candidates: candidates)

        store.invalidate(target: .ssh(host: "dev"), worktreePath: "/srv/one")

        #expect(store.state(target: .ssh(host: "dev"), worktreePath: "/srv/one", localAgents: []) == .loading)
        #expect(store.state(target: .ssh(host: "dev"), worktreePath: "/srv/two", localAgents: []) == .loading)
    }

    @Test func invalidationAdvancesGenerationForMountedViewTasks() async {
        let store = AgentAvailabilityStore { _, _, _ in
            ProcessResult(exitCode: 0, stdout: "0\n", stderr: "")
        }
        let candidates = [TestAgents.custom(id: "one", binary: "one")]

        await store.load(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)
        let loadedGeneration = store.generation

        store.invalidate(target: .ssh(host: "dev"), worktreePath: "/srv/repo")
        #expect(store.generation == loadedGeneration + 1)

        store.invalidateAll()
        #expect(store.generation == loadedGeneration + 2)
    }
}

private actor ProbeCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }

    var value: Int { count }
}

private enum TestAgents {
    static func custom(id: String, binary: String) -> AgentDefinition {
        AgentDefinition(
            id: id,
            displayName: id,
            binary: binary,
            binaryOverride: nil,
            promptModeArgs: [],
            bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )
    }
}
