import Foundation
import os

/// Reinstalls the guest helper in an existing VM: shuts it down, writes the
/// helper's grants and turns sshd on offline (the user already exists), boots
/// it, installs the helper and its LaunchAgent over SSH from inside the guest
/// (launchd skips host-written ones), and waits for both grants. sshd still
/// listening afterwards gets one guest restart to go away. A failure after
/// sshd was turned on leaves the VM stopped with sshd off again; a VM
/// without the `alas` account is left untouched (and running, when its
/// helper can tell before the shutdown).
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

    /// True only when the running VM's helper answered that the guest has
    /// no `alas` user, so the VM need not be stopped to find out.
    var guestLacksAccount: @MainActor (String) async -> Bool
    /// Shuts the VM down: gracefully, then forced.
    var shutDown: @MainActor (String) async -> Void
    /// Whether the stopped VM's disk has the `alas` user record.
    var hasAccount: @MainActor (any GoldenProvisioningDisk) async -> Bool
    var patchGrants: @MainActor (any GoldenProvisioningDisk) async throws -> Void
    /// Whether the guest at this address accepts connections on port 22.
    var sshPortOpen: @MainActor (String) async -> Bool
    /// Asks the guest, through its helper, to restart. Does not wait.
    var restartGuest: @MainActor (String) async -> Void
    /// Keyed by the VM's registry id.
    var steps: GuestSetupSteps

    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "vm-helper-updater")

    func run(id: String, bundle: VMBundle) async -> Outcome {
        if await guestLacksAccount(id) {
            Self.logger.error("Not updating the helper in \(id, privacy: .public): the guest has no alas user")
            return .failed(reason: Reason.noAccount)
        }
        var sshdMayBeOn = false
        do {
            await shutDown(id)
            do {
                try await steps.withDisk(bundle) { disk in
                    // Without it the SSH step can't log in: write nothing.
                    guard await hasAccount(disk) else { throw Failure(reason: Reason.noAccount) }
                    try steps.markSSHDEnabled(bundle)
                    sshdMayBeOn = true
                    try await patchGrants(disk)
                }
            } catch let failure as Failure {
                throw failure
            } catch {
                Self.logger.error("Patching the helper grants of \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                throw Failure(reason: Reason.disk)
            }
            try await steps.bootOrFail(id, reason: Reason.vmStart)
            let host = try await steps.finishOverSSH(bundle)
            try await steps.waitForHelperGrants(id)
            try await ensureSSHDStopped(id, host: host)
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

    /// `launchctl disable` only stops sshd loading again, and the bootout
    /// may not have run. A restart from inside, through the helper, ends it;
    /// the helper must then come back with both grants and port 22 stay shut.
    private func ensureSSHDStopped(_ id: String, host: String) async throws {
        guard await sshPortOpen(host) else { return }
        Self.logger.notice("sshd still listens in \(id, privacy: .public); restarting the guest")
        await restartGuest(id)
        let went = await steps.waitUntil(
            timeout: GoldenProvisioner.helperTimeout, interval: GoldenProvisioner.helperInterval
        ) { await !sshPortOpen(host) }
        guard went else { throw Failure(reason: Reason.sshStillOn) }
        try await steps.waitForHelperGrants(id)
        guard await !sshPortOpen(host) else { throw Failure(reason: Reason.sshStillOn) }
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
                    // Its sshd is on on purpose: the next step logs in with it.
                    try await manager.startVM(worktreeID: id, keepingSSH: true)
                }
                try GuestSetupSteps.requireRunning(outcome)
            },
            stop: { id in await manager.forceStop(id: id) })
        let account = VMGuestAccount.alas
        return VMHelperUpdater(
            guestLacksAccount: { id in
                // A helper that doesn't answer (missing, out of date) says
                // nothing: the disk check after the shutdown decides.
                guard let client = manager.guestClient(for: id),
                      let result = try? await client.run("/usr/bin/id \(account.shortName)", timeoutSeconds: 10),
                      let exit = result.exitCode, !result.timedOut
                else { return false }
                return exit != 0
            },
            shutDown: { id in await manager.stopVM(worktreeID: id) },
            hasAccount: { disk in
                await Task.detached {
                    (try? VMGuestPatcher.hasAccount(account, dataVolume: disk.dataVolume)) ?? false
                }.value
            },
            patchGrants: { disk in
                guard let helperApp else { throw Failure(reason: Reason.disk) }
                try await Task.detached {
                    try VMGuestPatcher.patchGrants(
                        dataVolume: disk.dataVolume,
                        helperCodeRequirement: HelperCodeRequirement.designatedRequirementData(of: helperApp))
                }.value
            },
            sshPortOpen: { host in await GuestSSH.portOpen(host: host, port: 22, timeout: .seconds(3)) },
            restartGuest: { id in
                manager.requestGuestCommand(id: id, GoldenProvisioner.restartCommand(account: account))
            },
            steps: steps)
    }
}
