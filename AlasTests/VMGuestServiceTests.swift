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

    /// A `.response` with its body decoded: the encoded key order isn't fixed, so bytes can't be compared.
    private static func decoded(_ message: VMGuestMessage?) -> (id: UInt64, response: AlasCLIResponse)? {
        guard case .response(let id, let body)? = message, let response = try? AlasCLIResponse.decode(body) else {
            return nil
        }
        return (id, response)
    }

    @Test func commandRoundTripsThroughTheCoordinator() async throws {
        let coordinator = FakeCoordinator()
        let click = ComputerUseCommand(action: .click, windowID: 7, ref: "e3", count: 2)
        let reply = await Self.service(coordinator).handle(.command(id: 9, sessionID: "s1", request: try click.requestJSON()))

        #expect(coordinator.performed.map(\.command) == [click])
        #expect(coordinator.performed.map(\.sessionID) == ["s1"])
        let decoded = Self.decoded(reply)
        #expect(decoded?.id == 9)
        #expect(decoded?.response == .text(["clicked"]))
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
        let decoded = Self.decoded(reply)
        #expect(decoded?.id == 4)
        #expect(decoded?.response == .error(error))
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
        let cancelled = Self.decoded(await first.value)
        #expect(cancelled?.id == 1)
        #expect(cancelled?.response == .error("cancelled"))

        coordinator.release("b", with: .ok)
        let answered = Self.decoded(await second.value)
        #expect(answered?.id == 1)
        #expect(answered?.response == .ok)
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

    /// A runner that doesn't read the CI user's zsh startup files.
    private static var plainRunner: VMGuestShellRunner {
        var runner = VMGuestShellRunner()
        runner.shellArguments = ["/bin/sh", "-c"]
        return runner
    }

    @Test(.timeLimit(.minutes(1))) func runnerTimesOutAndKeepsTheTail() async {
        let result = await Self.plainRunner.run("yes | head -c 1000000; sleep 30", timeout: .seconds(1))
        #expect(result.timedOut)
        #expect(result.truncated)
        #expect(result.stdout.utf8.count == 262_144)
    }

    @Test(.timeLimit(.minutes(1))) func runnerStopsWaitingForAChildThatLeftTheGroup() async {
        var runner = Self.plainRunner
        runner.killGrace = .milliseconds(200)
        let start = ContinuousClock.now
        // The child starts its own session, so the group's SIGKILL misses it while it holds stdout.
        let result = await runner.run(
            #"echo started; perl -MPOSIX -e 'setsid() or die "setsid: $!"; exec "sleep", "10"' &"#, timeout: .seconds(1))
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(result.timedOut)
        #expect(result.stdout == "started\n")
    }

    @Test(.timeLimit(.minutes(1))) func runnerKillsAMemberThatIgnoresSIGTERM() async throws {
        var runner = Self.plainRunner
        runner.killGrace = .seconds(20)
        // The shell dies on SIGTERM and the child's output is gone, so the run ends before the kill grace.
        let result = await runner.run(
            #"perl -e '$SIG{TERM} = "IGNORE"; sleep 30' >/dev/null 2>&1 & echo $!; wait"#, timeout: .seconds(1))
        #expect(result.timedOut)
        let child = try #require(pid_t(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = ContinuousClock.now + .seconds(5)
        while kill(child, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(kill(child, 0) != 0)
    }
}
