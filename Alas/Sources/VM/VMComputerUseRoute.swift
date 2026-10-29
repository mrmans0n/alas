import AlasComputerUseKit
import Foundation

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

    static let vmMissingMessage = "computer_vm_missing: This worktree has no VM. Create one from its VM tab."
    /// Where the guest sees the worktree VM's transfer folder.
    static let transferGuestPath = "/Volumes/My Shared Files/transfer"

    /// `hasVM` is nil when the VM registry couldn't be read.
    static func resolve(worktreeID: String?, hasVM: Bool?, runningHere: Bool) -> VMComputerUseRoute {
        guard let worktreeID else { return .desktop }
        switch hasVM {
        case nil: return .vmStateUnreadable(worktreeID: worktreeID)
        case false?: return .desktop
        case true?: return runningHere ? .guest(worktreeID: worktreeID) : .vmNotRunning(worktreeID: worktreeID)
        }
    }

    // MARK: - vm_* replies

    /// The `vm_status` reply for this route. `helper`, the guest's hello or why it failed, is used
    /// only when the VM runs here; the transfer paths are given only when a VM is known to exist.
    static func statusReply(
        route: VMComputerUseRoute, helper: Result<VMGuestHello, VMGuestClient.Failure>?, transferHostPath: String
    ) -> String {
        let null = NSNull()
        let hasVM: Any
        let running: Bool
        switch route {
        case .desktop: (hasVM, running) = (false, false)
        case .vmStateUnreadable: (hasVM, running) = (null, false)
        case .vmNotRunning: (hasVM, running) = (true, false)
        case .guest: (hasVM, running) = (true, true)
        }
        var helperObject: Any = null
        var helperError: Any = null
        switch running ? helper : nil {
        case .success(let hello):
            helperObject = [
                "version": hello.guestVersion, "accessibility": hello.accessibility,
                "screen_recording": hello.screenRecording,
            ] as [String: Any]
        case .failure(let failure):
            helperError = failure.message
        case nil:
            break
        }
        let knownVM = (hasVM as? Bool) == true
        return jsonLine([
            "has_vm": hasVM,
            "running": running,
            "helper": helperObject,
            "helper_error": helperError,
            "transfer_host_path": knownVM ? transferHostPath : null,
            "transfer_guest_path": knownVM ? transferGuestPath : null,
        ])
    }

    /// The `vm_run` reply; `exit_code` is null when the command was killed.
    static func runReply(_ result: VMGuestRunResult) -> String {
        let exitCode: Any = result.exitCode.map { Int($0) } ?? NSNull()
        return jsonLine([
            "exit_code": exitCode,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "truncated": result.truncated,
            "timed_out": result.timedOut,
        ])
    }

    private static func jsonLine(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
