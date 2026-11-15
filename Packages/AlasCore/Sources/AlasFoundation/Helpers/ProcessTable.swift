import Foundation

/// The live process table: a process's parent and birth time, and its
/// children. libproc on macOS, `/proc` on Linux.
public enum ProcessTable {
    /// When a process started, as wall-clock time since 1970. Stable for the
    /// life of the process, so a pid plus its start time names one process
    /// even after the pid is reused.
    public struct StartTime: Hashable, Sendable {
        public let seconds: Int64
        public let microseconds: Int64

        public init(seconds: Int64, microseconds: Int64) {
            self.seconds = seconds
            self.microseconds = microseconds
        }

        public var date: Date {
            Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(microseconds) / 1_000_000)
        }
    }

    public struct Entry: Sendable {
        public let parentPID: pid_t
        public let startTime: StartTime
        /// The foreground process group of the process's controlling
        /// terminal; nil when it has none.
        public let terminalForegroundGroup: pid_t?
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
        guard result == Int32(size), info.pbi_pid == UInt32(pid) else { return nil }
        let group = info.e_tdev != UInt32.max ? pid_t(exactly: info.e_tpgid).flatMap { $0 > 0 ? $0 : nil } : nil
        return Entry(
            parentPID: pid_t(info.pbi_ppid),
            startTime: StartTime(seconds: Int64(info.pbi_start_tvsec), microseconds: Int64(info.pbi_start_tvusec)),
            terminalForegroundGroup: group
        )
        #else
        guard let fields = statFields(of: pid), fields.count > 19,
              let parent = pid_t(fields[1]), let ticks = Int64(fields[19]),
              let terminal = Int64(fields[4]), let group = pid_t(fields[5]) else { return nil }
        let perSecond = Int64(sysconf(Int32(_SC_CLK_TCK)))
        guard perSecond > 0, let bootTime else { return nil }
        return Entry(
            parentPID: parent,
            startTime: StartTime(
                seconds: bootTime + ticks / perSecond,
                microseconds: ticks % perSecond * 1_000_000 / perSecond
            ),
            terminalForegroundGroup: terminal != 0 && group > 0 ? group : nil
        )
        #endif
    }

    public static func children(of parent: pid_t) -> [pid_t] {
        #if canImport(Darwin)
        var capacity = 16
        while capacity <= 65536 {
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

    /// The executable a process is running.
    public static func executablePath(of pid: pid_t) -> String? {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")
        #endif
    }

    /// A process's argv.
    public static func arguments(of pid: pid_t) -> [String]? {
        #if canImport(Darwin)
        // `KERN_PROCARGS2`: argc, the exec path, padding, then argc NUL-terminated strings.
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var argv: [String] = []
        while argv.count < Int(argc), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            argv.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return argv
        #else
        // NUL-separated, with a trailing NUL.
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline"), !data.isEmpty else { return nil }
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
        #endif
    }

    /// Every process id in the system.
    public static func allPIDs() -> [pid_t] {
        #if canImport(Darwin)
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, count)).filter { $0 > 0 }
        #else
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        return entries.compactMap { pid_t($0) }
        #endif
    }

    #if !canImport(Darwin)
    /// When the system booted, in seconds since 1970: the `btime` line of
    /// `/proc/stat`. Process start times there count from it.
    private static let bootTime: Int64? = {
        guard let text = try? String(contentsOfFile: "/proc/stat", encoding: .utf8) else { return nil }
        let line = text.split(separator: "\n").first { $0.hasPrefix("btime ") }
        return line.flatMap { Int64($0.dropFirst("btime ".count)) }
    }()

    /// `/proc/<pid>/stat` after the command name, which is parenthesized and
    /// may itself contain spaces: index 0 is the state, 1 the parent pid,
    /// 4 the controlling terminal, 5 its foreground group, 19 the start time
    /// in clock ticks since boot.
    static func statFields(of pid: pid_t) -> [Substring]? {
        guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = text.lastIndex(of: ")") else { return nil }
        return text[text.index(after: close)...].split(separator: " ")
    }
    #endif
}
