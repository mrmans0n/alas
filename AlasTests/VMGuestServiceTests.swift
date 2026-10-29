import AlasCore
import Foundation
import Synchronization
import Testing
@testable import AlasComputerUseKit

// Main actor: VMGuestService and its coordinator are main-actor-only.
@MainActor
struct VMGuestServiceTests {
    /// Answers at once, or, for a session in `holding`, when `release` or a cancellation ends the call.
    @MainActor
    private final class FakeCoordinator: VMGuestCoordinating {
        var performed: [(command: ComputerUseCommand, sessionID: String)] = []
        var events: [(event: VMGuestLifecycleEvent, sessionID: String)] = []
        var response: AlasCLIResponse = .text(["clicked"])
        var holding: Set<String> = []
        /// Sessions whose call was cancelled, recorded as the cancellation happens.
        nonisolated let cancelled = Mutex<[String]>([])
        private var held: [String: CheckedContinuation<AlasCLIResponse, Never>] = [:]
        private var releasedEarly: [String: AlasCLIResponse] = [:]
        private var heldWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func perform(_ command: ComputerUseCommand, sessionID: String) async -> AlasCLIResponse {
            performed.append((command, sessionID))
            guard holding.contains(sessionID) else { return response }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { self.hold(sessionID, $0) }
            } onCancel: {
                cancelled.withLock { $0.append(sessionID) }
                Task { @MainActor in self.release(sessionID, with: .error("cancelled")) }
            }
        }

        func release(_ sessionID: String, with response: AlasCLIResponse) {
            if let continuation = held.removeValue(forKey: sessionID) {
                continuation.resume(returning: response)
            } else {
                releasedEarly[sessionID] = response
            }
        }

        func waitUntilHeld(_ count: Int) async {
            guard held.count < count else { return }
            await withCheckedContinuation { heldWaiters.append((count, $0)) }
        }

        private func hold(_ sessionID: String, _ continuation: CheckedContinuation<AlasCLIResponse, Never>) {
            if let response = releasedEarly.removeValue(forKey: sessionID) { return continuation.resume(returning: response) }
            held[sessionID] = continuation
            let ready = heldWaiters.filter { $0.count <= held.count }
            heldWaiters.removeAll { $0.count <= held.count }
            for waiter in ready { waiter.continuation.resume() }
        }

