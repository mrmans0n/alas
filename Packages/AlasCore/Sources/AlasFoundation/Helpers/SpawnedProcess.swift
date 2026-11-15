import Foundation

/// A child process started with `posix_spawn`, by default leading its own process group from the start:
/// `POSIX_SPAWN_SETPGROUP` sets the group before the child runs anything, so `kill(-pid, …)` reaches everything it
/// forks. Foundation's `Process` cannot do that, and a parent-side `setpgid` after `run()` races the child's `exec`.
/// Only the standard streams are inherited; every other descriptor is closed in the child.
public final class SpawnedProcess: @unchecked Sendable {
    public enum Termination: Equatable, Sendable {
        case exit(Int32)
        case signal(Int32)

        /// The exit code or the signal number, as Foundation's `terminationStatus`.
        public var status: Int32 {
            switch self {
            case .exit(let code), .signal(let code): code
            }
        }

        /// The exit code, or 128 plus the signal number, as shells report it.
        public var shellStatus: Int32 {
            switch self {
            case .exit(let code): code
            case .signal(let signal): 128 + signal
            }
        }
    }

    public let pid: pid_t
    private let lock = NSLock()
    private var _termination: Termination?
    private var onExit: (@Sendable (pid_t, Termination) -> Void)?

    /// Set once the child has exited, before it is reaped.
    public var termination: Termination? { lock.withLock { _termination } }
    public var isRunning: Bool { termination == nil }

    /// `newSession` starts the child in a session of its own, with no controlling terminal, so nothing it runs can
    /// read from or take over the terminal of this process; it then leads its own process group too.
    /// A nil `stdin` reads `/dev/null`. The child's ends of the pipes are closed here once it has them, so the
    /// readers see EOF when it and whatever inherited them are gone. `onExit` gets the pid and how it ended, once,
    /// on the reaper thread, before the child is reaped, so its pid is still its own.
    public init(
        executable: URL, arguments: [String], environment: [String: String], directory: URL? = nil,
        newProcessGroup: Bool = true, newSession: Bool = false, stdin: Pipe?, stdout: Pipe, stderr: Pipe,
        onExit: @escaping @Sendable (pid_t, Termination) -> Void
    ) throws {
        #if canImport(Darwin)
        var attributes: posix_spawnattr_t?
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        let setSession = POSIX_SPAWN_SETSID
        #else
        var attributes = posix_spawnattr_t()
        var flags = Int32(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        let setSession: Int32 = 0x80 // glibc's POSIX_SPAWN_SETSID, which Swift doesn't import
        #endif
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        if newSession {
            flags |= setSession
        } else if newProcessGroup {
            flags |= Int32(POSIX_SPAWN_SETPGROUP)
            posix_spawnattr_setpgroup(&attributes, 0)
        }
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        #else
        var actions = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let stdin {
            posix_spawn_file_actions_adddup2(&actions, stdin.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory.path) }
        #if !canImport(Darwin)
        // Linux has no POSIX_SPAWN_CLOEXEC_DEFAULT: after the dups above, close everything past the standard streams.
        posix_spawn_file_actions_addclosefrom_np(&actions, 3)
        #endif

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        self.pid = pid
        self.onExit = onExit

        try? stdin?.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        if stderr !== stdout { try? stderr.fileHandleForWriting.close() }

        // A thread of its own blocks in `waitpid` until the child exits. An exit dispatch source registers its
        // watch asynchronously, so a child that exits in between is never reported, and a blocking wait on a shared
        // queue could exhaust its threads.
        let reaper = Thread { [self] in reap() }
        reaper.name = "SpawnedProcess \(pid)"
        reaper.stackSize = 64 << 10
        reaper.start()
    }

    /// Sends SIGTERM while the child has not been reaped, so the pid is still its own.
    public func terminate() {
        lock.withLock { if _termination == nil { _ = kill(pid, SIGTERM) } }
    }

    /// Runs on the reaper thread, outside the lock: `isRunning` and `terminate()` never wait for the child. It
    /// waits without reaping (`WNOWAIT`), records the exit and runs `onExit` while the zombie still holds the pid,
    /// and reaps last, so nothing that signals by pid or group in between can reach a process that reused it.
    private func reap() {
        var info = siginfo_t()
        var waited: Int32
        repeat {
            waited = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
        } while waited == -1 && errno == EINTR
        // Nothing else reaps this pid; should something have, the exit is still reported so no waiter hangs.
        #if canImport(Darwin)
        let exitStatus = info.si_status
        #else
        let exitStatus = info._sifields._sigchld.si_status
        #endif
        let termination: Termination = switch waited == 0 ? Int(info.si_code) : -1 {
        case Int(CLD_EXITED): .exit(exitStatus)
        case Int(CLD_KILLED), Int(CLD_DUMPED): .signal(exitStatus)
        default: .exit(-1)
        }
        let callback = lock.withLock {
            _termination = termination
            defer { onExit = nil }
            return onExit
        }
        callback?(pid, termination)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
    }
}
