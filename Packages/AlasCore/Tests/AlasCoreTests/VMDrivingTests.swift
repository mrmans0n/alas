import Foundation
import Testing

@testable import AlasPlatform

struct VMDrivingTests {
    private static let now = Date(timeIntervalSince1970: 1_000_000)

    private static func call(secondsAgo: TimeInterval) -> (sessionID: String, tool: String, at: Date) {
        (sessionID: "s1", tool: "computer_click", at: now.addingTimeInterval(-secondsAgo))
    }

    @Test(arguments: [
        (nil as TimeInterval?, false, false, VMDriver.idle),
        (10 as TimeInterval?, false, false, VMDriver.agent(sessionID: "s1", tool: "computer_click", at: now.addingTimeInterval(-10))),
        (29 as TimeInterval?, false, false, VMDriver.agent(sessionID: "s1", tool: "computer_click", at: now.addingTimeInterval(-29))),
        (31 as TimeInterval?, false, false, VMDriver.idle),
        // A call still running drives however long ago it began.
        (31 as TimeInterval?, true, false, VMDriver.agent(sessionID: "s1", tool: "computer_click", at: now.addingTimeInterval(-31))),
        // Handed back or stopped mid-call: the call no longer counts.
        (nil as TimeInterval?, true, false, VMDriver.idle),
        (5 as TimeInterval?, false, true, VMDriver.user),
    ])
    func driverFollowsTakeOverAndTheLastAgentCall(
        secondsAgo: TimeInterval?, inFlight: Bool, takenOver: Bool, expected: VMDriver
    ) {
        let last = secondsAgo.map { Self.call(secondsAgo: $0) }
        #expect(VMDriver.current(lastAgentCall: last, inFlight: inFlight, takenOver: takenOver, now: Self.now) == expected)
    }

    @Test(arguments: [
        (VMDriver.idle, true, VMAgentCallDecision.proceed),
        (VMDriver.agent(sessionID: "s", tool: "vm_run", at: now), false, VMAgentCallDecision.proceed),
        (VMDriver.user, true, VMAgentCallDecision.userDriving),
    ])
    func viewInputAndAgentCallsByDriver(driver: VMDriver, input: Bool, decision: VMAgentCallDecision) {
        #expect(VMDriver.allowsViewInput(driver) == input)
        #expect(VMDriver.decision(for: driver) == decision)
    }

    @Test(arguments: [
        (true, false, VMStoppedDecision.runningElsewhere),
        (true, true, VMStoppedDecision.runningElsewhere),
        (false, true, VMStoppedDecision.refuse),
        (false, false, VMStoppedDecision.start),
    ])
    func stoppedVMDecision(elsewhere: Bool, isStatus: Bool, expected: VMStoppedDecision) {
        #expect(VMStoppedDecision.decide(runningElsewhere: elsewhere, isStatusCall: isStatus) == expected)
    }
}
