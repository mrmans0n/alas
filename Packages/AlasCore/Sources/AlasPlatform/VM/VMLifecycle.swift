import CryptoKit
import Foundation

/// When a running worktree VM should pause to free its memory.
public enum VMIdlePolicy {
    /// Seconds without activity before a macOS VM pauses.
    public static let idleAfter: TimeInterval = 900

    /// Idle time counts from the latest of the last agent call, the last user input, and when the
    /// VM started running, so a VM that booted and was never used still pauses. Linux guests never
    /// save state, so they never idle-pause.
    public static func shouldPause(
        guest: VMGuestOS, lastAgentCall: Date?, agentCallInFlight: Bool, lastUserInput: Date?,
        takenOver: Bool, starting: Bool, inSetupFlow: Bool, runningSince: Date, now: Date
    ) -> Bool {
        guard guest == .macOS, !agentCallInFlight, !takenOver, !starting, !inSetupFlow else { return false }
        let lastActivity = [lastAgentCall, lastUserInput, runningSince].compactMap { $0 }.max() ?? runningSince
        return now.timeIntervalSince(lastActivity) >= idleAfter
    }
}

/// Whether a saved machine state may be restored.
public enum VMSavedState {
    /// `state.json`, written beside `state.vzvmsave` once the state is saved: the disk it belongs
    /// to. It lives in the VM's bundle, not the registry, which older builds rewrite without it.
    public struct Info: Codable, Equatable, Sendable {
        /// `disk.img`'s modification time when the state was saved.
        public var diskStamp: Date

        public init(diskStamp: Date) {
            self.diskStamp = diskStamp
        }
    }

    /// A state file is valid only for the disk it was saved with: any later change to `disk.img`
    /// (for example a cold boot by an older build) makes it stale.
    public static func isValid(pausedDiskStamp: Date?, currentDiskModified: Date) -> Bool {
        guard let pausedDiskStamp else { return false }
        return currentDiskModified <= pausedDiskStamp
    }
}

/// Bundles under `vms/worktrees/` that no live worktree owns.
public enum VMOrphans {
    /// A bundle is an orphan when no record names it, or the record's worktree is gone. A bundle
    /// whose record's worktree exists is never listed. `bundleName` maps a worktree id and guest
    /// to its bundle directory name.
    public static func find(
        bundleNames: [String], records: [WorktreeVMRecord], worktreeExists: (String) -> Bool,
        bundleName: (String, VMGuestOS) -> String
    ) -> [String] {
        var live = Set<String>()
        for record in records {
            let (worktree, guest) = VMIdentity.parse(recordID: record.id)
            if worktreeExists(worktree) { live.insert(bundleName(worktree, guest)) }
        }
        return bundleNames.filter { !live.contains($0) }
    }
}

/// A snapshot of a freshly set-up VM that it can be reset to.
public struct VMCleanPoint: Codable, Equatable, Sendable {
    public var createdAt: Date
    /// SHA-256 of the project's guest setup script when the point was taken.
    public var setupScriptHash: String?

    public init(createdAt: Date, setupScriptHash: String? = nil) {
        self.createdAt = createdAt
        self.setupScriptHash = setupScriptHash
    }

    /// Lowercase hex SHA-256 of `script`; nil for a nil or blank script.
    public static func scriptHash(_ script: String?) -> String? {
        guard let script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
