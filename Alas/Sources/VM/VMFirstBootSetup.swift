import AlasComputerUseKit
import AlasCore
import Foundation

/// A new VM's first boot: once its guest helper answers, runs the project's guest setup script,
/// then takes the VM's clean point. A failed script leaves the VM running with no clean point.
@MainActor
struct VMFirstBootSetup {
    enum Outcome: Equatable {
        case cleanPointTaken
        /// The script exited nonzero, or with no code when it timed out or its run failed.
        case scriptFailed(exitCode: Int32?)
        /// The helper never answered, or the VM stopped first: nothing ran.
        case helperUnavailable
        /// The script succeeded, but the clean point couldn't be taken.
        case cleanPointFailed(String)
    }

    /// How long the guest gives the setup script.
    static let scriptTimeoutSeconds = 600

    let manager: WorktreeVMManager
    /// Waits until VM `recordID`'s guest helper says hello; false when it never does.
    let waitForHelper: (_ recordID: String) async -> Bool
    /// Runs `script` in VM `recordID`'s guest shell, bounded by `timeoutSeconds`.
    let runScript: (_ recordID: String, _ script: String, _ timeoutSeconds: Int) async throws -> VMGuestRunResult

    /// A nil or blank `script` takes the clean point right away.
    func run(recordID: String, script: String?) async -> Outcome {
        guard await waitForHelper(recordID) else { return .helperUnavailable }
        let hash = VMCleanPoint.scriptHash(script)
        if hash != nil, let script {
            let exitCode: Int32?
            do {
                let result = try await runScript(recordID, script, Self.scriptTimeoutSeconds)
                exitCode = result.timedOut ? nil : result.exitCode
            } catch {
                exitCode = nil
            }
            guard exitCode == 0 else { return .scriptFailed(exitCode: exitCode) }
        }
        let vm = VMIdentity.parse(recordID: recordID)
        do {
            try await manager.takeCleanPoint(worktreeID: vm.worktree, guest: vm.guest, setupScriptHash: hash)
        } catch {
            return .cleanPointFailed(error.localizedDescription)
        }
        return .cleanPointTaken
    }
}
