import Foundation
import Testing
@testable import Alas

@Suite("ACPAdapterInstallCoordinator")
struct ACPAdapterInstallCoordinatorTests {
    @Test("local and SSH installs route to separate implementations")
    func routesByTarget() async throws {
        let recorder = CoordinatorInstallRecorder()
        let coordinator = makeCoordinator(recorder)

        try await coordinator.install(target: .local, agentID: "codex")
        try await coordinator.install(target: .ssh(host: "buildbox"), agentID: "codex")

        #expect(await recorder.localAgentIDs == ["codex"])
        #expect(await recorder.remoteRequests == ["buildbox|codex"])
    }

    @Test("same target and agent coalesce into one task")
    func sameKeyCoalesces() async throws {
        let recorder = CoordinatorInstallRecorder(delay: .milliseconds(100))
        let coordinator = makeCoordinator(recorder)

        async let first: Void = coordinator.install(target: .ssh(host: "buildbox"), agentID: "codex")
        async let second: Void = coordinator.install(target: .ssh(host: "buildbox"), agentID: "codex")
        _ = try await (first, second)

        #expect(await recorder.remoteRequests == ["buildbox|codex"])
        #expect(await coordinator.isInstalling(target: .ssh(host: "buildbox"), agentID: "codex") == false)
    }

    @Test("different target-agent keys run independently")
    func differentKeysAreIndependent() async throws {
        let recorder = CoordinatorInstallRecorder(delay: .milliseconds(100))
        let coordinator = makeCoordinator(recorder)

        async let first: Void = coordinator.install(target: .ssh(host: "one"), agentID: "codex")
        async let second: Void = coordinator.install(target: .ssh(host: "two"), agentID: "pi")
        _ = try await (first, second)

        #expect(await recorder.maximumActiveRemoteInstalls == 2)
        #expect(Set(await recorder.remoteRequests) == ["one|codex", "two|pi"])
    }

    @Test("a failed task is removed so retry can proceed")
    func failureClearsInFlight() async throws {
        let recorder = CoordinatorInstallRecorder(failuresRemaining: 1)
        let coordinator = makeCoordinator(recorder)

        await #expect(throws: CoordinatorTestError.failed) {
            try await coordinator.install(target: .ssh(host: "buildbox"), agentID: "codex")
        }
        try await coordinator.install(target: .ssh(host: "buildbox"), agentID: "codex")

        #expect(await recorder.remoteRequests.count == 2)
    }

    @Test("unsupported remote agents never touch the local registry")
    func unsupportedRemoteDoesNotRouteLocally() async {
        let recorder = CoordinatorInstallRecorder()
        let coordinator = makeCoordinator(recorder)

        await #expect(throws: ACPRemoteAdapterInstallError.unsupportedAgent("custom")) {
            try await coordinator.install(target: .ssh(host: "buildbox"), agentID: "custom")
        }
        #expect(await recorder.localAgentIDs.isEmpty)
        #expect(await recorder.remoteRequests.isEmpty)
    }

    private func makeCoordinator(_ recorder: CoordinatorInstallRecorder) -> ACPAdapterInstallCoordinator {
        ACPAdapterInstallCoordinator(
            localInstall: { agentID in try await recorder.installLocal(agentID) },
            remoteInstall: { host, descriptor in try await recorder.installRemote(host, descriptor) }
        )
    }
}

private enum CoordinatorTestError: Error {
    case failed
}

private actor CoordinatorInstallRecorder {
    private let delay: Duration
    private var failuresRemaining: Int
    private(set) var localAgentIDs: [String] = []
    private(set) var remoteRequests: [String] = []
    private var activeRemoteInstalls = 0
    private(set) var maximumActiveRemoteInstalls = 0

    init(delay: Duration = .zero, failuresRemaining: Int = 0) {
        self.delay = delay
        self.failuresRemaining = failuresRemaining
    }

    func installLocal(_ agentID: String) async throws {
        localAgentIDs.append(agentID)
    }

    func installRemote(_ host: String, _ descriptor: ACPManagedAdapterDescriptor) async throws {
        remoteRequests.append("\(host)|\(descriptor.agentID)")
        activeRemoteInstalls += 1
        maximumActiveRemoteInstalls = max(maximumActiveRemoteInstalls, activeRemoteInstalls)
        defer { activeRemoteInstalls -= 1 }
        if delay != .zero {
            try await Task.sleep(for: delay)
        }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw CoordinatorTestError.failed
        }
    }
}
