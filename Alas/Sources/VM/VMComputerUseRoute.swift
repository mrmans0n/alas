/// Where one `computer_*` call from a worktree session goes, decided per call so a VM
/// started mid-session takes over on the next call.
enum VMComputerUseRoute: Equatable {
    /// The user's desktop, through the host coordinator.
    case desktop
    /// The guest helper of the worktree's VM, which this process runs.
    case guest(worktreeID: String)
    /// The worktree has a VM, but this process doesn't run it.
    case vmNotRunning(worktreeID: String)
    /// Whether the worktree has a VM couldn't be read; never the desktop, which it may not mean.
    case vmStateUnreadable(worktreeID: String)

    static let vmNotRunningMessage = "computer_vm_stopped: This worktree's VM isn't running. Start it from its VM tab."
    static let vmStateUnreadableMessage = "computer_vm_stopped: Couldn't read this worktree's VM state. Try again."

    /// `hasVM` is nil when the VM registry couldn't be read.
    static func resolve(worktreeID: String?, hasVM: Bool?, runningHere: Bool) -> VMComputerUseRoute {
        guard let worktreeID else { return .desktop }
        switch hasVM {
        case nil: return .vmStateUnreadable(worktreeID: worktreeID)
        case false?: return .desktop
        case true?: return runningHere ? .guest(worktreeID: worktreeID) : .vmNotRunning(worktreeID: worktreeID)
        }
    }
}
