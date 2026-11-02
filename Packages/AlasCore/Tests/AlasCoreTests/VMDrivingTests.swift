import Foundation
import Testing

@testable import AlasPlatform

struct VMDrivingTests {
    private static let now = Date(timeIntervalSince1970: 1_000_000)

    private static func call(secondsAgo: TimeInterval) -> (sessionID: String, tool: String, at: Date) {
        (sessionID: "s1", tool: "computer_click", at: now.addingTimeInterval(-secondsAgo))
    }

    @Test(arguments: [
        (nil as TimeInterval?, false, VMDriver.idle),
        (10 as TimeInterval?, false, VMDriver.agent(sessionID: "s1", tool: "computer_click", at: now.addingTimeInterval(-10))),
        (29 as TimeInterval?, false, VMDriver.agent(sessionID: "s1", tool: "computer_click", at: now.addingTimeInterval(-29))),
        (31 as TimeInterval?, false, VMDriver.idle),
        (5 as TimeInterval?, true, VMDriver.user),
    ])
    func driverFollowsTakeOverAndTheLastAgentCall(secondsAgo: TimeInterval?, takenOver: Bool, expected: VMDriver) {
        let last = secondsAgo.map { Self.call(secondsAgo: $0) }
        #expect(VMDriver.current(lastAgentCall: last, takenOver: takenOver, now: Self.now) == expected)
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
        #expect(AlasPlatform.stoppedVMDecision(runningElsewhere: elsewhere, isStatusCall: isStatus) == expected)
    }

    @Test func messagesAreExact() {
        #expect(VMAutoStartMessages.userDriving == "computer_user_active: The user is driving this VM. Try again after they hand it back.")
        #expect(VMAutoStartMessages.starting == "computer_vm_starting: This worktree's VM is still starting. Try again in a moment.")
        #expect(VMAutoStartMessages.slotPending == "computer_vm_slot_pending: Both VM slots are busy and the user hasn't chosen which to pause yet. Try again in a moment.")
        #expect(VMAutoStartMessages.userDeclined == "computer_vm_stopped: The user chose not to start this worktree's VM.")
    }
}
