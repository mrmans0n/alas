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
    /// Whether this run still owns the VM's setup. A stop hands it to the VM's next start, so a
    /// run that outlived its VM must not touch the one started after it.
    var isCurrent: () -> Bool = { true }

    enum ScriptOutcome {
        case succeeded, failed(Int32?), helperUnavailable, interrupted
    }

    func executeScript(recordID: String, script: String?) async -> ScriptOutcome {
        let helperReady = await waitForHelper(recordID)
        guard !Task.isCancelled, isCurrent() else { return .interrupted }
        guard helperReady else { return .helperUnavailable }
        guard let script else { return .succeeded }
        let exitCode: Int32?
        do {
            let result = try await runScript(recordID, script, Self.scriptTimeoutSeconds)
            exitCode = result.timedOut ? nil : result.exitCode
        } catch {
            if error is TakenOver || manager.runningVMs[recordID] == nil { return .interrupted }
            exitCode = nil
        }
        guard !Task.isCancelled, isCurrent() else { return .interrupted }
        return exitCode == 0 ? .succeeded : .failed(exitCode)
    }

    /// A nil or blank script, or one that already succeeded, goes straight to the clean point.
    func run(recordID: String, script: String?, scriptSucceeded: Bool = false) async -> Outcome {
        let hash = VMCleanPoint.scriptHash(script)
        switch await executeScript(recordID: recordID, script: hash != nil && !scriptSucceeded ? script : nil) {
        case .succeeded: break
        case .failed(let exitCode): return .scriptFailed(exitCode: exitCode)
        case .helperUnavailable, .interrupted: return .interrupted
        }
        let vm = VMIdentity.parse(recordID: recordID)
        do {
            try await manager.takeCleanPoint(
                worktreeID: vm.worktree, guest: vm.guest, setupScriptHash: hash, publishTemplate: hash != nil)
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
