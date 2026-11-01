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
    static let linuxVMNotRunningMessage =
        "computer_vm_stopped: This worktree's Linux VM isn't running. Start it from its Linux VM tab."
    static let vmStateUnreadableMessage = "computer_vm_stopped: Couldn't read this worktree's VM state. Try again."

    static let vmMissingMessage = "computer_vm_missing: This worktree has no VM. Create one from its VM tab."
    static let vmUnsupportedMessage = "computer_vm_unsupported: \(WorktreeVMManager.unsupportedMessage)."
    static let vmAmbiguousMessage =
        #"computer_vm_ambiguous: This worktree has a macOS and a Linux VM. Pass vm: "macos" or "linux"."#
    /// Only for a Linux helper whose hello lists no capabilities at all.
    static let linuxComputerUseUnsupportedMessage = "computer_vm_unsupported: Computer use isn't available in Linux VMs yet."
    static let linuxHelperOutdatedMessage =
        "computer_vm_helper_outdated: This Linux VM's helper can't do computer use yet. Click Update helper in its VM tab."

    /// Whether a Linux helper takes `computer_*` calls, from its hello's `capabilities`.
    enum LinuxComputerUseDecision: Equatable {
        case forward
        /// It only runs commands: Update helper installs one that can.
        case outdated
        /// Its hello says nothing about what it can do.
        case unsupported

        /// The error the agent gets; nil when the call goes to the guest.
        var refusal: String? {
            switch self {
            case .forward: nil
            case .outdated: VMComputerUseRoute.linuxHelperOutdatedMessage
            case .unsupported: VMComputerUseRoute.linuxComputerUseUnsupportedMessage
            }
        }
    }

    static func linuxComputerUse(capabilities: [String]?) -> LinuxComputerUseDecision {
        guard let capabilities else { return .unsupported }
        return capabilities.contains(VMGuestHello.computerUseCapability) ? .forward : .outdated
    }

    /// The reply to a call naming a guest the worktree has no VM of.
    static func vmMissingMessage(for guest: VMGuestOS) -> String {
        "computer_vm_missing: This worktree has no \(guest == .linux ? "Linux" : "macOS") VM. Create one from its VM tab."
    }

    /// The VMs, by registry id, that a session's lifecycle event goes to: every VM in `recorded`
    /// (the ones it made a call in), or only `worktreeID`'s for an event from that worktree's
    /// session. Sorted, so events go out in a stable order.
    static func lifecycleTargets(_ recorded: Set<String>?, worktreeID: String? = nil) -> [String] {
        (recorded ?? []).filter { id in worktreeID.map { VMIdentity.parse(recordID: id).worktree == $0 } ?? true }.sorted()
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
        // Transfer paths only for a VM known to exist and to be one guest.
        let transferGuest: VMGuestOS? = switch route {
        case .guest(_, let guest), .vmNotRunning(_, let guest): guest
        default: nil
        }
        var helperObject: Any = null
        var helperError: Any = null
        switch running ? helper : nil {
        case .success(let hello) where transferGuest == .linux:
            // No TCC grants in a Linux guest; reporting them false would read as missing permissions.
            helperObject = ["version": hello.guestVersion, "capabilities": hello.capabilities ?? ["run"]] as [String: Any]
        case .success(let hello):
            helperObject = [
                "version": hello.guestVersion, "accessibility": hello.accessibility,
                "screen_recording": hello.screenRecording,
            ] as [String: Any]
        case .failure(let failure):
            helperError = failure.message(for: transferGuest ?? .macOS)
        case nil:
            break
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
