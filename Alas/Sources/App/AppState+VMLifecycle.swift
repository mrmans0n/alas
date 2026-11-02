import AlasComputerUseKit
import AlasCore
import Foundation
import os

extension AppState {
    /// A key or mouse event reached VM `recordID`'s screen. The screen calls this at most once a
    /// second.
    func noteVMUserInput(recordID: String) {
        vmLastUserInput[recordID] = vmNow()
    }

    /// What the idle sweep needs to know about VM `recordID`'s use.
    func vmActivity(recordID: String) -> VMIdleSweeper.Activity {
        VMIdleSweeper.Activity(
            lastAgentCall: vmLastAgentCall[recordID]?.at,
            agentCallInFlight: vmLastAgentCall.isInFlight(recordID),
            lastUserInput: vmLastUserInput[recordID],
            takenOver: vmTakenOver.contains(recordID),
            starting: vmAutoStarter.starting.contains(recordID),
            inSetupFlow: vmInSetupFlow(recordID: recordID)
        )
    }

    /// Whether VM `recordID` is being set up: a golden (installed, customized or finished by
    /// hand), the worktree VM whose tab shows the base image being customized, or a VM running
    /// its project's first-boot setup script.
    func vmInSetupFlow(recordID: String) -> Bool {
        if recordID.hasPrefix(WorktreeVMManager.goldenIDPrefix) || vmSetupScriptsRunning.contains(recordID) {
            return true
        }
        let vm = VMIdentity.parse(recordID: recordID)
        guard vm.guest == .macOS, vmManager.customizingFrom == vm.worktree else { return false }
        if case .awaitingSetup = goldenImageInstaller.phase { return true }
        return false
    }

    // MARK: - First boot

    /// A VM started here. Its first boot (no clean point yet, and no setup failure to retry by
    /// hand) runs the project's guest setup script, then takes its clean point. An auto-started
    /// VM gets it too.
    func vmStarted(recordID: String) {
        guard !recordID.hasPrefix(WorktreeVMManager.goldenIDPrefix), !vmSetupScriptsRunning.contains(recordID),
              vmSetupFailures[recordID] == nil, vmManager.cleanPoint(recordID: recordID) == nil
        else { return }
        Task { await runVMSetup(recordID: recordID) }
    }

    /// The project's guest setup script for VM `recordID`'s worktree; nil without one.
    func vmGuestSetupScript(recordID: String) -> String? {
        projectAndWorktree(withWorktreeId: VMIdentity.parse(recordID: recordID).worktree)?.project.vmGuestSetupScript
    }

    /// Runs the project's setup script in VM `recordID` and takes its clean point on success: on
    /// its first boot, and for the tab's "Run again" and "Run the new setup script".
    func runVMSetup(recordID: String) async {
        guard vmSetupScriptsRunning.insert(recordID).inserted else { return }
        defer { vmSetupScriptsRunning.remove(recordID) }
        let outcome = await makeVMFirstBootSetup().run(recordID: recordID, script: vmGuestSetupScript(recordID: recordID))
        switch outcome {
        case .cleanPointTaken:
            vmSetupFailures.removeValue(forKey: recordID)
        case .scriptFailed(let exitCode):
            // `updateValue`: assigning a nil code through the subscript would remove the entry.
            vmSetupFailures.updateValue(exitCode, forKey: recordID)
        case .helperUnavailable:
            // Stopped before its helper answered: the next start is a first boot again.
            break
        case .cleanPointFailed(let message):
            vmLogger.error("Taking the clean point of VM \(recordID, privacy: .public) failed: \(message, privacy: .public)")
        }
    }

    /// The tab's "Save clean point now" and "Skip and save clean point": takes the clean point
    /// without running the script. `setupScriptHash` is the script the VM was last set up with.
    func saveVMCleanPoint(recordID: String, setupScriptHash: String?) async throws {
        guard vmSetupScriptsRunning.insert(recordID).inserted else { return }
        defer { vmSetupScriptsRunning.remove(recordID) }
        let vm = VMIdentity.parse(recordID: recordID)
        try await vmManager.takeCleanPoint(worktreeID: vm.worktree, guest: vm.guest, setupScriptHash: setupScriptHash)
        vmSetupFailures.removeValue(forKey: recordID)
    }

    private func makeVMFirstBootSetup() -> VMFirstBootSetup {
        VMFirstBootSetup(
            manager: vmManager,
            waitForHelper: { [weak self] recordID in await self?.waitForVMHelper(recordID: recordID) ?? false },
            runScript: { [weak self] recordID, script, timeout in
                let vm = VMIdentity.parse(recordID: recordID)
                guard let client = self?.vmManager.guestClient(for: vm.worktree, guest: vm.guest) else {
                    throw VMGuestClient.Failure.stopped
                }
                return try await client.run(script, timeoutSeconds: timeout)
            }
        )
    }

    /// Waits for a freshly booted guest's helper, which starts only after its user logs in.
    private func waitForVMHelper(recordID: String) async -> Bool {
        let vm = VMIdentity.parse(recordID: recordID)
        return await GuestSetupSteps.waitUntil(
            timeout: .seconds(600), interval: .seconds(5),
            sleep: { try? await Task.sleep(for: $0) }, now: { .now }
        ) { [weak self] in
            guard let self, let client = vmManager.guestClient(for: vm.worktree, guest: vm.guest) else { return true }
            return (try? await client.hello()) != nil
        } && vmManager.running(vm.worktree, guest: vm.guest) != nil
    }
}

private let vmLogger = Logger(subsystem: "io.nlopez.alas", category: "vm-setup")
