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
        /// The helper never answered, the VM stopped, or the user took it over mid-script:
        /// nothing is recorded, and the next start tries again.
        case interrupted
        /// The script succeeded (or there was none), but the clean point couldn't be taken.
        case cleanPointFailed(String)
        /// The clean point was taken, but the VM couldn't start again afterwards.
        case notRestarted(String)
    }

    /// Thrown by `runScript` when the user took the VM over mid-script.
    struct TakenOver: Error {}

    /// How long the guest gives the setup script.
    static let scriptTimeoutSeconds = 600

    let manager: WorktreeVMManager
    /// Waits until VM `recordID`'s guest helper says hello; false when it never does.
    let waitForHelper: (_ recordID: String) async -> Bool
    /// Runs `script` in VM `recordID`'s guest shell, bounded by `timeoutSeconds`.
    let runScript: (_ recordID: String, _ script: String, _ timeoutSeconds: Int) async throws -> VMGuestRunResult

    /// A nil or blank `script`, or one that already succeeded in this VM, goes straight to the
    /// clean point.
    func run(recordID: String, script: String?, scriptSucceeded: Bool = false) async -> Outcome {
        guard await waitForHelper(recordID) else { return .interrupted }
        let vm = VMIdentity.parse(recordID: recordID)
        let hash = VMCleanPoint.scriptHash(script)
        if hash != nil, !scriptSucceeded, let script {
            let exitCode: Int32?
            do {
                let result = try await runScript(recordID, script, Self.scriptTimeoutSeconds)
                exitCode = result.timedOut ? nil : result.exitCode
            } catch {
                // A stop or a take over cut the run short: the script didn't fail.
                if error is TakenOver || manager.running(vm.worktree, guest: vm.guest) == nil { return .interrupted }
                exitCode = nil
            }
            guard exitCode == 0 else { return .scriptFailed(exitCode: exitCode) }
        }
        do {
            try await manager.takeCleanPoint(worktreeID: vm.worktree, guest: vm.guest, setupScriptHash: hash)
        } catch let error as WorktreeVMManager.RestartFailed {
            return .notRestarted(error.message)
        } catch {
            return .cleanPointFailed(error.localizedDescription)
        }
        return .cleanPointTaken
    }
}

/// A first-boot clean point that went wrong after the script, for the VM tab's callout.
enum VMCleanPointIssue: Equatable {
    /// The clean point couldn't be taken; "Save clean point now" tries again.
    case notSaved(String)
    /// The clean point was taken, but the VM couldn't start again afterwards.
    case notRestarted(String)

    var message: String {
        switch self {
        case .notSaved(let reason):
            let phrase = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
            return "Couldn't save this VM's clean point: \(phrase)."
        case .notRestarted(let message):
            return message
        }
    }
}
