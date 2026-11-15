import Foundation

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
