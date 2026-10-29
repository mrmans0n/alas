/// Where one `computer_*` call from a worktree session goes, decided per call so a VM
/// started mid-session takes over on the next call.
enum VMComputerUseRoute: Equatable {
    /// The user's desktop, through the host coordinator.
    case desktop
    /// The guest helper of the worktree's VM, which this process runs.
    case guest(worktreeID: String)
    /// The worktree has a VM, but this process doesn't run it.
    case vmNotRunning(worktreeID: String)

    static let vmNotRunningMessage = "computer_vm_stopped: This worktree's VM isn't running. Start it from its VM tab."

    static func resolve(worktreeID: String?, hasVM: Bool, runningHere: Bool) -> VMComputerUseRoute {
        guard let worktreeID, hasVM else { return .desktop }
        return runningHere ? .guest(worktreeID: worktreeID) : .vmNotRunning(worktreeID: worktreeID)
    }
}
