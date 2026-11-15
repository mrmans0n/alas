import Foundation

extension Pipe {
    /// A pipe for a child process whose ends close on exec. On Linux,
    /// Foundation's `Process` picks the descriptors a child closes by scanning
    /// `/proc/self/fd` before it spawns, so a pipe made concurrently leaks into
    /// that child. A long-lived one then holds the write end, and the reader
    /// never sees EOF. The child still gets its own ends: `dup2` onto 0, 1 and
    /// 2 clears the flag.
    public static func closingOnExec() -> Pipe {
        let pipe = Pipe()
        _ = fcntl(pipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        return pipe
    }
}
