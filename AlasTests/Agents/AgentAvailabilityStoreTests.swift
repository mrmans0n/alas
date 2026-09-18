import Foundation
import Testing
@testable import Alas

private func agentProbeLine(_ index: Int) -> String {
    "__ALAS_AGENT_PROBE_AVAILABLE__ \(index)\n"
}

@MainActor
struct AgentAvailabilityStoreTests {
    @Test func remoteLoadPublishesFilteredCatalogInCatalogOrder() async {
        let store = AgentAvailabilityStore { _, _, _ in
            ProcessResult(exitCode: 0, stdout: "\(agentProbeLine(1))\(agentProbeLine(0))", stderr: "")
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
            ProcessResult(exitCode: 0, stdout: host == "dev-a" ? agentProbeLine(0) : agentProbeLine(1), stderr: "")
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
            ProcessResult(exitCode: 0, stdout: path == "/srv/one" ? agentProbeLine(0) : "", stderr: "")
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
            return ProcessResult(exitCode: 0, stdout: agentProbeLine(0), stderr: "")
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
                : ProcessResult(exitCode: 0, stdout: agentProbeLine(0), stderr: "")
        }
        let candidates = [TestAgents.custom(id: "one", binary: "one")]

        await store.load(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)
        #expect(store.state(target: .ssh(host: "dev"), worktreePath: "/srv/repo", localAgents: []) == .failed("Could not check agents on dev."))

        await store.retry(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)

        #expect(store.state(target: .ssh(host: "dev"), worktreePath: "/srv/repo", localAgents: []).agents.map(\.id) == ["one"])
    }

    @Test func loadRetryingFailureRefreshesCachedProbeFailure() async {
        let counter = ProbeCounter()
        let store = AgentAvailabilityStore { _, _, _ in
            let attempt = await counter.increment()
            return attempt == 1
                ? ProcessResult(exitCode: 255, stdout: "", stderr: "offline")
                : ProcessResult(exitCode: 0, stdout: agentProbeLine(0), stderr: "")
        }
        let candidates = [TestAgents.custom(id: "one", binary: "one")]

        await store.load(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)
        await store.loadRetryingFailure(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)

        #expect(await counter.value == 2)
        #expect(store.state(target: .ssh(host: "dev"), worktreePath: "/srv/repo", localAgents: []).agents.map(\.id) == ["one"])
    }

    @Test func freshSuccessfulAvailabilityDoesNotProbeAgain() async {
        let counter = ProbeCounter()
        let store = AgentAvailabilityStore { _, _, _ in
            await counter.increment()
            return ProcessResult(exitCode: 0, stdout: agentProbeLine(0), stderr: "")
        }
        let candidates = [TestAgents.custom(id: "one", binary: "one")]

        await store.load(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)
        await store.load(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)

        #expect(await counter.value == 1)
    }

    @Test func staleSuccessfulAvailabilityRefreshesOnLoad() async {
        let counter = ProbeCounter()
        let clock = TestClock()
        let store = AgentAvailabilityStore(
            probe: { _, _, _ in
                let attempt = await counter.increment()
                return ProcessResult(
                    exitCode: 0,
                    stdout: attempt == 1 ? agentProbeLine(0) : "\(agentProbeLine(0))\(agentProbeLine(1))",
                    stderr: ""
                )
            },
            now: { clock.now }
        )
        let candidates = [
            TestAgents.custom(id: "one", binary: "one"),
            TestAgents.custom(id: "two", binary: "two")
        ]

        await store.load(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)
        #expect(store.state(target: .ssh(host: "dev"), worktreePath: "/srv/repo", localAgents: []).agents.map(\.id) == ["one"])

        clock.advance(by: AgentAvailabilityStore.successfulProbeTTL)
        await store.load(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)

        #expect(await counter.value == 2)
        #expect(store.state(target: .ssh(host: "dev"), worktreePath: "/srv/repo", localAgents: []).agents.map(\.id) == ["one", "two"])
    }

