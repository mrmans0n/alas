import Foundation
import os

/// Reinstalls the guest helper in an existing VM: shuts it down, writes the
/// helper's grants and turns sshd on offline (the user already exists), boots
/// it, installs the helper and its LaunchAgent over SSH from inside the guest
/// (launchd skips host-written ones), and waits for both grants. A failure
/// after sshd was turned on leaves the VM stopped with sshd off again.
@MainActor
struct VMHelperUpdater {
    enum Outcome: Equatable {
        /// The VM runs again with the current helper.
        case updated
        /// The VM is left stopped; `reason` is a short phrase for
        /// "Couldn't update the helper (<reason>)".
        case failed(reason: String)
    }

    typealias Failure = GoldenProvisioner.Failure
    typealias Reason = GoldenProvisioner.Reason

    /// Shuts the VM down: gracefully, then forced.
    var shutDown: @MainActor (String) async -> Void
    var patchGrants: @MainActor (any GoldenProvisioningDisk) async throws -> Void
    /// Keyed by the VM's registry id.
    var steps: GuestSetupSteps

    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "vm-helper-updater")

    func run(id: String, bundle: VMBundle) async -> Outcome {
        var sshdMayBeOn = false
        do {
            await shutDown(id)
            do {
                try await steps.withDisk(bundle) { disk in
                    sshdMayBeOn = true
                    try await patchGrants(disk)
                }
            } catch {
                Self.logger.error("Patching the helper grants of \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                throw Failure(reason: Reason.disk)
            }
            try await steps.bootOrFail(id, reason: Reason.vmStart)
            try await steps.finishOverSSH(bundle)
            try await steps.waitForHelperGrants(id)
            Self.logger.info("Updated the helper in \(id, privacy: .public)")
            return .updated
        } catch {
            let reason = (error as? Failure)?.reason ?? Reason.vmStart
            Self.logger.error("Updating the helper in \(id, privacy: .public) stopped: \(reason, privacy: .public)")
            await steps.stop(id)
            if sshdMayBeOn { await steps.turnSSHDOffOffline(bundle) }
            return .failed(reason: reason)
        }
    }
}

extension VMHelperUpdater {
    /// The updater wired to `manager`'s VM `id`, a worktree's or a golden's.
    static func live(
        manager: WorktreeVMManager, id: String, helperApp: URL? = GuestSetupSteps.embeddedHelperApp
    ) -> VMHelperUpdater {
        let goldenBuild = id.hasPrefix(WorktreeVMManager.goldenIDPrefix)
            ? String(id.dropFirst(WorktreeVMManager.goldenIDPrefix.count)) : nil
        let steps = GuestSetupSteps.live(
            manager: manager,
            // Every key and bundle here is this VM's.
            registryID: { _ in id },
            boot: { id in
                let outcome = if let goldenBuild {
                    try await manager.startGolden(build: goldenBuild)
                } else {
                    try await manager.startVM(worktreeID: id)
                }
                try GuestSetupSteps.requireRunning(outcome)
            },
            stop: { id in await manager.forceStop(id: id) })
        return VMHelperUpdater(
            shutDown: { id in await manager.stopVM(worktreeID: id) },
            patchGrants: { disk in
                guard let helperApp else { throw Failure(reason: Reason.disk) }
                try await Task.detached {
                    try VMGuestPatcher.patchGrants(
                        dataVolume: disk.dataVolume,
                        helperCodeRequirement: HelperCodeRequirement.designatedRequirementData(of: helperApp))
                }.value
            },
            steps: steps)
    }
}
