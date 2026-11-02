import Foundation

/// Who is driving a worktree VM right now. Held in memory per VM record.
public enum VMDriver: Equatable, Sendable {
    case idle
    case agent(sessionID: String, tool: String, at: Date)
    case user

    /// An agent call counts as driving for this long.
    public static let agentWindow: TimeInterval = 30

    public static func current(
        lastAgentCall: (sessionID: String, tool: String, at: Date)?, takenOver: Bool, now: Date
    ) -> VMDriver {
        if takenOver { return .user }
        guard let call = lastAgentCall, now.timeIntervalSince(call.at) < agentWindow else { return .idle }
        return .agent(sessionID: call.sessionID, tool: call.tool, at: call.at)
    }

    /// The VM view takes keyboard and mouse input unless an agent is driving.
    public static func allowsViewInput(_ driver: VMDriver) -> Bool {
        if case .agent = driver { return false }
        return true
    }

    public static func decision(for driver: VMDriver) -> VMAgentCallDecision {
        driver == .user ? .userDriving : .proceed
    }
}

public enum VMAgentCallDecision: Equatable, Sendable {
    case proceed
    case userDriving
}

public enum VMStoppedDecision: Equatable, Sendable {
    case start
    case runningElsewhere
    case refuse

    /// What an agent call does when its VM is not running here.
    public static func decide(runningElsewhere: Bool, isStatusCall: Bool) -> VMStoppedDecision {
        if runningElsewhere { return .runningElsewhere }
        return isStatusCall ? .refuse : .start
    }
}

public enum VMAutoStartMessages {
    public static let userDriving = "computer_user_active: The user is driving this VM. Try again after they hand it back."
    public static let starting = "computer_vm_starting: This worktree's VM is still starting. Try again in a moment."
    public static let slotPending = "computer_vm_slot_pending: Both VM slots are busy and the user hasn't chosen which to pause yet. Try again in a moment."
    public static let userDeclined = "computer_vm_stopped: The user chose not to start this worktree's VM."
}
