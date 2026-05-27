import Darwin
import Foundation

/// Shared utility for graceful-then-forceful process termination.
/// SIGTERMs the process, waits 500ms, SIGKILLs if still running.
enum ACPProcessKiller {
    static let sigtermGraceNanoseconds: UInt64 = 500_000_000

    static func terminateThenKillIfNeeded(_ process: Process) {
        process.terminate()
        Task {
            try? await Task.sleep(nanoseconds: sigtermGraceNanoseconds)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}
