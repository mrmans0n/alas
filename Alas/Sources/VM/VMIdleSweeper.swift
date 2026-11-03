import AlasCore
import Foundation

/// Pauses the macOS VMs running here that nobody used for `VMIdlePolicy.idleAfter`, so they
/// free their slot and memory. AppState runs it every minute.
@MainActor
final class VMIdleSweeper {
    /// What AppState knows about a VM's use, by registry id.
    struct Activity {
        var lastAgentCall: Date?
        var agentCallInFlight = false
        var lastUserInput: Date?
        var takenOver = false
        /// An agent call is starting it.
        var starting = false
        /// Its tab shows golden install, customize or finish-by-hand, or its first-boot setup runs.
        var inSetupFlow = false
    }

    private let manager: WorktreeVMManager
    private let activity: (String) -> Activity
    private let now: () -> Date
    private var loop: Task<Void, Never>?

    init(manager: WorktreeVMManager, activity: @escaping (String) -> Activity, now: @escaping () -> Date) {
        self.manager = manager
        self.activity = activity
        self.now = now
    }

    /// Sweeps every `interval` until `stop()`.
    func start(interval: Duration = .seconds(60)) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await runIdleSweep()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One sweep: pauses each idle macOS VM running here, one after another. Each VM is judged
    /// when its turn comes, so a pause that takes a while doesn't act on stale activity.
    func runIdleSweep() async {
        for id in manager.runningVMs.keys.sorted() {
            let guest = VMIdentity.parse(recordID: id).guest
            // A golden runs only for its setup, whose sealing needs a clean shutdown.
            guard guest == .macOS, !id.hasPrefix(WorktreeVMManager.goldenIDPrefix),
                  let since = manager.runningSince(id)
            else { continue }
            let use = activity(id)
            guard VMIdlePolicy.shouldPause(
                guest: guest, lastAgentCall: use.lastAgentCall, agentCallInFlight: use.agentCallInFlight,
                lastUserInput: use.lastUserInput, takenOver: use.takenOver,
                starting: use.starting || manager.isStarting(id), inSetupFlow: use.inSetupFlow,
                runningSince: since, now: now()
            ) else { continue }
            _ = await manager.pauseVM(worktreeID: VMIdentity.parse(recordID: id).worktree, guest: guest)
        }
    }
}
