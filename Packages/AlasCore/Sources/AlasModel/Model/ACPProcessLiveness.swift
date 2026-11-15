import Foundation
import AlasFoundation

/// Cross-process liveness check. `kill(pid, 0)` sends no signal but
/// performs the existence/permission check: 0 = alive, ESRCH = gone,
/// EPERM = exists but owned by another user (treated as alive).
public enum ACPProcessLiveness: Sendable {
    public static func pidAlive(_ pid: Int64) -> Bool {
        guard pid > 0, pid <= Int64(Int32.max) else { return false }
        let rc = kill(pid_t(pid), 0)
        if rc == 0 { return true }
        return errno == EPERM
    }

    public static func pidMatchesLease(pid: Int64, createdAt: Date) -> Bool {
        guard pidAlive(pid), pid <= Int64(Int32.max),
              let startedAt = processStartTime(pid: Int32(pid)) else {
            return false
        }
        return startedAt <= createdAt.addingTimeInterval(1)
    }

    private static func processStartTime(pid: Int32) -> Date? {
        ProcessTable.entry(of: pid)?.startTime.date
    }
}