    @Test func successfulAvailabilityAdvancesGenerationAtExpiry() async {
        let counter = ProbeCounter()
        let scheduledRefresh = ScheduledRefreshCapture()
        let store = AgentAvailabilityStore(
            probe: { _, _, _ in
                let attempt = await counter.increment()
                return ProcessResult(
                    exitCode: 0,
                    stdout: attempt == 1 ? agentProbeLine(0) : "\(agentProbeLine(0))\(agentProbeLine(1))",
                    stderr: ""
                )
            },
            refreshScheduler: { delay, action in
                #expect(delay == AgentAvailabilityStore.successfulProbeTTL)
                return scheduledRefresh.schedule(action)
            }
        )
        let candidates = [
            TestAgents.custom(id: "one", binary: "one"),
            TestAgents.custom(id: "two", binary: "two")
        ]

        await store.load(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)
        let loadedGeneration = store.generation
        #expect(store.state(target: .ssh(host: "dev"), worktreePath: "/srv/repo", localAgents: []).agents.map(\.id) == ["one"])

        await scheduledRefresh.run()

        #expect(await counter.value == 1)
        #expect(store.generation == loadedGeneration + 1)
        #expect(store.state(target: .ssh(host: "dev"), worktreePath: "/srv/repo", localAgents: []).agents.map(\.id) == ["one"])

        await store.load(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)

        #expect(await counter.value == 2)
        #expect(store.state(target: .ssh(host: "dev"), worktreePath: "/srv/repo", localAgents: []).agents.map(\.id) == ["one", "two"])
    }

    @Test func staleSuccessfulAvailabilityStaysVisibleDuringRefresh() async {
        let counter = ProbeCounter()
        let clock = TestClock()
        let probe = PausedProbe()
        let store = AgentAvailabilityStore(
            probe: { _, _, _ in
                let attempt = await counter.increment()
                if attempt == 2 {
                    await probe.waitUntilReleased()
                }
                return ProcessResult(
                    exitCode: 0,
                    stdout: attempt == 1 ? agentProbeLine(0) : "\(agentProbeLine(0))\(agentProbeLine(1))",
                    stderr: ""
                )
            },
            now: { clock.now }
        )
        let candidates = [
            TestAgents.custom(id: "one", binary: "one"),
            TestAgents.custom(id: "two", binary: "two")
        ]

        await store.load(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)
        clock.advance(by: AgentAvailabilityStore.successfulProbeTTL)

        let refresh = Task {
            await store.load(target: .ssh(host: "dev"), worktreePath: "/srv/repo", candidates: candidates)
        }
        await probe.waitUntilPaused()

        #expect(store.state(target: .ssh(host: "dev"), worktreePath: "/srv/repo", localAgents: []).agents.map(\.id) == ["one"])

        await probe.release()
        await refresh.value

        #expect(store.state(target: .ssh(host: "dev"), worktreePath: "/srv/repo", localAgents: []).agents.map(\.id) == ["one", "two"])
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
            ProcessResult(exitCode: 0, stdout: agentProbeLine(0), stderr: "")
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
            ProcessResult(exitCode: 0, stdout: agentProbeLine(0), stderr: "")
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
            ProcessResult(exitCode: 0, stdout: agentProbeLine(0), stderr: "")
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

private actor PausedProbe {
    private var pausedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var paused = false
    private var released = false

    func waitUntilReleased() async {
        await withCheckedContinuation { continuation in
            paused = true
            pausedContinuation?.resume()
            pausedContinuation = nil
            if released {
                continuation.resume()
            } else {
                releaseContinuation = continuation
            }
        }
    }

    func waitUntilPaused() async {
        await withCheckedContinuation { continuation in
            if paused {
                continuation.resume()
            } else {
                pausedContinuation = continuation
            }
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
private final class ScheduledRefreshCapture {
    private var action: (@MainActor @Sendable () async -> Void)?

    func schedule(_ action: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        self.action = action
        return Task { @MainActor in }
    }

    func run() async {
        await action?()
    }
}

@MainActor
private final class TestClock {
    private(set) var now = Date(timeIntervalSinceReferenceDate: 0)

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
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
