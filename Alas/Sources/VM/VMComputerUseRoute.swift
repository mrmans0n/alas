import AlasComputerUseKit
import Foundation

/// Where one `computer_*` or `vm_*` call from a worktree session goes, decided per call so a VM
/// started mid-session takes over on the next call.
enum VMComputerUseRoute: Equatable {
    /// The user's desktop, through the host coordinator.
    case desktop
    /// The guest helper of the worktree's VM of `guest`, which this process runs.
    case guest(worktreeID: String, guest: VMGuestOS)
    /// The worktree has a VM of `guest`, but this process doesn't run it.
    case vmNotRunning(worktreeID: String, guest: VMGuestOS)
    /// Whether the worktree has a VM couldn't be read; never the desktop, which it may not mean.
    case vmStateUnreadable(worktreeID: String)
    /// The call named a guest the worktree has no VM of.
    case vmMissing(guest: VMGuestOS)
    /// The worktree has a macOS and a Linux VM and the call named neither.
    case ambiguous(worktreeID: String)

    static let vmNotRunningMessage = "computer_vm_stopped: This worktree's VM isn't running. Start it from its VM tab."
    static let vmStateUnreadableMessage = "computer_vm_stopped: Couldn't read this worktree's VM state. Try again."

    static let vmMissingMessage = "computer_vm_missing: This worktree has no VM. Create one from its VM tab."
    static let vmUnsupportedMessage = "computer_vm_unsupported: \(WorktreeVMManager.unsupportedMessage)."
    static let vmAmbiguousMessage =
        #"computer_vm_ambiguous: This worktree has a macOS and a Linux VM. Pass vm: "macos" or "linux"."#
    static let linuxComputerUseUnsupportedMessage = "computer_vm_unsupported: Computer use isn't available in Linux VMs yet."

    /// The reply to a call naming a guest the worktree has no VM of.
    static func vmMissingMessage(for guest: VMGuestOS) -> String {
        "computer_vm_missing: This worktree has no \(guest == .linux ? "Linux" : "macOS") VM. Create one from its VM tab."
    }

    /// Where the guest sees the worktree VM's transfer folder.
    static let transferGuestPath = "/Volumes/My Shared Files/transfer"
    static let linuxTransferGuestPath = LinuxCloudInit.shareMountPoint + "/transfer"

    static func transferGuestPath(for guest: VMGuestOS) -> String {
        guest == .linux ? linuxTransferGuestPath : transferGuestPath
    }

    /// `kinds`, the guests the worktree has a VM of, is nil when the VM registry couldn't be read;
    /// it is read only when no running VM settles the call. A VM running here counts as existing.
    /// One VM is used when `requested` is nil; with both, the call must name one.
    static func resolve(
        worktreeID: String?, kinds: @autoclosure () -> Set<VMGuestOS>?, requested: VMGuestOS?,
        runningHere: (VMGuestOS) -> Bool
    ) -> VMComputerUseRoute {
        guard let worktreeID else { return requested.map { .vmMissing(guest: $0) } ?? .desktop }
        if let requested {
            if runningHere(requested) { return .guest(worktreeID: worktreeID, guest: requested) }
            guard let kinds = kinds() else { return .vmStateUnreadable(worktreeID: worktreeID) }
            return kinds.contains(requested)
                ? .vmNotRunning(worktreeID: worktreeID, guest: requested) : .vmMissing(guest: requested)
        }
        let running = Set([VMGuestOS.macOS, .linux].filter(runningHere))
        if running.count > 1 { return .ambiguous(worktreeID: worktreeID) }
        guard let known = kinds().map({ $0.union(running) }) ?? (running.isEmpty ? nil : running) else {
            return .vmStateUnreadable(worktreeID: worktreeID)
        }
        if known.count > 1 { return .ambiguous(worktreeID: worktreeID) }
        guard let guest = known.first else { return .desktop }
        return running.contains(guest)
            ? .guest(worktreeID: worktreeID, guest: guest) : .vmNotRunning(worktreeID: worktreeID, guest: guest)
    }

    // MARK: - vm_* replies

    /// The `vm_status` reply for this route. `helper`, the guest's hello or why it failed, is used
    /// only when the VM runs here; the transfer paths are given only when a VM is known to exist.
    static func statusReply(
        route: VMComputerUseRoute, helper: Result<VMGuestHello, VMGuestClient.Failure>?, transferHostPath: String
    ) -> String {
        jsonLine(statusObject(route: route, helper: helper, transferHostPath: transferHostPath))
    }

    /// The `vm_status` reply for a worktree with both VMs and no `vm` named: one status per VM,
    /// in the given order, each naming its guest.
    static func statusReply(vms: [VMStatusEntry]) -> String {
        jsonLine(["vms": vms.map { vm in
            var object = statusObject(route: vm.route, helper: vm.helper, transferHostPath: vm.transferHostPath)
            object["vm"] = vm.guest.wireName
            return object
        }])
    }

    /// One VM's part of a `vm_status` reply listing both.
    typealias VMStatusEntry = (
        guest: VMGuestOS, route: VMComputerUseRoute, helper: Result<VMGuestHello, VMGuestClient.Failure>?,
        transferHostPath: String
    )

    private static func statusObject(
        route: VMComputerUseRoute, helper: Result<VMGuestHello, VMGuestClient.Failure>?, transferHostPath: String
    ) -> [String: Any] {
        let null = NSNull()
        let hasVM: Any
        let running: Bool
        switch route {
        case .desktop, .vmMissing: (hasVM, running) = (false, false)
        case .vmStateUnreadable: (hasVM, running) = (null, false)
        case .vmNotRunning, .ambiguous: (hasVM, running) = (true, false)
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
        // Transfer paths only for a VM known to exist and to be one guest.
        let transferGuest: VMGuestOS? = switch route {
        case .guest(_, let guest), .vmNotRunning(_, let guest): guest
        default: nil
        }
        return [
            "has_vm": hasVM,
            "running": running,
            "helper": helperObject,
            "helper_error": helperError,
            "transfer_host_path": transferGuest == nil ? null : transferHostPath,
            "transfer_guest_path": transferGuest.map(transferGuestPath(for:)) ?? null,
        ]
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
