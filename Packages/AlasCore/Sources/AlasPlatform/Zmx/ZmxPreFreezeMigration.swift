import Darwin
import Foundation

/// Stops session daemons started by a zmx that predates the frozen (v1) IPC.
///
/// The bundled v1 zmx cannot talk to a pre-freeze daemon: attaching shows a
/// blank, stuck terminal and `zmx kill` hangs. Stopping those daemons and
/// removing their sockets lets the next `zmx attach` with the same name start
/// a fresh session in the same pane. Daemons that answer v1, that another
/// client is attached to, or that accept a connection but give no usable
/// reply, are left alone; the last two are reported so restores keep away.
public enum ZmxPreFreezeMigration {
    public struct Result: Equatable, Sendable {
        /// Socket names, sorted, whose pre-freeze daemon was stopped and whose
        /// socket is gone.
        public var restarted: [String]
        /// Socket names, sorted, of pre-freeze daemons whose socket survived.
        public var failed: [String]
        /// Socket names, sorted, of pre-freeze daemons left running because a
        /// client is attached: another, older Alas sharing the directory.
        public var inUse: [String]
        /// Socket names, sorted, whose daemon accepted a connection but gave
        /// no reply the probe could classify, such as a hung or busy daemon.
        /// It may be pre-freeze, so it is left running and reported. A socket
        /// that refuses connections is not: its daemon is gone and the next
        /// `zmx attach` replaces it.
        public var unresponsive: [String]
        /// Socket names, sorted, whose daemon answered the v1 probe: current,
        /// so the bundled zmx attaches it and it was left alone.
        public var current: [String]

        public init(
            restarted: [String] = [],
            failed: [String] = [],
            inUse: [String] = [],
            unresponsive: [String] = [],
            current: [String] = []
        ) {
            self.restarted = restarted
            self.failed = failed
            self.inUse = inUse
            self.unresponsive = unresponsive
            self.current = current
        }
    }

