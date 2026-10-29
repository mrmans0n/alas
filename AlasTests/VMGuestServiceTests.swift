import AlasCore
import Foundation
import Testing
@testable import AlasComputerUseKit

// Main actor: VMGuestService and its coordinator are main-actor-only.
@MainActor
struct VMGuestServiceTests {
    @MainActor
    private final class FakeCoordinator: VMGuestCoordinating {
        var performed: [(command: ComputerUseCommand, sessionID: String)] = []
        var events: [(event: VMGuestLifecycleEvent, sessionID: String)] = []
        var response: AlasCLIResponse = .text(["clicked"])

        func perform(_ command: ComputerUseCommand, sessionID: String) async -> AlasCLIResponse {
            performed.append((command, sessionID))
            return response
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
        #expect(reply == .helloReply(guestVersion: "1.2.3", accessibility: accessibility, screenRecording: screenRecording))
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
        #expect(result.stdout.utf8.count == VMGuestShellRunner.outputLimit)
        #expect(VMGuestShellRunner.outputLimit == 262_144)
    }
}
