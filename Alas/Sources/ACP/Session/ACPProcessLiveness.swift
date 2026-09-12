import Darwin
import Foundation

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

    static func pidMatchesLease(pid: Int64, createdAt: Date) -> Bool {
        guard pidAlive(pid), pid <= Int64(Int32.max),
              let startedAt = processStartTime(pid: Int32(pid)) else {
            return false
        }
        return startedAt <= createdAt.addingTimeInterval(1)
    }

    private static func processStartTime(pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, u_int(pointer.count), &info, &size, nil, 0)
        }
        guard result == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        let startTime = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(startTime.tv_sec) + TimeInterval(startTime.tv_usec) / 1_000_000)
    }
}