        func stop(sessionID: String) async { events.append((.stop, sessionID)) }
        func resume(sessionID: String) { events.append((.resume, sessionID)) }
        func turnEnded(sessionID: String) { events.append((.turnEnded, sessionID)) }
        func sessionEnded(sessionID: String) { events.append((.sessionEnded, sessionID)) }
    }

    private struct UnusedRunner: VMGuestCommandRunning {
        func run(_ command: String, timeout: Duration) async -> VMGuestRunResult {
            VMGuestRunResult(exitCode: 0, stdout: "", stderr: "", truncated: false, timedOut: false)
        }
    }

    private static func service(
        _ coordinator: FakeCoordinator, grants: (accessibility: Bool, screenRecording: Bool) = (true, true)
    ) -> VMGuestService {
        VMGuestService(coordinator: coordinator, permissions: { grants }, runner: UnusedRunner(), version: "1.2.3")
    }

    @Test func commandRoundTripsThroughTheCoordinator() async throws {
        let coordinator = FakeCoordinator()
        let click = ComputerUseCommand(action: .click, windowID: 7, ref: "e3", count: 2)
        let reply = await Self.service(coordinator).handle(.command(id: 9, sessionID: "s1", request: try click.requestJSON()))

        #expect(coordinator.performed.map(\.command) == [click])
        #expect(coordinator.performed.map(\.sessionID) == ["s1"])
        #expect(reply == .response(id: 9, body: try AlasCLIResponse.text(["clicked"]).encode()))
    }

    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func helloReportsVersionAndGrants(accessibility: Bool, screenRecording: Bool) async {
        let service = Self.service(FakeCoordinator(), grants: (accessibility, screenRecording))
        let reply = await service.handle(.hello(hostVersion: "9.9.9"))
        #expect(reply == .helloReply(
            guestVersion: "1.2.3", protocolRevision: VMGuestProtocol.revision,
            accessibility: accessibility, screenRecording: screenRecording))
    }

    @Test(arguments: [
        (false, true, "Accessibility", "it"),
        (true, false, "Screen Recording", "it"),
        (false, false, "Accessibility and Screen Recording", "them"),
    ])
    func missingGrantsPointAtTheVMsSettings(accessibility: Bool, screenRecording: Bool, missing: String, pronoun: String) async throws {
        let coordinator = FakeCoordinator()
        let service = Self.service(coordinator, grants: (accessibility, screenRecording))
        let request = try ComputerUseCommand(action: .apps).requestJSON()
        let reply = await service.handle(.command(id: 4, sessionID: "s1", request: request))

        let error = "computer_permissions: Alas VM Guest is missing \(missing) in this VM. "
            + "Ask the user to grant \(pronoun) in the VM's System Settings › Privacy & Security."
        #expect(reply == .response(id: 4, body: try AlasCLIResponse.error(error).encode()))
        #expect(coordinator.performed.isEmpty)
    }

    @Test func cancelStopsOnlyThatConnectionsCall() async throws {
        let coordinator = FakeCoordinator()
        coordinator.holding = ["a", "b"]
        let service = Self.service(coordinator)
        let request = try ComputerUseCommand(action: .apps).requestJSON()
        // The same host id on two connections.
        let first = Task { await service.handle(.command(id: 1, sessionID: "a", request: request), connection: 1) }
        let second = Task { await service.handle(.command(id: 1, sessionID: "b", request: request), connection: 2) }
        await coordinator.waitUntilHeld(2)

        #expect(await service.handle(.cancel(id: 1), connection: 1) == nil)
        #expect(coordinator.cancelled.withLock { $0 } == ["a"])
        #expect(await first.value == .response(id: 1, body: try AlasCLIResponse.error("cancelled").encode()))

        coordinator.release("b", with: .ok)
        #expect(await second.value == .response(id: 1, body: try AlasCLIResponse.ok.encode()))
    }

    @Test func closingAConnectionEndsItsCallsAndSessions() async throws {
        let coordinator = FakeCoordinator()
        coordinator.holding = ["a"]
        let service = Self.service(coordinator)
        let request = try ComputerUseCommand(action: .apps).requestJSON()
        let call = Task { await service.handle(.command(id: 1, sessionID: "a", request: request), connection: 1) }
        await coordinator.waitUntilHeld(1)
        _ = await service.handle(.command(id: 1, sessionID: "b", request: request), connection: 2)

        service.connectionClosed(1)

        #expect(coordinator.cancelled.withLock { $0 } == ["a"])
        _ = await call.value
        #expect(coordinator.events.map(\.event) == [.turnEnded, .sessionEnded])
        #expect(coordinator.events.map(\.sessionID) == ["a", "a"])
        #expect(await service.handle(.command(id: 2, sessionID: "a", request: request), connection: 1) == nil)
    }

    @Test(arguments: [VMGuestLifecycleEvent.stop, .resume, .turnEnded, .sessionEnded])
    func lifecycleEventsReachTheCoordinator(event: VMGuestLifecycleEvent) async {
        let coordinator = FakeCoordinator()
        let reply = await Self.service(coordinator).handle(.lifecycle(sessionID: "s1", event: event))
        #expect(reply == nil)
        #expect(coordinator.events.map(\.event) == [event])
        #expect(coordinator.events.map(\.sessionID) == ["s1"])
    }

    @Test func runnerTimesOutAndKeepsTheTail() async {
        let result = await VMGuestShellRunner().run("yes | head -c 1000000; sleep 30", timeout: .seconds(1))
        #expect(result.timedOut)
        #expect(result.truncated)
        #expect(result.stdout.utf8.count == 262_144)
    }

    @Test func runnerStopsWaitingForAChildThatLeftTheGroup() async {
        var runner = VMGuestShellRunner()
        runner.killGrace = .milliseconds(200)
        let start = ContinuousClock.now
        // The child starts its own session, so the group's SIGKILL misses it while it holds stdout.
        let result = await runner.run(
            #"echo started; perl -MPOSIX -e 'setsid() or die "setsid: $!"; exec "sleep", "10"' &"#, timeout: .seconds(1))
        #expect(ContinuousClock.now - start < .seconds(4))
        #expect(result.timedOut)
        #expect(result.stdout == "started\n")
    }
}
