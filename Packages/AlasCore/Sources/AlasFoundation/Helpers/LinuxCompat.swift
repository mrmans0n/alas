import Foundation
#if canImport(CAlasLinux)
import CAlasLinux
#endif

// Stand-ins for Apple-only runtime pieces the core calls, so that code
// builds unchanged on Linux. Each is a no-op or a plain equivalent there.

#if !canImport(ObjectiveC)
/// Linux has no Objective-C autorelease pools; the body just runs.
@inlinable
public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif

/// Makes writes to a closed pipe or socket fail with `EPIPE` instead of
/// raising SIGPIPE, which would kill the process. macOS switches it per
/// descriptor; Linux has no such switch, so there the first call ignores
/// SIGPIPE for the whole process.
public enum NoSigPipe {
    @discardableResult
    public static func pipe(_ fd: Int32) -> Bool {
        #if canImport(Darwin)
        fcntl(fd, F_SETNOSIGPIPE, 1) != -1
        #else
        ignoredProcessWide
        #endif
    }

    @discardableResult
    public static func socket(_ fd: Int32) -> Bool {
        #if canImport(Darwin)
        var on: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
        #else
        return ignoredProcessWide
        #endif
    }

    #if !canImport(Darwin)
    private static let ignoredProcessWide: Bool = {
        _ = signal(SIGPIPE, SIG_IGN)
        return true
    }()
    #endif
}

/// The path an open descriptor refers to, as the filesystem spells it:
/// `F_GETPATH` on macOS, the `/proc/self/fd` link on Linux.
public func pathOfOpenFile(_ fd: Int32) -> String? {
    #if canImport(Darwin)
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
    return String(cString: buffer)
    #else
    try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(fd)")
    #endif
}

/// `SOCK_STREAM` as `socket(2)` takes it: Glibc imports it as an enum case.
public var streamSocketType: Int32 {
    #if canImport(Glibc)
    Int32(SOCK_STREAM.rawValue)
    #else
    SOCK_STREAM
    #endif
}

/// A stream socket that closes on exec. On Linux, Foundation's `Process`
/// picks the descriptors a child closes by scanning `/proc/self/fd` before it
/// spawns, so a socket made concurrently would leak into that child and stay
/// open, or keep its port, for the child's life. macOS spawns with
/// `POSIX_SPAWN_CLOEXEC_DEFAULT`.
public func streamSocket(_ family: Int32) -> Int32 {
    #if canImport(Glibc)
    socket(family, streamSocketType | Int32(SOCK_CLOEXEC.rawValue), 0)
    #else
    socket(family, streamSocketType, 0)
    #endif
}

/// `accept(2)` whose connection closes on exec, for the reason `streamSocket`
/// gives.
public func acceptClosingOnExec(_ listener: Int32) -> Int32 {
    let fd = accept(listener, nil, nil)
    #if canImport(Glibc)
    // ponytail: not atomic (Glibc's module hides accept4); a spawn between the
    // two calls can still inherit the connection. Import accept4 via a C shim
    // if that window ever shows up.
    if fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    #endif
    return fd
}

/// Renames that refuse to replace an existing entry (`exclusive`) or that
/// atomically exchange two (`swap`): `renameatx_np` on macOS, `renameat2`
/// on Linux. Returns 0, or -1 with `errno` set.
public enum AtomicRename {
    public enum Mode: Sendable {
        case plain, exclusive, swap
    }

    public static func renameAt(
        _ fromDirectory: Int32, _ from: String, _ toDirectory: Int32, _ to: String, mode: Mode
    ) -> Int32 {
        #if canImport(Darwin)
        let flags: UInt32 = switch mode {
        case .plain: 0
        case .exclusive: UInt32(RENAME_EXCL)
        case .swap: UInt32(RENAME_SWAP)
        }
        return renameatx_np(fromDirectory, from, toDirectory, to, flags)
        #else
        let flags: UInt32 = switch mode {
        case .plain: 0
        case .exclusive: UInt32(ALAS_RENAME_NOREPLACE)
        case .swap: UInt32(ALAS_RENAME_EXCHANGE)
        }
        return alas_renameat2(fromDirectory, from, toDirectory, to, flags)
        #endif
    }

    public static func rename(_ from: String, _ to: String, mode: Mode) -> Int32 {
        renameAt(AT_FDCWD, from, AT_FDCWD, to, mode: mode)
    }
}

#if !canImport(Darwin)
/// Darwin's spellings of `stat`'s time fields, so callers read both.
extension stat {
    public var st_mtimespec: timespec { st_mtim }
    public var st_ctimespec: timespec { st_ctim }
}

public typealias CFAbsoluteTime = Double

/// Seconds since 2001, as CoreFoundation's clock reads.
public func CFAbsoluteTimeGetCurrent() -> CFAbsoluteTime {
    Date().timeIntervalSinceReferenceDate
}
#endif

/// Writes to stderr without going through C's `stderr` global, which Swift
/// 6 treats as shared mutable state on Linux.
public func writeStandardError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

#if !canImport(Darwin)
/// Linux's Dispatch has no `DispatchSerialQueue`; this is the part actors use
/// as their executor: jobs run in order on one serial queue.
public final class DispatchSerialQueue: SerialExecutor, @unchecked Sendable {
    private let queue: DispatchQueue

    public init(label: String) {
        queue = DispatchQueue(label: label)
    }

    public func async(execute work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { [self] in job.runSynchronously(on: asUnownedSerialExecutor()) }
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
#endif

/// The uid of the process at the other end of a Unix socket.
public func peerUID(of socket: Int32) -> uid_t? {
    #if canImport(Darwin)
    var uid = uid_t(0)
    var gid = gid_t(0)
    return getpeereid(socket, &uid, &gid) == 0 ? uid : nil
    #else
    var uid: UInt32 = 0
    return alas_peer_uid(socket, &uid) == 0 ? uid_t(uid) : nil
    #endif
}

/// Whether two values from `JSONSerialization` (or a property list) hold
/// the same thing. Apple platforms compare them as Foundation objects;
/// elsewhere they are plain Swift values, compared by their sorted JSON.
public func jsonValuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
    #if canImport(ObjectiveC)
    (lhs as AnyObject).isEqual(rhs)
    #else
    let encode = { (value: Any) in try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]) }
    guard let left = encode(lhs), let right = encode(rhs) else { return String(describing: lhs) == String(describing: rhs) }
    return left == right
    #endif
}
