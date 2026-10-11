import Darwin
import Foundation

/// Shared utility for graceful-then-forceful process termination.
/// SIGTERMs the process, waits 500ms, SIGKILLs if still running.
public enum ACPProcessKiller: Sendable {
    public static let sigtermGraceNanoseconds: UInt64 = 500_000_000

    public static func terminateThenKillIfNeeded(_ process: Process) {
        process.terminate()
        Task {
            try? await Task.sleep(nanoseconds: sigtermGraceNanoseconds)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}
