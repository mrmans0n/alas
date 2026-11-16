import Foundation
#if canImport(CAlasLinux)
import CAlasLinux
#endif

extension Pipe {
    /// A pipe for a child process whose ends close on exec. On Linux,
    /// Foundation's `Process` picks the descriptors a child closes by scanning
    /// `/proc/self/fd` before it spawns, so a pipe made concurrently leaks into
    /// that child. A long-lived one then holds the write end, and the reader
    /// never sees EOF. The child still gets its own ends: `dup2` onto 0, 1 and
    /// 2 clears the flag.
    public static func closingOnExec() -> Pipe {
        closingOnExec(replacing: Pipe())
    }

    /// Configure a newly initialized, unpublished pipe before any I/O or monitoring.
    static func closingOnExec(replacing pipe: Pipe) -> Pipe {
        #if os(Linux)
        // Foundation cannot build a Pipe from existing handles. Its descriptors
        // are placeholders: a concurrent spawn may already have inherited them.
        // Replace their backing pipe with pipe2/dup3(O_CLOEXEC), so every real
        // transport endpoint closes on exec from birth. FileHandle stores only
        // the descriptor until I/O/monitoring begins; these handles are unused.
        // Creating the replacement needs two additional descriptors briefly.
        let result = alas_replace_pipe_cloexec(
            pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor)
        if result != 0 {
            let code = errno
            fatalError("Creating a close-on-exec pipe failed: \(String(cString: strerror(code))) (errno \(code))")
        }
        #else
        _ = fcntl(pipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        #endif
        return pipe
    }
}
