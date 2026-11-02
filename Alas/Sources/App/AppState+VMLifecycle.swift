import AlasCore
import Foundation

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
}
