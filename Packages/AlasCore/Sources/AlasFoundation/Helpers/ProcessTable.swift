import Foundation

/// The live process table: a process's parent and birth time, and its
/// children. libproc on macOS, `/proc` on Linux.
public enum ProcessTable {
    /// When a process started. Stable for the life of the process, so a pid
    /// plus its start time names one process even after the pid is reused.
    /// On macOS it is wall-clock time; on Linux it is time since boot, so
    /// compare it only with other start times.
    public struct StartTime: Hashable, Sendable {
        public let seconds: Int64
        public let microseconds: Int64

        public init(seconds: Int64, microseconds: Int64) {
            self.seconds = seconds
            self.microseconds = microseconds
        }
    }

    public struct Entry: Sendable {
        public let parentPID: pid_t
        public let startTime: StartTime
    }

    public static func entry(of pid: pid_t) -> Entry? {
        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: size) { rebound in
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, rebound, Int32(size))
            }
        }
        guard result == Int32(size) else { return nil }
        return Entry(
            parentPID: pid_t(info.pbi_ppid),
            startTime: StartTime(seconds: Int64(info.pbi_start_tvsec), microseconds: Int64(info.pbi_start_tvusec))
        )
        #else
        guard let fields = statFields(of: pid), fields.count > 19,
              let parent = pid_t(fields[1]), let ticks = Int64(fields[19]) else { return nil }
        let perSecond = Int64(sysconf(Int32(_SC_CLK_TCK)))
        guard perSecond > 0 else { return nil }
        return Entry(
            parentPID: parent,
            startTime: StartTime(seconds: ticks / perSecond, microseconds: ticks % perSecond * 1_000_000 / perSecond)
        )
        #endif
    }

    public static func children(of parent: pid_t) -> [pid_t] {
        #if canImport(Darwin)
        var capacity = 16
        while capacity <= 4096 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let pidCount = pids.withUnsafeMutableBufferPointer { buffer in
                proc_listchildpids(parent, buffer.baseAddress, Int32(capacity * MemoryLayout<pid_t>.stride))
            }
            guard pidCount > 0 else { return [] }
            let count = min(capacity, Int(pidCount))
            if count < capacity {
                return Array(pids.prefix(count)).filter { $0 > 0 }
            }
            capacity *= 2
        }
        return []
        #else
        // Each thread lists the children it forked.
        let tasks = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/\(parent)/task")) ?? []
        var out: [pid_t] = []
        for task in tasks {
            guard let text = try? String(contentsOfFile: "/proc/\(parent)/task/\(task)/children", encoding: .utf8)
            else { continue }
            out += text.split(separator: " ").compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return out
        #endif
    }

    #if !canImport(Darwin)
    /// `/proc/<pid>/stat` after the command name, which is parenthesized and
    /// may itself contain spaces: index 0 is the state, 1 the parent pid,
    /// 19 the start time in clock ticks since boot.
    static func statFields(of pid: pid_t) -> [Substring]? {
        guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = text.lastIndex(of: ")") else { return nil }
        return text[text.index(after: close)...].split(separator: " ")
    }
    #endif
}
