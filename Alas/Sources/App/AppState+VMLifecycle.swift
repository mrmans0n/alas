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

    /// A VM started here. A new VM's first boot runs the project's guest setup script, then takes
    /// its clean point. An auto-started VM gets it too.
    func vmStarted(recordID: String) {
        guard WorktreeVMManager.runsFirstBootSetup(
            recordID: recordID, firstBootPending: vmManager.isFirstBootPending(recordID: recordID),
            setupRunning: vmSetupScriptsRunning.contains(recordID), setupFailed: vmSetupFailures[recordID] != nil
        ) else { return }
        // Claimed before the start returns, so an agent call that started the VM is refused until
        // the setup is done rather than racing the script.
        vmSetupScriptsRunning.insert(recordID)
        Task { await runVMSetup(recordID: recordID, claimed: true) }
    }

    /// The project's guest setup script for VM `recordID`'s worktree; nil without one.
    func vmGuestSetupScript(recordID: String) -> String? {
        projectAndWorktree(withWorktreeId: VMIdentity.parse(recordID: recordID).worktree)?.project.vmGuestSetupScript
    }

    /// Runs the project's setup script in VM `recordID` and takes its clean point on success: on
    /// its first boot, where a script that already succeeded isn't run again, and for the tab's
    /// "Run again" and "Run the new setup script" (`rerunScript`). `claimed` when the caller
    /// already put it in `vmSetupScriptsRunning`.
    func runVMSetup(recordID: String, rerunScript: Bool = false, claimed: Bool = false) async {
        guard claimed || vmSetupScriptsRunning.insert(recordID).inserted else { return }
        defer { vmSetupScriptsRunning.remove(recordID) }
        let script = vmGuestSetupScript(recordID: recordID)
        let succeeded = !rerunScript && vmSetupScriptSucceeded[recordID] == VMCleanPoint.scriptHash(script)
        vmCleanPointIssues.removeValue(forKey: recordID)
        let outcome = await makeVMFirstBootSetup().run(recordID: recordID, script: script, scriptSucceeded: succeeded)
        switch outcome {
        case .cleanPointTaken:
            vmCleanPointTaken(recordID: recordID)
        case .notRestarted(let message):
            vmCleanPointTaken(recordID: recordID)
            vmCleanPointIssues[recordID] = .notRestarted(message)
        case .scriptFailed(let exitCode):
            // `updateValue`: assigning a nil code through the subscript would remove the entry.
            vmSetupFailures.updateValue(exitCode, forKey: recordID)
        case .interrupted:
            // Stopped or taken over: the next start is a first boot again.
            break
        case .cleanPointFailed(let message):
            vmLogger.error("Taking the clean point of VM \(recordID, privacy: .public) failed: \(message, privacy: .public)")
            // The next start goes straight to the clean point.
            vmSetupFailures.removeValue(forKey: recordID)
            vmSetupScriptSucceeded.updateValue(VMCleanPoint.scriptHash(script), forKey: recordID)
            vmCleanPointIssues[recordID] = .notSaved(message)
        }
    }

    /// The tab's "Save clean point now" and "Skip and save clean point": takes the clean point
    /// without running the script, after the script that last succeeded in the VM, if any.
    /// `setupScriptHash` is the clean point's otherwise.
    func saveVMCleanPoint(recordID: String, setupScriptHash: String?) async throws {
        guard vmSetupScriptsRunning.insert(recordID).inserted else { return }
        defer { vmSetupScriptsRunning.remove(recordID) }
        let vm = VMIdentity.parse(recordID: recordID)
        vmCleanPointIssues.removeValue(forKey: recordID)
        let hash = vmSetupScriptSucceeded[recordID] ?? setupScriptHash
        do {
            try await vmManager.takeCleanPoint(worktreeID: vm.worktree, guest: vm.guest, setupScriptHash: hash)
        } catch let error as WorktreeVMManager.RestartFailed {
            vmCleanPointTaken(recordID: recordID)
            vmCleanPointIssues[recordID] = .notRestarted(error.message)
            return
        }
        vmCleanPointTaken(recordID: recordID)
    }

    private func vmCleanPointTaken(recordID: String) {
        vmSetupFailures.removeValue(forKey: recordID)
        vmSetupScriptSucceeded.removeValue(forKey: recordID)
    }

    /// Forgets VM `recordID`'s setup state when it is deleted: a VM created again is new.
    func forgetVMSetup(recordID: String) {
        vmCleanPointTaken(recordID: recordID)
        vmCleanPointIssues.removeValue(forKey: recordID)
    }

    private func makeVMFirstBootSetup() -> VMFirstBootSetup {
        VMFirstBootSetup(
            manager: vmManager,
            waitForHelper: { [weak self] recordID in await self?.waitForVMHelper(recordID: recordID) ?? false },
            runScript: { [weak self] recordID, script, timeout in
                guard let self else { throw VMGuestClient.Failure.stopped }
                return try await runVMSetupScript(script, recordID: recordID, timeoutSeconds: timeout)
            }
        )
    }

    /// Runs the setup script like `vm_run` does a command: registered in `vmRuns`, so a take over
    /// cancels it, and then it counts as interrupted rather than failed.
    private func runVMSetupScript(_ script: String, recordID: String, timeoutSeconds: Int) async throws -> VMGuestRunResult {
        let vm = VMIdentity.parse(recordID: recordID)
        guard !vmTakenOver.contains(recordID) else { throw VMFirstBootSetup.TakenOver() }
        guard let client = vmManager.guestClient(for: vm.worktree, guest: vm.guest) else {
            throw VMGuestClient.Failure.stopped
        }
        let token = UUID()
        let run = Task { try await client.run(script, timeoutSeconds: timeoutSeconds) }
        vmRuns[recordID, default: [:]][token] = run
        defer { vmRuns[recordID]?[token] = nil }
        let result: Result<VMGuestRunResult, any Error>
        do {
            result = .success(try await run.value)
        } catch {
            result = .failure(error)
        }
        // A take over cancels the run, and the guest may still answer with its result.
        if vmTakenOver.contains(recordID) { throw VMFirstBootSetup.TakenOver() }
        return try result.get()
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

    // MARK: - New worktrees

    /// Creates the macOS VM of a worktree just created in a project that gives its new worktrees
    /// one, without booting it; its first boot runs the setup script and takes the clean point.
    /// Never fails the worktree: without a golden image the VM waits for the VM tab or an agent.
    func createVMForNewWorktree(_ worktree: Worktree, projectId: String) {
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        #if arch(arm64)
        let isAppleSilicon = true
        #else
        let isAppleSilicon = false
        #endif
        guard WorktreeVMManager.shouldCreateVM(
            project: project, isAppleSilicon: isAppleSilicon,
            goldenAvailable: vmManager.availableGolden() != nil,
            isRemote: project.host != nil || RemotePath.isReserved(worktree.id)
        ) else { return }
        do {
            try vmManager.createVM(worktreeID: worktree.id, guest: .macOS)
        } catch {
            vmLogger.error("Could not create the VM of a new worktree: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private let vmLogger = Logger(subsystem: "io.nlopez.alas", category: "vm-setup")