    /// Which file a socket path named when it was listed, so a socket a
    /// fresh daemon has since bound at the same path is never mistaken for
    /// the one probed.
    private struct SocketIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
    }

    /// When a process started, which tells it apart from a later process
    /// the system has given the same pid.
    public struct ProcessStart: Equatable, Sendable {
        public let seconds: UInt64
        public let microseconds: UInt64

        public init(seconds: UInt64, microseconds: UInt64) {
            self.seconds = seconds
            self.microseconds = microseconds
        }
    }

    private enum Outcome {
        case untouched
        case restarted
        case failed
        case inUse
        case unresponsive
        case current
    }

    /// Sockets probed and stopped at the same time. Each worker blocks for
    /// up to a probe, a kill, and an exit wait, so this stays well below the
    /// global queue's thread limit.
    static let maxConcurrentSockets = 32

    /// How long a daemon gets to exit after `SIGKILL`, which it cannot catch.
    static let sigkillExitTimeout: DispatchTimeInterval = .milliseconds(500)

    /// Probes the Unix sockets directly inside `directory`, one worker per
    /// socket, and stops each pre-freeze daemon no client is attached to: a
    /// pre-freeze `Kill`, then `signal(pid, SIGTERM)` when the daemon does
    /// not hang up or has not exited within `exitTimeout`, then
    /// `signal(pid, SIGKILL)` when it outlives `SIGTERM` as long. Its socket
    /// is removed only once `isAlive(pid)` turns false, so an exiting daemon
    /// cannot remove a socket a fresh daemon has since bound. `processStart`
    /// is read once the probe names the pid and again before each signal and
    /// liveness check: once the pid is gone or names a process that started
    /// at another time, the daemon has exited and is never signalled, since
    /// the pid may now belong to an unrelated process. A daemon that
    /// survives `SIGKILL`, or one reporting a pid that is unusable or whose
    /// start time cannot be read, is left in place and reported failed. A socket whose probe is `.unreachable` is
    /// reported unresponsive when `accepts(path)` still connects, and left
    /// out of the result when it refuses. Blocking; run it off the main
    /// thread.
    ///
    /// `names`, when given, limits the run to those socket names, such as
    /// one session a previous run left in use. Without it the run covers
    /// only sockets this Alas could attach: `sessionPrefix` followed by an
    /// Alas session name (`ZmxSessionName.isAlasName`). Sockets of another
    /// tool or another `ZMX_SESSION_PREFIX` share the directory and are
    /// never probed, matching the orphan sweeps. Does nothing, without
    /// probing, while `bundledWire` is `.preFreeze`: the bundled zmx still
    /// speaks to those daemons, and another Alas sharing the directory may be
    /// using them.
    public static func run(
        directory: URL,
        names filter: Set<String>? = nil,
        sessionPrefix: String = ProcessInfo.processInfo.environment["ZMX_SESSION_PREFIX"] ?? "",
        bundledWire: ZmxIPC.Wire = ZmxIPC.bundledWire,
        probe: @escaping @Sendable (String) -> ZmxDaemonStatus = { ZmxIPCSocket.probe(path: $0) },
        accepts: @escaping @Sendable (String) -> Bool = { acceptsConnections(path: $0) },
        kill: @escaping @Sendable (String) -> Bool = { ZmxIPCSocket.killPreFreeze(path: $0) },
        signal: @escaping @Sendable (_ pid: Int32, _ signal: Int32) -> Void = { _ = Darwin.kill($0, $1) },
        isAlive: @escaping @Sendable (Int32) -> Bool = { processExists($0) },
        processStart: @escaping @Sendable (Int32) -> ProcessStart? = { startTime(ofProcess: $0) },
        exitTimeout: DispatchTimeInterval = .seconds(2)
    ) -> Result {
        guard bundledWire == .v1 else { return Result() }
        let directory = directory.path
        let sockets = Self.sockets(in: directory).filter { socket in
            if let filter { return filter.contains(socket.name) }
            return socket.name.hasPrefix(sessionPrefix)
                && ZmxSessionName.isAlasName(String(socket.name.dropFirst(sessionPrefix.count)))
        }
        guard !sockets.isEmpty else { return Result() }
        let outcomes = OutcomeTable(count: sockets.count)
        let group = DispatchGroup()
        let slots = DispatchSemaphore(value: maxConcurrentSockets)
        for (index, (name, identity)) in sockets.enumerated() {
            let path = (directory as NSString).appendingPathComponent(name)
            slots.wait()
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                defer { slots.signal() }
                let status = probe(path)
                if status == .unreachable, accepts(path) {
                    outcomes[index] = .unresponsive
                    return
                }
                if case .v1 = status {
                    outcomes[index] = .current
                    return
                }
                guard case .preFreeze(let pid, let clients) = status else { return }
                guard clients == 0 else {
                    outcomes[index] = .inUse
                    return
                }
                outcomes[index] = stop(
                    path: path, identity: identity, pid: pid, kill: kill, signal: signal, isAlive: isAlive,
                    processStart: processStart, exitTimeout: exitTimeout)
            }
        }
        group.wait()
        var result = Result()
        for (index, (name, _)) in sockets.enumerated() {
            switch outcomes[index] {
            case .restarted: result.restarted.append(name)
            case .failed: result.failed.append(name)
            case .inUse: result.inUse.append(name)
            case .unresponsive: result.unresponsive.append(name)
            case .current: result.current.append(name)
            case .untouched: break
            }
        }
        return result
    }

    /// Whether a daemon is listening at `path`. A stale socket, left by a
    /// daemon that has exited, refuses the connection.
    public static func acceptsConnections(path: String) -> Bool {
        guard let socket = try? ZmxIPCSocket.connect(path: path) else { return false }
        socket.shutdown()
        return true
    }

    /// Whether `pid` names a live process: `kill(pid, 0)` succeeds, or fails
    /// for a reason other than `ESRCH` (such as `EPERM`).
    public static func processExists(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno != ESRCH
    }

    /// When the process `pid` names started; nil when there is none or its
    /// information cannot be read.
    public static func startTime(ofProcess pid: Int32) -> ProcessStart? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, Int32(info.pbi_pid) == pid else { return nil }
        return ProcessStart(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    private static func stop(
        path: String,
        identity: SocketIdentity,
        pid: Int32,
        kill: @Sendable (String) -> Bool,
        signal: @Sendable (Int32, Int32) -> Void,
        isAlive: @Sendable (Int32) -> Bool,
        processStart: @Sendable (Int32) -> ProcessStart?,
        exitTimeout: DispatchTimeInterval
    ) -> Outcome {
        // Without a pid to watch there is no safe moment to remove the socket.
        guard pid > 1, pid != getpid() else { return .failed }
        // Read as close to the probe as possible: a daemon that exits leaves
        // its pid free for the system to reuse, and a process found under it
        // later that started at another time is not the daemon.
        guard let started = processStart(pid) else { return .failed }
        func isProbedDaemon() -> Bool { processStart(pid) == started }
        func exits(within timeout: DispatchTimeInterval) -> Bool {
            let deadline = DispatchTime.now() + timeout
            while isAlive(pid), isProbedDaemon() {
                guard DispatchTime.now() < deadline else { return false }
                usleep(20_000)
            }
            return true
        }
        /// Signals the daemon unless its pid no longer names it, and returns
        /// whether it had already exited.
        func exitedBefore(_ sent: Int32) -> Bool {
            guard isProbedDaemon() else { return true }
            signal(pid, sent)
            return false
        }
        // Once the probed socket has left the path, the old daemon has too,
        // and whatever is bound there now is a fresh session, such as one
        // another Alas started: `Kill` would reach and stop it instead.
        guard socketIdentity(path) == identity else { return .restarted }
        let hungUp = kill(path)
        var exited = false
        if !hungUp {
            guard socketIdentity(path) == identity else { return .restarted }
            exited = exitedBefore(SIGTERM)
        }
        if !exited { exited = exits(within: exitTimeout) }
        if !exited, hungUp {
            exited = exitedBefore(SIGTERM) || exits(within: exitTimeout)
        }
        if !exited {
            exited = exitedBefore(SIGKILL) || exits(within: sigkillExitTimeout)
        }
        guard exited else { return .failed }
        // A daemon that hung up may not have removed its socket, and a
        // signalled one never does; the next attach must not find it. A
        // socket at the path that is not the one probed belongs to a fresh
        // daemon, such as one another Alas started once the old one left:
        // the old socket is gone and the new one stays.
        if socketIdentity(path) == identity { _ = unlink(path) }
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? .restarted : .failed }
        return SocketIdentity(info) == identity ? .failed : .restarted
    }

    /// Sorted names, and identities, of the direct children that are Unix
    /// sockets. `lstat` never follows a symlink, so a link to a socket
    /// elsewhere is skipped.
    private static func sockets(in directory: String) -> [(name: String, identity: SocketIdentity)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return entries
            .filter { !$0.contains("/") }
            .sorted()
            .compactMap { name in
                socketIdentity((directory as NSString).appendingPathComponent(name)).map { (name, $0) }
            }
    }

    /// The identity of the Unix socket at `path`; nil when there is none.
    private static func socketIdentity(_ path: String) -> SocketIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        return SocketIdentity(info)
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
