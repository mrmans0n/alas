import Darwin

/// Cross-process liveness check. `kill(pid, 0)` sends no signal but
/// performs the existence/permission check: 0 = alive, ESRCH = gone,
/// EPERM = exists but owned by another user (treated as alive).
enum ACPProcessLiveness {
    static func pidAlive(_ pid: Int64) -> Bool {
        guard pid > 0, pid <= Int64(Int32.max) else { return false }
        let rc = kill(pid_t(pid), 0)
        if rc == 0 { return true }
        return errno == EPERM
    }
}
