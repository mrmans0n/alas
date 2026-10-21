import Darwin
import Foundation

/// Stops session daemons started by a zmx that predates the frozen (v1) IPC.
///
/// The bundled v1 zmx cannot talk to a pre-freeze daemon: attaching shows a
/// blank, stuck terminal and `zmx kill` hangs. Stopping those daemons and
/// removing their sockets lets the next `zmx attach` with the same name start
/// a fresh session in the same pane. Daemons that answer v1, or that cannot
/// be classified at all, are left alone.
public enum ZmxPreFreezeMigration {
    public struct Result: Equatable, Sendable {
        /// Socket names, sorted, whose pre-freeze daemon was stopped and whose
        /// socket is gone.
        public var restarted: [String]
        /// Socket names, sorted, of pre-freeze daemons whose socket survived.
        public var failed: [String]

        public init(restarted: [String] = [], failed: [String] = []) {
            self.restarted = restarted
            self.failed = failed
        }
    }

    private enum Outcome {
        case untouched
        case restarted
        case failed
    }

    /// Sockets probed and stopped at the same time. Each worker blocks for
    /// up to a probe, a kill, and an exit wait, so this stays well below the
    /// global queue's thread limit.
    static let maxConcurrentSockets = 32

    /// Probes every Unix socket directly inside `directory`, one worker per
    /// socket, and stops each pre-freeze daemon: a pre-freeze `Kill`, falling
    /// back to `signal(pid)` when the daemon does not hang up. Its socket is
    /// removed only once `isAlive(pid)` turns false, so an exiting daemon
    /// cannot remove a socket a fresh daemon has since bound. A daemon still
    /// alive after `exitTimeout`, or one reporting an unusable pid, is left in
    /// place and reported failed. Blocking; run it off the main thread.
    public static func run(
        directory: URL,
        probe: @escaping @Sendable (String) -> ZmxDaemonStatus = { ZmxIPCSocket.probe(path: $0) },
        kill: @escaping @Sendable (String) -> Bool = { ZmxIPCSocket.killPreFreeze(path: $0) },
        signal: @escaping @Sendable (Int32) -> Void = { _ = Darwin.kill($0, SIGTERM) },
        isAlive: @escaping @Sendable (Int32) -> Bool = { processExists($0) },
        exitTimeout: DispatchTimeInterval = .seconds(2)
    ) -> Result {
        let directory = directory.path
        let names = socketNames(in: directory)
        guard !names.isEmpty else { return Result() }
        let outcomes = OutcomeTable(count: names.count)
        let group = DispatchGroup()
        let slots = DispatchSemaphore(value: maxConcurrentSockets)
        for (index, name) in names.enumerated() {
            let path = (directory as NSString).appendingPathComponent(name)
            slots.wait()
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                defer { slots.signal() }
                guard case .preFreeze(let pid) = probe(path) else { return }
                outcomes[index] = stop(
                    path: path, pid: pid, kill: kill, signal: signal, isAlive: isAlive, exitTimeout: exitTimeout)
            }
        }
        group.wait()
        var result = Result()
        for (index, name) in names.enumerated() {
            switch outcomes[index] {
            case .restarted: result.restarted.append(name)
            case .failed: result.failed.append(name)
            case .untouched: break
            }
        }
        return result
    }

    /// Whether `pid` names a live process: `kill(pid, 0)` succeeds, or fails
    /// for a reason other than `ESRCH` (such as `EPERM`).
    public static func processExists(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno != ESRCH
    }

    private static func stop(
        path: String,
        pid: Int32,
        kill: @Sendable (String) -> Bool,
        signal: @Sendable (Int32) -> Void,
        isAlive: @Sendable (Int32) -> Bool,
        exitTimeout: DispatchTimeInterval
    ) -> Outcome {
        // Without a pid to watch there is no safe moment to remove the socket.
        guard pid > 1, pid != getpid() else { return .failed }
        if !kill(path) { signal(pid) }
        let deadline = DispatchTime.now() + exitTimeout
        while isAlive(pid) {
            guard DispatchTime.now() < deadline else { return .failed }
            usleep(20_000)
        }
        // A daemon that hung up may not have removed its socket, and a
        // signalled one never does; the next attach must not find it.
        if isSocket(path) { _ = unlink(path) }
        return exists(path) ? .failed : .restarted
    }

    /// Sorted names of the direct children that are Unix sockets. `lstat`
    /// never follows a symlink, so a link to a socket elsewhere is skipped.
    private static func socketNames(in directory: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return entries
            .filter { !$0.contains("/") && isSocket((directory as NSString).appendingPathComponent($0)) }
            .sorted()
    }

    private static func isSocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 || errno != ENOENT
    }

    /// One slot per socket; each worker writes only its own index.
    private final class OutcomeTable: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [Outcome]

        init(count: Int) {
            outcomes = Array(repeating: .untouched, count: count)
        }

        subscript(index: Int) -> Outcome {
            get { lock.withLock { outcomes[index] } }
            set { lock.withLock { outcomes[index] = newValue } }
        }
    }
}
